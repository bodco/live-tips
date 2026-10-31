"""Pacenote 0.8.8 (rules/decisions.yaml): the decision register, Workspace on every Notion write, de-duplication,
the automatic add and the decision_conflict card. Fakes only; nothing reaches Notion or a model."""
import json
import shutil
from pathlib import Path

import pytest
import yaml

from conftest import FIX
from livetips_m0 import decision_notion as D
from livetips_m0 import notion_links, risk_notion
from livetips_m0 import wrapup_notion as W
from livetips_m0.providers import FakeProvider

ROOT = Path(__file__).resolve().parents[3]
LD = chr(0x2014)

DB_PROPS = {
    "Decision": {"type": "title"}, "Date": {"type": "date"},
    "Area": {"type": "select", "select": {"options": [{"name": "Scope"}, {"name": "Delivery"}]}},
    "Context": {"type": "rich_text"}, "Source": {"type": "url"},
    "Status": {"type": "status", "status": {"options": [{"name": "Active"}, {"name": "Superseded"}, {"name": "Cancelled"}]}},
    "Supersedes": {"type": "relation"}, "Superseded By": {"type": "relation"},
    "Alternatives rejected": {"type": "rich_text"}, "Trade-off": {"type": "rich_text"}, "Review trigger": {"type": "rich_text"},
    "Door": {"type": "select", "select": {"options": [{"name": "One-way"}, {"name": "Two-way"}]}},
    "Stated by": {"type": "rich_text"}, "Project": {"type": "relation"}, "Workspace": {"type": "relation"},
}


def fake(monkeypatch, props=None, module=D, active=None):
    calls, n = [], {"i": 0}

    def notion(method, path, body=None):
        calls.append((method, path, body))
        if method == "GET":
            return {"properties": props or DB_PROPS}
        if path.endswith("/query"):
            return {"results": active or []}
        n["i"] += 1
        return {"url": "https://notion.so/d%d" % n["i"], "id": "d%d" % n["i"]}
    monkeypatch.setattr(module, "notion", notion)
    return calls


def posts(calls):
    return [c[2] for c in calls if c[0] == "POST" and c[1] == "/pages"]


def call_file(tmp_path, decisions=("Orbit pilot goes to Northwind first",), risks=()):
    live = tmp_path / "Orbit" / "live"
    live.mkdir(parents=True)
    md = live / "2026-10-12-1000-orbit-weekly.app.md"
    shutil.copy(FIX / "demo-call.md", md)
    (live / (md.name + ".tips.jsonl")).write_text(json.dumps({"kind": "situation", "decisions": list(decisions),
                                                               "risks": [{"what": r} for r in risks]}) + "\n")
    return md


def text(props, name):
    return props[name]["rich_text"][0]["text"]["content"]


def test_decision_properties_area_from_options_and_nothing_invented(tmp_path, monkeypatch, capsys):
    calls = fake(monkeypatch)
    md = call_file(tmp_path)
    details = {"area": "scope", "context": "Northwind has the test accounts ready.", "stated_by": "Emily Clark",
               "trade_off": "", "alternatives": "", "review_trigger": "", "door": ""}
    monkeypatch.setattr(D, "model_details", lambda *a, **k: details)
    assert D.main(["--db", "collection://dec1", "--title", "Orbit pilot goes to Northwind first", "--call-file", str(md),
                   "--source", "https://notion.so/meeting", "--project-page", "p-orbit, p-orbit2", "--workspace-page", "w-nw",
                   "--no-supersede-check"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["ok"] and out["url"] == "https://notion.so/d1"
    p = posts(calls)[0]["properties"]
    assert p["Decision"]["title"][0]["text"]["content"] == "Orbit pilot goes to Northwind first"
    assert p["Date"]["date"]["start"] == "2026-10-12"
    assert p["Area"] == {"select": {"name": "Scope"}}
    assert text(p, "Context") == "Northwind has the test accounts ready." and text(p, "Stated by") == "Emily Clark"
    assert p["Source"] == {"url": "https://notion.so/meeting"} and p["Status"] == {"status": {"name": "Active"}}
    assert p["Project"] == {"relation": [{"id": "p-orbit"}, {"id": "p-orbit2"}]}
    assert p["Workspace"] == {"relation": [{"id": "w-nw"}]}
    for never in ("Trade-off", "Alternatives rejected", "Review trigger", "Door", "Supersedes"):
        assert never not in p


def test_an_area_that_is_not_an_option_is_not_written(tmp_path, monkeypatch, capsys):
    calls = fake(monkeypatch)
    monkeypatch.setattr(D, "model_details", lambda *a, **k: {"area": "Budget", "door": "Two-way", "trade_off": "slower start"})
    md = call_file(tmp_path)
    assert D.main(["--db", "dec1", "--title", "x decision", "--call-file", str(md), "--no-supersede-check"]) == 0
    p = posts(calls)[0]["properties"]
    assert "Area" not in p and p["Door"] == {"select": {"name": "Two-way"}} and text(p, "Trade-off") == "slower start"


@pytest.mark.parametrize("ptype,expect", [
    ("select", {"select": {"name": "Northwind"}}),
    ("multi_select", {"multi_select": [{"name": "Northwind"}]}),
    ("rich_text", {"rich_text": [{"type": "text", "text": {"content": "Northwind"}}]}),
    ("relation", None)])
def test_workspace_on_every_write(tmp_path, monkeypatch, capsys, ptype, expect):
    props = dict(DB_PROPS, Workspace={"type": ptype}, Project={"type": "select"})
    calls = fake(monkeypatch, props)
    assert D.main(["--db", "dec1", "--title", "A", "--no-ai", "--project-name", "Orbit", "--workspace-value", "Northwind"]) == 0
    p = posts(calls)[0]["properties"]
    assert p["Project"] == {"select": {"name": "Orbit"}}
    if expect is None:
        assert "Workspace" not in p      # a relation needs page ids; a name is never written there
    else:
        assert p["Workspace"] == expect
    # risks and meeting pages take the same arguments
    rcalls = fake(monkeypatch, {"Risk": {"type": "title"}, "Project": {"type": "select"}, "Workspace": {"type": ptype}}, module=risk_notion)
    assert risk_notion.main(["--db", "r1", "--title", "Pilot may slip", "--project-name", "Orbit", "--workspace-value", "Northwind"]
                            + (["--workspace-page", "w1,w2"] if ptype == "relation" else [])) == 0
    rp = posts(rcalls)[0]["properties"]
    assert rp["Workspace"] == (expect or {"relation": [{"id": "w1"}, {"id": "w2"}]})


def test_a_chosen_workspace_property_and_the_meeting_page():
    class A:
        project_prop, workspace_prop, project_page, workspace_page = "", "Client space", "", "w9"
    ids = W.apply_link_args(A(), {})
    props = {"Name": {"type": "title"}, "Client space": {"type": "relation"}, "Workspace": {"type": "select"}}
    assert W.link_values(props, ids, "", "Northwind") == {"Client space": {"relation": [{"id": "w9"}]}}
    sc = {"project": None, "workspace": W.link_prop(props, "Workspace")}
    assert W.link_props(sc, ids, {}, "", "Northwind") == {"Client space": {"relation": [{"id": "w9"}]}}
    W.WORKSPACE_PROP["name"] = ""
    assert W.link_props({"project": None, "workspace": W.link_prop(props, "Workspace")}, {}, {}, "", "Northwind") == \
        {"Workspace": {"select": {"name": "Northwind"}}}


def test_the_same_decision_of_the_same_call_is_written_once(tmp_path, monkeypatch, capsys):
    calls = fake(monkeypatch)
    md = call_file(tmp_path)
    args = ["--db", "dec1", "--call-file", str(md), "--no-ai"]
    assert D.main(args + ["--title", "Orbit pilot goes to Northwind first"]) == 0
    assert D.main(args + ["--title", "  orbit pilot goes to NORTHWIND first! "]) == 0
    second = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert len(posts(calls)) == 1 and second["existing"] and second["url"] == "https://notion.so/d1"
    assert notion_links.get(md, "decisions", "Orbit pilot goes to Northwind first")["id"] == "d1"
    assert md.with_name(md.name[:-3] + ".notion.json").exists()


def test_auto_add_writes_each_decision_and_risk_of_the_call_once(tmp_path, monkeypatch, capsys):
    md = call_file(tmp_path, decisions=("Northwind first", "Weekly sync on Tuesdays"), risks=("API may slip",))
    calls = fake(monkeypatch)
    assert D.main(["--db", "dec1", "--call-file", str(md), "--from-call", "--no-ai"]) == 0
    assert D.main(["--db", "dec1", "--call-file", str(md), "--from-call", "--no-ai"]) == 0
    outs = [json.loads(l) for l in capsys.readouterr().out.strip().splitlines()]
    assert outs[0]["added"] == 2 and outs[1]["added"] == 0 and outs[1]["skipped"] == 2 and len(posts(calls)) == 2
    rcalls = fake(monkeypatch, {"Risk": {"type": "title"}}, module=risk_notion)
    assert risk_notion.main(["--db", "r1", "--call-file", str(md), "--from-call"]) == 0
    assert risk_notion.main(["--db", "r1", "--call-file", str(md), "--title", "API may slip"]) == 0
    assert len(posts(rcalls)) == 1


def test_auto_add_is_off_by_default_in_the_rules():
    dc = yaml.safe_load((ROOT / "rules/decisions.yaml").read_text(encoding="utf-8"))
    nt = yaml.safe_load((ROOT / "rules/notion-tasks.yaml").read_text(encoding="utf-8"))["settings"]["auto_add"]
    assert "off by default" in dc["auto_add"] and "hidden call" in dc["auto_add"]
    assert "Off by default; a value saved by 0.8.6 is kept" in nt
    for f in ("decisions.yaml", "notion-tasks.yaml", "risks.yaml", "usage.yaml"):
        assert LD not in (ROOT / "rules" / f).read_text(encoding="utf-8")
    ev = yaml.safe_load((ROOT / "rules/usage.yaml").read_text(encoding="utf-8"))["events"]
    assert ev["decision_added"] == [] and ev["auto_added"] == ["kind", "n"]


def test_supersede_only_on_click_and_the_candidate(tmp_path, monkeypatch, capsys):
    active = [{"id": "old1", "url": "https://notion.so/old1", "properties": {
        "Decision": {"type": "title", "title": [{"plain_text": "Orbit pilot goes to Acme first"}]},
        "Date": {"type": "date", "date": {"start": "2026-10-01"}}, "Stated by": {"type": "rich_text", "rich_text": [{"plain_text": "Ann Lee"}]}}}]
    calls = fake(monkeypatch, active=active)
    monkeypatch.setattr(D, "model_details", lambda *a, **k: {})
    monkeypatch.setattr(D, "supersede_candidate", lambda new, act, model, provider=None: act[0])
    assert D.main(["--db", "dec1", "--title", "Orbit pilot goes to Northwind first", "--project-page", "p1"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["supersede"] == {"id": "old1", "title": "Orbit pilot goes to Acme first", "date": "2026-10-01", "url": "https://notion.so/old1"}
    q = [c for c in calls if c[1].endswith("/query")][0][2]
    assert {"property": "Project", "relation": {"contains": "p1"}} in q["filter"]["and"]
    assert not [c for c in calls if c[0] == "PATCH"]          # nothing changed on the old page without the click
    assert D.main(["--db", "dec1", "--supersede", "old1", "--new", "d1"]) == 0
    patches = [(c[1], c[2]["properties"]) for c in calls if c[0] == "PATCH"]
    assert ("/pages/old1", {"Status": {"status": {"name": "Superseded"}}}) in patches
    assert ("/pages/old1", {"Superseded By": {"relation": [{"id": "d1"}]}}) in patches
    assert ("/pages/d1", {"Supersedes": {"relation": [{"id": "old1"}]}}) in patches


def test_supersede_candidate_from_the_model():
    act = [{"id": "a", "title": "Acme first"}, {"id": "b", "title": "Weekly on Tuesdays"}]
    prov = FakeProvider(lambda m, u: '{"replaces": 1}', 0.0, 0.0)
    assert D.supersede_candidate("Weekly on Thursdays", act, "fake", prov)["id"] == "b"
    assert D.supersede_candidate("x", act, "fake", FakeProvider(lambda m, u: '{"replaces": -1}', 0.0, 0.0)) is None
    assert D.supersede_candidate("x", [], "fake", prov) is None


def test_snapshot_round_trip_and_no_other_projects(tmp_path, monkeypatch, capsys):
    active = [{"id": "x", "properties": {"Decision": {"type": "title", "title": [{"plain_text": "Northwind first | then Acme"}]},
                                         "Date": {"type": "date", "date": {"start": "2026-10-12"}},
                                         "Stated by": {"type": "rich_text", "rich_text": [{"plain_text": "Emily Clark"}]},
                                         "Area": {"type": "select", "select": {"name": "Scope"}}}}]
    fake(monkeypatch, active=active)
    snap = tmp_path / "Orbit" / "pacenote" / "decisions.md"
    assert D.main(["--db", "dec1", "--project-page", "p1", "--snapshot", str(snap)]) == 0
    rows = D.parse_snapshot(snap.read_text(encoding="utf-8"))
    assert rows == [{"date": "2026-10-12", "title": "Northwind first / then Acme", "stated_by": "Emily Clark", "area": "Scope"}]
    capsys.readouterr()
    # a per-project database and a project without a value: nothing, never another project's decisions
    assert D.main(["--db", "dec1", "--list-active"]) == 0
    assert json.loads(capsys.readouterr().out)["decisions"] == []


def test_decision_conflict_card_on_a_synthetic_call(tmp_path):
    from livetips_m0.engine import decision_conflict_card, load_active_decisions
    proj = tmp_path / "Orbit"
    (proj / "pacenote").mkdir(parents=True)
    (proj / "pacenote" / "decisions.md").write_text(D.snapshot_text(
        [{"date": "2026-10-12", "title": "Orbit pilot goes to Northwind first", "stated_by": "Emily Clark", "area": "Scope"}], "now"))
    act = load_active_decisions(str(proj))
    assert act[0]["title"] == "Orbit pilot goes to Northwind first" and load_active_decisions("") == []
    c = decision_conflict_card(act[0], {"n": 0, "who": "Mike Johnson", "t": "10:01:00",
                                        "remind": "We agreed on 12.10 that Northwind goes first."}, "10:01:05", uk=False)
    assert c["kind"] == "decision_conflict" and c["level"] == "info"
    assert c["gist"] == "12.10 decided: Orbit pilot goes to Northwind first (Emily Clark)"
    assert c["items"] == ["We agreed on 12.10 that Northwind goes first."] and c["who"] == "Mike Johnson"
    assert decision_conflict_card(act[0], {"n": 0}, "t", uk=True)["gist"].startswith("12.10 вирішили:")


def test_decision_conflict_in_the_engine(tmp_path):
    from test_engine import _feed, _meeting_engine, _out
    proj = tmp_path / "Orbit"
    (proj / "pacenote").mkdir(parents=True)
    (proj / "pacenote" / "decisions.md").write_text(D.snapshot_text(
        [{"date": "2026-10-12", "title": "Orbit pilot goes to Northwind first", "stated_by": "Emily Clark"}], "now"))
    seen = {}

    def resp(model, user):
        if "PREVIOUS STATE" in user:
            seen["user"] = user
            return ('{"topic": "pilot", "owner": "Mike", "mine": false, "floor": "Mike", "asks": [], "actions": [], "decisions": [], '
                    '"speech_done": [], "theirs": [], "risks": [], "conflicts": [{"n": 0, "who": "Mike Johnson", "t": "10:00:05", '
                    '"remind": "We agreed on 12.10 that Northwind goes first."}]}')
        return '{"need_tip": false, "level": "none", "trigger": "none", "topic": "x"}'
    eng, clock = _meeting_engine(tmp_path, resp, situation=True, proactive=False, project_dir=str(proj))
    _feed(eng, clock, "[10:00:05] Other (en): Let us start the Orbit pilot with Acme instead.", 1, 36005.0)
    _feed(eng, clock, "[10:00:20] Other (en): Yes, Acme first, I think.", 2, 36020.0)
    tips, _ = _out(tmp_path)
    cs = [t for t in tips if t.get("kind") == "decision_conflict"]
    assert len(cs) == 1 and cs[0]["level"] == "info" and "Northwind" in cs[0]["gist"]
    assert "ACTIVE DECISIONS OF THE PROJECT" in seen["user"]


def test_every_rules_yaml_is_valid_yaml():
    """0.8.8: every rules/*.yaml loads (notion-tasks.yaml had a colon inside a plain value)."""
    files = sorted((ROOT / "rules").glob("*.yaml"))
    assert len(files) > 10
    for f in files:
        assert isinstance(yaml.safe_load(f.read_text(encoding="utf-8")), dict), f.name
