"""One model request outside a call (Pacenote 0.8, F6): follow-up email, call memory, rehearsal.

The key comes from the environment (CLAUDE_API, set by the app for the child process only); the cost goes into the
same monthly ledger as the tips (LT_LEDGER). Tests pass a FakeProvider.
"""
import json
import os
from typing import Optional, Tuple

from .cost import BudgetGuard, cost_usd
from .engine import first_json


def provider_from_env():
    from .providers import AnthropicProvider
    return AnthropicProvider(os.environ.get("CLAUDE_API", ""), timeout=120.0, workspace_id=os.environ.get("CLAUDE_WORKSPACE", ""))


def ask_json(system: str, user: str, model: str, max_tokens: int = 1500, provider=None) -> Tuple[Optional[dict], Optional[float]]:
    prov = provider or provider_from_env()
    c = prov.complete(model=model, system=[{"text": system}], user=user, max_tokens=max_tokens, cache_ttl=None,
                      extra={"thinking": {"type": "disabled"}} if provider is None else None)
    if c.error:
        raise RuntimeError("model request failed: " + str(c.error)[:200])
    usd = cost_usd(c.model, c.input_tokens, c.cache_write_5m, c.cache_write_1h, c.cache_read, c.output_tokens)
    if usd and provider is None:
        try:
            BudgetGuard(os.environ.get("LT_LEDGER", "~/.livetips/spend.json"), 1e9, 1e9, 1e9).add(float(usd))
        except Exception:  # noqa: BLE001
            pass
    obj = first_json(c.text)
    return (obj if isinstance(obj, dict) else None), usd


def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False))
