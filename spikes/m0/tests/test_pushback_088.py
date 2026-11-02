"""2026-11-02 (owner): the PM-mode triggers scope_pushback and value_doubt (not only in sales calls)."""
from livetips_m0.engine import RED_TRIGGERS, demote_red
from livetips_m0.prompt import disabled_triggers, render_rules
from livetips_m0.rules import Rules
from livetips_m0.signals import Detector
from livetips_m0.transcript import Line


def line(text, speaker="them"):
    return Line(1, "10:00:00", speaker, "Client" if speaker == "them" else "Me", None, "en", text)


def det():
    return Detector(Rules(), ["Alex"])


def test_scope_pushback_cues():
    d = det()
    for t in ("That is too long, it should be faster.", "Це занадто довго для такої правки.", "Чому так дорого?",
              "I thought it should be simple, we can cut the scope."):
        s = d.detect(line(t))
        assert s.scope_pushback, t
        assert s.route == "classify", t
    assert d.detect(line("Чому так довго?")).trigger_hint == "scope_pushback"


def test_value_doubt_cues():
    d = det()
    for t in ("Why do we need this at all?", "Навіщо нам це робити зараз?", "I don't see the value in the refactoring.",
              "Не бачу сенсу в цьому етапі.", "Who asked for this?"):
        s = d.detect(line(t))
        assert s.value_doubt, t
        assert s.route == "classify", t
    assert d.detect(line("Why do we need this?")).trigger_hint == "value_doubt"   # wins over a plain question


def test_no_false_cues():
    d = det()
    for t in ("Thanks, the export works.", "Добре, дякую, до зустрічі.", "How long was the call yesterday?"):
        s = d.detect(line(t))
        assert not s.scope_pushback and not s.value_doubt, t
    # the PM's own words never count
    assert not d.detect(line("That is too long for us.", speaker="me")).scope_pushback


def test_new_requirement_and_commitment_still_win():
    d = det()
    s = d.detect(line("Could you also add this, it should be faster."))
    assert s.new_requirement and s.trigger_hint == "new_requirement" and s.route == "direct"


def test_red_is_kept_for_pm_triggers():
    assert {"scope_pushback", "value_doubt"} <= set(RED_TRIGGERS)
    obj = {"level": "red", "gist": "🔴 Заперечення: строк", "trigger": "scope_pushback"}
    demote_red(obj, "scope_pushback", {})
    assert obj["level"] == "red"


def test_triggers_in_the_prompt_and_off_in_interview():
    txt = render_rules(Rules(), meta={"audience": "client"})
    assert "scope_pushback" in txt and "value_doubt" in txt
    assert "answer-cards.md" in txt and "never a number for an estimate" in txt
    assert {"scope_pushback", "value_doubt"} <= disabled_triggers({"call_type": "interview", "hiring_role": "observer"})
    assert not {"scope_pushback", "value_doubt"} & disabled_triggers({"audience": "client"})
    assert not {"scope_pushback", "value_doubt"} & disabled_triggers({"audience": "team"})


def test_sweep_has_the_pushbacks_section():
    from pathlib import Path
    sweep = (Path(__file__).resolve().parents[3] / "skill/references/sweep.md").read_text(encoding="utf-8")
    assert "Likely pushbacks and value questions" in sweep and "never a number" in sweep
