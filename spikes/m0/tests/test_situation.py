from livetips_m0.situation import fresh_asks, hms_to_s, jaccard, merge_risks, next_situation, speech_done


def test_hms_to_s():
    assert hms_to_s("01:02:03") == 3723
    assert hms_to_s("1:2") is None and hms_to_s(None) is None and hms_to_s("a:b:c") is None


def test_jaccard():
    assert jaccard("a b", "a b") == 1.0 and jaccard("", "x") == 0.0 and jaccard("a b", "b c") == 1 / 3


def test_risks_stay_and_near_duplicates_are_skipped():
    old = [{"what": "release slips a week", "who": "", "t": ""}]
    out = merge_risks(old, [{"what": "release slips a week again"}, {"what": "no QA", "who": "Ann" * 30}, "bad", {}])
    assert [r["what"] for r in out] == ["release slips a week", "no QA"] and len(out[1]["who"]) == 40
    assert len(merge_risks([], [{"what": "r%d unique%d" % (i, i)} for i in range(20)])) == 12


def test_speech_done_needs_the_pm_to_speak():
    assert speech_done({"speech_done": [1]}, [2, "3", "x"], pm_words=7) == [1]
    assert speech_done({"speech_done": [1]}, [2, "3", "x"], pm_words=8) == [1, 2, 3]


def test_old_asks_drop_and_unparsable_times_stay():
    asks = [{"what": "a", "t": "00:00:00"}, {"what": "b", "t": "00:09:00"}, {"what": "c", "t": "?"}]
    assert [a["what"] for a in fresh_asks(asks, 600, 360)] == ["b", "c"]


def test_next_situation_keeps_promises_and_clips():
    prev = {"theirs": [{"what": "send deck", "who": "Ann"}], "speech_done": [0]}
    sit = next_situation({"topic": "t" * 100, "mine": 1, "asks": [{"what": "q", "t": "00:00:10"}], "theirs": [{"what": "x"}],
                          "decisions": ["", "d"], "actions": [{"what": "a"}, {"who": "b"}]}, prev, 0, 20)
    assert len(sit["topic"]) == 80 and sit["mine"] is True and sit["theirs"] == prev["theirs"]
    assert sit["decisions"] == ["d"] and sit["actions"] == [{"what": "a"}] and sit["speech_done"] == [0]
    assert sit["asks"] == [{"what": "q", "t": "00:00:10"}] and sit["risks"] == []


def test_red_is_for_the_pm():
    from livetips_m0.engine import demote_red
    obj = {"level": "red", "gist": "\U0001f534 ask"}
    demote_red(obj, "question", {})
    assert obj == {"level": "orange", "gist": "\U0001f7e0 ask"}
    for span, trig in (({"to_pm": True}, "question"), ({"force_level": "red"}, "question"), ({}, "pm_commitment")):
        obj = {"level": "red", "gist": "g"}
        demote_red(obj, trig, span)
        assert obj["level"] == "red"


def test_tip_item_drops_empty_fields_but_keeps_late():
    from livetips_m0.engine import tip_item
    from livetips_m0.transcript import Line
    line = Line(line_id=3, t="00:00:05", speaker="them", label="", stag=None, lang="en", text="x")
    item = tip_item({"gist": "g", "phrase": ""}, "a3-1", line, "question", 7.0, late=False)
    assert item["late"] is False and "phrase" not in item and item["level"] == "orange" and item["trigger"] == "question"


def test_edges_the_mutants_found():
    assert jaccard("", "") == 0.0
    same_half = merge_risks([{"what": "a b c d"}], [{"what": "a b"}])
    assert len(same_half) == 1                                     # exactly 0.5 is a duplicate
    assert merge_risks([], [{"what": "x"}]) == [{"what": "x", "who": "", "t": ""}]
    assert [a["what"] for a in fresh_asks([{"what": "a", "t": "00:00:00"}, {"what": "b", "t": "?"}], 360, 360)] == ["a", "b"]
    assert fresh_asks([{"what": "b", "t": "?"}], 10, 0) == [{"what": "b", "t": "?"}]
    sit = next_situation({}, {}, 0, 0)
    assert (sit["topic"], sit["owner"], sit["floor"]) == ("", "", "")
