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
    # OpenAI standard pricing checked 2026-11-04: developers.openai.com/api/docs/pricing (cached input = cache read)
    # 0.9.3: GPT-6 and 6.1 charge cache writes like Claude: 1.25x the input rate for 30 minutes (the 5m column), 2.5x
    # for 12 hours (the 1h column); developers.openai.com/api/docs/pricing, checked 2026-11-04.
    ("gpt-6-astra", (10.0, 12.5, 25.0, 1.0, 50.0)),
    ("gpt-6.1-sol", (2.0, 2.5, 5.0, 0.10, 10.0)),
    ("gpt-6.1-terra", (1.0, 1.25, 2.5, 0.05, 5.0)),
    ("gpt-6-luna", (0.10, 0.125, 0.25, 0.01, 0.50)),
    ("gpt-5.4-mini", (0.75, 0.0, 0.0, 0.075, 4.50)),
    # 0.9.3: Gemini paid tier, standard, checked 2026-11-04: ai.google.dev/gemini-api/docs/pricing. Caching is implicit:
    # no write charge (the 5m and 1h columns stay 0), cache read in the fourth column. Output includes thinking.
    # Google announced rises: see PRICE_CHANGES below.
    ("gemini-4-argon", (2.0, 0.0, 0.0, 0.10, 10.0)),
    ("gemini-3.8-flash", (0.75, 0.0, 0.0, 0.075, 3.75)),
    ("gemini-3.6-flash", (0.75, 0.0, 0.0, 0.075, 3.75)),
    ("gemini-3.5-flash-lite", (0.30, 0.0, 0.0, 0.03, 2.50)),
    ("gemini-3.1-flash-lite", (0.25, 0.0, 0.0, 0.025, 1.50)),
    ("haiku-5-5", (0.10, 0.125, 0.20, 0.01, 0.50)),     # prompts up to 100K tokens
    ("sonnet-5-5", (2.0, 2.5, 4.0, 0.10, 10.0)),
    ("opus-5-5", (4.0, 5.0, 8.0, 0.20, 20.0)),
    ("sonnet-5", (2.0, 2.5, 4.0, 0.20, 10.0)),
    ("opus-5", (5.0, 6.25, 10.0, 0.50, 25.0)),
    ("haiku-4-5", (1.0, 1.25, 2.0, 0.10, 5.0)),
    ("sonnet-4", (3.0, 3.75, 6.0, 0.30, 15.0)),
]


# (family substring, first day of the new price, prices): announced rises, checked 2026-11-04 on the same page.
PRICE_CHANGES = [
    ("gemini-4-argon", "2026-12-01", (4.0, 0.0, 0.0, 0.20, 20.0)),
    ("gemini-3.8-flash", "2027-01-01", (1.50, 0.0, 0.0, 0.15, 7.50)),
    ("gemini-3.6-flash", "2027-01-01", (1.50, 0.0, 0.0, 0.15, 7.50)),
]


def price_for(model: str, today=None):
    """The prices of a model on `today` (YYYY-MM-DD, default: today): an announced rise applies from its first day."""
    m = model.lower()
    today = today or time.strftime("%Y-%m-%d")
    for key, p in PRICES:
        if key in m:
            for fam, since, new in PRICE_CHANGES:
                if fam == key and today >= since:
                    return new
            return p
    return None


PLAN_PAID = ("agy/", "codex/", "claude-code/")    # 0.9.3: accounts paid by their plans never get an API price


def cost_usd(model, input_tokens, cache_write_5m, cache_write_1h, cache_read, output_tokens):
    if str(model or "").startswith(PLAN_PAID):
        return None
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

    def _ledger(self) -> dict:
        try:
            return json.loads(self.ledger.read_text())
        except (OSError, ValueError):
            return {}

    def month_spent(self) -> float:
        return float(self._ledger().get(self._month(), 0.0))

    def add(self, usd: float) -> None:
        self.call_spent += usd or 0.0
        try:                                   # an unreadable ledger stops here rather than being overwritten
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
