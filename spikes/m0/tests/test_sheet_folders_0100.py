"""0.10.0 (Meeting Sheet, folders): a folder is a source of its own. The preparation reads its files changed in the
last N days (default 7), newest first, within the size budget (the newest 5 when none is that fresh); the whole
folder stays searchable during the call. Every fixture is invented and built here (Emily Parker, Mike Carter,
Lumenfield, Orbit)."""
import datetime as dt
import json
import os
import time
from pathlib import Path

from livetips_m0.sheet import build as B
from livetips_m0.sheet import lookup as LK
from livetips_m0.sheet import schema as S
from livetips_m0.sheet import size as Z
from livetips_m0.sheet import sources as SRC

TODAY = dt.date(2026, 11, 12)


def _touch(p: Path, text: str, days_ago: int) -> Path:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")
    t = time.mktime((TODAY - dt.timedelta(days=days_ago)).timetuple()) + 12 * 3600
    os.utime(p, (t, t))
    return p


def _folder(tmp_path: Path) -> Path:
    f = tmp_path / "Orbit"
    _touch(f / "status.md", "Orbit status: release 2.4 moves to Friday. Emily Parker owns QA.\n", 1)
    _touch(f / "notes" / "sync.md", "Lumenfield sync notes: Mike Carter sends the estimate.\n", 3)
    _touch(f / "plan.md", "Orbit plan for the Lumenfield call.\n", 3)
    _touch(f / "older.md", "Kickoff notes from October.\n", 20)
    _touch(f / "contract-2026-09-13.md", "The penalty clause: 2 percent per week of delay, signed by Orbit.\n", 60)
    # never taken, never searched: archived, hidden, generated call files, logs, binaries, older versions
    _touch(f / "_archived" / "old.md", "archived plan", 1)
    _touch(f / ".hidden.md", "hidden", 1)
    _touch(f / "2026-11-11-1000-sync.app.md", "transcript of a call", 1)
    _touch(f / "run.log", "log line", 1)
    (f / "logo.png").write_bytes(b"\x89PNG....")
    _touch(f / "speech-v1-2026-11-10.md", "speech v1", 2)
    _touch(f / "speech-v2-2026-11-10.md", "speech v2", 2)
    return f


def _req(folder: Path, tmp_path: Path, **kw):
    r = {"route": "fake", "today": TODAY.isoformat(), "meeting": {"title": "Lumenfield sync", "start": "2026-11-13T16:00:00+02:00"},
         "participants": {"theirs": [{"name": "Emily Parker", "company": "Lumenfield"}]},
         "sources": [{"id": "s1", "path": str(folder), "type": "folder", "title": "Orbit"}]}
    r.update(kw)
    return r


def test_schema_and_types_accept_folder():
    assert "folder" in S.SOURCE_TYPES
    errs = []
    v = S._V()
    S._source(v, {"id": "s1", "n": 1, "type": "folder", "title": "Orbit", "access": "ok", "used": "full", "days": 7,
                  "folder": {"days": 7, "recent": 3, "in_window": 3, "searchable": 5, "fallback": False}}, "s")
    S._source(v, {"id": "s1-fabc", "n": 2, "type": "folder_file", "title": "plan.md", "access": "ok", "used": "full",
                  "parent": "s1"}, "s")
    assert v.errors == errs


def test_a_folder_is_ok_never_a_folder_not_a_file(tmp_path):
    f = _folder(tmp_path)
    # an older setup saved the folder as "folder_file" or "file": it becomes a folder source
    for t in ("folder_file", "file", None):
        raw = {"id": "s1", "path": str(f)}
        if t:
            raw["type"] = t
        srcs, texts, _ = SRC.collect(_req(f, tmp_path, sources=[raw]))
        top = srcs[0]
        assert top["type"] == "folder" and top["access"] == "ok"
        assert "a folder, not a file" not in json.dumps(srcs)
    missing = SRC.collect(_req(f, tmp_path, sources=[{"id": "s1", "type": "folder", "path": str(tmp_path / "nope")}]))[0][0]
    assert missing["access"] == "denied" and missing["access_reason"] == "folder not found"


def test_expansion_window_newest_first_filters_and_parent_ids(tmp_path):
    f = _folder(tmp_path)
    srcs, texts, _ = SRC.collect(_req(f, tmp_path))
    folder, kids = srcs[0], srcs[1:]
    names = [k["title"] for k in kids]
    # the last 7 days only, newest first; ties (same day) by the match to the meeting ("Lumenfield", "sync")
    assert names == ["status.md", "speech-v2-2026-11-10.md", "notes/sync.md", "plan.md"]
    assert all(k["type"] == "folder_file" and k["parent"] == "s1" and k["access"] == "ok" and k["id"] in texts for k in kids)
    assert len({k["id"] for k in kids}) == len(kids) and [s["n"] for s in srcs] == list(range(1, len(srcs) + 1))
    for bad in ("older.md", "contract", "_archived", ".hidden", ".app.md", "run.log", "logo.png", "speech-v1"):
        assert not any(bad in k["path"] for k in kids)
    info = folder["folder"]
    assert info["days"] == 7 and info["recent"] == 4 and info["in_window"] == 4 and not info["fallback"]
    assert info["searchable"] == 6            # status, sync, plan, older, contract, speech-v2
    assert folder["reason"] == "4 recent files for the preparation (last 7 days) · 6 searchable during the call"
    assert folder["size_tokens"] == 0 and folder["used"] == "full"
    # the same files again: stable ids
    again = SRC.collect(_req(f, tmp_path))[0]
    assert [s["id"] for s in again] == [s["id"] for s in srcs]


def test_days_from_settings_and_the_folder_override(tmp_path):
    f = _folder(tmp_path)
    wide = SRC.collect(_req(f, tmp_path, options={"folder_days": 30}))[0]
    assert wide[0]["folder"]["recent"] == 5 and any(k["title"] == "older.md" for k in wide[1:])
    own = SRC.collect(_req(f, tmp_path, options={"folder_days": 30},
                           sources=[{"id": "s1", "type": "folder", "path": str(f), "days": 2}]))[0]
    assert own[0]["folder"]["days"] == 2 and [k["title"] for k in own[1:]] == ["status.md"]


def test_no_file_in_the_window_takes_the_newest_five(tmp_path):
    f = tmp_path / "Lumenfield"
    for i in range(8):
        _touch(f / f"note-{i}.md", f"Lumenfield note {i}\n", 30 + i)
    srcs = SRC.collect(_req(f, tmp_path))[0]
    info = srcs[0]["folder"]
    assert info["fallback"] and info["recent"] == 5 and info["in_window"] == 0 and info["searchable"] == 8
    assert [k["title"] for k in srcs[1:]] == [f"note-{i}.md" for i in range(5)]
    assert srcs[0]["reason"].startswith("no file changed in the last 7 days: the newest 5 files")
    assert srcs[0]["access"] == "ok"


def test_the_size_budget_stops_and_counts_only_the_files_taken(tmp_path):
    f = tmp_path / "Orbit"
    for i in range(6):
        _touch(f / f"big-{i}.md", ("Orbit release planning words " * 400) + "\n", 1)
    one = SRC.collect(_req(f, tmp_path))[0]
    per = one[1]["size_tokens"]
    srcs = SRC.collect(_req(f, tmp_path, options={"folder_tokens": per * 2 + 10}))[0]
    info = srcs[0]["folder"]
    assert info["recent"] == 2 and info["over_budget"] == 4 and info["tokens"] == per * 2
    assert srcs[0]["used"] == "truncated" and "4 more did not fit the size budget" in srcs[0]["reason"]
    rep = Z.report(srcs, "fake")
    assert rep["total_tokens"] == per * 2           # the folder itself counts 0, only the files taken
    assert srcs[0]["access"] == "ok" and all(s["access"] == "ok" for s in srcs)


def _sheet_req(f: Path, tmp_path: Path):
    root = tmp_path / "proj"
    (root / "live").mkdir(parents=True, exist_ok=True)
    return _req(f, tmp_path, preset="client_sync", language="en", blocks=["header", "overview", "questions", "gaps"],
                project={"slug": "orbit", "root": str(root)},
                base=str(root / "live" / "prep-2026-11-13-1600-lumenfield-sync"))


ANSWER = {"goal": "Agree on the release", "blocks": {"overview": [
    {"label": "Release", "text": "Release 2.4 moves to Friday", "source_ids": ["s1"], "status": "found"}]}}


def test_build_report_lists_the_folder_with_counts_and_file_rows(tmp_path):
    f = _folder(tmp_path)
    req = _sheet_req(f, tmp_path)
    res = B.build(req, emit=lambda **k: None, responder=lambda s, u: json.dumps(ANSWER))
    assert res.get("done"), res
    sheet = json.loads(Path(res["sheet"]).read_text())
    assert S.validate(sheet) == []
    folder = next(s for s in sheet["sources"] if s["type"] == "folder")
    kids = [s for s in sheet["sources"] if s.get("parent") == folder["id"]]
    assert folder["access"] == "ok" and folder["used"] != "skipped" and len(kids) == 4
    rep = json.loads(Path(req["base"] + ".sheet.sources.json").read_text())
    row = rep["folders"][0]
    assert row["recent"] == 4 and row["searchable"] == 6 and row["days"] == 7 and len(row["files"]) == 4
    assert row["line"].startswith("4 recent files for the preparation (last 7 days)")
    assert any(r.get("parent") == folder["id"] for r in rep["sources"])
    assert sheet["size_report"]["total_tokens"] == sum(k["size_tokens"] for k in kids) + sum(
        s["size_tokens"] for s in sheet["sources"] if s["type"] == "text" and s.get("used") != "skipped")


def test_lookup_finds_an_old_file_of_a_folder_source_that_the_prep_did_not_take(tmp_path):
    f = _folder(tmp_path)
    req = _sheet_req(f, tmp_path)
    res = B.build(req, emit=lambda **k: None, responder=lambda s, u: json.dumps(ANSWER))
    sheet = json.loads(Path(res["sheet"]).read_text())
    prep_paths = {s.get("path") for s in sheet["sources"] if s.get("type") == "folder_file"}
    old = str(f / "contract-2026-09-13.md")
    assert old not in prep_paths                                   # 60 days old: not in the preparation
    assert LK.sheet_folder_roots(sheet) == [str(f)]
    idx = LK.FolderIndex([], deep=LK.sheet_folder_roots(sheet))
    idx.build()
    t0 = time.time()
    hits = LK.snippets("what is the penalty clause per week of delay", sheet=sheet, index=idx, max_seconds=1.0)
    assert time.time() - t0 < 1.5
    assert hits and hits[0]["path"] == old and hits[0]["src"].startswith("Orbit/")
    # never the filtered files, not even during the call
    paths = {d["path"] for d in idx.docs}
    assert not any(x in p for p in paths for x in ("_archived", ".hidden", ".app.md", "run.log", "speech-v1"))
    # without the background index the same answer (collect walks the folder sources too)
    hits2 = LK.snippets("penalty clause per week of delay", sheet=sheet, max_seconds=2.0)
    assert hits2 and hits2[0]["path"] == old


def test_engine_index_takes_the_sheet_folders_deep(tmp_path, monkeypatch):
    from test_engine import _meeting_engine
    f = _folder(tmp_path)
    req = _sheet_req(f, tmp_path)
    res = B.build(req, emit=lambda **k: None, responder=lambda s, u: json.dumps(ANSWER))
    eng, _clock = _meeting_engine(tmp_path, lambda m, u: "{}", ai={"routes": {"prep": "code", "tips": "code"}})
    eng._call_agent = lambda: None
    eng.prompt._brief_path = Path(res["sheet"][: -len(".sheet.json")] + ".brief.md")
    idx = eng._folder_index(eng._search_roots())
    assert idx is not None and idx.deep == [str(f)]
    idx.ready.wait(10)
    hits = LK.snippets("penalty clause per week of delay", sheet=eng._sheet(), index=idx, max_seconds=1.0)
    assert hits and hits[0]["path"].endswith("contract-2026-09-13.md")
    eng.drain(1)
