"""Unit checks for the mirror's helpers (pinned before the ub-mode split). Synthetic data only."""
import io
import json
import os
import types
import urllib.error

import pytest

import mirror as M
from fake_notion import dashed, uid


def test_prop_value_every_type():
    users = {dashed(uid(5)): "Ann"}
    titles = {dashed(uid(6)): "Linked"}
    cases = [
        ({"type": "title", "title": [{"plain_text": "T"}]}, "T"), ({"type": "rich_text", "rich_text": []}, ""),
        ({"type": "select", "select": {"name": "S"}}, "S"), ({"type": "status", "status": None}, None),
        ({"type": "multi_select", "multi_select": [{"name": "a"}]}, ["a"]), ({"type": "multi_select", "multi_select": None}, []),
        ({"type": "date", "date": None}, None), ({"type": "date", "date": {"start": "2026-10-01", "end": "2026-10-02"}}, "2026-10-01/2026-10-02"),
        ({"type": "relation", "relation": [{"id": dashed(uid(6))}, {"id": "x"}]}, ["Linked", "x"]),
        ({"type": "people", "people": [{"name": "N"}, {"id": dashed(uid(5))}, {"id": "zz"}]}, ["N", "Ann", "zz"]),
        ({"type": "number", "number": 3}, 3), ({"type": "checkbox", "checkbox": True}, True), ({"type": "url", "url": "u"}, "u"),
        ({"type": "created_time", "created_time": "t"}, "t"),
        ({"type": "created_by", "created_by": {"id": dashed(uid(5))}}, "Ann"), ({"type": "last_edited_by", "last_edited_by": None}, None),
        ({"type": "formula", "formula": {"type": "string", "string": "f"}}, "f"), ({"type": "formula", "formula": None}, None),
        ({"type": "rollup", "rollup": None}, None), ({"type": "rollup", "rollup": {"type": "number", "number": 2}}, 2),
        ({"type": "rollup", "rollup": {"type": "array", "array": [{"type": "number", "number": 1}]}}, [1]),
        ({"type": "unique_id", "unique_id": {"prefix": "T", "number": 7}}, "T-7"), ({"type": "unique_id", "unique_id": {"number": 7}}, 7),
        ({"type": "files", "files": [{"name": "a.pdf"}]}, ["a.pdf"]), ({"type": "button", "button": {}}, None)]
    for p, want in cases:
        assert M.prop_value(p, titles, users) == want, p
    assert M.prop_value({"type": "people", "people": [{"id": "q"}]}, {}) == ["q"]


def test_first_date_and_row_filename():
    pg = {"id": dashed(uid(9)), "created_time": "2026-09-01T00:00:00Z",
          "properties": {"Reply by": {"type": "date", "date": {"start": "2026-01-01"}}, "Due": {"type": "date", "date": {"start": "2026-02-02"}},
                         "Name": {"type": "title", "title": [{"plain_text": "A/B: c 2026-10-01T15:00:00.000+03:00"}]}}}
    assert M.first_date(pg, ["Missing", "Due"]) == "2026-02-02" and M.first_date(pg) == "2026-02-02"
    assert M.first_date({"created_time": "2026-09-01T00:00:00Z", "properties": {"X": {"type": "date", "date": None}}}) == "2026-09-01"
    assert M.row_filename("meetings", pg, {}) == os.path.join("meetings", "2026-02-02 A B c [%s].md" % uid(9))


def test_render_truncated_with_children():
    pg = {"id": dashed(uid(1)), "url": "u", "created_time": "c", "last_edited_time": "e",
          "properties": {"Name": {"type": "title", "title": [{"plain_text": "P"}]}, "Empty": {"type": "rich_text", "rich_text": []}}}
    out = M.render(pg, "reports", {}, "Body<br>two", True, [("Child", "inside")], ["transcript: present"])
    assert "truncated: true" in out and "transcript: present" in out and "## [child page] Child" in out and "Body\ntwo" in out
    assert '"Empty"' not in out and out.endswith("inside\n")


def test_resolver_lookups():
    calls = []

    def lookup(pid):
        calls.append(pid)
        if pid == "boom":
            raise RuntimeError("x")
        return "Found" if pid == "ok" else None
    rs = M.Resolver({"known": "K"}, {}, {"cached": "C"}, lookup, max_lookups=3)
    assert rs.page_title(None) is None and rs.page_title("known") == "K" and rs.page_title("cached") == "C"
    assert rs.page_title("ok") == "Found" and rs.page_title("ok") == "Found" and rs.page_title("boom") is None
    assert rs.page_title("none") is None and rs.page_title("none") is None and rs.page_title("more") is None
    assert calls == ["ok", "boom", "none"] and rs.lookups == 3
    txt = rs.text('<mention-date start="2026-10-01" end="2026-10-02T10:00"/> <mention-date x="1"/> '
                  '<mention-user url="user://%s"/>' % dashed(uid(3)))
    assert txt.startswith("2026-10-01 → 2026-10-02 10:00 <mention-date") and "@user-" + uid(3)[:8] in txt
    assert M.resolve_mentions("a<br/>b", {}) == "a\nb"


def test_find_orphans_and_parse_configs(tmp_path):
    top = tmp_path / "w" / "_notion"
    (top / "tasks").mkdir(parents=True)
    (top / "_archived").mkdir()
    for f in ("tasks/a.md", "tasks/b.md", "tasks/c.txt", "_archived/old.md", "INDEX.md"):
        (top / f).write_text("x")
    out = M.find_orphans([str(tmp_path / "w"), str(tmp_path / "none")], [str(top / "tasks" / "a.md"), None])
    assert [os.path.basename(p) for _, p in out] == ["b.md"]
    cfgs = tmp_path / "projects"
    cfgs.mkdir()
    (cfgs / "demo.md").write_text("- **project_page_id**: `%s`\n- **project_root**: `/w/Demo/` (folder)\n" % dashed(uid(4)))
    (cfgs / "_template.md").write_text("- **project_page_id**: `%s`\n- **project_root**: `/x`\n" % uid(5))
    (cfgs / "notes.txt").write_text("")
    (cfgs / "partial.md").write_text("- **project_page_id**: `%s`\n" % uid(6))
    assert M.parse_configs(str(cfgs)) == {dashed(uid(4)): "/w/Demo"} and M.parse_configs(None) == {}


def test_read_secret_and_token(tmp_path, monkeypatch):
    f = tmp_path / "s.env"
    f.write_text("# x\nexport A_TOKEN='abc'\nB=\"q\"\nC=v\n")
    assert M.read_secret(str(f), "A_TOKEN") == "abc" and M.read_secret(str(f), "B") == "q" and M.read_secret(str(f), "C") == "v"
    with pytest.raises(SystemExit):
        M.read_secret(str(f), "NOPE")
    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    assert M.get_token({"secrets_file": str(f), "token_env": "C"}) == "v"
    with pytest.raises(SystemExit):
        M.get_token({})


class Resp:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return json.dumps(self.body).encode()


def http_error(code, retry_after=None):
    return urllib.error.HTTPError("u", code, "x", {"Retry-After": retry_after} if retry_after else {}, io.BytesIO(b"detail"))


def test_req_retries_and_errors(monkeypatch):
    waits = []
    monkeypatch.setattr(M.time, "sleep", waits.append)
    script = [http_error(429, "3"), http_error(503), Resp({"ok": 1})]

    def urlopen(r, timeout, context):
        x = script.pop(0)
        if isinstance(x, Exception):
            raise x
        return x
    monkeypatch.setattr(M.urllib.request, "urlopen", urlopen)
    api = M.Notion("tok", "v1", None, 0.0)
    assert api.req("GET", "/users/me") == {"ok": 1} and api.calls == 3 and waits == [0.0, 3.0, 0.0, 2, 0.0]
    script[:] = [http_error(400)]
    with pytest.raises(M.NotionError) as e:
        api.req("GET", "/x")
    assert e.value.code == 400 and "detail" in str(e.value)
    script[:] = [urllib.error.URLError("down")] * 6
    with pytest.raises(M.NotionError) as e:
        api.req("GET", "/x")
    assert e.value.code == 0
    script[:] = [http_error(500)] * 6
    with pytest.raises(M.NotionError) as e:
        api.req("GET", "/x")
    assert "retries exhausted" in str(e.value)


def test_markdown_fallbacks(monkeypatch):
    api = M.Notion("tok", "v1", "v2", 0.0)
    seen = []

    def req(method, path, body=None, version=None):
        seen.append((path, version))
        if "include_transcript" in path:
            raise M.NotionError(400, "bad param")
        if path.endswith("/markdown") and "p2" in path:
            raise M.NotionError(403, "no access")
        if path.endswith("/markdown") and "p3" in path:
            return {"markdown": None}
        if "/blocks/" in path:
            return {"results": [{"type": "paragraph", "paragraph": {"rich_text": [{"plain_text": "from blocks"}]}}]}
        return {"markdown": "md", "truncated": True}
    monkeypatch.setattr(api, "req", req)
    assert api.markdown("p1", transcript=True) == ("md", True) and seen[1] == ("/pages/p1/markdown", "v2")
    with pytest.raises(M.NotionError):
        api.markdown("p2")
    assert api.markdown("p3") == ("from blocks", False)


def test_block_lines_more_types():
    api = M.Notion("t", "v", None, 0.0)
    b = lambda t, **v: {"type": t, t: dict({"rich_text": [{"plain_text": "x"}]}, **v)}  # noqa: E731
    lines = []
    for blk in (b("numbered_list_item"), b("quote"), b("toggle"), b("callout"), b("to_do", checked=False),
                {"id": dashed(uid(8)), "type": "child_page", "child_page": {"title": "Kid"}},
                {"type": "bookmark", "bookmark": {"url": "https://b"}}, {"type": "file", "file": {"caption": [{"plain_text": "cap"}]}},
                {"type": "empty_thing", "empty_thing": {}}):
        lines += api.block_lines(blk, 1)
    assert lines == ["  1. x", "  > x", "  - x", "  > x", "  - [ ] x",
                     '<page url="https://app.notion.com/p/%s">Kid</page>' % uid(8), "  https://b", "  [file: cap]"]


def test_discover(tmp_path, monkeypatch, capsys):
    cfgp = tmp_path / "c.json"
    monkeypatch.setattr(M, "CONFIG_PATH", str(cfgp))
    monkeypatch.setenv("NOTION_TOKEN", "t")
    pages = [{"results": [{"id": "ds-tasks", "title": [{"plain_text": "Tasks Tracker"}], "last_edited_time": "1"},
                          {"id": "ds-proj-old", "title": [{"plain_text": "Projects"}], "last_edited_time": "1"}],
              "has_more": True, "next_cursor": "c2"},
             {"results": [{"id": "ds-proj-new", "title": [{"plain_text": "\U0001f4c1 Projects"}], "last_edited_time": "2"},
                          {"id": "ds-x", "title": [{"plain_text": "Unrelated"}]}], "has_more": False}]
    bodies = []
    monkeypatch.setattr(M.Notion, "req", lambda self, m, p, body=None, version=None: (bodies.append(dict(body)), pages[len(bodies) - 1])[1])
    cfg = {"work_root": str(tmp_path)}
    assert M.discover(cfg) == 0
    saved = json.loads(cfgp.read_text())
    assert saved["projects_ds"] == "ds-proj-new" and saved["databases"] == {"tasks": "ds-tasks"} and bodies[1]["start_cursor"] == "c2"
    out = capsys.readouterr().out
    assert "2 data sources named 'projects'" in out and "not found" in out
    bodies.clear()
    pages[:] = [{"results": [], "has_more": False}]
    with pytest.raises(SystemExit):
        M.discover(cfg)


def test_guarded_main_writes_failed_status(tmp_path, monkeypatch):
    cfgp = tmp_path / "c.json"
    cfgp.write_text(json.dumps({"work_root": str(tmp_path / "w")}))
    monkeypatch.setattr(M, "CONFIG_PATH", str(cfgp))
    monkeypatch.setattr(M, "LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.setattr(M, "LOG_PATH", str(tmp_path / "logs" / "m.log"))
    monkeypatch.setattr(M, "main", lambda: 1 / 0)
    assert M.guarded_main() == 1
    assert "result: FAILED" in (tmp_path / "w" / "_notion" / "MIRROR_STATUS.md").read_text()
    monkeypatch.setattr(M, "main", lambda: (_ for _ in ()).throw(SystemExit(3)))
    with pytest.raises(SystemExit):
        M.guarded_main()
    monkeypatch.setattr(M, "main", lambda: 0)
    assert M.guarded_main() == 0


def test_selftest_passes(monkeypatch):
    assert M.selftest() == 0
