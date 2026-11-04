from livetips_m0 import agenda
from conftest import FIX
from test_engine import CFG, responder
from livetips_m0.providers import FakeProvider
from livetips_m0.replay import build_engine


def test_matching_rejects_ambiguity_and_changed_scope():
    old = [{"text": "Review deployment checklist for tomorrow", "state": "done"}]
    assert agenda.reconcile(old, ["Confirm deployment checklist for tomorrow"])[0]["state"] == "done"
    assert not agenda.reconcile(old, ["Confirm deployment checklist for today"])
    assert not agenda.reconcile(old, [old[0]["text"], old[0]["text"]])
    assert not agenda.same_question("Approve release 12 before rollout", "Approve release 13 before rollout")
    assert not agenda.same_question("Approve release before rollout", "Approve release after rollout")


def test_identity_preserves_now_through_rewording_and_late_click(tmp_path):
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    try:
        eng.set_agenda_items("- [ ] Deployment blockers\n- [ ] Authorization rollout")
        first, second = eng.agenda_ids
        eng.set_agenda_state(first + "|now")
        eng.set_agenda_state(second + "|skip")
        eng.set_agenda_items(f"- [ ] Rollout of authorization <!-- agenda:{second} -->\n- [ ] Blockers for deployment <!-- agenda:{first} -->\n- [ ] New item")
        assert [x["state"] for x in eng.agenda_strip()] == ["skip", "now", "todo"]
        assert eng.agenda_full[0] == "Rollout of authorization"
        eng.set_agenda_state(first + "|done")
        assert [x["state"] for x in eng.agenda_strip()] == ["skip", "done", "todo"]
        eng.set_agenda_items("- [ ] Different participant questions")
        eng.set_agenda_state(first + "|done")
        assert eng.agenda_strip()[0]["state"] == "todo"
    finally:
        eng.pool.shutdown(wait=True)


def test_duplicate_markers_are_not_trusted():
    brief = "- [ ] One <!-- agenda:q_1 -->\n- [ ] Two <!-- agenda:q_1 -->"
    assert agenda.marked_ids(brief, agenda.full_items(brief)) == ["", ""]


def test_refresh_undo_and_repeated_correction_keep_original_states(tmp_path):
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    try:
        eng.set_agenda_items("- [ ] Deployment status\n- [ ] Estimate")
        identity = eng.agenda_ids[0]
        eng.set_agenda_state(identity + "|done")
        eng.set_agenda_items("- [ ] Entirely new agenda")
        eng.undo_agenda_refresh()
        assert eng.agenda_ids[0] == identity
        assert eng.agenda_strip()[0]["state"] == "done"
        eng.correct_context("First correction")
        eng.correct_context("Second correction while preparing")
        eng.restore_agenda()
        assert eng.agenda_strip()[0]["state"] == "done"
        assert eng.agenda_ids[0] == identity
    finally:
        eng.pool.shutdown(wait=True)


def test_marked_question_with_changed_date_cannot_inherit_done():
    old = [{"id": "q_old", "text": "Deployment on 06.11", "state": "done"}]
    brief = "- [ ] Deployment on 07.11 <!-- agenda:q_old -->"
    assert agenda.match_identities(old, brief, agenda.full_items(brief)) == {}


def test_daily_and_client_standup_shapes_keep_states_separate(tmp_path):
    # Anonymized structures from the November daily/authorization stand-up agendas:
    # deployment approval, access, expiring domain, change request, external sandbox.
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    try:
        eng.set_agenda_items("- [ ] Approve production deployment\n- [ ] Renew test domain before 07.11\n- [ ] Estimate card change request")
        ids = eng.agenda_ids[:]
        eng.set_agenda_state(ids[0] + "|done")
        eng.set_agenda_state(ids[1] + "|skip")
        eng.set_agenda_state(ids[2] + "|now")
        eng.set_agenda_items(f"- [ ] Card change request estimate <!-- agenda:{ids[2]} -->\n- [ ] Approval for production deployment <!-- agenda:{ids[0]} -->\n- [ ] Renew test domain before 07.11 <!-- agenda:{ids[1]} -->\n- [ ] External sandbox update")
        assert [x["state"] for x in eng.agenda_strip()] == ["now", "done", "skip", "todo"]
        eng.correct_context("Different customer and goal")
        eng.set_agenda_items("- [ ] Approve production deployment")
        assert eng.agenda_strip()[0]["state"] == "todo"
    finally:
        eng.pool.shutdown(wait=True)


def test_correction_between_model_return_and_publication_drops_all_effects(tmp_path):
    from livetips_m0.transcript import parse_line
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    try:
        eng.history = [parse_line("[10:00:00] Other (en): Discuss deployment", 1, "Me")]
        eng._situation_ask = lambda ctx, new: {"topic": "Old topic", "agenda_done": [0]}
        apply = eng._apply_situation
        def corrected(*args):
            eng.correct_context("Different goal and participant")
            apply(*args)
        eng._apply_situation = corrected
        eng._situation_round()
        assert eng.situation is None
        assert eng.sit_last_line == -1
        assert eng.agenda_items == []
    finally:
        eng.pool.shutdown(wait=True)


def test_model_request_does_not_hold_state_lock(tmp_path):
    from livetips_m0.transcript import parse_line
    import threading
    eng, _ = build_engine(CFG, FIX / "demo-call.md", tmp_path / "out", lambda: 36001, FakeProvider(responder))
    try:
        eng.history = [parse_line("[10:00:00] Other (en): Discuss deployment", 1, "Me")]
        def answer(ctx, new):
            thread = threading.Thread(target=eng.correct_context, args=("Corrected during model request",))
            thread.start()
            thread.join(timeout=2)
            assert not thread.is_alive()
            return {"topic": "Obsolete answer"}
        eng._situation_ask = answer
        eng._situation_round()
        assert eng.situation is None
    finally:
        eng.pool.shutdown(wait=True)
