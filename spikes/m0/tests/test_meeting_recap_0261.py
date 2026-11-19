"""0.26.1 (owner: "what happened on the call?"): ### Recap under the TL;DR of the Meeting notes."""
from pathlib import Path

from livetips_m0.callnotes import MEETING_SYS, parse_meeting
from livetips_m0.wrapup_notion import meeting_blocks

NOTES = """## Meeting notes
### TL;DR
The export is merged.
### Recap
1. **Prod.** I wanted to show it, but they had tested it already.
2) **Priority.** Transactions first; affinity groups wait.
- **Table.** A separate one.
Overall no blockers.
### Decisions
- [10:04:10] Export goes to production on Tuesday.

## Summary
Export.
"""


def test_the_prompt_asks_for_a_recap_without_times():
    assert MEETING_SYS.index("### TL;DR\n") < MEETING_SYS.index("### Recap\n") < MEETING_SYS.index("### Decisions\n")
    assert "except TL;DR, Recap and Topics" in MEETING_SYS and "(not in ### Recap)" in MEETING_SYS


def test_recap_is_read_as_points_and_a_note():
    m = parse_meeting(NOTES)
    assert m["recap"] == ["**Prod.** I wanted to show it, but they had tested it already.",
                          "**Priority.** Transactions first; affinity groups wait.", "**Table.** A separate one."]
    assert m["recap_note"] == "Overall no blockers."
    assert m["tldr"] == "The export is merged." and len(m["decisions"]) == 1


def test_notion_page_has_the_recap_under_the_tldr(tmp_path):
    md = tmp_path / "call.md"
    md.write_text("# x\n", encoding="utf-8")
    b = meeting_blocks(parse_meeting(NOTES), md, {}, False, "en")
    kinds = [x["type"] for x in b]
    assert kinds[:6] == ["paragraph", "heading_3", "numbered_list_item", "numbered_list_item", "numbered_list_item", "paragraph"]
    assert b[1]["heading_3"]["rich_text"][0]["text"]["content"] == "What happened"
    bold = [r for r in b[2]["numbered_list_item"]["rich_text"] if r.get("annotations", {}).get("bold")]
    assert bold and bold[0]["text"]["content"] == "Prod."
