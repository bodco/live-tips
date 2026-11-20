"""0.26.2: the families ModelCatalog (Swift) marks as priced are the families cost.PRICES prices."""
import re
from pathlib import Path

from livetips_m0 import cost

APP = Path(__file__).absolute().parents[3]
SWIFT = APP / "app" / "Sources" / "LiveTipsCore" / "ModelCatalog.swift"


def test_priced_families_match_the_price_table():
    text = SWIFT.read_text(encoding="utf-8")
    block = re.search(r"pricedFamilies: \[String\] = \[(.*?)\n    \]", text, re.S)
    assert block, "pricedFamilies not found in ModelCatalog.swift"
    swift = set(re.findall(r'"([^"]+)"', block.group(1)))
    assert swift == {key for key, _ in cost.PRICES}


def test_a_model_without_a_price_costs_none():
    """Gemini 4 Hydrogen is listed by the pickers but has no price yet: no cost, no crash."""
    assert cost.price_for("gemini-4-hydrogen") is None
    assert cost.cost_usd("gemini-4-hydrogen", 1000, 0, 0, 0, 100) is None
