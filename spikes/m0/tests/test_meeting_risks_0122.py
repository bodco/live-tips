"""0.12.2 (L3, rules/notes.yaml schema 3): ### Risks in the Meeting notes, read by the app, the Notion page and here."""
from pathlib import Path

from livetips_m0.callnotes import MEETING_SYS, parse_meeting, put_meeting

FULL = "# Call notes: Orbit weekly\n## Summary\nPilot.\n"
SECTION = """## Meeting notes
### TL;DR
The pilot starts November 10.
### Open questions
- [10:11:02] Who signs the data statement?
### Risks
- [10:09:40] The pilot moves if the test accounts come after Friday.
### Topics
#### Pilot [10:06:12]
Outcome: starts November 10.
- [10:06:18] Mike: accounts by Friday.
"""


def test_prompt_asks_for_risks():
    assert "### Risks" in MEETING_SYS and "at most 5 risks" in MEETING_SYS
    assert MEETING_SYS.index("### Open questions") < MEETING_SYS.index("### Risks") < MEETING_SYS.index("### Topics")
    assert "a question, risk or blocker" not in MEETING_SYS
    assert chr(0x2014) not in MEETING_SYS


def test_parse_risks():
    m = parse_meeting(put_meeting(FULL, SECTION))
    assert m["risks"] == [{"t": "10:09:40", "text": "The pilot moves if the test accounts come after Friday."}]
    assert m["open"][0]["text"] == "Who signs the data statement?"
    assert parse_meeting("## Meeting notes\n### Ризики\n- [10:00:01] Бюджет можуть не погодити\n")["risks"][0]["t"] == "10:00:01"
    assert parse_meeting(FULL)["risks"] == []


def test_notion_page_has_risks(tmp_path, monkeypatch):
    from livetips_m0 import wrapup_notion as w
    md = tmp_path / "2026-11-05-1000-orbit.md"
    md.write_text("# Live Transcript: Orbit\n", encoding="utf-8")
    (tmp_path / "2026-11-05-1000-orbit.notes.md").write_text(put_meeting(FULL, SECTION), encoding="utf-8")
    monkeypatch.setattr(w, "agenda_lines", lambda md, lang: [])
    b = w.meeting_blocks(w.call_meeting(md), md, {}, False, "en")
    heads = [x["heading_3"]["rich_text"][0]["text"]["content"] for x in b if x["type"] == "heading_3"]
    assert heads.index("Open questions") < heads.index("Risks")
