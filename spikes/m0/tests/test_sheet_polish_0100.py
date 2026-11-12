"""0.10.0 (Meeting Sheet, polish): a not_found fact whose text is only "Not found" is not doubled in the derived brief.
Every fixture is invented (Emily Parker, Lumenfield)."""
from livetips_m0.sheet import derive as D


def _sheet(text):
    return {"version": 1, "title": "Intro with Emily Parker", "language": "en", "sources": [],
            "blocks": [{"id": "qualification", "type": "qualification", "title": "Qualification", "visible": True,
                        "only_if_data": False, "order": 0, "edited_by_user": False,
                        "facts": [{"id": "q1", "label": "Budget", "text": text, "source_ids": [],
                                   "status": "not_found", "origin": "model"}]}]}


def test_placeholder_text_is_not_repeated():
    for t in ("Not found", "not found.", "", "  Not Found "):
        md = D.render_md(_sheet(t))
        line = next(l for l in md.splitlines() if "Budget" in l)
        assert line == "- **Budget:** Not found", (t, line)
        assert "Not found: Not found" not in md


def test_real_text_stays_after_the_status():
    md = D.render_md(_sheet("No budget mentioned in the notes"))
    assert "- **Budget:** Not found: No budget mentioned in the notes" in md


def test_is_placeholder():
    assert D.is_placeholder("Not found") and D.is_placeholder("Не знайдено") and D.is_placeholder(None)
    assert not D.is_placeholder("Budget is 20K")
