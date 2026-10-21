import json
import subprocess
import sys

from conftest import APP
from livetips_m0.cost import cost_usd
from livetips_m0.prompt import render_rules
from livetips_m0.rules import Rules


def test_rules_load_and_versions():
    r = Rules()
    assert r.version.count(".") == 2
    for d in (r.triggers, r.diet, r.priorities, r.meeting, r.asr_filters):
        assert d["schema_version"] == 1
    ids = [t["id"] for t in r.triggers["triggers"]]
    assert len(ids) == len(set(ids))
    cls_enum = set(r.classify_schema["properties"]["trigger"]["enum"])
    assert {i for i in ids if i not in ("unanswered_question", "timer_checkpoint", "silent_log")} <= cls_enum


def test_i18n_keys_match():
    en = json.loads((APP / "rules/i18n/en.json").read_text())
    uk = json.loads((APP / "rules/i18n/uk.json").read_text())
    assert set(en) == set(uk)


def test_generated_skill_section_is_current():
    p = subprocess.run([sys.executable, str(APP / "tools/gen_skill_section.py"), "--check"], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr


def test_prompt_has_no_long_dash():
    assert chr(0x2014) not in render_rules(Rules(), "en")


def test_anonymization_clean():
    p = subprocess.run([sys.executable, str(APP / "tools/check_anonymized.py")], capture_output=True, text=True)
    assert p.returncode == 0, p.stdout


def test_cost():
    # 10k cached read + 1k input + 150 output on a Sonnet 5.5 class id
    usd = cost_usd("claude-sonnet-5-5", 1000, 0, 0, 10000, 150)
    assert abs(usd - (1000 * 2 + 10000 * 0.10 + 150 * 10) / 1e6) < 1e-12
    assert cost_usd("unknown-model", 1, 0, 0, 0, 1) is None
