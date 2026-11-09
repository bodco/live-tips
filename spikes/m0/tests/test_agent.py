"""The call agent (0.9.6) with a fake SDK client: one session, costs, the gates, timeouts, the ledger."""
import asyncio
import json
import types

from livetips_m0 import agent as ag
from livetips_m0.cost import ProviderCaps


class ResultMessage:
    def __init__(self, result, total, turns=2, is_error=False, subtype="success"):
        self.result, self.total_cost_usd, self.num_turns = result, total, turns
        self.is_error, self.subtype, self.session_id = is_error, subtype, "s1"
        self.usage = {"input_tokens": 10, "output_tokens": 50, "cache_read_input_tokens": 1000,
                      "cache_creation_input_tokens": 200}


class FakeClient:
    def __init__(self, replies, delay=0.0):
        self.replies, self.delay, self.prompts, self.connected, self.interrupted = list(replies), delay, [], 0, 0
        self.cut, self.total = False, 0.0

    async def connect(self):
        self.connected += 1

    async def query(self, prompt):
        self.prompts.append(prompt)

    async def receive_response(self):
        end = asyncio.get_running_loop().time() + self.delay
        while not self.cut and asyncio.get_running_loop().time() < end:
            await asyncio.sleep(0.01)
        yield types.SimpleNamespace(kind="assistant")
        if self.cut:                       # interrupted: the CLI ends the turn with an error result
            self.cut = False
            yield ResultMessage("", self.total, is_error=True, subtype="error_during_execution")
            return
        r = self.replies.pop(0)
        self.total = r.total_cost_usd
        yield r

    async def interrupt(self):
        self.interrupted += 1
        self.cut = True
        self.delay = 0.0

    async def disconnect(self):
        pass


ANS = '{"answered": true, "gist": "42 hours", "phrase": "We have 42 hours left.", "items": ["42 h"], "sources": ["plan.md"]}'


def make(tmp_path, client, **acfg):
    cfg = {"project_root": str(tmp_path), "agent": dict({"enabled": True}, **acfg)}
    return ag.CallAgent(cfg, "sk-test", ctx=None, state_dir=str(tmp_path), client_factory=lambda a: client)


def test_one_session_for_the_call_and_cost_per_answer(tmp_path):
    c = FakeClient([ResultMessage(ANS, 0.066), ResultMessage(ANS, 0.074)])
    a = make(tmp_path, c)
    r1 = a.ask("Budget?", ["them: a", "them: b"], "English")
    r2 = a.ask("And the owner?", ["them: b", "them: c"], "English")
    a.close()
    assert c.connected == 1                                 # the session is kept
    assert r1["answered"] is True and abs(r1["cost_usd"] - 0.066) < 1e-9
    assert abs(r2["cost_usd"] - 0.008) < 1e-9               # the SDK total is cumulative
    assert abs(a.spent - 0.074) < 1e-9 and a.asks == 2
    assert "them: c" in c.prompts[1] and "them: a" not in c.prompts[1]   # only the new lines
    assert "English" in c.prompts[0]
    rows = [json.loads(x) for x in (tmp_path / "spend-ledger.jsonl").read_text().splitlines()]
    assert [r["job"] for r in rows] == ["agent", "agent"] and rows[0]["route"] == "api"
    assert rows[0]["cache_read"] == 1000 and abs(rows[1]["usd"] - 0.008) < 1e-6


def test_no_json_and_error_results(tmp_path):
    c = FakeClient([ResultMessage("I could not find it", 0.01), ResultMessage("", 0.02, is_error=True, subtype="error_max_turns")])
    a = make(tmp_path, c)
    assert a.ask("q", [], "English")["error"] == "no answer from the agent"
    r = a.ask("q", [], "English")
    a.close()
    assert "max_turns" in r["error"] and abs(r["cost_usd"] - 0.01) < 1e-9


def test_timeout_interrupts_and_drains(tmp_path):
    c = FakeClient([ResultMessage(ANS, 0.05), ResultMessage(ANS, 0.06), ResultMessage(ANS, 0.07)], delay=2.0)
    a = make(tmp_path, c, timeout_s=0.3)
    r = a.ask("q", [], "English")
    assert r["error"] == "the search took too long" and c.interrupted == 1
    r2 = a.ask("q2", [], "English")
    a.close()
    assert r2.get("answered") is True


def test_call_budget(tmp_path):
    c = FakeClient([ResultMessage(ANS, 0.5)])
    a = make(tmp_path, c, max_usd_per_call=0.4)
    assert a.call_budget_left()
    a.ask("q", [], "English")
    a.close()
    assert not a.call_budget_left()


def test_why_not(tmp_path):
    on = {"agent": {"enabled": True, "economy_file": str(tmp_path / "economy")}}
    assert ag.why_not({}, "k", sdk=True) == "off"
    assert ag.why_not(on, "", sdk=True) == "no_key"
    assert ag.why_not(on, "k", sdk=False) == "no_sdk"
    assert ag.why_not(on, "k", sdk=True) is None
    (tmp_path / "economy").write_text("1")
    assert ag.why_not(on, "k", sdk=True) is None          # 0.9.6 Б1: economy is a profile, not a reason
    e = ag.effective_cfg(dict(on, agent=dict(on["agent"], max_usd_per_call=1.0, proactive=True)))
    assert e["economy"] and e["model"] == "claude-haiku-5-5" and e["max_turns"] == 6 and e["max_usd_per_ask"] == 0.05
    assert e["max_usd_per_call"] == 0.25 and e["proactive"] is False
    assert ag.effective_cfg(dict(on, agent=dict(on["agent"], max_usd_per_call=0.1)))["max_usd_per_call"] == 0.1
    (tmp_path / "economy").unlink()
    assert ag.effective_cfg(on)["economy"] is False and ag.effective_cfg(on)["model"] == "claude-sonnet-5-5"
    led = tmp_path / "spend-ledger.jsonl"
    import time
    led.write_text(json.dumps({"at": time.strftime("%Y-%m-%dT10:00:00+0200"), "route": "api", "usd": 5.0}) + "\n")
    caps = ProviderCaps({"claude": 4.0}, led)
    assert ag.why_not(on, "k", caps, sdk=True) == "capped"


def test_new_lines_and_prompt():
    assert ag.new_lines(["a", "b", "c"], ["a", "b"]) == ["c"]
    p = ag.ask_prompt("What?", ["x"], "Ukrainian", True)
    assert "<transcript_data>" in p and "Ukrainian" in p and p.endswith("What?")


def test_options_are_read_only(tmp_path):
    """Without the SDK installed the options cannot be built; the lists themselves are checked."""
    assert "Bash" in ag.REMOVED and "Write" in ag.REMOVED and "WebFetch" in ag.REMOVED
    assert ag.BUILTIN == ["Read", "Grep", "Glob"]
    assert all(t.startswith("mcp__pacenote__") for t in ag.TOOL_NAMES)


# ---------- background searches (0.9.6 point 2) ----------
def test_background_search_has_its_own_share(tmp_path):
    c = FakeClient([ResultMessage(ANS, 0.03), ResultMessage(ANS, 0.05), ResultMessage(ANS, 0.06)])
    a = make(tmp_path, c, proactive=True, proactive_max_per_call=2, proactive_usd_per_call=0.04)
    r = a.ask("When is the export live?", ["them: when is the export live?"], "English", background=True, who="Emily C.")
    assert r["answered"] is True and r["background"] is True
    assert "BACKGROUND CHECK" in c.prompts[0] and "Emily C." in c.prompts[0]
    assert abs(a.bg_spent - 0.03) < 1e-9 and a.bg_asks == 1 and a.bg_budget_left()
    a.ask("And the pilot?", [], "English", background=True)          # $0.05 total: the background share is spent
    assert not a.bg_budget_left()
    assert a.ask("q3", [], "English", background=True)["skipped"] == "budget"
    assert a.ask("PM question", [], "English").get("answered") is True    # the PM's questions are not limited by it
    a.close()
    rows = [json.loads(x) for x in (tmp_path / "spend-ledger.jsonl").read_text().splitlines()]
    assert [bool(r.get("background")) for r in rows] == [True, True, False]


def test_background_count_limit_and_busy(tmp_path):
    c = FakeClient([ResultMessage(ANS, 0.01)])
    a = make(tmp_path, c, proactive=True, proactive_max_per_call=1)
    a._inflight = 1                                                    # a question is in flight: never queued
    assert a.ask("q", [], "English", background=True)["skipped"] == "busy" and a.bg_asks == 0
    a._inflight = 0
    a.ask("q", [], "English", background=True)
    assert a.ask("q2", [], "English", background=True)["skipped"] == "budget"
    a.close()


def test_a_pm_question_interrupts_a_background_search(tmp_path):
    import threading, time
    c = FakeClient([ResultMessage(ANS, 0.02), ResultMessage(ANS, 0.03)], delay=3.0)
    a = make(tmp_path, c, proactive=True)
    box = {}
    t = threading.Thread(target=lambda: box.setdefault("bg", a.ask("bg q", [], "English", background=True)))
    t.start()
    end = time.time() + 2
    while not a._bg_active and time.time() < end:
        time.sleep(0.01)
    assert a._bg_active
    c.delay = 0.0
    fg = a.ask("PM q", [], "English")
    t.join(5)
    a.close()
    assert c.interrupted == 1 and "error" in box["bg"]               # the background result is dropped
    assert fg.get("answered") is True and "BACKGROUND CHECK" not in c.prompts[-1]


def test_background_prompt():
    p = ag.background_prompt("Who tests the pilot?", "David K.", ["x"], "Ukrainian", False)
    assert "BACKGROUND CHECK" in p and "David K." in p and "Ukrainian" in p and "answered=false" in p


# ---------- economy mode v1 (0.9.6 Б1) ----------
def test_economy_switches_the_session_mid_call(tmp_path):
    eco = tmp_path / "economy"
    made = []

    def factory(a):
        c = FakeClient([ResultMessage(ANS, 0.05), ResultMessage(ANS, 0.06)])
        made.append((c, a.a["model"], a.a["max_turns"]))
        return c
    cfg = {"project_root": str(tmp_path), "agent": {"enabled": True, "proactive": True, "economy_file": str(eco)}}
    a = ag.CallAgent(cfg, "sk-test", ctx=None, state_dir=str(tmp_path), client_factory=factory)
    a.ask("q1", [], "English")
    eco.write_text("on")                                        # the PM turns economy on during the call
    r = a.ask("q2", [], "English")
    assert len(made) == 2 and made[0][1] == "claude-sonnet-5-5" and made[1][1:] == ("claude-haiku-5-5", 6)
    assert r["economy"] is True and abs(r["cost_usd"] - 0.05) < 1e-9     # a new session: its own running total
    assert a.ask("bg", [], "English", background=True)["skipped"] == "economy"
    assert abs(a.spent - 0.10) < 1e-9 and a.a["max_usd_per_call"] == 0.25
    eco.unlink()
    a.ask("q3", [], "English")
    a.close()
    assert len(made) == 3 and made[2][1] == "claude-sonnet-5-5"
    rows = [json.loads(x) for x in (tmp_path / "spend-ledger.jsonl").read_text().splitlines()]
    assert [bool(r.get("economy")) for r in rows] == [False, True, False]
