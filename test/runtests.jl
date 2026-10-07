using Test
using Sockets
using RobotsTxt
using RobotsTxt: is_allowed, matching_rule, crawl_delay, status_policy, normalize, pattern_matches

include("conformance.jl")

const SAMPLE = """
User-agent: *
Disallow: /private/
Allow: /private/public-page
Crawl-delay: 2

User-agent: NowhereToBeBot
Disallow: /private
Disallow: /*.pdf\$

Sitemap: https://example.com/sitemap.xml
"""

err(f) = try f(); nothing catch e; e end
code(f) = (e = err(f); e isa RobotsError ? e.code : e)

# A tiny HTTP/1.1 server on 127.0.0.1 for the default transport. `handler`
# gets the request lines and returns the raw response bytes.
function serve(handler)
    port, server = listenany(ip"127.0.0.1", 20000)
    @async while isopen(server)
        sock = try accept(server) catch; break end
        @async try
            request = String[]
            while (line = readline(sock)) != ""
                push!(request, line)
            end
            write(sock, handler(request))
        catch
        finally
            close(sock)
        end
    end
    return Int(port), server
end

http(status, headers, body) =
    "HTTP/1.1 $status X\r\n" * join("$k: $v\r\n" for (k, v) in headers) *
    "Content-Length: $(sizeof(body))\r\nConnection: close\r\n\r\n" * body

@testset "RobotsTxt" begin
    @testset "sample file" begin
        r = RobotsTxt.parse(SAMPLE)
        @test length(r.groups) == 2
        @test r.sitemaps == ["https://example.com/sitemap.xml"]
        @test !r.truncated
        @test !is_allowed(r, "NowhereToBeBot", "/private/page")
        @test is_allowed(r, "OtherBot", "/private/public-page")
        @test !is_allowed(r, "OtherBot", "/private/x")
        @test matching_rule(r, "nowheretobebot", "/a/b.pdf") == Rule(false, "/*.pdf\$", 8)
        @test crawl_delay(r, "OtherBot") == 2.0
        @test crawl_delay(r, "NowhereToBeBot") === nothing
    end

    @testset "type stability" begin
        r = RobotsTxt.parse(SAMPLE)
        @inferred RobotsTxt.parse(SAMPLE)
        @inferred RobotsTxt.parse(Vector{UInt8}(SAMPLE))
        @inferred is_allowed(r, "FooBot", "/x")
        @inferred Union{Nothing,Rule} matching_rule(r, "FooBot", "/x")
        @inferred Union{Nothing,Float64} crawl_delay(r, "FooBot")
        @inferred status_policy(200)
    end

    @testset "parse accepts strings, bytes and views" begin
        bytes = Vector{UInt8}(SAMPLE)
        r = RobotsTxt.parse(bytes)
        @test RobotsTxt.parse(SAMPLE) == r
        @test RobotsTxt.parse(SubString(SAMPLE, 1)) == r
        @test RobotsTxt.parse(view(bytes, 1:length(bytes))) == r
        @test RobotsTxt.parse(UInt8[]) == RobotsFile(Group[], String[], false)
    end

    @testset "byte order marks" begin
        body = Vector{UInt8}("User-agent: a\nDisallow: /x\n")
        for bom in ([0xEF, 0xBB, 0xBF], [0xEF, 0xBB], [0xEF])
            @test RobotsTxt.parse([bom; body]) == RobotsTxt.parse(body)
        end
        @test RobotsTxt.parse([0xEF, 0xBB, 0xBF]).groups == Group[]
        @test isempty(RobotsTxt.parse([0xBB, 0xBF, body...]).groups)          # no EF: not a BOM
        @test RobotsTxt.parse([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, body...]).groups == Group[]  # only one is skipped
    end

    @testset "lines" begin
        r = RobotsTxt.parse("User-agent: a\r\n\rDisallow: /x\n\r\nAllow: /y")
        @test [(x.pattern, Int(x.line)) for x in r.groups[1].rules] == [("/x", 3), ("/y", 5)]
        # Missing colon: exactly two words, separated by spaces or tabs (D-006).
        r = RobotsTxt.parse("user-agent\ta\ndisallow  /x\ndisallow /y z\ndisallow\n")
        @test r.groups[1].user_agents == ["a"]
        @test [x.pattern for x in r.groups[1].rules] == ["/x"]
        # Comments, trimming, empty keys, values with colons.
        r = RobotsTxt.parse("# c\n \tUser-agent : a # c\n: /k\nDisallow:/a#b\nSitemap: https://x/s.xml#f\nAllow: /p:q\n")
        @test r.groups[1].user_agents == ["a"]
        @test [x.pattern for x in r.groups[1].rules] == ["/a", "/p:q"]
        @test r.sitemaps == ["https://x/s.xml"]
        # Empty values add nothing but still close the agent list.
        r = RobotsTxt.parse("User-agent: a\nDisallow:\nUser-agent: b\nSitemap:\n")
        @test [g.user_agents for g in r.groups] == [["a"], ["b"]]
        @test isempty(r.sitemaps)
        # Rules and crawl-delay before any user-agent are ignored.
        @test isempty(RobotsTxt.parse("Disallow: /\nCrawl-delay: 3\n").groups)
    end

    @testset "truncation boundary (D-005)" begin
        text = "User-agent: *\nDisallow: /a\r\nDisallow: /b\n"   # 14 + 14 + 13 = 41 bytes
        lines(n) = [Int(x.line) for x in RobotsTxt.parse(text; limits=Limits(max_bytes=n)).groups[1].rules]
        @test !RobotsTxt.parse(text; limits=Limits(max_bytes=41)).truncated
        @test RobotsTxt.parse(text; limits=Limits(max_bytes=40)).truncated
        @test lines(41) == [2, 3]
        @test lines(40) == [2]          # cut just before the final '\n': the line is dropped
        @test lines(28) == [2]          # just after "\r\n"
        @test lines(27) == [2]          # between '\r' and '\n': the '\r' ends the line
        @test lines(26) == Int[]        # inside line 2
        r = RobotsTxt.parse(text; limits=Limits(max_bytes=13))  # cut before the first '\n'
        @test r == RobotsFile(Group[], String[], true)
        @test RobotsTxt.parse(text; limits=Limits(max_bytes=0)) == RobotsFile(Group[], String[], true)
        @test RobotsTxt.parse("abc"; limits=Limits(max_bytes=2)) == RobotsFile(Group[], String[], true)
        # The limit counts the BOM's bytes.
        @test RobotsTxt.parse([0xEF, 0xBB, 0xBF, 0x0A]; limits=Limits(max_bytes=2)).truncated
    end

    @testset "reported text replaces invalid UTF-8" begin
        @test RobotsTxt.text(UInt8[0x61, 0xC0, 0x80, 0xE2, 0x82, 0x62, 0xF0, 0x9F, 0x98, 0x80]) == "a\ufffd\ufffd\ufffdb😀"
        @test RobotsTxt.text(UInt8[0xED, 0xA0, 0x80]) == "\ufffd\ufffd\ufffd"   # surrogate
        @test RobotsTxt.text(UInt8[0xF4, 0x90, 0x80, 0x80]) == "\ufffd"^4         # above U+10FFFF
        @test RobotsTxt.text(UInt8[0xF0, 0x9F, 0x98]) == "\ufffd"                 # truncated sequence
        r = RobotsTxt.parse(UInt8[codeunits("User-agent: b\xffot\nDisallow: /caf\xe9\nSitemap: /\xfe\n")...])
        @test r.groups[1].user_agents == ["b\ufffdot"]
        @test r.groups[1].rules[1].pattern == "/caf\ufffd"
        @test r.sitemaps == ["/\ufffd"]
        @test all(isvalid, [r.groups[1].user_agents; r.sitemaps; r.groups[1].rules[1].pattern])
        # Matching uses the original bytes.
        @test !is_allowed(r, "b", "/caf%E9")
        @test !is_allowed(r, "b", "/caf\xe9")
        @test is_allowed(r, "b", "/caf\ufffd")
    end

    @testset "normalization (D-004)" begin
        n(s) = String(normalize(Vector{UInt8}(s)))
        @test n("/%7euser") == "/~user"
        @test n("/%41%5a%61%7A%30%2D%2e%5F") == "/AZaz0-._"
        @test n("/a%2fb%3F") == "/a%2Fb%3F"
        @test n("/%zz%4") == "/%zz%4"
        @test n("/%%41") == "/%A"
        @test n("/a b\tc") == "/a%20b%09c"
        @test n("/\x00\x1f\x7f") == "/%00%1F%7F"
        @test n("/ツ") == "/%E3%83%84"
        @test n("/?q=a&b=*\$") == "/?q=a&b=*\$"
        @test n("/%E3%83%84") == "/%E3%83%84"
        # Rule length is the normalized pattern's.
        r = RobotsTxt.parse("User-agent: *\nAllow: /%61\nDisallow: /ab\n")
        @test matching_rule(r, "FooBot", "/abc").pattern == "/ab"
    end

    @testset "matcher" begin
        m(p, q) = pattern_matches(normalize(Vector{UInt8}(p)), normalize(Vector{UInt8}(q)))
        @test m("/", "/anything")
        @test m("*", "/x")
        @test m("/*", "/")
        @test m("/a*b*c", "/aXXbYYc/d")
        @test !m("/a*b*c", "/aXXcYYb")
        @test m("/a**b", "/ab")
        @test m("/a\$", "/a") && !m("/a\$", "/ab")
        @test m("/*\$", "/x") && m("/*\$", "/")
        @test m("/a*\$", "/abc")
        @test m("/*.pdf\$", "/x.pdf") && !m("/*.pdf\$", "/x.pdf?y")
        @test m("/*b\$", "/bb") && m("/*ab\$", "/abab") && !m("/a*ab\$", "/ab")
        @test m("/a\$b", "/a\$b") && !m("/a\$b", "/a")     # '$' not last: a literal
        @test !m("\$", "/") && !m("/x\$\$", "/x")
        @test m("/x\$\$", "/x\$")
        @test !m("/abc", "/ab")
        @test !m("/A", "/a")                              # case-sensitive
        # Many '*' against a long path: greedy pieces, no backtracking.
        path = "/" * "a"^20_000
        for (p, want) in (("/" * "*a"^60 * "b", false), ("/" * "*a"^60, true),
                          ("/" * "*a"^60 * "*\$", true), ("/" * "*a"^60 * "b\$", false),
                          ("/" * "a*"^60 * "ab", false))
            t = @elapsed got = m(p, path)
            @test got == want
            @test t < 1.0
        end
        r = RobotsTxt.parse("User-agent: *\nDisallow: /" * "*a"^200 * "b\n")
        @test (@elapsed is_allowed(r, "FooBot", path)) < 1.0
    end

    @testset "decisions" begin
        r = RobotsTxt.parse("User-agent: FooBot\nDisallow: /a\nAllow: /a\nDisallow: /b\nDisallow: /b\n")
        @test matching_rule(r, "FooBot", "/a").allow                      # allow wins a tie
        @test Int(matching_rule(r, "FooBot", "/b").line) == 4             # first of equals
        @test is_allowed(r, "FooBot", "/robots.txt")
        @test matching_rule(RobotsTxt.parse("User-agent: *\nDisallow: /\n"), "a", "/robots.txt?x=1") === nothing
        @test !is_allowed(RobotsTxt.parse("User-agent: *\nDisallow: /\n"), "a", "/robots.txtx")
        @test !is_allowed(RobotsTxt.parse("User-agent: *\nDisallow: /\n"), "a", "/%72obots.txt")
        # Fragments are ignored.
        r = RobotsTxt.parse("User-agent: *\nDisallow: /a\$\n")
        @test !is_allowed(r, "a", "/a#frag")
        @test matching_rule(RobotsTxt.parse("User-agent: *\nDisallow: /\n"), "a", "/robots.txt#x") === nothing
    end

    @testset "group tokens (D-001, D-002)" begin
        r = RobotsTxt.parse("User-agent: FooBot/2.1\nDisallow: /f\n\nUser-agent: *\tx\nDisallow: /g\n\nUser-agent: *bot\nDisallow: /h\n")
        @test !is_allowed(r, "foobot", "/f") && is_allowed(r, "foobot", "/g")
        @test !is_allowed(r, "Other", "/g") && is_allowed(r, "Other", "/h")
        @test is_allowed(r, "FooBo", "/f")
        r = RobotsTxt.parse("User-agent: Foo_Bar-Baz qux\nDisallow: /\n")
        @test !is_allowed(r, "foo_bar-baz", "/x")
    end

    @testset "argument errors, in order" begin
        r = RobotsTxt.parse(SAMPLE)
        @test code(() -> is_allowed(r, "", "x")) == "robotstxt.invalid_user_agent"
        @test code(() -> matching_rule(r, "a b", "/")) == "robotstxt.invalid_user_agent"
        @test code(() -> crawl_delay(r, "a\xff")) == "robotstxt.invalid_user_agent"
        @test code(() -> is_allowed(r, "a", "")) == "robotstxt.invalid_path"
        @test code(() -> is_allowed(r, "a", "x/")) == "robotstxt.invalid_path"
        @test code(() -> is_allowed(r, "a", "#/")) == "robotstxt.invalid_path"
        e = err(() -> is_allowed(r, "a", "x"))
        @test e.kind === :invalid_input
        @test sprint(showerror, e) == "RobotsError(invalid_input): robotstxt.invalid_path"
    end

    @testset "crawl-delay (extension)" begin
        delay(text) = RobotsTxt.parse("User-agent: a\n" * text).groups[1].crawl_delay
        @test delay("Crawl-delay: 1.\nCrawl-delay: .5\nCrawl-delay: 1e3\nCrawl-delay: +1\nCrawl-delay: 0.25\n") == 0.25
        @test delay("Crawl-delay: 0\nCrawl-delay: 4\n") == 0.0
        @test delay("Crawl-delay: " * "9"^400 * "\n") == Inf
        @test delay("Crawl-delay: 0." * "0"^400 * "1\n") == 0.0
        @test delay("Crawl-delay: 1 2\n") === nothing
        r = RobotsTxt.parse("User-agent: a\nDisallow: /\n\nUser-agent: a\nCrawl-delay: 7\n")
        @test crawl_delay(r, "A") == 7.0
    end

    @testset "status policy" begin
        @test status_policy(-1) === :disallow_all
        @test status_policy(typemax(Int)) === :disallow_all
        @test status_policy(UInt32(299)) === :parse
        @test status_policy(399) === :follow_redirect
        @test status_policy(499) === :allow_all
        @test status_policy(429) === :disallow_all
    end

    @testset "fetch with a scripted transport" begin
        body = Vector{UInt8}("User-agent: *\nDisallow: /x\n")
        script(responses) = url -> get(responses, url, nothing)
        ok = Response(200, nothing, body)
        for bad in ("example.com", "http://", "https://", "http:///", "HTTPS://a.com", "https://a.com//",
                    "https://a.com#f", "https://a b.com", "https://a.com/robots.txt", "ws://a.com")
            @test code(() -> RobotsTxt.fetch(bad; transport=_ -> error("not called"))) == "robotstxt.invalid_origin"
        end
        @test RobotsTxt.fetch("http://a.com:8080/"; transport=script(Dict("http://a.com:8080/robots.txt" => ok))).policy === :parsed
        @test RobotsTxt.fetch("https://[::1]"; transport=script(Dict("https://[::1]/robots.txt" => ok))).policy === :parsed
        # Relative, dot-segment and scheme-relative redirects.
        f = RobotsTxt.fetch("https://a.com"; transport=script(Dict(
            "https://a.com/robots.txt" => Response(302, "x/../y/r.txt?v=1#frag", UInt8[]),
            "https://a.com/y/r.txt?v=1" => Response(307, "//b.com/z", UInt8[]),
            "https://b.com/z" => Response(308, "http://c.com/robots.txt", UInt8[]),
            "http://c.com/robots.txt" => ok)))
        @test f == Fetched(:parsed, UInt32(200), RobotsTxt.parse(body))
        # max_redirects is a limit: 0 means the first redirect is "unavailable".
        f = RobotsTxt.fetch("https://a.com"; limits=Limits(max_redirects=0), transport=script(Dict(
            "https://a.com/robots.txt" => Response(301, "/r", UInt8[]), "https://a.com/r" => ok)))
        @test f == Fetched(:allow_all, UInt32(301), nothing)
        @test RobotsTxt.fetch("https://a.com"; transport=script(Dict(
            "https://a.com/robots.txt" => Response(301, "  ", UInt8[])))).policy === :allow_all
        # Any value with status, location and body works; a string body too.
        f = RobotsTxt.fetch("https://a.com"; transport=_ -> (status=200, location=nothing, body="User-agent: *\nDisallow: /\n"))
        @test !is_allowed(f.robots, "a", "/x")
        # A body longer than max_bytes is truncated, whatever the transport sends.
        f = RobotsTxt.fetch("https://a.com"; limits=Limits(max_bytes=14), transport=_ -> Response(200, nothing, body))
        @test f.robots.truncated && f.robots.groups[1].user_agents == ["*"] && isempty(f.robots.groups[1].rules)
        @test RobotsTxt.fetch("https://a.com"; transport=_ -> nothing) == Fetched(:disallow_all, nothing, nothing)
        @test RobotsTxt.fetch("https://a.com"; transport=_ -> Response(-5, nothing, UInt8[])).status === nothing
    end

    @testset "redirect resolution" begin
        base = "https://a.com/d/robots.txt?q"
        @test RobotsTxt.resolve(base, "HTTPS://B.com/x") == "HTTPS://B.com/x"
        @test RobotsTxt.resolve(base, "r") == "https://a.com/d/r"
        @test RobotsTxt.resolve(base, "../../r") == "https://a.com/r"
        @test RobotsTxt.resolve(base, "./") == "https://a.com/d/"
        @test RobotsTxt.resolve(base, "?x") == "https://a.com/d/robots.txt?x"
        @test RobotsTxt.resolve(base, "/a/./b/../c?d/../e") == "https://a.com/a/c?d/../e"
        @test RobotsTxt.resolve("https://a.com", "r") == "https://a.com/r"
        @test RobotsTxt.resolve(base, "/ツ/r") == "https://a.com/ツ/r"
    end

    @testset "default transport (local server)" begin
        seen = String[]
        big = "User-agent: *\n" * "Disallow: /x\n"^100_000          # 1.3 MB
        port, server = serve() do request
            append!(seen, request)
            target = split(request[1])[2]
            target == "/robots.txt" && return http(301, ["Location" => "/moved/robots.txt"], "redirect body")
            target == "/moved/robots.txt" && return http(200, [], "User-agent: *\nDisallow: /private\n")
            target == "/big/robots.txt" && return http(200, [], big)
            return http(404, [], "not found")
        end
        try
            origin = "http://127.0.0.1:$port"
            t = DownloadsTransport(timeout=10.0, user_agent="FooBot")
            r = t("$origin/robots.txt")
            @test r.status == 301                                     # not followed by curl
            @test r.location == "/moved/robots.txt"
            @test any(l -> lowercase(l) == "accept-encoding: identity", seen)
            @test any(l -> lowercase(l) == "user-agent: foobot", seen)
            f = RobotsTxt.fetch(origin; transport=t)
            @test f.policy === :parsed && f.status == 200
            @test !is_allowed(f.robots, "FooBot", "/private")
            @test RobotsTxt.fetch(origin * "/") == f                  # default transport
            r = DownloadsTransport(max_body=1000)("$origin/big/robots.txt")
            @test r.status == 200 && length(r.body) == 1000
            r = DownloadsTransport()("$origin/big/robots.txt")
            @test length(r.body) == 512_001
            @test DownloadsTransport()("$origin/nope").status == 404
            @test DownloadsTransport()("file:///etc/hosts") === nothing
        finally
            close(server)
        end
        # Nothing listening: no response.
        @test DownloadsTransport(timeout=5.0)("http://127.0.0.1:$port/robots.txt") === nothing
        @test RobotsTxt.fetch("http://127.0.0.1:$port"; transport=DownloadsTransport(timeout=5.0)) ==
              Fetched(:disallow_all, nothing, nothing)
    end

    @testset "conformance" begin
        passed, total = run_conformance()
        @test total > 0
        @test passed == total
    end

    if haskey(ENV, "FUZZ_SECONDS")
        include("fuzz.jl")
        @testset "fuzz" begin
            seed = haskey(ENV, "FUZZ_SEED") ? parse(UInt64, ENV["FUZZ_SEED"]) : UInt64(time_ns())
            @test fuzz(parse(Float64, ENV["FUZZ_SECONDS"]), seed) > 0
        end
    end
end
