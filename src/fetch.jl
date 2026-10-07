# io layer: fetch (spec §3.6) and the default HTTP transport on the stdlib
# Downloads. Format logic stays in the core (parse, status_policy).

import Downloads

"""
    Fetched(policy, status, robots)

The result of `fetch`. `policy` is `:parsed`, `:allow_all` or
`:disallow_all`; `status` is the final HTTP status, or `nothing` when there
was no response; `robots` is the parsed file when `policy === :parsed`.
"""
struct Fetched
    policy::Symbol
    status::Union{Nothing,UInt32}
    robots::Union{Nothing,RobotsFile}
end

Base.:(==)(a::Fetched, b::Fetched) = a.policy === b.policy && a.status == b.status && a.robots == b.robots
Base.hash(f::Fetched, h::UInt) = hash(f.robots, hash(f.status, hash(f.policy, hash(:Fetched, h))))

"""
    Response(status, location, body)

What a transport returns for one request: the HTTP `status`, the `Location`
header (`nothing` if absent) and the body bytes. A transport may return any
value with these three properties, such as a `NamedTuple`.
"""
struct Response
    status::Int
    location::Union{Nothing,String}
    body::Vector{UInt8}
end

# ---------------------------------------------------------------------------
# Origins and redirects
# ---------------------------------------------------------------------------

# scheme://authority with at most a trailing '/' (no path, query or fragment).
function check_origin(origin::AbstractString)::String
    s = String(origin)
    rest = startswith(s, "http://") ? 8 : startswith(s, "https://") ? 9 : invalid("invalid_origin")
    b = codeunits(s)
    stop = length(b)
    stop >= rest && b[stop] == UInt8('/') && (stop -= 1)
    stop >= rest || invalid("invalid_origin")             # empty authority
    for k in rest:stop
        c = b[k]
        (c == UInt8('/') || c == UInt8('?') || c == UInt8('#') || c <= 0x20 || c == 0x7F) &&
            invalid("invalid_origin")
    end
    return String(b[1:stop])
end

# Split an absolute URL into "scheme://authority", path and "?query"
# (the fragment dropped).
function split_url(url::String)
    frag = findfirst('#', url)
    frag === nothing || (url = url[1:prevind(url, frag)])
    sep = findfirst("://", url)
    k = sep === nothing ? 1 : last(sep) + 1
    while k <= ncodeunits(url) && !(codeunit(url, k) in (UInt8('/'), UInt8('?')))
        k += 1
    end
    prefix = url[1:prevind(url, k)]
    path, query = split_query(url[k:end])
    return prefix, path, query
end

# RFC 3986 §5.2.4.
function remove_dot_segments(path::String)::String
    input = path
    out = String[]
    while !isempty(input)
        if startswith(input, "../")
            input = input[4:end]
        elseif startswith(input, "./")
            input = input[3:end]
        elseif startswith(input, "/./")
            input = input[3:end]
        elseif input == "/."
            input = "/"
        elseif startswith(input, "/../")
            input = input[4:end]
            isempty(out) || pop!(out)
        elseif input == "/.."
            input = "/"
            isempty(out) || pop!(out)
        elseif input == "." || input == ".."
            input = ""
        else
            k = findnext('/', input, startswith(input, "/") ? 2 : 1)
            seg = k === nothing ? input : input[1:prevind(input, k)]
            push!(out, seg)
            input = k === nothing ? "" : input[k:end]
        end
    end
    return join(out)
end

# Resolve a Location header against the URL that returned it (RFC 3986 §5.2).
function resolve(base::String, location::String)::String
    loc = String(strip(location))
    frag = findfirst('#', loc)
    frag === nothing || (loc = loc[1:prevind(loc, frag)])
    occursin(r"^[A-Za-z][A-Za-z0-9+.\-]*:", loc) && return loc
    prefix, path, query = split_url(base)
    if startswith(loc, "//")
        return prefix[1:findfirst(':', prefix)] * loc
    elseif startswith(loc, "/")
        lp, lq = split_query(loc)
        return prefix * remove_dot_segments(lp) * lq
    elseif startswith(loc, "?")
        return prefix * path * loc
    elseif isempty(loc)
        return prefix * path * query
    end
    lp, lq = split_query(loc)
    dir = isempty(path) ? "/" : path[1:something(findlast('/', path), 0)]
    return prefix * remove_dot_segments(dir * lp) * lq
end

function split_query(s::String)
    q = findfirst('?', s)
    return q === nothing ? (s, "") : (s[1:prevind(s, q)], s[q:end])
end

# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------

"""
    RobotsTxt.fetch(origin; transport = DownloadsTransport(), limits = Limits()) -> Fetched

Spec operation `fetch` (io layer). Requests `origin * "/robots.txt"`, follows
up to `limits.max_redirects` redirects itself, applies `status_policy` and
parses a 2xx body. `origin` is `http://` or `https://` plus an authority, with
at most a trailing `/`.

`transport` is called as `transport(url::String)` and returns `nothing` when
there was no response (connection, TLS or timeout failure), or a value with
`status`, `location` and `body` properties such as `Response`. The default is
a `DownloadsTransport` reading at most `limits.max_bytes + 1` body bytes.

A failed fetch is a policy, not an error: the only error is `RobotsError` with
code `robotstxt.invalid_origin`. Exceptions thrown by a custom transport
propagate unchanged.
"""
function fetch(origin::AbstractString; limits::Limits=Limits(),
               transport=DownloadsTransport(max_body=body_cap(limits)))::Fetched
    url = check_origin(origin) * "/robots.txt"
    redirects = 0
    while true
        r = transport(url)
        r === nothing && return Fetched(:disallow_all, nothing, nothing)
        status = r.status
        0 <= status <= typemax(UInt32) || return Fetched(:disallow_all, nothing, nothing)
        policy = status_policy(status)
        if policy === :follow_redirect
            location = r.location
            # Too many redirects, or nowhere to go: unavailable (D-007).
            (redirects >= limits.max_redirects || location === nothing || isempty(strip(location))) &&
                return Fetched(:allow_all, UInt32(status), nothing)
            redirects += 1
            url = resolve(url, String(location))
        elseif policy === :parse
            body = r.body
            body === nothing && (body = UInt8[])
            bytes = body isa AbstractString ? codeunits(String(body)) : body
            cap = body_cap(limits)
            length(bytes) > cap && (bytes = view(bytes, firstindex(bytes):firstindex(bytes)+cap-1))
            return Fetched(:parsed, UInt32(status), parse(bytes; limits))
        else
            return Fetched(policy, UInt32(status), nothing)
        end
    end
end

body_cap(limits::Limits)::Int = Int(min(limits.max_bytes, UInt64(typemax(Int) - 1))) + 1

# ---------------------------------------------------------------------------
# Default transport: stdlib Downloads, redirects off
# ---------------------------------------------------------------------------

"""
    DownloadsTransport(; timeout = 30.0, max_body = 512_001, user_agent = nothing)

The default `fetch` transport, on the standard library's `Downloads`. It sends
`GET` with `Accept-Encoding: identity`, never follows redirects itself (`fetch`
does, per the spec), stops reading the body after `max_body` bytes, and
returns `nothing` on a connection, TLS or timeout failure or for a URL that
isn't `http` or `https`. `user_agent` sets the `User-Agent` header.
"""
Base.@kwdef struct DownloadsTransport
    timeout::Float64 = 30.0
    max_body::Int = 512_001
    user_agent::Union{Nothing,String} = nothing
end

# A sink that keeps the first `cap` bytes and then asks Downloads to stop.
mutable struct CappedSink <: IO
    buf::Vector{UInt8}
    cap::Int
    full::Bool
    stop::Base.Event
end

function Base.unsafe_write(s::CappedSink, p::Ptr{UInt8}, n::UInt)
    room = s.cap - length(s.buf)
    take = min(Int(n), room)
    take > 0 && append!(s.buf, unsafe_wrap(Array, p, take))
    if !s.full && Int(n) >= room
        s.full = true
        notify(s.stop)
    end
    return n
end
Base.write(s::CappedSink, b::UInt8) = (unsafe_write(s, Ref(b), UInt(1)); 1)
Base.isopen(::CappedSink) = true

const DOWNLOADER = Ref{Union{Nothing,Downloads.Downloader}}(nothing)
const DOWNLOADER_LOCK = ReentrantLock()

function no_redirect_downloader()::Downloads.Downloader
    lock(DOWNLOADER_LOCK) do
        d = DOWNLOADER[]
        if d === nothing
            d = Downloads.Downloader()
            d.easy_hook = (easy, info) ->
                Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_FOLLOWLOCATION, false)
            DOWNLOADER[] = d
        end
        return d
    end
end

function header(r::Downloads.Response, name::String)::Union{Nothing,String}
    for (k, v) in r.headers
        lowercase(k) == name && return String(strip(v))
    end
    return nothing
end

function (t::DownloadsTransport)(url::AbstractString)::Union{Nothing,Response}
    scheme = lowercase(first(split(url, "://"; limit=2)))
    (scheme == "http" || scheme == "https") || return nothing
    sink = CappedSink(UInt8[], t.max_body, false, Base.Event())
    headers = ["Accept-Encoding" => "identity"]
    t.user_agent === nothing || push!(headers, "User-Agent" => t.user_agent)
    r = try
        Downloads.request(String(url); method="GET", headers, output=sink, timeout=t.timeout,
                          throw=false, downloader=no_redirect_downloader(), interrupt=sink.stop)
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    if r isa Downloads.RequestError
        # Stopping at max_body ends the request early; anything else is "no response".
        (sink.full && r.response.status > 0) || return nothing
        r = r.response
    end
    r.status > 0 || return nothing
    return Response(r.status, header(r, "location"), sink.buf)
end
