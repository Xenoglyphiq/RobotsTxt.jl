# Conformance runner: every case in the vendored spec's manifest.
# Loaded by runtests.jl. Set ROBOTSTXT_MANIFEST to run against another manifest.

using Base64
using JSON3
using RobotsTxt: RobotsTxt, RobotsFile, Group, Rule, Fetched, Response, RobotsError, Limits

const DEFAULT_MANIFEST = joinpath(@__DIR__, "..", ".spec", "conformance", "manifest.json")

# A robots.txt input: `value` (a string) or `base64` (raw bytes).
input_bytes(input)::Vector{UInt8} =
    haskey(input, "base64") ? base64decode(String(input["base64"])) : Vector{UInt8}(codeunits(String(input["value"])))

function case_limits(case)
    o = get(case, "options", nothing)
    o === nothing && return Limits()
    return Limits(; max_bytes=UInt64(get(o, "max_bytes", 512_000)), max_redirects=UInt32(get(o, "max_redirects", 5)))
end

# Results as canonical JSON values (spec §6).
canon(::Nothing) = nothing
canon(x::Union{Bool,Real,String}) = x
canon(s::Symbol) = String(s)
canon(r::Rule) = Dict("allow" => r.allow, "pattern" => r.pattern, "line" => Int(r.line))
canon(g::Group) = Dict("user_agents" => g.user_agents, "rules" => canon.(g.rules), "crawl_delay" => canon(g.crawl_delay))
canon(f::RobotsFile) = Dict("groups" => canon.(f.groups), "sitemaps" => f.sitemaps, "truncated" => f.truncated)
canon(f::Fetched) = Dict("policy" => String(f.policy), "status" => f.status === nothing ? nothing : Int(f.status),
                         "robots" => canon(f.robots))

# json_equal: objects by key set and values, arrays in order, numbers by value.
json_equal(a::AbstractDict, b::AbstractDict) =
    Set(String.(collect(keys(a)))) == Set(String.(collect(keys(b)))) &&
    all(json_equal(a[k], b[String(k)]) for k in keys(a))
json_equal(a::AbstractVector, b::AbstractVector) = length(a) == length(b) && all(json_equal(x, y) for (x, y) in zip(a, b))
json_equal(a::Number, b::Number) = a == b
json_equal(a::AbstractString, b::AbstractString) = String(a) == String(b)
json_equal(a::Bool, b::Bool) = a == b
json_equal(::Nothing, ::Nothing) = true
json_equal(a, b) = false

# The scripted transport for a fetch case: answers from its `responses` map;
# a URL not listed, or {"error": "network"}, has no response.
function scripted_transport(responses)
    return function (url::String)
        haskey(responses, url) || return nothing
        r = responses[url]
        haskey(r, "error") && return nothing
        location = get(r, "location", nothing)
        body = haskey(r, "body_base64") ? base64decode(String(r["body_base64"])) : UInt8[]
        return Response(Int(r["status"]), location === nothing ? nothing : String(location), body)
    end
end

function call(case)
    op = case["op"]
    input = case["input"]
    limits = case_limits(case)
    if op == "parse"
        return RobotsTxt.parse(input_bytes(input); limits)
    elseif op in ("is_allowed", "matching_rule", "crawl_delay")
        robots = RobotsTxt.parse(input_bytes(input); limits)
        args = input["args"]
        ua = String(args["user_agent"])
        op == "crawl_delay" && return RobotsTxt.crawl_delay(robots, ua)
        path = String(args["path"])
        return op == "is_allowed" ? RobotsTxt.is_allowed(robots, ua, path) : RobotsTxt.matching_rule(robots, ua, path)
    elseif op == "status_policy"
        return RobotsTxt.status_policy(Int(input["value"]))
    elseif op == "fetch"
        v = input["value"]
        return RobotsTxt.fetch(String(v["origin"]); limits, transport=scripted_transport(v["responses"]))
    end
    error("unknown op $op")
end

"""Run one case; return `nothing` on pass, or a reason string on failure."""
function run_case(case)::Union{Nothing,String}
    expect = case["expect"]
    result = try
        call(case)
    catch e
        e isa RobotsError || return "unexpected exception $(sprint(showerror, e))"
        haskey(expect, "error") || return "unexpected error $(e.code) ($(e.kind))"
        want = expect["error"]
        (String(e.kind) == want["kind"] && e.code == want["code"]) ||
            return "expected $(want["kind"])/$(want["code"]), got $(e.kind)/$(e.code)"
        return nothing
    end
    haskey(expect, "value") || return "expected an error, got $(repr(result))"
    want = expect["value"]
    got = canon(result)
    compare = case["compare"]
    ok = if compare == "float_tol"
        want === nothing ? got === nothing : (got isa Real && abs(got - want) <= Float64(case["tolerance"]))
    elseif compare == "exact"
        want === nothing ? got === nothing : (got !== nothing && got == want)
    elseif compare == "json_equal"
        json_equal(got, want)
    else
        return "unknown compare mode $compare"
    end
    ok && return nothing
    return "expected $(JSON3.write(want)), got $(JSON3.write(got))"
end

"""Run the manifest; print failures and the summary line; return (passed, total)."""
function run_conformance(path=get(ENV, "ROBOTSTXT_MANIFEST", DEFAULT_MANIFEST))
    manifest = JSON3.read(read(path, String))
    counts = Dict("core" => [0, 0], "io" => [0, 0])
    for case in manifest["cases"]
        level = counts[String(case["level"])]
        level[2] += 1
        why = run_case(case)
        why === nothing ? (level[1] += 1) : println("FAIL $(case["id"]): $why")
    end
    (cp, ct), (ip, it) = counts["core"], counts["io"]
    println("robotstxt julia (spec $(manifest["spec_version"])): core $cp/$ct, io $ip/$it, full $(cp + ip)/$(ct + it)")
    return cp + ip, ct + it
end
