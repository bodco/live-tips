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

    # ---------- input ----------
    def on_line(self, line: Line) -> None:
        now = self.clock()
        with self.lock:
            self.history.append(line)
        if hasattr(self.prompt, "refresh_facts") and line.line_id % 5 == 0 and self.prompt.refresh_facts():
            self.out_timing.write({"line_id": line.line_id, "src": line.t, "outcome": "facts_reloaded"})
        sig = self.detector.detect(line)
        span = {"line_id": line.line_id, "src": line.t, "speaker": line.speaker, "seg_end": line.seg_end,
                "written": line.written, "available_at": now, "signals": sig.tags}
        if self.paused or (self.budget and self.budget.state() == "hard"):
            return
        route = sig.route if self.direct_enabled else ("classify" if sig.route else None)
        # Meeting concept (2026-10-23): triggers the skill switches off for this call type / audience.
        off = disabled_triggers(getattr(self.prompt, "meta", None))
        if route and sig.trigger_hint in off:
            span["off"] = sig.trigger_hint
            route = "classify" if (sig.question or sig.name_mention) and sig.trigger_hint not in ("pm_commitment", "new_requirement") else None
        if route == "direct":
            span["route"] = "direct"
            self._submit_tip(line, sig.trigger_hint, span)
        elif route == "classify" and self.classify_enabled and self.cfg.get("parallel_tip", True) \
                and (sig.question or sig.name_vocative) and not sig.third_person:
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
        elif line.speaker == "them" and self.classify_enabled and (
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
        return {"tips_given": given, "now": s_to_hms(self.clock())}

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
                if self._diet(part, now):
                    early["shown"] = None      # decided: wait for the full tip, no early card
                    return
                with self.lock:                # counts for the rate and same-topic checks at once
                    self.tips.append(dict(part, uid=uid, partial=True, _at=now))
                    if part["level"] != "red":
                        self.last_nonred_emit = now
            seg_end0 = line.seg_end if line.seg_end is not None else line.t_s
            item = {"schema_version": 1, "engine": "app", "uid": uid, "partial": True, "t": s_to_hms(now),
                    "src": line.t, "kind": "tip", "level": part["level"], "gist": part["gist"], "at": s_to_hms(now)}
            self.out_tips.write(item)
            early["shown"] = True
            span["shown_at"] = now
            span["e2e_shown_s"] = round(now - seg_end0, 2)

        if self.tip_cache_warm.is_set():
            c = self._call("tip", line, trigger, on_text=on_text)
        else:
            with self.tip_warm_lock:
                c = self._call("tip", line, trigger, on_text=on_text)
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
                verdict = self._diet(obj, done)
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
            self.tips.append(dict(item, _at=done))
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
    def _diet(self, obj: dict, now: float) -> Optional[str]:
        if obj.get("level") == "red":
            # A red tip is never rate-limited, but the same red tip twice within a minute is noise
            # (two lines of one turn can both trigger "your turn").
            with self.lock:
                recent = [t for t in self.tips if t.get("level") == "red" and t.get("_at", -1e9) >= now - self.red_repeat_s]
            g, topic = obj.get("gist", ""), obj.get("topic", "")
            if any(t.get("gist") == g or (topic and jaccard(topic, t.get("topic", "")) >= self.topic_sim) for t in recent):
                return "red_repeat"
            return None
        if self.presenting(now):
            return "presenting"
        if self.last_nonred_emit is not None and now - self.last_nonred_emit < self.rate_s:
            return "rate"
        with self.lock:
            pm_recent = any(h.speaker == "me" and h.written is not None and 0 <= now - h.written <= self.pm_window
                            for h in self.history[-6:])
            topics = [t.get("topic", "") for t in self.tips]
        if pm_recent:
            return "pm_speaking"
        topic = obj.get("topic", "")
        if topic and any(jaccard(topic, t) >= self.topic_sim for t in topics):
            return "same_topic"
        return None

    # ---------- meeting concept and live mode ----------
    def set_meeting(self, change: dict) -> bool:
        """call_type / audience / hiring_role changed in the window's menu (status.json)."""
        return self.prompt.set_meeting(change) if hasattr(self.prompt, "set_meeting") else False

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

    # ---------- requests from the tips window (asks, HELP NOW) ----------
    def on_request(self, kind: str, text: str = "") -> None:
        """kind: "ask" (a question typed in the window) or "sos" (HELP NOW). Never rate-limited."""
        if self.budget and self.budget.state() == "hard":
            return
        now = self.clock()
        with self.lock:
            last = self.history[-1] if self.history else None
        line = last or Line(-1, s_to_hms(now), "them", "", None, "en", "")
        span = {"line_id": line.line_id, "src": s_to_hms(now), "request": kind, "available_at": now}
        self.futures.append(self.pool.submit(self._run_request, kind, text, line, span))

    def _run_request(self, kind: str, text: str, line: Line, span: dict) -> None:
        if kind == "sos":
            event = ("HELP NOW pressed: the PM is speaking and cannot type. Give ONE red tip now: gist starting with "
                     "'🆘 ', the next sentence the PM can say right now (answer to the open question, a fact with its number, "
                     "or a bridge such as 'Let me give you the exact number after the call.'), up to 2 fact lines. Never skip.")
        else:
            event = "The PM typed a question in the tips window: " + text + ". Answer it briefly as a tip (gist = the answer in a few words). Skip only if nothing in the context answers it, then say so in the gist."
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
        item = {k: v for k, v in item.items() if v not in ("", [], None)}
        with self.lock:
            self.tips.append(item)
        self.out_tips.write(item)
        span.update({"outcome": "emitted", "emit_at": done, "tip_ms": c.ms(c.t_done), "error": c.error})
        self.out_timing.write(span)

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
