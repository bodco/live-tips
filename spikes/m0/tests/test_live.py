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
