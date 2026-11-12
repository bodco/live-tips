"""0.10.0 (Meeting Sheet, fix 2026-11-12, owner): a stand-up preparation came out empty. Every build now reads the
series, the Tracker, the project state and the digest (auto sources, ticked, with a why); stand-up facts are the PM's
own lines, never sentences about the sources; the live "My update" card lists only real lines and falls back to the
Tracker's On me list. Every fixture is invented (Orbit, Mike Carter, Emily Parker)."""
import datetime as dt
import json
from pathlib import Path

import pytest

from livetips_m0.sheet import build as B
from livetips_m0.sheet import prompt as PR
from livetips_m0.sheet import schema as S
from livetips_m0.sheet import sources as SRC
from livetips_m0.sheet import standup as SU
from livetips_m0.sheet import tracker as TR
from test_presentation_rules import T  # noqa: F401  (module fixture: the recorder)

TODAY = dt.date(2026, 11, 12)


def _register(live: Path, items):
    live.mkdir(parents=True, exist_ok=True)
    with (live / "commitments.jsonl").open("a", encoding="utf-8") as f:
        for i, (owner, text, due, created) in enumerate(items):
            f.write(json.dumps({"v": 1, "op": "add", "id": f"c-{live.parent.name}-{i}", "text": text, "owner": owner,
                                "due": due, "created": created, "call": "2026-11-10-1000-orbit-stand-up.app.md",
                                "series": "orbit|orbitstandup"}) + "\n")


def _project(tmp_path: Path) -> Path:
    root = tmp_path / "Orbit"
    live = root / "live"
    _register(live, [("me", "Send Mike Carter the test accounts", "2026-11-10", "2026-11-09T10:00:00+02:00"),
                     ("me", "Review the release notes", "today", "2026-11-12T09:00:00+02:00"),
                     ("me", "Plan the Q1 roadmap", "", "2026-11-05T09:00:00+02:00"),
                     ("Mike Carter", "Share the staging access", "2026-11-11", "2026-11-09T10:00:00+02:00")])
    # a done item never shows
    with (live / "commitments.jsonl").open("a") as f:
        f.write(json.dumps({"v": 1, "op": "add", "id": "c-done", "text": "Old thing", "owner": "me", "created": "2026-11-01"}) + "\n")
        f.write(json.dumps({"v": 1, "op": "done", "id": "c-done", "at": "2026-11-02"}) + "\n")
    (live / "2026-11-10-1000-orbit-stand-up.app.md").write_text("Mike Carter: what did you do?\nMe: finished the export.\n")
    (live / "2026-11-10-1000-orbit-stand-up.app.notes.md").write_text("# Notes\n- Finished the export screen\n")
    (live / "2026-11-11-1000-orbit-stand-up.app.md").write_text("Me: fixing the date filter today.\n")
    (live / "2026-11-12-1000-orbit-stand-up.app.md").write_text("this very call, never its own source\n")
    return root


def _req(root: Path, **kw):
    r = {"route": "fake", "today": TODAY.isoformat(), "preset": "standup", "language": "en", "mode": "quick",
         "blocks": ["header", "standup_since", "standup_today", "standup_blockers", "standup_waiting"],
         "meeting": {"title": "Orbit stand-up", "start": "2026-11-12T10:00:00+02:00"},
         "project": {"slug": "orbit", "root": str(root)}, "live": str(root / "live"),
         "use_project_folder": False, "folders": [],
         "sources": [{"id": "u1", "type": "text", "title": "Series note", "text": "Daily stand-up of the Orbit team."}],
         "base": str(root / "live" / "prep-2026-11-12-1000-orbit-stand-up")}
    r.update(kw)
    return r


META_ANSWER = {"blocks": {
    "standup_since": [{"label": "Export", "text": "Finished the export screen", "source_ids": ["u1"], "status": "found"}],
    "standup_today": [{"text": "The call context mentions an email from Emily Parker; maybe it needs handling, but the content is not given",
                       "source_ids": [], "status": "needs_check"}],
    "standup_blockers": [{"text": "The sources do not say what blocks the work", "status": "not_found"}],
    "standup_waiting": [{"text": "Not specified who to wait on", "status": "not_found"}]}}


def test_tracker_due_dates_and_split():
    assert TR.due_date("today", TODAY) == TODAY
    assert TR.due_date("2026-11-10", TODAY) == dt.date(2026, 11, 10)
    assert TR.due_date("Friday", TODAY) == dt.date(2026, 11, 13)
    assert TR.due_date("14.11", TODAY) == dt.date(2026, 11, 14)
    assert TR.due_date("", TODAY) is None


def test_auto_sources_tracker_and_prev_call_without_project_folder(tmp_path):
    root = _project(tmp_path)
    autos = SRC.auto_sources(_req(root))
    kinds = [a["type"] for a in autos]
    assert "tracker" in kinds and kinds.count("prev_call") == 2
    tr = next(a for a in autos if a["type"] == "tracker")
    assert tr["title"] == "Tracker: 3 on me, 1 waiting on others" and tr["suggested"] and tr["auto"] and tr["why"]
    assert "OVERDUE since 2026-11-10" in tr["text"] and "due TODAY" in tr["text"] and "Old thing" not in tr["text"]
    calls = [a for a in autos if a["type"] == "prev_call"]
    assert calls[0]["path"].endswith("2026-11-11-1000-orbit-stand-up.app.md")         # no notes: the transcript
    assert calls[1]["path"].endswith("2026-11-10-1000-orbit-stand-up.app.notes.md")   # notes first
    assert all("2026-11-12-1000" not in (a.get("path") or "") for a in autos)          # never the call itself
    assert all(a["why"] for a in autos)
    # the wizard's candidates show them ticked too
    c = SRC.candidates(_req(root))["candidates"]
    assert any(x["type"] == "tracker" and x["suggested"] for x in c) and not any("_tracker" in x for x in c)


def test_workspace_call_reads_every_register(tmp_path):
    ws = tmp_path / "Workspace General"
    _register(ws / "live", [("me", "Prepare the workspace report", "today", "2026-11-12")])
    other = tmp_path / "Lumenfield"
    _register(other / "live", [("me", "Call Emily Parker about the invoice", "2026-11-11", "2026-11-10"),
                               ("Emily Parker", "Send the signed order", "", "2026-11-10")])
    added = _project(tmp_path)
    req = _req(ws, live=str(ws / "live"), tracker_folders=[str(other / "live")],
               sources=[{"id": "u1", "type": "folder", "path": str(added), "title": "Orbit"}])
    tr = TR.collect(req, TODAY)
    assert tr["folders"] == 3
    assert len(tr["on_me"]) == 5 and len(tr["waiting"]) == 2
    assert [x["state"] for x in tr["on_me"]][:3] == ["overdue", "overdue", "today"]


def test_build_adds_auto_sources_guards_meta_and_fills_from_tracker(tmp_path):
    root = _project(tmp_path)
    seen = {}

    def responder(system, user):
        seen["prompt"] = system + "\n" + user
        return json.dumps(META_ANSWER)
    res = B.build(_req(root), emit=lambda **k: None, responder=responder)
    assert res.get("done"), res
    sheet = json.loads(Path(res["sheet"]).read_text())
    assert S.validate(sheet) == []
    assert "Stand-up blocks (standup_*)" in seen["prompt"] and "first person" in seen["prompt"]
    by_type = {}
    for s in sheet["sources"]:
        by_type.setdefault(s["type"], []).append(s)
    assert by_type["tracker"][0]["auto"] and by_type["tracker"][0]["why"] and by_type["tracker"][0]["used"] != "skipped"
    assert len(by_type["prev_call"]) == 2
    blocks = {b["type"]: b["facts"] for b in sheet["blocks"]}
    texts = json.dumps(blocks)
    assert "context mentions" not in texts and "maybe" not in texts
    assert [f["text"] for f in blocks["standup_since"]] == ["Finished the export screen"]
    today = [f["text"] for f in blocks["standup_today"]]
    assert today[0].startswith("Send Mike Carter the test accounts") and "overdue" in today[0]
    assert today[1].startswith("Review the release notes")
    assert all(f["status"] == "found" and f["source_ids"] == ["s-tracker"] for f in blocks["standup_today"])
    assert blocks["standup_waiting"][0]["value"]["owner"] == "Mike Carter"
    assert sheet["tracker"]["on_me"][0]["text"] == "Send Mike Carter the test accounts"
    rep = json.loads(Path(_req(root)["base"] + ".sheet.sources.json").read_text())
    assert any("Sources added by Pacenote" in n for n in rep.get("notes") or []) or "Sources added" in json.dumps(rep)


def test_a_tracker_listed_by_the_series_is_replaced_by_todays(tmp_path):
    root = _project(tmp_path)
    req = _req(root, sources=[{"id": "u9", "type": "tracker", "title": "Open commitments (1)", "text": "- stale item"}])
    res = B.build(req, emit=lambda **k: None, responder=lambda s, u: json.dumps(META_ANSWER))
    sheet = json.loads(Path(res["sheet"]).read_text())
    trs = [s for s in sheet["sources"] if s["type"] == "tracker"]
    assert len(trs) == 1 and trs[0]["id"] == "s-tracker"


@pytest.mark.parametrize("text", [
    "The call context mentions an email; maybe it needs handling",
    "У контексті дзвінка згадано імейл від Emily Parker; можливо, його треба опрацювати, але дія не вказана.",
    "У джерелах немає даних про блокери.",
    "The sources do not say what was done"])
def test_meta_sentences_are_caught(text):
    assert SU.is_meta(text)


@pytest.mark.parametrize("text", ["Finished the export screen for Orbit", "Закінчив фільтр дат для Orbit, віддав на тест",
                                  "Today: review the release notes", "Mike Carter: share the staging access"])
def test_real_lines_pass(text):
    assert not SU.is_meta(text)


def test_guard_keeps_not_found_in_the_sheet():
    facts = {"standup_since": [{"text": "Немає даних у джерелах", "status": "needs_check", "source_ids": []}],
             "standup_today": [{"text": "Відправляю Mike Carter тестові акаунти", "status": "found", "source_ids": ["s1"]},
                               {"text": "Нічого", "status": "not_found"}]}
    n = SU.guard(facts, "uk", "2026-11-12T09:00:00+02:00", {"standup_since", "standup_today"})
    assert n == 1
    assert facts["standup_since"][0]["status"] == "not_found"
    assert [f["status"] for f in facts["standup_today"]] == ["found"]


def test_recorder_and_sidecar_share_the_patterns(T):
    assert T.STANDUP_META_PATTERNS == SU.META_PATTERNS


def _standup_sheet(facts, tracker=None):
    s = {"preset": "standup", "language": "en", "sources": [], "blocks": [
        {"id": f"b-{t}", "type": t, "visible": True, "facts": facts.get(t, [])} for t in SU.BLOCKS]}
    if tracker is not None:
        s["tracker"] = tracker
    return s


def test_card_lists_only_real_lines(T, tmp_path):
    su = T.sheet_standup(_standup_sheet({
        "standup_since": [{"text": "Finished the export screen", "status": "found"}],
        "standup_today": [{"text": "The call context mentions an email; maybe it needs handling", "status": "needs_check"},
                          {"text": "Nothing found for today.", "status": "not_found"}],
        "standup_waiting": [{"text": "Mike Carter: staging access", "status": "found", "value": {"owner": "Mike Carter"}}]}),
        tmp_path)
    assert su["since"] == ["Finished the export screen"] and su["today"] == [] and su["on_me"] == []
    assert su["ask"] == [{"who": "Mike Carter", "what": "Mike Carter: staging access"}]


def test_card_falls_back_to_the_tracker_on_me(T, tmp_path):
    empty = {t: [{"text": "Not found", "status": "not_found"}] for t in SU.BLOCKS}
    su = T.sheet_standup(_standup_sheet(empty, {"on_me": [{"text": "Send Mike Carter the test accounts"}]}), tmp_path)
    assert su["on_me"] == ["Send Mike Carter the test accounts"]
    # no tracker in the sheet (an older sheet): this call's own register
    _register(tmp_path, [("me", "Review the release notes", "today", "2026-11-12"), ("Emily Parker", "Sign", "", "2026-11-12")])
    su = T.sheet_standup(_standup_sheet(empty), tmp_path)
    assert su["on_me"] == ["Review the release notes"]


def test_live_card_from_a_meta_only_sheet(T, tmp_path):
    stem = tmp_path / "2026-11-12-1000-orbit-stand-up.app.md"
    tips = tmp_path / "2026-11-12-1000-orbit-stand-up.app.tips.jsonl"
    tips.write_text("")
    sheet = json.loads((Path(__file__).parent / "fixtures" / "sheet" / "standup-orbit.sheet.json").read_text(encoding="utf-8"))
    for b in sheet["blocks"]:
        if b["type"] in SU.BLOCKS:
            b["facts"] = [dict(f, status="not_found") for f in b["facts"]]
        if b["type"] == "standup_today":
            b["facts"] = [{"id": "f-meta", "text": "У контексті згадано імейл; можливо, треба опрацювати", "source_ids": [],
                           "locator": {}, "checked_at": "2026-11-12T09:00:00+02:00", "status": "needs_check", "origin": "model"}]
    sheet["language"] = "uk"
    sheet["tracker"] = {"on_me": [{"text": "Send Mike Carter the test accounts"}]}
    (tmp_path / (stem.stem + ".sheet.json")).write_text(json.dumps(sheet))
    sl = T.SheetLive(stem, tips)
    sl.refresh()
    rows = [json.loads(x) for x in tips.read_text().splitlines() if x.strip()]
    sp = [r for r in rows if r.get("kind") == "speech"]
    assert sp and sp[0]["items"] == ["На мені: Send Mike Carter the test accounts"]
    assert "згадано" not in json.dumps(rows, ensure_ascii=False)


def test_prompt_rule_only_for_standup_blocks():
    lib = {"overview": {"fields": "x"}, "standup_today": {"fields": "y"}}
    assert SU.RULE in PR.block_lines([{"type": "standup_today"}], lib)
    assert SU.RULE not in PR.block_lines([{"type": "overview"}], lib)
