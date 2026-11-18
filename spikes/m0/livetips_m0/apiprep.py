"""Prepare a call through the Claude API key without Claude Code (0.24.1, F4): the same context pack and passes as
the other packed ways (codexprep), asked through the Messages API with the key from Settings > AI
(ANTHROPIC_API_KEY, given to this process only). The first outside user had a working key and no Claude Code: the
preparation failed with "Claude Code is not installed" and the key was marked as out."""
import argparse
import json
import os
import time
from pathlib import Path

from . import localprep as prep
from .codexprep import Preparation
from .providers import AnthropicProvider

DEFAULT_MODEL = "claude-sonnet-5-5"


def model_for(name: str) -> str:
    """A Claude Code alias ("sonnet") means nothing to the API: the full model id, else the default."""
    n = (name or "").strip()
    return n if n.startswith("claude-") else DEFAULT_MODEL


class APIPreparation(Preparation):
    label = "Claude API"
    head_route = "Claude API"
    route = "api"         # the pack budget (prepcontext.BUDGETS)

    def __init__(self, request, provider, model):
        super().__init__(request, provider)
        self.model = model

    def ask(self, name, system, user, max_tokens):
        step = self.STEPS.index(name) + 1 if name in self.STEPS else 0
        prep.say(stage="model", pass_=name, step=step, steps=len(self.STEPS) - (0 if self.request.get("deck") else 1))
        result = self.provider.complete(model=self.model, system=[{"text": system}], user=user,
                                        max_tokens=max_tokens, cache_ttl=None)
        self.tokens["input"] += result.input_tokens + result.cache_read
        self.tokens["output"] += result.output_tokens
        from .cost import cost_usd
        self.usd += cost_usd(result.model or "", result.input_tokens, result.cache_write_5m, result.cache_write_1h,
                             result.cache_read, result.output_tokens) or 0.0
        if result.error:
            raise RuntimeError(result.error)
        if not result.text.strip():
            raise RuntimeError(self.label + " returned an empty " + name)
        return result.text


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True)
    request = json.loads(Path(parser.parse_args(argv).request).read_text(encoding="utf-8"))
    started = time.monotonic()
    model = model_for(request.get("model") or "")
    result = {"ok": False, "model": model, "tokens": {}, "sources": []}
    preparation = None
    try:
        key = os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("CLAUDE_API") or ""
        if not key:
            raise RuntimeError("No API key: add it in Settings > AI > Claude")
        headers = os.environ.get("ANTHROPIC_CUSTOM_HEADERS", "")
        ws = headers.split(":", 1)[1].strip() if headers.lower().startswith("anthropic-workspace-id:") else ""
        preparation = APIPreparation(request, AnthropicProvider(key, timeout=300, workspace_id=ws), model)
        result["sources"] = preparation.run()
        result["context_summary"] = preparation.summary
        if preparation.slides_error:
            result["slides_error"] = preparation.slides_error
        result["tokens"] = preparation.tokens
        result["ok"] = True
    except Exception as error:  # noqa: BLE001  the app restores the previous files on failure
        result["error"] = str(error)[:200]
    if preparation is not None:
        result["cost_usd"] = round(preparation.usd, 6)
    result["duration_s"] = int(time.monotonic() - started)
    prep.say(**result)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
