from conftest import FIX
from test_engine import CFG, responder
from livetips_m0.providers import FakeProvider
from livetips_m0.replay import build_engine
from livetips_m0.transcript import parse_line


def test_backfilled_question_never_requests_model(tmp_path):
    provider = FakeProvider(responder)
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 18 * 3600, provider)
    line = parse_line("[17:15:48] Other (en): Mike, when is the release?", 1, "Me")
    eng.on_line(line)
    assert line in eng.history
    assert provider.calls == []
    assert eng.stale(line, "direct_question") == "expired"
    eng.pool.shutdown(wait=True)


def test_model_delay_and_midnight(tmp_path):
    clock = [86399.0]
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: clock[0], FakeProvider(responder))
    line = parse_line("[23:59:58] Other (en): Mike, when is the release?", 1, "Me")
    line.seg_end = 86399
    assert eng.stale(line, "direct_question") is None
    clock[0] = 5
    assert eng.stale(line, "direct_question") is None
    clock[0] = 25
    assert eng.stale(line, "direct_question") == "expired"
    eng.pool.shutdown(wait=True)


def test_old_context_cannot_stream_or_publish(tmp_path):
    from livetips_m0.engine import TipRun
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    line = parse_line("[10:00:00] Other (en): Mike, when is the release?", 1, "Me")
    run = TipRun(line, "direct_question", {"context_revision": 0}, None, "old")
    eng.context_revision = 1
    assert eng._early_hold(run) == "drop"
    assert eng._judge_tip(run, None) == "context_changed"
    eng.pool.shutdown(wait=True)


def test_agenda_compares_full_questions_and_can_clear(tmp_path):
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    prefix = "Please describe the workflow and responsibilities for this customer "
    eng.set_agenda_items("## Checklist\n- [ ] " + prefix + "before the call")
    eng.set_agenda_items("## Checklist\n- [ ] " + prefix + "after the call")
    assert eng.agenda_full == [prefix + "after the call"]
    eng.set_agenda_items("## Brief\nNo checklist")
    assert eng.agenda_items == []
    assert eng.agenda_sent == []
    eng.pool.shutdown(wait=True)


def test_context_correction_clears_agenda_and_reaches_requests(tmp_path):
    from livetips_m0.live import handle_inbox
    import json
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    eng.set_agenda_items("## Checklist\n- [ ] Questions for the previous participant")
    handle_inbox(eng, json.dumps({"kind": "context_correction", "text": "Today interview Sales, use the Sales questions."}))
    assert eng.context_revision == 1
    assert eng.agenda_items == []
    assert "Today interview Sales" in eng.correction_block()
    assert "Today interview Sales" in eng._situation_system()
    # once, in the cached brief block, not in every request
    assert any("Today interview Sales" in b["text"] for b in eng.prompt.blocks if b.get("cache"))
    eng.pool.shutdown(wait=True)


def test_failed_prep_after_correction_restores_agenda(tmp_path):
    from livetips_m0.live import handle_inbox
    import json
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    eng.set_agenda_items("## Checklist\n- [ ] Deployment status\n- [ ] Open estimate")
    eng.agenda_manual = {1: "skip"}
    handle_inbox(eng, json.dumps({"kind": "context_correction", "text": "Mike joins instead of Emily."}))
    assert eng.agenda_items == []
    handle_inbox(eng, json.dumps({"kind": "context_restore_agenda"}))
    assert [x["state"] for x in eng.agenda_strip()] == ["todo", "skip"]
    eng.pool.shutdown(wait=True)


def test_expired_line_still_counts_but_never_asks_for_a_tip(tmp_path):
    provider = FakeProvider(responder)
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 18 * 3600, provider)
    line = parse_line("[17:15:48] Other (en): Mike, when is the release?", 1, "Me")
    calls = []
    eng._every_fifth_line = lambda ln: calls.append(ln.line_id)
    eng.on_line(line)
    assert calls == [1]                     # the brief reload and the history still see it
    assert provider.calls == []
    eng.pool.shutdown(wait=True)


def test_line_without_timing_ages_from_its_arrival(tmp_path):
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36030, FakeProvider(responder))
    line = parse_line("[10:00:00] Other (en): a long answer of twenty eight seconds", 1, "Me")
    line.written = 36028                     # a 28 s segment that has just landed
    assert not eng._expired(line)
    eng.pool.shutdown(wait=True)


def test_late_red_warning_survives_twice_the_window(tmp_path):
    from livetips_m0.engine import TipRun
    clock = [36000 + 30]
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: clock[0], FakeProvider(responder))
    line = parse_line("[10:00:00] Other (en): So we can promise Friday?", 1, "Me")
    line.seg_end = 36000
    red = TipRun(line, "pm_commitment", {}, None, "r"); red.obj = {"level": "red", "trigger": "pm_commitment"}
    orange = TipRun(line, "add_fact", {}, None, "o"); orange.obj = {"level": "orange", "trigger": "add_fact"}
    eng._after = lambda ln: []
    assert eng._tip_stale(orange) == "stale_expired"
    assert eng._tip_stale(red) is None
    clock[0] = 36000 + 45
    assert eng._tip_stale(red) == "stale_expired"
    eng.pool.shutdown(wait=True)


def test_daily_and_client_warning_are_not_interviewer_filtered(tmp_path):
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    warning = {"gist": "Confirm the estimate with the developer", "phrase": "I will check the estimate and confirm it in writing.", "level": "red"}
    for call_type, audience in [("sync", "team"), ("sync", "client")]:
        eng.set_meeting({"call_type": call_type, "audience": audience})
        assert eng.meeting_block(warning, "pm_commitment", {}) is None
        assert eng.meeting_block({"phrase": "The deployment is ready."}, "direct_question", {}) is None
    eng.set_meeting({"call_type": "interview", "hiring_role": "interviewer"})
    # owner, 2026-11-04: the candidate's question to the interviewer gets an answer tip
    assert eng.meeting_block({"phrase": "We use the starter plan."}, "direct_question", {}) is None
    assert eng.meeting_block({"phrase": "We use the starter plan."}, "add_fact", {"to_pm": True}) is None
    # an automatic statement would answer for the interviewee: blocked; a follow-up question passes
    assert eng.meeting_block({"phrase": "The handoff took two weeks."}, "add_fact", {}) == "interviewer_answer"
    assert eng.meeting_block({"phrase": "What happened during the last handoff?"}, "add_fact", {}) is None
    eng.pool.shutdown(wait=True)


def test_rewritten_transcript_does_not_retrigger_same_lines(tmp_path):
    from livetips_m0.live import LiveRun
    md = tmp_path / "call.md"
    first = "[10:00:00] Other (en): Mike, when is the release?\n"
    md.write_text(first)
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    live = LiveRun(CFG, eng, md, from_start=True)
    live.read_lines()
    live.t_md.pos = 0  # recorder replaces the file after speaker correction
    md.write_text(first + "[10:00:01] Me (en): I will check the date.\n")
    live.read_lines()
    assert live.n == 2
    assert len(live.pending) == 2
    eng.pool.shutdown(wait=True)


def test_backchannel_saves_situation_call_but_keeps_decisions(tmp_path):
    eng, _ = build_engine(dict(CFG, situation=True), FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    line = parse_line("[10:00:00] Other (en): mhm", 1, "Me")
    eng._maybe_situation(line, eng.detector.detect(line), 36001)
    assert not eng.futures
    decision = parse_line("[10:00:01] Other (en): Yes, approve the deployment today.", 2, "Me")
    eng.history.append(decision)
    eng._maybe_situation(decision, eng.detector.detect(decision), 36001)
    assert eng.futures
    eng.drain(5)
    eng.pool.shutdown(wait=True)


def test_daily_refresh_keeps_done_and_skipped_but_new_questions_are_open(tmp_path):
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    eng.set_agenda_items("## Checklist\n- [ ] Deployment status\n- [ ] Old integration\n- [ ] Open estimate")
    eng.agenda_done = {0}
    eng.agenda_manual = {1: "skip"}
    eng.set_agenda_items("## Checklist\n- [ ] New requirement\n- [ ] Deployment status\n- [ ] Old integration\n- [ ] Open estimate")
    assert [x["state"] for x in eng.agenda_strip()] == ["todo", "done", "skip", "todo"]
    eng.correct_context("Different customer, new scope")
    eng.set_agenda_items("## Checklist\n- [ ] Deployment status")
    assert eng.agenda_strip()[0]["state"] == "todo"
    eng.pool.shutdown(wait=True)


def test_same_gist_within_five_minutes_is_dropped_red_is_not(tmp_path):
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    eng.tips.append({"gist": "🟠 Етапи угоди від першого контакту", "_at": 36000, "level": "orange"})
    assert eng._gist_repeat({"gist": "🟠 Етапи угоди від першого контакту до контракту", "level": "orange"}, 36046)
    assert not eng._gist_repeat({"gist": "🟠 Етапи угоди від першого контакту", "level": "orange"}, 36000 + 301)
    assert not eng._gist_repeat({"gist": "🟠 Хто веде контракт після дзвінка", "level": "orange"}, 36046)
    assert eng._diet({"gist": "🔴 Етапи угоди від першого контакту", "level": "red"}, 36046) != "gist_repeat"
    eng.pool.shutdown(wait=True)
