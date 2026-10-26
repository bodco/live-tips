"""wrapup_notion.schema: any Meetings database works (2026-10-26)."""
from livetips_m0 import wrapup_notion as w


def run(props):
    w.notion = lambda method, path, body=None: {"properties": props}
    return w.schema("ds")


def test_control_tower_schema():
    s = run({"Meeting Name": {"type": "title"}, "Date": {"type": "date"}, "Summary": {"type": "rich_text"},
             "Project": {"type": "relation"}, "Workspace": {"type": "relation"}})
    assert s == {"title": "Meeting Name", "date": "Date", "summary": "Summary",
                 "project": ("Project", "relation"), "workspace": ("Workspace", "relation")}


def test_bare_database():
    s = run({"Name": {"type": "title"}, "When": {"type": "date"}, "Tags": {"type": "multi_select"}})
    assert s["title"] == "Name" and s["date"] == "When" and s["summary"] is None and s["project"] is None


def test_no_date_never_searches():
    s = run({"Name": {"type": "title"}})
    assert s["date"] is None
    assert w.find_page("ds", None, s["date"]) is None
