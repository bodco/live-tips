"""The tips engine's behaviour over a synthetic 13-minute call in nine meeting setups is pinned in
tests/golden/ (see golden_harness.py). A refactoring must keep it identical."""
import json
import tempfile
from pathlib import Path

import pytest

import golden_harness as g


@pytest.mark.parametrize("name", list(g.VARIANTS))
def test_engine_behaviour_is_unchanged(name):
    with tempfile.TemporaryDirectory() as d:
        got = g.run_variant(name, Path(d))
    assert got == json.loads((g.GOLD / (name + ".json")).read_text())
