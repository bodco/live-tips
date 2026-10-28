"""handle_inbox and the run loop's side jobs, pinned with a fake engine before the refactor."""
import json
from types import SimpleNamespace

from livetips_m0.commitments import norm_text
from livetips_m0.live import handle_inbox


class FakeEngine:
    def __init__(self):
        self.calls, self.written = [], []
        self.paused, self.proactive = False, False
        self.cfg, self.onme_ticked = {}, {}
        self.out_tips = SimpleNamespace(write=self.written.append)
        eng = self

        class Prompt:
            def set_meeting(self, ch):
                eng.calls.append(("set_meeting", ch))
                if ch.get("title") == "boom":
                    raise RuntimeError("x")
        self.prompt = Prompt()

    def on_request(self, kind, text=""):
        self.calls.append((kind, text))

    def reload_prep(self):
        self.calls.append(("reload",))

    def set_agenda_state(self, v):
        self.calls.append(("agenda", v))

    def commitment_closed(self, v):
        self.calls.append(("closed", v))


def setting(eng, key, value):
    handle_inbox(eng, json.dumps({"kind": "setting", "key": key, "value": value}))


def test_settings():
    eng = FakeEngine()
    setting(eng, "tips_paused", "True")
    setting(eng, "proactive", "on")
    assert eng.paused is True and eng.proactive is True and eng.cfg["proactive"] is True
    setting(eng, "proactive", "off")
    assert eng.proactive is False
    setting(eng, "title", "  Weekly " + "x" * 200)
    assert eng.cfg["title"].startswith("Weekly") and len(eng.cfg["title"]) == 120
    setting(eng, "title", "   ")
    setting(eng, "title", "boom")                          # a failing prompt does not break the inbox
    setting(eng, "call_lang", "mix")
    setting(eng, "call_lang", "uk+en+")
    setting(eng, "call_lang", "")
    setting(eng, "agenda_state", "2|done")
    setting(eng, "agenda_state", None)
    setting(eng, "onme_state", "Send the deck|done")
    setting(eng, "onme_state", "Call Ann|open")
    setting(eng, "onme_state", "|done")
    setting(eng, "commitment_closed", "c1")
    setting(eng, "unknown", "x")
    assert ("set_meeting", {"langs": ["uk", "en"]}) in eng.calls and eng.calls.count(("set_meeting", {"langs": ["uk", "en"]})) == 2
    assert ("agenda", "2|done") in eng.calls and ("agenda", "") in eng.calls and ("closed", "c1") in eng.calls
    assert eng.onme_ticked == {norm_text("Send the deck"): True, norm_text("Call Ann"): False}
    acks = [w["key"] for w in eng.written if w.get("kind") == "ack"]
    assert acks == ["tips_paused", "proactive", "proactive"]
    assert all(w["value"] is not None for w in eng.written)


def test_requests():
    eng = FakeEngine()
    for raw in ["not json", json.dumps({"text": "  "}), json.dumps({}), json.dumps({"text": "SOS"}),
                json.dumps({"text": "find: pilot start"}), json.dumps({"text": "find:  "}),
                json.dumps({"text": "Refresh context"}), json.dumps({"text": "off topic"}), json.dumps({"text": "When is the release?"})]:
        handle_inbox(eng, raw)
    assert eng.calls == [("sos", ""), ("find", "pilot start"), ("reload",), ("ask", "When is the release?")]


class LoopEngine:
    def __init__(self):
        self.lines, self.meetings, self.tips = [], [], [1, 2]
        self.budget = SimpleNamespace(call_spent=0.123456, state=lambda: "soft")

    def on_line(self, ln):
        self.lines.append(ln)

    def set_meeting(self, ch):
        self.meetings.append(ch)
        return True


def test_live_run_parts(tmp_path, monkeypatch):
    from livetips_m0 import live
    md = tmp_path / "c.md"
    md.write_text("# Live transcript: c\n[10:00:00] Me (en): old line\n")
    (tmp_path / "c.md.timing.jsonl").write_text("")
    inbox = tmp_path / "in.jsonl"
    inbox.write_text(json.dumps({"text": "old"}) + "\n")
    eng = LoopEngine()
    lr = live.LiveRun({"me_label": "Me"}, eng, md, inbox, from_start=False)
    assert lr.t_md.pos == md.stat().st_size and lr.t_in.pos == inbox.stat().st_size
    with md.open("a") as f:
        f.write("[10:00:05] Other (en): a new line\n[10:00:06] Me (en): mine\nnot a line\n")
    with (tmp_path / "c.md.timing.jsonl").open("a") as f:
        f.write(json.dumps({"t": "10:00:05", "ch": "them", "seg_end": "10:00:06.5", "written": "10:00:07"}) + "\nbad\n")
    lr.step()
    assert [l.text for l in eng.lines] == ["a new line"] and len(lr.pending) == 1
    assert eng.lines[0].seg_end == 36006.5 and eng.lines[0].written == 36007
    monkeypatch.setattr(live.time, "monotonic", lambda: 10 ** 9)
    monkeypatch.setattr(live, "now_sod", lambda: 42.0)
    lr.feed_ready()
    assert [l.text for l in eng.lines] == ["a new line", "mine"] and eng.lines[1].written == 42.0
    assert lr.summary() == {"lines": 2, "call_span_s": round(42.0 - 36007, 1), "tips": 2, "spent_usd": 0.1235}
    lr.feed(SimpleNamespace(seg_end=None, written=None), {"t": "x"})
    assert lr.last_written == 42.0
    state = tmp_path / "state"
    state.mkdir()
    lr.touch_state(state)
    assert (state / "listener").exists() and json.loads((state / "llm.json").read_text())["budget"] == "soft"
    lr.touch_state(None)
    lr.last_touch = 0
    lr.touch_state(tmp_path / "missing" / "dir")          # an OSError is ignored
    assert lr.last_touch == 10 ** 9
    st = tmp_path / "status.json"
    assert lr.follow_status(None) is False and lr.follow_status(st) is False
    st.write_text(json.dumps({"state": "stopped", "audience": "team", "call_type": ""}))
    assert lr.follow_status(st) is True and eng.meetings == [{"audience": "team"}]
    st.write_text("{bad")
    assert lr.follow_status(st) is False
    assert lr.timed_out(1, None) and lr.timed_out(0, 5) and not lr.timed_out(0, None)


def test_wait_for(tmp_path):
    from livetips_m0.live import wait_for
    wait_for(tmp_path / "never", limit_s=0.02, step=0.01)
    (tmp_path / "x").write_text("")
    wait_for(tmp_path / "x")
