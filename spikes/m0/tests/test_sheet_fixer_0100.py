"""0.10.0 (Meeting Sheet, round 2, fixer): newer wins in conflicts, build honors the wizard (visible, only_if_data,
options.blocks, find_again, the Retry/Skip control file), questions only once, Contact pages skipped by the web plan.
Every fixture is invented and built here (Emily Parker, Mike Carter, Jake T., Sarah M., Lumenfield, Orbit)."""
import json
import os
import sys
import threading
import time
from pathlib import Path

import pytest

from livetips_m0.sheet import build as B
from livetips_m0.sheet import derive as D
from livetips_m0.sheet import schema as S

REC = Path(__file__).resolve().parents[3] / "recorder" / "src"


def _f(label, text, sid, **kw):
    return dict({"label": label, "text": text, "source_ids": [sid], "status": "found"}, **kw)


# ---------------------------------------------------------------- F1: newer wins

def test_newer_source_wins_with_link_and_equal_dates_stay_conflict():
    facts = {"company": [_f("Team size", "About 120 employees", "a"), _f("Team size", "About 80 employees", "b")],
             "contact": [_f("Role", "VP Operations", "a"), _f("Role", "COO", "b")]}
    srcs = {"a": {"modified_at": "2026-11-10"}, "b": {"modified_at": "2026-10-01"}}
    # contact: same sources dates differ too, so make contact equal by its own as_of
    facts["contact"][0]["as_of"] = "2026-11-01"
    facts["contact"][1]["as_of"] = "2026-11-01"
    assert B.mark_conflicts(facts, srcs, 6, 2026) == 1
    B.assign_ids(facts)
    new, old = facts["company"]
    assert new["status"] == "found" and old["status"] == "stale"
    assert old["conflict_with"] == [new["id"]] and old["superseded_by"] == new["id"]
    assert [f["status"] for f in facts["contact"]] == ["conflict", "conflict"]


def test_unknown_date_is_a_conflict():
    facts = {"company": [_f("Team size", "120", "a"), _f("Team size", "80", "b")]}
    assert B.mark_conflicts(facts, {"a": {"modified_at": "2026-11-10"}, "b": {}}, 6, 2026) == 1
    assert {f["status"] for f in facts["company"]} == {"conflict"}


def test_decision_changed_newer_note_wins_over_older_values():
    """L6 (s01): the decision register moved production from November 17 to November 19; the config and the plan
    still say November 17. All three sources have the same file date."""
    same = {k: {"modified_at": "2026-11-06"} for k in ("dec", "cfg", "plan")}
    facts = {"project_context": [
        _f("Production release date", "The November 4 08:00 decision-register snapshot moves production to November 19.", "dec"),
        _f("Production release date", "The project config still lists November 17 for production.", "cfg"),
        _f("Production release date", "Pilot plan version 3 lists November 17 for production.", "plan"),
        _f("Budget balance", "As of November 3, 81 of 120 hours were used, 20 hours of support still planned.", "dec"),
        _f("Budget balance", "The older plan records 78 hours used through November 2.", "plan"),
        _f("Payment retries", "The November 4 current state says PR 412 merged.", "dec"),
        _f("Payment retries", "The November 3 status has PR 412 in review.", "plan"),
    ]}
    assert B.mark_conflicts(facts, same, 6, 2026) == 0
    B.assign_ids(facts)
    st = [(f["label"], f["status"]) for f in facts["project_context"]]
    assert st == [("Production release date", "found"), ("Production release date", "stale"),
                  ("Production release date", "stale"), ("Budget balance", "found"), ("Budget balance", "stale"),
                  ("Payment retries", "found"), ("Payment retries", "stale")]
    win = facts["project_context"][0]
    assert all(f["superseded_by"] == win["id"] for f in facts["project_context"][1:3])


def test_old_value_is_out_first_even_when_dated_later():
    """L6 round 2 (s01 on codex): the config's file date is the newest, but it "still lists" the old date; the plan
    lists the old date as of November 3; the November 4 decision moved it. The decision wins, both others are stale."""
    facts = {"project_context": [
        _f("Production release", "The pilot plan lists production release on November 17.", "plan", as_of="2026-11-03"),
        _f("Production release", "The project config still lists production release on November 17.", "cfg", as_of="2026-11-06"),
        _f("Production release", "Emily's November 4 decision moves production release to November 19.", "dec", as_of="2026-11-04")]}
    assert B.mark_conflicts(facts, {}, 6, 2026) == 0
    assert [f["status"] for f in facts["project_context"]] == ["stale", "stale", "found"]


def test_change_loses_to_a_later_dated_value_and_model_as_of_counts():
    facts = {"project_context": [
        _f("Release", "On 2026-11-01 the release moved to November 19.", "a"),
        _f("Release", "Release confirmed for November 21.", "b", as_of="2026-11-05")]}
    B.mark_conflicts(facts, {}, 6, 2026)
    assert [f["status"] for f in facts["project_context"]] == ["stale", "found"]


def test_dates_in_text_parse():
    assert str(B.parse_day("4 листопада", 2026)) == "2026-11-04"
    assert str(B.parse_day("Nov 19, 2026")) == "2026-11-19"
    assert str(B.parse_day("04.11.2026")) == "2026-11-04"
    assert B.fact_as_of({"text": "Станом на 3 листопада використано 81 годину"}, 2026).isoformat() == "2026-11-03"


def test_replaced_value_is_not_a_gap_not_live_and_shows_was(tmp_path):
    sheet = {"language": "en", "title": "Meeting Sheet: Orbit", "blocks": [
        {"id": "b-pc", "type": "project_context", "title": "Project context", "order": 0, "visible": True, "facts": [
            {"id": "f-new", "label": "Release", "text": "Production moved to November 19", "source_ids": ["s1"],
             "status": "found", "origin": "model", "keywords": ["release date"]},
            {"id": "f-old", "label": "Release", "text": "Production on November 17", "source_ids": ["s2"],
             "status": "stale", "origin": "model", "conflict_with": ["f-new"], "superseded_by": "f-new"}]}],
        "sources": [{"id": "s1", "n": 1, "title": "Decisions", "modified_at": "2026-11-04"},
                    {"id": "s2", "n": 2, "title": "Config", "modified_at": "2026-11-04"}]}
    from livetips_m0.sheet import readiness as RR
    assert RR.stale_fact_ids(sheet, "2026-11-12", 6) == []
    assert [g["sheet_fact"] for g in D.facts(sheet)] == ["f-new"]
    md = D.render_md(sheet)
    assert "(was: Production on November 17)" in md and "November 17" not in D.render_md(sheet, for_brief=True)
    gaps = B.gap_facts({"project_context": sheet["blocks"][0]["facts"]}, sheet["blocks"], "2026-11-12")
    assert gaps == []
    sys.path.insert(0, str(REC))
    import transcriber as T
    live = T.sheet_facts(dict(sheet, schema="pacenote.sheet/1"))
    assert [x["sheet_fact"] for x in live] == ["f-new"]


# ---------------------------------------------------------------- F2: build honors the wizard

from test_sheet_pipeline_0100 import ANSWER, _project, _req  # noqa: E402


def _quiet(**kw):
    pass


def _resp(answer, seen=None):
    def r(system, user):
        if seen is not None:
            seen.setdefault("users", []).append(user)
        return json.dumps(answer)
    return r


def test_hidden_block_not_asked_and_only_if_data_block_left_empty(tmp_path):
    root, a, b = _project(tmp_path)
    blocks = [{"type": t} for t in ("header", "overview", "company", "contact", "qualification", "agenda", "questions",
                                    "best_outcome", "gaps")]
    blocks.insert(3, {"type": "signals", "visible": False})
    blocks.append({"type": "red_lines", "only_if_data": True, "title": "Do not promise"})
    ans = json.loads(json.dumps(ANSWER))
    ans["blocks"]["signals"] = [{"label": "Hiring", "text": "Hiring analysts", "source_ids": ["s1"]}]
    ans["blocks"]["red_lines"] = [{"text": "Nothing found", "source_ids": [], "status": "not_found"}]
    seen = {}
    res = B.build(_req(root, a, b, blocks=blocks), emit=_quiet, responder=_resp(ans, seen))
    assert res.get("done"), res
    assert "- signals (" not in seen["users"][0] and "- red_lines (" in seen["users"][0]
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    by = {x["type"]: x for x in sheet["blocks"]}
    assert by["signals"]["visible"] is False and by["signals"]["facts"] == []
    assert by["red_lines"]["only_if_data"] is True and by["red_lines"]["facts"] == []
    assert by["red_lines"]["title"] == "Do not promise"
    assert "## Do not promise" not in Path(req_base(res) + ".sheet.md").read_text(encoding="utf-8")


def req_base(res):
    return res["sheet"][: -len(".sheet.json")]


def test_regenerate_one_block_keeps_the_rest_and_edits(tmp_path):
    root, a, b = _project(tmp_path)
    req = _req(root, a, b)
    res = B.build(req, emit=_quiet, responder=_resp(ANSWER))
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    ov = next(x for x in sheet["blocks"] if x["type"] == "overview")
    ov["facts"][0]["text"] = "Edited by Mike Carter"
    ov["facts"][0]["status"] = "edited"
    Path(res["sheet"]).write_text(json.dumps(sheet), encoding="utf-8")
    contact_before = next(x for x in sheet["blocks"] if x["type"] == "contact")["facts"]
    ans = json.loads(json.dumps(ANSWER))
    ans["blocks"]["company"] = [{"label": "Team size", "text": "About 95 employees", "source_ids": ["s1"]}]
    ans["blocks"]["contact"] = [{"label": "Role", "text": "COO", "source_ids": ["s2"]}]
    seen = {}
    res2 = B.build(dict(req, options={"blocks": ["b-company"]}), refresh=True, emit=_quiet, responder=_resp(ans, seen))
    assert res2.get("done"), res2
    assert "- company (" in seen["users"][0] and "- contact (" not in seen["users"][0]
    s2 = json.loads(Path(res2["sheet"]).read_text(encoding="utf-8"))
    by = {x["type"]: x for x in s2["blocks"]}
    assert [f["text"] for f in by["company"]["facts"]] == ["About 95 employees"]
    assert by["contact"]["facts"] == contact_before                        # not rebuilt: as it was
    assert by["overview"]["facts"][0]["text"] == "Edited by Mike Carter"   # the edit survives
    assert S.validate(s2) == [] and s2["versions"][-1]["n"] == 2


def test_find_again_asks_only_that_block_with_a_pointed_note(tmp_path):
    root, a, b = _project(tmp_path)
    req = _req(root, a, b)
    res = B.build(req, emit=_quiet, responder=_resp(ANSWER))
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    gap = next(g for g in sheet["readiness"]["gaps"] if g.get("block") and "budget" in g["id"])
    blk = next(x for x in sheet["blocks"] if x["id"] == gap["block"])
    ans = json.loads(json.dumps(ANSWER))
    ans["blocks"]["qualification"][0] = {"label": "Budget", "text": "The CFO set aside $70k", "source_ids": ["s1"],
                                         "value": {"key": "budget", "level": "green"}}
    seen = {}
    res2 = B.build(dict(req, options={"find_again": [gap["id"]]}), refresh=True, emit=_quiet, responder=_resp(ans, seen))
    assert res2.get("done"), res2
    u = seen["users"][0]
    assert "Find again" in u and f"- {blk['type']} (" in u and "- company (" not in u
    s2 = json.loads(Path(res2["sheet"]).read_text(encoding="utf-8"))
    q = next(x for x in s2["blocks"] if x["type"] == blk["type"])["facts"]
    assert any("$70k" in f["text"] for f in q) and any("Find again" in n for n in res2["notes"])


def test_control_file_skip_and_retry(tmp_path):
    root, a, b = _project(tmp_path)
    missing = root / "late.md"
    ctl = tmp_path / "control.json"
    ctl.write_text(json.dumps({"actions": [{"action": "skip", "source_id": "s2"}]}), encoding="utf-8")
    req = _req(root, a, b, control=str(ctl), control_wait_s=8,
               sources=[{"id": "s1", "path": str(a)}, {"id": "s2", "path": str(b)}, {"id": "s3", "path": str(missing)}])
    lines = []

    def later():
        time.sleep(0.8)
        missing.write_text("Budget: the CFO set aside $70k.\n", encoding="utf-8")
        acts = json.loads(ctl.read_text(encoding="utf-8"))["actions"] + [{"action": "retry", "source_id": "s3"}]
        ctl.write_text(json.dumps({"actions": acts}), encoding="utf-8")
    th = threading.Thread(target=later)
    th.start()
    seen = {}
    t0 = time.time()
    res = B.build(req, emit=lambda **k: lines.append(k), responder=_resp(ANSWER, seen))
    th.join()
    assert res.get("done"), res
    assert time.time() - t0 < 7                                            # it went on as soon as the retry worked
    assert any(x.get("waiting") == ["s3"] for x in lines) and any(x.get("skipped") and x.get("source_id") == "s2" for x in lines)
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    src = {s["id"]: s for s in sheet["sources"]}
    assert src["s2"]["used"] == "skipped" and src["s2"]["reason"] == "skipped by you"
    assert src["s3"]["access"] == "ok" and src["s3"]["used"] == "full"
    assert "SOURCE s2" not in seen["users"][0] and "SOURCE s3" in seen["users"][0]


def test_no_control_file_never_waits(tmp_path):
    root, a, b = _project(tmp_path)
    req = _req(root, a, b, control_wait_s=30, sources=[{"id": "s1", "path": str(a)}, {"id": "s3", "path": str(root / "nope.md")}])
    t0 = time.time()
    res = B.build(req, emit=_quiet, responder=_resp(ANSWER))
    assert res.get("done") and time.time() - t0 < 5


# ---------------------------------------------------------------- F3: Prepare again during the call = a sheet refresh

def test_refresh_with_the_transcript_so_far_keeps_edits(tmp_path):
    root, a, b = _project(tmp_path)
    req = _req(root, a, b)
    res = B.build(req, emit=_quiet, responder=_resp(ANSWER))
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    ov = next(x for x in sheet["blocks"] if x["type"] == "overview")
    ov["facts"][0].update(text="Edited by Mike Carter", status="edited")
    Path(res["sheet"]).write_text(json.dumps(sheet), encoding="utf-8")
    tr = root / "live" / "2026-11-13-1600-lumenfield-intro.md"
    tr.write_text("[16:02] Emily Parker: the CFO set aside $70k for this.\n", encoding="utf-8")
    srcs = req["sources"] + [{"id": "s3", "path": str(tr), "type": "transcript", "title": "This call so far (transcript)"}]
    ans = json.loads(json.dumps(ANSWER))
    ans["blocks"]["qualification"][0] = {"label": "Budget", "text": "$70k set aside by the CFO", "source_ids": ["s3"],
                                         "value": {"key": "budget", "level": "green"}}
    seen = {}
    res2 = B.build(dict(req, sources=srcs), refresh=True, emit=_quiet, responder=_resp(ans, seen))
    assert res2.get("done"), res2
    assert "SOURCE s3 | transcript" in seen["users"][0]
    s2 = json.loads(Path(res2["sheet"]).read_text(encoding="utf-8"))
    assert next(x for x in s2["blocks"] if x["type"] == "overview")["facts"][0]["text"] == "Edited by Mike Carter"
    assert any("$70k" in f["text"] for x in s2["blocks"] for f in x["facts"]) and s2["versions"][-1]["n"] == 2


def test_failed_refresh_leaves_the_previous_sheet(tmp_path):
    root, a, b = _project(tmp_path)
    req = _req(root, a, b)
    res = B.build(req, emit=_quiet, responder=_resp(ANSWER))
    before = Path(res["sheet"]).read_text(encoding="utf-8")
    brief = Path(req_base(res) + ".brief.md").read_text(encoding="utf-8")

    def broken(system, user):
        raise RuntimeError("timeout")
    res2 = B.build(req, refresh=True, emit=_quiet, responder=broken)
    assert res2.get("error") and res2.get("code") == 5
    assert Path(res["sheet"]).read_text(encoding="utf-8") == before
    assert Path(req_base(res) + ".brief.md").read_text(encoding="utf-8") == brief


# ---------------------------------------------------------------- F4: questions only once

def test_questions_only_in_their_checklist_not_in_the_agenda(tmp_path):
    root, a, b = _project(tmp_path)
    res = B.build(_req(root, a, b), emit=_quiet, responder=_resp(ANSWER))
    base = req_base(res)
    brief = Path(base + ".brief.md").read_text(encoding="utf-8")
    check = brief.split("## 1. Checklist", 1)[1].split("\n## ", 1)[0]
    assert "Walk through the monthly report" in check and "Who signs off" not in check
    assert "## Questions to ask\n- Who signs off on a workshop?" in brief and "- [ ] **Ask" not in brief
    ag = json.loads(Path(base + ".agenda.json").read_text(encoding="utf-8"))
    assert {x["kind"] for x in ag} == {"agenda"}
    cards = json.loads(Path(base + ".cards.json").read_text(encoding="utf-8"))
    assert not any("Who signs off" in c["gist"] for c in cards)
    sys.path.insert(0, str(REC))
    import transcriber as T
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    assert [q["text"] for q in T.sheet_questions(sheet) if "signs off" in q["text"]] == ["Who signs off on a workshop?"]
    assert not any("signs off" in x for x in T.sheet_agenda(sheet))
    from livetips_m0 import agenda as A
    assert not any("signs off" in t for t, _ in A.full_items(brief))


# ---------------------------------------------------------------- F5: Contact pages are never planned

def test_contact_pages_are_skipped_but_contact_center_products_are_not():
    from livetips_m0.sheet import web as W
    for u in ("https://lumenfield.example/contact", "https://lumenfield.example/contact-us", "https://lumenfield.example/en/contacts/",
              "https://lumenfield.example/kontakty"):
        assert W.skip_reason(W.normalize(u)) == "contact", u
    assert W.skip_reason("https://lumenfield.example/contact-center-software") is None
    assert W.skip_reason("https://lumenfield.example/about") is None
