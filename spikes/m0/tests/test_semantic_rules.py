import os
import sys

import pytest

from livetips_m0.rules import Rules


def test_semantic_and_index_rules_load():
    r = Rules()
    assert r.semantic["schema_version"] == 1 and r.index["schema_version"] == 1
    t = r.semantic["thresholds"]
    assert 0 < t["index_min"] <= t["sos_min"] <= t["fact_min"] <= t["card_min"] < 1
    assert "Secrets" in r.index["skip_dirs"] and "_to_delete" in r.index["skip_dirs"]


@pytest.mark.skipif(not os.environ.get("LIVETIPS_LT_SRC"), reason="set LIVETIPS_LT_SRC to live-transcriber/src")
def test_parity_with_live_transcriber():
    sys.path.insert(0, os.environ["LIVETIPS_LT_SRC"])
    import semantic as S
    r = Rules()
    assert r.semantic["neutral_anchors"] == S.NEUTRAL_ANCHORS
    assert set(r.index["skip_dirs"]) == S.SKIP_DIRS
    assert r.index["secret_name_regex"] == S.SECRET_NAME.pattern
    assert r.index["max_bytes"] == S.MAX_BYTES and r.index["format_version"] == S.INDEX_VERSION
    import json
    from pathlib import Path
    cfg = Path(os.environ["LIVETIPS_LT_SRC"]).parent / "config.json"
    if cfg.exists():
        c = json.loads(cfg.read_text())
        t = r.semantic["thresholds"]
        assert c.get("semantic_margin", t["fact_margin"]) == t["fact_margin"]
        assert c.get("semantic_fact_min", t["fact_min"]) == t["fact_min"]
        assert c.get("semantic_card_min", t["card_min"]) == t["card_min"]
