#!/usr/bin/env python3
"""Pacenote 0.16.0 (D3, updates): writes the Sparkle 2 appcast for a release.

    make_appcast.py --version 0.16.1 --build 240 --dmg Pacenote.dmg --url https://github.com/bodco/live-tips/releases/download/v0.16.1/Pacenote.dmg \
                    --signature "<sparkle:edSignature from sign_update>" --notes CHANGELOG.md --out appcast.xml [--keep appcast.xml]

The EdDSA signature comes from Sparkle's `sign_update` run on the build machine with the private key (Keychain or
the file named by an environment variable, never in this repository). The notes are the CHANGELOG section of that
version, as an HTML list. With --keep the earlier items of an existing appcast stay (newest first, at most 10).
Only the standard library; the output is plain RSS 2.0 with the sparkle namespace.
"""
import argparse
import email.utils
import html
import os
import re
import sys

NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def notes_html(changelog: str, version: str) -> str:
    """The CHANGELOG section `## <version> (...)` (or `## Unreleased`) as <ul><li>…</li></ul>."""
    text = open(changelog, encoding="utf-8").read()
    m = re.search(r"^## (?:" + re.escape(version) + r"\b.*|Unreleased)\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        return ""
    items = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if line.startswith(("- ", "* ")):
            items.append(html.escape(re.sub(r"\*\*|`", "", line[2:]).strip()))
    return "<ul>" + "".join(f"<li>{i}</li>" for i in items[:12]) + "</ul>" if items else ""


def item_xml(a) -> str:
    length = os.path.getsize(a.dmg)
    date = email.utils.formatdate(usegmt=True)
    desc = notes_html(a.notes, a.version) if a.notes else ""
    return (
        "    <item>\n"
        f"      <title>Pacenote {html.escape(a.version)}</title>\n"
        f"      <pubDate>{date}</pubDate>\n"
        f"      <sparkle:version>{html.escape(a.build)}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{html.escape(a.version)}</sparkle:shortVersionString>\n"
        "      <sparkle:minimumSystemVersion>14.4</sparkle:minimumSystemVersion>\n"
        f"      <sparkle:releaseNotesLink>https://github.com/bodco/live-tips/releases/tag/v{html.escape(a.version)}</sparkle:releaseNotesLink>\n"
        f"      <description><![CDATA[{desc}]]></description>\n"
        f'      <enclosure url="{html.escape(a.url)}" length="{length}" type="application/octet-stream" '
        f'sparkle:edSignature="{html.escape(a.signature)}"/>\n'
        "    </item>\n"
    )


def main() -> int:
    p = argparse.ArgumentParser()
    for k in ("version", "build", "dmg", "url", "signature", "out"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--notes", help="CHANGELOG.md")
    p.add_argument("--keep", help="an existing appcast whose items stay below the new one")
    a = p.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9+/=]{40,}", a.signature):
        print("signature: expected the base64 edSignature from sign_update", file=sys.stderr)
        return 2
    old = []
    if a.keep and os.path.exists(a.keep):
        prev = open(a.keep, encoding="utf-8").read()
        old = [i for i in re.findall(r"    <item>\n.*?    </item>\n", prev, re.S)
               if f"<sparkle:shortVersionString>{a.version}<" not in i]
    items = [item_xml(a)] + old[:9]
    xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<rss version="2.0" xmlns:sparkle="{NS}">\n'
        "  <channel>\n"
        "    <title>Pacenote</title>\n"
        "    <link>https://pacenote.bodco.pm/appcast.xml</link>\n"
        "    <description>Pacenote updates</description>\n"
        "    <language>en</language>\n"
        + "".join(items)
        + "  </channel>\n</rss>\n"
    )
    open(a.out, "w", encoding="utf-8").write(xml)
    print(f"appcast: {a.out} ({len(items)} items, newest {a.version}/{a.build})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
