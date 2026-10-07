# robots.txt for Julia

Parse robots.txt files and decide whether a crawler may fetch a path. Implements RFC 9309 · Spec v0.1.2 · Conformance: **core ✓ io ✓ full ✓** (130/130)

> **Crawl-delay** is supported as an extension. It is not part of RFC 9309, and it's kept apart: `crawl_delay` never affects `is_allowed`.

Package name: **`RobotsTxt`**. Julia 1.10 (LTS) or later. No dependencies beyond the standard library (`Downloads`, for `fetch` only).

## Install

> **Not registered yet.** The first release goes to Julia's General registry; until then, add it from the repo:
> `Pkg.add(url="https://github.com/Xenoglyphiq/RobotsTxt.jl")`

Once registered:

```julia
using Pkg
Pkg.add("RobotsTxt")
```

## Quick start

```julia
using RobotsTxt

robots = RobotsTxt.parse("User-agent: *\nDisallow: /private/\n")
RobotsTxt.is_allowed(robots, "NowhereToBeBot", "/private/page")   # false
```

The operations are deliberately not exported, because `parse` and `fetch` would clash with `Base`; call them qualified.

## Examples

Each runs with `julia --project examples/<name>.jl`.

### 1. Check one path (`examples/check_path.jl`)
```julia
robots = RobotsTxt.parse(SAMPLE)
allowed = RobotsTxt.is_allowed(robots, "NowhereToBeBot", "/private/page")
println("NowhereToBeBot ", allowed ? "may" : "may not", " fetch /private/page")
```

### 2. List the sitemaps (`examples/list_sitemaps.jl`)
```julia
robots = RobotsTxt.parse(SAMPLE)
for url in robots.sitemaps
    println(url)
end
```

### 3. Explain a decision (`examples/explain_decision.jl`)
```julia
rule = try
    RobotsTxt.matching_rule(robots, "NowhereToBeBot", path)
catch e
    e isa RobotsError && println(stderr, sprint(showerror, e))
    rethrow()
end
if rule === nothing
    println("$path: allowed, no rule applies")
else
    verdict = rule.allow ? "allowed" : "disallowed"
    println("$path: $verdict by line $(rule.line): $(rule.allow ? "Allow" : "Disallow"): $(rule.pattern)")
end
```

## API

| Function | Spec operation | Returns |
|---|---|---|
| `RobotsTxt.parse(data; limits)` | `parse` (§3.1) | `RobotsFile`. Takes bytes (`AbstractVector{UInt8}`) or a string; never throws |
| `RobotsTxt.is_allowed(robots, user_agent, path)` | `is_allowed` (§3.3) | `Bool` |
| `RobotsTxt.matching_rule(robots, user_agent, path)` | `matching_rule` (§3.3) | `Rule`, or `nothing` when no rule decides |
| `RobotsTxt.crawl_delay(robots, user_agent)` | `crawl_delay` (§3.4), extension | `Float64` seconds, or `nothing` |
| `RobotsTxt.status_policy(http_status)` | `status_policy` (§3.5) | `:parse`, `:follow_redirect`, `:allow_all` or `:disallow_all` |
| `RobotsTxt.fetch(origin; transport, limits)` | `fetch` (§3.6), io | `Fetched`: `policy` (`:parsed`, `:allow_all`, `:disallow_all`), `status`, `robots` |

`user_agent` is the crawler's product token, `[A-Za-z_-]+` (`FooBot`, not `FooBot/2.1`). `path` starts with `/` and includes the query; a fragment is ignored. A crawler obeys only the groups that name it, merged; the `*` groups apply only when none does.

`RobotsFile` has `groups`, `sitemaps` and `truncated`; each `Group` has `user_agents`, `rules` and `crawl_delay`; each `Rule` has `allow`, `pattern` (as written) and `line`. Values that aren't valid UTF-8 are reported with U+FFFD; matching still uses the original bytes.

`fetch` follows redirects itself and treats a failed fetch as a policy, not an error. Its `transport` is any function or callable that takes a URL and returns `nothing` (no response) or a value with `status`, `location` and `body`, such as `Response`:

```julia
fetched = RobotsTxt.fetch("https://example.com")                 # DownloadsTransport()
fetched = RobotsTxt.fetch("https://example.com";
                          transport=DownloadsTransport(timeout=10.0, user_agent="NowhereToBeBot"))
fetched = RobotsTxt.fetch("https://example.com";
                          transport=url -> Response(200, nothing, Vector{UInt8}("User-agent: *\nDisallow: /\n")))
```

The default `DownloadsTransport` uses the standard library's `Downloads` with automatic redirects off, sends `Accept-Encoding: identity`, and stops reading after `max_bytes + 1` body bytes.

## Limits and errors

| Limit | Default | Option name |
|---|---|---|
| Bytes of a robots.txt file read | 512,000 | `Limits(; max_bytes)` |
| Redirects `fetch` follows | 5 | `Limits(; max_redirects)` |

Pass limits as `limits = Limits(max_bytes = 100_000)`. Input past `max_bytes` is ignored and `truncated` is set, never an error; a line cut by the limit is dropped.

Errors are `RobotsError` with a `kind` (always `:invalid_input` here) and a stable `code`: `"robotstxt.invalid_user_agent"`, `"robotstxt.invalid_path"` (checked in that order) or `"robotstxt.invalid_origin"`. `parse` and `status_policy` never throw. Full list: spec §3.

## Modules

| Module | Layer | Needs |
|---|---|---|
| `RobotsTxt` (`src/RobotsTxt.jl`) | core | nothing beyond Base |
| `RobotsTxt.fetch`, `DownloadsTransport` (`src/fetch.jl`) | io | the standard library's `Downloads` |

## Development

| Command | What |
|---|---|
| `julia --project -e 'using Pkg; Pkg.test()'` | Unit tests, type-stability checks and every conformance case |
| `FUZZ_SECONDS=60 julia --project -e 'using Pkg; Pkg.test()'` | Also fuzz `parse` and matching for 60 s (`FUZZ_SEED` to reproduce a run) |
| `julia --project bench/bench.jl [dir]` | Timings on `robots.txt` and `paths.txt` in `dir` (default `.spec/bench`, method in its `README.md`) |

## Performance

| Benchmark | Reference | This port | Ratio |
|---|---|---|---|
| Parse and check 10k paths | Rust `texting_robots` 0.2.2 | not recorded yet | – |

The bench input arrives with spec 0.1.1; numbers will be recorded here before the first release. The spec's target is within 2× of the reference.

## License

MIT OR Apache-2.0. Some conformance cases in `.spec/` are translated from Google's `robotstxt` tests (Apache-2.0); see `.spec/NOTICE`.
