"""rules/sales.yaml (0.8.7): the qualification tracker, sales tips, answer cards, the after-call summary."""
import json
from types import SimpleNamespace

from livetips_m0.rules import Rules
from livetips_m0.sales import SalesTracker, best_card, parse_cards

CARDS = parse_cards("""## Price is too high
Orbit pays back in 4 months for a team of 20; we can start with a pilot.
Tags: price, objection
## Northwind Analytics
They need a data team; we work with your engineers from day one.
Tags: competitor
Use when: the client compares us with Northwind
""")


def tracker(method="bant", planned=1800, lang="en"):
    return SalesTracker(Rules().sales, method, lang, CARDS, planned)


def test_methods_parse_with_both_languages():
    m = Rules().sales["methods"]
    assert set(m) >= {"general", "bant", "spiced", "meddic"}
    for k, v in m.items():
        assert v["name"]["en"] and v["name"]["uk"] and v["desc"]["en"] and v["desc"]["uk"]
        for c in v["criteria"]:
            assert c["key"] and c["name"]["uk"] and c["explain"]["en"] and c["ask"]["uk"]


def test_tracker_keeps_the_strongest_state_and_the_pm_wins():
    t = tracker()
    t.update({"deal": [{"criterion": "budget", "state": "known", "what": "40k approved", "quote": "we have 40k", "t": "10:01:00"}]})
    t.update({"deal": [{"criterion": "budget", "state": "partial", "what": "maybe"}]})
    assert t.deal["budget"]["state"] == "known" and t.deal["budget"]["what"] == "40k approved"
    t.fix("need", "known", "Reporting is manual")
    t.update({"deal": [{"criterion": "need", "state": "unknown"}]})
    assert t.deal["need"]["state"] == "known"
    item = t.item()
    assert item["kind"] == "deal" and item["known"] == 2 and item["total"] == 4 and item["chip"]


def test_objection_tip_uses_the_answer_card():
    t = tracker()
    t.update({"objections": [{"what": "The price is too high for us", "t": "10:05:00"}]})
    tips = t.tips({}, 60)
    ob = [x for x in tips if x["sales"] == "objection"]
    assert ob and "pays back" in ob[0]["phrase"]
    assert not [x for x in t.tips({}, 61) if x["sales"] == "objection"], "each tip fires once"


def test_qualify_after_40_percent_and_next_step_near_the_end():
    t = tracker(planned=1800)
    assert not [x for x in t.tips({}, 300) if x["sales"] == "qualify"]
    q = [x for x in t.tips({}, 0.4 * 1800) if x["sales"] == "qualify"]
    assert q and q[0]["phrase"].endswith("?")
    ns = [x for x in t.tips({}, 1800 - 240) if x["sales"] == "next_step"]
    assert ns
    t2 = tracker(planned=1800)
    t2.update({"next_step": {"what": "Demo for Ann Lee", "due": "2026-11-05", "owner": "me"}})
    assert not [x for x in t2.tips({}, 1700) if x["sales"] == "next_step"]


def test_signal_pain_and_competitor():
    t = tracker("general")
    t.update({"signals": [{"what": "Asked when onboarding can start"}],
              "deal": [{"criterion": "pain", "state": "partial", "what": "reports take long"}]})
    kinds = {x["sales"] for x in t.tips({}, 60, "they compare with Northwind Analytics")}
    assert {"signal", "pain", "competitor"} <= kinds
    assert not t.item()["chip"], "General sales has no chip"


def test_best_card_needs_overlap():
    assert best_card("too high price", CARDS)["title"] == "Price is too high"
    assert best_card("weather in Kyiv", CARDS) is None


def test_summary_written(tmp_path):
    t = tracker("spiced")
    t.update({"next_step": {"what": "Send the proposal", "due": "2026-11-03"}})
    p = tmp_path / "call.app.sales.json"
    t.write(p, open_questions=2)
    d = json.loads(p.read_text())
    assert d["method"] == "spiced" and d["scorecard"]["next_step_with_date"] and d["scorecard"]["total"] == 5


def test_engine_rules_only_in_sales_mode():
    from livetips_m0.engine import Engine
    on = SimpleNamespace(rules=Rules(), agenda_items=[], open_commitments=[], sales=tracker("meddic"))
    off = SimpleNamespace(rules=Rules(), agenda_items=[], open_commitments=[], sales=None)
    assert '"deal"' in Engine._situation_extra_rules(on) and "economic_buyer" in Engine._situation_extra_rules(on)
    assert '"deal"' not in Engine._situation_extra_rules(off)


def test_situation_keeps_sales_keys_only_when_given():
    from livetips_m0.situation import next_situation
    s = next_situation({"deal": [{"criterion": "budget", "state": "known"}], "objections": [{"what": "price"}]}, {}, 0, 0)
    assert s["deal"] and s["objections"]
    assert "deal" not in next_situation({}, {}, 0, 0)


def test_notion_wrapup_has_a_sales_section(tmp_path):
    from livetips_m0.wrapup_notion import TXT, sales_lines
    md = tmp_path / "2026-10-31-1000-orbit.app.md"
    t = tracker("bant")
    t.update({"deal": [{"criterion": "budget", "state": "known", "what": "40k"}], "objections": [{"what": "price", "answer": "pilot"}],
              "next_step": {"what": "Demo", "due": "2026-11-05"}})
    t.write(tmp_path / "2026-10-31-1000-orbit.app.sales.json")
    lines = sales_lines(md, TXT["en"])
    assert "budget: known · 40k" in lines and any(l.startswith("Objection: price") for l in lines) and "Next step: Demo (2026-11-05)" in lines
    assert sales_lines(tmp_path / "other.md", TXT["en"]) == []


def test_methods_parse_with_en_and_uk_texts():
    from livetips_m0.rules import Rules
    from livetips_m0.sales import methods_json
    for lang in ("en", "uk"):
        m = methods_json(Rules(), lang)
        keys = [x["key"] for x in m["methods"]]
        assert m["default"] == "general" and {"general", "bant", "spiced", "meddic"} <= set(keys)
        for x in m["methods"]:
            assert x["name"] and x["desc"] and x["criteria"], (lang, x["key"])
            assert all(c["name"] and c["explain"] for c in x["criteria"])


def test_feature_registry_strings_in_both_languages():
    """0.8.7 (L1, L5): every feature of FeatureRegistry has a name, a sentence and, when it has a condition, When."""
    import json
    import re
    from pathlib import Path
    root = Path(__file__).resolve().parents[3]
    src = (root / "app/Sources/LiveTips/Features.swift").read_text()
    feats = re.findall(r'Feature\(id: "(\w+)", event: "\w+", hasWhen: (true|false)\)', src)
    assert len(feats) >= 12
    for lang in ("en", "uk"):
        d = json.loads((root / f"app/Resources/i18n/{lang}.json").read_text(encoding="utf-8"))
        for fid, when in feats:
            assert d.get("feat." + fid) and d.get("feat." + fid + ".what"), (lang, fid)
            if when == "true":
                assert d.get("feat." + fid + ".when"), (lang, fid)
        assert d.get("feat.try")


def test_ask_and_help_now_look_in_the_answer_cards_first():
    """0.8.7 (H4.5, rules/sales.yaml > ask_order): the cards come before the brief and the project memory."""
    import threading
    from livetips_m0.engine import Engine
    from livetips_m0.sales import cards_block, ranked_cards
    assert ranked_cards("Is the price too high?", CARDS)[0]["title"] == "Price is too high"
    assert cards_block("weather in Kyiv", CARDS) == ""
    line = SimpleNamespace(text="Honestly the price is too high for a team our size")
    on = SimpleNamespace(sales=tracker(), lock=threading.Lock(), history=[line])
    ask = Engine._sales_cards_first(on, "ask", "what do we say about the price?")
    assert ask.startswith("ANSWER CARDS") and "pays back in 4 months" in ask
    sos = Engine._sales_cards_first(on, "sos", "")
    assert "Price is too high" in sos, "HELP NOW matches the last lines of the call"
    assert Engine._sales_cards_first(on, "find", "price") == ""
    off = SimpleNamespace(sales=None, lock=threading.Lock(), history=[line])
    assert Engine._sales_cards_first(off, "ask", "price too high") == ""


def test_coach_mode_tips_address_the_seller():
    """0.8.7 (H2, rules/sales.yaml > coach): the PM watches someone else sell."""
    from livetips_m0.sales import observed_seller
    assert observed_seller({"call_type": "interview", "hiring_role": "observer"})
    assert observed_seller({"call_type": "coach", "coach_role": "mentor"})
    assert not observed_seller({"call_type": "interview", "hiring_role": "coach"}), "I am interviewed: the PM is the seller"
    assert not observed_seller({})
    t = tracker()
    t.observed = True
    t.update({"objections": [{"what": "The price is too high for us", "t": "10:05:00"}]})
    ob = [x for x in t.tips({}, 60) if x["sales"] == "objection"][0]
    assert ob["gist"].startswith("Seller: ") and ob["to"] == "seller" and "pays back" in ob["phrase"]
    t2 = tracker(lang="uk")
    t2.observed = True
    t2.update({"objections": [{"what": "The price is too high for us"}]})
    assert [x for x in t2.tips({}, 60) if x["sales"] == "objection"][0]["gist"].startswith("Продавцю: ")
    plain = tracker()
    plain.update({"objections": [{"what": "The price is too high for us"}]})
    assert "to" not in [x for x in plain.tips({}, 60) if x["sales"] == "objection"][0]
