"""0.8.7 (M, rules/usage.yaml): the local usage log keeps only event names and small parameters."""
import re
from pathlib import Path

import yaml

from livetips_m0 import usage

ROOT = Path(__file__).resolve().parents[3]


def test_line_shape_and_limits():
    rec = usage.line("tip_shown", {"kind": "risk"})
    assert set(rec) == {"t", "e", "p"} and rec["p"] == {"kind": "risk"}
    assert usage.line("tip_shown", {"kind": "x" * 81}) is None
    assert usage.line("tip_shown", {"text": "hi"}) is None
    assert usage.line("no_such_event") is None


def test_off_without_dir(tmp_path, monkeypatch):
    monkeypatch.delenv("LT_USAGE_DIR", raising=False)
    usage.log("help_now")
    monkeypatch.setenv("LT_USAGE_DIR", str(tmp_path))
    usage.log("help_now")
    files = list(tmp_path.glob("*.jsonl"))
    assert len(files) == 1 and '"e": "help_now"' in files[0].read_text()


def test_every_event_is_logged_somewhere():
    """Each event of rules/usage.yaml has a call site in the app or the engine."""
    events = yaml.safe_load((ROOT / "rules/usage.yaml").read_text())["events"]
    code = "".join(p.read_text(encoding="utf-8") for p in list((ROOT / "app/Sources").rglob("*.swift"))
                   + list((ROOT / "spikes/m0/livetips_m0").glob("*.py")) + list((ROOT / "app/Resources").rglob("*.js")))
    code = code.replace((ROOT / "app/Sources/LiveTipsCore/UsageLog.swift").read_text(), "")
    missing = [e for e in events if not re.search(r"""(?:UsageLog\.log|usage\.log|usage)\(\s*['"]%s['"]""" % e, code)]
    assert missing == [], missing
