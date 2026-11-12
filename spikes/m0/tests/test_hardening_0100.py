"""0.10.0 (Meeting Sheet, hardening): what could hurt a real call. H1 lookup latency (background folder index, a hard
time budget, the call's own and generated files left out), H5 notes before the sheet check, H6 timeouts and visible
truncation, H8 questions in the agenda strip when a preset has no agenda block, readiness rules about a hidden block.
Invented names only (Emily Parker, Mike Carter, Lumenfield, Northwind Studio, Orbit)."""
import json
import time
from pathlib import Path

import pytest


def _folder(tmp_path):
    (tmp_path / "_notion").mkdir()
    (tmp_path / "_notion" / "current-state.md").write_text("# Budget\n\n81 of 120 pilot hours used, 39 hours left.\n")
    (tmp_path / "live").mkdir()
    (tmp_path / "live" / "2026-11-12-1000-orbit.app.md").write_text("[10:00:01] Me: pilot hours left, the current call itself\n")
    (tmp_path / "live" / "2026-11-12-1000-orbit.brief.md").write_text("# Brief\n\npilot hours left 12 (generated)\n")
    (tmp_path / "live" / "2026-11-05-1000-orbit.brief.md").write_text("# Brief\n\npilot hours left 50 (older generated brief)\n")
    (tmp_path / "live" / "2026-11-05-1000-orbit.sheet.v2.json").write_text('{"x": "pilot hours left 60"}')
    (tmp_path / "live" / "2026-11-05-1000-orbit.app.md").write_text("[10:00:01] Mike Carter: pilot hours, we have 45 left last week\n")
    return tmp_path


def test_h1_index_answers_fast_and_skips_the_call_and_generated_files(tmp_path):
    from livetips_m0.sheet import lookup
    root = _folder(tmp_path)
    for i in range(300):                                  # a bigger folder: the index, not the walk, answers
        (root / f"note-{i:03d}.md").write_text(f"# Note {i}\n\nRandom planning text about sprint {i} and retro items.\n")
    idx = lookup.FolderIndex([root], exclude_prefix="2026-11-12-1000-orbit.").build()
    assert idx.ready.is_set() and idx.files >= 300
    t = time.time()
    hits = lookup.snippets("How many pilot hours are left?", roots=[root], k=4, max_seconds=1.0, index=idx)
    assert time.time() - t < 1.0
    assert hits[0]["src"] == "_notion/current-state.md"
    texts = " ".join(h["text"] for h in hits)
    assert "current call itself" not in texts and "generated" not in texts and "60" not in texts
    assert "45 left last week" in texts                    # an earlier call's transcript is still a source
    assert not any("_t" in h or "_m" in h for h in hits)


def test_h1_index_keeps_newest_files_when_capped(tmp_path):
    from livetips_m0.sheet import lookup
    import os
    old = tmp_path / "old.md"
    old.write_text("# Old\n\nrelease date November 17\n")
    os.utime(old, (time.time() - 86400 * 30, time.time() - 86400 * 30))
    new = tmp_path / "new.md"
    new.write_text("# New\n\nrelease date November 19\n")
    idx = lookup.FolderIndex([tmp_path], max_files=1).build()
    assert idx.files == 1 and all(d["path"].endswith("new.md") for d in idx.docs)


def test_h1_rank_stops_at_the_deadline():
    from livetips_m0.sheet import lookup
    docs = [{"src": f"f{i}.md", "path": f"/x/f{i}.md", "date": "", "head": "", "text": "pilot hours budget " * 40}
            for i in range(30000)]
    t = time.time()
    lookup.rank("pilot hours", docs, k=5, deadline=time.time() + 0.3)
    assert time.time() - t < 1.2


def test_h1_collect_caps_passages(tmp_path):
    from livetips_m0.sheet import lookup
    (tmp_path / "big.md").write_text("\n\n".join("# H{}\n\npilot hours line {}".format(i, i) for i in range(3000)))
    assert len(lookup.collect("pilot", roots=[tmp_path], max_docs=500)) <= 600


def test_h1_engine_call_prefix_and_index_reuse(tmp_path):
    from livetips_m0.engine import Engine
    e = Engine.__new__(Engine)
    import threading
    e._fidx_lock = threading.Lock()
    e.cfg = {"call_file": str(tmp_path / "live" / "2026-11-12-1000-orbit.app.md")}
    assert e._call_prefix() == "2026-11-12-1000-orbit."
    root = _folder(tmp_path)
    a = e._folder_index([str(root)])
    a.ready.wait(5)
    assert e._folder_index([str(root)]) is a           # built once per call
    e.cfg["lookup_index"] = False
    assert e._folder_index([str(root)]) is None


# ---------------------------------------------------------------- H5: notes first, the sheet check after

def test_h5_notes_are_written_before_the_sheet_check(tmp_path, monkeypatch):
    from livetips_m0 import callnotes as CN
    out = tmp_path / "2026-11-12-1000-orbit.notes.md"
    seen = {}

    def slow_check(md, notes, text, lang, ask):
        seen["file_at_check"] = out.read_text(encoding="utf-8") if out.exists() else None
        return notes + "\n## Sheet check\n- Budget question: answered\n"
    monkeypatch.setattr(CN, "_sheet_check", slow_check)
    CN._write_then_check(out, tmp_path / "2026-11-12-1000-orbit.app.md", "# Notes\n\nMike Carter owns the release.\n", "", "en", None)
    assert seen["file_at_check"] == "# Notes\n\nMike Carter owns the release.\n"
    assert out.read_text(encoding="utf-8").endswith("- Budget question: answered\n")
    assert not (tmp_path / (out.name + ".tmp")).exists()


def test_h5_failed_check_keeps_the_notes(tmp_path, monkeypatch):
    from livetips_m0 import callnotes as CN
    out = tmp_path / "x.notes.md"
    monkeypatch.setattr(CN, "_sheet_check", lambda md, notes, text, lang, ask: notes)
    CN._write_then_check(out, tmp_path / "x.app.md", "# Notes\n", "", "en", None)
    assert out.read_text(encoding="utf-8") == "# Notes\n"


# ---------------------------------------------------------------- H6: timeouts, no silent truncation

class _Slow:
    def __init__(self, data, pause=0.0):
        self.data, self.pause = data, pause

    def read(self, n):
        time.sleep(self.pause)
        piece, self.data = self.data[:n], self.data[n:]
        return piece


def test_h6_read_capped_marks_a_cut_and_stops_a_slow_page():
    from livetips_m0.sheet import web as W
    raw, cut = W.read_capped(_Slow(b"a" * 1000), 400, 5)
    assert raw == b"a" * 400 and cut is True
    raw, cut = W.read_capped(_Slow(b"a" * 300), 400, 5)
    assert len(raw) == 300 and cut is False
    with pytest.raises(W.FetchError):
        W.read_capped(_Slow(b"a" * 10_000_000, pause=0.2), 10_000_000, 0.5)


def test_h6_a_cut_web_page_is_reported_truncated(tmp_path):
    from livetips_m0.sheet import web as W
    body = W.Body("<html><head><title>Lumenfield</title></head><body><main><p>" + "Lumenfield builds reporting tools. " * 50
                  + "</p></main></body></html>")
    body.cut = W.MAX_BYTES

    def getter(url):
        return 200, url, "text/html", body
    plan = {"url": "https://lumenfield.example/", "limits": {"respect_robots": False},
            "pages": [{"url": "https://lumenfield.example/", "planned": True, "depth": 0}]}
    res = W.fetch(plan, out_dir=tmp_path, delay=0, getter=getter, sleep=lambda s: None)
    src = res["sources"][0]
    assert src["used"] == "truncated" and src["cut"]["read_bytes"] == W.MAX_BYTES and "only the first" in src["reason"]


def test_h6_robots_txt_has_a_timeout(monkeypatch):
    from livetips_m0.sheet import build as B
    import urllib.request
    calls = {}

    def fake_urlopen(rq, timeout=None):
        calls["timeout"] = timeout
        raise TimeoutError("silent host")
    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    t = time.time()
    assert B.robots_allowed("https://lumenfield.example/about") is True
    assert calls["timeout"] and calls["timeout"] <= 10 and time.time() - t < 2


def test_h6_fetch_page_reports_a_cut(monkeypatch):
    from livetips_m0.sheet import build as B
    import io
    import urllib.request

    class R(io.BytesIO):
        headers = {"Content-Type": "text/html"}

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False
    monkeypatch.setattr(B.SRC, "web_allowed", lambda url: True)
    monkeypatch.setattr(B, "PAGE_MAX_BYTES", 1000)
    monkeypatch.setattr(urllib.request, "urlopen", lambda rq, timeout=None: R(b"<p>" + b"Northwind " * 500 + b"</p>"))
    text, why, cut = B.fetch_page("https://northwind.example/case")
    assert text and why is None and cut == 1000


def test_h6_silent_claude_is_stopped_with_a_clear_error(tmp_path):
    from livetips_m0.sheet import build as B
    fake = tmp_path / "claude"
    fake.write_text("#!/bin/sh\nsleep 30\n")
    fake.chmod(0o755)
    t = time.time()
    with pytest.raises(RuntimeError) as e:
        B.run_claude({"claude": str(fake), "route": "code", "inactivity_s": 1}, "prompt", {}, [], lambda **kw: None, [])
    assert "stopped answering" in str(e.value) and time.time() - t < 10


# ---------------------------------------------------------------- H8: PM decisions

from test_sheet_fixer_0100 import REC, _quiet, _resp, req_base  # noqa: E402
from test_sheet_pipeline_0100 import ANSWER, _project, _req  # noqa: E402


def test_h8_no_agenda_block_questions_feed_the_agenda_strip(tmp_path):
    import sys
    from livetips_m0.sheet import build as B
    root, a, b = _project(tmp_path)
    blocks = ["header", "overview", "company", "signals", "contact", "qualification", "questions", "best_outcome", "red_lines", "gaps"]
    res = B.build(_req(root, a, b, blocks=blocks), emit=_quiet, responder=_resp(ANSWER))
    base = req_base(res)
    brief = Path(base + ".brief.md").read_text(encoding="utf-8")
    check = brief.split("## 1. Checklist", 1)[1].split("\n## ", 1)[0]
    assert "Who signs off on a workshop?" in check
    assert "## Questions to ask" not in brief                      # once, not twice
    ag = json.loads(Path(base + ".agenda.json").read_text(encoding="utf-8"))
    assert {x["kind"] for x in ag} == {"questions"}
    sys.path.insert(0, str(REC))
    import transcriber as T
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    assert any("signs off" in x for x in T.sheet_agenda(sheet))


def test_h8_readiness_rule_about_a_hidden_block_is_skipped(tmp_path):
    from livetips_m0.sheet import build as B
    root, a, b = _project(tmp_path)
    blocks = ["header", "overview", "company", "signals", "contact", {"type": "qualification", "visible": False}, "agenda",
              "questions", "best_outcome", "red_lines", "gaps"]
    res = B.build(_req(root, a, b, blocks=blocks), emit=_quiet, responder=_resp(ANSWER))
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    q = next(x for x in sheet["blocks"] if x["type"] == "qualification")
    assert q["visible"] is False
    checks = {c["rule"]: c for c in sheet["readiness"]["checks"]}
    assert checks["qualification_complete"].get("skipped") is True and checks["qualification_complete"].get("reason") == "block_hidden"
    assert not any(g.get("block") == q["id"] for g in sheet["readiness"]["gaps"])
    # no auto question about the hidden qualification (the gaps block's own facts are not questions)
    assert not any(f.get("origin") == "readiness" for x in sheet["blocks"] if x["type"] == "questions" for f in x.get("facts") or [])
