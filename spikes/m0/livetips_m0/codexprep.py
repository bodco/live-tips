"""Prepare a call through the user's ChatGPT account; Pacenote reads and writes the files itself."""
import argparse
import json
import time
from pathlib import Path

from . import localprep as prep
from .codex_provider import CodexProvider, MODEL, find_codex_cli


class Preparation:
    def __init__(self, request, provider):
        self.request = request
        self.provider = provider
        self.tokens = {"input": 0, "output": 0}

    def ask(self, name, system, user, max_tokens):
        prep.say(stage="model", pass_=name)
        result = self.provider.complete(model=MODEL, system=[{"text": system}], user=user,
                                        max_tokens=max_tokens, cache_ttl=None)
        self.tokens["input"] += result.input_tokens + result.cache_read
        self.tokens["output"] += result.output_tokens
        if result.error:
            raise RuntimeError(result.error)
        if not result.text.strip():
            raise RuntimeError("Codex returned an empty " + name)
        return result.text

    def contents(self):
        request = self.request
        codes = request.get("languages") or ["uk"]
        language = prep.LANGS.get(codes[0], codes[0])
        brief_language = prep.LANGS.get(request.get("brief_lang") or "uk", "Ukrainian")
        languages = ", ".join(prep.LANGS.get(code, code) for code in codes)
        prep.say(stage="pack")
        pack, sources = prep.build_pack(request)
        call = "Call: %s; when: %s; project: %s; audience: %s; type: %s; languages: %s" % (
            request["title"], request.get("when", ""), request.get("project_name", ""),
            request.get("audience", "auto"), request.get("call_type", "auto"), languages)
        pack = call + "\n\n" + pack
        head = '# Live Brief: %s (prep, %s, ChatGPT through Codex)' % (request["title"], request.get("when", ""))
        brief = prep.clean_md(self.ask("brief", prep.BRIEF_SYS.format(
            BRIEF_LANG=brief_language, CALL_LANG=language, HEAD=head), pack, 7000))
        speech = self.ask("speech", prep.SPEECH_SYS.format(BRIEF_LANG=brief_language, CALL_LANG=language), brief, 3000)
        brief = prep.insert_speech(brief, speech)
        card_rules = prep.skill_rules(request["skill"])
        cards = prep.as_list(self.ask("cards", prep.CARDS_SYS.format(
            BRIEF_LANG=brief_language, CALL_LANG=language, LANGS=languages), card_rules + "\n\n" + brief, 5000))
        facts = prep.as_list(self.ask("facts", prep.FACTS_SYS.format(LANGS=languages), brief + "\n\n" + pack, 8000))
        if not facts:
            raise RuntimeError("Codex returned no usable facts; the previous preparation is kept")
        return brief, cards, facts, sources

    def run(self):
        brief, cards, facts, sources = self.contents()
        base = self.request["base"]
        Path(base + ".brief.md").write_text(brief.rstrip() + "\n\nSources: " + "; ".join(sources) + "\n", encoding="utf-8")
        for kind, values in (("cards", cards), ("facts", facts)):
            Path(base + "." + kind + ".json").write_text(json.dumps(values, ensure_ascii=False, indent=1), encoding="utf-8")
        return sources


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True)
    request = json.loads(Path(parser.parse_args(argv).request).read_text(encoding="utf-8"))
    started = time.monotonic()
    result = {"ok": False, "model": MODEL, "tokens": {}, "sources": []}
    try:
        cli = find_codex_cli()
        if not cli:
            raise RuntimeError("Codex CLI is not installed")
        preparation = Preparation(request, CodexProvider(cli, timeout=300))
        result["sources"] = preparation.run()
        result["tokens"] = preparation.tokens
        result["ok"] = True
    except Exception as error:  # noqa: BLE001  the app restores the previous files on failure
        result["error"] = str(error)[:200]
    result["duration_s"] = int(time.monotonic() - started)
    prep.say(**result)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
