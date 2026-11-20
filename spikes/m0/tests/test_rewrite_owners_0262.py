"""0.26.2 (speakers on the call page, B3): Rewrite notes after the PM fixed the speakers. The owners of this call's
untouched register items follow the new names (commitments.migrate_owners), so the rewritten notes do not add twins."""
import json

from livetips_m0 import callnotes
from livetips_m0 import commitments as C

CALL = "2026-11-15-1000-orbit-weekly.app.md"
OLD = """## Meeting notes
### TL;DR
Pilot.
### Action items
- [10:06:29] **Speaker 2**: send the test accounts (due: Friday)
- [10:07:00] **Speaker 3**: check the export on staging
- [10:08:00] **Mike**: book the review room
### Topics
"""
NEW = """## Meeting notes
### TL;DR
Pilot.
### Action items
- [10:06:29] **David Kim**: send the test accounts (due: Friday)
- [10:07:00] **David Kim**: check the export on staging
- [10:08:00] **Emily**: book the review room
### Topics
"""


def first(folder):
    C.record_notes(folder, call=CALL, notes=OLD, aliases=["Mike Johnson"])
    return {i["text"]: i for i in C.load(folder)}


def test_untouched_items_follow_the_new_names(tmp_path):
    first(tmp_path)
    ev = C.migrate_owners(tmp_path, call=CALL, notes=NEW, aliases=["Mike Johnson"])
    assert all(e["op"] == "edit" and e["source"] == "rewrite" for e in ev)
    C.record_notes(tmp_path, call=CALL, notes=NEW, aliases=["Mike Johnson"])
    items = C.load(tmp_path)
    got = sorted((i["owner"], i["text"]) for i in items)
    assert got == [("David Kim", "check the export on staging"), ("David Kim", "send the test accounts"),
                   ("Emily", "book the review room")]       # renamed, merged, and a line the PM said was Emily's
    assert len(items) == 3                                   # no twins under the old names


def test_the_pms_own_edits_and_ticks_stay(tmp_path):
    items = first(tmp_path)
    C.append(tmp_path, [{"op": "edit", "id": items["send the test accounts"]["id"], "at": C.now_iso(), "due": "Monday"}])
    C.mark(tmp_path, items["check the export on staging"]["id"], "done")
    C.migrate_owners(tmp_path, call=CALL, notes=NEW, aliases=["Mike Johnson"])
    by = {i["text"]: i for i in C.load(tmp_path)}
    assert by["send the test accounts"]["owner"] == "Speaker 2"         # the PM touched it
    assert by["check the export on staging"]["owner"] == "Speaker 3"    # done: not open
    assert by["book the review room"]["owner"] == "Emily"


def test_a_tick_from_the_call_window_stays_the_pms(tmp_path):
    C.record_call(tmp_path, call=CALL, project="orbit", title="Orbit weekly",
                  actions=[{"what": "Book the review room", "t": "10:08:00"}], theirs=[])
    C.migrate_owners(tmp_path, call=CALL, notes=NEW, aliases=["Mike Johnson"])
    assert [i["owner"] for i in C.load(tmp_path)] == ["me"]


def test_same_owner_or_another_call_is_left_alone(tmp_path):
    first(tmp_path)
    C.record_notes(tmp_path, call="2026-11-16-1000-orbit-weekly.app.md", notes=OLD, aliases=["Mike Johnson"])
    assert C.migrate_owners(tmp_path, call=CALL, notes=OLD, aliases=["Mike Johnson"]) == []
    ev = C.migrate_owners(tmp_path, call=CALL, notes=NEW, aliases=["Mike Johnson"])
    assert len(ev) == 3
    other = [i for i in C.load(tmp_path) if i["call"].startswith("2026-11-16")]
    assert sorted(i["owner"] for i in other) == ["Speaker 2", "Speaker 3", "me"]


def test_rewrite_flag_writes_the_full_notes_over_the_old_ones(tmp_path, monkeypatch):
    md = tmp_path / CALL
    md.write_text("# Live transcript\n[10:00:00] Me: hi\n", encoding="utf-8")
    notes = tmp_path / CALL.replace(".md", ".notes.md")
    notes.write_text("old", encoding="utf-8")
    seen = {}

    def fake(m, model, lang, aliases=None, config="", rewrite=False, provider=None):
        seen["rewrite"] = rewrite
        return {"ok": True, "path": str(notes), "coverage": "", "cost_usd": 0.1, "parts": 1, "error": None}

    monkeypatch.setattr(callnotes, "make_notes", fake)
    monkeypatch.setattr(callnotes, "make_meeting_only", lambda *a, **k: {"ok": False, "error": "meeting only"})
    monkeypatch.setattr(callnotes.call_layout, "place", lambda name, folder: folder / name)
    assert callnotes.main(["--md", str(md), "--rewrite", "--meeting"]) == 0
    assert seen == {"rewrite": True}
    seen.clear()
    assert callnotes.main(["--md", str(md)]) == 0
    assert seen == {"rewrite": False}


def test_register_tasks_migrates_only_on_rewrite(tmp_path):
    first(tmp_path)
    md = tmp_path / CALL
    callnotes._register_tasks(md, NEW, ["Mike Johnson"])
    assert len(C.load(tmp_path)) == 6                        # without --rewrite: the old way (twins)
    json.dumps(C.load(tmp_path))
