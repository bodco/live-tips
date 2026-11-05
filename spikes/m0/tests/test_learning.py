"""rules/learning.yaml: patterns across calls, the shared fixture (Swift checks the same file in CoreChecks)."""
import json
from pathlib import Path

from livetips_m0 import learning

FIX = json.loads((Path(__file__).resolve().parents[3] / "rules/fixtures/learning-patterns.json").read_text(encoding="utf-8"))


def test_fixture_standing_patterns():
    assert learning.standing(FIX["records"]) == FIX["expect"]


def test_one_call_is_not_a_pattern():
    one = [{"kind": "followup_instruction", "file": "a.md", "text": "Drop pricing"},
           {"kind": "followup_instruction", "file": "a.md", "text": "drop the pricing"}]
    assert learning.standing(one) == [] and learning.prompt([]) == ""


def test_prompt_block():
    p = learning.prompt(FIX["expect"])
    assert p.startswith(learning.HEAD) and "- [followup_instruction] shorter please, make it short" in p


def test_followup_revise_and_lessons(monkeypatch, tmp_path):
    from livetips_m0 import followup
    md = tmp_path / "call.md"
    md.write_text("# Weekly (2026-10-29 10:00)\n\n**Me** 10:00:01: hello\n")
    seen = []

    def fake(system, user, model, max_tokens, provider):
        seen.append((system, user))
        return {"subject": "Weekly", "body": "Hi" + chr(0x2014) + "all"}, 0.0

    monkeypatch.setattr(followup, "ask_json", fake)
    d = followup.draft(md, "en", lessons=learning.HEAD + "\n- [followup_instruction] shorter")
    assert d["body"] == "Hi-all" and learning.HEAD in seen[-1][0]
    r = followup.revise(md, {"subject": "S", "body": "B"}, "drop the pricing line")
    assert "drop the pricing line" in seen[-1][1] and "CURRENT DRAFT" in seen[-1][1]


def test_onme_fix_wins_over_the_model():
    from livetips_m0 import live
    from livetips_m0.engine import Engine

    class E:
        onme_fixed = {}
        fix_onme = Engine.fix_onme
    e = E()
    live.handle_setting(e, "onme_fix", "Send the deck to Ann|")
    live.handle_setting(e, "onme_fix", "check logs|Check the export logs by Friday")
    sit = {"actions": [{"what": "send the deck to Ann"}, {"what": "Check logs"}, {"what": "Book the room"}]}
    assert [a["what"] for a in e.fix_onme(sit)["actions"]] == ["Check the export logs by Friday", "Book the room"]


def test_tips_lang_switch():
    from livetips_m0 import live

    class P:
        fmt = {"tips_lang": "uk"}

    class W:
        def __init__(self):
            self.items = []

        def write(self, o):
            self.items.append(o)

    class E:
        cfg = {"tips_lang": "uk"}
        prompt = P()
        out_tips = W()
    e = E()
    live.handle_setting(e, "tips_lang", "en")
    assert e.cfg["tips_lang"] == "en" and e.prompt.fmt["tips_lang"] == "en"
    live.handle_setting(e, "tips_lang", "de")
    assert e.cfg["tips_lang"] == "en" and e.out_tips.items[0]["key"] == "tips_lang"


def test_tip_ratings_become_tip_lessons():
    """0.9.4 (rules/learning.yaml > tip_rating): two calls with the same down-rated tip are a standing lesson."""
    lessons = learning.tip_lessons(FIX["records"])
    assert lessons.startswith(learning.TIP_HEAD) and "- no pricing tips on stand-ups (off_topic)" in lessons
    assert learning.tip_lessons([r for r in FIX["records"] if r.get("file") != "call-3.md"]) == ""


def test_rating_in_the_call_reaches_the_tip_prompt():
    import threading
    from livetips_m0 import live
    from livetips_m0.engine import Engine
    from livetips_m0.prompt import PromptBuilder
    from livetips_m0.rules import Rules

    class E:
        tip_ratings = {}
        lock = threading.RLock()
        rate_tip = Engine.rate_tip
    e = E()
    live.handle_setting(e, "tip_feedback", "not_useful|c1|10:00:01|Offer the annual price|r=off_topic")
    live.handle_setting(e, "tip_feedback", "partly|c1|10:00:01|Offer the annual price|r=too_long|c=only the first line")
    live.handle_setting(e, "tip_feedback", "used|c2|10:01:00|Ask about test accounts")
    assert list(e.tip_ratings.values())[0] == {"verdict": "partly", "reasons": ["too_long"], "comment": "only the first line",
                                               "tip": "Offer the annual price"}
    pb = PromptBuilder(Rules(), {"title": "t", "tips_lang": "en", "langs": ["en"]})
    st = {"pm_ratings": [{"verdict": "partly", "reasons": ["too_long"], "tip": "x"}]}
    assert "STATE.pm_ratings" in pb.user("tip", "ask", ["a"], st)
    assert "STATE.pm_ratings" not in pb.user("tip", "ask", ["a"], {})
