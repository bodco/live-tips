#!/usr/bin/env python3
"""live-transcriber: mic + system audio -> local Whisper (MLX) -> append-only Markdown.

Run:
  transcriber.py --from-control                      (what the LaunchAgent / run.command does)
  transcriber.py --project-dir "$HOME/work/Acme Portal" --title "Sync" --me-lang uk --langs uk,ru

The md file is written to <project-dir>/live/<YYYY-MM-DD-HHMM>-<title>.md, one line per utterance:
  [12:30:11] Я (uk): ...
  [12:30:15] Співрозмовник (ru): ...

Control (all under the tool root):
  control/start.json   request to start (written by the Cowork skill or by hand)
  control/stop         request to stop (any content)
  state/status.json    live status for the skill
"""

from __future__ import annotations

import argparse
import datetime as dt
import difflib
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "bin" / "audiocap"
CONTROL = ROOT / "control"
STATE = ROOT / "state"
LOGS = ROOT / "logs"
SR = 16000
FRAME = 480  # 30 ms at 16 kHz

DEFAULTS = {
    "model": "mlx-community/whisper-large-v3-turbo",
    "me_label": "Я",
    "them_label": "Співрозмовник",
    "me_lang": "uk",            # language of the PM's own mic; "auto" = pick from langs
    "langs": ["uk", "ru"],      # allowed languages in this meeting
    "vad_mode": 2,              # webrtcvad aggressiveness 0..3
    "end_silence": 0.7,         # s of silence that closes a segment
    "max_segment": 12.0,        # s, hard cut for long monologues
    "min_segment": 0.6,         # s, shorter segments are dropped
    "pre_roll": 0.3,            # s of audio kept before speech start
    "sticky_short": 2.0,        # s, segments shorter than this keep the channel's last language
    "echo_window": 4.0,         # s, mic line equal to a system line within this window = echo
    "echo_similarity": 0.6,
    "mic_hold": 3.0,            # s, mic lines wait this long for a matching system line
}

# Phrases Whisper invents on silence or noise. Compared after normalisation.
HALLUCINATIONS = {
    "thank you", "thanks for watching", "thank you for watching", "you", "bye",
    "дякую за перегляд", "дякую", "субтитри", "субтитрування", "продовження далі",
    "спасибо за просмотр", "спасибо", "субтитры", "редактор субтитров",
    "gracias", "gracias por ver", "subtítulos", "amara.org",
}


def now() -> float:
    return time.time()


def hhmmss(t: float) -> str:
    return dt.datetime.fromtimestamp(t).strftime("%H:%M:%S")


def norm(text: str) -> str:
    return re.sub(r"[^\w\s]", "", text.lower()).strip()


def slugify(s: str) -> str:
    s = re.sub(r"[^\w\s-]", "", s, flags=re.UNICODE).strip().lower()
    return re.sub(r"[\s_]+", "-", s)[:60] or "meeting"


def log(msg: str) -> None:
    line = f"{dt.datetime.now().strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        LOGS.mkdir(parents=True, exist_ok=True)
        with open(LOGS / "transcriber.log", "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def write_json_atomic(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


# --------------------------------------------------------------------------- VAD + segmentation

class Vad:
    """webrtcvad when available, otherwise an adaptive energy gate."""

    def __init__(self, mode: int):
        self.noise = 0.003
        try:
            import webrtcvad  # type: ignore
            self.v = webrtcvad.Vad(mode)
        except Exception:  # noqa: BLE001
            self.v = None
            log("webrtcvad not available, using energy VAD")

    def is_speech(self, frame: np.ndarray) -> bool:
        rms = float(np.sqrt(np.mean(frame * frame)) + 1e-9)
        if rms < 0.002:
            self.noise = 0.95 * self.noise + 0.05 * rms
            return False
        if self.v is not None:
            pcm = (np.clip(frame, -1, 1) * 32767).astype(np.int16).tobytes()
            return self.v.is_speech(pcm, SR)
        speech = rms > max(0.008, self.noise * 3)
        if not speech:
            self.noise = 0.95 * self.noise + 0.05 * rms
        return speech


@dataclass
class Segment:
    channel: str          # "me" | "them"
    t_start: float
    t_end: float
    audio: np.ndarray

    @property
    def duration(self) -> float:
        return len(self.audio) / SR


class Segmenter:
    def __init__(self, channel: str, cfg: dict, out: "queue.Queue[Segment]"):
        self.channel = channel
        self.cfg = cfg
        self.out = out
        self.vad = Vad(cfg["vad_mode"])
        self.pending = np.zeros(0, dtype=np.float32)
        self.pre = []                 # frames before speech
        self.cur: list[np.ndarray] = []
        self.in_speech = False
        self.silence = 0.0
        self.t0 = None                # wall time of sample 0
        self.samples = 0
        self.seg_start_sample = 0
        self.peak_window: list[float] = []

    def wall(self, sample_idx: int) -> float:
        return (self.t0 or now()) + sample_idx / SR

    def feed(self, chunk: np.ndarray) -> None:
        if self.t0 is None:
            self.t0 = now() - len(chunk) / SR
        self.pending = np.concatenate([self.pending, chunk])
        while len(self.pending) >= FRAME:
            frame, self.pending = self.pending[:FRAME], self.pending[FRAME:]
            self._frame(frame)
            self.samples += FRAME

    def _frame(self, frame: np.ndarray) -> None:
        self.peak_window.append(float(np.max(np.abs(frame))))
        if len(self.peak_window) > 500:     # ~15 s of frames
            self.peak_window = self.peak_window[-500:]
        speech = self.vad.is_speech(frame)
        fd = FRAME / SR
        if not self.in_speech:
            self.pre.append(frame)
            max_pre = int(self.cfg["pre_roll"] / fd)
            if len(self.pre) > max_pre:
                self.pre = self.pre[-max_pre:]
            if speech:
                self.in_speech = True
                self.silence = 0.0
                self.cur = list(self.pre)
                self.seg_start_sample = self.samples - (len(self.pre) - 1) * FRAME
                self.pre = []
            return
        self.cur.append(frame)
        self.silence = 0.0 if speech else self.silence + fd
        length = len(self.cur) * fd
        if self.silence >= self.cfg["end_silence"] or length >= self.cfg["max_segment"]:
            self._close()

    def _close(self) -> None:
        audio = np.concatenate(self.cur) if self.cur else np.zeros(0, dtype=np.float32)
        self.cur = []
        self.in_speech = False
        self.silence = 0.0
        if len(audio) / SR >= self.cfg["min_segment"]:
            start = self.wall(self.seg_start_sample)
            self.out.put(Segment(self.channel, start, start + len(audio) / SR, audio))

    def flush(self) -> None:
        if self.in_speech:
            self._close()

    def recent_peak(self) -> float:
        return max(self.peak_window) if self.peak_window else 0.0


# --------------------------------------------------------------------------- Whisper (MLX)

class Whisper:
    def __init__(self, cfg: dict):
        import mlx.core as mx  # noqa: F401
        import mlx_whisper  # type: ignore
        self.mlx_whisper = mlx_whisper
        self.repo = cfg["model"]
        self.langs = [l for l in cfg["langs"] if l] or ["uk"]
        self.detector = None
        # Warm up and download the model on first run.
        mlx_whisper.transcribe(np.zeros(SR, dtype=np.float32), path_or_hf_repo=self.repo,
                               language=self.langs[0], verbose=None)
        self._init_detector()

    def _init_detector(self) -> None:
        """Restricted language detection via mlx_whisper internals. Optional: falls back if the API differs."""
        try:
            import mlx.core as mx
            from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim
            from mlx_whisper.decoding import detect_language
            from mlx_whisper.transcribe import ModelHolder
            model = ModelHolder.get_model(self.repo, mx.float16)

            def detect(audio: np.ndarray) -> dict:
                mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
                mel = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
                _, probs = detect_language(model, mel)
                if isinstance(probs, list):
                    probs = probs[0]
                return dict(probs)

            detect(np.zeros(SR, dtype=np.float32))
            self.detector = detect
            log("language detection: restricted to " + "+".join(self.langs))
        except Exception as e:  # noqa: BLE001
            self.detector = None
            log(f"restricted language detection unavailable ({e!r}); using whisper auto + check")

    def pick_language(self, audio: np.ndarray) -> str | None:
        if len(self.langs) == 1:
            return self.langs[0]
        if self.detector is None:
            return None
        probs = self.detector(audio)
        return max(self.langs, key=lambda l: probs.get(l, 0.0))

    def transcribe(self, audio: np.ndarray, language: str | None, prompt: str | None) -> tuple[str, str]:
        res = self.mlx_whisper.transcribe(
            audio, path_or_hf_repo=self.repo, language=language, initial_prompt=prompt or None,
            condition_on_previous_text=False, temperature=(0.0, 0.2, 0.4),
            no_speech_threshold=0.6, logprob_threshold=-1.0, compression_ratio_threshold=2.4,
            verbose=None,
        )
        lang = res.get("language") or language or "?"
        if language is None and lang not in self.langs:
            # Auto picked something outside the allowed set (typical: Ukrainian heard as Russian
            # is fine, but "be", "pl", "pt" are not). Redo with the first allowed language.
            return self.transcribe(audio, self.langs[0], prompt)
        parts = []
        for s in res.get("segments", []):
            if s.get("no_speech_prob", 0) > 0.6 and s.get("avg_logprob", 0) < -0.8:
                continue
            parts.append(s.get("text", "").strip())
        text = " ".join(p for p in parts if p).strip()
        return text, lang


class FakeWhisper:
    """For tests without MLX: returns the segment duration as text."""

    def __init__(self, cfg: dict):
        self.langs = cfg["langs"]

    def pick_language(self, audio):
        return self.langs[0]

    def transcribe(self, audio, language, prompt):
        import hashlib
        words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]
        h = hashlib.md5(audio.tobytes()).digest()
        return " ".join(words[b % 10] for b in h[:5]) + f" ({len(audio) / SR:.1f}s)", language or self.langs[0]


# --------------------------------------------------------------------------- Writer

@dataclass
class Line:
    channel: str
    t: float
    lang: str
    text: str
    written: bool = False
    created: float = field(default_factory=now)


class Writer:
    def __init__(self, path: Path, cfg: dict, header: str):
        self.path = path
        self.cfg = cfg
        self.lock = threading.Lock()
        self.recent_them: list[Line] = []
        self.held_me: list[Line] = []
        self.lines = 0
        self.last_line_at = None
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(header)

    def _similar(self, a: str, b: str) -> bool:
        a, b = norm(a), norm(b)
        if not a or not b:
            return False
        if min(len(a.split()), len(b.split())) < 3:
            return a == b          # short replies ("так", "ok") are often said by both sides
        if a in b or b in a:
            return True
        return difflib.SequenceMatcher(None, a, b).ratio() >= self.cfg["echo_similarity"]

    def add(self, line: Line) -> None:
        with self.lock:
            w = self.cfg["echo_window"]
            if line.channel == "them":
                # Remove held mic lines that are an echo of this system line.
                self.held_me = [m for m in self.held_me
                                if not (abs(m.t - line.t) <= w and self._similar(m.text, line.text))]
                self._write(line)
                self.recent_them.append(line)
                self.recent_them = [l for l in self.recent_them if line.t - l.t <= 30]
            else:
                if any(abs(t.t - line.t) <= w and self._similar(t.text, line.text) for t in self.recent_them):
                    return  # echo of something already written
                self.held_me.append(line)
            self._release()

    def tick(self) -> None:
        with self.lock:
            self._release()

    def _release(self, force: bool = False) -> None:
        keep = []
        for m in sorted(self.held_me, key=lambda x: x.t):
            if force or now() - m.created >= self.cfg["mic_hold"]:
                self._write(m)
            else:
                keep.append(m)
        self.held_me = keep

    def _write(self, line: Line) -> None:
        label = self.cfg["me_label"] if line.channel == "me" else self.cfg["them_label"]
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(f"[{hhmmss(line.t)}] {label} ({line.lang}): {line.text}\n")
            f.flush()
            os.fsync(f.fileno())
        self.lines += 1
        self.last_line_at = now()

    def close(self, footer: str) -> None:
        with self.lock:
            self._release(force=True)
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(footer)


# --------------------------------------------------------------------------- Capture

class Capture(threading.Thread):
    def __init__(self, source: str, seg: Segmenter, stop: threading.Event):
        super().__init__(daemon=True)
        self.source = source
        self.seg = seg
        self.stop_ev = stop
        self.proc: subprocess.Popen | None = None
        self.error: str | None = None
        self.restarts = 0

    def run(self) -> None:
        LOGS.mkdir(parents=True, exist_ok=True)
        while not self.stop_ev.is_set():
            errlog = open(LOGS / f"audiocap-{self.source}.log", "a")
            try:
                self.proc = subprocess.Popen([str(BIN), "--source", self.source],
                                             stdout=subprocess.PIPE, stderr=errlog)
            except OSError as e:
                self.error = f"cannot start audiocap: {e}"
                log(self.error)
                return
            assert self.proc.stdout is not None
            while not self.stop_ev.is_set():
                data = self.proc.stdout.read(6400)   # 0.1 s of float32 mono
                if not data:
                    break
                usable = len(data) - len(data) % 4
                self.seg.feed(np.frombuffer(data[:usable], dtype=np.float32))
            if self.stop_ev.is_set():
                break
            code = self.proc.wait()
            self.restarts += 1
            self.error = f"audiocap {self.source} exited with {code} (see logs/audiocap-{self.source}.log)"
            log(self.error)
            if self.restarts > 5:
                return
            time.sleep(1.5)
        self.terminate()

    def terminate(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()


# --------------------------------------------------------------------------- Main

def load_request(args) -> dict:
    cfg = dict(DEFAULTS)
    user_cfg = ROOT / "config.json"
    if user_cfg.exists():
        cfg.update(json.loads(user_cfg.read_text(encoding="utf-8")))
    req: dict = {}
    if args.from_control:
        start = CONTROL / "start.json"
        if not start.exists():
            sys.exit("control/start.json not found")
        req = json.loads(start.read_text(encoding="utf-8"))
        os.replace(start, CONTROL / "active.json")
    for k in ("project_dir", "title", "slug", "prompt", "me_lang", "langs", "model"):
        v = getattr(args, k, None)
        if v:
            req[k] = v
    if isinstance(req.get("langs"), str):
        req["langs"] = [l.strip() for l in req["langs"].replace("+", ",").split(",") if l.strip()]
    cfg.update({k: v for k, v in req.items() if v not in (None, "")})
    if not cfg.get("project_dir"):
        sys.exit("project_dir is required")
    if cfg["me_lang"] not in ("auto", None) and cfg["me_lang"] not in cfg["langs"]:
        cfg["langs"] = [cfg["me_lang"]] + list(cfg["langs"])
    return cfg


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from-control", action="store_true")
    ap.add_argument("--project-dir")
    ap.add_argument("--title")
    ap.add_argument("--slug")
    ap.add_argument("--prompt")
    ap.add_argument("--me-lang", dest="me_lang")
    ap.add_argument("--langs")
    ap.add_argument("--model")
    ap.add_argument("--fake-whisper", action="store_true", help="test mode without MLX")
    args = ap.parse_args()

    cfg = load_request(args)
    title = cfg.get("title") or "Meeting"
    started = now()
    out = Path(cfg["project_dir"]) / "live" / f"{dt.datetime.fromtimestamp(started):%Y-%m-%d-%H%M}-{slugify(title)}.md"
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / "pid").write_text(str(os.getpid()))
    stop_file = CONTROL / "stop"
    if stop_file.exists():
        stop_file.unlink()

    status = {"state": "loading_model", "pid": os.getpid(), "file": str(out), "title": title,
              "slug": cfg.get("slug"), "started_at": dt.datetime.fromtimestamp(started).isoformat(timespec="seconds"),
              "langs": cfg["langs"], "me_lang": cfg["me_lang"], "lines": 0, "queue": 0,
              "system_audio": "starting", "mic": "starting", "errors": []}
    write_json_atomic(STATE / "status.json", status)
    log(f"live-transcriber: {title} -> {out}")
    log(f"languages: me={cfg['me_lang']} allowed={'+'.join(cfg['langs'])} model={cfg['model']}")

    try:
        whisper = FakeWhisper(cfg) if args.fake_whisper else Whisper(cfg)
    except Exception as e:  # noqa: BLE001
        status.update(state="error", errors=[f"whisper load failed: {e!r}"])
        write_json_atomic(STATE / "status.json", status)
        log(status["errors"][0])
        return 1

    header = (f"# Live transcript: {title}\n\n"
              f"- Проєкт: {cfg.get('slug') or Path(cfg['project_dir']).name}\n"
              f"- Початок: {dt.datetime.fromtimestamp(started):%Y-%m-%d %H:%M:%S}\n"
              f"- Мови: {cfg['me_label']} = {cfg['me_lang']}, дозволені = {'+'.join(cfg['langs'])}\n"
              f"- Модель: {cfg['model']}\n"
              f"- Канали: {cfg['me_label']} = мікрофон, {cfg['them_label']} = системний звук\n\n")
    writer = Writer(out, cfg, header)

    segq: "queue.Queue[Segment]" = queue.Queue()
    stop_ev = threading.Event()
    flushed = threading.Event()
    segs = {"me": Segmenter("me", cfg, segq), "them": Segmenter("them", cfg, segq)}
    caps = [Capture("mic", segs["me"], stop_ev), Capture("system", segs["them"], stop_ev)]
    for c in caps:
        c.start()

    def on_signal(*_):
        stop_ev.set()
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    last_lang = {"me": cfg["me_lang"] if cfg["me_lang"] != "auto" else cfg["langs"][0],
                 "them": cfg["langs"][0]}
    prompt = cfg.get("prompt")

    def process(seg: Segment) -> None:
        if seg.channel == "me" and cfg["me_lang"] != "auto":
            lang = cfg["me_lang"]
        elif seg.duration < cfg["sticky_short"]:
            lang = last_lang[seg.channel]
        else:
            lang = whisper.pick_language(seg.audio)
        text, lang = whisper.transcribe(seg.audio, lang, prompt)
        if not text or norm(text) in HALLUCINATIONS or not norm(text):
            return
        last_lang[seg.channel] = lang
        writer.add(Line(seg.channel, seg.t_start, lang, text))

    def worker() -> None:
        while True:
            try:
                seg = segq.get(timeout=0.5)
            except queue.Empty:
                if flushed.is_set():
                    return
                continue
            try:
                process(seg)
            except Exception as e:  # noqa: BLE001
                log(f"transcribe error: {e!r}")
            finally:
                segq.task_done()

    wt = threading.Thread(target=worker, daemon=True)
    wt.start()
    status["state"] = "recording"
    log("recording. Stop: Ctrl+C here, or the skill writes control/stop")

    last_status = 0.0
    while not stop_ev.is_set():
        time.sleep(0.5)
        writer.tick()
        if stop_file.exists():
            stop_ev.set()
        if now() - last_status >= 2:
            last_status = now()
            errs = [c.error for c in caps if c.error]
            status.update(lines=writer.lines, queue=segq.qsize(), errors=errs,
                          last_line_at=hhmmss(writer.last_line_at) if writer.last_line_at else None,
                          mic="ok" if segs["me"].recent_peak() > 0.001 else "silent",
                          system_audio="ok" if segs["them"].recent_peak() > 0.0005 else "silent")
            write_json_atomic(STATE / "status.json", status)
            if segq.qsize() > 6:
                log(f"warning: {segq.qsize()} segments waiting, transcription is behind")

    log("stopping...")
    status["state"] = "stopping"
    write_json_atomic(STATE / "status.json", status)
    for c in caps:
        c.terminate()
    for c in caps:
        c.join(timeout=3)
    for s in segs.values():
        s.flush()
    flushed.set()
    deadline = now() + 60
    while segq.unfinished_tasks and now() < deadline:
        time.sleep(0.3)
    writer.close(f"\n--- кінець запису {hhmmss(now())} ---\n")
    status.update(state="stopped", lines=writer.lines, stopped_at=hhmmss(now()))
    write_json_atomic(STATE / "status.json", status)
    for f in (CONTROL / "active.json", stop_file, STATE / "pid", STATE / "launching"):
        try:
            f.unlink()
        except FileNotFoundError:
            pass
    log(f"done: {writer.lines} lines -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
