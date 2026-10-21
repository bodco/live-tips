"""Token pricing and spending guard.

Prices in USD per million tokens, from https://platform.claude.com/docs/en/about-claude/pricing
(checked 2026-10-21). Keep the date when updating.
"""
import json
import os
import time
from pathlib import Path

PRICES_CHECKED = "2026-10-21"
# family substring -> (input, cache_write_5m, cache_write_1h, cache_read, output)
PRICES = [
    ("haiku-5-5", (0.10, 0.125, 0.20, 0.01, 0.50)),     # prompts up to 100K tokens
    ("sonnet-5-5", (2.0, 2.5, 4.0, 0.10, 10.0)),
    ("opus-5-5", (4.0, 5.0, 8.0, 0.20, 20.0)),
    ("sonnet-5", (2.0, 2.5, 4.0, 0.20, 10.0)),
    ("opus-5", (5.0, 6.25, 10.0, 0.50, 25.0)),
    ("haiku-4-5", (1.0, 1.25, 2.0, 0.10, 5.0)),
    ("sonnet-4", (3.0, 3.75, 6.0, 0.30, 15.0)),
]


def price_for(model: str):
    m = model.lower()
    for key, p in PRICES:
        if key in m:
            return p
    return None


def cost_usd(model, input_tokens, cache_write_5m, cache_write_1h, cache_read, output_tokens):
    p = price_for(model)
    if not p:
        return None
    return (input_tokens * p[0] + cache_write_5m * p[1] + cache_write_1h * p[2] + cache_read * p[3]
            + output_tokens * p[4]) / 1e6


class BudgetGuard:
    """Soft and hard limits per call and a hard monthly cap kept in a small ledger file."""

    def __init__(self, ledger: str, call_soft_usd: float, call_hard_usd: float, monthly_hard_usd: float):
        self.ledger = Path(os.path.expanduser(ledger))
        self.call_soft = call_soft_usd
        self.call_hard = call_hard_usd
        self.monthly_hard = monthly_hard_usd
        self.call_spent = 0.0
        self.warned = False

    def _month(self):
        return time.strftime("%Y-%m")

    def month_spent(self) -> float:
        try:
            return float(json.loads(self.ledger.read_text()).get(self._month(), 0.0))
        except (OSError, ValueError):
            return 0.0

    def add(self, usd: float) -> None:
        self.call_spent += usd or 0.0
        try:
            data = json.loads(self.ledger.read_text()) if self.ledger.exists() else {}
        except ValueError:
            data = {}
        data[self._month()] = round(float(data.get(self._month(), 0.0)) + (usd or 0.0), 6)
        self.ledger.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.ledger.with_suffix(".tmp")
        tmp.write_text(json.dumps(data))
        tmp.replace(self.ledger)

    def state(self) -> str:
        """'ok', 'soft' (warn once) or 'hard' (model tips off)."""
        if self.call_spent >= self.call_hard or self.month_spent() >= self.monthly_hard:
            return "hard"
        if self.call_spent >= self.call_soft:
            return "soft"
        return "ok"
