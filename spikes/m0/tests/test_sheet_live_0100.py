"""0.10.0 (Meeting Sheet, phase 7): live takes the Meeting Sheet. Sheet -> cards, facts, questions, red lines, agenda,
slides, stand-up; no sheet = exactly the old behaviour; derived copies never shown twice; lookup ranking; after-call check."""
import json
import shutil
from pathlib import Path

import pytest

from test_presentation_rules import T  # noqa: F401  (module fixture: the recorder)

FIX = Path(__file__).parent / "fixtures" / "sheet"


def _sheet(name="sales-intro-lumenfield"):
    return json.loads((FIX / f"{name}.sheet.json").read_text(encoding="utf-8"))


def _with_extra(sheet):
    """The Lumenfield sheet plus a red line, an agenda and a deck structure (all invented)."""
    s = json.loads(json.dumps(sheet))
    base = {"source_ids": ["s5"], "locator": {}, "checked_at": "2026-11-12T09:00:00+02:00", "status": "found", "origin": "user"}
    for b in s["blocks"]:
        if b["type"] == "red_lines":
            b["facts"] = [dict(base, id="r-price", text="No fixed price before the discovery workshop")]
        if b["type"] == "questions":
            b["facts"].append(dict(base, id="q-budget", text="Is there a budget for reporting automation this year?"))
    s["blocks"].append({"id": "b-agenda", "type": "agenda", "title": "Agenda", "visible": True, "only_if_data": False,
                        "order": 99, "edited_by_user": False,
                        "facts": [dict(base, id="a-1", text="Their reporting today"), dict(base, id="a-2", text="Northwind Studio case")]})
    s["blocks"].append({"id": "b-structure_roles", "type": "structure_roles", "title": "Structure and roles", "visible": True,
                        "only_if_data": True, "order": 100, "edited_by_user": False,
                        "facts": [dict(base, id="sl-1", label="Intro", text="We build reporting tools.", value={"slide": 1, "owner": "me", "minutes": 2}),
                                  dict(base, id="sl-2", label="Case", text="Northwind cut reports from 3 days to 2 hours.",
                                       value={"slide": 2, "owner": "Mike Carter", "minutes": 3, "backup": "Northwind: 3 days to 2 hours."})]})
    return s


def _call(tmp_path, sheet=None, cards=None, facts=None):
    stem = tmp_path / "2026-11-13-1600-lumenfield.app.md"
    tips = tmp_path / "2026-11-13-1600-lumenfield.app.tips.jsonl"
    tips.write_text("")
    if sheet is not None:
        (tmp_path / (stem.stem + ".sheet.json")).write_text(json.dumps(sheet))
    if cards is not None:
        (tmp_path / (stem.stem + ".cards.json")).write_text(json.dumps(cards))
    if facts is not None:
        (tmp_path / (stem.stem + ".facts.json")).write_text(json.dumps(facts))
    return stem, tips


def _wire(T, stem, tips):
    sl = T.SheetLive(stem, tips)
    c, f, s = T.Cards(stem, tips), T.FactBook(stem, tips), T.Slides(stem, tips)
    sl.has_slides_file = s.path.exists
    c.sheet = f.sheet = s.sheet = sl
    sl.refresh()
    f.refresh()
    s.refresh()
    return sl, c, f, s


def _rows(tips):
    return [json.loads(x) for x in tips.read_text().splitlines() if x.strip()]


# ---------------------------------------------------------------- mapping

def test_sheet_facts_carry_source_numbers_and_skip_not_found(T):
    facts = T.sheet_facts(_sheet())
    by = {f["sheet_fact"]: f for f in facts}
    assert "f-q-budget" not in by                                  # "Not found" is no answer
    assert by["f-industry"]["text"].endswith("[1]")
    assert by["f-contact-title"]["text"].endswith("[2]") and "[2] Emily Parker" in by["f-contact-title"]["source"]
    assert "conflicts" in by["f-size-site"]["text"]                # both sides of a conflict, marked
    assert all(f["sheet"] is True and f["keywords"] for f in facts)
    assert not any("\u2014" in json.dumps(f, ensure_ascii=False) for f in facts)


def test_questions_become_ask_now_cards_and_a_checklist(T):
    cards = T.sheet_cards(_with_extra(_sheet()))
    asks = [c for c in cards if c.get("ask")]
    assert {c["sheet_fact"] for c in asks} == {"q-reports", "q-budget"}
    assert all(c["gist"] == "Ask now" and c["phrase"] and c["on"] == "any" for c in asks)
    red = [c for c in cards if c.get("promise")]
    assert len(red) == 1 and red[0]["on"] == "me" and red[0]["level"] == "red"
    assert "price" in red[0]["kw"] and "promise" not in red[0]["kw"]
    best = [c for c in cards if c.get("best")]
    assert best and best[0]["items"] == ["A discovery workshop booked for next week"]


def test_ask_now_fires_on_the_topic_once_and_one_at_a_time(T, tmp_path):
    stem, tips = _call(tmp_path, _with_extra(_sheet()))
    sl, c, f, s = _wire(T, stem, tips)
    c.check(T.Line(channel="them", t=1.0, lang="en", text="Honestly the monthly reports hurt us the most."))
    assert [r.get("phrase") for r in _rows(tips) if r.get("kind") == "card"] == ["Which reports hurt the most today?"]
    rows = [r for r in _rows(tips) if r.get("kind") == "card"]
    assert [r["card"] for r in rows] == ["ms-q-q-reports"]
    c.check(T.Line(channel="them", t=2.0, lang="en", text="And the budget for automation is approved for this year."))
    assert len([r for r in _rows(tips) if r.get("kind") == "card"]) == 1     # a second "ask now" waits (gap)
    c.last_ask -= 200
    c.check(T.Line(channel="them", t=3.0, lang="en", text="The reports hurt the most, the reports."))
    assert len([r for r in _rows(tips) if r.get("kind") == "card"]) == 1     # never the same question twice


def test_a_question_the_pm_asked_is_ticked_and_never_prompted(T, tmp_path):
    stem, tips = _call(tmp_path, _with_extra(_sheet()))
    sl, c, f, s = _wire(T, stem, tips)
    line = T.Line(channel="me", t=1.0, lang="en", text="Is there any budget for reporting automation this year?")
    sl.note_line(line)
    assert "ms-q-q-budget" in sl.asked
    qs = [r for r in _rows(tips) if r.get("kind") == "questions"][-1]
    assert {i["id"]: i["state"] for i in qs["items"]} == {"ms-q-q-reports": "todo", "ms-q-q-budget": "asked"}
    c.check(T.Line(channel="them", t=2.0, lang="en", text="Budget for the automation, yes, this year we have it."))
    assert not [r for r in _rows(tips) if r.get("card") == "ms-q-q-budget"]


def test_red_line_warns_on_a_promise_not_on_mere_words(T, tmp_path):
    stem, tips = _call(tmp_path, _with_extra(_sheet()))
    sl, c, f, s = _wire(T, stem, tips)
    c.check(T.Line(channel="them", t=1.0, lang="en", text="Can you give us a fixed price today?"))
    c.check(T.Line(channel="me", t=2.0, lang="en", text="The price depends on the discovery."))
    assert not [r for r in _rows(tips) if r.get("card", "").startswith("ms-red")]
    c.check(T.Line(channel="me", t=3.0, lang="en", text="Sure, I can give you a fixed price, roughly twenty thousand."))
    red = [r for r in _rows(tips) if r.get("card", "").startswith("ms-red")]
    assert len(red) == 1 and red[0]["gist"] == "Red line: No fixed price before the discovery workshop"
    assert "twenty" not in json.dumps(red[0])                      # the sheet's words, never the PM's


def test_best_outcome_on_a_wrap_cue_and_by_time(T, tmp_path):
    stem, tips = _call(tmp_path, _with_extra(_sheet()))
    sl, c, f, s = _wire(T, stem, tips)
    c.check(T.Line(channel="them", t=1.0, lang="en", text="Okay, anything else before we finish?"))
    assert [r for r in _rows(tips) if r.get("card") == "ms-best"]
    (tmp_path / "x").mkdir()
    stem2, tips2 = _call(tmp_path / "x", _with_extra(_sheet()))
    sl2, c2, *_ = _wire(T, stem2, tips2)
    end = T._iso_ts(_sheet()["meeting_ref"]["end"])
    sl2.tick(end - 3600, c2.emit_direct)
    assert not [r for r in _rows(tips2) if r.get("card") == "ms-best"]
    sl2.tick(end - 120, c2.emit_direct)
    sl2.tick(end - 60, c2.emit_direct)
    assert len([r for r in _rows(tips2) if r.get("card") == "ms-best"]) == 1


def test_agenda_and_slides_and_facts_reach_the_window(T, tmp_path):
    stem, tips = _call(tmp_path, _with_extra(_sheet()))
    sl, c, f, s = _wire(T, stem, tips)
    rows = _rows(tips)
    chk = [r for r in rows if r.get("kind") == "checklist"]
    assert chk and chk[0]["items"] == ["Their reporting today", "Northwind Studio case"]
    sld = [r for r in rows if r.get("kind") == "slides"]
    assert sld and [x["who"] for x in sld[0]["slides"]] == ["me", "other"]
    assert sld[0]["slides"][1]["speaker"] == "Mike Carter" and sld[0]["slides"][1]["sec"] == 180
    assert any(b["t"].startswith("Northwind: 3 days") for b in sld[0]["slides"][1]["body"])   # backup text for the colleague
    assert any(r.get("kind") == "facts" and any(x.get("sheet") for x in r["facts"]) for r in rows)


def test_slides_json_wins_over_the_sheet_structure(T, tmp_path):
    stem, tips = _call(tmp_path, _with_extra(_sheet()))
    (tmp_path / (stem.stem + ".slides.json")).write_text(json.dumps({"slides": [{"n": 1, "title": "Own deck", "body": ["x"]}]}))
    sl, c, f, s = _wire(T, stem, tips)
    assert [x["title"] for x in s.slides] == ["Own deck"]


def test_standup_gives_my_update_and_whom_to_ask(T, tmp_path):
    stem, tips = _call(tmp_path, _sheet("standup-orbit"))
    sl, c, f, s = _wire(T, stem, tips)
    rows = _rows(tips)
    sp = [r for r in rows if r.get("kind") == "speech"]
    assert sp and sp[0]["standup"] is True
    assert sp[0]["items"] == ["Finished the export screen", "Today: Fix the date filter bug", "Ask Mike Carter: test accounts"]
    assert not [r for r in rows if r.get("kind") == "card"]
    assert not [r for r in rows if r.get("kind") == "slides"]


# ---------------------------------------------------------------- no duplication, no sheet

def test_derived_cards_and_facts_are_not_shown_twice(T, tmp_path):
    derived_cards = [{"id": "d1", "triggers": ["which reports hurt"], "gist": "Ask: which reports hurt", "sheet": True},
                     {"id": "q-reports", "triggers": ["reports hurt most"], "gist": "same question by id"},
                     {"id": "own", "triggers": ["send the contract"], "gist": "Own card", "on": "any"}]
    derived_facts = [{"id": "x", "title": "Industry", "text": "Lighting", "keywords": ["industry"], "sheet_fact": "f-industry"},
                     {"id": "own-f", "title": "Rate", "text": "Own fact", "keywords": ["rate"]}]
    stem, tips = _call(tmp_path, _with_extra(_sheet()), derived_cards, derived_facts)
    sl, c, f, s = _wire(T, stem, tips)
    ids = [T.Cards.cid(x) for x in c.snapshot()]
    assert "own" in ids and "d1" not in ids and "q-reports" not in ids and "ms-q-q-reports" in ids
    fids = [x["id"] for x in f.facts]
    assert "own-f" in fids and "x" not in fids and "ms-f-industry" in fids


def test_no_sheet_is_exactly_the_old_behaviour(T, tmp_path):
    cards = [{"id": "price", "triggers": ["how much does it cost"], "on": "any", "gist": "Price", "cooldown_s": 0}]
    facts = [{"id": "f1", "title": "Rate", "text": "50 per hour", "keywords": ["rate", "hour"]}]
    stem, tips = _call(tmp_path, None, cards, facts)
    old_c, old_f = T.Cards(stem, tips), T.FactBook(stem, tips)
    old_f.refresh()
    line = T.Line(channel="them", t=1.0, lang="en", text="So how much does it cost?")
    old_c.check(line)
    before = tips.read_text()
    tips.write_text("")
    sl, c, f, s = _wire(T, stem, tips)
    c.check(line)
    assert not sl.active() and sl.cards == [] and sl.questions == []
    strip = lambda txt: [{k: v for k, v in json.loads(x).items() if k not in ("at",)} for x in txt.splitlines()]
    assert strip(tips.read_text()) == strip(before)
    assert c.snapshot() == old_c.snapshot() and f.facts == old_f.facts
    sl.tick(9e9, c.emit_direct)
    sl.save_state(stem)
    assert not (tmp_path / (stem.stem + ".sheet-live.json")).exists()


def test_a_half_written_sheet_keeps_the_last_good_one(T, tmp_path):
    stem, tips = _call(tmp_path, _with_extra(_sheet()))
    sl, c, f, s = _wire(T, stem, tips)
    n = len(sl.cards)
    p = tmp_path / (stem.stem + ".sheet.json")
    p.write_text('{"schema": "pacenote.sheet/1", "blocks": [')
    import os
    os.utime(p, (1, 1))
    assert sl.refresh() is False and len(sl.cards) == n


def test_state_saved_for_the_after_call(T, tmp_path):
    stem, tips = _call(tmp_path, _with_extra(_sheet()))
    sl, c, f, s = _wire(T, stem, tips)
    sl.note_line(T.Line(channel="me", t=1.0, lang="en", text="Which reports hurt the most today?"))
    sl.save_state(stem)
    st = json.loads((tmp_path / (stem.stem + ".sheet-live.json")).read_text())
    assert st["asked"] == ["ms-q-q-reports"] and len(st["questions"]) == 2


# ---------------------------------------------------------------- lookup (L2)

def test_lookup_ranks_the_file_with_the_answer_first(tmp_path):
    from livetips_m0.sheet import lookup
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "orbit-config.md").write_text("# Working rules\n\nAbove ten hours the director approves a change.\n\n"
                                                      "# Team\n\nMike Carter leads the backend.\n")
    (tmp_path / "_notion").mkdir()
    (tmp_path / "_notion" / "current-state.md").write_text("# Budget\n\n81 of 120 pilot hours used, 39 hours left.\n")
    (tmp_path / "live").mkdir()
    (tmp_path / "live" / "2026-11-04-1000-orbit.app.md").write_text("[10:00:01] Me: the current call itself\n")
    (tmp_path / "live" / "2026-11-04-1000-orbit.app.tips.jsonl").write_text('{"gist": "pilot hours left 39"}\n')
    (tmp_path / ".livetips-index").mkdir()
    (tmp_path / ".livetips-index" / "chunks.json").write_text('["pilot hours left"]')
    hits = lookup.snippets("How many pilot hours are left?", roots=[tmp_path], k=3, exclude_prefix="2026-11-04-1000-orbit.app")
    assert hits[0]["src"] == "_notion/current-state.md" and "39 hours left" in hits[0]["text"]
    assert not any(".livetips-index" in h["path"] or h["path"].endswith(".tips.jsonl") or "current call" in h["text"] for h in hits)
    # Ukrainian question, English notes: the shared stems find it without a model
    uk = lookup.snippets("скільки годин лишилось?", roots=[tmp_path], k=2)
    assert uk and uk[0]["src"] == "_notion/current-state.md"


def test_lookup_searches_the_sheet_with_source_numbers(tmp_path):
    from livetips_m0.sheet import lookup
    hits = lookup.snippets("What does Emily do at Lumenfield?", sheet=_sheet(), roots=[], k=3)
    assert all(h["src"].startswith("Meeting Sheet [") for h in hits)
    assert any(h["src"] == "Meeting Sheet [2]" and "VP Operations" in h["text"] for h in hits[:2])
    assert lookup.snippets("", sheet=_sheet()) == [] and lookup.snippets("anything", roots=[tmp_path / "nope"]) == []


def test_lookup_reads_the_sheet_sources_on_disk(tmp_path):
    from livetips_m0.sheet import lookup
    s = _sheet()
    case = tmp_path / "northwind.md"
    case.write_text("# Northwind Studio\n\nReporting automation cut monthly reports from 3 days to 2 hours.\n")
    for src in s["sources"]:
        if src["id"] == "s4":
            src["path"] = str(case)
    hits = lookup.snippets("How fast are the Northwind monthly reports now?", sheet=s, k=4)
    assert any(h["src"] == "[4] cases/northwind-studio-reporting.md" and "2 hours" in h["text"] for h in hits)
    assert lookup.load_sheet_near(tmp_path / "x.brief.md") is None


def test_engine_lookup_is_local_on_every_way_and_sees_the_sheet(tmp_path, monkeypatch):
    from test_engine import _meeting_engine
    from livetips_m0 import deep
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "notes.md").write_text("# Pricing\n\nPhase 2 is 420 hours, Reports first.\n")
    eng, clock = _meeting_engine(tmp_path, lambda m, u: '{"queries": ["phase 2 hours"]}' if "Question:" in u else "{}",
                                 project_root=str(proj), deep_lookup=True, ai={"routes": {"prep": "code", "tips": "code"}})
    eng._call_agent = lambda: None
    (tmp_path / "x.sheet.json").write_text(json.dumps(_sheet()))
    eng.prompt._brief_path = tmp_path / "x.brief.md"
    monkeypatch.setattr(deep, "claude_path", lambda cfg: "/usr/bin/claude")
    monkeypatch.setattr(deep, "lookup", lambda *a, **k: pytest.fail("Claude Code must not run unless switched on"))
    seen = {}

    def local(prov, model, q, tail, lang, snips, render):
        seen["snips"] = snips
        return {"answered": True, "gist": "420 h", "phrase": "p", "items": [], "sources": ["notes.md"], "cost_usd": 0.0}
    monkeypatch.setattr(deep, "local_lookup", local)
    assert eng._deep_via_claude_code() is False
    eng._run_deep("phase 2 hours and Emily's role", "ask", [])
    srcs = [x["src"] for x in seen["snips"]]
    assert "notes.md" in srcs and any(x.startswith("Meeting Sheet") for x in srcs)
    eng.drain(1)


# ---------------------------------------------------------------- after the call (L4)

def test_after_call_check_marks_questions_and_outcome_and_feeds_the_followup(tmp_path):
    from livetips_m0.sheet import aftercheck
    from livetips_m0 import followup
    md = tmp_path / "2026-11-13-1600-lumenfield.app.md"
    md.write_text("# Lumenfield intro\n\n[16:04:10] Me: Which reports hurt the most today?\n"
                  "[16:04:20] Emily Parker: The monthly ops report, two people for three days.\n")
    (tmp_path / "2026-11-13-1600-lumenfield.app.sheet.json").write_text(json.dumps(_with_extra(_sheet())))
    (tmp_path / "2026-11-13-1600-lumenfield.app.sheet-live.json").write_text(json.dumps({"asked": ["ms-q-q-reports"]}))
    seen = {}

    def ask(system, user, n):
        seen["user"] = user
        return json.dumps({"questions": [{"id": "q-reports", "status": "answered", "t": "16:04:20",
                                          "said": "The monthly ops report takes two people three days."},
                                         {"id": "q-budget", "status": "maybe", "t": "soon"}],
                           "outcome": [{"id": "f-outcome", "status": "partly", "t": "", "said": "",
                                        "follow_up": "Propose two workshop dates"}]})
    notes = "# Notes\n\n## Meeting notes\n### TL;DR\nIntro call.\n\n## Summary\nText.\n\nCoverage: numbers 1/1.\n"
    out = aftercheck.add_to_notes(md, notes, md.read_text(), "en", ask)
    assert "q-reports | Which reports hurt the most today? (the PM asked it during the call)" in seen["user"]
    res = json.loads((tmp_path / "2026-11-13-1600-lumenfield.app.sheet-check.json").read_text())
    assert [q["status"] for q in res["questions"]] == ["answered", "not"]          # unknown status -> not
    assert res["questions"][1]["t"] == "" and res["outcome"][0]["status"] == "partly"
    assert out.index("## Meeting notes") < out.index("## Meeting Sheet check") < out.index("## Summary")
    assert "- [16:04:20] Answered: Which reports hurt the most today?" in out
    assert "Partly reached: A discovery workshop booked for next week" in out and "Propose two workshop dates" in out
    assert aftercheck.put_section(out, aftercheck.render(res)).count("## Meeting Sheet check") == 1
    assert chr(0x2014) not in out      # pipeline agent: the repo check forbids the character itself
    lines = aftercheck.followup_lines(md)
    assert any("Is there a budget" in x for x in lines) and any("discovery workshop" in x for x in lines)
    assert "FROM THE MEETING SHEET CHECK" in followup.build_user(md)


def test_after_call_check_does_nothing_without_a_sheet(tmp_path):
    from livetips_m0.sheet import aftercheck
    md = tmp_path / "call.app.md"
    md.write_text("[10:00:00] Me: hi\n")
    notes = "## Meeting notes\nx\n"
    assert aftercheck.add_to_notes(md, notes, "x", "en", lambda *a: pytest.fail("no model call without a sheet")) == notes
    assert aftercheck.followup_lines(md) == []
