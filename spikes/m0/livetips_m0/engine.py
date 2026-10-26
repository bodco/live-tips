"""Event-driven tip engine: local signals -> (classify) -> tip -> diet -> window file.

Times: every timestamp in spans is "call seconds of day" from the injected clock, so it can be
compared with the recorder's seg_end. Monotonic time is used for durations of model calls.
"""
import json
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable, Dict, List, Optional

import jsonschema

from .cost import cost_usd
from .prompt import disabled_triggers
from .providers import HedgedProvider
from .signals import Detector
from .transcript import Line, s_to_hms

WORD = re.compile(r"\w+", re.UNICODE)

# Meeting concept in code (2026-10-23, from the skill's hiring.md, presentation.md, SKILL.md "Tip diet").
# Coach role: money, dates and scope asked of the PM get a red "no numbers now" tip.
COACH_MONEY_CUES = ["price", "cost", "rate", "salary", "start date", "notice period", "budget",
                    "цінов", "вартіст", "ставк", "зарплат", "дата старту", "дату старту", "бюджет"]
COACH_MONEY_WORDS = {"ціна", "ціни", "ціну", "ціні", "ціною", "rate", "rates", "cost", "costs"}
MEETING_EXEMPT_PER_MIN = 2           # hiring tips ignore the orange rate, max 2 per minute
INTERVIEWER_ANSWER_WORDS = 40        # a them answer this long gets at most one "Уточни" tip
TEAM_TIPS_PER_HOUR = 12              # team audience: non-red model tips per hour
QA_SHARE_MAX = 0.40                  # presentation Q&A: the PM's share below this for QA_WINDOW_S
QA_WINDOW_S = 60
PACING = re.compile(r"(time left|minutes? left|min left|pace|pacing|behind schedule|skip (the )?slides?|speed up|"
                    r"хвилин\w* (лишил|залишил)|залишилось \d+ ?хв|лишилось \d+ ?хв|темп|пропусти слайд|прискор|\bтаймінг|⏱)",
                    re.I | re.U)
OBSERVER_EVENT = ("Interview, role observer: the other side asked the candidate a question. Give ONE orange tip: gist = "
                  "the interviewer's question VERBATIM (merge rephrasings into one question, the 7-word limit does not "
                  "apply), phrase = what a strong answer contains, 4-5 sentences in the interview language, note = "
                  "'для порівняння, не для озвучення'. Never analyse the PM. trigger direct_question.")
INTERVIEWER_EVENT = ("Interview, role interviewer: the candidate just gave a long answer to the PM's question. If the answer "
                     "is vague (no numbers, no own role, no result) give ONE orange tip: gist starting with '🟠 Уточни: ', "
                     "phrase = the follow-up question the PM can ask now. Never suggest answers for the candidate. If the "
                     "answer is concrete, skip. trigger add_fact.")
COACH_QUESTION_EVENT = ("Interview, role coach: the PM is being asked a question. Give ONE red tip: gist = what is asked, "
                        "phrase = a ready opening sentence, items = situation, action, result with a number, only from the "
                        "brief, the fact book or the cards. trigger direct_question.")
COACH_MONEY_EVENT = ("Interview, role coach: the other side asks about money, dates or scope (price, rate, salary, start date, "
                     "notice period, budget). Give ONE red tip: gist like '🔴 Без цифр зараз', phrase = a calm sentence that "
                     "defers the number (for example 'I would like to understand the scope first and come back with a "
                     "number'), never a number. trigger direct_question.")
QA_EVENT = ("Presentation Q&A: someone in the audience asks a question after the talk. Answer it with one fact from the "
            "brief, the fact book or the cards, or skip. Never a timing or pacing tip. trigger direct_question.")


def meeting_role(meta: Optional[dict]) -> str:
    """observer, interviewer or coach on an interview call (legacy "candidate" = coach), else ""."""
    meta = meta or {}
    if meta.get("call_type") != "interview":
        return ""
    r = meta.get("hiring_role") or ""
    return "coach" if r == "candidate" else r


_HEAD_STR = r'"{}"\s*:\s*"((?:[^"\\]|\\.)*)"'


def partial_head(buf: str) -> Optional[dict]:
    """gist, level and topic from a streaming tip JSON once all three are complete (topic may be
    absent for red tips: red is shown on gist + level). None while incomplete or for a skip."""
    if '"skip"' in buf[:40]:
        return None
    out = {}
    for k in ("gist", "level", "topic"):
        m = re.search(_HEAD_STR.format(k), buf)
        if m:
            try:
                out[k] = json.loads('"' + m.group(1) + '"')
            except ValueError:
                return None
    if not out.get("gist") or out.get("level") not in ("red", "orange", "info"):
        return None
    if out["level"] != "red" and "topic" not in out:
        return None
    return out


def first_json(text: str) -> Optional[dict]:
    i = text.find("{")
    while i >= 0:
        try:
            obj, _ = json.JSONDecoder().raw_decode(text[i:])
            if isinstance(obj, dict):
                return obj
        except ValueError:
            pass
        i = text.find("{", i + 1)
    return None


def jaccard(a: str, b: str) -> float:
    x, y = set(WORD.findall(a.lower())), set(WORD.findall(b.lower()))
    if not x or not y:
        return 0.0
    return len(x & y) / len(x | y)


class JsonlWriter:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()
        path.parent.mkdir(parents=True, exist_ok=True)

    def write(self, obj: dict) -> None:
        with self.lock, self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(obj, ensure_ascii=False, default=lambda o: str(type(o).__name__)) + "\n")


# 2026-10-26 review: the engine keeps a running picture of the call (Haiku, every ~10 s) instead of
# judging every line alone: the topic and whose it is, open asks to the PM, what the PM took on,
# decisions, which speech points were said. The window shows it as a status line and an "On me" panel.
SITUATION_SYS = """You keep the running state of a video call for a project manager (the PM). The PM's lines are labelled "{me}"; the PM is addressed as: {aliases}. The PM's own projects: {projects}. Participants: {people}. Today: {today}.
Return JSON only, no prose:
{{"topic": "<what is discussed now, max 6 words, in {lang}>", "owner": "<who leads this topic: a name, PM, or empty>", "mine": true|false, "floor": "<who speaks now: a name or PM>",
 "asks": [{{"id": "a1", "t": "<HH:MM:SS of the line>", "who": "<name>", "what": "<what the PM is asked, max 12 words, in {lang}>", "type": "question|request|update"}}],
 "actions": [{{"id": "m1", "what": "<what the PM must do, max 12 words, in {lang}>", "due": "<day or date, or empty>", "from": "<who asked, or PM>"}}],
 "decisions": ["<a decision made on this call, max 14 words, in {lang}>"],
 "speech_done": [<numbers of the PM's speech points already said aloud by the PM>]}}
Rules:
- mine = the topic is about the PM's projects or work, or the PM is asked or assigned something in it. Someone else's update about their own project is not mine.
- asks = OPEN questions or requests TO THE PM: by name, by "you" after the PM spoke, or about the PM's projects; also a request said in the third person ("Alex will check"). type update = the PM is asked for their status or given the floor for their update (also by a nickname or short form of the PM's name, "давай", "твоя черга", "over to you", or the host moving to the PM's projects). Remove an ask once the PM answered it or did it. Questions to other people, and questions the PM asked others, are not asks.
- actions = everything the PM took on or was given on this call (keep them all until the call ends, update the due date when it changes). Not other people's tasks.
- decisions = only decisions actually agreed aloud, keep them all.
- speech_done = only points the PM said aloud in the PM's own lines ("{me}"); nobody else's update counts. Empty until the PM gives the update.
- Keep the ids of items you keep; new items get new ids. Never invent: only what was said."""

SITUATION_STRONG = re.compile(r"(\?|\b(you|your|ти|тобі|тебе|твій|твоя|ваш|вам|вас|can you|could you|зможеш|можеш|глянь|подивись|перевір|скинь|надішли|зроби)\b)", re.I)

# "Your turn", "your turn soon", "pause: you can start" (PM sync review 2026-10-23).
TURN_GIST = re.compile(r"(твоя черга|твій черг|черга .{0,12}тебе|можеш почати|your turn|you can start|over to you)", re.I)


class Engine:
    def __init__(self, *, cfg: dict, rules, provider, prompt, out_dir: Path, stem: str,
                 clock: Callable[[], float], budget=None):
        self.cfg = cfg
        self.rules = rules
        self.provider = provider
        self.prompt = prompt
        self.clock = clock
        self.budget = budget
        self.detector = Detector(rules, cfg.get("name_aliases", []))
        self.models = cfg["models"]                      # {"classify": id, "tip": id}
        # M2 hedging: a second request when the first one is slow (cfg "hedge", on by default).
        hg = cfg.get("hedge", {}) if isinstance(cfg.get("hedge"), dict) else {}
        if hg.get("enabled", True) and not isinstance(provider, HedgedProvider):
            after = dict({"classify": 2.0, "tip": 3.0}, **(hg.get("after_s") or {}))
            by_model = {}
            for role, mid in self.models.items():
                if mid and role in after:
                    by_model[mid] = min(after[role], by_model.get(mid, after[role]))
            self.provider = provider = HedgedProvider(provider, by_model, on_extra=self._extra_usage)
        self.ttl = cfg.get("cache_ttl", "1h")
        self.direct_enabled = cfg.get("direct_route", True)
        self.classify_enabled = bool(self.models.get("classify"))
        self.periodic_s = cfg.get("periodic_classify_s", 20)
        d = rules.diet
        self.rate_s = cfg.get("active_rate_seconds", d["active_rate_seconds"])
        self.pm_window = d["pm_speaking_window_s"]
        self.topic_sim = d["topic_similarity_min"]
        self.stale_s = d["stale_after_s"]
        self.history: List[Line] = []
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=cfg.get("max_parallel_calls", 4))
        self.futures = []
        self.tips: List[dict] = []
        self.last_nonred_emit: Optional[float] = None
        self.last_classify_at: Optional[float] = None
        self.classify_busy = False
        self.classify_pending: Optional[Line] = None
        self.tipped_lines = set()
        self.out_tips = JsonlWriter(Path(cfg["tips_out"]) if cfg.get("tips_out") else out_dir / (stem + ".app.tips.jsonl"))
        self.out_llm = JsonlWriter(out_dir / (stem + ".app.llm.jsonl"))
        self.out_timing = JsonlWriter(out_dir / (stem + ".app.timing.jsonl"))
        self.tip_validator = jsonschema.Draft202012Validator(rules.model_tip_schema)
        self.cls_validator = jsonschema.Draft202012Validator(rules.classify_schema)
        self.paused = False
        # The first tip call writes the prompt cache; parallel first calls would each pay the write.
        self.tip_cache_warm = threading.Event()
        self.tip_warm_lock = threading.Lock()
        self.red_repeat_s = d.get("red_repeat_window_s", 60)
        self.diet_lock = threading.Lock()     # diet check + "shown" bookkeeping are one step
        # Names the PM gave to voices in the tips window (<stem>.speakers.json, written by the recorder).
        self.speakers = SpeakerNames(cfg.get("speakers_file"))
        self.clarified_for = set()            # interviewer: PM question line ids that already got "Уточни"
        # 2026-10-23 PM sync review: a question to anyone on the call may be one the PM is expected to
        # answer or add to; the addressee is ignored (cfg "answer_any", on by default).
        self.answer_any = cfg.get("answer_any", True)
        # 2026-10-26: "Зафіксуй / Можеш додати" by the periodic classify only when proactive is on.
        self.proactive = cfg.get("proactive", False)
        self.situation: dict = {}
        self.sit_busy = False
        self.sit_pending = False
        self.sit_last_at: Optional[float] = None
        self.sit_last_line = -1
        self.sit_interval = cfg.get("situation_interval_s", 10)
        self.sit_enabled = cfg.get("situation", True) and bool(self.models.get("classify"))
        self.sit_asks_tipped = set()
        self.speech_items: List[str] = []
        self.speech_item: Optional[dict] = None
        self.ask_log: List[dict] = []
        mt = cfg.setdefault("max_tokens", {})
        if isinstance(mt, dict) and mt.get("tip", 0) and mt["tip"] < 700:
            mt["tip"] = 700                   # 300 cut the two best tips of the PM sync (long Ukrainian phrase)

    # ---------- input ----------
    def on_line(self, line: Line) -> None:
        now = self.clock()
        with self.lock:
            self.history.append(line)
        if hasattr(self.prompt, "refresh_facts") and line.line_id % 5 == 0 and self.prompt.refresh_facts():
            self.out_timing.write({"line_id": line.line_id, "src": line.t, "outcome": "facts_reloaded"})
        sig = self.detector.detect(line)
        span = {"line_id": line.line_id, "src": line.t, "speaker": line.speaker, "seg_end": line.seg_end,
                "written": line.written, "available_at": now, "signals": sig.tags,
                "to_pm": bool(sig.name_vocative or (sig.question and sig.second_person))}
        if self.paused or (self.budget and self.budget.state() == "hard"):
            return
        self._maybe_situation(line, sig, now)
        mh = self.meeting_hint(line, sig, now)
        if mh:
            span["route"] = "direct"
            span["meeting"] = mh["kind"]
            span["event"] = mh["event"]
            if mh.get("level"):
                span["force_level"] = mh["level"]
            if mh.get("exempt"):
                span["rate_exempt"] = True
            self._submit_tip(line, mh["trigger"], span)
            return
        if meeting_role(self.meta()) == "observer":
            return                            # observer: only the question tips above, nothing after the answer
        route = sig.route if self.direct_enabled else ("classify" if sig.route else None)
        if not route and self.answer_any and line.speaker == "them" and sig.question:
            route = "classify"                # a question to anyone: the PM may answer or add (2026-10-23)
        # Meeting concept (2026-10-23): triggers the skill switches off for this call type / audience.
        off = disabled_triggers(getattr(self.prompt, "meta", None))
        if route and sig.trigger_hint in off:
            span["off"] = sig.trigger_hint
            route = "classify" if (sig.question or sig.name_mention) and sig.trigger_hint not in ("pm_commitment", "new_requirement") else None
        if route == "direct":
            span["route"] = "direct"
            self._submit_tip(line, sig.trigger_hint, span)
        elif route == "classify" and self.classify_enabled and self.cfg.get("parallel_tip", True) \
                and (sig.name_vocative or (sig.question and sig.second_person)) and not sig.third_person:
            # 2026-10-26 replay: a question to anyone ran Sonnet in parallel 30 times per call for 3 tips;
            # now only a question to the PM (by name or "you") runs in parallel, others wait for classify.
            # 2026-10-23: a likely trigger runs classify and the tip at once; classify only vetoes the
            # tip before it is shown (saves the 1.3 s classify step on about 20% of tips).
            span["route"] = "parallel"
            gate = {"event": threading.Event(), "need_tip": None, "obj": None}
            span["gate"] = gate
            tip_span = dict(span)
            self._submit_classify(line, span)
            self._submit_tip(line, sig.trigger_hint, tip_span)
        elif route == "classify" and self.classify_enabled:
            span["route"] = "classify"
            self._submit_classify(line, span)
        elif route == "classify" and not self.classify_enabled:
            span["route"] = "tip_only"
            self._submit_tip(line, sig.trigger_hint, span)
        elif self.proactive and line.speaker == "them" and self.classify_enabled and (
                self.last_classify_at is None or now - self.last_classify_at >= self.periodic_s):
            span["route"] = "periodic"
            self._submit_classify(line, span)

    # ---------- model roles ----------
    def _earlier(self, line: Line) -> List[str]:
        """Lines older than the live tail, up to `context_earlier_s` back (default 8 min)."""
        span = self.cfg.get("context_earlier_s", 240)
        if not span:
            return []
        with self.lock:
            hist = [h for h in self.history if h.line_id <= line.line_id]
        end = line.t_s
        out = []
        for h in hist:
            if 90 < end - h.t_s <= 90 + span:
                out.append("[{}] {}: {}".format(h.t, self.speakers.who(h), h.text[:300]))
        return out[-80:]

    def _tail(self, line: Line) -> List[str]:
        with self.lock:
            hist = [h for h in self.history if h.line_id <= line.line_id]
        end = line.t_s
        out = []
        for h in hist:
            if end - h.t_s <= 90:
                out.append("[{}] {}: {}".format(h.t, self.speakers.who(h), h.text))
        return out[-40:]

    def _state(self) -> dict:
        """tips_given carries the numbers already shown (review 2026-10-23: "63 h" was shown three times
        because the state held only gists)."""
        with self.lock:
            recent = [t for t in self.tips if not t.get("partial")][-10:]
        given = []
        for t in recent:
            nums = sorted(set(re.findall(r"\d[\d.,:%]*", " ".join([t.get("phrase", "")] + list(t.get("items") or [])))))
            given.append(t["gist"] + ((" [" + ", ".join(nums[:6]) + "]") if nums else ""))
        st = {"tips_given": given, "now": s_to_hms(self.clock())}
        sit = self.situation
        if sit:
            st["situation"] = {"topic": sit.get("topic", ""), "owner": sit.get("owner", ""), "mine": sit.get("mine"),
                               "open_asks_to_pm": [a.get("what", "") for a in sit.get("asks") or []][:4]}
        return st

    # ---------- freshness checks (code, not prompt) ----------
    def _after(self, line: Line) -> List[Line]:
        with self.lock:
            return [h for h in self.history if h.line_id > line.line_id]

    def stale(self, line: Line, trigger: str, obj: Optional[dict] = None) -> Optional[str]:
        """Review 2026-10-23: in 38 of 52 late tips the trigger was already resolved when the tip came.
        A question to the PM or the PM's turn is closed once the PM has spoken after it (two or more
        of the PM's lines, or one long one), or once two other lines moved the talk on without it.
        "Fix owner/date" is closed when an owner or a date was named after the trigger."""
        after = self._after(line)
        if not after:
            return None
        pm = [h for h in after if h.speaker == "me"]
        if trigger in ("your_turn", "direct_question"):
            if len(pm) >= 2 or any(len(h.text) > 80 for h in pm):
                return "pm_answered"
            if len([h for h in after if h.speaker == "them"]) >= 3 and not pm:
                return "talk_moved_on"
        if trigger == "fix_owner_date":
            txt = " ".join(h.text for h in after).lower()
            if re.search(r"\b(by|till|until|до|на|в)\s+(monday|tuesday|wednesday|thursday|friday|понеділ|вівтор|серед|четвер|п.ятниц|завтра|tomorrow|\d{1,2}[./]\d{1,2})", txt) \
                    or re.search(r"\b(i will|i'll|я зроблю|я візьму|беру на себе|will do|візьм)", txt):
                return "owner_or_date_said"
        if obj and obj.get("topic"):
            said = " ".join(h.text for h in after).lower()
            nums = re.findall(r"\d[\d.,]*", " ".join([obj.get("phrase", "")] + list(obj.get("items") or [])))
            if nums and all(n in said for n in nums):
                return "numbers_already_said"
        return None

    def validate_facts(self, obj: dict, line: Line) -> dict:
        """Numbers in items must exist in the brief, the fact book, the cards or the transcript so far
        (review 2026-10-23: 17 invented facts in 72 weak app tips). Offending items are dropped; a
        phrase with an unseen number loses the number to the gist's topic only when nothing is left."""
        corpus = self.prompt.corpus()
        with self.lock:
            corpus += " " + " ".join(h.text for h in self.history[-400:])
        corpus = corpus.lower()

        def ok(text: str) -> bool:
            for n in re.findall(r"\d[\d.,]*\d|\d", text or ""):
                n = n.rstrip(".,")
                if n and len(n) > 1 and n not in corpus:
                    return False
            return True
        items = [i for i in (obj.get("items") or []) if ok(i)]
        dropped = len(obj.get("items") or []) - len(items)
        obj["items"] = items
        if dropped:
            obj["_dropped_items"] = dropped
        if obj.get("phrase") and not ok(obj["phrase"]):
            obj["_unseen_number_in_phrase"] = True
        return obj

    def _extra_usage(self, c) -> None:
        """The losing request of a hedged pair finished: it is billed, so it counts."""
        usd = cost_usd(c.model, c.input_tokens, c.cache_write_5m, c.cache_write_1h, c.cache_read, c.output_tokens)
        if self.budget and usd:
            self.budget.add(usd)
        self.out_llm.write({"at": s_to_hms(self.clock()), "role": "hedge_extra", "model": c.model,
                            "ttft_ms": c.ms(c.t_first_token), "total_ms": c.ms(c.t_done),
                            "input": c.input_tokens, "cache_read": c.cache_read, "cache_write_5m": c.cache_write_5m,
                            "cache_write_1h": c.cache_write_1h, "output": c.output_tokens,
                            "usd": round(usd, 6) if usd is not None else None, "error": c.error})

    def _call(self, role: str, line: Line, event: str, on_text=None):
        user = self.prompt.user(role, event, self._tail(line), self._state(), self._earlier(line))
        max_tokens = self.cfg.get("max_tokens", {}).get(role, 60 if role == "classify" else 300)
        extra = (self.cfg.get("request_extra") or {}).get(role)
        c = self.provider.complete(model=self.models[role], system=self.prompt.blocks, user=user,
                                   max_tokens=max_tokens, cache_ttl=self.ttl, extra=extra, on_text=on_text)
        usd = cost_usd(c.model, c.input_tokens, c.cache_write_5m, c.cache_write_1h, c.cache_read, c.output_tokens)
        if self.budget and usd:
            self.budget.add(usd)
        self.out_llm.write({"at": s_to_hms(self.clock()), "role": role, "model": c.model, "line_id": line.line_id,
                            "ttft_ms": c.ms(c.t_first_token), "gist_ms": c.ms(c.t_gist), "total_ms": c.ms(c.t_done),
                            "input": c.input_tokens, "cache_read": c.cache_read, "cache_write_5m": c.cache_write_5m,
                            "cache_write_1h": c.cache_write_1h, "output": c.output_tokens,
                            "usd": round(usd, 6) if usd is not None else None, "error": c.error,
                            "stop": c.stop_reason, "hedge": c.hedge,
                            "text_head": None if c.error else c.text[:160],
                            "text": c.text if (self.cfg.get("debug_log_text") and not c.error) else None})
        return c

    def _submit_classify(self, line: Line, span: dict) -> None:
        with self.lock:
            if self.classify_busy:
                self.classify_pending = line      # coalesce: only the newest waiting line is classified next
                span["coalesced"] = True
                self.out_timing.write(dict(span, outcome="classify_coalesced"))
                return
            self.classify_busy = True
            self.last_classify_at = self.clock()
        self.futures.append(self.pool.submit(self._run_classify, line, span))

    def _run_classify(self, line: Line, span: dict) -> None:
        try:
            span["classify_start"] = self.clock()
            c = self._call("classify", line, "classify")
            span["classify_done"] = self.clock()
            span["classify_ms"] = c.ms(c.t_done)
            obj = first_json(c.text) if not c.error else None
            if c.error or obj is None or list(self.cls_validator.iter_errors(obj)):
                span["outcome"] = "classify_error" if c.error else "classify_invalid"
                span["error"] = c.error
                if span.get("gate") is not None:
                    g = span.pop("gate"); g["need_tip"] = None; g["event"].set()   # no verdict: the tip decides
                self.out_timing.write(span)
            elif span.get("gate") is not None:
                gate = span.pop("gate")
                gate["need_tip"] = bool(obj.get("need_tip"))
                gate["obj"] = obj
                gate["event"].set()
                span["classify"] = obj
                span["outcome"] = "classify_for_parallel"
                self.out_timing.write(span)
            elif obj.get("need_tip"):
                span["classify"] = obj
                self._submit_tip(line, obj.get("trigger", "none"), span, level_hint=obj.get("level"))
            else:
                span["classify"] = obj
                span["outcome"] = "no_tip"
                self.out_timing.write(span)
        finally:
            with self.lock:
                nxt = self.classify_pending
                self.classify_pending = None
                self.classify_busy = False
            if nxt is not None:
                self._submit_classify(nxt, {"line_id": nxt.line_id, "src": nxt.t, "speaker": nxt.speaker,
                                            "seg_end": nxt.seg_end, "written": nxt.written,
                                            "available_at": self.clock(), "route": "classify_pending"})

    def _submit_tip(self, line: Line, trigger: str, span: dict, level_hint: Optional[str] = None) -> None:
        with self.lock:
            if line.line_id in self.tipped_lines:
                span["outcome"] = "dup_line"
                self.out_timing.write(span)
                return
            self.tipped_lines.add(line.line_id)
        self.futures.append(self.pool.submit(self._run_tip, line, trigger, span))

    def _run_tip(self, line: Line, trigger: str, span: dict) -> None:
        span["tip_start"] = self.clock()
        gate = span.pop("gate", None)          # parallel route: classify's verdict arrives here
        uid = "a{}-{}".format(line.line_id, int(span["tip_start"] * 1000) % 1000000)
        early = {"shown": False}
        stream = self.cfg.get("stream_gist", True)

        def on_text(buf: str) -> None:
            """Streamed gist (2026-10-23): as soon as the gist, level and topic are complete in the
            stream, run the diet on them and show the gist; the full tip replaces it by uid."""
            if early["shown"] or not stream:
                return
            part = partial_head(buf)
            if not part:
                return
            if span.get("force_level"):
                part["level"] = span["force_level"]
            if self.meeting_block(part, trigger, span):
                early["shown"] = None
                return
            now = self.clock()
            if self.stale(line, trigger):
                early["shown"] = None          # the trigger is already resolved: no early card
                return
            if gate is not None and not gate["event"].is_set():
                return                         # classify still running: the gist waits for its verdict
            if gate is not None and gate["need_tip"] is False:
                early["shown"] = None
                return
            with self.diet_lock:
                if self._diet(part, now, exempt=bool(span.get("rate_exempt"))):
                    early["shown"] = None      # decided: wait for the full tip, no early card
                    return
                with self.lock:                # counts for the rate and same-topic checks at once
                    self.tips.append(dict(part, uid=uid, partial=True, _at=now, _exempt=bool(span.get("rate_exempt"))))
                    if part["level"] != "red":
                        self.last_nonred_emit = now
            seg_end0 = line.seg_end if line.seg_end is not None else line.t_s
            item = {"schema_version": 1, "engine": "app", "uid": uid, "partial": True, "t": s_to_hms(now),
                    "src": line.t, "kind": "tip", "level": part["level"], "gist": part["gist"], "at": s_to_hms(now)}
            self.out_tips.write(item)
            early["shown"] = True
            span["shown_at"] = now
            span["e2e_shown_s"] = round(now - seg_end0, 2)

        event = span.get("event") or trigger
        if self.tip_cache_warm.is_set():
            c = self._call("tip", line, event, on_text=on_text)
        else:
            with self.tip_warm_lock:
                c = self._call("tip", line, event, on_text=on_text)
                if not c.error:
                    self.tip_cache_warm.set()
        done = self.clock()
        shown = early["shown"] is True

        def retract():
            if shown:
                with self.lock:
                    self.tips[:] = [t for t in self.tips if t.get("uid") != uid]
                self.out_tips.write({"schema_version": 1, "engine": "app", "kind": "retract", "uid": uid})
        span["tip_ttft_ms"] = c.ms(c.t_first_token)
        span["tip_gist_ms"] = c.ms(c.t_gist)
        span["tip_ms"] = c.ms(c.t_done)
        if c.t_gist is not None:
            span["gist_at"] = span["tip_start"] + (c.t_gist - c.t_start)
        span["tip_done"] = done
        obj = first_json(c.text) if not c.error else None
        if c.error or obj is None:
            span["outcome"] = "tip_error" if c.error else "tip_invalid"
            span["error"] = c.error
            retract()
            self.out_timing.write(span)
            return
        errs = list(self.tip_validator.iter_errors(obj))
        if errs:
            import jsonschema
            best = jsonschema.exceptions.best_match(errs)
            span["outcome"] = "tip_invalid"
            span["error"] = "{}: {}".format("/".join(str(p) for p in best.absolute_path), best.message[:160])
            retract()
            self.out_timing.write(span)
            return
        if obj.get("skip"):
            span["outcome"] = "skip"
            span["reason"] = obj.get("reason")
            retract()
            self.out_timing.write(span)
            return
        if span.get("force_level"):
            obj["level"] = span["force_level"]
        blocked = self.meeting_block(obj, obj.get("trigger", trigger), span)
        if blocked:
            span["outcome"] = blocked
            span["gist"] = obj.get("gist")
            retract()
            self.out_timing.write(span)
            return
        if gate is not None:
            gate["event"].wait(2.0)
            if gate["need_tip"] is False:
                span["outcome"] = "classify_vetoed"
                span["gist"] = obj.get("gist")
                retract()
                self.out_timing.write(span)
                return
            if gate.get("obj") and gate["obj"].get("trigger") and trigger == "none":
                trigger = gate["obj"]["trigger"]
        # 2026-10-26 client call: 16 red tips in 33 min, most for questions to the room. Red is for the PM:
        # addressed by name or "you", a new request, the PM's commitment, or an open ask the call picture found.
        if obj.get("level") == "red" and not span.get("to_pm") and not span.get("force_level") \
                and obj.get("trigger", trigger) not in ("new_requirement", "pm_commitment", "contradicts_decision", "pm_factual_error"):
            obj["level"] = "orange"
            if obj.get("gist", "").startswith(("🎯", "🔴")):
                obj["gist"] = "🟠" + obj["gist"][1:]
        why = self.stale(line, obj.get("trigger", trigger), obj)
        if why:
            span["outcome"] = "stale_" + why
            span["gist"] = obj.get("gist")
            retract()
            self.out_timing.write(span)
            return
        obj = self.validate_facts(obj, line)
        if obj.get("_dropped_items"):
            span["dropped_items"] = obj.pop("_dropped_items")
        if obj.pop("_unseen_number_in_phrase", False):
            span["outcome"] = "unseen_number"
            span["gist"] = obj.get("gist")
            retract()
            self.out_timing.write(span)
            return
        if shown:
            verdict = None                     # a gist already on screen is kept
        else:
            with self.diet_lock:
                verdict = self._diet(obj, done, exempt=bool(span.get("rate_exempt")))
                if not verdict and obj.get("level") != "red":
                    with self.lock:
                        self.last_nonred_emit = done
        if verdict:
            span["outcome"] = "diet_" + verdict
            span["gist"] = obj.get("gist")
            self.out_timing.write(span)
            return
        seg_end = line.seg_end if line.seg_end is not None else line.t_s
        late = (done - seg_end) > self.stale_s
        item = {"schema_version": 1, "engine": "app", "uid": uid, "t": s_to_hms(done), "src": line.t, "kind": "tip",
                "level": obj.get("level", "orange"), "gist": obj["gist"], "phrase": obj.get("phrase", ""),
                "items": obj.get("items", []), "note": obj.get("note", ""), "topic": obj.get("topic", ""),
                "trigger": obj.get("trigger", trigger), "fact_ids": obj.get("fact_ids", []),
                "at": s_to_hms(done), "late": late}
        item = {k: v for k, v in item.items() if v not in ("", [], None) or k in ("late",)}
        with self.lock:
            self.tips[:] = [t for t in self.tips if not (t.get("uid") == uid and t.get("partial"))]
            self.tips.append(dict(item, _at=done, _exempt=bool(span.get("rate_exempt"))))
            if item["level"] != "red":
                self.last_nonred_emit = done
        self.out_tips.write(item)
        span["outcome"] = "emitted"
        span["emit_at"] = done
        span["level"] = item["level"]
        span["e2e_s"] = round(done - seg_end, 2)
        if span.get("gist_at") is not None:
            span["e2e_gist_s"] = round(span["gist_at"] - seg_end, 2)
        span["gist"] = item["gist"]
        self.out_timing.write(span)

    # ---------- diet (code, not prompt) ----------
    def _phrase_repeat(self, obj: dict, now: float) -> bool:
        """The same answer in other words (the client call repeated "we can only speak to our module" 8
        times): a phrase this close to one shown in the last 10 minutes is noise, at any level."""
        ph = obj.get("phrase") or ""
        if len(ph.split()) < 5:
            return False
        with self.lock:
            shown = [t.get("phrase", "") for t in self.tips if t.get("_at", -1e9) >= now - 600 and not t.get("partial")]
        return any(p and jaccard(ph, p) >= self.cfg.get("phrase_repeat_min", 0.42) for p in shown)

    def _diet(self, obj: dict, now: float, exempt: bool = False) -> Optional[str]:
        if self._phrase_repeat(obj, now):
            return "phrase_repeat"
        if obj.get("level") == "red":
            # A red tip is never rate-limited, but the same red tip twice within a minute is noise
            # (two lines of one turn can both trigger "your turn").
            with self.lock:
                recent = [t for t in self.tips if t.get("level") == "red" and t.get("_at", -1e9) >= now - self.red_repeat_s]
            g, topic = obj.get("gist", ""), obj.get("topic", "")
            if any(t.get("gist") == g or (topic and jaccard(topic, t.get("topic", "")) >= self.topic_sim) for t in recent):
                return "red_repeat"
            # 2026-10-26 replay: one question in two or three lines gave three red tips in 20 s.
            if any(t.get("_at", -1e9) >= now - self.cfg.get("red_burst_s", 15) for t in recent):
                return "red_burst"
            return None
        if self.presenting(now):
            return "presenting"
        meta = self.meta()
        if meta.get("audience") == "team":
            # Team calls: no info tips (the PM did not ask; window asks and SOS do not pass the diet) and
            # at most TEAM_TIPS_PER_HOUR non-red model tips per hour.
            if obj.get("level") == "info":
                return "team_info"
            with self.lock:
                uids = {t.get("uid") or id(t) for t in self.tips if t.get("level") != "red" and "_at" in t
                        and t["_at"] >= now - 3600 and t.get("kind", "tip") == "tip"}
            if len(uids) >= TEAM_TIPS_PER_HOUR:
                return "team_hour_cap"
        if exempt:
            # Hiring tips ignore the orange rate (hiring.md "Live tips by role"), max 2 per minute.
            with self.lock:
                n = len({t.get("uid") for t in self.tips if t.get("_exempt") and t.get("_at", -1e9) >= now - 60})
            return "meeting_rate" if n >= MEETING_EXEMPT_PER_MIN else None
        if self.last_nonred_emit is not None and now - self.last_nonred_emit < self.rate_s:
            return "rate"
        with self.lock:
            pm_recent = any(h.speaker == "me" and h.written is not None and 0 <= now - h.written <= self.pm_window
                            for h in self.history[-6:])
            topics = [t.get("topic", "") for t in self.tips if t.get("_at", -1e9) >= now - 600]
        if pm_recent:
            return "pm_speaking"
        topic = obj.get("topic", "")
        if topic and any(jaccard(topic, t) >= self.topic_sim for t in topics):
            return "same_topic"
        return None

    # ---------- meeting concept and live mode ----------
    def meta(self) -> dict:
        return getattr(self.prompt, "meta", None) or {}

    def set_meeting(self, change: dict) -> bool:
        """call_type / audience / hiring_role changed in the window's menu (status.json). Every meeting
        rule in the engine reads the prompt's meta live, so a change applies from the next line."""
        changed = self.prompt.set_meeting(change) if hasattr(self.prompt, "set_meeting") else False
        if changed:
            with self.lock:
                self.clarified_for.clear()
            self._presenting = False
        return changed

    def _is_question(self, line: Line, sig=None) -> bool:
        if sig is not None and sig.question:
            return True
        words = re.findall(r"[\w'ʼ’]+", line.text.lower())
        return "?" in line.text or (bool(words) and any(w in self.detector.q for w in words[:2]))

    def meeting_hint(self, line: Line, sig, now: float) -> Optional[dict]:
        """Routing by meeting concept (hiring.md "Live tips by role", presentation.md Q&A). Returns
        {kind, trigger, event, level?, exempt?} for a line that goes straight to a tip, or None."""
        meta = self.meta()
        role = meeting_role(meta)
        if line.speaker != "them":
            return None
        if role == "observer":
            if self._is_question(line, sig) and not sig.name_mention:
                return {"kind": "observer_question", "trigger": "direct_question", "event": OBSERVER_EVENT,
                        "level": "orange", "exempt": True}
            return None
        if role == "coach":
            tl = line.text.lower()
            words = re.findall(r"[\w'ʼ’]+", tl)
            if any(w in COACH_MONEY_WORDS for w in words) or any(
                    (c in tl) if " " in c else any(w.startswith(c) for w in words)
                    for c in COACH_MONEY_CUES if c not in ("rate", "cost")):
                return {"kind": "coach_money", "trigger": "direct_question", "event": COACH_MONEY_EVENT, "level": "red"}
            if self._is_question(line, sig):
                return {"kind": "coach_question", "trigger": "direct_question", "event": COACH_QUESTION_EVENT, "level": "red"}
            return None
        if role == "interviewer":
            with self.lock:
                hist = [h for h in self.history if h.line_id <= line.line_id]
            q, answer = None, []
            for h in reversed(hist):
                if h.speaker == "me":
                    q = h
                    break
                answer.append(h)
            if q is None or not self._is_question(q) or q.line_id in self.clarified_for:
                return None
            n = sum(len(h.text.split()) for h in answer)
            if n >= INTERVIEWER_ANSWER_WORDS:
                with self.lock:
                    self.clarified_for.add(q.line_id)
                return {"kind": "interviewer_clarify", "trigger": "add_fact", "event": INTERVIEWER_EVENT,
                        "level": "orange", "exempt": True}
            return None
        if meta.get("call_type") == "presentation" and self._is_question(line, sig) and self.qa_mode(now):
            return {"kind": "presentation_qa", "trigger": "direct_question", "event": QA_EVENT}
        return None

    def qa_mode(self, now: float) -> bool:
        """Presentation Q&A: the PM spoke before, and the PM's share of the last QA_WINDOW_S seconds
        (characters) is below QA_SHARE_MAX over a window that covers most of it."""
        with self.lock:
            hist = list(self.history)
        if not any(h.speaker == "me" for h in hist):
            return False
        recent = [h for h in hist if h.t_s >= now - QA_WINDOW_S]
        if not recent or now - min(h.t_s for h in hist) < QA_WINDOW_S:
            return False
        me = sum(len(h.text) for h in recent if h.speaker == "me")
        tot = sum(len(h.text) for h in recent) or 1
        return me / tot < QA_SHARE_MAX

    def meeting_block(self, obj: dict, trigger: str, span: dict) -> Optional[str]:
        """Model tips the meeting concept does not allow, checked on the streamed gist and the full tip."""
        meta = self.meta()
        if not meta.get("turn_tips", self.cfg.get("turn_tips", False)) and TURN_GIST.search(obj.get("gist", "") or ""):
            return "turn_tip"                 # 2026-10-23: the PM starts on their own, never on a "your turn" tip
        sp = getattr(self, "speech_phrase", "")
        if sp and obj.get("phrase") and jaccard(obj["phrase"], sp) >= 0.45:
            return "speech_repeat"            # the speech card is already on screen
        if meeting_role(meta) == "observer" and not span.get("meeting"):
            return "role_observer"            # after the answer: nothing (no add_fact, no fix_owner_date)
        if meta.get("call_type") == "presentation" and obj.get("level") != "red":
            text = " ".join([obj.get("gist", ""), obj.get("topic", ""), obj.get("phrase", "")])
            if trigger == "timer_checkpoint" or obj.get("trigger") == "timer_checkpoint" or PACING.search(text):
                return "presentation_timing"  # the recorder owns the time line
        return None

    def presenting(self, now: float) -> bool:
        """The skill's live mode (read_delta detect_mode): presenting when the PM has more than 65% of
        the talk (characters) over the last 120 s, back to discussion below 55%. A presentation call is
        presenting whenever the PM leads the talk (above 55%). Only red tips pass while presenting."""
        meta = getattr(self.prompt, "meta", {}) or {}
        if meta.get("call_type") == "interview":
            return False
        with self.lock:
            recent = [h for h in self.history if h.t_s >= now - 120 - 30]
        if not recent or recent[-1].t_s - recent[0].t_s < 100:
            return False
        me = sum(len(h.text) for h in recent if h.speaker == "me")
        tot = sum(len(h.text) for h in recent) or 1
        share = me / tot
        was = getattr(self, "_presenting", False)
        enter = 0.55 if meta.get("call_type") == "presentation" else 0.65
        self._presenting = share >= 0.55 if was else share > enter
        return self._presenting

    # ---------- the PM's speech from the brief, at the start ----------
    def speech_card(self, brief_text: str) -> Optional[dict]:
        """The skill shows "Твій спіч" from the brief as the first card (no model call). The brief carries
        it as a ready item under "## speech.json"; without one, the "спіч / speech" section is used."""
        if not brief_text:
            return None
        try:                                   # an engine restart must not show the speech twice
            prev = self.out_tips.path.read_text(encoding="utf-8", errors="replace")
            if '"kind": "speech"' in prev or '"kind":"speech"' in prev:
                for ln in prev.splitlines():
                    if '"speech"' in ln:
                        try:
                            it = json.loads(ln)
                            if it.get("kind") == "speech":
                                self.speech_phrase = it.get("phrase", "")
                                self.speech_items = list(it.get("items") or [])
                                self.speech_item = it
                        except ValueError:
                            pass
                return None
        except (OSError, AttributeError):
            pass
        item = None
        m = re.search(r"^##\s*speech\.json\s*\n(\{.*?\})\s*$", brief_text, re.M | re.S)
        if m:
            try:
                item = json.loads(m.group(1))
            except ValueError:
                item = None
        if not item:
            m = re.search(r"^##\s*(?:\d+\.\s*)?(?:Мій спіч|Твій спіч|My speech|Your speech|My update|Мій апдейт)[^\n]*\n(.*?)(?=^##\s|\Z)",
                          brief_text, re.M | re.S | re.I)
            if not m:
                return None
            body = [l.strip() for l in m.group(1).splitlines() if l.strip() and not l.startswith("#")]
            gist = next((l.strip("* ") for l in body if l.startswith("**")), "🟢 Твій спіч")
            phrase = next((l.strip('"“” ') for l in body if l.startswith('"') or l.startswith("“")), "")
            items = [l.lstrip("-* ") for l in body if not l.startswith("**") and not l.startswith('"') and not l.startswith("“")]
            item = {"gist": gist, "phrase": phrase, "items": items[:12]}
        now = self.clock()
        out = {"schema_version": 1, "engine": "app", "uid": "speech", "t": s_to_hms(now), "src": s_to_hms(now), "kind": "speech",
               "level": "info", "gist": item.get("gist") or "🟢 Твій спіч", "phrase": item.get("phrase", ""),
               "items": [str(x) for x in (item.get("items") or [])][:14], "note": item.get("note", "бриф"),
               "at": s_to_hms(now)}
        out = {k: v for k, v in out.items() if v not in ("", [], None)}
        self.speech_phrase = out.get("phrase", "")
        self.speech_items = list(out.get("items") or [])
        self.speech_item = out
        self.out_tips.write(out)
        return out

    # ---------- requests from the tips window (asks, HELP NOW) ----------
    def on_request(self, kind: str, text: str = "") -> None:
        """kind: "ask" (a question typed in the window), "find" (search the project folder, then answer)
        or "sos" (HELP NOW). Never rate-limited."""
        if self.budget and self.budget.state() == "hard":
            return
        now = self.clock()
        with self.lock:
            last = self.history[-1] if self.history else None
        line = last or Line(-1, s_to_hms(now), "them", "", None, "en", "")
        span = {"line_id": line.line_id, "src": s_to_hms(now), "request": kind, "available_at": now}
        self.futures.append(self.pool.submit(self._run_request, kind, text, line, span))

    # ---------- "Search the project" from the tips window (2026-10-26) ----------
    FIND_QUERIES = ("You turn a question asked during a call into search queries for a project folder "
                    "(notes, transcripts, specs, Notion and Jira exports). Return JSON only: "
                    "{\"queries\": [\"...\", \"...\", \"...\"]}: 2-4 short keyword queries (2-6 words), mixing "
                    "Ukrainian and English when the folder may hold both, names and ticket keys kept as written.")

    def _find_queries(self, text: str) -> List[str]:
        qs = [text]
        try:
            c = self.provider.complete(model=self.models["classify"], system=[{"text": self.FIND_QUERIES}],
                                       user="Question: " + text, max_tokens=150, cache_ttl=None,
                                       extra=(self.cfg.get("request_extra") or {}).get("classify"))
            usd = cost_usd(c.model, c.input_tokens, c.cache_write_5m, c.cache_write_1h, c.cache_read, c.output_tokens)
            if self.budget and usd:
                self.budget.add(usd)
            obj = first_json(c.text) if not c.error else None
            for q in (obj or {}).get("queries") or []:
                if isinstance(q, str) and q.strip() and q.strip().lower() not in [x.lower() for x in qs]:
                    qs.append(q.strip())
        except Exception:  # noqa: BLE001  (the question itself is still searched)
            pass
        return qs[:5]

    @staticmethod
    def _hit_text(h: dict, width: int = 1800) -> str:
        """The text around a search hit: a window of the file for text files, the preview otherwise."""
        prev = (h.get("preview") or "").strip()
        path = h.get("path") or ""
        if path and Path(path).suffix.lower() in (".md", ".txt", ".csv", ".json", ".yaml", ".yml", ".html", ".eml"):
            try:
                raw = Path(path).read_text(encoding="utf-8", errors="replace")
                key = re.sub(r"\s+", " ", prev.strip("…. "))[:50]
                flat = re.sub(r"\s+", " ", raw)
                i = flat.find(key) if key else -1
                if i < 0:
                    i = 0
                a = max(0, i - width // 3)
                return flat[a:a + width]
            except OSError:
                pass
        return prev

    def _project_snippets(self, text: str, budget_chars: int = 14000) -> List[dict]:
        root, lt = self.cfg.get("project_root"), self.cfg.get("lt_cmd")
        if not root or not lt:
            return []
        from .context import index_snippets
        seen, hits = set(), []
        from concurrent.futures import ThreadPoolExecutor as _TP
        qs = self._find_queries(text)
        with _TP(max_workers=len(qs) or 1) as ex:      # parallel, one overall wait (QA: up to 100 s in a row)
            results = list(ex.map(lambda q: index_snippets(lt, Path(root), q, k=6, timeout=15.0), qs))
        for res in results:
            for h in res:
                key = (h.get("path"), (h.get("preview") or "")[:60])
                if key not in seen:
                    seen.add(key)
                    hits.append(h)
        hits.sort(key=lambda h: -(h.get("score") or 0))
        out, used = [], 0
        for h in hits:
            body = self._hit_text(h)
            if not body or used + len(body) > budget_chars:
                continue
            used += len(body)
            out.append({"src": h.get("rel") or Path(h.get("path") or "").name, "date": h.get("date") or "", "text": body})
            if len(out) >= 10:
                break
        return out

    def _run_find(self, text: str, line: Line, span: dict) -> None:
        span["tip_start"] = self.clock()
        snips = self._project_snippets(text)
        srcs = []
        for x in snips:
            if x["src"] not in srcs:
                srcs.append(x["src"])
        if snips:
            found = "\n\n".join("[{}{}]\n{}".format(x["src"], ", " + x["date"] if x["date"] else "", x["text"]) for x in snips)
            event = ("The PM asked to search the project folder: " + text + ". Below are passages found in the project "
                     "files (newest facts win when they disagree). Answer as one tip: gist = the answer in a few words, "
                     "phrase = a sentence the PM can say if useful, items = up to 4 facts with numbers, dates and owners, "
                     "note = the file names used. Only what the passages, the brief or the call say; when the answer is "
                     "not there, say so in the gist and name the closest thing found.\n\nPASSAGES FROM THE PROJECT FOLDER:\n" + found)
        else:
            event = ("The PM asked to search the project folder: " + text + ". The search found nothing in the project "
                     "files. Answer from the brief, the fact book, the current state and the call if they cover it; "
                     "otherwise gist = 'Nothing found in the project folder'.")
        c = self._call("tip", line, event)
        done = self.clock()
        obj = first_json(c.text) if not c.error else None
        if not obj or obj.get("skip"):
            obj = {"gist": "Nothing found in the project folder" if not c.error else "Search failed: " + c.error[:80]}
        note = obj.get("note") or ""
        if srcs and not note:
            note = "Sources: " + ", ".join(srcs[:4])
        item = {"schema_version": 1, "engine": "app", "t": s_to_hms(done), "src": span["src"], "kind": "answer",
                "level": obj.get("level", "info"), "gist": "🔎 " + str(obj.get("gist", "")).lstrip("🔎 "),
                "phrase": obj.get("phrase", ""), "items": obj.get("items", []), "note": note, "at": s_to_hms(done),
                "q": "find: " + text, "sources": srcs[:6]}
        item = {k: v for k, v in item.items() if v not in ("", [], None)}
        with self.lock:
            self.tips.append(item)
        self.out_tips.write(item)
        span.update({"outcome": "emitted", "emit_at": done, "tip_ms": c.ms(c.t_done), "error": c.error,
                     "find_snippets": len(snips)})
        self.out_timing.write(span)

    # Rewrite only on an edit verb next to the speech; show on "where / show (me) my speech ..." (QA 26.10).
    SPEECH_ASK = re.compile(r"(додай|добав|прибери|видали|зміни|переп[иі]ши|онови|скороти|встав|допиши|add|remove|change|rewrite|update|shorten|put)\b.{0,60}(спіч|speech|апдейт|update)"
                            r"|(спіч|speech|апдейт)\w*.{0,40}\b(додай|прибери|зміни|переп[иі]ши|онови|скороти|add|remove|change|rewrite|shorten)", re.I)
    SPEECH_SHOW = re.compile(r"^\W*(де|покажи|show|where|дай|відкрий|open)\b.{0,40}(спіч|speech|мій апдейт|my update)", re.I)

    def _emit_speech(self, obj: dict, note: str = "") -> dict:
        now = self.clock()
        out = {"schema_version": 1, "engine": "app", "uid": "speech", "t": s_to_hms(now), "src": s_to_hms(now),
               "kind": "speech", "level": "info", "gist": obj.get("gist") or "🟢 Твій спіч", "phrase": obj.get("phrase", ""),
               "items": [str(x) for x in (obj.get("items") or [])][:14], "note": note or obj.get("note", ""), "at": s_to_hms(now)}
        out = {k: v for k, v in out.items() if v not in ("", [], None)}
        changed = list(out.get("items") or []) != self.speech_items
        self.speech_item, self.speech_items, self.speech_phrase = out, list(out.get("items") or []), out.get("phrase", "")
        if changed and self.situation:
            with self.lock:
                self.situation["speech_done"] = []      # numbers of the old points mean nothing now (QA 26.10)
        self.out_tips.write(out)
        return out

    def _run_speech_request(self, text: str, line: Line, span: dict) -> bool:
        """2026-10-26: "де мій спіч?" shows the speech; "додай X у спіч" rewrites it in place (one card)."""
        if self.speech_item and self.SPEECH_SHOW.search(text):
            self._emit_speech(self.speech_item)
            span.update({"outcome": "speech_shown"})
            self.out_timing.write(span)
            return True
        cur = self.speech_item or {}
        event = ("The PM asks about the speech (the PM's own update for this call): " + text + ". CURRENT SPEECH: " +
                 json.dumps({"gist": cur.get("gist", ""), "phrase": cur.get("phrase", ""), "items": cur.get("items", [])},
                            ensure_ascii=False) + ". Return the FULL updated speech as JSON {\"gist\": \"🟢 ...\", "
                 "\"phrase\": \"<opening sentence>\", \"items\": [\"<point>\", ...up to 12], \"note\": \"<what changed>\"}: "
                 "apply the request, keep every point that was not asked to change, use only the brief, the fact book, "
                 "the cards, the project current state and the call. With no speech yet, build it from the brief.")
        c = self._call("tip", line, event)
        obj = first_json(c.text) if not c.error else None
        if not obj or not (obj.get("items") or obj.get("phrase")):
            return False
        self._emit_speech(obj, note=obj.get("note", ""))
        span.update({"outcome": "speech_updated", "tip_ms": c.ms(c.t_done)})
        self.out_timing.write(span)
        self.ask_log.append({"q": text, "a": "speech updated: " + str(obj.get("note", ""))[:120]})
        return True

    def _run_request(self, kind: str, text: str, line: Line, span: dict) -> None:
        if kind == "ask" and (self.SPEECH_ASK.search(text) or (self.speech_item and self.SPEECH_SHOW.search(text))):
            span["tip_start"] = self.clock()
            if self._run_speech_request(text, line, span):
                return
        if kind == "find":
            self._run_find(text, line, span)
            return
        if kind == "sos":
            event = ("HELP NOW pressed: the PM is speaking and cannot type. Give ONE red tip now: gist starting with "
                     "'🆘 ', the next sentence the PM can say right now (answer to the open question, a fact with its number, "
                     "or a bridge such as 'Let me give you the exact number after the call.'), up to 2 fact lines. Never skip.")
        else:
            hist = ""
            if self.ask_log:
                hist = " Earlier asks in this call (the PM may refer to them, e.g. 'more detail', 'and the other one'): " + \
                       " | ".join("Q: {} A: {}".format(x["q"], x["a"]) for x in self.ask_log[-5:]) + "."
            event = "The PM typed a question in the tips window: " + text + "." + hist + " Answer it like a short chat reply (gist = the answer in a few words, items = details when asked for detail). Everything in the brief counts (the PM's speech, open questions, blocks), as do the fact book, the cards, the project current state, the call situation and the transcript. Never answer 'no answer' to a follow-up of an earlier answer: build on it. Skip only if nothing in the context answers it, then say so in the gist."
        span["tip_start"] = self.clock()
        c = self._call("tip", line, event)
        done = self.clock()
        obj = first_json(c.text) if not c.error else None
        if not obj or obj.get("skip"):
            gist = "🆘 Nothing concrete found" if kind == "sos" else "No answer in the brief or the call so far"
            obj = {"gist": gist, "level": "info", "topic": kind}
        item = {"schema_version": 1, "engine": "app", "t": s_to_hms(done), "src": span["src"],
                "kind": "tip" if kind == "sos" else "answer", "level": "red" if kind == "sos" else obj.get("level", "info"),
                "gist": obj.get("gist", ""), "phrase": obj.get("phrase", ""), "items": obj.get("items", []),
                "note": obj.get("note", ""), "at": s_to_hms(done)}
        if kind == "ask":
            item["q"] = text
            self.ask_log.append({"q": text, "a": (str(obj.get("gist", "")) + " " + str(obj.get("phrase", "")))[:200]})
        item = {k: v for k, v in item.items() if v not in ("", [], None)}
        with self.lock:
            self.tips.append(item)
        self.out_tips.write(item)
        span.update({"outcome": "emitted", "emit_at": done, "tip_ms": c.ms(c.t_done), "error": c.error})
        self.out_timing.write(span)

    # ---------- situation tracker (2026-10-26) ----------
    def _maybe_situation(self, line: Line, sig, now: float) -> None:
        if not self.sit_enabled:
            return
        strong = line.speaker == "them" and (sig.name_vocative or sig.name_mention or bool(SITUATION_STRONG.search(line.text)))
        since = None if self.sit_last_at is None else now - self.sit_last_at
        due = since is None or since >= self.sit_interval
        if not (due or (strong and since >= 3)):
            return
        with self.lock:
            if self.sit_busy:
                self.sit_pending = True
                return
            self.sit_busy = True
            self.sit_last_at = now
        self.futures.append(self.pool.submit(self._run_situation))

    def _run_situation(self) -> None:
        try:
            with self.lock:
                hist = list(self.history)
                last_done = self.sit_last_line
            new = [h for h in hist if h.line_id > last_done]
            if not new:
                return
            ctx = [h for h in hist if h.line_id <= last_done][-12:]
            meta = self.meta()
            lang = "Ukrainian" if (self.cfg.get("tips_lang") or meta.get("tips_lang", "uk")) == "uk" else "English"
            import datetime as _dt
            sysmsg = SITUATION_SYS.format(me=meta.get("me_label", "Me"), aliases=", ".join(meta.get("name_aliases", [])) or "-",
                                          projects=", ".join(meta.get("pm_projects") or [meta.get("project", "")]) or "-",
                                          people=", ".join(meta.get("participants") or []) or "unknown",
                                          today=_dt.date.today().strftime("%A %Y-%m-%d"), lang=lang)
            fmt = lambda h: "[{}] {}: {}".format(h.t, self.speakers.who(h), h.text[:400])
            speech = "\n".join("{}. {}".format(i, x) for i, x in enumerate(self.speech_items)) or "(none)"
            user = "PREVIOUS STATE: {}\n\nPM SPEECH POINTS:\n{}\n\nEARLIER LINES (context):\n{}\n\nNEW LINES:\n{}".format(
                json.dumps(self.situation or {}, ensure_ascii=False), speech, "\n".join(fmt(h) for h in ctx) or "-",
                "\n".join(fmt(h) for h in new[-60:]))
            extra = (self.cfg.get("request_extra") or {}).get("classify")
            c = self.provider.complete(model=self.models["classify"], system=[{"text": sysmsg}], user=user,
                                       max_tokens=self.cfg.get("situation_max_tokens", 900), cache_ttl=None, extra=extra)
            usd = cost_usd(c.model, c.input_tokens, c.cache_write_5m, c.cache_write_1h, c.cache_read, c.output_tokens)
            if self.budget and usd:
                self.budget.add(usd)
            self.out_llm.write({"at": s_to_hms(self.clock()), "role": "situation", "model": c.model, "line_id": new[-1].line_id,
                                "total_ms": c.ms(c.t_done), "input": c.input_tokens, "output": c.output_tokens,
                                "usd": round(usd, 6) if usd is not None else None, "error": c.error,
                                "text_head": None if c.error else c.text[:160]})
            obj = first_json(c.text) if not c.error else None
            if not isinstance(obj, dict):
                return
            sit = {"topic": str(obj.get("topic") or "")[:80], "owner": str(obj.get("owner") or "")[:40],
                   "mine": bool(obj.get("mine")), "floor": str(obj.get("floor") or "")[:40],
                   "asks": [a for a in (obj.get("asks") or []) if isinstance(a, dict) and a.get("what")][:6],
                   "actions": [a for a in (obj.get("actions") or []) if isinstance(a, dict) and a.get("what")][:20],
                   "decisions": [str(d) for d in (obj.get("decisions") or []) if d][:20],
                   "speech_done": [int(i) for i in (obj.get("speech_done") or []) if str(i).isdigit()]}
            # A speech point counts as said only when the PM really spoke in the new lines (review: a replay
            # struck the whole speech through during someone else's update).
            prev_done = set(self.situation.get("speech_done") or [])
            pm_spoke = sum(len(h.text.split()) for h in new if h.speaker == "me") >= 8
            sit["speech_done"] = sorted(prev_done | (set(sit["speech_done"]) if pm_spoke else set()))
            # An ask nobody answered for 6 minutes is old news (user review: one ask stayed red all call).
            now_s = new[-1].t_s
            def _age(t):
                try:
                    h, m, x = (int(v) for v in str(t).split(":"))
                    return now_s - (h * 3600 + m * 60 + x)
                except ValueError:
                    return 0
            sit["asks"] = [a for a in sit["asks"] if _age(a.get("t")) <= self.cfg.get("ask_ttl_s", 360)]
            with self.lock:
                self.sit_last_line = new[-1].line_id
                changed = sit != self.situation
                self.situation = sit
            if changed:
                now = self.clock()
                self.out_tips.write(dict(sit, schema_version=1, engine="app", kind="situation", t=s_to_hms(now), at=s_to_hms(now)))
            self._asks_to_tips(sit, hist)
        except Exception as e:  # noqa: BLE001  (the state is a helper; tips go on without it)
            self.out_timing.write({"outcome": "situation_error", "error": repr(e)[:200]})
        finally:
            with self.lock:
                self.sit_busy = False
                again = self.sit_pending
                self.sit_pending = False
            if again:
                with self.lock:
                    self.sit_busy = True
                    self.sit_last_at = self.clock()
                self.futures.append(self.pool.submit(self._run_situation))

    def _asks_to_tips(self, sit: dict, hist: List[Line]) -> None:
        """A new open question or request to the PM that no tip covered yet (a third-person request, an
        implicit question) gets one red "answer" tip, once per ask."""
        for a in sit.get("asks") or []:
            key = (a.get("t"), (a.get("what") or "")[:40])
            if a.get("type") == "update" or key in self.sit_asks_tipped:
                continue
            self.sit_asks_tipped.add(key)
            line = next((h for h in reversed(hist) if h.t == a.get("t")), None)
            if line is None or line.speaker != "them":
                continue
            with self.lock:
                if line.line_id in self.tipped_lines:
                    continue
            if self.stale(line, "direct_question"):
                continue
            span = {"line_id": line.line_id, "src": line.t, "speaker": line.speaker, "seg_end": line.seg_end,
                    "written": line.written, "available_at": self.clock(), "route": "situation",
                    "event": "Open {} to the PM from {}: {}. Give the PM the answer or the next step: gist = what is asked, "
                             "phrase = a ready sentence, items = 1-2 facts from the brief, fact book or call. Skip if the PM "
                             "already answered.".format(a.get("type", "question"), a.get("who", "someone"), a.get("what", "")),
                    "force_level": "red"}
            self._submit_tip(line, "direct_question", span)

    def final_wrapup(self) -> Optional[dict]:
        """P2 (26.10): at the end, the window gets what the call picture holds: decisions, what is on the PM,
        open asks and the speech points never said. No model call."""
        sit = self.situation or {}
        uk = (self.cfg.get("tips_lang") or self.meta().get("tips_lang", "uk")) == "uk"
        L = (lambda u, e: u if uk else e)
        items = [L("Рішення: ", "Decision: ") + d for d in sit.get("decisions") or []]
        items += [L("На мені: ", "On me: ") + a.get("what", "") + (" (" + a["due"] + ")" if a.get("due") else "")
                  for a in sit.get("actions") or []]
        items += [L("Без відповіді: ", "Unanswered: ") + a.get("what", "") + (" · " + a["who"] if a.get("who") else "")
                  for a in sit.get("asks") or [] if a.get("type") != "update"]
        done = set(sit.get("speech_done") or [])
        missed = [x for i, x in enumerate(self.speech_items) if i not in done]
        if self.speech_items and missed and len(missed) < len(self.speech_items):
            items += [L("Не сказав зі спічу: ", "Not said from the speech: ") + x for x in missed[:5]]
        if not items:
            return None
        now = self.clock()
        out = {"schema_version": 1, "engine": "app", "uid": "call-picture", "t": s_to_hms(now), "src": s_to_hms(now),
               "kind": "wrapup", "level": "info", "gist": L("📋 Підсумок дзвінка", "📋 Call summary"),
               "items": items[:24], "note": L("з картини дзвінка, без перевірки", "from the call picture, unchecked"),
               "at": s_to_hms(now)}
        self.out_tips.write(out)
        return out

    def drain(self, timeout: float = 60.0) -> None:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            pending = [f for f in self.futures if not f.done()]
            if not pending:
                break
            time.sleep(0.2)
        self.pool.shutdown(wait=False)


class SpeakerNames:
    """Display names for the other side's lines, as in the skill (@@SPEAKERS): the PM names a voice in
    the tips window, the recorder writes <stem>.speakers.json (clusters, merges, per-line fixes), and
    the prompt shows "Name" instead of "Them [S2]". Re-read when the file changes. Unnamed voices keep
    the label and tag ("Them [S3]"); the PM's own lines keep the PM label."""

    def __init__(self, path):
        self.path = Path(path) if path else None
        self.mtime = None
        self.clusters, self.merged, self.overrides = {}, {}, {}

    def _load(self):
        if not self.path:
            return
        try:
            m = self.path.stat().st_mtime
        except OSError:
            return
        if m == self.mtime:
            return
        try:
            d = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        self.mtime = m
        g = lambda k: d.get(k) if isinstance(d.get(k), dict) else {}
        self.clusters, self.merged, self.overrides = g("clusters"), g("merged"), g("overrides")

    def name(self, t, sid):
        self._load()
        s, seen = self.overrides.get(t) or sid, set()
        while s in self.merged and s not in seen:
            seen.add(s)
            s = self.merged[s]
        if isinstance(s, str) and s.startswith("name:"):
            return s[5:]
        c = self.clusters.get(s) if s else None
        return c.get("name") if isinstance(c, dict) and c.get("name") else None

    def who(self, line) -> str:
        if line.speaker == "me":
            return line.label
        n = self.name(line.t, line.stag)
        if n:
            return n
        return "{} [{}]".format(line.label, line.stag) if line.stag else line.label
