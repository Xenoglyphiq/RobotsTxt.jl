# Mutation fuzzer for `parse` and matching (no dependencies beyond the test env).
# Runs from runtests.jl only when FUZZ_SECONDS is set:
#   FUZZ_SECONDS=600 julia --project -e 'using Pkg; Pkg.test()'
# FUZZ_SEED fixes the seed; otherwise it's time-based and printed.
#
# Corpus: every robots.txt input in the manifest (including fetch bodies)
# plus random byte strings. Each iteration applies 1–4 mutations and checks:
#   - `parse` never throws, with the default limit or a random small one;
#     every reported string is valid UTF-8 and rule lines are in range;
#   - only RobotsError escapes `is_allowed`, `matching_rule` and
#     `crawl_delay`, and it always has a code;
#   - is_allowed == (matching_rule === nothing || rule.allow).

using Random
using JSON3
using RobotsTxt: RobotsTxt, RobotsError, Limits

const FUZZ_TOKENS = [b"User-agent: ", b"Allow: ", b"Disallow: ", b"Crawl-delay: ", b"Sitemap: ",
                     b"user-agent ", b"*", b"$", b"%", b"%2F", b"%7e", b"#", b":", b"\r\n", b"\n", b"\r",
                     b"\t", b" ", b"/", b"?", b"\xef\xbb\xbf", b"\xe3\x83\x84", b"FooBot", b"*bot"]

function fuzz_corpus(rng)
    manifest = JSON3.read(read(DEFAULT_MANIFEST, String))
    corpus = Vector{UInt8}[]
    for c in manifest["cases"]
        if c["op"] in ("parse", "is_allowed", "matching_rule", "crawl_delay")
            push!(corpus, input_bytes(c["input"]))
        elseif c["op"] == "fetch"
            for (_, r) in c["input"]["value"]["responses"]
                haskey(r, "body_base64") && push!(corpus, base64decode(String(r["body_base64"])))
            end
        end
    end
    for _ in 1:8
        push!(corpus, rand(rng, UInt8, rand(rng, 0:80)))
    end
    return unique(corpus)
end

function mutate!(rng, s::Vector{UInt8})
    for _ in 1:rand(rng, 1:4)
        op = rand(rng, 1:7)
        if op == 1 && !isempty(s)                      # flip a byte
            i = rand(rng, eachindex(s)); s[i] ⊻= rand(rng, UInt8(1):UInt8(255))
        elseif op == 2                                  # insert a byte
            b = rand(rng) < 0.5 ? rand(rng, UInt8(0x20):UInt8(0x7e)) : rand(rng, UInt8)
            insert!(s, rand(rng, 1:length(s)+1), b)
        elseif op == 3 && !isempty(s)                   # delete a byte
            deleteat!(s, rand(rng, eachindex(s)))
        elseif op == 4 && !isempty(s)                   # duplicate a slice
            a = rand(rng, eachindex(s)); b = rand(rng, a:min(lastindex(s), a + 32))
            append!(s, s[a:b])
        elseif op == 5 && !isempty(s)                   # truncate
            resize!(s, rand(rng, 0:length(s)-1))
        elseif op == 6                                  # insert a robots.txt token
            t = rand(rng, FUZZ_TOKENS)
            i = rand(rng, 1:length(s)+1)
            for (k, b) in enumerate(t)
                insert!(s, i + k - 1, b)
            end
        else                                            # long run of continuation bytes or '*'
            append!(s, fill(rand(rng, (0x80, 0xBF, UInt8('*'), UInt8('a'))), rand(rng, 1:64)))
        end
        length(s) > 4096 && resize!(s, 4096)
    end
    return s
end

# A crawler name: usually valid, sometimes taken from the file or mangled.
function fuzz_agent(rng, robots)
    r = rand(rng)
    if r < 0.4 && !isempty(robots.groups)
        ua = rand(rng, rand(rng, robots.groups).user_agents)
        r < 0.3 && (ua = String(collect(Iterators.takewhile(c -> isascii(c) && (isletter(c) || c in "_-"), ua))))
        return ua
    elseif r < 0.9
        return rand(rng, ["FooBot", "foobot", "BarBot", "a", "*", "Foo-Bar_Baz"])
    end
    return String(rand(rng, UInt8, rand(rng, 0:6)))
end

# A path: usually built from one of the file's patterns, sometimes mangled.
function fuzz_path(rng, robots)
    rules = [r for g in robots.groups for r in g.rules]
    p = if !isempty(rules) && rand(rng) < 0.7
        s = Vector{UInt8}(rand(rng, rules).pattern)
        # Expand '*' into a random run; sometimes drop a final '$'.
        out = UInt8[]
        for b in s
            b == UInt8('*') ? append!(out, rand(rng, UInt8('a'):UInt8('z'), rand(rng, 0:5))) : push!(out, b)
        end
        !isempty(out) && out[end] == UInt8('$') && rand(rng) < 0.5 && pop!(out)
        out
    else
        Vector{UInt8}("/" * randstring(rng, rand(rng, 0:12)))
    end
    rand(rng) < 0.3 && mutate!(rng, p)
    return String(p)
end

function check_strings(robots)
    for g in robots.groups
        all(isvalid, g.user_agents) || error("invalid UTF-8 in user_agents")
        for r in g.rules
            isvalid(r.pattern) || error("invalid UTF-8 in a pattern")
            r.line >= 1 || error("rule line < 1")
        end
        g.crawl_delay === nothing || g.crawl_delay >= 0 || error("negative crawl_delay")
    end
    all(isvalid, robots.sitemaps) || error("invalid UTF-8 in sitemaps")
end

function fuzz(seconds::Float64, seed::UInt64)
    rng = Xoshiro(seed)
    corpus = fuzz_corpus(rng)
    println("fuzz: seed $seed, $(seconds) s, corpus $(length(corpus))")
    deadline = time() + seconds
    iterations = 0
    while time() < deadline
        input = mutate!(rng, copy(rand(rng, corpus)))
        iterations += 1
        robots = try
            limits = rand(rng) < 0.2 ? Limits(max_bytes=rand(rng, 0:length(input)+2)) : Limits()
            r = RobotsTxt.parse(input; limits)
            check_strings(r)
            r
        catch e
            println("FUZZ FAILURE (parse) on ", repr(String(copy(input)))); rethrow()
        end
        for _ in 1:4
            ua, path = fuzz_agent(rng, robots), fuzz_path(rng, robots)
            rule, allowed, delay = try
                (RobotsTxt.matching_rule(robots, ua, path), RobotsTxt.is_allowed(robots, ua, path),
                 RobotsTxt.crawl_delay(robots, ua))
            catch e
                if !(e isa RobotsError) || isempty(e.code)
                    println("FUZZ FAILURE (match) on ", repr(String(copy(input))), " ua ", repr(ua), " path ", repr(path))
                    rethrow()
                end
                continue
            end
            if allowed != (rule === nothing || rule.allow)
                println("FUZZ FAILURE (is_allowed != matching_rule) on ", repr(String(copy(input))),
                        " ua ", repr(ua), " path ", repr(path))
                error("is_allowed disagrees with matching_rule")
            end
        end
    end
    println("fuzz: $iterations iterations in $(round(seconds; digits=1)) s, clean")
    return iterations
end
