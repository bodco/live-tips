"""S1-2 (2026-11-17): the deal blocks beyond qualification: competitors with battlecards, prices and limits,
stakeholders, the mutual action plan and the CRM stage's focus."""
from livetips_m0.rules import Rules
from livetips_m0.sales import SalesTracker, cards_block, crm_stage, match_stage, parse_cards, price_limits
from livetips_m0.situation import next_situation

CARDS = parse_cards("""## Northwind Analytics
They need a data team; we work with your engineers.
Type: competitor
They win: brand and a big partner list
We win: live in two weeks, no data team
Trap: Who on your side would run their models?
## Old competitor card
Tags: competitor
## Discount
We can offer a pilot at a lower price instead of a discount.
Type: price
Limit: no more than 20% discount
## Security review
We passed SOC 2 Type II in 2026.
""")


def tracker(method="bant", lang="en", planned=1800):
    return SalesTracker(Rules().sales, method, lang, CARDS, planned)


def test_cards_get_types_battlecards_and_limits():
    by = {c["title"]: c for c in CARDS}
    assert by["Northwind Analytics"]["type"] == "competitor" and by["Northwind Analytics"]["we_win"].startswith("live")
    assert by["Old competitor card"]["type"] == "competitor", "Tags: competitor still means a competitor"
    assert by["Discount"]["type"] == "price" and by["Discount"]["limit"] == "no more than 20% discount"
    assert by["Security review"]["type"] == "answer" and by["Security review"]["answer"].startswith("We passed")
    assert [c["title"] for c in price_limits(CARDS)] == ["Discount"]
    assert "We win: live in two weeks" in cards_block("how do you compare with Northwind analytics", CARDS)


def test_price_limits_go_to_the_model_only_with_price_cards():
    k, r = tracker().extra()
    assert "limit_breach" in k and "PRICE LIMITS" in r and "20% discount" in r
    k2, r2 = SalesTracker(Rules().sales, "bant", "en", [], 1800).extra()
    assert "limit_breach" not in k2 and "PRICE LIMITS" not in r2
    assert "stakeholders" in k2 and "mutual_plan" in k2


def test_situation_keeps_the_blocks_only_when_given():
    sit = next_situation({"topic": "x", "stakeholders": [{"name": "Emily", "role": "decider"}, {"role": "user"}]}, {}, 0, 0)
    assert sit["stakeholders"] == [{"name": "Emily", "role": "decider"}]
    assert "competitors" not in sit and "mutual_plan" not in sit


def test_stakeholders_merge_and_keep_known_role():
    t = tracker()
    t.update({"stakeholders": [{"name": "Emily Stone", "role": "decider", "stance": "for", "quote": "I sign", "t": "00:05:00"}]})
    t.update({"stakeholders": [{"name": "emily stone", "role": "unknown", "stance": "unknown"},
                               {"name": "Mike", "role": "boss", "stance": "against", "quote": "Too risky"}]})
    assert len(t.stakeholders) == 2 and t.stakeholders[0]["role"] == "decider"
    assert t.stakeholders[1]["role"] == "unknown" and t.stakeholders[1]["stance"] == "against"
    tips = [x for x in t.tips({}, 60) if x["sales"] == "stakeholder"]
    assert len(tips) == 1 and "Mike" in tips[0]["gist"] and "Mike" in tips[0]["phrase"]


def test_unknown_decider_tip_after_40_percent():
    t = tracker()
    assert not [x for x in t.tips({}, 300) if x["sales"] == "stakeholder"]
    assert [x for x in t.tips({}, 800) if x["sales"] == "stakeholder" and x["uid"].endswith("decider")]
    t2 = tracker()
    t2.update({"deal": [{"criterion": "authority", "state": "known", "what": "CFO signs"}]})
    assert not [x for x in t2.tips({}, 800) if x["uid"].endswith("decider")]


def test_limit_breach_is_a_red_tip_with_the_card():
    t = tracker()
    t.update({"limit_breach": [{"what": "We can do 30% off", "limit": "no more than 20% discount", "t": "00:12:00"}],
              "price_talk": [{"who": "us", "what": "30% off the annual plan"}, {"who": "x", "what": "Budget is 40k"}]})
    tip = [x for x in t.tips({}, 60) if x["sales"] == "price_limit"]
    assert tip and tip[0]["level"] == "red" and "20%" in tip[0]["gist"] and "pilot" in tip[0]["phrase"]
    assert [p["who"] for p in t.price_talk] == ["us", "them"]
    t2 = SalesTracker(Rules().sales, "bant", "en", [], 1800)
    t2.update({"limit_breach": [{"what": "30% off", "limit": "?"}]})
    assert t2.limit_breach == [], "no price cards, no breaches"


def test_competitor_from_the_call_picture_gets_the_battlecard():
    t = tracker()
    t.update({"competitors": [{"name": "Northwind", "what": "they already use it"}, {"name": "northwind"}]})
    assert len(t.competitors) == 1
    c = [x for x in t.tips({}, 60) if x["sales"] == "competitor"]
    assert c and "We win: live in two weeks" in c[0]["phrase"] and "Ask: Who on your side" in c[0]["phrase"]


def test_mutual_plan_merges_by_step_and_lands_in_item_and_summary():
    t = tracker()
    t.update({"mutual_plan": [{"step": "Security review with IT", "owner": "them"}]})
    t.update({"mutual_plan": [{"step": "security review with IT team", "owner": "them", "due": "Nov 30"},
                              {"step": "Pilot kickoff", "owner": "us", "due": "Dec 5"}]})
    assert len(t.mutual_plan) == 2 and t.mutual_plan[0]["due"] == "Nov 30"
    item, summ = t.item(), t.summary()
    for d in (item, summ):
        assert d["mutual_plan"] == t.mutual_plan and "stakeholders" in d and "competitors" in d and "stage" in d


def test_crm_stage_matches_and_sets_the_focus(tmp_path):
    rules = Rules().sales
    assert match_stage(rules, "Appointment scheduled") == "discovery"
    assert match_stage(rules, "qualifiedtobuy") == "qualification"
    assert match_stage(rules, "Contract sent") == "negotiation"
    assert match_stage(rules, "Something custom") == ""
    (tmp_path / "c.crm.md").write_text("# CRM\n\n## Deal: Orbit\n\n- Stage: Qualified to buy\n", encoding="utf-8")
    assert crm_stage(tmp_path / "c.brief.md") == "Qualified to buy"
    assert crm_stage(tmp_path / "none.brief.md") == "" and crm_stage(None) == ""
    t = tracker("bant")
    t.set_stage("Qualified to buy")
    q = [x for x in t.tips({}, 800) if x["sales"] == "qualify"]
    assert q[0]["gist"] == "Not clear yet: Authority", "the stage's focus is asked first"
    assert t.item()["stage"] == "qualification" and t.item()["stage_name"] == "Qualification"
    n = tracker("bant")
    assert [x for x in n.tips({}, 800) if x["sales"] == "qualify"][0]["gist"] == "Not clear yet: Budget"


def test_notion_lines_and_followup_carry_the_blocks(tmp_path):
    import json
    from livetips_m0.followup import sales_plan_lines
    from livetips_m0.wrapup_notion import TXT, sales_lines
    md = tmp_path / "call.md"
    md.write_text("x", encoding="utf-8")
    assert sales_plan_lines(md) == []
    t = tracker()
    t.set_stage("Contract sent")
    t.update({"stakeholders": [{"name": "Emily", "role": "decider", "stance": "for"}],
              "mutual_plan": [{"step": "Legal review", "owner": "them", "due": "Dec 1"}],
              "competitors": [{"name": "Northwind"}], "price_talk": [{"who": "them", "what": "Budget 40k"}],
              "next_step": {"what": "Send the contract", "due": "Nov 25"}})
    t.write(tmp_path / "call.sales.json")
    lines = sales_lines(md, TXT["en"])
    assert "Stakeholder: Emily (decider, for)" in lines and "Mutual plan: Legal review · them (Dec 1)" in lines
    assert "Competitor: Northwind" in lines and "Price (them): Budget 40k" in lines and "Stage: Contract sent" in lines
    uk = sales_lines(md, TXT["uk"])
    assert any(x.startswith("План дій: Legal review · вони") for x in uk)
    plan = sales_plan_lines(md)
    assert plan[0] == "- Legal review · owner: them · due: Dec 1" and plan[-1].startswith("- Next step: Send the contract")
    assert json.loads((tmp_path / "call.sales.json").read_text())["stage"] == "negotiation"


def test_meeting_sheet_has_the_deal_blocks_and_decider_rule():
    from livetips_m0.sheet import presets as P, readiness as R, schema as S
    from livetips_m0.sheet.derive import CARD_BLOCKS, LIVE_FACTS
    rules = P.load_rules()
    for b in ("objections", "competitors", "stakeholders", "mutual_plan"):
        assert b in rules["blocks"] and b in S.BLOCK_TYPES and b in LIVE_FACTS and rules["blocks"][b]["live"] == "sales"
    assert {"objections", "competitors"} <= set(CARD_BLOCKS)
    for pid in ("sales_intro", "repeat_call"):
        p = rules["presets"][pid]
        assert {"objections", "competitors", "stakeholders"} <= set(p["blocks"]) and "decider_known" in p["readiness"]
    assert "mutual_plan" in rules["presets"]["repeat_call"]["blocks"]
    rule = rules["readiness_rules"]["decider_known"]
    sheet = {"preset": "sales_intro", "blocks": [{"id": "b-st", "type": "stakeholders", "facts": [
        {"id": "f-1", "label": "Mike", "text": "Head of IT, influencer", "status": "found"}]}]}
    gaps, _ = R._run_rule(sheet, rules, "decider_known", rule, None, {})
    assert gaps and gaps[0]["text"] == "Not known who decides"
    sheet["blocks"][0]["facts"].append({"id": "f-2", "label": "Emily", "text": "CFO, signs the contract", "status": "found"})
    gaps, _ = R._run_rule(sheet, rules, "decider_known", rule, None, {})
    assert gaps == []


def test_sheet_reads_cards_and_the_deal_so_far_of_the_series(tmp_path):
    import json
    from livetips_m0.sheet.sources import auto_sources, series_deal_text
    live = tmp_path / "live"
    live.mkdir()
    (tmp_path / "pacenote").mkdir()
    (tmp_path / "pacenote" / "answer-cards.md").write_text("## Northwind\nType: competitor\n", encoding="utf-8")
    stem = live / "2026-11-10-1500-orbit-sales"
    (live / (stem.name + ".md")).write_text("# Orbit sales\n", encoding="utf-8")
    (live / (stem.name + ".sales.json")).write_text(json.dumps({
        "stakeholders": [{"name": "Emily", "role": "decider", "stance": "for"}],
        "mutual_plan": [{"step": "Security review", "owner": "them", "due": "Nov 30"}],
        "criteria": [{"criterion": "budget", "state": "known", "what": "40k"}]}), encoding="utf-8")
    txt = series_deal_text(str(live), "Orbit sales")
    assert txt
    assert "Stakeholder: Emily (decider, for)" in txt and "Mutual plan: Security review" in txt and "budget: known" in txt
    req = {"project": {"root": str(tmp_path)}, "meeting": {"title": "Orbit sales", "start": "2026-11-17T15:00:00"},
           "preset": "repeat_call", "today": "2026-11-17"}
    titles = [c["title"] for c in auto_sources(req)]
    assert "Answer cards" in titles and "Deal so far (earlier calls of the series)" in titles
    req["preset"] = "client_sync"
    assert "Answer cards" not in [c["title"] for c in auto_sources(req)]
