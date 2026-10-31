"""After-call helpers with fakes: risk to Notion, secrets, rehearsal scores, follow-up picture, one-shot model calls."""
import json
import types

import pytest

from livetips_m0 import oneshot, rehearse, risk_notion, secret_store
from livetips_m0 import wrapup_notion as W
from livetips_m0.providers import Completion


def fake_notion(monkeypatch, props):
    calls = []

    def notion(method, path, body=None):
        calls.append((method, path, body))
        return {"properties": props} if method == "GET" else {"url": "https://notion.so/r", "id": "r1"}
    monkeypatch.setattr(risk_notion, "notion", notion)
    return calls


@pytest.mark.parametrize("ptype,expect", [("relation", {"relation": [{"id": "pp"}]}), ("select", {"select": {"name": "Demo"}}),
                                          ("rich_text", "text"), ("people", None)])
def test_risk_written_with_project_link(tmp_path, monkeypatch, capsys, ptype, expect):
    cfg = tmp_path / "p.md"
    cfg.write_text("**risks_db**: `collection://db1`\n**project_page_id**: `pp`\n")
    calls = fake_notion(monkeypatch, {"Risk": {"type": "title"}, "Project": {"type": ptype}})
    assert risk_notion.main(["--project-config", str(cfg), "--title", "Pilot may slip", "--call", "Weekly, 1 Oct",
                             "--project-name", "Demo"]) == 0
    assert json.loads(capsys.readouterr().out)["url"] == "https://notion.so/r"
    body = calls[-1][2]
    assert body["parent"]["data_source_id"] == "db1" and body["properties"]["Risk"]["title"][0]["text"]["content"] == "Pilot may slip"
    if expect == "text":
        assert body["properties"]["Project"]["rich_text"][0]["text"]["content"] == "Demo"
    elif expect is None:
        assert "Project" not in body["properties"]
    else:
        assert body["properties"]["Project"] == expect
    assert body["children"][0]["paragraph"]["rich_text"][0]["text"]["content"] == "Heard on the call: Weekly, 1 Oct"


def test_risk_without_call_and_a_failing_notion(monkeypatch, capsys):
    calls = fake_notion(monkeypatch, {"Name": {"type": "title"}})
    assert risk_notion.main(["--db", "collection://d2", "--title", "x"]) == 0
    assert calls[-1][2]["children"] == [] and calls[0][1] == "/data_sources/d2"
    capsys.readouterr()
    monkeypatch.setattr(risk_notion, "notion", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("401")))
    assert risk_notion.main(["--db", "d2", "--title", "x"]) == 1 and json.loads(capsys.readouterr().out)["error"] == "401"


def test_secrets(tmp_path, monkeypatch):
    f = tmp_path / "s.env"
    f.write_text("# c\nexport MY_TOKEN = \"abc\"\nOTHER='x'\n")
    monkeypatch.delenv("MY_TOKEN", raising=False)
    assert secret_store.load_secret("MY_TOKEN", str(f)) == "abc" and secret_store.load_secret("OTHER", str(f)) == "x"
    monkeypatch.setenv("MY_TOKEN", " env ")
    assert secret_store.load_secret("MY_TOKEN", str(f)) == "env"
    with pytest.raises(KeyError):
        secret_store.load_secret("NOPE_X", str(f))
    with pytest.raises(KeyError):
        secret_store.load_secret("NOPE_X", str(tmp_path / "missing"))
    with pytest.raises(KeyError):
        secret_store.load_secret("NOPE_X")
    assert secret_store.masked("1234567890") == "...7890" and secret_store.masked("short") == "(set)"


def test_rehearsal_scored():
    assert rehearse.scored({"q": "Q"}, {"score": "9", "feedback": "a" + chr(0x2014) + "b"}) == {"q": "Q", "score": 5, "feedback": "a-b", "better": "", "slide": None}   # 0.8.5: + slide
    assert rehearse.scored({}, {"score": "x"})["score"] == 0 and rehearse.scored({}, {"score": -3})["score"] == 1


def test_followup_picture_lines():
    from livetips_m0.followup import picture_lines
    sit = {"decisions": ["go"], "actions": [{"what": "send", "due": "Fri"}], "theirs": [{"who": "Ann", "what": "deck"}],
           "asks": [{"what": "q"}, {"what": "u", "type": "update"}]}
    assert picture_lines(sit) == ["Decision: go", "PM will: send (Fri)", "Ann will: deck ", "Open: q"]


class Prov:
    def __init__(self, text="", error=None):
        self.text, self.error, self.seen = text, error, {}

    def complete(self, **kw):
        self.seen = kw
        return Completion(model="claude-sonnet-5-5", text=self.text, error=self.error, input_tokens=1000, output_tokens=100)


def test_oneshot_ask_json(monkeypatch, tmp_path):
    obj, usd = oneshot.ask_json("S", "U", "claude-sonnet-5-5", 50, Prov('ok {"a": 1}'))
    assert obj == {"a": 1} and usd and usd > 0
    assert oneshot.ask_json("S", "U", "m", 50, Prov("[1]"))[0] is None
    with pytest.raises(RuntimeError):
        oneshot.ask_json("S", "U", "m", 50, Prov(error="boom"))
    p = Prov('{"b": 2}')
    monkeypatch.setattr(oneshot, "provider_from_env", lambda: p)
    monkeypatch.setenv("LT_LEDGER", str(tmp_path / "spend.json"))
    assert oneshot.ask_json("S", "U", "claude-sonnet-5-5")[0] == {"b": 2}
    assert p.seen["extra"] == {"thinking": {"type": "disabled"}} and (tmp_path / "spend.json").exists()


def test_claude_wrapup_and_find_page(monkeypatch):
    p = Prov('Here: {"name": "N", "summary": "S"} done')
    out = W.claude_wrapup("T", "B", "claude-sonnet-5-5", "en", provider=p)
    assert out["name"] == "N" and out["_cost"] and out["_route"] == "api" and "PREP BRIEF" in p.seen["user"]
    assert "PREP BRIEF" not in (W.claude_wrapup("T", "", "m", "uk", provider=p) and p.seen["user"])
    with pytest.raises(RuntimeError):
        W.claude_wrapup("T", "", "m", "uk", provider=Prov(error="x"))
    import datetime as dt
    start = dt.datetime(2026, 10, 1, 10, 0, tzinfo=dt.timezone.utc)
    monkeypatch.setattr(W, "notion", lambda m, path, body=None: {"results": []})
    assert W.find_page("ds", start) is None


def test_upload_md_refuses_a_foreign_host(monkeypatch):
    sent = []
    monkeypatch.setattr(W, "notion", lambda m, path, body=None: {"id": "f1", "upload_url": "https://evil.example/u"})
    monkeypatch.setattr(W, "http", lambda *a, **k: sent.append(a))
    with pytest.raises(RuntimeError):
        W.upload_md("t.md", "text")
    assert sent == []
    monkeypatch.setattr(W, "notion", lambda m, path, body=None: {"id": "f1", "upload_url": "https://api.notion.com/v1/file_uploads/f1/send"})
    assert W.upload_md("t.md", "text") == "f1" and sent and sent[0][1].startswith("https://api.notion.com/")
    assert W.file_block("f1", "t.md")["file"]["file_upload"]["id"] == "f1"


def test_cli_entry_points(tmp_path, monkeypatch, capsys):
    from livetips_m0 import followup, memory
    monkeypatch.setattr(rehearse, "questions", lambda base, lang, model, **k: {"ok": True, "questions": ["Q1"]})
    monkeypatch.setattr(rehearse, "score", lambda base, answers, lang, model: {"ok": True, "n": len(answers)})
    ans = tmp_path / "a.json"
    ans.write_text('[{"q": "Q1", "a": "A"}]')
    assert rehearse.main(["questions", "--base", "b"]) == 0 and json.loads(capsys.readouterr().out)["questions"] == ["Q1"]
    assert rehearse.main(["score", "--base", "b", "--answers", str(ans)]) == 0 and json.loads(capsys.readouterr().out)["n"] == 1
    assert rehearse.main(["score", "--base", "b", "--answers", str(tmp_path / "none")]) == 1
    assert json.loads(capsys.readouterr().out)["ok"] is False
    monkeypatch.setattr(memory, "ask", lambda root, q, lt, model, lang: {"ok": True, "q": q, "lt": lt})
    assert memory.main(["--root", str(tmp_path), "--q", "csv", "--lt", "py", "lt"]) == 0
    assert json.loads(capsys.readouterr().out) == {"ok": True, "q": "csv", "lt": ["py", "lt"]}
    monkeypatch.setattr(memory, "ask", lambda *a: (_ for _ in ()).throw(RuntimeError("no index")))
    assert memory.main(["--root", str(tmp_path), "--q", "csv"]) == 1 and "no index" in capsys.readouterr().out
    monkeypatch.setattr(followup, "draft", lambda md, lang, model, **k: {"subject": "S"})
    assert followup.main(["--md", "x.md"]) == 0 and json.loads(capsys.readouterr().out) == {"subject": "S", "ok": True}


def test_rehearsal_material_and_questions(tmp_path):
    base = str(tmp_path / "call")
    assert rehearse.material(base) == "(no preparation)"
    (tmp_path / "call.brief.md").write_text("B")
    (tmp_path / "call.slides.json").write_text("[]")
    assert rehearse.material(base) == "BRIEF.MD:\nB\n\nSLIDES.JSON:\n[]"
    out = rehearse.questions(base, "en", "m", Prov('{"questions": [{"q": "Why?"}, "How" , "", {"q": " "}]}'))
    assert out["questions"] == ["Why?", "How"]


def test_link_value_writes_every_page_id_of_the_project():
    """0.8.7: Settings > Projects > In Notion may hold several pages ("id1, id2"); all go into the relation."""
    from livetips_m0.wrapup_notion import link_value, page_ids
    assert page_ids("aaa, bbb,aaa,, ccc") == ["aaa", "bbb", "ccc"]
    assert link_value("Project", "relation", "aaa, bbb", "Orbit") == {"Project": {"relation": [{"id": "aaa"}, {"id": "bbb"}]}}
    assert link_value("Project", "relation", "aaa", "") == {"Project": {"relation": [{"id": "aaa"}]}}
    assert link_value("Project", "relation", "", "Orbit") == {}
    assert link_value("Project", "multi_select", "", "Orbit, Northwind") == {"Project": {"multi_select": [{"name": "Orbit"}, {"name": "Northwind"}]}}
