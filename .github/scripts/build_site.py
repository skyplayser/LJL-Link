#!/usr/bin/env python3
"""Builds the German pages and the sitemap of the LJL Link website.

    python3 .github/scripts/build_site.py site

Like the LJ Link and VJ-Link sites, the English page is the source and carries the German text in data-de attributes:
- every data-de="…" replaces the element's text (the element must hold plain text only),
- every data-de-<attr>="…" replaces that attribute,
- links to images/, style.css, impressum.html and datenschutz.html get ../,
and the result goes to de/<page>.html without the data-de attributes. The English source stays as it is, so the
script can run locally and in the Pages workflow. It also writes sitemap.xml with both languages.
Standard library only.
"""
import datetime
import re
import sys
from pathlib import Path

BASE = "https://skyplayser.github.io/LJL-Link/"


def to_german(page):
    page = page.replace('<html lang="en">', '<html lang="de">', 1)
    # Text first, so data-de="…" is not mistaken for an attribute value below.
    page = re.sub(r'<(\w+)([^>]*?)\sdata-de="([^"]*)"([^>]*)>[^<]*</\1>',
                  lambda m: "<%s%s%s>%s</%s>" % (m[1], m[2], m[4], m[3], m[1]), page)

    def attrs(m):
        tag = m[0]
        for name, value in re.findall(r'\sdata-de-([\w:-]+)="([^"]*)"', tag):
            tag = re.sub(r'(\s%s=)"[^"]*"' % re.escape(name), lambda a: '%s"%s"' % (a[1], value), tag, count=1)
        return tag
    page = re.sub(r"<[^>]+>", attrs, page)
    page = re.sub(r'((?:src|href)=")(images/|style\.css|impressum\.html|datenschutz\.html)', r"\1../\2", page)
    return strip(page)


def strip(page):
    return re.sub(r'\sdata-de(?:-[\w:-]+)?="[^"]*"', "", page)


def sitemap(site, names):
    today = datetime.date.today().isoformat()
    urls = []
    for name in names:
        path = "" if name == "index.html" else name
        alt = "".join('\n    <xhtml:link rel="alternate" hreflang="%s" href="%s"/>' % (l, BASE + p)
                      for l, p in (("en", path), ("de", "de/" + path), ("x-default", path)))
        for sub in ("", "de/"):
            urls.append("  <url>\n    <loc>%s</loc>\n    <lastmod>%s</lastmod>%s\n  </url>" % (BASE + sub + path, today, alt))
    (site / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
        'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n' + "\n".join(urls) + "\n</urlset>\n", encoding="utf-8")


def main():
    site = Path(sys.argv[1] if len(sys.argv) > 1 else "site")
    pages = [(f.name, f.read_text(encoding="utf-8")) for f in sorted(site.glob("*.html"))]
    pages = [(name, source) for name, source in pages if "data-de" in source]  # the bilingual pages
    (site / "de").mkdir(exist_ok=True)
    for name, source in pages:
        (site / "de" / name).write_text(to_german(source), encoding="utf-8")
    sitemap(site, [name for name, _ in pages])
    print("built de/ for", ", ".join(name for name, _ in pages))


if __name__ == "__main__":
    main()
