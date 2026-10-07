# Canonical example `explain_decision`: print the rule that decides a path,
# with its line number, or that no rule applies.
using RobotsTxt

const SAMPLE = """
User-agent: *
Disallow: /private/
Allow: /private/press-kit
Disallow: /*.pdf\$
"""

robots = RobotsTxt.parse(SAMPLE)
for path in ("/private/page", "/private/press-kit/logo.png", "/docs/guide.pdf", "/about")
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
end
