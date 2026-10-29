"""0.8.5 presentation rules in the recorder (rules/presentation.yaml): time line, time advice, slide sync.
The recorder is the one place that computes them; the skill's and the app's windows only show them."""
import importlib.util
import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).absolute().parents[3]
FIX = json.loads((REPO / "rules" / "fixtures" / "presentation-advice.json").read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def T():
    spec = importlib.util.spec_from_file_location("lt_transcriber", REPO / "recorder" / "src" / "transcriber.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["lt_transcriber"] = mod               # dataclasses look their module up while it loads
    spec.loader.exec_module(mod)
    return mod


@pytest.mark.parametrize("case", FIX["cases"], ids=lambda c: f"slide{c['cur']}-behind{c['behind']}")
@pytest.mark.parametrize("lang", ["en", "uk"])
def test_advice_matches_the_shared_fixture(T, case, lang):
    T.UI["lang"] = lang
    slides = T.parse_slides({"slides": FIX["slides"]})
    adv = T.time_advice(slides, case["cur"], case["behind"])
    exp = case["expect"]
    if exp is None:
        assert adv is None
        return
    assert adv["kind"] == exp["kind"] and adv["slides"] == exp["slides"]
    assert T.advice_text(adv) == exp[lang]


def test_old_slides_files_stay_valid(T):
    s = T.parse_slides({"slides": [{"n": 1, "title": "A", "sec": 60}]})[0]
    assert s["skip"] is False and s["short"] == "" and s["edited"] is False and s["who"] == "me"
    s = T.parse_slides({"slides": [{"n": 1, "title": "A", "skip": "yes", "short": "x" * 300, "edited": True}]})[0]
    assert s["skip"] is False and len(s["short"]) == 200 and s["edited"] is True


def test_plan_and_behind(T):
    slides = T.parse_slides({"slides": FIX["slides"]})
    plan = T.slide_plan(slides, {3: 30})
    assert plan[1] == (0, 45) and plan[3] == (165, 240) and plan[4] == (405, 90)
    assert T.behind_s(plan, 3, 165, 200) == 0                 # started on time, within the budget
    assert T.behind_s(plan, 3, 200, 300) == 35                # started 35 s late
    assert T.behind_s(plan, 3, 165, 165 + 300) == 60          # 60 s over the slide's budget
    assert T.behind_s(plan, 3, 100, 120) == -65               # ahead
    assert T.behind_s(plan, 99, 0, 0) is None and T.behind_s(plan, 3, None, 0) is None
    T.UI["lang"] = "en"
    assert T.timeline_line(580, 1500, 70) == "⏱ 9:40 of 25:00 · 1 min behind"
    assert T.timeline_line(580, 1500, -90).endswith("2 min ahead") and T.timeline_line(5, 60, None).endswith("on plan")


class Clock:
    def __init__(self, T):
        self.t, self.T = 1000.0, T
        T.now = lambda: self.t


def items(path):
    return [json.loads(x) for x in path.read_text().splitlines()]


def outline(T, tmp_path):
    T.UI["lang"] = "en"
    T.MEETING["call_type"] = "presentation"
    stem = tmp_path / "call.md"
    secs = [{"id": f"s{s['n']}", "title": s["title"], "slides": [s["n"], s["n"]], "keywords": [s["title"].lower(), f"word{s['n']}"],
             "who": "other" if s["who"] == "other" else None} for s in FIX["slides"]]
    for x in secs:
        if x["who"] is None:
            del x["who"]
    (tmp_path / "call.outline.json").write_text(json.dumps({"sections": secs}))
    (tmp_path / "call.slides.json").write_text(json.dumps({"slides": FIX["slides"]}))
    tips = tmp_path / "call.tips.jsonl"
    tips.write_text("")
    o, sl = T.Outline(stem, tips), T.Slides(stem, tips)
    o.slides_src = sl
    sl.refresh()
    o.refresh()
    return o, tips


def test_manual_moves_ask_and_advice(T, tmp_path):
    clk = Clock(T)
    o, tips = outline(T, tmp_path)
    o.set_slide(2)                                             # Start / Next in the window
    pos = [i for i in items(tips) if i["kind"] == "outline_pos"][-1]
    assert pos["cur"] == "s2" and pos["slide"] == 2 and pos["follow"] is None
    o._ask(2, clk.t)                                           # the tracker heard slide 3's words
    ask = [i for i in items(tips) if i["kind"] == "move_ask"]
    assert ask[-1]["n"] == 3 and ask[-1]["topic"] == "Results"
    o._ask(2, clk.t)
    assert len([i for i in items(tips) if i["kind"] == "move_ask"]) == 1      # asked once
    o.answer_move("no|3")
    assert o.ask is None and o.cur == 1
    o._ask(2, clk.t)
    assert len([i for i in items(tips) if i["kind"] == "move_ask"]) == 1      # quiet 60 s after a no
    clk.t += 61
    o._ask(2, clk.t)
    o.answer_move("yes|3")
    assert o.cur == 2 and o.slide_n == 3
    clk.t += 400                                               # 400 s on slide 3: 190 s over its 210 s budget
    o.set_slide(4)
    tl = [i for i in items(tips) if i["kind"] == "timeline"][-1]
    assert tl["slide"] == 4 and tl["behind"] >= 60 and tl["advice"]["kind"] == "skip"
    assert tl["text"].endswith(tl["advice"]["text"]) and tl["plan"] == sum(s["sec"] for s in FIX["slides"])
    o.add30(4)
    assert o.extra == {4: 30} and [i for i in items(tips) if i["kind"] == "timeline"][-1]["plan"] == tl["plan"] + 30


def test_following_the_deck_never_asks(T, tmp_path):
    clk = Clock(T)
    o, tips = outline(T, tmp_path)
    o.set_slide(2, "keynote")
    o._ask(3, clk.t)
    assert not [i for i in items(tips) if i["kind"] == "move_ask"]
    assert [i for i in items(tips) if i["kind"] == "outline_pos"][-1]["follow"] == "keynote"
    o.set_slide(3, "speech")
    assert o.follow == ""
    clk.t += 1000
    o.set_slide(5)                                             # the colleague's block: no advice
    assert [i for i in items(tips) if i["kind"] == "timeline"][-1]["advice"] is None


def test_checkpoints_give_the_advice(T, tmp_path):
    clk = Clock(T)
    o, tips = outline(T, tmp_path)
    o.set_slide(2)
    o.tick(clk.t)
    n0 = len([i for i in items(tips) if i["kind"] == "timeline"])
    clk.t += 30
    o.tick(clk.t)                                              # under 60 s and no checkpoint: nothing new
    assert len([i for i in items(tips) if i["kind"] == "timeline"]) == n0
    clk.t += 900                                               # past two thirds of the plan, still on slide 2
    o.tick(clk.t)
    tl = [i for i in items(tips) if i["kind"] == "timeline"][-1]
    assert "two_thirds" in o.checkpoints and tl["advice"] is not None


def test_slides_without_an_outline_still_track(T, tmp_path):
    """0.8.5: a deck attached during the call writes only slides.json; the tracker builds one section per slide."""
    clk = Clock(T)
    T.UI["lang"] = "en"
    T.MEETING["call_type"] = "presentation"
    stem = tmp_path / "call.md"
    (tmp_path / "call.slides.json").write_text(json.dumps({"slides": FIX["slides"]}))
    tips = tmp_path / "call.tips.jsonl"
    tips.write_text("")
    o, sl = T.Outline(stem, tips), T.Slides(stem, tips)
    o.slides_src = sl
    o.refresh()                                              # slides not read yet: nothing
    assert o.sections == []
    sl.refresh()
    o.refresh()
    assert [x["id"] for x in o.sections][:3] == ["sl1", "sl2", "sl3"] and o.sections[4]["who"] == "other"
    o.set_slide(2)
    clk.t += 400
    o.set_slide(3)
    tl = [i for i in items(tips) if i["kind"] == "timeline"][-1]
    assert tl["slide"] == 3 and tl["slide_el"] == 0 and tl["slide_sec"] == 210 and tl["behind"] >= 60
    o.refresh()                                              # unchanged slides: not rebuilt
    assert o.cur == 2
