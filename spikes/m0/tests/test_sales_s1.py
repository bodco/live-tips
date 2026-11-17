"""S1 (2026-11-17): more sales methods as data (MEDDPICC, GPCTBA/C&I, SPIN, Sandler pain funnel, Challenger), the
method kinds for the pickers and the approach methods judged on the seller."""
import yaml
from pathlib import Path

from livetips_m0.rules import Rules
from livetips_m0.sales import SalesTracker, methods_json

NEW = {"meddpicc", "gpctba", "spin", "sandler", "challenger"}
RULES = Path(__file__).resolve().parents[3] / "rules"


def test_new_methods_have_both_languages_and_a_known_kind():
    s = Rules().sales
    kinds = set(s["kinds"])
    assert NEW <= set(s["methods"])
    for k, m in s["methods"].items():
        assert (m.get("kind") or "qualification") in kinds, k
        assert m["name"]["en"] and m["name"]["uk"] and m["desc"]["en"] and m["desc"]["uk"], k
        keys = [c["key"] for c in m["criteria"]]
        assert len(keys) == len(set(keys)), k
        for c in m["criteria"]:
            assert c["name"]["en"] and c["name"]["uk"] and c["explain"]["en"] and c["explain"]["uk"], (k, c["key"])
            assert c["ask"]["en"] and c["ask"]["uk"], (k, c["key"])
            assert chr(0x2014) not in yaml.safe_dump(c, allow_unicode=True), (k, c["key"])


def test_meddpicc_adds_paper_process_and_competition_to_meddic():
    m = Rules().sales["methods"]
    a = [c["key"] for c in m["meddic"]["criteria"]]
    b = [c["key"] for c in m["meddpicc"]["criteria"]]
    assert set(b) - set(a) == {"paper_process", "competition"}


def test_methods_json_gives_kind_names_and_judge():
    for lang in ("en", "uk"):
        out = {x["key"]: x for x in methods_json(Rules(), lang)["methods"]}
        assert out["spin"]["kind"] == "questioning" and out["challenger"]["kind"] == "approach"
        assert out["challenger"]["judge"] == "seller" and out["bant"]["judge"] == "client"
        assert out["general"]["kind"] == "general" and out["bant"]["kind_name"]
    assert methods_json(Rules(), "uk")["methods"][0]["kind_name"] == "Загальне"


def test_meeting_sheet_offers_every_method():
    ms = yaml.safe_load((RULES / "meeting-sheet.yaml").read_text(encoding="utf-8"))
    assert set(ms["qualification"]["methods"]) == set(Rules().sales["methods"])


def test_challenger_is_judged_on_the_seller():
    t = SalesTracker(Rules().sales, "challenger", "en", [], 1800)
    _, rule = t.extra()
    assert "SELLER" in rule and "teach" in rule
    tips = t.tips({}, 1000)
    q = [x for x in tips if x["sales"] == "qualify"]
    assert q and q[0]["gist"] == "Not done yet: Teach"
    b = SalesTracker(Rules().sales, "bant", "en", [], 1800)
    assert "SELLER" not in b.extra()[1]


def test_sandler_asks_down_the_funnel_in_order():
    t = SalesTracker(Rules().sales, "sandler", "uk", [], 1800)
    t.update({"deal": [{"criterion": "surface_problem", "state": "known", "what": "reports late"}]})
    q = [x for x in t.tips({}, 1000) if x["sales"] == "qualify"]
    assert q[0]["gist"].startswith("Ще не зʼясовано: ") and q[0]["phrase"] == "Можете навести приклад?"


def test_pain_tip_works_for_spin_and_sandler():
    for method, key in (("spin", "problem"), ("sandler", "surface_problem")):
        t = SalesTracker(Rules().sales, method, "en", [], 1800)
        t.update({"deal": [{"criterion": key, "state": "partial", "what": "slow reports", "t": "00:03:00"}]})
        assert any(x["sales"] == "pain" for x in t.tips({}, 60)), method


def test_an_unknown_method_falls_back_to_the_default():
    t = SalesTracker(Rules().sales, "nope", "en", [], 1800)
    assert t.method == "general" and t.judge == "client"
