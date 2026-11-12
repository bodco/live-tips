"""2026-11-12 (owner): the brief never gives the PM homework before the call; the PM has nowhere to look things up."""
from livetips_m0 import localprep as p


def test_brief_prompt_forbids_homework():
    s = p.BRIEF_SYS
    assert "Never give the PM homework before the call" in s
    assert "say so and what to\ncheck" not in s
    assert "real conflicts only, at most 3" in s


def test_speech_prompt_has_no_check_marks():
    assert '"[check]"' not in p.SPEECH_SYS
    assert "what to check before the call" not in p.SPEECH_SYS


def test_open_items_ask_on_the_call():
    assert "Things to check before the call" not in p.OPEN_SYS
    assert "Questions to ask on the call" in p.OPEN_SYS
