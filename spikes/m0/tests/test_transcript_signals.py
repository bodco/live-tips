from conftest import FIX
from livetips_m0.rules import Rules
from livetips_m0.signals import Detector
from livetips_m0.transcript import load_call, parse_line, hms_to_s


def lines():
    return load_call(FIX / "demo-call.md", "Me")


def test_parse_and_timing():
    ls = lines()
    assert len(ls) == 8
    assert ls[1].speaker == "them" and ls[1].stag == "S1" and ls[1].lang == "en"
    assert ls[0].speaker == "me" and ls[0].stag is None
    assert ls[2].seg_end == hms_to_s("10:00:17.700") and ls[2].written > ls[2].seg_end


def test_marker_lines_are_skipped():
    assert parse_line("--- mic stalled, restarting 12:21:52 ---", 0, "Me") is None


def test_signals():
    d = Detector(Rules(), ["Alex", "Alexander"])
    ls = lines()
    s = d.detect(ls[2])          # name + question
    assert s.name_mention and s.question and s.route == "direct"
    assert d.detect(ls[4]).new_requirement and d.detect(ls[4]).route == "direct"
    assert d.detect(ls[5]).commitment and d.detect(ls[5]).trigger_hint == "pm_commitment"
    assert d.detect(ls[6]).route is None
    q = d.detect(ls[7])
    assert q.question and not q.second_person and q.route == "classify"
