"""0.8.7 (E): the call page's Notion section sync planner (pure, no network)."""
from livetips_m0.notion_sections import page_id, plan


def hd(i, t):
    return {"id": i, "type": "heading_3", "heading_3": {"rich_text": [{"plain_text": t}]}}


def bl(i, t):
    return {"id": i, "type": "bulleted_list_item", "bulleted_list_item": {"rich_text": [{"plain_text": t}]}}


PAGE = [hd("h1", "Decisions"), bl("b1", "Old A"), bl("b2", "Old B"), hd("h2", "Open questions"), bl("b3", "Q1"),
        {"id": "d", "type": "divider", "divider": {}}, bl("tail", "Pacenote footer")]


def test_replaces_only_the_edited_section():
    p = plan(PAGE, {"Decisions": ["New A"]})
    assert p["archive"] == ["b1", "b2"]
    assert p["after"][0][0] == "h1" and len(p["after"][0][1]) == 1
    assert p["append"] == []


def test_section_stops_at_divider_and_empty_list_only_archives():
    p = plan(PAGE, {"Open questions": []})
    assert p["archive"] == ["b3"] and p["after"] == []


def test_missing_section_is_appended_with_heading():
    p = plan(PAGE, {"Risks": ["Late access"]})
    assert p["archive"] == [] and p["append"][0]["type"] == "heading_3" and len(p["append"]) == 2
    assert p["appended"] == ["Risks"]
    assert plan(PAGE, {"Decisions": ["x"]})["appended"] == []


def test_heading_match_ignores_case_and_spaces_and_todo():
    p = plan(PAGE, {"  decisions ": ["x"]}, todo_sections=("  decisions ",))
    assert p["archive"] == ["b1", "b2"] and p["after"][0][1][0]["type"] == "to_do"


def test_page_id_from_url():
    assert page_id("https://www.notion.so/Orbit-call-0123456789abcdef0123456789abcdef") == "0123456789abcdef0123456789abcdef"
    assert page_id("") == ""


def test_titled_follows_page_language():
    from livetips_m0.notion_sections import titled
    uk = [hd("h", "Рішення")]
    assert list(titled(uk, {"decisions": ["x"]})) == ["Рішення"]
    assert list(titled(PAGE, {"decisions": ["x"], "open": []})) == ["Decisions", "Open questions"]
    assert list(titled([], {"risks": []}, "uk")) == ["Ризики"]


def test_sales_section_from_the_sales_file(tmp_path):
    """0.8.7 (H6.1): edits of the Sales section go to the page's "Sales" heading, in the page's language."""
    import json
    from livetips_m0.notion_sections import page_lang, titled, with_sales
    md = tmp_path / "call.md"
    (tmp_path / "call.sales.json").write_text(json.dumps({
        "criteria": [{"criterion": "budget", "state": "known", "what": "40k approved"}],
        "objections": [{"what": "Price is high", "answer": "Pilot first"}],
        "next_step": {"what": "Demo for Ann Lee", "due": "2026-11-05"}}), encoding="utf-8")
    uk = [hd("h", "Рішення"), hd("s", "Sales")]
    lang = page_lang(uk, {"sales": []})
    assert lang == "en", "Sales alone does not tell the language"
    lang = page_lang(uk, {"decisions": [], "sales": []})
    secs = titled(uk, with_sales({"decisions": [], "sales": []}, str(md), lang))
    assert secs["Sales"] == ["budget: known · 40k approved", "Заперечення: Price is high -> Pilot first",
                             "Наступний крок: Demo for Ann Lee (2026-11-05)"]
    assert with_sales({"decisions": ["x"]}, str(md), "en") == {"decisions": ["x"]}
    p = plan([hd("s", "Sales"), bl("o", "old")], {"Sales": secs["Sales"]})
    assert p["archive"] == ["o"] and len(p["after"][0][1]) == 3
