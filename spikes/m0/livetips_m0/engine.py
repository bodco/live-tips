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
from .signals import Detector
from .transcript import Line, s_to_hms

WORD = re.compile(r"\w+", re.UNICODE)


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
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")


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
        # Names the PM gave to voices in the tips window (<stem>.speakers.json, written by the recorder).
        self.speakers = SpeakerNames(cfg.get("speakers_file"))

    # ---------- input ----------
    def on_line(self, line: Line) -> None:
        now = self.clock()
        with self.lock:
            self.history.append(line)
        sig = self.detector.detect(line)
        span = {"line_id": line.line_id, "src": line.t, "speaker": line.speaker, "seg_end": line.seg_end,
                "written": line.written, "available_at": now, "signals": sig.tags}
        if self.paused or (self.budget and self.budget.state() == "hard"):
            return
        route = sig.route if self.direct_enabled else ("classify" if sig.route else None)
        if route == "direct":
            span["route"] = "direct"
            self._submit_tip(line, sig.trigger_hint, span)
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
        span = self.cfg.get("context_earlier_s", 480)
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
        with self.lock:
            gists = [t["gist"] for t in self.tips[-8:]]
        return {"tips_given": gists, "now": s_to_hms(self.clock())}

    def _call(self, role: str, line: Line, event: str):
        user = self.prompt.user(role, event, self._tail(line), self._state(), self._earlier(line))
        max_tokens = self.cfg.get("max_tokens", {}).get(role, 120 if role == "classify" else 300)
        extra = (self.cfg.get("request_extra") or {}).get(role)
        c = self.provider.complete(model=self.models[role], system=self.prompt.blocks, user=user,
                                   max_tokens=max_tokens, cache_ttl=self.ttl, extra=extra)
        usd = cost_usd(c.model, c.input_tokens, c.cache_write_5m, c.cache_write_1h, c.cache_read, c.output_tokens)
        if self.budget and usd:
            self.budget.add(usd)
        self.out_llm.write({"at": s_to_hms(self.clock()), "role": role, "model": c.model, "line_id": line.line_id,
                            "ttft_ms": c.ms(c.t_first_token), "gist_ms": c.ms(c.t_gist), "total_ms": c.ms(c.t_done),
                            "input": c.input_tokens, "cache_read": c.cache_read, "cache_write_5m": c.cache_write_5m,
                            "cache_write_1h": c.cache_write_1h, "output": c.output_tokens,
                            "usd": round(usd, 6) if usd is not None else None, "error": c.error,
                            "stop": c.stop_reason,
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
        if self.tip_cache_warm.is_set():
            c = self._call("tip", line, trigger)
        else:
            with self.tip_warm_lock:
                c = self._call("tip", line, trigger)
                if not c.error:
                    self.tip_cache_warm.set()
        done = self.clock()
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
            self.out_timing.write(span)
            return
        errs = list(self.tip_validator.iter_errors(obj))
        if errs:
            import jsonschema
            best = jsonschema.exceptions.best_match(errs)
            span["outcome"] = "tip_invalid"
            span["error"] = "{}: {}".format("/".join(str(p) for p in best.absolute_path), best.message[:160])
            self.out_timing.write(span)
            return
        if obj.get("skip"):
            span["outcome"] = "skip"
            span["reason"] = obj.get("reason")
            self.out_timing.write(span)
            return
        verdict = self._diet(obj, done)
        if verdict:
            span["outcome"] = "diet_" + verdict
            span["gist"] = obj.get("gist")
            self.out_timing.write(span)
            return
        seg_end = line.seg_end if line.seg_end is not None else line.t_s
        late = (done - seg_end) > self.stale_s
        item = {"schema_version": 1, "engine": "app", "t": s_to_hms(done), "src": line.t, "kind": "tip",
                "level": obj.get("level", "orange"), "gist": obj["gist"], "phrase": obj.get("phrase", ""),
                "items": obj.get("items", []), "note": obj.get("note", ""), "topic": obj.get("topic", ""),
                "trigger": obj.get("trigger", trigger), "fact_ids": obj.get("fact_ids", []),
                "at": s_to_hms(done), "late": late}
        item = {k: v for k, v in item.items() if v not in ("", [], None) or k in ("late",)}
        with self.lock:
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
