"""0.9.1 (owner): the call notes are written in the language the call was held in."""
from livetips_m0.callnotes import call_lang


def test_majority_of_line_tags():
    t = "# Live transcript: X\n- Languages: Я = en, allowed = en\n[13:00:58] Я (uk): Привіт\n[13:01:04] Співрозмовник [S1] (uk): Так\n[13:01:09] Я (en): ok\n"
    assert call_lang(t) == "uk"


def test_header_when_no_tags_and_default():
    assert call_lang("- Languages: Я = en, allowed = en\n") == "en"
    assert call_lang("nothing") == "uk"
