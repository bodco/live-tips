#!/usr/bin/env python3
"""Fail if the public live-tips repository contains personal data.

Forbidden: absolute user paths, API keys and tokens, and any word listed in a private deny
list (one term per line). The deny list lives outside the repository; pass it with
--deny FILE or LIVETIPS_DENYLIST. Without it only the generic patterns run.
"""
import argparse
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GENERIC = [
    (r"/Users/(?!you\b|me\b|example\b|Shared\b)[A-Za-z0-9._-]+", "absolute macOS user path"),
    (r"sk-ant-[A-Za-z0-9_-]{8,}", "Anthropic key"),
    (r"ntn_[A-Za-z0-9]{20,}|secret_[A-Za-z0-9]{30,}", "Notion token"),
    (r"(?<![0-9a-f])[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}(?![0-9a-f])", "UUID (Notion or other ID)"),
    (chr(0x2014), "long dash"),
]
SKIP_DIRS = {".git", "__pycache__", ".pytest_cache", "runs", "venv", ".venv", ".metrics", "target"}   # + quality-gate output (ub-mode)
SKIP_FILES = {"LICENSE", ".coverage"}          # the copyright line names the author on purpose
# Made-up IDs in self-tests (all one digit, or 0-9a-f in order) are not real IDs.
FAKE_ID = re.compile(r"^(?:([0-9a-f])\1*|(?:0123456789abcdef)+)$")
TEXT_EXT = {".py", ".md", ".json", ".yaml", ".yml", ".txt", ".sh", ".swift", ".html", ".toml", ".cfg", ""}


def files(root: Path):
    for p in root.rglob("*"):
        if p.is_file() and not (set(p.parts) & SKIP_DIRS) and p.suffix in TEXT_EXT and p.name not in SKIP_FILES:
            yield p


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--deny", default=os.environ.get("LIVETIPS_DENYLIST"))
    ap.add_argument("--root", type=Path, default=ROOT)
    a = ap.parse_args(argv)
    pats = [(re.compile(p), why) for p, why in GENERIC]
    if a.deny and Path(a.deny).exists():
        for term in Path(a.deny).read_text(encoding="utf-8").splitlines():
            term = term.strip()
            if term and not term.startswith("#"):
                pats.append((re.compile(r"(?i)(?<!\w)" + re.escape(term) + r"(?!\w)"), "deny list term"))
    bad = 0
    for f in files(a.root):
        for n, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            for rx, why in pats:
                m = rx.search(line)
                if m and why.startswith("UUID") and all(FAKE_ID.match(x.replace("-", "")[:32]) or len(set(x.replace("-", ""))) <= 1
                                                         for x in rx.findall(line)):
                    continue
                if m:
                    print("{}:{}: {}".format(f.relative_to(a.root), n, why))
                    bad += 1
    print("anonymization: {} finding(s)".format(bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
