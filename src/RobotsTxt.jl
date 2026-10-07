"""
    RobotsTxt

Parse robots.txt files and decide whether a crawler may fetch a path, per
RFC 9309 (the Robots Exclusion Protocol).

Implements the robots.txt spec (see `.spec/spec/SPEC.md`). `Crawl-delay` is
supported as an extension; it is not part of RFC 9309.

The operations are deliberately not exported (`parse` and `fetch` would clash
with `Base`); call them qualified: `RobotsTxt.parse`, `RobotsTxt.is_allowed`,
`RobotsTxt.matching_rule`, `RobotsTxt.crawl_delay`, `RobotsTxt.status_policy`
and `RobotsTxt.fetch`.
"""
module RobotsTxt

export RobotsFile, Group, Rule, Fetched, Response, DownloadsTransport, RobotsError, Limits

"""
    RobotsError(kind, code)

Raised by `is_allowed`, `matching_rule`, `crawl_delay` and `fetch` when an
argument is invalid. `kind` is the spec's error kind (always `:invalid_input`)
and `code` the stable spec code: `"robotstxt.invalid_user_agent"`,
`"robotstxt.invalid_path"` or `"robotstxt.invalid_origin"`. `parse` never
raises.
"""
struct RobotsError <: Exception
    kind::Symbol
    code::String
end

Base.showerror(io::IO, e::RobotsError) = print(io, "RobotsError(", e.kind, "): ", e.code)

@noinline invalid(code::String) = throw(RobotsError(:invalid_input, "robotstxt." * code))

"""
    Limits(; max_bytes = 512_000, max_redirects = 5)

Limits on untrusted input, with the spec's defaults. Input past `max_bytes` is
ignored (and `truncated` set), never an error; `fetch` follows at most
`max_redirects` redirects.
"""
Base.@kwdef struct Limits
    max_bytes::UInt64 = 512_000
    max_redirects::UInt32 = 5
end

# ---------------------------------------------------------------------------
# Types (spec §2)
# ---------------------------------------------------------------------------

"""
    Rule(allow, pattern, line)

One `allow` or `disallow` line. `pattern` is the value as written, trimmed and
not normalized; `line` is its 1-based line number in the file.
"""
struct Rule
    allow::Bool
    pattern::String
    line::UInt32
    # The pattern's original bytes, normalized (spec §3.3). Matching uses
    # these, so invalid UTF-8 replaced in `pattern` still matches as written.
    normalized::Vector{UInt8}

    Rule(allow::Bool, raw::AbstractVector{UInt8}, line::Integer) =
        new(allow, text(raw), UInt32(line), normalize(raw))
end

Rule(allow::Bool, pattern::AbstractString, line::Integer) = Rule(allow, codeunits(String(pattern)), line)

Base.:(==)(a::Rule, b::Rule) = a.allow == b.allow && a.pattern == b.pattern && a.line == b.line
Base.hash(r::Rule, h::UInt) = hash(r.line, hash(r.pattern, hash(r.allow, hash(:Rule, h))))
Base.show(io::IO, r::Rule) = print(io, "Rule(", r.allow, ", ", repr(r.pattern), ", ", Int(r.line), ")")

"""
    Group(user_agents, rules, crawl_delay)

One or more `user-agent` lines and the rules that follow them. `user_agents`
are the values as written, trimmed. `crawl_delay` (seconds, or `nothing`) is
the group's first valid `Crawl-delay`: an extension, not RFC 9309.
"""
struct Group
    user_agents::Vector{String}
    rules::Vector{Rule}
    crawl_delay::Union{Nothing,Float64}
end

Base.:(==)(a::Group, b::Group) =
    a.user_agents == b.user_agents && a.rules == b.rules && isequal(a.crawl_delay, b.crawl_delay)
Base.hash(g::Group, h::UInt) = hash(g.crawl_delay, hash(g.rules, hash(g.user_agents, hash(:Group, h))))

"""
    RobotsFile(groups, sitemaps, truncated)

A parsed robots.txt file: its groups in file order, its sitemap URLs in file
order, and whether the input was longer than `max_bytes`.
"""
struct RobotsFile
    groups::Vector{Group}
    sitemaps::Vector{String}
    truncated::Bool
end

Base.:(==)(a::RobotsFile, b::RobotsFile) =
    a.groups == b.groups && a.sitemaps == b.sitemaps && a.truncated == b.truncated
Base.hash(f::RobotsFile, h::UInt) = hash(f.truncated, hash(f.sitemaps, hash(f.groups, hash(:RobotsFile, h))))

# ---------------------------------------------------------------------------
# Text: reported values replace invalid UTF-8 with U+FFFD (spec §2)
# ---------------------------------------------------------------------------

@inline iscont(b::UInt8) = 0x80 <= b <= 0xBF

# Decode `b` as UTF-8, replacing each maximal invalid subpart with U+FFFD
# (Unicode §3.9 "best practice", as Python, Rust and Swift do).
function text(b::AbstractVector{UInt8})::String
    s = String(Vector{UInt8}(b))
    isvalid(s) && return s
    out = IOBuffer(sizehint=length(b) + 8)
    i, n = firstindex(b), lastindex(b)
    while i <= n
        c = b[i]
        if c < 0x80
            write(out, c)
            i += 1
            continue
        end
        # Expected length and the allowed range of the second byte.
        need, lo2, hi2 = if 0xC2 <= c <= 0xDF
            1, 0x80, 0xBF
        elseif c == 0xE0
            2, 0xA0, 0xBF
        elseif 0xE1 <= c <= 0xEC || c == 0xEE || c == 0xEF
            2, 0x80, 0xBF
        elseif c == 0xED
            2, 0x80, 0x9F
        elseif c == 0xF0
            3, 0x90, 0xBF
        elseif 0xF1 <= c <= 0xF3
            3, 0x80, 0xBF
        elseif c == 0xF4
            3, 0x80, 0x8F
        else
            0, 0x00, 0x00
        end
        good = 0                               # continuation bytes accepted
        while good < need
            j = i + 1 + good
            j <= n || break
            d = b[j]
            ok = good == 0 ? (lo2 <= d <= hi2) : iscont(d)
            ok || break
            good += 1
        end
        if need > 0 && good == need
            for k in i:i+need
                write(out, b[k])
            end
        else
            write(out, '\ufffd')
        end
        i += 1 + good
    end
    return String(take!(out))
end

# ---------------------------------------------------------------------------
# parse (spec §3.1)
# ---------------------------------------------------------------------------

@inline isws(b::UInt8) = b == UInt8(' ') || b == UInt8('\t')
@inline iseol(b::UInt8) = b == UInt8('\n') || b == UInt8('\r')
@inline lower(b::UInt8) = UInt8('A') <= b <= UInt8('Z') ? b + 0x20 : b
@inline isdigitbyte(b::UInt8) = UInt8('0') <= b <= UInt8('9')

# Case-insensitive (ASCII) comparison of data[a:z] with a lower-case key.
function keyis(data, a::Int, z::Int, key::String)::Bool
    z - a + 1 == ncodeunits(key) || return false
    for k in 0:(z - a)
        lower(data[a + k]) == codeunit(key, k + 1) || return false
    end
    return true
end

# A non-negative decimal, [0-9]+(\.[0-9]+)?, that is finite as a correctly
# rounded Float64: seconds. Anything else is nothing (skipped).
function delay_value(data, a::Int, z::Int)::Union{Nothing,Float64}
    a <= z || return nothing
    i = a
    while i <= z && isdigitbyte(data[i])
        i += 1
    end
    i == a && return nothing
    int_end = i
    if i <= z
        data[i] == UInt8('.') || return nothing
        i += 1
        f = i
        while i <= z && isdigitbyte(data[i])
            i += 1
        end
        (i == f || i <= z) && return nothing
    end
    s = String(Vector{UInt8}(view(data, a:z)))
    v = tryparse(Float64, s)
    v === nothing || return isfinite(v) ? v : nothing
    # Base reports a result out of range as a failure (strtod's ERANGE). With a
    # non-zero integer part it overflowed: skipped. Otherwise it is below half
    # the smallest subnormal, and rounds to 0.0.
    for k in a:(int_end - 1)
        data[k] == UInt8('0') || return nothing
    end
    return 0.0
end

mutable struct GroupBuilder
    user_agents::Vector{String}
    rules::Vector{Rule}
    crawl_delay::Union{Nothing,Float64}
end

"""
    RobotsTxt.parse(data; limits = Limits()) -> RobotsFile

Spec operation `parse`. Parses a robots.txt file given as bytes
(`AbstractVector{UInt8}`) or a string. Lenient: never throws. Input past
`limits.max_bytes` is ignored, a line cut by the limit is dropped, and
`truncated` is set.
"""
function parse(data::AbstractVector{UInt8}; limits::Limits=Limits())::RobotsFile
    lo, hi = firstindex(data), lastindex(data)
    n = hi - lo + 1
    max_bytes = limits.max_bytes
    truncated = UInt64(n) > max_bytes
    if truncated
        # 1. Keep max_bytes; drop the line the limit cut (D-005).
        hi = lo + Int(max_bytes) - 1
        if hi >= lo && !iseol(data[hi])
            while hi >= lo && !iseol(data[hi])
                hi -= 1
            end
        end
    end
    # 2. A UTF-8 byte order mark, or a prefix of one, is skipped.
    if lo <= hi && data[lo] == 0xEF
        lo += 1
        if lo <= hi && data[lo] == 0xBB
            lo += 1
            lo <= hi && data[lo] == 0xBF && (lo += 1)
        end
    end

    groups = GroupBuilder[]
    sitemaps = String[]
    open_agents = false
    lineno = 0
    i = lo
    start = lo
    # 3. Lines end at \r\n, \n or a lone \r; a final unterminated line counts.
    while i <= hi
        b = data[i]
        if iseol(b)
            lineno += 1
            open_agents = parse_line!(groups, sitemaps, open_agents, data, start, i - 1, lineno)
            i += (b == UInt8('\r') && i < hi && data[i + 1] == UInt8('\n')) ? 2 : 1
            start = i
        else
            i += 1
        end
    end
    if start <= hi
        lineno += 1
        parse_line!(groups, sitemaps, open_agents, data, start, hi, lineno)
    end
    return RobotsFile([Group(g.user_agents, g.rules, g.crawl_delay) for g in groups], sitemaps, truncated)
end

parse(data::Union{String,SubString{String}}; limits::Limits=Limits()) = parse(codeunits(data); limits)
parse(data::AbstractString; limits::Limits=Limits()) = parse(String(data); limits)

# 4–5. One line, data[a:z]. Returns whether the agent list is open afterwards.
function parse_line!(groups, sitemaps, open_agents::Bool, data, a::Int, z::Int, lineno::Int)::Bool
    # Comment from the first '#'.
    for k in a:z
        if data[k] == UInt8('#')
            z = k - 1
            break
        end
    end
    while a <= z && isws(data[a]); a += 1; end
    while z >= a && isws(data[z]); z -= 1; end
    a > z && return open_agents

    # Key and value: split at the first ':', else exactly two words (D-006).
    colon = 0
    for k in a:z
        if data[k] == UInt8(':')
            colon = k
            break
        end
    end
    if colon != 0
        ka, kz, va, vz = a, colon - 1, colon + 1, z
    else
        k = a
        while k <= z && !isws(data[k]); k += 1; end
        k > z && return open_agents            # one word
        ka, kz = a, k - 1
        while k <= z && isws(data[k]); k += 1; end
        va, vz = k, z
        for m in va:vz
            isws(data[m]) && return open_agents  # three or more words
        end
    end
    while ka <= kz && isws(data[ka]); ka += 1; end
    while kz >= ka && isws(data[kz]); kz -= 1; end
    while va <= vz && isws(data[va]); va += 1; end
    while vz >= va && isws(data[vz]); vz -= 1; end
    ka > kz && return open_agents
    value = view(data, va:vz)

    if keyis(data, ka, kz, "user-agent")
        if isempty(groups) || !open_agents
            push!(groups, GroupBuilder(String[], Rule[], nothing))
        end
        push!(groups[end].user_agents, text(value))
        return true
    elseif keyis(data, ka, kz, "allow") || keyis(data, ka, kz, "disallow")
        isempty(groups) && return open_agents
        isempty(value) || push!(groups[end].rules, Rule(keyis(data, ka, kz, "allow"), value, lineno))
        return false
    elseif keyis(data, ka, kz, "crawl-delay")       # extension (D-009)
        isempty(groups) && return open_agents
        g = groups[end]
        g.crawl_delay === nothing && (g.crawl_delay = delay_value(data, va, vz))
        return false
    elseif keyis(data, ka, kz, "sitemap")
        isempty(value) || push!(sitemaps, text(value))
        return open_agents
    end
    return open_agents                          # unknown keys change nothing
end

# ---------------------------------------------------------------------------
# Matching (spec §3.2, §3.3)
# ---------------------------------------------------------------------------

@inline istokenbyte(b::UInt8) =
    (UInt8('A') <= b <= UInt8('Z')) | (UInt8('a') <= b <= UInt8('z')) | (b == UInt8('_')) | (b == UInt8('-'))

@inline ishex(b::UInt8) =
    (UInt8('0') <= b <= UInt8('9')) | (UInt8('A') <= b <= UInt8('F')) | (UInt8('a') <= b <= UInt8('f'))
@inline hexval(b::UInt8) = b <= UInt8('9') ? b - UInt8('0') : lower(b) - UInt8('a') + 0x0a
@inline isunreserved(b::UInt8) =
    (UInt8('A') <= b <= UInt8('Z')) | (UInt8('a') <= b <= UInt8('z')) | (UInt8('0') <= b <= UInt8('9')) |
    (b == UInt8('-')) | (b == UInt8('.')) | (b == UInt8('_')) | (b == UInt8('~'))

const HEXDIGITS = b"0123456789ABCDEF"

"""
    RobotsTxt.normalize(bytes) -> Vector{UInt8}

Percent-encoding normalization applied to paths and patterns alike (spec §3.3,
D-004): `%XX` of an unreserved character is decoded, other `%XX` get upper-case
hex, and bytes 0x00–0x20, 0x7F and 0x80–0xFF are percent-encoded.
"""
function normalize(b::AbstractVector{UInt8})::Vector{UInt8}
    out = Vector{UInt8}(undef, 0)
    sizehint!(out, length(b))
    i, n = firstindex(b), lastindex(b)
    while i <= n
        c = b[i]
        if c == UInt8('%') && i + 2 <= n && ishex(b[i + 1]) && ishex(b[i + 2])
            v = (hexval(b[i + 1]) << 4) | hexval(b[i + 2])
            if isunreserved(v)
                push!(out, v)
            else
                push!(out, UInt8('%'), HEXDIGITS[(v >> 4) + 1], HEXDIGITS[(v & 0x0f) + 1])
            end
            i += 3
        elseif c <= 0x20 || c >= 0x7F
            push!(out, UInt8('%'), HEXDIGITS[(c >> 4) + 1], HEXDIGITS[(c & 0x0f) + 1])
            i += 1
        else
            push!(out, c)
            i += 1
        end
    end
    return out
end

# Does p[pa:pz] occur in q at position at?
@inline function occurs_at(p::Vector{UInt8}, pa::Int, pz::Int, q::Vector{UInt8}, at::Int)::Bool
    at + (pz - pa) <= length(q) || return false
    for k in 0:(pz - pa)
        @inbounds p[pa + k] == q[at + k] || return false
    end
    return true
end

# First position >= from where p[pa:pz] occurs in q, or 0.
function find_piece(p::Vector{UInt8}, pa::Int, pz::Int, q::Vector{UInt8}, from::Int)::Int
    pa > pz && return from
    stop = length(q) - (pz - pa)
    head = @inbounds p[pa]
    at = from
    while at <= stop
        @inbounds q[at] == head && occurs_at(p, pa, pz, q, at) && return at
        at += 1
    end
    return 0
end

"""
    RobotsTxt.pattern_matches(pattern, path) -> Bool

Whether the normalized `pattern` matches a prefix of the normalized `path`
(spec §3.3): `*` matches any run of bytes and a final `\$` anchors at the end.
Each literal piece between `*`s is found greedily left to right, so there is
no backtracking: the cost is linear in the path per piece.
"""
function pattern_matches(p::Vector{UInt8}, q::Vector{UInt8})::Bool
    np = length(p)
    anchored = np > 0 && p[np] == UInt8('$')
    pend = anchored ? np - 1 : np
    star = findfirst(==(UInt8('*')), view(p, 1:pend))
    # The first piece must match at the start of the path.
    first_end = star === nothing ? pend : star - 1
    occurs_at(p, 1, first_end, q, 1) || return false
    pos = first_end + 1                         # next unmatched byte of the path
    star === nothing && return !anchored || pos == length(q) + 1
    pa = star + 1
    while true
        nxt = findnext(==(UInt8('*')), view(p, 1:pend), pa)
        if nxt === nothing
            # The last piece. Anchored: it must end the path, after pos.
            len = pend - pa + 1
            anchored && return length(q) - len + 1 >= pos && occurs_at(p, pa, pend, q, length(q) - len + 1)
            return find_piece(p, pa, pend, q, pos) != 0
        end
        at = find_piece(p, pa, nxt - 1, q, pos)
        at == 0 && return false
        pos = at + (nxt - pa)
        pa = nxt + 1
    end
end

function check_user_agent(user_agent::AbstractString)
    isempty(user_agent) && invalid("invalid_user_agent")
    for c in user_agent
        (isascii(c) && istokenbyte(UInt8(c))) || invalid("invalid_user_agent")
    end
    return nothing
end

# The group token a user-agent value names (D-001): :global, or the length of
# its [A-Za-z_-] prefix (0 matches nothing).
function token_matches(value::String, user_agent::AbstractString)::Bool
    n = 0
    for b in codeunits(value)
        istokenbyte(b) || break
        n += 1
    end
    n == ncodeunits(user_agent) || return false
    ua = codeunits(user_agent)
    for k in 1:n
        lower(codeunit(value, k)) == lower(ua[k]) || return false
    end
    return true
end

isglobal(value::String) = value == "*" || (startswith(value, '*') && ncodeunits(value) > 1 && isws(codeunit(value, 2)))

names_crawler(g::Group, user_agent) = any(v -> token_matches(v, user_agent), g.user_agents)
isglobal(g::Group) = any(isglobal, g.user_agents)

# Spec §3.2: every group naming the crawler, merged; else every global group.
function crawler_groups(robots::RobotsFile, user_agent::AbstractString)::Vector{Group}
    ua = String(user_agent)
    specific = filter(g -> names_crawler(g, ua), robots.groups)
    isempty(specific) || return specific
    return filter(isglobal, robots.groups)
end

"""
    RobotsTxt.matching_rule(robots, user_agent, path) -> Union{Rule,Nothing}

Spec operation `matching_rule`: the rule that decides `is_allowed`, or
`nothing` when none does (including for `/robots.txt`). `user_agent` is the
crawler's product token (`[A-Za-z_-]+`); `path` starts with `/` and includes
the query.

Throws `RobotsError` with code `robotstxt.invalid_user_agent` or
`robotstxt.invalid_path`, checked in that order.
"""
function matching_rule(robots::RobotsFile, user_agent::AbstractString, path::AbstractString)::Union{Rule,Nothing}
    check_user_agent(user_agent)
    startswith(path, '/') || invalid("invalid_path")
    raw = codeunits(String(path))
    stop = findfirst(==(UInt8('#')), raw)
    raw = view(raw, 1:(stop === nothing ? length(raw) : stop - 1))
    # 1. /robots.txt (up to any '?') is always allowed.
    q = findfirst(==(UInt8('?')), raw)
    view(raw, 1:(q === nothing ? length(raw) : q - 1)) == b"/robots.txt" && return nothing
    # 2–4. Longest normalized pattern; allow wins ties; first in file among equals.
    target = normalize(raw)
    best = nothing
    best_len = -1
    for g in crawler_groups(robots, user_agent), r in g.rules
        len = length(r.normalized)
        wins = len > best_len || (len == best_len && r.allow && !(best::Rule).allow)
        wins && pattern_matches(r.normalized, target) || continue
        best, best_len = r, len
    end
    return best
end

"""
    RobotsTxt.is_allowed(robots, user_agent, path) -> Bool

Spec operation `is_allowed`: whether the crawler `user_agent` (a product token,
`[A-Za-z_-]+`) may fetch `path` (starting with `/`, including the query). `true`
when no rule matches or the deciding rule is an `allow`.

Throws `RobotsError` with code `robotstxt.invalid_user_agent` or
`robotstxt.invalid_path`, checked in that order.
"""
function is_allowed(robots::RobotsFile, user_agent::AbstractString, path::AbstractString)::Bool
    rule = matching_rule(robots, user_agent, path)
    return rule === nothing || rule.allow
end

"""
    RobotsTxt.crawl_delay(robots, user_agent) -> Union{Float64,Nothing}

Spec operation `crawl_delay` (an extension, not RFC 9309): the `Crawl-delay`
in seconds of the first of the crawler's groups that has one, or `nothing`.

Throws `RobotsError` with code `robotstxt.invalid_user_agent`.
"""
function crawl_delay(robots::RobotsFile, user_agent::AbstractString)::Union{Float64,Nothing}
    check_user_agent(user_agent)
    for g in crawler_groups(robots, user_agent)
        g.crawl_delay === nothing || return g.crawl_delay
    end
    return nothing
end

# ---------------------------------------------------------------------------
# status_policy (spec §3.5)
# ---------------------------------------------------------------------------

"""
    RobotsTxt.status_policy(http_status) -> Symbol

Spec operation `status_policy`: what the HTTP status of a `/robots.txt` fetch
means. One of `:parse` (2xx), `:follow_redirect` (3xx), `:allow_all` (4xx
except 429) or `:disallow_all` (429, 5xx and anything else). Never throws.
"""
function status_policy(http_status::Integer)::Symbol
    200 <= http_status <= 299 && return :parse
    300 <= http_status <= 399 && return :follow_redirect
    400 <= http_status <= 499 && http_status != 429 && return :allow_all
    return :disallow_all
end

include("fetch.jl")

end # module
