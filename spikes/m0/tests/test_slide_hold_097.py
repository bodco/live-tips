"""0.9.7 (owner, call of 11.11: the slide jumped 1 <-> 18 dozens of times). A slide set by hand holds for
rules/presentation.yaml > slide_sync > hold_s, and the other side's words move only one step forward, into a
colleague's section right after the current one."""
import json

from test_presentation_rules import Clock, T, items, outline  # noqa: F401  (T is the module fixture)


def rich(T, tmp_path):
    """The shared fixture with more words for the colleague's slide 5, so its section can win on their words."""
    o, tips = outline(T, tmp_path)
    secs = json.loads((tmp_path / "call.outline.json").read_text())["sections"]
    secs[4]["keywords"] += ["regions", "waves", "onboarding", "training"]
    (tmp_path / "call.outline.json").write_text(json.dumps({"sections": secs}))
    o.mtime = None
    o.refresh()
    return o, tips


ROLLOUT = "rollout word5 regions waves onboarding training"


def them(T, text, t):
    return T.Line(channel="them", t=t, lang="en", text=text)


def pos(tips):
    p = [i for i in items(tips) if i["kind"] == "outline_pos"]
    return p[-1]["slide"] if p else None


def test_a_manual_slide_holds_then_the_colleague_block_follows_forward(T, tmp_path):
    clk = Clock(T)
    o, tips = rich(T, tmp_path)
    o.set_slide(4)                                   # the PM moved to "Risks"; slide 5 "Rollout" is the colleague's
    for _ in range(3):
        o.check(them(T, ROLLOUT, clk.t))
        clk.t += 5
    assert pos(tips) == 4                            # held: 90 s after a manual move nothing moves by speech
    clk.t += T.PRESENT_HOLD_S
    for _ in range(3):
        o.check(them(T, ROLLOUT, clk.t))
        clk.t += 5
    assert pos(tips) == 5                            # then the colleague's next section follows without asking


def test_the_other_side_never_pulls_the_pm_back_into_a_colleague_block(T, tmp_path):
    clk = Clock(T)
    o, tips = rich(T, tmp_path)
    o.set_slide(7)                                   # the PM's "Pricing", after the colleague's slide 5
    clk.t += T.PRESENT_HOLD_S + 1
    for _ in range(6):
        o.check(them(T, ROLLOUT, clk.t))
        clk.t += 5
    assert pos(tips) == 7
    assert not [i for i in items(tips) if i["kind"] == "move_ask"]


def test_the_other_side_never_jumps_far_ahead(T, tmp_path):
    clk = Clock(T)
    o, tips = rich(T, tmp_path)
    o.set_slide(2)
    clk.t += T.PRESENT_HOLD_S + 1
    for _ in range(4):                               # slide 5 is the colleague's, but not the next section
        o.check(them(T, ROLLOUT, clk.t))
        clk.t += 5
    assert pos(tips) == 2


def test_hold_is_in_the_rules():
    from pathlib import Path
    import yaml
    r = yaml.safe_load((Path(__file__).absolute().parents[3] / "rules" / "presentation.yaml").read_text(encoding="utf-8"))
    assert r["slide_sync"]["hold_s"] == 90
    assert "backup" in r and r["backup"]["cards"]
