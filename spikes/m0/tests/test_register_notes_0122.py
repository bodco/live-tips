"""0.12.2 (L4): the Meeting notes' Action items complete the commitments register (commitments.record_notes)."""
from livetips_m0 import commitments as C
from livetips_m0.callnotes import _register_tasks

CALL = "2026-11-15-1000-orbit-weekly.app.md"
NOTES = """## Meeting notes
### TL;DR
Pilot.
### Action items
- [10:05:00] **Mike**: send the pilot deck to David (due: Monday)
- [10:06:29] **David Kim**: send the test accounts (due: Friday)
- [10:07:00] **Emily:** check the export on staging
- [10:08:00] Book the review room
- None
### Topics
"""


def live(folder):
    C.record_call(folder, call=CALL, project="orbit", title="Orbit weekly",
                  actions=[{"what": "Send the pilot deck to David", "t": "10:05:00"}],
                  theirs=[{"who": "David", "what": "Send the test accounts", "t": "10:06:30"}])


def test_notes_complete_the_register(tmp_path):
    live(tmp_path)
    ev = C.record_notes(tmp_path, call=CALL, notes=NOTES, aliases=["Mike Johnson"])
    items = C.load(tmp_path)
    texts = [(i["owner"], i["text"], i["due"]) for i in items]
    assert ("me", "Send the pilot deck to David", "Monday") in texts            # twin: kept, due taken from the notes
    assert ("David", "Send the test accounts", "Friday") in texts               # "David Kim" is David
    assert ("Emily", "check the export on staging", "") in texts
    assert ("me", "Book the review room", "") in texts                          # nobody named: the PM
    assert len(items) == 4
    assert all(e.get("source") == "notes" for e in ev)
    assert all(i["project"] == "orbit" and i["series"] == C.series_key("orbit", "Orbit weekly") for i in items)


def test_again_adds_nothing(tmp_path):
    live(tmp_path)
    C.record_notes(tmp_path, call=CALL, notes=NOTES, aliases=["Mike Johnson"])
    assert C.record_notes(tmp_path, call=CALL, notes=NOTES, aliases=["Mike Johnson"]) == []


def test_the_pms_drop_and_edit_win(tmp_path):
    live(tmp_path)
    items = {i["owner"]: i for i in C.load(tmp_path)}
    C.mark(tmp_path, items["David"]["id"], "drop")
    C.append(tmp_path, [{"op": "edit", "id": items["me"]["id"], "at": C.now_iso(), "text": "Deck to David", "due": "Tuesday"}])
    C.record_notes(tmp_path, call=CALL, notes=NOTES, aliases=["Mike"])
    by = {(i["owner"], i["status"]): i for i in C.load(tmp_path)}
    assert by[("David", "dropped")] and ("David", "open") not in by          # not added again
    assert by[("me", "open")]["text"] in ("Deck to David", "Book the review room")
    mine = [i for i in C.load(tmp_path) if i["owner"] == "me"]
    assert {i["text"] for i in mine} == {"Deck to David", "Book the review room"}
    assert next(i for i in mine if i["text"] == "Deck to David")["due"] == "Tuesday"   # the PM's due stays


def test_notes_task_reading():
    assert C.notes_task("**Mike**: send it (due: Friday)") == {"owner": "Mike", "what": "send it", "due": "Friday"}
    assert C.notes_task("**Emily:** check (до: п'ятниці)") == {"owner": "Emily", "what": "check", "due": "п'ятниці"}
    assert C.notes_task("Book the room") == {"owner": "", "what": "Book the room", "due": ""}


def test_without_live_register_and_hook(tmp_path):
    md = tmp_path / CALL
    md.write_text("# t\n", encoding="utf-8")
    _register_tasks(md, NOTES, ["Mike"])
    items = C.load(tmp_path)
    assert len(items) == 4 and items[0]["series"] == C.series_key("", "orbit weekly")
