"""context.build: the recent-calls digest from `lt digest` is appended, and its absence or failure is silent."""
import sys
import textwrap
from pathlib import Path

from livetips_m0 import context

FAKE_LT = textwrap.dedent('''
    import json, sys
    args = sys.argv[1:]
    mode = open(sys.argv[0] + ".mode").read().strip()
    if args and args[0] == "digest":
        if mode == "fail":
            print("ERROR: boom"); sys.exit(1)
        if mode == "empty":
            print("RECENT CALLS of p, last 7 days, newest first: 0 calls"); print("(no calls in the window)"); sys.exit(0)
        assert args[2:6] == ["--days", "7", "--max-chars", "3000"], args
        print("RECENT CALLS of p, last 7 days, newest first: 1 calls")
        print("## 2026-01-02 10:00 weekly sync (2026-01-02-1000-weekly-sync)")
        print("- Q [10:05:00] Alex: Can you send the plan by Friday?")
        print("  PM answered: Yes, I will send it on Friday morning.")
        sys.exit(0)
    if args and args[0] == "search":
        print(json.dumps({"hits": [{"rel": "notes/a.md", "preview": "plan draft"}]})); sys.exit(0)
    sys.exit(2)
''')


def make(tmp_path: Path, mode: str):
    root = tmp_path / "proj"
    (root / "_notion").mkdir(parents=True)
    (root / "_notion" / "current-state.md").write_text("Release planned for Monday.", encoding="utf-8")
    lt = tmp_path / "fake_lt.py"
    lt.write_text(FAKE_LT, encoding="utf-8")
    (tmp_path / "fake_lt.py.mode").write_text(mode, encoding="utf-8")
    return root, [sys.executable, str(lt)]


def test_digest_appended(tmp_path):
    root, lt = make(tmp_path, "ok")
    out = context.build("weekly sync about the plan", str(root), lt)
    assert "PROJECT CURRENT STATE" in out
    assert "LOCAL MATERIALS FOUND" in out
    assert "RECENT CALLS (digest" in out
    assert "Can you send the plan by Friday?" in out
    assert out.index("PROJECT CURRENT STATE") < out.index("RECENT CALLS (digest")


def test_digest_without_typed_context(tmp_path):
    root, lt = make(tmp_path, "ok")
    out = context.build("", str(root), lt)
    assert "RECENT CALLS (digest" in out
    assert "LOCAL MATERIALS FOUND" not in out


def test_digest_failure_is_silent(tmp_path):
    root, lt = make(tmp_path, "fail")
    out = context.build("plan", str(root), lt)
    assert "RECENT CALLS" not in out
    assert "PROJECT CURRENT STATE" in out


def test_digest_empty_window_is_silent(tmp_path):
    root, lt = make(tmp_path, "empty")
    assert "RECENT CALLS" not in context.build("plan", str(root), lt)


def test_no_lt_and_no_root(tmp_path):
    root, _ = make(tmp_path, "ok")
    assert "RECENT CALLS" not in context.build("plan", str(root), None)
    assert "RECENT CALLS" not in context.build("plan", None, None)
    assert context.recent_calls([str(tmp_path / "missing-binary")], root) == ""
