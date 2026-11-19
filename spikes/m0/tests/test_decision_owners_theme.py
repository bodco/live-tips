"""Theme pass stage 2: owners next to decisions (call_lists.decision_items, the one rule, decision_notion)."""
from livetips_m0 import call_lists as C

NOTES = ("# Call notes\n\n## Meeting notes\n\n### TL;DR\nShort.\n\n### Decisions\n"
         "- [13:25:00] **Emily Clark**: The export goes to production on Tue, Nov 24.\n"
         "- [13:40:00] **Emily Clark, you**: CSV download goes through a change request.\n"
         "- [13:41:00] **Go with plan B**\n- Keep the deposit at 20 euros\n- None\n")


def test_notes_owner():
    r = C.resolve([], NOTES)
    assert r["decisions_from"] == "notes"
    assert [(i["text"], i["by"]) for i in r["decision_items"]] == [
        ("The export goes to production on Tue, Nov 24.", "Emily Clark"),
        ("CSV download goes through a change request.", "Emily Clark, you"),
        ("Go with plan B", ""), ("Keep the deposit at 20 euros", "")]
    assert r["decisions"][0] == "The export goes to production on Tue, Nov 24."
    assert r["decision_items"][0]["t"] == "13:25:00"


def test_pm_edit_owners_and_live_dicts():
    pm = {"kind": "situation", "source": "call_page", "lists": ["decisions"],
          "decisions": ["Ship Tuesday", "Ship Tuesday", "Hold the price"], "decision_owners": ["Mike", "Mike", ""]}
    r = C.resolve([pm], None)
    assert [(i["text"], i["by"]) for i in r["decision_items"]] == [("Ship Tuesday", "Mike"), ("Hold the price", "")]
    live = {"kind": "situation", "decisions": [{"what": "Pilot starts Monday", "who": "David Kim"}, "Old style line"]}
    r = C.resolve([live], None)
    assert [(i["text"], i["by"]) for i in r["decision_items"]] == [("Pilot starts Monday", "David Kim"), ("Old style line", "")]


def test_old_notes_still_read():
    r = C.resolve([], "## Meeting notes\n\n### Decisions\n- [10:01:00] Go with plan B\n")
    assert [(i["text"], i["by"]) for i in r["decision_items"]] == [("Go with plan B", "")]
