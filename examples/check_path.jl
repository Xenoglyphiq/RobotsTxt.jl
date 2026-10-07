# Canonical example `check_path`: parse a sample robots.txt and print whether
# NowhereToBeBot may fetch /private/page.
using RobotsTxt

const SAMPLE = """
User-agent: *
Disallow: /private/
Allow: /private/press-kit

User-agent: NowhereToBeBot
Disallow: /private/
Crawl-delay: 5

Sitemap: https://example.com/sitemap.xml
Sitemap: https://example.com/news/sitemap.xml
"""

robots = RobotsTxt.parse(SAMPLE)
allowed = RobotsTxt.is_allowed(robots, "NowhereToBeBot", "/private/page")
println("NowhereToBeBot ", allowed ? "may" : "may not", " fetch /private/page")
