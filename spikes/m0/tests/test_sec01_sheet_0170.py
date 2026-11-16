"""0.17.0 (SEC-01): the Meeting Sheet build's agent: no Google or hook hosts for WebFetch, an old Claude Code refused."""
import os
import stat

from livetips_m0.sheet import build as B


def _fake(tmp_path, out):
    p = tmp_path / ("claude-%d" % abs(hash(out)))
    p.write_text("#!/bin/sh\necho '%s'\n" % out)
    p.chmod(p.stat().st_mode | stat.S_IEXEC)
    return str(p)


def test_fetch_blocked():
    assert B.fetch_blocked("docs.google.com") and B.fetch_blocked("forms.gle") and B.fetch_blocked("x.webhook.site")
    assert B.fetch_blocked("") and not B.fetch_blocked("northwind.example")


def test_claude_version(tmp_path):
    assert B.claude_too_old(_fake(tmp_path, "2.1.162 (Claude Code)")) == "2.1.162"
    assert B.claude_too_old(_fake(tmp_path, "2.1.163 (Claude Code)")) is None
    assert B.claude_too_old(_fake(tmp_path, "nonsense")) is None
    assert B.claude_too_old(os.path.join(str(tmp_path), "missing")) is None
