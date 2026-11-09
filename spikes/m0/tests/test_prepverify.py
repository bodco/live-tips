"""0.9.6 Б3: the preparation's checker (prepVerify, rules/prep.yaml > verify) with a fake claude -p."""
import json
import types

from livetips_m0 import prepverify as pv

BRIEF = """# Brief: Orbit weekly
## Facts
- The pilot starts November 10 (Mike Johnson).
- Budget: 42 hours left.
- Export goes to production on Monday.
- Retries after 1, 6 and 24 hours, as Emily Carter asked last week in the payments review.
## Agenda
1. Pilot readiness
"""
CLAIMS = [
    {"quote": "The pilot starts November 10", "verdict": "verified", "source": "decisions, 2026-11-01"},
    {"quote": "Budget: 42 hours left.", "verdict": "unverified", "source": ""},
    {"quote": "Export goes to production on Monday.", "verdict": "contradicted", "source": "mcp__pacenote__decisions",
     "source_date": "2026-11-04", "note": "Tuesday", "correct": "Export goes to production on Tuesday."},
    {"quote": "Retries after 1, 6 and 24 hours", "verdict": "contradicted", "source": "decisions.md"},   # no correct
    {"quote": "Something that is not in the brief", "verdict": "unverified"},
    {"quote": "Orbit weekly", "verdict": "unverified"},          # only in a heading: never touched
]


def test_apply_corrects_marks_and_keeps_headings():
    new, s = pv.apply(BRIEF, CLAIMS, pv.RULE)
    assert "- Budget: 42 hours left. (unverified)" in new
    # contradicted with a correct value: fixed in place with a short note, nothing removed
    assert "- Export goes to production on Tuesday. (corrected per the decision Nov 4)" in new
    assert "on Monday" not in new
    assert s["corrected"] == ["- Export goes to production on Monday. -> "
                              "- Export goes to production on Tuesday. (corrected per the decision Nov 4)"]
    # contradicted without a correct value: the unverified marker, the line stays
    assert "payments review. (unverified)" in new
    assert "# Brief: Orbit weekly\n" in new and "1. Pilot readiness" in new
    assert len(new.splitlines()) == len(BRIEF.splitlines())
    assert s["verified"] == 1 and s["unverified"] == 3 and s["contradicted"] == 2 and s["not_found"] == 2
    again, s2 = pv.apply(new, CLAIMS, pv.RULE)
    assert again == new and s2["marked"] == [] and s2["corrected"] == []    # applied twice: no second note


def test_correction_in_ukrainian_with_markdown_and_without_a_date():
    brief = "## Факти\n- **Пілот** стартує 23 листопада.\n- Демо в п'ятницю.\n"
    claims = [{"quote": "Пілот стартує 23 листопада.", "verdict": "contradicted", "source": "pacenote/decisions.md",
               "source_date": "2026-11-03", "correct": "Пілот стартує 16 листопада."},
              {"quote": "Демо в п'ятницю.", "verdict": "contradicted", "source": "roadmap.md",
               "correct": "Демо в четвер."}]
    new, s = pv.apply(brief, claims, pv.RULE, lang="uk")
    assert "- Пілот стартує 16 листопада. (виправлено за рішенням від 03.11)" in new
    assert "- Демо в четвер. (виправлено за roadmap.md)" in new
    assert len(s["corrected"]) == 2 and s["marked"] == []
    assert pv.source_label("pacenote/decisions.md (decisions register)", "uk") == "рішенням"
    assert pv.source_label("live/commitments.jsonl (commitments)") == "the commitments"
    assert pv.source_label("brief-2026-11-01.md, 2026-11-01") == "brief-2026-11-01.md"


def test_no_correction_from_reasoning_or_on_a_line_that_compares_sources():
    brief = ("- Release: Thursday 2026-11-20.\n"
             "- Budget. Plan v3: 78 used, 42 left. Current State: 81 used, 39 left. Current State wins.\n")
    claims = [{"quote": "Release: Thursday 2026-11-20.", "verdict": "contradicted", "source": "calendar (weekday check)",
               "correct": "Release: Friday 2026-11-20."},
              {"quote": "Plan v3: 78 used, 42 left.", "verdict": "contradicted", "source": "_notion/current-state.md",
               "source_date": "2026-11-04", "correct": "Plan v3: 81 used, 39 left."}]
    new, s = pv.apply(brief, claims, pv.RULE)
    assert "- Release: Thursday 2026-11-20. (unverified)" in new          # reasoning is not a source: only marked
    assert "Plan v3: 78 used, 42 left. Current State: 81 used, 39 left. Current State wins.\n" in new
    assert s["corrected"] == [] and s["kept"] == 1
    assert pv.source_ok("mcp__pacenote__decisions") and pv.source_ok("docs/orbit-config.md") and not pv.source_ok("calendar")


def test_a_correct_value_equal_to_the_quote_is_only_marked():
    brief = "- Budget: 42 hours left.\n"
    c = [{"quote": "Budget: 42 hours left.", "verdict": "contradicted", "source": "x", "correct": "Budget: 42 hours left."}]
    new, s = pv.apply(brief, c, pv.RULE)
    assert new == "- Budget: 42 hours left. (unverified)\n" and s["corrected"] == []


def fake(stdout):
    calls = []

    def runner(args):
        calls.append(args)
        return types.SimpleNamespace(stdout=stdout, returncode=0)
    return runner, calls


def req(tmp_path, route="api"):
    base = tmp_path / "live" / "2026-11-06-1000-orbit-weekly"
    base.parent.mkdir(parents=True)
    (tmp_path / "live" / (base.name + ".brief.md")).write_text(BRIEF, encoding="utf-8")
    return {"base": str(base), "root": str(tmp_path), "extra": [], "lt": None, "claude": "/bin/claude",
            "route": route, "state_dir": str(tmp_path), "budget_usd": 0.2, "python": "/venv/bin/python",
            "engine_dir": "/engine"}


def test_run_writes_verify_json_the_original_and_the_ledger(tmp_path):
    r = req(tmp_path)
    out = json.dumps({"type": "result", "result": "Here: " + json.dumps({"claims": CLAIMS}), "total_cost_usd": 0.012,
                      "num_turns": 7})
    runner, calls = fake(out)
    res = pv.run(r, runner)
    assert res["ok"] and res["verified"] == 1 and res["cost_usd"] == 0.012 and res["turns"] == 7
    v = json.loads(open(r["base"] + ".verify.json").read())
    assert v["unverified"] == 3 and len(v["corrected"]) == 1 and "removed" not in v and len(v["claims_list"]) == 6
    assert open(r["base"] + ".brief.preverify.md").read() == BRIEF
    assert "(unverified)" in open(r["base"] + ".brief.md").read()
    row = json.loads((tmp_path / "spend-ledger.jsonl").read_text().splitlines()[-1])
    assert row["job"] == "prep_verify" and row["route"] == "api" and row["usd"] == 0.012 and row["model"] == "claude-haiku-5-5"
    a = calls[0]
    assert a[0] == "/bin/claude" and a[a.index("--model") + 1] == "claude-haiku-5-5"
    assert "Write" in a[a.index("--disallowedTools") + 1] and "Bash" in a[a.index("--disallowedTools") + 1]
    assert "mcp__pacenote__commitments" in a[a.index("--allowedTools") + 1]
    cfg = json.loads(a[a.index("--mcp-config") + 1])["mcpServers"]["pacenote"]
    assert cfg["args"][:4] == ["-m", "livetips_m0.pn_mcp", "--root", str(tmp_path)] and cfg["env"] == {"PYTHONPATH": "/engine"}
    assert a[a.index("--max-budget-usd") + 1] == "0.20"


def test_account_way_has_no_budget_flag_and_a_bad_answer_keeps_the_brief(tmp_path):
    r = req(tmp_path, route="plan")
    runner, calls = fake(json.dumps({"type": "result", "result": "no json here", "is_error": True, "subtype": "error_max_turns"}))
    res = pv.run(r, runner)
    assert "--max-budget-usd" not in calls[0]
    assert res["ok"] is False and "no verdicts" in res["error"] and "error_max_turns" in res["error"]
    assert open(r["base"] + ".brief.md").read() == BRIEF
    assert not (tmp_path / "live" / "2026-11-06-1000-orbit-weekly.brief.preverify.md").exists()


def test_no_brief():
    assert pv.run({"base": "/nonexistent/x"}, lambda a: None)["ok"] is False


def test_rule_comes_from_rules_prep_yaml():
    r = pv.rule()
    assert r["marker"] == "(unverified)" and r["model"] == "claude-haiku-5-5" and r["contradicted"] == "correct"
    assert r["corrected_marker"]["uk"].startswith("(виправлено за")
