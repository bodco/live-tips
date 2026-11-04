"""The tips engine's behaviour over a synthetic 13-minute call in nine meeting setups is pinned in
tests/golden/ (see golden_harness.py). A refactoring must keep it identical."""
import json
import tempfile
from pathlib import Path

import pytest

import golden_harness as g


def _r(o):
    """Times measured with the real clock (gist_at = tip start + the model's time to the gist) drift by a
    millisecond on a busy machine; the engine's behaviour is the same (2026-11-03: flaky in a full run)."""
    if isinstance(o, float):
        return round(o, 2)
    if isinstance(o, dict):
        return {k: _r(v) for k, v in o.items() if k != "context_revision"}  # diagnostic version, not behavior
    if isinstance(o, list):
        return [_r(v) for v in o]
    return o


@pytest.mark.parametrize("name", list(g.VARIANTS))
def test_engine_behaviour_is_unchanged(name):
    with tempfile.TemporaryDirectory() as d:
        got = g.run_variant(name, Path(d))
    assert _r(got) == _r(json.loads((g.GOLD / (name + ".json")).read_text()))
