"""Prepare a call through the user's ChatGPT account; Pacenote reads and writes the files itself."""
import argparse
import json
import os
import re
import time
from pathlib import Path

from . import localprep as prep
from .codex_provider import CodexProvider, MODEL, find_codex_cli


class Preparation:
    label = "Codex"
    head_route = "ChatGPT through Codex"
    route = "codex"      # 0.9.7: the pack budget (prepcontext.BUDGETS); the cloud models hold more than Ollama

    def __init__(self, request, provider):
        self.request = request
        self.provider = provider
        self.tokens = {"input": 0, "output": 0}
        self.usd = 0.0       # 0.9.3: what the API passes cost (Settings > Usage); stays 0 for the ChatGPT account
        self.manifest, self.summary, self.slides_error, self._pack = [], {}, None, ""

    # 2026-11-11: the account's CLI sends each answer whole, so the app shows the step and a clock instead of 25%
    STEPS = ("brief", "speech", "cards", "facts", "slides")

    def ask(self, name, system, user, max_tokens):
        step = self.STEPS.index(name) + 1 if name in self.STEPS else 0
        prep.say(stage="model", pass_=name, step=step, steps=len(self.STEPS) - (0 if self.request.get("deck") else 1))
        result = self.provider.complete(model=MODEL, system=[{"text": system}], user=user,
                                        max_tokens=max_tokens, cache_ttl=None)
        self.tokens["input"] += result.input_tokens + result.cache_read
        self.tokens["output"] += result.output_tokens
        from .cost import cost_usd
        self.usd += cost_usd(result.model or "", result.input_tokens, result.cache_write_5m, result.cache_write_1h,
                             result.cache_read, result.output_tokens) or 0.0      # a failed pass is billed too
        if result.error:
            raise RuntimeError(result.error)
        if not result.text.strip():
            raise RuntimeError(self.label + " returned an empty " + name)
        return result.text

    def contents(self):
        request = self.request
        codes = request.get("languages") or ["uk"]
        language = prep.LANGS.get(codes[0], codes[0])
        brief_language = prep.LANGS.get(request.get("brief_lang") or "uk", "Ukrainian")
        languages = ", ".join(prep.LANGS.get(code, code) for code in codes)
        prep.say(stage="pack")
        pack, sources, self.manifest, self.summary = prep.build_pack_ex(request, route=self.route)
        call = "Call: %s; when: %s; project: %s; audience: %s; type: %s; languages: %s" % (
            request["title"], request.get("when", ""), request.get("project_name", ""),
            request.get("audience", "auto"), request.get("call_type", "auto"), languages)
        pack = call + "\n\n" + pack
        self._pack = pack
        head = '# Live Brief: %s (prep, %s, %s)' % (request["title"], request.get("when", ""), self.head_route)
        brief = prep.clean_md(self.ask("brief", prep.BRIEF_SYS.format(
            BRIEF_LANG=brief_language, CALL_LANG=language, HEAD=head), pack, 7000))
        speech = self.ask("speech", prep.SPEECH_SYS.format(BRIEF_LANG=brief_language, CALL_LANG=language), brief, 3000)
        brief = prep.insert_speech(brief, speech)
        card_rules = prep.skill_rules(request["skill"])
        cards = prep.as_list(self.ask("cards", prep.CARDS_SYS.format(
            BRIEF_LANG=brief_language, CALL_LANG=language, LANGS=languages), card_rules + "\n\n" + brief, 5000))
        facts = prep.as_list(self.ask("facts", prep.FACTS_SYS.format(LANGS=languages), brief + "\n\n" + pack, 8000))
        if not facts:
            raise RuntimeError(self.label + " returned no usable facts; the previous preparation is kept")
        brief = prep.with_context_line(brief, self.summary, request.get("brief_lang") or "en")
        return brief, cards, facts, sources

    SLIDES_CHUNK = 10          # slides per pass: a 31-slide talk in one answer timed out on the ChatGPT account
    SLIDES_MATERIAL = 120_000  # the deck, the speech documents and the brief; not the whole pack each time
    SLIDES_DOCS = 8            # 0.9.7: speech documents of a folder-only preparation (was 3); they share the room below

    def slides_material(self, brief):
        """The deck, the files the PM added (or the folder's speech documents) and the brief, for the talk passes."""
        from . import prepcontext
        request = self.request
        parts = [request.get("deck_lines") or "", "## The deck\n" + prepcontext.deck_text(request["deck"])]
        docs = [m["path"] for m in self.manifest if m.get("kind") == "file"]
        if not docs:      # a folder only: its speech or talk documents that made it into the pack
            docs = [m["path"] for m in self.manifest if m.get("kind") == "folder_file" and m.get("status") in ("full", "compressed")
                    and re.search(r"speech|спіч|промов|talk|script|slides|deck|презентац|доповід", os.path.basename(m["path"]), re.I)]
            docs = docs[:self.SLIDES_DOCS]
        room = self.SLIDES_MATERIAL - len(brief) - sum(len(x) for x in parts)
        for d in docs:
            text, _ = prepcontext.compress(prepcontext.read_text(d), max(4000, room // max(1, len(docs))), d)
            parts.append("## Speech document: " + d + "\n" + text)
        return "\n\n".join(parts) + "\n\n## The brief\n" + brief

    def slides(self, brief, pack):
        """0.9.7 (owner): a presentation with a deck gets its talk on these ways too (before: only on Claude), and a
        colleague's slides get their text as a backup, as on Claude (rules/presentation.yaml > backup). Ten slides
        per pass, so one answer stays short enough for the account's time limit."""
        from . import prepcontext
        request = self.request
        codes = request.get("languages") or ["uk"]
        system = prep.SLIDES_SYS.format(CALL_LANG=prep.LANGS.get(codes[0], codes[0])) + prep.talk_rules(request.get("skill"))
        material = self.slides_material(brief)
        try:
            nums = [int(s.get("n")) for s in json.loads(Path(request["deck"]).read_text(encoding="utf-8")).get("slides", [])
                    if str(s.get("n", "")).isdigit()]
        except Exception:  # noqa: BLE001
            nums = []
        nums = sorted(set(nums)) or [0]
        out = {"slides": []}
        for i in range(0, len(nums), self.SLIDES_CHUNK):
            part = nums[i:i + self.SLIDES_CHUNK]
            ask = "" if part == [0] else "\n\nIn THIS answer write only the deck slides %d-%d (n = %d..%d), all of them." % (
                part[0], part[-1], part[0], part[-1])
            got = prep.as_slides(self.ask("slides", system, material + ask, 9000))
            for k in ("talk_min", "qa_min"):
                if k in got and k not in out:
                    out[k] = got[k]
            have = {x.get("n") for x in out["slides"]}
            out["slides"] += [x for x in got.get("slides", []) if x.get("n") not in have]
        out["slides"].sort(key=lambda x: int(x["n"]) if str(x.get("n", "")).isdigit() else 0)
        return out

    def run(self):
        brief, cards, facts, sources = self.contents()
        base = self.request["base"]
        from .prepcontext import write_context
        write_context(base, self.manifest, self.summary)
        if self.request.get("deck"):
            try:
                talk = self.slides(brief, self._pack)
                if talk.get("slides"):
                    Path(base + ".slides.json").write_text(json.dumps(talk, ensure_ascii=False, indent=1), encoding="utf-8")
                else:
                    self.slides_error = "no slides in the reply"
            except Exception as error:  # noqa: BLE001  the brief, cards and facts stay; the talk is reported
                self.slides_error = str(error)[:200]
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
        result["context_summary"] = preparation.summary      # the manifest is in <base>.context.json
        if preparation.slides_error:
            result["slides_error"] = preparation.slides_error
        result["ok"] = True
    except Exception as error:  # noqa: BLE001  the app restores the previous files on failure
        result["error"] = str(error)[:200]
    result["duration_s"] = int(time.monotonic() - started)
    prep.say(**result)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
