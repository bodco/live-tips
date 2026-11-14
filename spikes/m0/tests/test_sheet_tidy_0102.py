"""0.10.2 (Q, v4): the Meeting Sheet prompt asks for the likely goal, and the sheet is cleaned after the build: no meta
lines in the header, a fact repeated in another block is dropped, a "not found" placeholder goes when its block has
real facts, and a block with nothing real is not shown (the Gaps block says what is missing).
Every fixture is invented (Mike Carter, Emily Parker, Lumenfield)."""
import json
from pathlib import Path

from livetips_m0.sheet import build as B, derive as D, prompt as PR, schema as S

from test_sheet_pipeline_0100 import ANSWER, _project, _req, quiet


def _f(fid, label, text, status="found", **kw):
    f = {"id": fid, "label": label, "text": text, "source_ids": ["s1"] if status != "not_found" else [],
         "status": status, "origin": "model"}
    f.update(kw)
    return f


def _b(t, order, facts, **kw):
    b = {"id": "b-" + t, "type": t, "title": t.title(), "visible": True, "only_if_data": False, "order": order,
         "edited_by_user": False, "facts": facts}
    b.update(kw)
    return b


def test_contract_asks_for_the_likely_goal_on_every_route():
    sys_ = PR.system("en", ["en"])
    assert 'starting with "Likely: "' in sys_ and "Order the facts in each block from that goal" in sys_
    assert "Likely: <your best guess>" in sys_
    agent = PR.agent_prompt({"meeting": {"title": "Sync"}}, "- overview", [], {}, {}, "en", ["en"])
    assert 'starting with "Likely: "' in agent


def test_header_has_no_meta_lines_and_shows_the_sheet_goal():
    req = {"meeting": {"start": "2026-11-20T10:00"}, "call_type": "status", "goal": "",
           "participants": {"ours": [{"name": "auto"}], "theirs": [{"name": "Emily Parker", "company": "Lumenfield"}]}}
    labels = {f["label"]: f["text"] for f in B.header_facts(req, "s-meeting", "x", "Likely: agree the pilot scope")}
    assert "Meeting type" not in labels and "Our side" not in labels
    assert labels["Goal"] == "Likely: agree the pilot scope" and labels["Their side"] == "Emily Parker, Lumenfield"
    req["participants"]["ours"] = [{"name": "Mike Carter", "role": "PM"}]
    req["goal"] = "Sign the SOW"
    labels = {f["label"]: f["text"] for f in B.header_facts(req, "s-meeting", "x")}
    assert labels["Our side"] == "Mike Carter (PM)" and labels["Goal"] == "Sign the SOW"


def test_same_fact():
    assert B.same_fact("SOW Confirm the Phase 2 SOW is signed", "SOW signed? Was the Phase 2 SOW signed on 2026-10-19?")
    assert not B.same_fact("Deals 94 in 2024, 51 in 2025", "Deals 96 in 2024, 50 in 2025")      # numbers disagree
    assert not B.same_fact("Role VP Operations", "Who Lumenfield sells software; Emily runs operations")  # one word
    assert not B.same_fact("Mike Carter: share the staging access", "Send Mike Carter the test accounts")
    assert B.LONE_NUM.findall("Verra O365 from 11-03, 19:00") == ["11-03", "19:00"]


def test_tidy_drops_repeats_and_placeholders_but_keeps_what_must_stay():
    blocks = [
        _b("header", 0, [_f("h1", "When", "2026-11-20")]),
        _b("agenda", 1, [_f("a1", "Staging access", "Confirm who gives Emily Parker staging access by Friday")]),
        _b("questions", 2, [_f("q1", "Access", "Who gives Emily Parker staging access, and by Friday?"),
                            _f("q2", "Budget", "Is the budget for the pilot approved?")]),
        _b("company", 3, [_f("c1", "Team size", "About 120 employees", conflict_with=["c2"]),
                          _f("c2", "Team size", "About 120 employees in total", status="conflict"),
                          _f("c3", "Founded", "Not stated", status="not_found")]),
        _b("qualification", 4, [_f("k1", "Budget", "Is the budget for the pilot approved?"),
                                _f("k2", "Need", "Not stated", status="not_found")]),
        _b("signals", 5, [_f("g1", "Access", "Emily Parker staging access by Friday confirmed", origin="user")]),
        _b("red_lines", 6, [_f("r1", "Access", "Who gives Emily Parker staging access by Friday")], visible=False),
    ]
    assert B.tidy(blocks) == 1
    by = {b["type"]: [f["id"] for f in b["facts"]] for b in blocks}
    assert by["questions"] == ["q2"]                          # the agenda already has it
    assert by["company"] == ["c1", "c2"]                      # both sides of a conflict stay; the placeholder goes
    assert by["qualification"] == ["k1", "k2"]                # one fact per criterion, never merged away
    assert by["signals"] == ["g1"] and by["red_lines"] == ["r1"] and by["header"] == ["h1"]


def test_tidy_changes_only_the_rebuilt_blocks():
    agenda = _b("agenda", 0, [_f("a1", "Access", "Confirm staging access for Emily Parker")])
    questions = _b("questions", 1, [_f("q1", "Access", "Staging access for Emily Parker confirmed?")])
    assert B.tidy([agenda, questions], [agenda]) == 0 and len(questions["facts"]) == 1
    assert B.tidy([agenda, questions], [questions]) == 1 and questions["facts"] == []


def test_empty_block_is_not_shown_and_gaps_still_name_it():
    sheet = {"version": 1, "title": "Lumenfield sync", "language": "en", "goal": "Likely: agree the pilot scope",
             "sources": [], "blocks": [
                 _b("header", 0, [_f("f-header-goal", "Goal", "Likely: agree the pilot scope"),
                                  _f("f-header-when", "When", "2026-11-20")]),
                 _b("signals", 1, [_f("s1", "Signals", "No hiring news in the sources", status="not_found")]),
                 _b("qualification", 2, [_f("k1", "Budget", "Not stated", status="not_found")]),
                 _b("contact", 3, [_f("c1", "Role", "Not stated", status="not_found")], edited_by_user=True),
                 _b("gaps", 4, [_f("gp1", "Not found: Signals", "No hiring news in the sources", status="needs_check",
                                   origin="readiness")])]}
    md = D.render_md(sheet)
    assert "## Signals" not in md and "No hiring news in the sources" in md        # only in Gaps
    assert "## Qualification" in md and "## Contact" in md
    assert md.count("Likely: agree the pilot scope") == 1                            # on top, not again in the header


def test_build_keeps_the_likely_goal_and_cleans_the_sheet(tmp_path):
    root, a, b = _project(tmp_path)
    req = _req(root, a, b, call_type="sales_intro")
    ans = json.loads(json.dumps(ANSWER))
    ans["goal"] = "Likely: agree on a discovery workshop"
    ans["blocks"]["questions"].append({"label": "Reporting pain", "text": "Walk through the monthly report?",
                                       "source_ids": ["s1"]})
    ans["blocks"]["best_outcome"] = [{"label": "Discount", "text": "Nothing about a discount limit", "status": "not_found"}]
    res = B.build(req, emit=quiet, responder=lambda s, u: json.dumps(ans))
    assert res.get("done"), res
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    assert S.validate(sheet) == []
    assert sheet["goal"] == "Likely: agree on a discovery workshop"
    head = {f["label"]: f["text"] for b in sheet["blocks"] if b["type"] == "header" for f in b["facts"]}
    assert head["Goal"] == sheet["goal"] and "Meeting type" not in head
    qs = [f["text"] for b in sheet["blocks"] if b["type"] == "questions" for f in b["facts"]]
    assert "Who signs off on a workshop?" in qs and "Walk through the monthly report?" not in qs   # the agenda has it
    assert any("repeated another block" in n for n in res["notes"])
    md = Path(req["base"] + ".sheet.md").read_text(encoding="utf-8")
    assert "Nothing about a discount limit" in md and "## Best outcome" not in md
    gaps = [f["text"] for b in sheet["blocks"] if b["type"] == "gaps" for f in b["facts"]]
    assert any("discount limit" in g for g in gaps)
