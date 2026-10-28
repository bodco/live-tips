"""wrapup_notion.main end to end with a fake Notion, a fake `lt wrapup-data` and a fake model (pinned before the split)."""
import json
import types

import pytest

from livetips_m0 import wrapup_notion as W

PROPS = {"Name": {"type": "title"}, "Date": {"type": "date"}, "Summary": {"type": "rich_text"},
         "Project": {"type": "select"}, "Workspace": {"type": "relation"}}


@pytest.fixture
def call(tmp_path, monkeypatch):
    md = tmp_path / "2026-10-01-1000-weekly.md"
    md.write_text("# Live transcript: Weekly sync\n- Start: 2026-10-01 10:00:00\n- Languages: Me = en, allowed = en\n\n"
                  "[10:00:01] Me (en): hello\n")
    clean = tmp_path / "clean.md"
    clean.write_text("\n".join("[10:00:0{}] Me (en): line \\*{}".format(i, i) for i in range(6)))
    (tmp_path / "2026-10-01-1000-weekly.brief.md").write_text("The brief")
    (tmp_path / "2026-10-01-1000-weekly.edits.jsonl").write_text(json.dumps({"action": "onme_add", "after": {"text": "Send deck"}}) + "\n")
    cfg = tmp_path / "proj.md"
    cfg.write_text("- **meetings_db**: `collection://ds1`\n- **workspace_page_id**: `ws1`\n")
    stats = {"transcript": {"clean_file": str(clean), "lines_real": 6, "langs": {"en": 6}}, "tips": {"shown": 2}}
    monkeypatch.setattr(W.subprocess, "run", lambda *a, **k: types.SimpleNamespace(stdout="log\n" + json.dumps(stats)))
    seen = {}

    def wrap(plain, brief, model, lang):
        seen.update(plain=plain, brief=brief, lang=lang)
        return {"name": "Release plan", "summary": "We agreed.", "decisions": ["Ship Friday"], "_cost": 0.02}
    monkeypatch.setattr(W, "claude_wrapup", wrap)
    monkeypatch.setenv("LT_LEDGER", str(tmp_path / "spend.json"))
    calls, state = [], {"pages": []}

    def notion(method, path, body=None):
        calls.append((method, path, body))
        if path == "/data_sources/ds1":
            return {"properties": PROPS}
        if path.endswith("/query"):
            return {"results": state["pages"]}
        if method == "POST" and path == "/pages":
            return {"id": "p%d" % len(calls), "url": "https://notion.so/new"}
        return {}
    monkeypatch.setattr(W, "notion", notion)
    base = ["--md", str(md), "--project-config", str(cfg), "--lt", "py", "lt", "--project-name", "Demo"]
    return types.SimpleNamespace(md=md, base=base, calls=calls, state=state, seen=seen, tmp=tmp_path)


def out(capsys):
    return json.loads(capsys.readouterr().out.strip().splitlines()[-1])


def test_new_page(call, capsys):
    assert W.main(call.base + ["--when", "2026-10-01T09:30:00+00:00"]) == 0
    res = out(capsys)
    assert res["ok"] and res["created"] and res["url"] == "https://notion.so/new" and res["cost_usd"] == 0.02
    assert "line *1" in call.seen["plain"] and call.seen["brief"].startswith("CORRECTIONS BY THE PM") and call.seen["lang"] == "en"
    page = [c for c in call.calls if c[0] == "POST" and c[1] == "/pages"][0][2]
    props = page["properties"]
    assert props["Name"]["title"][0]["text"]["content"] == "Weekly sync: Release plan "
    assert props["Date"]["date"]["start"].startswith("2026-10-01T")
    assert props["Summary"]["rich_text"][0]["text"]["content"] == "We agreed."
    assert props["Project"] == {"select": {"name": "Demo"}} and props["Workspace"] == {"relation": [{"id": "ws1"}]}
    assert page["parent"] == {"type": "data_source_id", "data_source_id": "ds1"}
    kinds = [b["type"] for b in page["children"]]
    assert kinds[0] == "heading_2" and "bulleted_list_item" in kinds and kinds[-1] == "heading_2"
    assert json.loads((call.tmp / "spend.json").read_text())
    tp = [c for c in call.calls if c[0] == "POST" and c[1] == "/pages"][1][2]
    assert tp["parent"]["type"] == "page_id" and tp["properties"]["title"]["title"][0]["text"]["content"].startswith("Transcript · Weekly sync: Release plan")
    assert call.calls[-1][0] == "PATCH" and call.calls[-1][2]["children"][0]["type"] == "divider"


def test_existing_page(call, capsys):
    call.state["pages"] = [{"id": "far", "url": "u-far", "properties": {"Date": {"date": {"start": "2026-10-01T12:00:00+00:00"}}}},
                           {"id": "near", "url": "u-near", "properties": {"Date": {"date": {"start": "2026-10-01T10:05:00"}}},
                            "Project": {"select": {"name": "x"}}},
                           {"id": "bad", "properties": {}}]
    assert W.main(call.base + ["--title", "Renamed"]) == 0
    res = out(capsys)
    assert res["ok"] and not res["created"]
    patches = [c for c in call.calls if c[0] == "PATCH"]
    target = patches[0][1].split("/")[2]
    assert patches[0][1] == "/pages/" + target and set(patches[0][2]["properties"]) == {"Project", "Workspace"}
    assert patches[1][1] == "/blocks/" + target + "/children" and patches[1][2]["children"][0]["type"] == "heading_2"
    tp = [c for c in call.calls if c[0] == "POST" and c[1] == "/pages"][0][2]
    assert tp["properties"]["title"]["title"][0]["text"]["content"].endswith("Renamed")


def test_dry_run_find_only_and_errors(call, capsys, tmp_path, monkeypatch):
    assert W.main(call.base + ["--dry-run"]) == 0
    res = out(capsys)
    assert res["dry_run"] and res["name"] == "Release plan" and res["ids"]["meetings_db"] == "ds1"
    assert W.main(call.base + ["--find-only"]) == 0
    assert out(capsys) == {"ok": True, "found": False, "url": None}
    assert W.main(["--md", str(call.md), "--lt", "py", "lt"]) == 1
    assert "no Meetings database" in out(capsys)["error"]
    assert W.main(["--md", str(call.md), "--lt", "py", "lt", "--meetings-db", "collection://ds1", "--dry-run"]) == 0
    capsys.readouterr()
    monkeypatch.setattr(W.subprocess, "run", lambda *a, **k: types.SimpleNamespace(
        stdout=json.dumps({"transcript": {"clean_file": str(tmp_path / "clean.md"), "lines_real": 2}})))
    assert W.main(call.base) == 1 and "fewer than 5" in out(capsys)["error"]


def test_pm_corrections(tmp_path):
    f = tmp_path / "e.jsonl"
    rows = [{"action": "onme_add", "after": {"text": "A"}}, {"action": "onme_remove", "before": {"text": "B"}},
            {"action": "onme_edit", "before": {"text": "C"}, "after": {"text": "D"}}, {"action": "remove", "before": {"gist": "E"}},
            {"action": "edit", "after": {"gist": "F", "phrase": "P", "items": ["x", "y"]}}, {"action": "edit", "after": {"gist": "G"}},
            {"action": "other"}, [1, 2]]
    f.write_text("\n".join(json.dumps(r) for r in rows) + "\nbad\n")
    lines = W.pm_corrections(f).splitlines()[3:]
    assert lines == ["- On the PM (added by the PM): A", "- NOT on the PM (removed by the PM): B",
                     '- Corrected by the PM: "C" is really "D"', "- Wrong or irrelevant (removed by the PM): E",
                     "- Corrected by the PM: F (P): x; y", "- Corrected by the PM: G"]
    assert W.pm_corrections(tmp_path / "none") == ""
    f.write_text(json.dumps({"action": "other"}))
    assert W.pm_corrections(f) == ""


def test_retry_later(monkeypatch):
    waits = []
    monkeypatch.setattr(W.time, "sleep", waits.append)
    assert W.retry_later(429, 0) and W.retry_later(529, 2) and not W.retry_later(529, 3) and not W.retry_later(400, 0)
    assert waits == [2, 8]


def test_action_line_and_pacenote_blocks(tmp_path):
    assert W.action_line({"who": " Ann ", "what": "send", "when": "Fri"}) == "Ann: send (Fri)"
    assert W.action_line({}) == ": "
    b = W.pacenote_blocks({}, tmp_path / "x.md", False, W.TXT["en"])
    assert b[0]["type"] == "heading_3" and "Preparation: none" in b[2]["bulleted_list_item"]["rich_text"][0]["text"]["content"]


def test_http_retries_then_fails(monkeypatch):
    import io
    import urllib.error
    waits, tries = [], []

    def urlopen(req, timeout):
        tries.append(req.get_method())
        if len(tries) == 1:
            raise urllib.error.HTTPError(req.full_url, 429, "busy", {}, io.BytesIO(b"slow down"))
        if len(tries) == 2:
            class R:
                def __enter__(self):
                    return self

                def __exit__(self, *a):
                    return False

                def read(self):
                    return b'{"ok": 1}'
            return R()
        raise urllib.error.HTTPError(req.full_url, 400, "bad", {}, io.BytesIO(b"nope"))
    monkeypatch.setattr(W.urllib.request, "urlopen", urlopen)
    monkeypatch.setattr(W.time, "sleep", waits.append)
    assert W.http("POST", "https://api.notion.com/v1/pages?x=1", {"A": "b"}, {"k": 1}) == {"ok": 1} and waits == [2]
    with pytest.raises(RuntimeError) as e:
        W.http("GET", "https://api.notion.com/v1/pages?x=1", {})
    assert str(e.value) == "GET https://api.notion.com/v1/pages -> 400: nope"


def test_notion_sends_the_token_header(monkeypatch):
    seen = {}
    monkeypatch.setenv("NOTION_TOKEN", "tok")
    monkeypatch.setattr(W, "http", lambda m, url, headers, body=None: seen.update(m=m, url=url, h=headers) or {})
    W.notion("GET", "/users/me")
    assert seen["url"] == W.NOTION + "/users/me" and seen["h"]["Authorization"] == "Bearer tok"
