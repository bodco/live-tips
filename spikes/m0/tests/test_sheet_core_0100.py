"""0.10.0 (Meeting Sheet, phase 1): the schema validator, presets (shared and the user's), readiness with the
automatic budget question, stale facts and the protection of manual edits. Fixtures are invented (tests/fixtures/sheet)
and are also read by the Swift CoreChecks."""
import copy
import json
import subprocess
import sys
from pathlib import Path

import pytest

from livetips_m0.sheet import merge, presets as P, readiness as R, schema as S
from livetips_m0.sheet.__main__ import main as cli

FIX = Path(__file__).parent / "fixtures" / "sheet"
TODAY = "2026-11-12"


@pytest.fixture(scope="module")
def rules():
    return P.load_rules()


def load(name):
    return json.loads((FIX / f"{name}.sheet.json").read_text(encoding="utf-8"))


def fact(sheet, fid):
    return next(f for b in sheet["blocks"] for f in b["facts"] if f["id"] == fid)


def block(sheet, t):
    return next(b for b in sheet["blocks"] if b["type"] == t)


# --- rules file --------------------------------------------------------------------------------------------------

def test_rules_file_is_complete(rules):
    assert set(rules["presets"]) == {"sales_intro", "upsell", "repeat_call", "client_sync", "internal_presentation",
                                     "standup", "interview", "blank"}
    assert set(rules["blocks"]) == set(S.BLOCK_TYPES)
    for pid, p in rules["presets"].items():
        assert p["mode"] in S.MODES and p["blocks"][0] == "header", pid
        assert all(b in rules["blocks"] for b in p["blocks"]), pid
        assert all(r in rules["readiness_rules"] for r in p["readiness"]), pid
    for rid, r in rules["readiness_rules"].items():
        assert r["action"] in S.GAP_ACTIONS and r["severity"] in S.SEVERITIES, rid
    assert rules["settings"]["stale_months"] == 6 and rules["settings"]["remind_minutes"] == 30
    assert P.method_names(rules)[0] == "bant" and set(P.method_names(rules)) <= set(rules["sales_methods"])
    raw = (Path(P.DEFAULT_RULES) / "meeting-sheet.yaml").read_text(encoding="utf-8")
    assert chr(0x2014) not in raw


# --- validator -----------------------------------------------------------------------------------------------------

@pytest.mark.parametrize("name", ["sales-intro-lumenfield", "client-sync-orbit", "standup-orbit"])
def test_fixtures_are_valid(rules, name):
    assert S.validate(load(name), P.method_names(rules)) == []


def test_validator_finds_broken_sheets(rules):
    s = load("sales-intro-lumenfield")
    del s["title"]
    s["mode"] = "turbo"
    s["sources"][1]["id"] = "s1"                                    # duplicate source id
    s["sources"].append({"id": "s9", "n": 9, "type": "fax", "title": "x", "access": "ok", "used": "full"})
    block(s, "company")["facts"][0]["source_ids"] = ["s404"]
    block(s, "company")["facts"][1]["conflict_with"] = ["f-none"]
    block(s, "contact")["facts"][0]["status"] = "maybe"
    block(s, "signals")["facts"][0]["source_ids"] = []             # a model fact without a source
    block(s, "fit")["visible"] = "yes"
    block(s, "qualification")["method"] = "astrology"
    block(s, "questions")["id"] = block(s, "fit")["id"]            # duplicate block id
    s["readiness"]["state"] = "maybe"
    errs = "\n".join(S.validate(s, P.method_names(rules)))
    for part in ("sheet.title: required", "sheet.mode: unknown value 'turbo'", "duplicate id 's1'", "unknown value 'fax'",
                 "unknown source 's404'", "unknown fact 'f-none'", "unknown value 'maybe'",
                 "a model fact needs at least one source", "visible: must be true or false", "unknown method 'astrology'",
                 "duplicate id 'b-fit'", "sheet.readiness.state: unknown value 'maybe'"):
        assert part in errs, part


def test_validator_on_non_objects():
    assert S.validate([]) == ["sheet: must be an object"]
    errs = S.validate({"schema": "other/9", "blocks": "x", "sources": []})
    assert any("must be 'pacenote.sheet/1'" in e for e in errs) and any("sheet.blocks: must be a list" in e for e in errs)


# --- presets -------------------------------------------------------------------------------------------------------

def test_new_sheet_has_the_preset_blocks_in_order(rules):
    s = P.new_sheet(rules, "sales_intro", {"start": "2026-11-13T16:00:00+02:00", "title": "Intro"},
                    {"ours": [{"name": "Mike Carter"}], "theirs": [{"name": "Emily Parker", "domain": "lumenfield.example"}]})
    assert [b["type"] for b in s["blocks"]] == rules["presets"]["sales_intro"]["blocks"]
    assert [b["order"] for b in s["blocks"]] == list(range(len(s["blocks"])))
    assert block(s, "qualification")["method"] == "bant"
    assert block(s, "company")["only_if_data"] is True and block(s, "contact")["only_if_data"] is False
    assert s["title"] == "Meeting Sheet: Emily Parker" and s["mode"] == "expert"
    assert S.validate(s, P.method_names(rules)) == []


def test_default_mode_rules(rules):
    theirs = [{"name": "Mike Carter", "domain": "orbit.example"}]
    assert P.default_mode(rules, "sales_intro", theirs=theirs) == "expert"
    assert P.default_mode(rules, "client_sync", theirs=theirs) == "quick"
    assert P.default_mode(rules, "standup") == "quick"
    assert P.default_mode(rules, "repeat_call", earlier_sheet=True, theirs=theirs) == "quick"
    assert P.default_mode(rules, "upsell", theirs=theirs, known_domains=[]) == "expert"           # new domain
    assert P.default_mode(rules, "upsell", theirs=theirs, known_domains=["orbit.example"]) == "quick"
    assert P.default_mode(rules, "blank") == "quick"                                              # internal
    assert P.default_mode(rules, "interview", theirs=[{"name": "Emily Parker"}]) == "expert"


def test_user_presets_crud(rules, tmp_path):
    app = tmp_path / "app"
    assert P.user_presets(app, rules) == []
    p = P.save_user_preset(app, rules, "My discovery", ["header", "contact", "qualification", "questions"], "expert",
                           base="sales_intro", method="spiced")
    assert p["id"] == "my_my_discovery" and Path(p["path"]).exists()
    assert p["readiness"] == rules["presets"]["sales_intro"]["readiness"]                     # from the base
    ids = [x["id"] for x in P.all_presets(rules, app)]
    assert ids[:8] == list(rules["presets"]) and "my_my_discovery" in ids
    s = P.new_sheet(rules, "my_my_discovery", {"start": "2026-11-13T10:00:00Z"}, app_root=app)
    assert block(s, "qualification")["method"] == "spiced"

    r = P.rename_user_preset(app, rules, "my_my_discovery", "Discovery v2")
    assert r["id"] == "my_my_discovery" and P.get_preset(rules, "my_my_discovery", app)["name"] == "Discovery v2"

    d = P.duplicate_preset(app, rules, "my_my_discovery")
    assert d["id"] != "my_my_discovery" and d["name"] == "Discovery v2 copy" and d["blocks"] == p["blocks"]
    d2 = P.duplicate_preset(app, rules, "standup", "Our stand-up")
    assert d2["base"] == "standup" and d2["readiness"] == ["standup_update"]
    assert P.default_mode(rules, d2["id"], app_root=app) == "quick"                          # base rules apply

    moved = P.delete_user_preset(app, rules, "my_my_discovery")
    assert Path(moved).exists() and "_deleted" in moved
    assert "my_my_discovery" not in [x["id"] for x in P.all_presets(rules, app)]

    with pytest.raises(ValueError):
        P.save_user_preset(app, rules, "Bad", ["header", "horoscope"])
    with pytest.raises(ValueError):
        P.save_user_preset(app, rules, "X", ["header"], preset_id="standup")                # shared ids are read-only
    with pytest.raises(KeyError):
        P.rename_user_preset(app, rules, "standup", "Mine")
    (P.presets_dir(app) / "broken.yaml").write_text("{: not yaml", encoding="utf-8")
    assert "broken" not in [x["id"] for x in P.user_presets(app, rules)]                     # skipped, not fatal


# --- readiness -----------------------------------------------------------------------------------------------------

@pytest.mark.parametrize("name", ["sales-intro-lumenfield", "client-sync-orbit", "standup-orbit"])
def test_stored_readiness_of_the_fixtures_is_what_the_engine_says(rules, name):
    s = load(name)
    assert R.evaluate(s, rules, TODAY) == s["readiness"]           # the Swift checks read the same stored values


def test_sales_intro_is_almost_with_budget_conflict_and_old_fact(rules):
    r = R.evaluate(load("sales-intro-lumenfield"), rules, TODAY)
    assert r["state"] == "almost"
    g = {x["id"]: x for x in r["gaps"]}
    assert list(g) == ["gap-qualification_complete-budget", "gap-no_open_conflicts-f-size-site", "gap-no_stale-f-funding"]
    assert g["gap-qualification_complete-budget"]["action"] == "add_question"
    assert g["gap-qualification_complete-budget"]["text"] == "Budget: no status yet"
    assert g["gap-no_open_conflicts-f-size-site"]["action"] == "mark_checked"
    assert "Team size" in g["gap-no_open_conflicts-f-size-site"]["text"]
    assert g["gap-no_stale-f-funding"]["action"] == "find_again" and g["gap-no_stale-f-funding"]["block"] == "b-signals"
    assert all(c["ok"] for c in r["checks"] if c["rule"] in ("goal_set", "participants_both", "contact_found", "fit_case"))


def test_blockers_make_not_ready(rules):
    s = load("sales-intro-lumenfield")
    s["goal"] = ""
    block(s, "contact")["facts"] = []
    s["participants"]["theirs"] = []
    r = R.evaluate(s, rules, TODAY)
    assert r["state"] == "not_ready"
    ids = [g["id"] for g in r["gaps"]]
    assert "gap-goal_set" in ids and "gap-contact_found" in ids and "gap-participants_both-theirs" in ids


def test_client_sync_owner_missing(rules):
    s = load("client-sync-orbit")
    block(s, "action_items")["facts"][1]["value"] = {"due": "2026-11-14"}
    r = R.evaluate(s, rules, TODAY)
    assert r["state"] == "almost"
    assert r["gaps"] == [{"id": "gap-owners_assigned-ai-2", "rule": "owners_assigned",
                          "text": "Action item without an owner: Confirm the test accounts", "action": "assign_owner",
                          "severity": "warning", "block": "b-action_items", "fact": "ai-2"}]
    block(s, "agenda")["facts"] = []
    assert R.evaluate(s, rules, TODAY)["state"] == "not_ready"


def test_standup_ready_and_missing_block_is_skipped(rules):
    s = load("standup-orbit")
    assert R.evaluate(s, rules, TODAY)["state"] == "ready"
    block(s, "standup_today")["facts"] = []
    assert R.evaluate(s, rules, TODAY)["state"] == "almost"
    s["blocks"] = [b for b in s["blocks"] if b["type"] != "standup_today"]
    r = R.evaluate(s, rules, TODAY)
    assert r["state"] == "ready" and r["checks"] == [{"rule": "standup_update", "ok": True, "skipped": True}]


def test_dropped_checks_are_honored(rules):
    s = load("sales-intro-lumenfield")
    s["readiness"]["dropped"] = ["no_stale", "gap-no_open_conflicts-f-size-site"]
    r = R.evaluate(s, rules, TODAY)
    assert [g["id"] for g in r["gaps"]] == ["gap-qualification_complete-budget"]
    assert {"rule": "no_stale", "ok": True, "dropped": True} in r["checks"]
    assert r["dropped"] == ["no_stale", "gap-no_open_conflicts-f-size-site"]
    s["readiness"]["dropped"].append("qualification_complete")
    assert R.evaluate(s, rules, TODAY)["state"] == "ready"


def test_auto_budget_question_is_added_once(rules):
    s = load("sales-intro-lumenfield")
    r1 = R.apply(s, rules, TODAY)
    q = [f for f in block(s, "questions")["facts"] if f["origin"] == "readiness"]
    assert len(q) == 1 and q[0]["id"] == "q-readiness-budget" and q[0]["text"] == "Is there a budget for this already?"
    assert q[0]["value"] == {"key": "budget"} and q[0]["source_ids"] == []
    budget_gap = next(g for g in r1["gaps"] if g["rule"] == "qualification_complete")
    assert budget_gap["action"] == "find_again"                    # the question is on the list already
    snapshot = copy.deepcopy(s)
    R.apply(s, rules, TODAY)
    R.apply(s, rules, TODAY)
    assert s == snapshot                                           # idempotent
    assert S.validate(s, P.method_names(rules)) == []


def test_auto_question_on_red_budget_and_gone_when_known(rules):
    s = load("sales-intro-lumenfield")
    f = fact(s, "f-q-budget")
    f.update(status="found", text="No budget this year", source_ids=["s5"], value={"key": "budget", "level": "red"})
    R.apply(s, rules, TODAY)
    assert any(x["id"] == "q-readiness-budget" for x in block(s, "questions")["facts"])
    assert not any(g["rule"] == "qualification_complete" for g in s["readiness"]["gaps"])   # red is a status
    f["value"]["level"] = "green"
    R.apply(s, rules, TODAY)
    assert not any(x["id"] == "q-readiness-budget" for x in block(s, "questions")["facts"])


def test_auto_question_creates_the_questions_block_and_keeps_user_edits(rules):
    s = load("sales-intro-lumenfield")
    s["blocks"] = [b for b in s["blocks"] if b["type"] != "questions"]
    R.apply(s, rules, TODAY)
    qb = block(s, "questions")
    assert qb["order"] == max(b["order"] for b in s["blocks"]) and qb["facts"][0]["id"] == "q-readiness-budget"
    qb["facts"][0].update(status="edited", text="What budget range do you have in mind?")
    fact(s, "f-q-budget").update(status="found", source_ids=["s5"], value={"key": "budget", "level": "green"})
    R.apply(s, rules, TODAY)
    assert block(s, "questions")["facts"][0]["text"] == "What budget range do you have in mind?"


def test_auto_question_language(rules):
    s = load("sales-intro-lumenfield")
    s["language"] = "uk"
    R.apply(s, rules, TODAY)
    assert fact(s, "q-readiness-budget")["text"] == "Чи є вже бюджет на це?"


def test_no_qualification_block_no_question(rules):
    s = load("client-sync-orbit")
    before = copy.deepcopy(s["blocks"])
    R.apply(s, rules, TODAY)
    assert s["blocks"] == before


# --- stale ---------------------------------------------------------------------------------------------------------

def test_stale_detection(rules):
    s = load("sales-intro-lumenfield")
    assert R.stale_fact_ids(s, TODAY, 6) == ["f-funding"]
    assert R.stale_fact_ids(s, TODAY, 1) == ["f-size-site", "f-industry", "f-funding", "f-case"]   # f-overview: s5 has no date
    assert R.stale_fact_ids(s, TODAY, 24) == []
    assert R.mark_stale(s, TODAY, 6) == ["f-funding"] and fact(s, "f-funding")["status"] == "stale"
    assert R.stale_fact_ids(s, TODAY, 24) == ["f-funding"]           # a stale status stays until rebuilt or checked
    s2 = load("sales-intro-lumenfield")
    fact(s2, "f-funding")["status"] = "edited"
    assert R.stale_fact_ids(s2, TODAY, 6) == []                      # the user's word is not old
    s3 = load("sales-intro-lumenfield")
    fact(s3, "f-funding")["source_ids"] = ["s3", "s2"]                # a fresh source keeps it current
    assert R.stale_fact_ids(s3, TODAY, 6) == []
    assert R.months_before(R._date("2026-08-31"), 6) == R._date("2026-02-28")


def test_stale_months_setting(rules):
    r = R.evaluate(load("sales-intro-lumenfield"), rules, TODAY, {"stale_months": 24})
    assert not any(g["rule"] == "no_stale" for g in r["gaps"])
    r = R.evaluate(load("sales-intro-lumenfield"), rules, TODAY, {"stale_months": 2})
    stale = [g for g in r["gaps"] if g["rule"] == "no_stale"]
    assert [g["fact"] for g in stale] == ["f-funding", "f-case"] and "older than 2 months" in stale[0]["text"]


# --- edit protection -----------------------------------------------------------------------------------------------

def test_protect_edits(rules):
    old = load("sales-intro-lumenfield")
    fact(old, "f-industry").update(status="edited", text="Lighting control for offices and hotels")
    block(old, "fit")["edited_by_user"] = True
    block(old, "fit")["facts"].append({"id": "f-mycase", "text": "Our own note", "source_ids": [], "status": "found", "origin": "user"})
    block(old, "red_lines")["facts"] = [{"id": "f-rl", "text": "Do not promise a date", "source_ids": [], "status": "found", "origin": "user"}]

    new = load("sales-intro-lumenfield")
    fact(new, "f-industry")["text"] = "Smart buildings"               # the rebuild says something else
    block(new, "fit")["facts"] = [{"id": "f-other", "text": "New case", "source_ids": ["s4"], "status": "found",
                                   "origin": "model", "checked_at": "2026-11-12"}]
    new["blocks"] = [b for b in new["blocks"] if b["type"] != "red_lines"]
    fact(new, "f-funding")["text"] = "Raised a Series A"
    out = merge.protect_edits(old, new)

    assert fact(out, "f-industry")["text"] == "Lighting control for offices and hotels"
    assert block(out, "fit") == block(old, "fit")                    # an edited block stays whole
    assert block(out, "red_lines")["facts"][0]["id"] == "f-rl"        # its block comes back
    assert fact(out, "f-funding")["text"] == "Raised a Series A"      # not protected: the rebuild wins
    assert "f-other" not in [f["id"] for b in out["blocks"] for f in b["facts"]]
    assert new["blocks"] != out["blocks"] and fact(new, "f-industry")["text"] == "Smart buildings"   # inputs untouched
    assert S.validate(out, P.method_names(rules)) == []


def test_protect_edits_user_fact_added_in_place():
    old = load("sales-intro-lumenfield")
    new = load("sales-intro-lumenfield")
    block(new, "questions")["facts"] = []
    out = merge.protect_edits(old, new)
    assert [f["id"] for f in block(out, "questions")["facts"]] == ["q-reports"]
    merge_again = merge.protect_edits(old, out)
    assert [f["id"] for f in block(merge_again, "questions")["facts"]] == ["q-reports"]


# --- CLI -----------------------------------------------------------------------------------------------------------

def run_cli(capsys, *args):
    code = cli(list(args))
    return code, json.loads(capsys.readouterr().out)


def test_cli(capsys, tmp_path, rules):
    code, o = run_cli(capsys, "validate", "--sheet", str(FIX / "standup-orbit.sheet.json"))
    assert code == 0 and o == {"ok": True, "errors": []}

    sheet = tmp_path / "x.sheet.json"
    sheet.write_text((FIX / "sales-intro-lumenfield.sheet.json").read_text(encoding="utf-8"), encoding="utf-8")
    code, o = run_cli(capsys, "readiness", "--sheet", str(sheet), "--today", TODAY, "--no-write")
    assert code == 0 and o["state"] == "almost" and "q-readiness-budget" not in sheet.read_text(encoding="utf-8")
    code, o = run_cli(capsys, "readiness", "--sheet", str(sheet), "--today", TODAY)
    assert code == 0 and "q-readiness-budget" in sheet.read_text(encoding="utf-8")

    req = tmp_path / "new.json"
    req.write_text(json.dumps({"preset": "client_sync", "meeting": {"start": "2026-11-14T15:00:00+02:00", "title": "Orbit weekly"},
                               "participants": {"ours": [{"name": "Sarah M."}], "theirs": [{"name": "Mike Carter", "domain": "orbit.example"}]},
                               "out": str(tmp_path / "live/prep-2026-11-14-1500-orbit.sheet.json"), "today": TODAY}))
    code, o = run_cli(capsys, "new", "--request", str(req))
    assert code == 0 and o["mode"] == "quick" and o["readiness"]["state"] == "not_ready"        # empty agenda
    assert S.validate(json.loads(Path(o["sheet"]).read_text(encoding="utf-8"))) == []

    preq = tmp_path / "p.json"
    preq.write_text(json.dumps({"action": "save", "app_root": str(tmp_path / "app"), "name": "Quick sync",
                                "blocks": ["header", "agenda"], "readiness": ["agenda_set"]}))
    code, o = run_cli(capsys, "presets", "--request", str(preq))
    assert code == 0 and o["preset"]["id"] == "my_quick_sync"
    code, o = run_cli(capsys, "presets", "--app-root", str(tmp_path / "app"))
    assert code == 0 and "my_quick_sync" in [p["id"] for p in o["presets"]] and o["methods"][0] == "bant"

    code, o = run_cli(capsys, "export", "--request", str(req))     # 0.10.0 phase 3: build is implemented now (pipeline)
    assert code == 2 and "not implemented yet" in o["error"]
    code, o = run_cli(capsys, "dance")
    assert code == 2

    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"schema": "pacenote.sheet/1"}))
    code, o = run_cli(capsys, "validate", "--sheet", str(bad))
    assert code == 1 and o["ok"] is False and o["errors"]


def test_cli_as_module(tmp_path):
    r = subprocess.run([sys.executable, "-m", "livetips_m0.sheet", "presets"], cwd=Path(__file__).parents[1],
                       capture_output=True, text=True)
    assert r.returncode == 0 and len(json.loads(r.stdout)["presets"]) == 8
