import datetime as dt
import json
import threading
import time

from conftest import FIX
from livetips_m0.live import run
from livetips_m0.providers import FakeProvider
from test_engine import CFG, responder


def test_live_tail_picks_up_appended_lines(tmp_path):
    md = tmp_path / "live-call.md"
    md.write_text("# Live transcript: live-call\n\n")
    tm = tmp_path / "live-call.md.timing.jsonl"
    tm.write_text("")
    src = [l for l in (FIX / "demo-call.md").read_text().splitlines() if l.startswith("[")]

    def writer():
        time.sleep(0.3)
        for line in src[:3]:
            now = dt.datetime.now()
            hms = now.strftime("%H:%M:%S")
            line = "[" + hms + "]" + line[10:]
            ch = "me" if "] Me " in line else "them"
            with md.open("a") as f:
                f.write(line + "\n")
            with tm.open("a") as f:
                f.write(json.dumps({"t": hms, "ch": ch, "seg_end": now.strftime("%H:%M:%S.%f")[:-3],
                                    "written": now.strftime("%H:%M:%S.%f")[:-3]}) + "\n")
            time.sleep(0.2)

    th = threading.Thread(target=writer)
    th.start()
    cfg = dict(CFG, budget=dict(CFG["budget"], ledger=str(tmp_path / "spend.json")))
    eng = run(cfg, md, tmp_path / "out", idle_min=0.03, provider=FakeProvider(responder, 0.01, 0.02), max_s=8)
    th.join()
    tips = (tmp_path / "out" / "live-call.app.tips.jsonl").read_text().splitlines()
    assert any(json.loads(t)["level"] == "red" for t in tips)
    summ = json.loads((tmp_path / "out" / "live-call.app.summary.json").read_text())
    assert summ["lines"] == 3


def test_inbox_requests_and_acks(tmp_path):
    from livetips_m0.live import handle_inbox
    from livetips_m0.replay import build_engine
    cfg = dict(CFG, budget=dict(CFG["budget"], ledger=str(tmp_path / "spend.json")), tips_out=str(tmp_path / "t.jsonl"))
    md = tmp_path / "c.md"
    md.write_text("# Live transcript: c\n")
    eng, stem = build_engine(cfg, md, tmp_path, lambda: 36000.0, FakeProvider(responder, 0.0, 0.0))
    handle_inbox(eng, json.dumps({"t": "10:00:00", "kind": "setting", "key": "audience", "value": "client"}))
    handle_inbox(eng, json.dumps({"t": "10:00:00", "kind": "setting", "key": "tips_paused", "value": "on"}))
    handle_inbox(eng, json.dumps({"t": "10:00:01", "text": "sos"}))
    handle_inbox(eng, json.dumps({"t": "10:00:02", "text": "What is the release date?"}))
    eng.drain(5)
    items = [json.loads(l) for l in (tmp_path / "t.jsonl").read_text().splitlines()]
    assert eng.paused is True
    assert any(i.get("kind") == "ack" and i["key"] == "audience" for i in items)
    assert any(i.get("kind") == "tip" and i["level"] == "red" for i in items)
    assert any(i.get("kind") == "answer" and i.get("q") == "What is the release date?" for i in items)


def test_call_context_block(tmp_path):
    from livetips_m0.context import build
    root = tmp_path / "proj"
    (root / "_notion").mkdir(parents=True)
    (root / "_notion" / "current-state.md").write_text("Release 2.4 on 15.01; payments retries in QA.")
    txt = build("Weekly sync with the client about the release", str(root), lt_cmd=None)
    assert "CALL CONTEXT FROM THE PM" in txt and "Release 2.4" in txt
    assert build("", None) == ""
