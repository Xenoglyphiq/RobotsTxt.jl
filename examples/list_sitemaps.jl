# Canonical example `list_sitemaps`: parse a sample robots.txt and print its
# sitemap URLs in file order.
using RobotsTxt

const SAMPLE = """
Sitemap: https://example.com/sitemap.xml

User-agent: *
Disallow: /private/

Sitemap: https://example.com/news/sitemap.xml
Sitemap: https://example.com/products/sitemap.xml
"""

robots = RobotsTxt.parse(SAMPLE)
for url in robots.sitemaps
    println(url)
end
