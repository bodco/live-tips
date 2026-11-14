"""0.10.1 (A3): a moved call's Notion pages: Project and Workspace overwritten in place, another database left alone."""
import json

from livetips_m0 import notion_move as nm
from livetips_m0 import wrapup_notion as wn

DS_A = "11111111111111111111111111111111"
DS_B = "22222222222222222222222222222222"
PAGE = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PROPS = {"Name": {"type": "title"}, "Date": {"type": "date"},
         "Project": {"type": "relation"}, "Workspace": {"type": "select"}}


class FakeNotion:
    def __init__(self, parent_ds):
        self.parent, self.calls = parent_ds, []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "GET" and path.startswith("/pages/"):
            return {"id": PAGE, "url": "https://www.notion.so/x-" + PAGE, "parent": {"data_source_id": self.parent}}
        if method == "GET" and path.startswith("/data_sources/"):
            return {"properties": PROPS}
        return {}


def run(monkeypatch, capsys, fake, argv):
    monkeypatch.setattr(nm, "notion", fake)
    monkeypatch.setattr(wn, "notion", fake)
    nm.main(argv)
    return json.loads(capsys.readouterr().out.strip().splitlines()[-1])


def test_page_id_from_url_and_id():
    assert nm.page_id("https://www.notion.so/Weekly-" + PAGE + "?pvs=4") == PAGE
    assert nm.page_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") == PAGE
    assert nm.page_id("") == ""


def test_overwrite_sets_and_clears():
    ids = {"project_page_id": "p1,p2"}
    out = nm.overwrite(PROPS, ids, "Orbit", "")
    assert out["Project"] == {"relation": [{"id": "p1"}, {"id": "p2"}]}
    assert out["Workspace"] == {"select": None}          # the new target has no workspace value: cleared


def test_same_database_rewrites_in_place(monkeypatch, capsys):
    fake = FakeNotion(DS_A)
    r = run(monkeypatch, capsys, fake, ["--kind", "meetings", "--page", PAGE, "--meetings-db", DS_A,
                                        "--project-page", "p9", "--workspace-value", "Bodco"])
    assert r["ok"] and r["updated"] == 1 and not r.get("other_db")
    patch = [c for c in fake.calls if c[0] == "PATCH"]
    assert patch == [("PATCH", f"/pages/{PAGE}", {"properties": {"Project": {"relation": [{"id": "p9"}]},
                                                                 "Workspace": {"select": {"name": "Bodco"}}}})]
    assert not any(c[0] == "POST" for c in fake.calls)    # no new page


def test_other_database_changes_nothing(monkeypatch, capsys):
    fake = FakeNotion(DS_B)
    r = run(monkeypatch, capsys, fake, ["--kind", "meetings", "--page", PAGE, "--meetings-db", DS_A, "--project-page", "p9"])
    assert r["ok"] and r["other_db"] and r["updated"] == 0
    assert not any(c[0] in ("PATCH", "POST") for c in fake.calls)


def test_items_from_notion_json(monkeypatch, capsys, tmp_path):
    md = tmp_path / "2026-11-14-1000-weekly.app.md"
    md.write_text("# Live transcript: Weekly\n", encoding="utf-8")
    (tmp_path / "2026-11-14-1000-weekly.app.notion.json").write_text(json.dumps(
        {"decisions": {"use plan b": {"id": PAGE, "url": ""}}, "risks": {}}), encoding="utf-8")
    fake = FakeNotion(DS_A)
    r = run(monkeypatch, capsys, fake, ["--kind", "decisions", "--md", str(md), "--project-page", "p9"])
    assert r["ok"] and r["updated"] == 1
    r = run(monkeypatch, capsys, fake, ["--kind", "risks", "--md", str(md), "--project-page", "p9"])
    assert r["ok"] and r["updated"] == 0


def test_moved_to_appends_one_paragraph(monkeypatch, capsys):
    fake = FakeNotion(DS_A)
    r = run(monkeypatch, capsys, fake, ["--moved-to", "https://www.notion.so/new", "--page", PAGE, "--lang", "uk"])
    assert r["ok"]
    (m, path, body), = [c for c in fake.calls if c[0] == "PATCH"]
    assert path == f"/blocks/{PAGE}/children" and len(body["children"]) == 1
