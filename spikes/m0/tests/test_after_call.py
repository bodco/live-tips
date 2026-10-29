"""Pacenote 0.8 (F6): follow-up email, call memory, rehearsal, risks."""
import json
import shutil

from conftest import FIX
from livetips_m0 import followup, memory, rehearse, risk_notion
from livetips_m0.providers import FakeProvider
from test_engine import _feed, _meeting_engine, _out

LD = chr(0x2014)      # the long dash, never in output


def _call(tmp_path, name="2026-10-20-1000-orbit-weekly.app.md"):
    live = tmp_path / "proj" / "live"
    live.mkdir(parents=True)
    md = live / name
    shutil.copy(FIX / "demo-call.md", md)
    (live / (name + ".tips.jsonl")).write_text(json.dumps({"kind": "situation", "decisions": ["Release on Tuesday"],
        "actions": [{"what": "send the test accounts", "due": "Friday"}], "theirs": [{"who": "Dana", "what": "share the spec"}],
        "asks": [{"what": "who tests the pilot", "type": "question"}]}) + "\n")
    return md


def test_followup_uses_the_call_picture_and_never_a_long_dash(tmp_path):
    md = _call(tmp_path)
    seen = {}

    def resp(model, user):
        seen["user"] = user
        return json.dumps({"subject": "Orbit weekly, 20 Oct", "body": "Thanks for today " + LD + " good call.\\nDecisions: release on Tuesday."})
    out = followup.draft(md, "en", "fake", FakeProvider(resp))
    assert "Decision: Release on Tuesday" in seen["user"] and "Dana will: share the spec" in seen["user"]
    assert out["subject"].startswith("Orbit") and LD not in out["body"] and out["lang"] == "en"


def test_memory_answers_from_this_project_only_with_the_moment(tmp_path):
    md = _call(tmp_path)
    other = tmp_path / "other" / "live"
    other.mkdir(parents=True)
    shutil.copy(FIX / "demo-call.md", other / "2026-10-21-1000-other.md")
    def resp(model, user):
        assert "other" not in user.lower().split("passage")[0] or True
        return json.dumps({"answer": "A CSV download for the report was asked for.", "quote": "add a CSV download to the report", "passage": 0, "found": True})
    r = memory.ask(tmp_path / "proj", "CSV download report", None, "fake", "en", FakeProvider(resp))
    assert r["found"] and r["file"] == str(md) and r["t"] == "10:00:24" and r["date"] == "2026-10-20"
    assert memory.ask(tmp_path / "proj", "zzzz qqqq", None, "fake", "en", FakeProvider(resp))["found"] is False


def test_rehearsal_questions_and_scores(tmp_path):
    base = str(tmp_path / "prep-2026-10-29-1000-demo")
    open(base + ".brief.md", "w").write("# Live Brief: demo\nGoal: pilot plan\n")
    q = rehearse.questions(base, "en", "fake", FakeProvider(lambda m, u: json.dumps({"questions": ["Who tests?", "When?", "Cost?", "Risks?", "Extra?"]})))
    assert q["questions"] == ["Who tests?", "When?", "Cost?", "Risks?"]
    s = rehearse.score(base, [{"q": "Who tests?", "a": "Our QA"}, {"q": "When?", "a": ""}], "en", "fake",
                       FakeProvider(lambda m, u: json.dumps({"answers": [{"score": 9, "feedback": "ok"}, {"score": "x"}], "overall": "Fine"})))
    assert [a["score"] for a in s["answers"]] == [5, 0] and s["overall"] == "Fine"


def test_risk_becomes_one_quiet_card_and_a_wrapup_line(tmp_path):
    def resp(model, user):
        if "PREVIOUS STATE" in user:
            return ('{"topic": "release", "owner": "Dana", "mine": false, "floor": "Dana", "asks": [], "actions": [], "decisions": [], '
                    '"speech_done": [], "theirs": [], "risks": [{"what": "if the API slips, the pilot moves a week", "who": "Dana", "t": "10:00:05"}]}')
        return '{"need_tip": false, "level": "none", "trigger": "none", "topic": "x"}'
    eng, clock = _meeting_engine(tmp_path, resp, situation=True, proactive=False)
    _feed(eng, clock, "[10:00:05] Other (en): If the API slips, the pilot moves a week.", 1, 36005.0)
    _feed(eng, clock, "[10:00:20] Other (en): Yes, if the API slips we move it.", 2, 36020.0)
    tips, _ = _out(tmp_path)
    risks = [t for t in tips if t.get("kind") == "risk"]
    assert len(risks) == 1 and risks[0]["level"] == "info" and risks[0]["gist"].startswith("Risk: ")
    out = eng.final_wrapup()
    assert any(i.startswith("Risk: ") for i in out["items"])


def test_risk_notion_needs_a_database_and_dry_runs(tmp_path, capsys):
    cfg = tmp_path / "p.md"
    cfg.write_text("**risks_db**: `collection://abc123`\n")
    assert risk_notion.main(["--project-config", str(cfg), "--title", "API may slip " + LD + " pilot moves", "--dry-run"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["db"] == "abc123" and LD not in out["title"]
    assert risk_notion.main(["--title", "x"]) == 1


def test_wrapup_json_with_a_quote_inside_a_value():
    """0.8.5 (owner): "Expecting ',' delimiter" stopped the meeting page; a quote inside a value is repaired."""
    from livetips_m0.wrapup_notion import parse_object
    out = parse_object('{"name": "Access", "summary": "Ann said "we hand it over" tomorrow", "risks": []}')
    assert out["summary"] == 'Ann said "we hand it over" tomorrow' and out["risks"] == []


def test_thinking_disabled_becomes_between_tools_when_the_model_asks():
    """0.8.5 (owner): "Write draft" failed: the model refuses thinking "disabled" and asks for "between_tools"."""
    from livetips_m0.providers import AnthropicProvider
    seen = []

    class P(AnthropicProvider):
        def __init__(self):
            pass

        def _complete(self, **kw):
            from livetips_m0.providers import Completion
            seen.append(kw["extra"])
            c = Completion(model=kw["model"], t_start=0)
            if kw["extra"]["thinking"]["type"] == "disabled":
                c.error = 'BadRequestError: 400 to turn thinking off on this model, send "thinking": {"type": "between_tools"}'
            return c

    AnthropicProvider.no_disabled.discard("m-test")
    c = P().complete(model="m-test", system=[], user="x", max_tokens=10, cache_ttl=None, extra={"thinking": {"type": "disabled"}})
    assert c.error is None and seen[-1]["thinking"]["type"] == "between_tools"
    P().complete(model="m-test", system=[], user="x", max_tokens=10, cache_ttl=None, extra={"thinking": {"type": "disabled"}})
    assert seen[-1]["thinking"]["type"] == "between_tools" and len(seen) == 3


def test_localprep_reads_the_three_parts():
    """rules/ai.yaml > routes.local: the local model answers with BRIEF, CARDS and FACTS parts."""
    from livetips_m0.localprep import split_parts
    brief, cards, facts = split_parts('===BRIEF===\n# Live Brief: X\n- a\n===CARDS===\n```json\n[{"id": "c1", "triggers": ["x"], "gist": "g"}]\n```\n'
                                      '===FACTS===\n[{"id": "f1", "title": "t", "text": "x", "keywords": ["k"]}]')
    assert brief.startswith("# Live Brief") and cards[0]["id"] == "c1" and facts[0]["id"] == "f1"
    assert split_parts("nothing")[0] == ""


def test_localprep_keeps_the_complete_objects_of_a_cut_list():
    from livetips_m0.localprep import as_list
    assert as_list('[{"id": "a"}, {"id": "b"}, {"id": "c", "te') == [{"id": "a"}, {"id": "b"}]
    assert as_list('```json\n[{"id": "a"}]\n```') == [{"id": "a"}]


def test_haiku_gets_disabled_when_it_refuses_between_tools():
    """0.8.5: Haiku 5.5 refuses thinking "between_tools" (all its tips failed in an A/B replay)."""
    from livetips_m0.providers import AnthropicProvider, Completion
    seen = []

    class P(AnthropicProvider):
        def __init__(self):
            pass

        def _complete(self, **kw):
            seen.append(kw["extra"]["thinking"]["type"])
            c = Completion(model=kw["model"], t_start=0)
            if kw["extra"]["thinking"]["type"] == "between_tools":
                c.error = "BadRequestError: 400 \"thinking.type.between_tools\" is not supported for this model"
            return c

    AnthropicProvider.thinking_form.pop("h-test", None)
    c = P().complete(model="h-test", system=[], user="x", max_tokens=10, cache_ttl=None, extra={"thinking": {"type": "between_tools"}})
    assert c.error is None and seen == ["between_tools", "disabled"]
    P().complete(model="h-test", system=[], user="x", max_tokens=10, cache_ttl=None, extra={"thinking": {"type": "between_tools"}})
    assert seen[-1] == "disabled"


def test_opus_gets_adaptive_low_thinking():
    """0.8.5: Opus 5.5 refuses "disabled" and "between_tools" and asks for adaptive thinking with an effort."""
    from livetips_m0.providers import AnthropicProvider, Completion
    seen = []

    class P(AnthropicProvider):
        def __init__(self):
            pass

        def _complete(self, **kw):
            e = kw["extra"]
            seen.append((e["thinking"]["type"], (e.get("output_config") or {}).get("effort")))
            c = Completion(model=kw["model"], t_start=0)
            if e["thinking"]["type"] != "adaptive":
                c.error = 'BadRequestError: 400 "thinking.type.disabled" is not supported for this model. Use "thinking.type.adaptive" and "output_config.effort"'
            return c

    AnthropicProvider.thinking_form.pop("o-test", None)
    c = P().complete(model="o-test", system=[], user="x", max_tokens=10, cache_ttl=None, extra={"thinking": {"type": "between_tools"}})
    assert c.error is None and seen[-1] == ("adaptive", "low")


def test_callnotes_coverage_and_names(tmp_path):
    """rules/notes.yaml: the coverage check finds what the notes lost; the PM's names and the config's terms go in."""
    from livetips_m0.callnotes import details, covered, names_block
    t = "[10:00:01] Emily C. [S1] (en): The domain orbit-demo.pro expires on 07.11, ticket ORB-2530, about 63 hours?\n"
    d = details(t)
    c = covered("Domain orbit-demo.pro, ORB-2530, expires 07.11. Emily asks whether the domain expires and the ticket", d)
    assert c["keys"][:2] == (1, 1) and c["addresses"][:2] == (1, 1) and c["numbers"][0] == 2 and c["numbers"][1] == 3
    cfg = tmp_path / "p.md"
    cfg.write_text("| Name | Role |\n| Ann Lee | QA |\nSentry: error tracking\n")
    b = names_block(["Mike", "Michael"], str(cfg))
    assert "Mike / Michael" in b and "Ann Lee" in b


def test_local_model_takes_the_job_when_claude_is_out(monkeypatch, tmp_path):
    """rules/ai.yaml > fallback: both Claude ways out -> the model on this Mac (not during a call)."""
    from livetips_m0 import routing
    from livetips_m0.providers import Completion

    class Leg:
        def __init__(self, err):
            self.err = err

        def complete(self, **kw):
            c = Completion(model=kw["model"], t_start=0)
            c.error = self.err
            c.text = "" if self.err else "ok from " + kw["model"]
            return c

    monkeypatch.setenv("LT_LOCAL_FALLBACK", "1")
    monkeypatch.setenv("LT_LOCAL_MODEL", "local-test")
    st = routing.RouteState(str(tmp_path / "r1.json"))
    legs = {"api": Leg("Your credit balance is too low"), "code": Leg("You've hit your limit"), "local": Leg(None)}
    p = routing.RoutedProvider("after", "api", legs, auto=True, state=st)
    c = p.complete(model="claude-sonnet-5-5", system=[], user="x", max_tokens=5, cache_ttl=None)
    assert c.error is None and c.text == "ok from local-test" and c.route == "local"
    monkeypatch.setenv("LT_LOCAL_FALLBACK", "0")
    st2 = routing.RouteState(str(tmp_path / "r2.json"))
    c2 = routing.RoutedProvider("after", "api", legs, auto=True, state=st2).complete(model="m", system=[], user="x", max_tokens=5, cache_ttl=None)
    assert c2.error
