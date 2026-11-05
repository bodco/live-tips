"""0.9.5.2 (rules/notes.yaml, schema 2): the readable ## Meeting notes section at the top of the full notes."""
from pathlib import Path

from livetips_m0.callnotes import MEETING_SYS, make_meeting, meeting_text, parse_meeting, put_meeting

FULL = """# Call notes: Orbit weekly
Date 2026-11-05 10:00, 18 min, Mike Johnson (team), David Kim (client).
## Summary
Export and pilot.
## Topics
- **Export (10:01)**: merged.
## Decisions
- Export goes to production on Tuesday

Coverage: numbers 4/4. Made 2026-11-05 10:20 by claude-sonnet-5-5.
"""

SECTION = """## Meeting notes
### TL;DR
The export is merged; the pilot starts November 10.
### Decisions
- [10:04:10] Export goes to production on Tuesday.
### Action items
- [10:06:29] **David Kim**: send the test accounts (due: Friday)
### Open questions
- [10:11:02] Data retention statement still needs legal approval.
### Topics
#### Export screen [10:00:21]
Outcome: merged to main, ships Tuesday.
- [10:00:30] Mike: failed payments retry after 1, 6 and 24 hours.
#### Pilot readiness [10:06:12]
**Outcome:** starts November 10 if the accounts come by Friday.
- [10:06:18] David's manager wants one more approval.
### Unclear
- The name of the security vendor.
"""


def test_section_goes_before_the_full_notes_and_keeps_them():
    out = put_meeting(FULL, SECTION)
    assert out.index("## Meeting notes") < out.index("## Summary")
    assert out.startswith("# Call notes: Orbit weekly\nDate")
    for kept in ("## Topics\n- **Export (10:01)**: merged.", "## Decisions", "Coverage: numbers 4/4"):
        assert kept in out


def test_section_is_replaced_not_added_twice():
    once = put_meeting(FULL, SECTION)
    twice = put_meeting(once, SECTION.replace("November 10", "November 12"))
    assert twice.count("## Meeting notes") == 1 and "November 12" in twice and "November 10 if" not in meeting_text(twice).split("TL;DR")[1][:80]
    assert twice.count("## Summary") == 1 and "Coverage: numbers 4/4" in twice


def test_parse():
    m = parse_meeting(put_meeting(FULL, SECTION))
    assert m["tldr"].startswith("The export is merged")
    assert m["decisions"] == [{"t": "10:04:10", "text": "Export goes to production on Tuesday."}]
    assert m["actions"][0]["t"] == "10:06:29" and m["actions"][0]["text"].startswith("**David Kim**")
    assert [t["title"] for t in m["topics"]] == ["Export screen", "Pilot readiness"]
    assert m["topics"][0]["t"] == "10:00:21" and m["topics"][0]["outcome"] == "merged to main, ships Tuesday."
    assert m["topics"][1]["outcome"].startswith("starts November 10")
    assert m["topics"][1]["points"][0] == {"t": "10:06:18", "text": "David's manager wants one more approval."}
    assert m["unclear"][0]["text"] == "The name of the security vendor."


def test_no_section():
    assert meeting_text(FULL) == "" and parse_meeting(FULL)["topics"] == []


def test_prompt_rules():
    assert chr(0x2014) not in MEETING_SYS and "[HH:MM:SS]" in MEETING_SYS
    for h in ("### TL;DR", "### Decisions", "### Action items", "### Open questions", "### Topics", "#### ", "### Unclear"):
        assert h in MEETING_SYS
    assert "Olena" not in MEETING_SYS


def test_make_meeting_one_request():
    calls = []

    def ask(system, user, max_tokens):
        calls.append((system, user))
        return "Here you go.\n" + SECTION
    sec = make_meeting(Path("2026-11-05-1000-orbit.md"), FULL, "[10:00:21] Mike Johnson (en): done", "en", ask, "The PM is Mike.")
    assert len(calls) == 1 and sec.startswith("## Meeting notes") and "English" in calls[0][0] and "The PM is Mike." in calls[0][0]
    assert "# TRANSCRIPT\n[10:00:21]" in calls[0][1]


def test_notion_page_from_meeting_notes(tmp_path, monkeypatch):
    from livetips_m0 import wrapup_notion as w
    md = tmp_path / "2026-11-05-1000-orbit.md"
    md.write_text("# Live Transcript: Orbit\n", encoding="utf-8")
    (tmp_path / "2026-11-05-1000-orbit.notes.md").write_text(put_meeting(FULL, SECTION), encoding="utf-8")
    monkeypatch.setattr(w, "agenda_lines", lambda md, lang: [])
    m = w.call_meeting(md)
    assert m["tldr"].startswith("The export")
    b = w.meeting_blocks(m, md, {}, False, "en")
    types = [x["type"] for x in b]
    assert types[0] == "paragraph" and "to_do" in types and "heading_2" in types
    todo = next(x for x in b if x["type"] == "to_do")["to_do"]["rich_text"]
    assert todo[0]["text"]["content"].startswith("10:06") and todo[1]["annotations"] == {"bold": True} and todo[1]["text"]["content"] == "David Kim"
    heads = [x["heading_3"]["rich_text"][0]["text"]["content"] for x in b if x["type"] == "heading_3"]
    assert "Export screen  10:00" in heads and "Topics" not in heads and "Unclear" in heads
    assert not any("**" in r["text"]["content"] for x in b for r in x[x["type"]].get("rich_text", []))


def test_notion_without_meeting_notes(tmp_path):
    from livetips_m0 import wrapup_notion as w
    md = tmp_path / "x.md"
    md.write_text("", encoding="utf-8")
    assert w.call_meeting(md) == {}
    (tmp_path / "x.notes.md").write_text(FULL, encoding="utf-8")
    assert w.call_meeting(md) == {}


def test_page_waits_for_the_meeting_notes(tmp_path):
    from livetips_m0 import wrapup_notion as w
    md = tmp_path / "x.md"
    md.write_text("", encoding="utf-8")
    assert w.wait_meeting(md, 0) == {}
    (tmp_path / "x.notes.md").write_text(put_meeting(FULL, SECTION), encoding="utf-8")
    assert w.wait_meeting(md, 30, step=0.01)["topics"]


def test_prompt_keeps_it_short():
    assert "at most 8 action items" in MEETING_SYS and "at most 5 open questions" in MEETING_SYS
