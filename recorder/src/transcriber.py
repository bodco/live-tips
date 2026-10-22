#!/usr/bin/env python3
"""live-transcriber: mic + system audio -> local Whisper (MLX) -> append-only Markdown.

Run:
  transcriber.py --from-control                      (what the LaunchAgent / run.command does)
  transcriber.py --project-dir "$HOME/work/Acme Portal" --title "Sync" --me-lang uk --langs uk,en

The md file is written to <project-dir>/live/<YYYY-MM-DD-HHMM>-<title>.md, one line per utterance:
  [12:30:11] Я (uk): ...
  [12:30:15] Співрозмовник (ru): ...

Control (all under the tool root):
  control/start.json   request to start (written by the Cowork skill or by hand)
  control/stop         request to stop (any content)
  control/go           standby only: start recording now (start.json "standby": true opens the window first)
  state/status.json    live status for the skill; `seq` grows by 1 on every write, `req_id` is
                       copied from start.json so `lt start` knows the status belongs to its request
"""

from __future__ import annotations

import argparse
import collections
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
import zlib
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

# Optional semantic layer (Ollama embeddings). Without it everything works on keywords as before.
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import semantic as SEM
    SEM_ERR = None
except Exception as _e:  # noqa: BLE001
    SEM = None
    SEM_ERR = f"src/semantic.py not loaded ({_e!r})"

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
    "me_langs": [],             # optional: languages the PM may switch between (e.g. uk+en); mic picks among them
    "langs": ["uk", "en"],      # allowed languages in this meeting, the first one is the main one
    "lang_bias": 2.0,           # another allowed language wins only if it is this many times likelier than the main one
    "vad_mode": 2,              # webrtcvad aggressiveness 0..3
    "end_silence": 0.7,         # s of silence that closes a segment
    "max_segment": 12.0,        # s, hard cut for long monologues
    "min_segment": 0.6,         # s, shorter segments are dropped
    "pre_roll": 0.3,            # s of audio kept before speech start
    "sticky_short": 2.0,        # s, segments shorter than this keep the channel's last language
    "echo_window": 4.0,         # s, mic line equal to a system line within this window = echo
    "echo_similarity": 0.6,
    "mic_hold": 3.0,            # s, mic lines wait this long for a matching system line
    "mic_hold_window": 4.0,     # s, mic lines are held only when the system channel had speech this recently
    "mic_stall_s": 12.0,        # s without any mic chunk = stalled
    "mic_zero_s": 10.0,         # s of exact digital zero on the mic (not muted) = stalled
    "prompter": True,           # open the always-on-top tips window (bin/prompter) on start
    "mic_device": "default",    # "default" = system default input (AirPods, Jabra, ...), "builtin" = the Mac's own microphone
    "gap_resync": 1.5,          # s, audio missing from a source longer than this moves its clock forward
    "min_voiced": 0.3,          # share of speech frames a segment needs; below it is noise (fan, keyboard, room)
    "min_rms": 0.003,           # mean loudness a segment needs; quieter segments are dropped as noise
    "max_no_speech": 0.85,      # Whisper's own no-speech probability above this = drop the segment
    # Speaker identification on the system channel (v37). Optional: needs sherpa-onnx and the model.
    "speakers_enabled": True,
    "speaker_model": "models/wespeaker_en_voxceleb_resnet34_LM.onnx",   # relative to the tool root
    "voices_dir": "voices",     # voice library <tool root>/voices/voices.json (never in a repo)
    "speaker_join": 0.45,       # cosine to a cluster centroid needed to join it (tuned on real speech, see README)
    "speaker_new_min_s": 1.5,   # only segments this long may open a new cluster (shorter ones are too noisy)
    "speaker_automerge": 0.6,   # two clusters whose centroids are this close are the same person
    "speaker_suggest": 0.5,     # library people with cosine >= this are offered as suggestions
    "speaker_prompt_s": 8.0,    # s of speech of an unnamed cluster before the window asks "Who is speaking?"
    "speaker_min_s": 1.0,       # s of speech a segment needs to get an embedding
    "speaker_inherit_s": 1.5,   # a segment without a usable embedding keeps the previous speaker within this gap
    "speaker_wait_s": 0,        # v37.1: never wait for the voice embedding; a late tag arrives via speakers.json
    "speaker_queue": 8,         # embedding jobs waiting; when behind, the oldest is dropped
    # Semantic layer (local Ollama embeddings). Optional: off with a reason when Ollama or the model is missing.
    "semantic_enabled": True,
    "ollama_url": "http://127.0.0.1:11434",
    "semantic_model": "bge-m3",
    "semantic_timeout_s": 2.0,  # s per live embedding call; a line that misses it is skipped
    "semantic_fact_min": 0.55,  # cosine of a `them` line to a fact needed for an automatic 📌 (bge-m3 scale)
    "semantic_card_min": 0.60,  # cosine of a line to a card (its gist or a trigger) needed to fire it
    "semantic_margin": 0.08,    # the cosine must also beat the entry's small-talk noise floor by this much
    "semantic_card_margin": 0.10,
    "semantic_sos_min": 0.45,   # SOS: semantic picks need at least this cosine to the live topic
    "semantic_index_min": 0.40, # SOS: project index snippets need at least this cosine
    "semantic_min_words": 3,    # shorter lines ("так", "ok") are not embedded
    "semantic_queue": 6,        # lines waiting for an embedding; when behind, the oldest is dropped
    "semantic_topic_s": 60,     # s of lines in the rolling "live topic" vector
    "index_enabled": True,      # keep <project>/.livetips-index fresh in the background during calls
    "index_extra": [],          # extra folders to index (e.g. a workspace _notion mirror)
    "index_live_max_chunks": 1500,  # at most this many chunks embedded per call (pre-index with `lt index`)
    "index_batch": 4,           # chunks per embedding request while recording
}

# Phrases Whisper invents on silence or noise. Compared after normalisation.
HALLUCINATIONS = {
    "thank you", "thanks for watching", "thank you for watching", "you", "bye",
    "дякую за перегляд", "дякую", "субтитри", "субтитрування", "продовження далі",
    "спасибо за просмотр", "спасибо", "субтитры", "редактор субтитров",
    "gracias", "gracias por ver", "subtítulos", "amara.org",
}

# Whisper was trained on subtitled internet videos. On silence, music or chopped audio it "recalls"
# their credit lines ("Субтитры создавал DimaTorzok", "Редактор субтитров ...", "Продолжение
# следует..."). These are not in the audio and not a virus: they come from the model itself.
# A sentence matching any pattern is removed; a line left empty is dropped.
HALLUCINATION_PATTERNS = [re.compile(p, re.I) for p in (
    r"субтитр", r"subtit", r"dimatorzok", r"корректор", r"amara\.org",
    r"продолжение следует", r"продовження (далі|буде|слідує)",
    r"спасибо за просмотр", r"дякую за перегляд", r"thanks? (you )?for watching",
    r"подписывайтесь", r"підписуйтесь", r"ставьте лайк", r"ставте лайк",
    r"^\W*(динамичная |спокойная |веселая |тревожная )?музыка\W*$", r"^\W*музика\W*$", r"^\W*music\W*$",
    # Seen on real calls as a whole line on noise or silence (not inside a longer sentence):
    r"^\W*наступного( року)?\W*$", r"^\W*відповідь( на екран)?\W*$", r"^\W*au revoir\W*$",
    # Sound descriptions the large model writes for non-speech (163 of 401 lines on one real call):
    r"^\W*(звучить|грає|лунає|звучала|звучать)\s+\w*\s*(музика|музику|пісня|мелодія)\W*$",
    r"^\W*(звук|шум|звуки)\s+[\w\s]{0,30}\W*$", r"^\W*(закінчення|кінець( брифінгу| відео| запису)?|продовження)\W*$",
    r"^\W*\[?(music|applause|laughter|silence|noise)\]?\W*$",
    # Video-credit style lines on noise: "Олександр Григорьов, директор ...", "Редактор: ..."
    r"^(?=(?:\S+\s+){0,6}\S+\s*$)\W*[А-ЯІЇЄҐA-Z][\w'’-]+\s+[А-ЯІЇЄҐA-Z][\w'’-]+,\s*(директор|редактор|коректор|перекладач|диктор|продюсер|ведуч\w*|автор|режисер|оператор|кореспондент|director|editor|producer|translator|narrator|host)\b",
    r"^\W*(редактор|коректор|перекладач|диктор|субтитр\w*|переклад)\s*[:\-]", r"^\W*(оплески|сміх|тиша|шум)\W*$",
    # Pure fillers ("м-м-м", "мгм", "е-е"): nothing to read, only clutter.
    r"^\W*(([мме]+[\s-]*)+|мгм+|угу+|гм+|хм+)\W*$",
)]

_REPEAT = re.compile(r"((?:\w[\w'’-]*\W+){1,4}?)\1{2,}")


PROMPT_HEAD: list[str] = []   # first two words of the Whisper prompt, set in main()


def clean_text(text: str, prompt_words: set[str]) -> str:
    """Remove Whisper artefacts. Returns "" when nothing real is left."""
    text = (text or "").strip()
    parts = re.split(r"(?<=[.!?…])\s+", text)
    text = " ".join(p for p in parts if p and not any(rx.search(p) for rx in HALLUCINATION_PATTERNS)).strip()
    if not text or norm(text) in HALLUCINATIONS:
        return ""
    # Repetition loop ("Маша, Льоша, Маша, Льоша, ..." or "сьому сьому сьому"): collapse repeats;
    # if the repeats were most of the line, the whole line is noise.
    collapsed = _REPEAT.sub(r"\1", text + " ").strip()
    if len(collapsed) < 0.5 * len(text):
        return ""
    text = collapsed
    words = re.findall(r"\w+", text.lower())
    if len(words) >= 8 and len(set(words)) / len(words) < 0.4:
        return ""
    raw = text.encode("utf-8")
    if len(raw) > 80 and len(raw) / max(1, len(zlib.compress(raw))) > 2.6:
        return ""
    # Prompt echo: on noise Whisper repeats the names it was given in the prompt.
    if prompt_words and len(words) >= 2 and sum(w in prompt_words for w in words) / len(words) >= 0.7:
        return ""
    # One or two words that all come from the prompt ("Дзвінок." when the prompt starts with
    # "Дзвінок команди ..."): Whisper echoes the start of the prompt on noise.
    if prompt_words and 1 <= len(words) <= 2 and all(w in prompt_words for w in words):
        return ""
    # A short line that starts like the prompt ("Дзвінок команди Санкт-Петербурга." when the
    # prompt is "Дзвінок команди Acme Portal: ..."): Whisper echoes the prompt's opening on
    # silence and garbles the rest, so the word-overlap check above misses it.
    if PROMPT_HEAD and len(words) <= 6 and words[:len(PROMPT_HEAD)] == PROMPT_HEAD:
        return ""
    # Same echo glued in front of real speech: "Дзвінок команди, а також, що це нормально..."
    if PROMPT_HEAD and words[:len(PROMPT_HEAD)] == PROMPT_HEAD:
        m = re.match(r"^\W*" + r"\W+".join(map(re.escape, PROMPT_HEAD)) + r"\s*,\s*(.+)$", text, re.I)
        if m:
            rest = m.group(1).strip()
            text = rest[:1].upper() + rest[1:]
    return text


CYRILLIC_LANGS = ("uk", "ru", "be", "bg")


def fix_lang_by_script(text: str, lang: str, langs: list[str]) -> str:
    """Whisper (turbo) sometimes tags Ukrainian speech as "en" while the text is Cyrillic.
    The text is what was heard, so the tag follows the script of the text."""
    letters = re.findall(r"[^\W\d_]", text)
    if len(letters) < 3:
        return lang
    cyr = sum(1 for c in letters if "\u0400" <= c <= "\u04ff") / len(letters)
    if cyr >= 0.7 and lang not in CYRILLIC_LANGS:
        for l in langs:
            if l in CYRILLIC_LANGS:
                return l
    if cyr <= 0.1 and lang in CYRILLIC_LANGS:
        for l in langs:
            if l not in CYRILLIC_LANGS:
                return l
    return lang


def now() -> float:
    return time.time()


def hhmmss(t: float) -> str:
    return dt.datetime.fromtimestamp(t).strftime("%H:%M:%S")


def norm(text: str) -> str:
    return re.sub(r"[^\w\s]", "", text.lower()).strip()


def mac_timezone() -> str | None:
    """IANA zone of the Mac clock, e.g. Europe/Kyiv (from the /etc/localtime symlink)."""
    try:
        real = os.path.realpath("/etc/localtime")
        i = real.find("zoneinfo/")
        return real[i + len("zoneinfo/"):] if i >= 0 else None
    except OSError:
        return None


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


def launch_prompter(title: str, tips: Path, inbox: Path) -> None:
    """Open the tips window. Closes a window left from a previous call first. Never fatal."""
    exe = ROOT / "bin" / "prompter"
    if not exe.exists():
        log("prompter: bin/prompter not built (re-run install.sh), tips stay in the chat")
        return
    pid_file = STATE / "prompter.pid"
    try:
        os.kill(int(pid_file.read_text().strip()), signal.SIGTERM)
    except (OSError, ValueError):
        pass
    try:
        tips.parent.mkdir(parents=True, exist_ok=True)
        tips.touch(exist_ok=True)
        inbox.touch(exist_ok=True)
        logf = open(LOGS / "prompter.log", "a", encoding="utf-8")
        proc = subprocess.Popen(
            [str(exe), "--tips", str(tips), "--inbox", str(inbox), "--control", str(CONTROL),
             "--status", str(STATE / "status.json"), "--html", str(ROOT / "src" / "prompter.html"),
             "--title", f"Суфлер · {title}"],
            stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
        pid_file.write_text(str(proc.pid))
        log(f"prompter: window opened (pid {proc.pid})")
    except Exception as e:  # noqa: BLE001
        log(f"prompter: could not start ({e!r}), tips stay in the chat")


def write_json_atomic(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
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
    voiced_s: float = -1.0   # s of speech frames in the segment (-1 = unknown: use the duration)

    @property
    def speech_s(self) -> float:
        return self.voiced_s if self.voiced_s >= 0 else self.duration

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
        self.lost = 0.0               # s of audio that never arrived (device restarts etc.)
        self.muted = False            # PM pressed mute in the tips window: mic audio is ignored
        self.last_feed: float | None = None   # wall time of the last chunk from audiocap (also while muted)
        self.voiced = 0               # speech frames in the open segment
        self.noise_dropped = 0        # segments dropped as noise (low share of speech or too quiet)
        self.last_speech_at: float | None = None   # wall time of the last speech frame (mic_hold)
        self.last_nonzero: float | None = None     # wall time of the last chunk with a non-zero sample
        self.unmuted_at = 0.0         # wall time of the last unmute (digital silence counts from here)

    def wall(self, sample_idx: int) -> float:
        return (self.t0 or now()) + sample_idx / SR

    def set_muted(self, on: bool) -> None:
        if on:
            if self.in_speech:
                self._close()         # keep what was said before the click
            self.samples += len(self.pending)
            self.pending = np.zeros(0, dtype=np.float32)
            self.pre = []
        elif self.muted:
            self.unmuted_at = now()
        self.muted = on

    def feed(self, chunk: np.ndarray) -> None:
        t = now()
        self.last_feed = t
        if len(chunk) and np.any(chunk):
            self.last_nonzero = t
        if self.t0 is None:
            self.t0 = t - len(chunk) / SR
        else:
            # Timestamps come from the sample count. If the source lost audio (mic restarts when
            # Meet or AirPods switch modes), the count falls behind the clock and every later line
            # would get an old time. Close the open phrase (do not glue audio across a hole) and
            # move this source's clock forward.
            gap = t - (self.t0 + (self.samples + len(self.pending) + len(chunk)) / SR)
            if gap > self.cfg["gap_resync"]:
                if self.in_speech:
                    self._close()
                self.t0 += gap
                self.lost += gap
        if self.muted:
            # Muted in the tips window (the PM is muted in the meeting): music and people around
            # are not transcribed as the PM. The clock keeps running.
            self.samples += len(chunk)
            return
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
        if speech:
            self.last_speech_at = self.wall(self.samples)
        if not self.in_speech:
            self.pre.append(frame)
            max_pre = int(self.cfg["pre_roll"] / fd)
            if len(self.pre) > max_pre:
                self.pre = self.pre[-max_pre:]
            if speech:
                self.in_speech = True
                self.silence = 0.0
                self.cur = list(self.pre)
                self.voiced = 1
                self.seg_start_sample = self.samples - (len(self.pre) - 1) * FRAME
                self.pre = []
            return
        self.cur.append(frame)
        if speech:
            self.voiced += 1
        self.silence = 0.0 if speech else self.silence + fd
        length = len(self.cur) * fd
        if self.silence >= self.cfg["end_silence"] or length >= self.cfg["max_segment"]:
            self._close()

    def _close(self) -> None:
        audio = np.concatenate(self.cur) if self.cur else np.zeros(0, dtype=np.float32)
        frames = max(1, len(self.cur))
        voiced, self.voiced = self.voiced, 0
        self.cur = []
        self.in_speech = False
        self.silence = 0.0
        if len(audio) / SR >= self.cfg["min_segment"]:
            # Noise gate: a fan, a keyboard or the room trigger the VAD for a few frames; Whisper
            # then invents text for them ("Звучить музика", a name with a job title). Real speech
            # has a high share of speech frames and some loudness.
            rms = float(np.sqrt(np.mean(audio * audio))) if len(audio) else 0.0
            if voiced / frames < self.cfg["min_voiced"] or rms < self.cfg["min_rms"]:
                self.noise_dropped += 1
                return
            start = self.wall(self.seg_start_sample)
            self.out.put(Segment(self.channel, start, start + len(audio) / SR, audio, voiced * FRAME / SR))

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
        self.bias = float(cfg.get("lang_bias") or 1.0)
        self.max_no_speech = float(cfg.get("max_no_speech") or 0.85)
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

    def pick_language(self, audio: np.ndarray, allowed: list[str] | None = None) -> str | None:
        allowed = allowed or self.langs
        if len(allowed) == 1:
            return allowed[0]
        if self.detector is None:
            return None if allowed is self.langs else allowed[0]
        probs = self.detector(audio)
        base = allowed[0]
        best = max(allowed, key=lambda l: probs.get(l, 0.0))
        # The first language is the main one: switch away only on a clear win, so short or
        # noisy phrases stay in the main language instead of flipping to another one.
        if best != base and probs.get(best, 0.0) < self.bias * probs.get(base, 0.0):
            return base
        return best

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
        segs = res.get("segments", [])
        if segs and min(x.get("no_speech_prob", 0) for x in segs) > self.max_no_speech:
            return "", lang   # Whisper itself is sure there is no speech
        for s in segs:
            nsp, lp = s.get("no_speech_prob", 0), s.get("avg_logprob", 0)
            if nsp > 0.6 and lp < -0.8:
                continue
            if lp < -1.25 or s.get("compression_ratio", 0) > 2.4:
                continue   # low confidence or a repetition loop
            parts.append(s.get("text", "").strip())
        text = " ".join(p for p in parts if p).strip()
        return text, fix_lang_by_script(text, lang, self.langs)


class FakeWhisper:
    """For tests without MLX: returns the segment duration as text."""

    def __init__(self, cfg: dict):
        self.langs = cfg["langs"]

    def pick_language(self, audio, allowed=None):
        return (allowed or self.langs)[0]

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
    sid: str | None = None    # speaker cluster of a system-channel line ("S2"), None = no speaker tag


def hold_me_line(last_them_speech: float | None, line_t: float, window: float = 4.0) -> bool:
    """A mic line waits for a matching system line (echo check) only when the system channel
    had speech within `window` s before the line started or later. With nobody else talking
    there is nothing to echo, so the PM's line is written at once."""
    return last_them_speech is not None and last_them_speech >= line_t - window


class Writer:
    def __init__(self, path: Path, cfg: dict, header: str, them_speech=None):
        self.path = path
        self.cfg = cfg
        self.them_speech = them_speech or (lambda: None)   # wall time of the last system speech frame
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

    def marker(self, text: str) -> None:
        """A service line in the transcript, e.g. mic muted / unmuted."""
        with self.lock:
            self._release(force=True)
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(f"--- {text} {hhmmss(now())} ---\n")

    def _release(self, force: bool = False) -> None:
        keep = []
        last_them = self.them_speech()
        win = float(self.cfg.get("mic_hold_window", 4.0))
        for m in sorted(self.held_me, key=lambda x: x.t):
            # Once one line is kept, the later ones wait too, so the order stays by time.
            if not keep and (force or now() - m.created >= self.cfg["mic_hold"]
                             or not hold_me_line(last_them, m.t, win)):
                self._write(m)
            else:
                keep.append(m)
        self.held_me = keep

    def _write(self, line: Line) -> None:
        label = self.cfg["me_label"] if line.channel == "me" else self.cfg["them_label"]
        if line.channel == "them" and line.sid:
            label += f" [{line.sid}]"
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


# --------------------------------------------------------------------------- Prep file parsers
# The skill writes these files during the call; a half-written or hand-edited file must never
# crash the recorder. The parsers coerce types and fill missing ids instead of raising.

def _as_list(data, key: str) -> list:
    """A list, or {"<key>": [...]} (also {"items": [...]}); anything else is an empty list."""
    if isinstance(data, dict):
        data = data.get(key, data.get("items"))
    return data if isinstance(data, list) else []


def _s(v) -> str:
    return "" if v is None else str(v).strip()


def _strs(v) -> list[str]:
    if v is None:
        return []
    if isinstance(v, (list, tuple)):
        return [str(x).strip() for x in v if x is not None and str(x).strip()]
    return [str(v).strip()] if str(v).strip() else []


def parse_cards(data) -> list[dict]:
    out = []
    for i, c in enumerate(_as_list(data, "cards")):
        if not isinstance(c, dict):
            continue
        trig = _strs(c.get("triggers"))
        if not trig:
            continue
        g = dict(c)
        g["id"] = _s(c.get("id")) or _s(c.get("gist"))[:30] or f"c{i + 1}"
        g["triggers"] = trig
        on = _s(c.get("on")).lower() or "any"
        g["on"] = on if on in ("me", "them", "any") else "any"
        for k in ("gist", "phrase", "note", "level"):
            if k in c:
                g[k] = _s(c.get(k))
        if "items" in c:
            g["items"] = _strs(c.get("items"))
        try:
            g["cooldown_s"] = float(c.get("cooldown_s", 300))
        except (TypeError, ValueError):
            g["cooldown_s"] = 300.0
        out.append(g)
    return out


def parse_facts(data) -> list[dict]:
    out = []
    for i, f in enumerate(_as_list(data, "facts")):
        if not isinstance(f, dict):
            continue
        title, text = _s(f.get("title")), _s(f.get("text"))
        if not title and not text:
            continue
        g = dict(f)
        g.update(id=_s(f.get("id")) or f"f{i + 1}", title=title, text=text, keywords=_strs(f.get("keywords")))
        if "source" in f:
            g["source"] = _s(f.get("source"))
        out.append(g)
    return out


def parse_outline(data) -> list[dict]:
    out = []
    for i, x in enumerate(_as_list(data, "sections")):
        if not isinstance(x, dict) or not _s(x.get("title")):
            continue
        g = dict(x)
        g.update(id=_s(x.get("id")) or f"s{i + 1}", title=_s(x.get("title")),
                 keywords=_strs(x.get("keywords")), points=_strs(x.get("points")))
        out.append(g)
    return out


def parse_slides(data) -> list[dict]:
    out = []
    for i, x in enumerate(_as_list(data, "slides")):
        if not isinstance(x, dict) or not _s(x.get("title")):
            continue
        body = []
        for b in x.get("body") or []:
            if isinstance(b, dict) and _s(b.get("t")):
                k = _s(b.get("k")) or "p"
                body.append({"k": k if k in ("p", "s", "h", "c") else "p", "t": _s(b.get("t"))})
            elif isinstance(b, str) and b.strip():
                body.append({"k": "p", "t": b.strip()})
        who = _s(x.get("who")) or "me"
        try:
            sec = max(5, int(float(x.get("sec") or 60)))
        except (TypeError, ValueError):
            sec = 60
        out.append({"n": x.get("n", i + 1), "title": _s(x.get("title")),
                    "who": who if who in ("me", "shared", "other") else "other",
                    "speaker": _s(x.get("speaker")), "sec": sec, "body": body})
    return out


# --------------------------------------------------------------------------- Instant cards

class Cards:
    """Pre-built tips ("battlecards") shown the moment a trigger phrase is transcribed, with no
    model in the loop. The skill writes <transcript stem>.cards.json during its prep:
      [{"id": "cr", "triggers": ["could you also", "можна ще", "re:\\bcan we add\\b"],
        "on": "them" | "me" | "any", "level": "red", "gist": "...", "phrase": "...",
        "items": [...], "note": "...", "cooldown_s": 300, "off": false}, ...]
    Triggers match the normalised line text (case-insensitive, plain substring, or a regex
    after "re:"). Each fired card is written to the tips file (kind "card") and to
    <stem>.cards-fired.jsonl, which read_delta.py reports to the skill as @@CARD lines."""

    def __init__(self, transcript: Path, tips: Path):
        self.path = transcript.with_name(transcript.stem + ".cards.json")
        self.fired_path = transcript.with_name(transcript.stem + ".cards-fired.jsonl")
        self.tips = tips
        self.mtime = None
        self.cards: list[dict] = []
        self.last: dict[str, float] = {}
        self.lock = threading.Lock()
        self.bad_mtime = None

    def _load(self) -> None:
        try:
            m = self.path.stat().st_mtime
        except OSError:
            self.cards, self.mtime = [], None
            return
        if m == self.mtime:
            return
        try:
            cards = parse_cards(json.loads(self.path.read_text(encoding="utf-8")))
        except Exception as e:  # noqa: BLE001
            # Keep the last good set; retry on the next check (the file may be half-written).
            if self.bad_mtime != m:
                self.bad_mtime = m
                log(f"cards: cannot read {self.path.name} ({e!r})")
            return
        self.cards, self.mtime = cards, m
        log(f"cards: {len(self.cards)} loaded from {self.path.name}")

    def snapshot(self) -> list[dict]:
        with self.lock:
            try:
                self._load()
            except Exception:  # noqa: BLE001
                pass
            return list(self.cards)

    @staticmethod
    def _hit(trigger: str, low: str, plain: str) -> bool:
        t = str(trigger).strip()
        if not t:
            return False
        if t.startswith("re:"):
            try:
                return re.search(t[3:], low, re.I) is not None
            except re.error:
                return False
        return norm(t) in plain

    def check(self, line: "Line") -> None:
        with self.lock:
            self._load()
            if not self.cards:
                return
            low = line.text.lower()
            plain = " " + norm(line.text) + " "
            for c in self.cards:
                if c.get("off"):
                    continue
                on = c.get("on", "any")
                if on != "any" and on != line.channel:
                    continue
                cid = self.cid(c)
                if now() - self.last.get(cid, 0) < float(c.get("cooldown_s", 300)):
                    continue
                if not any(self._hit(t, low, plain) for t in c.get("triggers", [])):
                    continue
                self.last[cid] = now()
                self._emit(c, cid, line)

    @staticmethod
    def cid(c: dict) -> str:
        return str(c.get("id") or str(c.get("gist", ""))[:30])

    def _emit(self, c: dict, cid: str, line: "Line", sem: float | None = None) -> None:
        tip = {k: c[k] for k in ("level", "gist", "phrase", "items", "note") if c.get(k)}
        tip.update(t=hhmmss(line.t), src=hhmmss(line.t), at=hhmmss(now()), kind="card", card=cid)
        fired = {"id": cid, "t": hhmmss(line.t), "ch": line.channel, "line": line.text[:160]}
        if sem is not None:
            tip["sem"] = fired["sem"] = round(float(sem), 3)
        try:
            with open(self.tips, "a", encoding="utf-8") as f:
                f.write(json.dumps(tip, ensure_ascii=False) + "\n")
            with open(self.fired_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(fired, ensure_ascii=False) + "\n")
        except OSError:
            pass

    def fire_semantic(self, cid: str, line: "Line", score: float) -> str | None:
        """Fire a card found by meaning (not by a trigger). None when shown, else why not."""
        with self.lock:
            c = next((x for x in self.cards if self.cid(x) == cid), None)
            if c is None or c.get("off"):
                return "gone"
            if now() - self.last.get(cid, 0) < float(c.get("cooldown_s", 300)):
                return "cooldown"
            self.last[cid] = now()
            self._emit(c, cid, line, sem=score)
            return None


# --------------------------------------------------------------------------- Fact book and outline

STOP_WORDS = set("""the and for that this with you your are was were have has will would could should
can about from what when where which into there their they them then than just also only very
але або щоб тому коли якщо тобто типу просто також треба можна буде було були який яка яке які
цей цього цьому ця це ці там тут вже ще дуже нам вам вони воно його йому її мені тебе тобі тоді
как что это так там тут уже еще""".split())


def tokens(text: str) -> list[str]:
    return [w for w in re.findall(r"[\w'’]{3,}", (text or "").lower()) if w not in STOP_WORDS]


def tok_match(a: str, b: str) -> bool:
    """Same word or the same stem: Ukrainian and English inflections ("логи" / "логів",
    "logs" / "logging") share all letters but the last one or two."""
    if a == b:
        return True
    if min(len(a), len(b)) < 4:
        return False
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n >= 3 and n >= min(len(a), len(b)) - 1


QUESTION_CUE = re.compile(
    r"\?|скільки|коли|як довго|термін|естімейт|оцінк|дедлайн|статус|ціна|вартіст|сколько|когда|"
    r"how long|how much|how many|when|estimate|\beta\b|deadline|status|price|cost", re.I)


class FactBook:
    """The project fact book (<transcript stem>.facts.json), written by the skill's prep:
      [{"id": "AUTH-123", "title": "Admin logs", "text": "estimate 16 h, In Progress, Mike",
        "keywords": ["logs", "логи", "audit"], "source": "Jira 18.10"}, ...]
    The tips window gets the whole book once (kind "facts") for its instant search box.
    When the other side asks a question (a cue word or "?") that names something in the book,
    the best 1-2 facts are shown at once as kind "fact", with no model in the loop."""

    def __init__(self, transcript: Path, tips: Path):
        self.path = transcript.with_name(transcript.stem + ".facts.json")
        self.tips = tips
        self.mtime = None
        self.facts: list[dict] = []
        self.index: list[tuple[dict, set[str]]] = []
        self.last: dict[str, float] = {}
        self.bad_mtime = None
        self.claim_lock = threading.Lock()

    def claim(self, fid: str, cooldown: float = 300.0) -> bool:
        """True (and the cooldown starts) unless this fact was shown less than `cooldown` s ago.
        Shared by the keyword path and the semantic path, so one fact is never shown twice."""
        with self.claim_lock:
            if now() - self.last.get(fid, 0) < cooldown:
                return False
            self.last[fid] = now()
            return True

    def refresh(self) -> None:
        """Pick up a new or changed fact book. Never raises; the mtime is recorded only after a
        successful parse, so a half-written file is read again on the next refresh."""
        try:
            m = self.path.stat().st_mtime
        except OSError:
            return
        if m == self.mtime:
            return
        try:
            facts = parse_facts(json.loads(self.path.read_text(encoding="utf-8")))
            index = [(f, set(tokens(" ".join([f["id"], f["title"], " ".join(f["keywords"])]))))
                     for f in facts]
        except Exception as e:  # noqa: BLE001
            if self.bad_mtime != m:
                self.bad_mtime = m
                log(f"facts: cannot read {self.path.name} ({e!r})")
            return
        self.facts, self.index, self.mtime = facts, index, m
        _append_json(self.tips, {"kind": "facts", "at": hhmmss(now()), "facts": self.facts})
        log(f"facts: {len(self.facts)} loaded from {self.path.name}")

    def check(self, line: "Line") -> None:
        if not self.index or line.channel != "them" or not QUESTION_CUE.search(line.text):
            return
        q = [t for t in tokens(line.text) if not QUESTION_CUE.fullmatch(t)]
        keys = set(re.findall(r"\b[A-Z][A-Z0-9]+-\d+\b", line.text))
        scored = []
        for f, ft in self.index:
            score = sum(1 for t in q if any(tok_match(t, x) for x in ft))
            if keys and str(f.get("id", "")) in keys:
                score += 3
            if score >= 2:
                scored.append((score, f))
        scored.sort(key=lambda x: -x[0])
        shown = []
        for score, f in scored[:4]:
            fid = str(f.get("id") or f.get("title"))
            if not self.claim(fid):
                continue
            shown.append(f)
            if len(shown) == 2:
                break
        if not shown:
            return
        items = [f"{f.get('title', '')}: {f.get('text', '')}".strip(": ") for f in shown]
        _append_json(self.tips, {"t": hhmmss(line.t), "src": hhmmss(line.t), "at": hhmmss(now()),
                                 "kind": "fact", "level": "orange", "gist": "📌 " + shown[0].get("title", ""),
                                 "items": items, "note": " · ".join(str(f.get("source", "")) for f in shown if f.get("source"))})


class Outline:
    """Presentation tracker (<transcript stem>.outline.json), written by the skill:
      [{"id": "s15", "title": "Pipedrive: prices", "points": ["4 plans, 14-69 EUR", ...],
        "keywords": ["pipedrive", "тариф", "lite", "growth"]}, ...]
    Every PM line is matched against the sections; the window pins "Now" and "Next" (kind
    "outline_pos"). It moves forward or back only on a clear match, so a side remark does not
    jump around; the skill may rewrite the file (e.g. the next section) during the call."""

    def __init__(self, transcript: Path, tips: Path):
        self.path = transcript.with_name(transcript.stem + ".outline.json")
        self.tips = tips
        self.mtime = None
        self.sections: list[dict] = []
        self.sets: list[set[str]] = []
        self.cur = -1
        self.recent: list[str] = []
        self.bad_mtime = None

    def refresh(self) -> None:
        """Same contract as FactBook.refresh: never raises, mtime only after a good parse."""
        try:
            m = self.path.stat().st_mtime
        except OSError:
            return
        if m == self.mtime:
            return
        try:
            sections = parse_outline(json.loads(self.path.read_text(encoding="utf-8")))
            sets = [set(tokens(" ".join([x["title"]] + x["keywords"] + x["points"]))) for x in sections]
        except Exception as e:  # noqa: BLE001
            if self.bad_mtime != m:
                self.bad_mtime = m
                log(f"outline: cannot read {self.path.name} ({e!r})")
            return
        self.sections, self.sets, self.mtime = sections, sets, m
        if self.cur >= len(self.sections):      # the skill rewrote the outline shorter
            self.cur = len(self.sections) - 1
        _append_json(self.tips, {"kind": "outline", "at": hhmmss(now()), "sections": self.sections})
        self._emit()
        log(f"outline: {len(self.sections)} sections from {self.path.name}")

    def _emit(self) -> None:
        if not self.sections:
            return
        cur = min(self.cur, len(self.sections) - 1)
        _append_json(self.tips, {"kind": "outline_pos", "at": hhmmss(now()),
                                 "cur": self.sections[cur].get("id") if cur >= 0 else None,
                                 "next": self.sections[cur + 1].get("id") if cur + 1 < len(self.sections) else None})

    def check(self, line: "Line") -> None:
        if not self.sections or line.channel != "me":
            return
        self.recent = (self.recent + tokens(line.text))[-60:]   # ~the last 20-30 s of the PM's words
        best, best_i = 0, -1
        lo, hi = max(0, self.cur - 1), min(len(self.sections), self.cur + 4)
        for i in range(len(self.sections)):
            sc = sum(1 for t in set(self.recent) if any(tok_match(t, x) for x in self.sets[i]))
            near = lo <= i < hi
            if (near and sc >= 3) or sc >= 6:
                if sc > best or (sc == best and i > best_i and near):
                    best, best_i = sc, i
        if best_i >= 0 and best_i != self.cur:
            self.cur = best_i
            self.recent = []
            self._emit()


class Slides:
    """Slide-by-slide speech for presentation mode (<transcript stem>.slides.json), written by
    the skill from the speaker notes:
      {"title": "...", "total_min": 40, "slides": [{"n": 12, "title": "...",
        "who": "me" | "shared" | "other", "speaker": "Maria", "sec": 75,
        "body": [{"k": "p" | "s" | "h" | "c", "t": "..."}]}]}
    k: p = read aloud, s = may be skipped, h = hint (not read), c = cue from another speaker.
    The window shows one card per slide in the left half (split view) when the meeting type is
    presentation. Same refresh contract as Outline: never raises, mtime only after a good parse."""

    def __init__(self, transcript: Path, tips: Path):
        self.path = transcript.with_name(transcript.stem + ".slides.json")
        self.tips = tips
        self.mtime = None
        self.bad_mtime = None

    def refresh(self) -> None:
        try:
            m = self.path.stat().st_mtime
        except OSError:
            return
        if m == self.mtime:
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            slides = parse_slides(data)
        except Exception as e:  # noqa: BLE001
            if self.bad_mtime != m:
                self.bad_mtime = m
                log(f"slides: cannot read {self.path.name} ({e!r})")
            return
        self.mtime = m
        meta = data if isinstance(data, dict) else {}
        _append_json(self.tips, {"kind": "slides", "at": hhmmss(now()), "title": _s(meta.get("title")),
                                 "total_min": meta.get("total_min"), "slides": slides})
        log(f"slides: {len(slides)} slides from {self.path.name}")


def _append_json(path: Path, obj: dict) -> None:
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")
    except OSError:
        pass


# --------------------------------------------------------------------------- Meeting settings

CALL_TYPES = ("auto", "presentation", "interview")
AUDIENCES = ("auto", "team", "client", "boss")


def normalize_meeting(call_type, audience=None) -> tuple[str, str]:
    """v36 meeting concept: call_type auto|presentation|interview, audience auto|team|client|boss.
    Legacy call types are accepted: status/topic -> auto, client -> auto + audience client,
    hiring -> interview. Unknown values fall back to auto."""
    ct = _s(call_type).lower() or "auto"
    au = _s(audience).lower() or "auto"
    if ct in ("status", "topic"):
        ct = "auto"
    elif ct == "client":
        ct = "auto"
        if au == "auto":
            au = "client"
    elif ct == "hiring":
        ct = "interview"
    if ct not in CALL_TYPES:
        ct = "auto"
    if au not in AUDIENCES:
        au = "auto"
    return ct, au


HIRING_ROLES = ("observer", "coach", "interviewer")


def normalize_hiring_role(v) -> str:
    """Interview role: observer|coach|interviewer ("" = not set). The legacy value `candidate`
    (the PM is the one being asked) is accepted and mapped to `coach`. Unknown values pass through."""
    r = _s(v).lower()
    return "coach" if r == "candidate" else r


def normalize_proactive(v) -> str:
    return "on" if _s(v).lower() in ("on", "true", "1", "yes") else "off"


# --------------------------------------------------------------------------- Question marker, SOS

def short_gist(text: str, n: int = 60) -> str:
    text = re.sub(r"\s+", " ", text or "").strip()
    if len(text) <= n:
        return text
    cut = text[:n].rsplit(" ", 1)[0] if " " in text[:n] else text[:n]
    return cut.rstrip(",.;:") + "…"


# Which other-side lines get the instant "❓" card (2026-10-22, same rule as Live Tips rules/triggers.yaml
# question_card). A bare "?" or "when" is not enough: songs and colleagues' small talk made most cards noise.
QCARD_STRONG = re.compile(
    r"естімейт|естимейт|оцінк|дедлайн|термін|статус|ціна|ціну|вартіст|бюджет|реліз|"
    r"оценк|срок|стоимост|estimate|\beta\b|deadline|status|price|cost|budget|release|"
    r"estimación|plazo|precio|presupuesto", re.I)
QCARD_WEAK = re.compile(r"скільки|коли|як довго|сколько|когда|how long|how much|how many|when|cuánto|cuándo", re.I)
QCARD_MUSIC = re.compile(r"[♪♫]|\[(музика|music|música)\]|\((музика|music|música)\)", re.I)


def question_item(text: str, t_hms: str, at_hms: str, names: list | None = None) -> dict | None:
    """The instant "❓" item for a `them` line that asks something work-related (the model tip replaces it).
    Shown when: the line names the PM and asks (cue or "?"); or it has a work word (estimate, deadline,
    status, price, release...); or it is a question ("?") about time or amount (when, how long, how much).
    A bare "?" (small talk, song lyrics) or a lone "when" without "?" gets no card."""
    text = text or ""
    if len(re.findall(r"\w+", text)) < 2 or QCARD_MUSIC.search(text):
        return None
    low = text.lower()
    named = any(n and re.search(r"(?<!\w)" + re.escape(n.lower()), low) for n in (names or []))
    asks = "?" in text or bool(QUESTION_CUE.search(text))
    if not ((named and asks) or QCARD_STRONG.search(text) or ("?" in text and QCARD_WEAK.search(text))):
        return None
    return {"t": t_hms, "src": t_hms, "at": at_hms, "kind": "question", "gist": "❓ " + short_gist(text, 60)}


def sos_pick(recent_texts: list[str], facts: list[dict], cards: list[dict], limit: int = 2,
             sem: dict | None = None) -> list[dict]:
    """Up to `limit` facts or cards that match the words of the last ~90 s of the call, best
    first, as red window items. No model involved: this is the instant reaction to the SOS button.
    `sem` (optional, from SemanticLive.sos_context): {"facts": {id: (cos, over_floor)},
    "cards": {id: (cos, over_floor)}, "min": .., "margin": .., "docs": [...]}. With it, entries close to
    the live topic qualify even without shared words, ranking is by cosine (+ a small keyword bonus)
    and up to 2 project index snippets are added; without it the keyword behaviour is unchanged."""
    joined = " ".join(recent_texts)
    words = set(tokens(joined))
    keys = set(re.findall(r"\b[A-Z][A-Z0-9]+-\d+\b", joined))
    low, plain = joined.lower(), " " + norm(joined) + " "
    scored: list[tuple[int, int, dict]] = []
    for i, f in enumerate(facts):
        ft = set(tokens(" ".join([_s(f.get("id")), _s(f.get("title")), " ".join(_strs(f.get("keywords")))])))
        score = sum(1 for w in words if any(tok_match(w, x) for x in ft))
        if _s(f.get("id")) in keys:
            score += 3
        sem_s = _sem_ok(sem, "facts", _s(f.get("id")) or _s(f.get("title")))
        if score >= 2 or sem_s is not None:
            items = [f"{_s(f.get('title'))}: {_s(f.get('text'))}".strip(": ")]
            item = {"kind": "fact", "level": "red", "gist": "🆘 " + (_s(f.get("title")) or _s(f.get("text"))[:60]),
                    "items": items, "note": _s(f.get("source"))}
            if sem_s is not None:
                item["sem"] = round(sem_s, 3)
            scored.append((_rank(score, sem_s, sem), -i, item))
    for i, c in enumerate(cards):
        if c.get("off"):
            continue
        ct = set(tokens(" ".join([_s(c.get("gist")), _s(c.get("phrase"))]
                                 + [t for t in _strs(c.get("triggers")) if not t.startswith("re:")])))
        score = sum(1 for w in words if any(tok_match(w, x) for x in ct))
        if any(Cards._hit(t, low, plain) for t in _strs(c.get("triggers"))):
            score += 3
        sem_s = _sem_ok(sem, "cards", Cards.cid(c))
        if score >= 2 or sem_s is not None:
            gist = re.sub(r"^\W+", "", _s(c.get("gist"))) or _s(c.get("id"))
            item = {"kind": "card", "level": "red", "gist": "🆘 " + gist, "card": _s(c.get("id"))}
            for k in ("phrase", "items", "note"):
                if c.get(k):
                    item[k] = c[k]
            if sem_s is not None:
                item["sem"] = round(sem_s, 3)
            scored.append((_rank(score, sem_s, sem), -i - 10000, item))
    scored.sort(key=lambda x: (-x[0], -x[1]))
    out = [x[2] for x in scored[:limit]]
    for d in ((sem or {}).get("docs") or [])[:2]:
        out.append(doc_item(d))
    for x in out:
        if not x.get("note"):
            x.pop("note", None)
    return out or [{"kind": "info", "gist": "🆘 Asking Claude..."}]


def _sem_ok(sem: dict | None, kind: str, key: str) -> float | None:
    """The cosine of an entry to the SOS query when it passes the SOS thresholds, else None."""
    if not sem:
        return None
    v = (sem.get(kind) or {}).get(key)
    if not v:
        return None
    cos, over = v
    if cos >= float(sem.get("min", 0.45)) and over >= float(sem.get("margin", 0.08)):
        return float(cos)
    return None


def _rank(kw: int, sem_s: float | None, sem: dict | None) -> float:
    """Keyword-only: the keyword score (as before). With semantics: cosine first, keywords as a bonus."""
    if sem is None:
        return float(kw)
    return (sem_s or 0.0) + 0.04 * min(kw, 5)


def doc_item(d: dict) -> dict:
    """A project index snippet as a red SOS item: file name and date in `note`."""
    rel = str(d.get("rel") or d.get("path") or "")
    title = SEM.doc_title(rel) if SEM else Path(rel).stem
    if d.get("heading"):
        title += " > " + str(d["heading"])
    date = SEM.hit_date(d) if SEM else ""
    return {"kind": "fact", "level": "red", "gist": "🆘 " + short_gist(title, 70), "items": [str(d.get("preview") or "")],
            "note": f"{Path(rel).name} · {date}".strip(" ·"), "doc": rel, "sem": round(float(d.get("score") or 0), 3)}


# --------------------------------------------------------------------------- Semantic layer (live)

def fact_sem_text(f: dict) -> str:
    kw = ", ".join(_strs(f.get("keywords")))
    return ". ".join(x for x in (_s(f.get("title")), _s(f.get("text")), kw) if x)


def card_sem_texts(c: dict) -> list[str]:
    """What a card is about: its gist plus each plain (non-regex) trigger of 2+ words."""
    gist = re.sub(r"^\W+", "", _s(c.get("gist")))
    trig = [t for t in _strs(c.get("triggers")) if not t.startswith("re:")]
    out = []
    if gist or trig:
        out.append(". ".join([gist] + trig[:6]).strip(". "))
    out += [t for t in trig if len(t.split()) >= 2][:8]
    return [x for x in out if x]


def word_count(text: str) -> int:
    return len(re.findall(r"\w+", text or ""))


class SemanticLive(threading.Thread):
    """Live semantic matching, in its own thread (never blocks ASR, the writer or the speaker worker).

    - Fact book entries (title + text + keywords) and card gists / triggers are embedded when the
      files load or change; vectors are cached in <stem>.semantic.npz by text hash.
    - Every new transcript line of 3+ words is queued (bounded, the oldest is dropped) and embedded
      with a 2 s timeout; a decayed mean of the last ~60 s of line vectors is the "live topic".
    - A `them` line close to a fact (cosine >= semantic_fact_min and above the fact's small-talk noise
      floor by semantic_margin) shows a 📌 fact when the line is a question or the topic held for
      2+ lines. Cards fire by meaning with semantic_card_min. Cooldowns are shared with the keyword
      path; nothing automatic while tips are paused. Every hit (and near miss) goes to
      <stem>.semantic.jsonl with its score, for tuning.
    - When Ollama or the model is missing: state "off" with the reason, re-probed every 30 s.
    - The window switch "Local AI (Ollama)" (setting `semantic`) turns it all off at once: no
      embedding call, no probe, no indexing until it is turned on again.
    - Accounting for the owner (is Ollama worth it?): one log line at start and on every on/off change,
      a compact line every 5 minutes, and at stop a summary line + <stem>.semantic-summary.json."""

    def __init__(self, cfg: dict, out: Path, tips: Path, facts: "FactBook", cards: "Cards", flags: dict, client):
        super().__init__(daemon=True)
        self.cfg, self.tips, self.facts, self.cards, self.flags, self.client = cfg, tips, facts, cards, flags, client
        self.log_path = out.with_name(out.stem + ".semantic.jsonl")
        self.npz = out.with_name(out.stem + ".semantic.npz")
        self.q: "collections.deque[tuple]" = collections.deque(maxlen=max(1, int(cfg.get("semantic_queue", 6))))
        self.ev = threading.Event()
        self.stop_ev = threading.Event()
        self.state, self.reason = "loading", None
        self.topic = SEM.LiveTopic(window=float(cfg.get("semantic_topic_s", 60)))
        self.vcache: dict | None = None
        self.A = None                        # neutral anchors
        self.fact_ref, self.fact_list, self.F, self.Ffloor = None, [], None, None
        self.card_ver, self.card_ids, self.card_on, self.C, self.C_owner, self.Cfloor = None, [], [], None, None, None
        self.hist: "collections.deque[tuple[float, int]]" = collections.deque()
        self.n_lines = self.dropped = self.hits = self.skipped = 0
        self.fail_streak = 0
        self.line_ms: "collections.deque[float]" = collections.deque(maxlen=100)
        self.next_probe = 0.0
        self.sync_lock = threading.Lock()
        self.enabled = True                  # the window switch
        self.index = None                    # read-only ProjectIndex (counts for the start line)
        self.started = time.time()
        self.ver: str | None = None
        # Accounting: totals and the current 5-minute window.
        self.tot = collections.Counter()
        self.win = collections.Counter()
        self.lat_all: list[float] = []
        self.lat_win: list[float] = []
        self.calls_win0 = 0
        self.win_t0 = time.time()
        self.hit_list: list[dict] = []
        self.feedback: dict[str, str] = {}
        self.acct_lock = threading.Lock()

    # ---- accounting
    def count(self, key: str, n: int = 1) -> None:
        with self.acct_lock:
            self.tot[key] += n
            self.win[key] += n

    def add_hit(self, kind: str, hid: str, score: float, gist: str, t: str, key: str, text: str = "") -> None:
        self.count("hits_" + kind)
        with self.acct_lock:
            self.hit_list.append({"t": t, "kind": kind, "id": hid, "score": round(float(score), 4), "gist": gist,
                                  "key": key, "text": text[:300]})

    def note_feedback(self, value) -> None:
        """tip_feedback from the window ('verdict|card|t|gist...'): kept to rate semantic hits."""
        v = str(value or "")
        verdict, sep, rest = v.partition("|")
        if not sep:
            return
        for marker in ("|c=", "|r="):
            i = rest.rfind(marker)
            if i >= 0:
                rest = rest[:i]
        self.feedback[rest] = verdict

    @staticmethod
    def _pct(vals: list[float], q: float) -> int | None:
        if not vals:
            return None
        v = sorted(vals)
        return round(v[min(len(v) - 1, int(q * len(v)))])

    def _window_line(self) -> None:
        with self.acct_lock:
            w, lat = dict(self.win), list(self.lat_win)
            calls = self.client.calls - self.calls_win0
            self.win.clear()
            self.lat_win = []
            self.calls_win0 = self.client.calls
            self.win_t0 = time.time()
        log(f"semantic 5m: {self.state}, embed calls {calls}, latency median {self._pct(lat, 0.5)} ms p90 {self._pct(lat, 0.9)} ms, "
            f"hits facts {w.get('hits_fact', 0)} cards {w.get('hits_card', 0)} sos {w.get('hits_sos', 0)}, "
            f"near misses {w.get('near', 0)}, timeouts {w.get('timeouts', 0)}, queue drops {w.get('dropped', 0)}, "
            f"index +{w.get('index_chunks', 0)} chunks")

    def _start_line(self) -> None:
        f_n, c_n = self.index.counts() if self.index is not None else (None, None)
        if self.ver is None:
            self.ver = self.client.version() or "?"
        log(f"semantic: on, model {self.client.model}, ollama {self.ver}, facts {len(self.facts.facts)}, "
            f"cards {len(self.card_ids)}, index files {f_n} chunks {c_n}")

    def set_enabled(self, on: bool) -> None:
        """The window switch. Off: stop at once (queue cleared, no probes, the index thread pauses)."""
        if on == self.enabled:
            return
        self.enabled = on
        if on:
            self.state, self.reason, self.next_probe = "loading", None, 0.0
            log("semantic: switched on in the window")
        else:
            self.q.clear()
            self.state, self.reason = "off", "turned off in the window"
            self.count("off_events")
            log("semantic: off: turned off in the window (no Ollama use until it is turned on)")
        self.ev.set()

    def f(self, key: str) -> float:
        try:
            return float(self.cfg.get(key, DEFAULTS.get(key)))
        except (TypeError, ValueError):
            return float(DEFAULTS[key])

    # ---- intake (called from the ASR worker: O(1), never blocks)
    def submit(self, line: "Line", is_question: bool) -> None:
        if self.state != "on":
            return
        if word_count(line.text) < int(self.f("semantic_min_words")):
            self.skipped += 1
            return
        if len(self.q) == self.q.maxlen:
            self.dropped += 1
            self.count("dropped")
        self.q.append((line, bool(is_question)))
        self.ev.set()

    def stop(self) -> None:
        self.stop_ev.set()
        self.ev.set()

    # ---- thread
    def run(self) -> None:
        while not self.stop_ev.is_set():
            if time.time() - self.win_t0 >= 300:
                self._window_line()
            if not self.enabled:
                self.ev.wait(1.0)
                self.ev.clear()
                continue
            if self.state != "on":
                if time.time() >= self.next_probe:
                    ok, reason = self.client.health(force=True)
                    if not self.enabled:
                        continue
                    if ok:
                        try:
                            self._sync()
                            self.state, self.reason, self.fail_streak = "on", None, 0
                            self._start_line()
                        except SEM.SemanticError as e:
                            self._down(e.reason)
                    else:
                        self._down(reason, quiet=self.reason == reason)
                self.ev.wait(1.0)
                self.ev.clear()
                continue
            self.ev.wait(1.0)
            self.ev.clear()
            try:
                self._sync()
            except SEM.SemanticError as e:
                self._down(e.reason)
                continue
            except Exception as e:  # noqa: BLE001
                log(f"semantic: sync failed ({e!r})")
            while self.q and self.state == "on" and not self.stop_ev.is_set():
                try:
                    line, is_q = self.q.popleft()
                except IndexError:
                    break
                try:
                    self._process(line, is_q)
                    self.fail_streak = 0
                except SEM.SemanticError as e:
                    self.fail_streak += 1
                    if "timeout" in e.reason:
                        self.count("timeouts")
                    else:
                        self.count("errors")
                    self._log({"kind": "error", "t": hhmmss(line.t), "why": e.reason})
                    if self.fail_streak >= 3:
                        self._down(e.reason)
                except Exception as e:  # noqa: BLE001
                    log(f"semantic: {e!r}")

    def _down(self, reason: str, quiet: bool = False) -> None:
        was = self.state
        self.state, self.reason = "off", reason
        self.client.mark_down(reason)
        self.q.clear()
        self.next_probe = time.time() + 30
        if was == "on":
            self.count("off_events")
        if not quiet or was == "on":
            log(f"semantic: off: {reason} (keyword tips work as before, retry in 30 s)")

    # ---- vectors
    def _vecs(self, texts: list[str], timeout: float = 60.0) -> np.ndarray:
        model = self.client.model
        if self.vcache is None:
            self.vcache = SEM.load_vec_cache(self.npz, model)
        keys = [SEM.text_hash(t, model) for t in texts]
        missing = [i for i, k in enumerate(keys) if k not in self.vcache]
        if missing:
            v = self.client.embed([texts[i] for i in missing], timeout=timeout, use_cache=False)
            for i, row in zip(missing, v):
                self.vcache[keys[i]] = row
            SEM.save_vec_cache(self.npz, model, self.vcache)
        return np.stack([self.vcache[k] for k in keys]).astype(np.float32) if keys else None

    def _sync(self) -> None:
        """Embed the fact book and the cards when they change (cheap when nothing changed)."""
        with self.sync_lock:
            if self.A is None:
                self.A = self._vecs(SEM.NEUTRAL_ANCHORS)
            lst = self.facts.facts
            if lst is not self.fact_ref:
                if lst:
                    F = self._vecs([fact_sem_text(x) for x in lst])
                    self.F, self.Ffloor = F, (F @ self.A.T).max(1)
                else:
                    self.F = self.Ffloor = None
                self.fact_ref, self.fact_list = lst, list(lst)
                self.hist.clear()
            snap = self.cards.snapshot()
            ver = (self.cards.mtime, len(snap))
            if ver != self.card_ver:
                ids, ons, texts, owner = [], [], [], []
                for c in snap:
                    if c.get("off"):
                        continue
                    tx = card_sem_texts(c)
                    if not tx:
                        continue
                    k = len(ids)
                    ids.append(Cards.cid(c))
                    ons.append(c.get("on", "any"))
                    texts += tx
                    owner += [k] * len(tx)
                if texts:
                    C = self._vecs(texts)
                    owner_a = np.array(owner)
                    floor = (C @ self.A.T).max(1)
                    self.Cfloor = np.array([floor[owner_a == k].max() for k in range(len(ids))], dtype=np.float32)
                    self.C, self.C_owner = C, owner_a
                else:
                    self.C = self.C_owner = self.Cfloor = None
                self.card_ids, self.card_on, self.card_ver = ids, ons, ver

    # ---- matching
    def _log(self, obj: dict) -> None:
        _append_json(self.log_path, obj | {"at": hhmmss(now())})

    def _process(self, line: "Line", is_q: bool) -> None:
        if not self.enabled:
            return
        t0 = time.time()
        v = self.client.embed([line.text], timeout=self.f("semantic_timeout_s"))[0]
        self.topic.add(line.t, v)
        self.n_lines += 1
        self.count("lines")
        if self.F is not None and len(self.fact_list):
            self._match_facts(line, is_q, v)
        if self.C is not None and len(self.card_ids):
            self._match_cards(line, v)
        ms = 1000 * (time.time() - t0)
        self.line_ms.append(ms)
        with self.acct_lock:
            self.lat_all.append(ms)
            self.lat_win.append(ms)

    def _match_facts(self, line: "Line", is_q: bool, v) -> None:
        s = self.F @ v
        over = s - self.Ffloor
        fmin, margin = self.f("semantic_fact_min"), self.f("semantic_margin")
        win = self.f("semantic_topic_s")
        for i in np.nonzero((s >= fmin - 0.05) & (over >= 0.75 * margin))[0]:
            self.hist.append((line.t, int(i)))
        while self.hist and line.t - self.hist[0][0] > win:
            self.hist.popleft()
        if line.channel != "them":
            return
        order = [int(i) for i in np.argsort(-s)[:4]]
        cands = [i for i in order if s[i] >= fmin and over[i] >= margin][:2]
        if not cands:
            b = order[0]
            if s[b] >= fmin - 0.1 or over[b] >= 0.75 * margin:
                self.count("near")
                self._log({"kind": "fact", "t": hhmmss(line.t), "id": _s(self.fact_list[b].get("id")),
                           "score": round(float(s[b]), 4), "over": round(float(over[b]), 4), "shown": False,
                           "why": "below threshold", "line": line.text[:160]})
            return
        shown = []
        for i in cands:
            f = self.fact_list[i]
            fid = str(f.get("id") or f.get("title"))
            held = sum(1 for _, j in self.hist if j == i) >= 2
            why = None
            if not (is_q or held):
                why = "not a question, topic not held"
            elif self.flags.get("tips_paused"):
                why = "tips paused"
            elif not self.facts.claim(fid):
                why = "cooldown (or keyword hit)"
            self._log({"kind": "fact", "t": hhmmss(line.t), "id": fid, "score": round(float(s[i]), 4),
                       "over": round(float(over[i]), 4), "question": is_q, "held": held, "shown": why is None,
                       "why": why, "line": line.text[:160]})
            if why is None:
                shown.append((f, float(s[i])))
        if not shown:
            return
        self.hits += 1
        items = [f"{f.get('title', '')}: {f.get('text', '')}".strip(": ") for f, _ in shown]
        gist = "📌 " + shown[0][0].get("title", "")
        self.add_hit("fact", str(shown[0][0].get("id") or ""), shown[0][1], gist, hhmmss(line.t),
                     "|" + hhmmss(line.t) + "|" + gist[:60], fact_sem_text(shown[0][0]))
        _append_json(self.tips, {"t": hhmmss(line.t), "src": hhmmss(line.t), "at": hhmmss(now()),
                                 "kind": "fact", "level": "orange", "gist": gist,
                                 "items": items, "sem": round(shown[0][1], 3),
                                 "note": " · ".join(str(f.get("source", "")) for f, _ in shown if f.get("source"))})

    def _match_cards(self, line: "Line", v) -> None:
        raw = self.C @ v
        cmin, margin = self.f("semantic_card_min"), self.f("semantic_card_margin")
        best = np.full(len(self.card_ids), -1.0, dtype=np.float32)
        np.maximum.at(best, self.C_owner, raw)
        over = best - self.Cfloor
        for k in np.argsort(-best)[:3]:
            k = int(k)
            on = self.card_on[k]
            if on != "any" and on != line.channel:
                continue
            if best[k] < cmin - 0.1 and over[k] < 0.75 * margin:
                break
            cid = self.card_ids[k]
            rec = {"kind": "card", "t": hhmmss(line.t), "id": cid, "score": round(float(best[k]), 4),
                   "over": round(float(over[k]), 4), "ch": line.channel, "line": line.text[:160]}
            if best[k] < cmin or over[k] < margin:
                self.count("near")
                self._log(rec | {"shown": False, "why": "below threshold"})
                continue
            if self.flags.get("tips_paused"):
                why = "tips paused"
            else:
                why = self.cards.fire_semantic(cid, line, float(best[k]))
            self._log(rec | {"shown": why is None, "why": why})
            if why is None:
                self.hits += 1
                c = next((x for x in self.cards.snapshot() if Cards.cid(x) == cid), {})
                gist = _s(c.get("gist"))
                self.add_hit("card", cid, float(best[k]), gist, hhmmss(line.t), f"{cid}|{hhmmss(line.t)}|{gist[:60]}",
                             " ".join(card_sem_texts(c)))

    # ---- SOS
    def sos_context(self, texts: list[str], index=None) -> dict | None:
        """Semantic scores of facts and cards against the live topic + the last 90 s text, and the
        best project index snippets. None when the layer is off (the caller uses keywords)."""
        if self.state != "on":
            return None
        try:
            self._sync()
            qs = []
            tv = self.topic.vector()
            if tv is not None:
                qs.append(tv)
            joined = " ".join(texts)[-2000:]
            if joined.strip():
                qs.append(self.client.embed([joined], timeout=self.f("semantic_timeout_s"))[0])
        except SEM.SemanticError as e:
            self._log({"kind": "sos", "why": e.reason})
            return None
        if not qs:
            return None
        q = SEM.l2norm(np.sum(qs, axis=0))
        out = {"facts": {}, "cards": {}, "docs": [], "min": self.f("semantic_sos_min"),
               "margin": 0.5 * self.f("semantic_margin")}      # SOS is an explicit ask: a lower bar, ranked by cosine
        if self.F is not None and len(self.fact_list):
            s = self.F @ q
            for f, a, b in zip(self.fact_list, s, s - self.Ffloor):
                out["facts"][_s(f.get("id")) or _s(f.get("title"))] = (float(a), float(b))
        if self.C is not None and len(self.card_ids):
            raw = self.C @ q
            best = np.full(len(self.card_ids), -1.0, dtype=np.float32)
            np.maximum.at(best, self.C_owner, raw)
            for cid, a, b in zip(self.card_ids, best, best - self.Cfloor):
                out["cards"][cid] = (float(a), float(b))
        if index is not None:
            try:
                if index.load() and index.manifest.get("model") == self.client.model:
                    out["docs"] = index.search_vec(q, 2, min_score=self.f("semantic_index_min"))
            except Exception as e:  # noqa: BLE001
                log(f"semantic: index search failed ({e!r})")
        best_f = sorted(out["facts"].items(), key=lambda x: -x[1][0])[:3]
        self._log({"kind": "sos", "facts": [[k, round(a, 4), round(b, 4)] for k, (a, b) in best_f],
                   "docs": [[d.get("rel"), d.get("score")] for d in out["docs"]]})
        return out

    def status_fields(self) -> dict:
        ms = sorted(self.line_ms)
        st = self.client.stats()
        return {"semantic": self.state, "semantic_reason": self.reason, "semantic_switch": "on" if self.enabled else "off",
                "semantic_stats": {"lines": self.n_lines, "hits": self.hits, "dropped": self.dropped,
                                   "line_ms_p50": round(ms[len(ms) // 2]) if ms else None,
                                   "calls": st["calls"], "errors": st["errors"]}}

    # ---- stop summary
    def summary(self, out: Path, tips_file: Path, them_label: str = "") -> dict:
        """<stem>.semantic-summary.json + one log line: totals, latency, every hit with its PM rating
        and whether a model tip on the same topic followed (or the hit was the only answer)."""
        with self.acct_lock:
            tot, lat, hits = dict(self.tot), list(self.lat_all), [dict(h) for h in self.hit_list]
        fb = dict(self.feedback)
        for r in _read_jsonl(out.with_name(out.stem + ".feedback.jsonl")):
            v = str(r.get("value") or "")
            verdict, sep, rest = v.partition("|")
            if sep:
                for marker in ("|c=", "|r="):
                    i = rest.rfind(marker)
                    if i >= 0:
                        rest = rest[:i]
                fb[rest] = verdict
        tips = [x for x in _read_jsonl(tips_file) if x.get("kind") in ("tip", "answer")]
        model_tips = []
        for x in tips:
            txt = " ".join(str(x.get(k) or "") for k in ("gist", "phrase", "note"))
            if isinstance(x.get("items"), list):
                txt += " " + " ".join(map(str, x["items"]))
            model_tips.append((_secs(x.get("src") or x.get("t")), txt))
        # Same topic: cosine with the hit's entry text (when Ollama still answers), else shared words.
        use_vec = self.state == "on"
        rated = collections.Counter()
        followed = collections.Counter()
        for h in hits:
            h["rating"] = fb.get(h["key"])
            if h["rating"]:
                rated[h["rating"]] += 1
            if h["kind"] == "sos":
                h["followed"] = None
                continue
            t0 = _secs(h["t"])
            near = [txt for ts, txt in model_tips if t0 is not None and ts is not None and -5 <= ts - t0 <= 90]
            if not near:
                h["followed"] = "only_answer"
            else:
                same = False
                if use_vec:
                    try:
                        v = self.client.embed([h["text"] or h["gist"]] + near, timeout=self.f("semantic_timeout_s"))
                        same = bool((v[1:] @ v[0]).max() >= self.f("semantic_fact_min") - 0.05)
                    except SEM.SemanticError:
                        use_vec = False
                if not use_vec:
                    hw = set(tokens(h["text"] or h["gist"]))
                    same = any(sum(1 for w in set(tokens(x)) if any(tok_match(w, y) for y in hw)) >= 2 for x in near)
                h["followed"] = "same_topic" if same else "other_topic"
            followed[h["followed"]] += 1
            h.pop("text", None)
        for h in hits:
            h.pop("text", None)
        mem = None
        if self.enabled and self.state == "on":
            try:
                mem = self.client.model_memory()
            except Exception:  # noqa: BLE001
                mem = None
        st = self.client.stats()
        res = {
            "model": self.client.model, "ollama_version": self.ver, "state_final": self.state,
            "switch": "on" if self.enabled else "off", "reason_final": self.reason,
            "minutes": round((time.time() - self.started) / 60, 1),
            "totals": {"lines_embedded": tot.get("lines", 0), "embed_calls": st["calls"], "texts_embedded": st["texts"],
                       "errors": tot.get("errors", 0), "timeouts": tot.get("timeouts", 0), "queue_drops": tot.get("dropped", 0),
                       "near_misses": tot.get("near", 0), "index_chunks_added": tot.get("index_chunks", 0),
                       "off_events": tot.get("off_events", 0)},
            "latency_ms": {"n": len(lat), "median": self._pct(lat, 0.5), "p90": self._pct(lat, 0.9),
                           "max": round(max(lat)) if lat else None},
            "hits": {"facts": tot.get("hits_fact", 0), "cards": tot.get("hits_card", 0), "sos": tot.get("hits_sos", 0),
                     "total": len(hits), "list": hits},
            "rated": {"rated": sum(rated.values()), "used": rated.get("used", 0), "partly": rated.get("partly", 0),
                      "not_useful": rated.get("not_useful", 0)},
            "followed": {"same_topic": followed.get("same_topic", 0), "other_topic": followed.get("other_topic", 0),
                         "only_answer": followed.get("only_answer", 0)},
            "ollama_memory": mem,
        }
        write_json_atomic(out.with_name(out.stem + ".semantic-summary.json"), res)
        ram = f", Ollama model RAM {mem['size_mb']} MB" if mem else ""
        log(f"semantic summary: {res['minutes']} min, {res['totals']['lines_embedded']} lines, {st['calls']} embed calls, "
            f"latency median {res['latency_ms']['median']} ms p90 {res['latency_ms']['p90']} ms, hits {len(hits)} "
            f"(facts {res['hits']['facts']}, cards {res['hits']['cards']}, sos {res['hits']['sos']}), rated used "
            f"{res['rated']['used']} partly {res['rated']['partly']} not useful {res['rated']['not_useful']}, "
            f"followed by a tip on the same topic {res['followed']['same_topic']}, only answer {res['followed']['only_answer']}{ram}")
        return res


def _read_jsonl(path: Path) -> list[dict]:
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for ln in f:
                try:
                    d = json.loads(ln)
                except Exception:  # noqa: BLE001
                    continue
                if isinstance(d, dict):
                    out.append(d)
    except OSError:
        pass
    return out


def _secs(hms) -> int | None:
    m = re.match(r"^(\d{1,2}):(\d{2}):(\d{2})", str(hms or ""))
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) if m else None


# --------------------------------------------------------------------------- Mic watchdog decision

def mic_watchdog(*, now_t: float, alive: bool, switching: bool, stalled: bool, muted: bool,
                 started_at: float, last_feed: float | None, last_nonzero: float | None, unmuted_at: float,
                 last_restart: float, streak: int, fed_s: float, device: str, auto_switched: bool,
                 stall_s: float = 12.0, zero_s: float = 10.0) -> tuple[str | None, float, float]:
    """Pure decision for the mic watchdog. Returns (action, silent_s, zero_for_s) where action is
    None | "restart" | "switch_builtin" | "recovered".
    - silent_s: no chunk from audiocap at all (counted from the process start as a grace period);
    - zero_for_s: chunks arrive but every sample is exactly 0 (digital silence), not muted;
    - retries back off 20, 20, 30, 45, 60, 60 ... s and never stop;
    - after 2 failed restarts in a row the mic moves to the Mac's built-in microphone once;
    - recovery needs audio that arrived after the last restart (>= 2 s of it), so a fresh
      process start alone is not taken for a recovery."""
    start = started_at or now_t
    silent_s = now_t - max(last_feed or 0.0, start)
    zero_for = 0.0 if muted else now_t - max(last_nonzero or 0.0, start, unmuted_at or 0.0)
    stuck = silent_s > stall_s or zero_for > zero_s
    retry_s = min(60.0, 20 * 1.5 ** max(0, streak - 2)) if streak > 1 else 20.0
    if alive and not switching and not stalled and stuck and now_t - last_restart > retry_s:
        if streak >= 2 and device != "builtin" and not auto_switched:
            return "switch_builtin", silent_s, zero_for
        return "restart", silent_s, zero_for
    if (streak and not stuck and silent_s < 2 and last_feed is not None and last_feed > last_restart
            and fed_s >= 2 and (muted or (last_nonzero is not None and last_nonzero > last_restart))):
        return "recovered", silent_s, zero_for
    return None, silent_s, zero_for


# --------------------------------------------------------------------------- Speaker identification (v37)
# The system channel mixes everybody on the other side. Every `them` segment with >= 1 s of speech
# gets a voice embedding (sherpa-onnx, wespeaker ResNet34, 256 floats) in a worker thread; an
# online clustering per call turns them into speakers S1, S2, ... The PM names them in the window;
# names go to a local voice library (<tool root>/voices/voices.json) that later only SUGGESTS names.

SPEAKER_MODEL_URL = ("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/"
                     "wespeaker_en_voxceleb_resnet34_LM.onnx")
SID_RX = re.compile(r"^S(\d+)$")
TAGGED_LINE = re.compile(r"^\[(\d\d:\d\d:\d\d)\] (.+?) \[(S\d+)\] \((\w+)\): ")
PLAIN_LINE = re.compile(r"^\[(\d\d:\d\d:\d\d)\] (.+?) \((\w+)\): ")


def unit(v) -> np.ndarray:
    v = np.asarray(v, dtype=np.float32).ravel()
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


def cosine(a, b) -> float:
    return float(np.dot(unit(a), unit(b)))


def _pb_varint(n: int) -> bytes:
    out = b""
    while True:
        x, n = n & 0x7F, n >> 7
        if n:
            out += bytes([x | 0x80])
        else:
            return out + bytes([x])


def _pb_bytes_field(num: int, data: bytes) -> bytes:
    return _pb_varint((num << 3) | 2) + _pb_varint(len(data)) + data


CMN_META = _pb_bytes_field(14, _pb_bytes_field(1, b"feature_normalize_type") + _pb_bytes_field(2, b"global-mean"))


def cmn_model_path(model: Path, fallback_dir: Path | None = None) -> Path:
    """sherpa-onnx subtracts the per-utterance feature mean (CMN) only when the model metadata
    says feature_normalize_type=global-mean. The published wespeaker export lacks that key; without
    CMN the embedding follows loudness and two different people score 0.6-0.9 (measured on real
    speech), so no threshold separates them. ONNX is protobuf: appending one metadata_props entry
    (field 14) to the file adds the key without any extra package. The downloaded model is patched
    in place (atomic replace, once); a symlinked or read-only model gets a <stem>.cmn.onnx copy."""
    data = model.read_bytes()
    if b"feature_normalize_type" in data:
        return model
    if not model.is_symlink():
        try:
            tmp = model.with_name(model.name + f".{os.getpid()}.tmp")
            tmp.write_bytes(data + CMN_META)
            os.replace(tmp, model)
            log(f"speakers: {model.name} patched for per-utterance mean normalisation")
            return model
        except OSError:
            pass
    for d in (model.parent, fallback_dir):
        if d is None:
            continue
        target = d / (model.stem + ".cmn.onnx")
        try:
            if target.exists() and target.stat().st_size == len(data) + len(CMN_META):
                return target
            d.mkdir(parents=True, exist_ok=True)
            tmp = target.with_name(target.name + f".{os.getpid()}.tmp")
            tmp.write_bytes(data + CMN_META)
            os.replace(tmp, target)
            return target
        except OSError:
            continue
    raise OSError(f"cannot write {model.stem}.cmn.onnx next to the model")


class SpeakerEmbedder:
    """sherpa-onnx speaker embedding extractor; embed() returns a unit vector."""

    MAX_S = 10.0   # longer segments: the middle 10 s is enough and keeps the worker fast

    def __init__(self, model: Path, threads: int = 1):
        import sherpa_onnx  # type: ignore
        self.path = cmn_model_path(model, STATE)
        conf = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(self.path), num_threads=threads)
        if not conf.validate():
            raise RuntimeError(f"invalid speaker model {self.path}")
        self.ex = sherpa_onnx.SpeakerEmbeddingExtractor(conf)
        self.dim = int(self.ex.dim)
        self.lock = threading.Lock()

    def embed(self, audio: np.ndarray) -> np.ndarray:
        audio = np.asarray(audio, dtype=np.float32)
        n = int(self.MAX_S * SR)
        if len(audio) > n:
            k = (len(audio) - n) // 2
            audio = audio[k:k + n]
        with self.lock:
            s = self.ex.create_stream()
            s.accept_waveform(SR, audio)
            s.input_finished()
            return unit(self.ex.compute(s))


def speaker_model_path(cfg: dict) -> Path:
    p = Path(os.path.expanduser(str(cfg.get("speaker_model") or DEFAULTS["speaker_model"])))
    return p if p.is_absolute() else ROOT / p


def load_embedder(cfg: dict) -> tuple["SpeakerEmbedder | None", str]:
    """(embedder, "") or (None, reason). Never raises: speakers are optional."""
    if cfg.get("speakers_enabled", True) in (False, "false", "off", "0", 0):
        return None, "disabled in config.json (speakers_enabled)"
    try:
        import sherpa_onnx  # type: ignore  # noqa: F401
    except Exception as e:  # noqa: BLE001
        return None, f"sherpa-onnx not installed ({type(e).__name__}); run bin/install-voices.sh"
    model = speaker_model_path(cfg)
    if not model.exists():
        return None, f"model missing: {model} ; run bin/install-voices.sh"
    try:
        return SpeakerEmbedder(model), ""
    except Exception as e:  # noqa: BLE001
        return None, f"speaker model failed to load ({e!r})"


class EmbedJob:
    def __init__(self, audio: np.ndarray):
        self.audio = audio
        self.done = threading.Event()
        self.result: np.ndarray | None = None

    def wait(self, timeout: float) -> np.ndarray | None:
        self.done.wait(timeout)
        return self.result


class EmbedWorker(threading.Thread):
    """One thread computes embeddings. The queue is bounded: when the worker is behind, the
    oldest job is dropped (its line simply gets no new embedding). submit() never blocks."""

    def __init__(self, embed_fn, maxlen: int = 8):
        super().__init__(daemon=True)
        self.embed_fn = embed_fn
        self.maxlen = max(1, int(maxlen))
        self.q: list[EmbedJob] = []
        self.cond = threading.Condition()
        self.stopped = False
        self.dropped = 0
        self.done_n = 0
        self.ms: list[float] = []
        self.err_logged = False

    def submit(self, audio: np.ndarray) -> EmbedJob:
        job = EmbedJob(audio)
        with self.cond:
            while len(self.q) >= self.maxlen:
                old = self.q.pop(0)
                old.done.set()
                self.dropped += 1
            self.q.append(job)
            self.cond.notify()
        return job

    def run(self) -> None:
        while True:
            with self.cond:
                while not self.q and not self.stopped:
                    self.cond.wait(0.5)
                if not self.q:
                    return
                job = self.q.pop(0)
            t0 = time.time()
            try:
                job.result = self.embed_fn(job.audio)
                self.done_n += 1
                self.ms = (self.ms + [1000 * (time.time() - t0)])[-20:]
            except Exception as e:  # noqa: BLE001
                if not self.err_logged:
                    self.err_logged = True
                    log(f"speakers: embedding failed ({e!r})")
            finally:
                job.done.set()

    def stop(self) -> None:
        with self.cond:
            self.stopped = True
            self.cond.notify_all()


def prune_embeddings(embs: list, max_n: int = 20) -> list:
    """Keep at most max_n embeddings, oldest first in the list. While over the limit, drop the
    older one of the most similar pair: the newest voices stay, and near-duplicates go first."""
    embs = list(embs)
    while len(embs) > max_n:
        m = np.array([unit(e) for e in embs])
        s = m @ m.T
        np.fill_diagonal(s, -9.0)
        i, j = np.unravel_index(int(np.argmax(s)), s.shape)
        del embs[min(i, j)]
    return embs


def _round_emb(v) -> list:
    return [round(float(x), 4) for x in unit(v)]


class VoiceLibrary:
    """<tool root>/voices/voices.json: {"people": {"Name": {"embeddings": [[...]], "updated": iso,
    "calls": n}}}. Local only. Used for suggestions; a name is never assigned automatically."""

    MAX = 20

    def __init__(self, path: Path):
        self.path = path
        self.people: dict[str, dict] = {}
        self.cents: dict[str, np.ndarray] = {}
        self.broken = False
        self.load()

    def load(self) -> None:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return
        except Exception as e:  # noqa: BLE001
            self.broken = True
            log(f"voices: cannot read {self.path} ({e!r}); a fresh library is started, the old file is kept")
            return
        people = data.get("people") if isinstance(data, dict) else None
        for name, p in (people or {}).items():
            if not isinstance(p, dict):
                continue
            embs = [e for e in (p.get("embeddings") or []) if isinstance(e, list) and len(e) > 8]
            try:
                calls = int(p.get("calls") or 0)
            except (TypeError, ValueError):
                calls = 0
            if embs:
                self.people[str(name)] = {"embeddings": embs, "updated": p.get("updated"), "calls": calls}
        self._cents()

    def _cents(self) -> None:
        self.cents = {}
        for name, p in self.people.items():
            try:
                self.cents[name] = unit(np.mean([unit(e) for e in p["embeddings"]], axis=0))
            except Exception:  # noqa: BLE001  (mixed dimensions: skip that person)
                pass

    def suggest(self, vec, min_score: float, limit: int = 3) -> list[dict]:
        if vec is None:
            return []
        v = unit(vec)
        out = []
        for name, c in self.cents.items():
            if len(c) != len(v):
                continue
            sc = float(np.dot(v, c))
            if sc >= min_score:
                out.append({"name": name, "score": round(sc, 2)})
        out.sort(key=lambda x: -x["score"])
        return out[:limit]

    def frequent(self, n: int = 6) -> list[str]:
        return [k for k, _ in sorted(self.people.items(), key=lambda kv: (-int(kv[1].get("calls") or 0), kv[0]))][:n]

    def apply_call(self, prev: dict, desired: dict) -> None:
        """Replace this call's earlier contribution (prev: name -> embeddings) with `desired`.
        A rename moves the call's embeddings from the old name to the new one."""
        stamp = dt.datetime.now().astimezone().isoformat(timespec="seconds")
        for name in set(prev) | set(desired):
            p = self.people.get(name) or {"embeddings": [], "calls": 0, "updated": stamp}
            before = prev.get(name) or []
            kept = [e for e in p["embeddings"] if e not in before]
            new = kept + [[float(x) for x in e] for e in (desired.get(name) or [])]
            calls = int(p.get("calls") or 0)
            if name in desired and name not in prev:
                calls += 1
            elif name in prev and name not in desired:
                calls = max(0, calls - 1)
            if not new:
                self.people.pop(name, None)
                continue
            self.people[name] = {"embeddings": prune_embeddings(new, self.MAX), "updated": stamp, "calls": calls}
        self._cents()

    def save(self) -> None:
        if self.broken and self.path.exists():
            try:   # never overwrite a library we could not read
                os.replace(self.path, self.path.with_name(self.path.name + f".broken-{int(time.time())}"))
            except OSError:
                pass
            self.broken = False
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(self.path.name + f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps({"people": self.people}, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, self.path)


NAME_MAX = 80


def clean_name(name, what: str = "name") -> str | None:
    """A person's display name: whitespace trimmed and collapsed, any script, spaces, apostrophes
    and quotes kept. Empty or longer than NAME_MAX -> None (logged)."""
    n = re.sub(r"\s+", " ", _s(name)).strip()
    if not n:
        log(f"speakers: empty {what} ignored")
        return None
    if len(n) > NAME_MAX:
        log(f"speakers: {what} longer than {NAME_MAX} chars ignored ({n[:40]}...)")
        return None
    return n


def clean_people(people) -> list[str]:
    """start.json `people`: full names of the team and the client roster (list, or a string
    separated by commas / new lines). Cleaned, deduplicated case-insensitively, order kept."""
    if isinstance(people, str):
        people = re.split(r"[,\n;]", people)
    out, seen = [], set()
    for p in people if isinstance(people, (list, tuple)) else []:
        n = clean_name(p, "people entry") if _s(p) else None
        if n and n.casefold() not in seen:
            seen.add(n.casefold())
            out.append(n)
    return out


def normalize_person(name: str, people: list[str]) -> str:
    """A typed name matching a `people` entry case-insensitively, or by a first name that only
    one entry has, becomes that full name. Anything else is kept as typed."""
    low = name.casefold()
    for p in people:
        if p.casefold() == low:
            return p
    if " " not in name:
        hits = [p for p in people if p.split(" ", 1)[0].casefold() == low]
        if len(hits) == 1:
            return hits[0]
    return name


def speaker_display(sid: str | None, name: str | None) -> str | None:
    if name:
        return name
    m = SID_RX.match(sid or "")
    return f"Speaker {m.group(1)}" if m else None


def apply_speaker_names(text: str, them_label: str, label_for) -> str:
    """Replace `{them_label} [S2]` (and untagged system lines with an override) by the display
    name from label_for(line_time, sid) -> str | None. Other lines stay as they are."""
    out = []
    for ln in text.splitlines(keepends=True):
        m = TAGGED_LINE.match(ln)
        if m:
            lab = label_for(m.group(1), m.group(3))
            if lab:
                ln = f"[{m.group(1)}] {lab} ({m.group(4)}): " + ln[m.end():]
        else:
            m = PLAIN_LINE.match(ln)
            if m and m.group(2) == them_label:
                lab = label_for(m.group(1), None)
                if lab:
                    ln = f"[{m.group(1)}] {lab} ({m.group(3)}): " + ln[m.end():]
        out.append(ln)
    return "".join(out)


class SpeakerTracker:
    """Online speaker clustering for one call plus naming, merges, fixes, the "Who is speaking?"
    asks and the voice library. Thread-safe (ASR thread observes, main thread applies settings).
    Writes <stem>.speakers.json on every change."""

    def __init__(self, cfg: dict, path: Path, library: VoiceLibrary | None = None, emit=None):
        self.cfg = cfg
        self.path = path
        self.lib = library
        self.emit = emit or (lambda item: None)
        self.lock = threading.RLock()
        self.clusters: dict[str, dict] = {}
        self.merged: dict[str, str] = {}
        self.overrides: dict[str, str] = {}
        self.skipped: set[str] = set()
        self.asked: set[str] = set()
        self.segs: dict[str, dict] = {}       # line time -> {"sid", "emb", "dur"}
        self.next_n = 1
        self.rev = 0
        self.ask_open: str | None = None
        self.ask_queue: list[str] = []
        self.paused = False
        self.now_info: dict | None = None
        self.last_sid: str | None = None
        self.last_end = 0.0
        self.lib_added: dict[str, list] = {}
        self.people: list[str] = clean_people(cfg.get("people") or [])

    def _f(self, key: str) -> float:
        try:
            return float(self.cfg.get(key, DEFAULTS[key]))
        except (TypeError, ValueError):
            return float(DEFAULTS[key])

    # ---- basics
    def resolve(self, sid: str | None) -> str | None:
        seen = set()
        while sid in self.merged and sid not in seen:
            seen.add(sid)
            sid = self.merged[sid]
        return sid

    def _new_cluster(self, name: str | None = None) -> str:
        sid = f"S{self.next_n}"
        self.next_n += 1
        self.clusters[sid] = {"name": name, "members": [], "centroid": None, "seconds": 0.0,
                              "first": None, "quotes": [], "suggestions": []}
        self.rev += 1
        return sid

    def _recompute(self, sid: str) -> None:
        c = self.clusters[sid]
        embs = [m["emb"] for m in c["members"] if m["emb"] is not None]
        c["centroid"] = unit(np.mean(embs, axis=0)) if embs else None
        if self.lib is not None and not c["name"]:
            c["suggestions"] = self.lib.suggest(c["centroid"], self._f("speaker_suggest"))
        elif c["name"]:
            c["suggestions"] = []

    def _best(self, emb) -> tuple[str | None, float]:
        best, score = None, -2.0
        for sid, c in self.clusters.items():
            if c["centroid"] is None or len(c["centroid"]) != len(emb):
                continue
            s = float(np.dot(c["centroid"], emb))
            if s > score:
                best, score = sid, s
        return best, score

    def by_name(self, name: str, exclude: str | None = None) -> str | None:
        for sid, c in self.clusters.items():
            if sid != exclude and c["name"] and c["name"].casefold() == name.casefold():
                return sid
        return None

    def label(self, t: str, sid: str | None) -> str | None:
        """Display name for a line written at t with tag sid (overrides and merges applied)."""
        with self.lock:
            s = self.resolve(self.overrides.get(t) or sid)
            if not s:
                return None
            c = self.clusters.get(s)
            return speaker_display(s, c["name"] if c else None)

    # ---- the ASR thread
    def observe(self, t_hms: str, t_start: float, t_end: float, emb, dur: float, text: str) -> str | None:
        """Assign a written `them` line to a speaker. Returns the tag to write, or None."""
        with self.lock:
            sid, member = None, False
            if emb is not None:
                emb = unit(emb)
                best, score = self._best(emb)
                if best is not None and score >= self._f("speaker_join"):
                    sid, member = best, True
                elif dur >= self._f("speaker_new_min_s"):
                    sid, member = self._new_cluster(), True
            if sid is None and self.last_sid and t_start - self.last_end <= self._f("speaker_inherit_s"):
                sid = self.resolve(self.last_sid)      # tag only: an unsure embedding never moves a centroid
                if sid not in self.clusters:
                    sid = None
            self.segs[t_hms] = {"sid": sid, "emb": emb, "dur": float(dur)}
            if sid is None:
                self.now_info, self.last_sid, self.last_end = None, None, t_end
                return None
            c = self.clusters[sid]
            if member:
                c["members"].append({"t": t_hms, "emb": emb, "dur": float(dur)})
            c["seconds"] += float(dur)
            c["first"] = c["first"] or t_hms
            c["quotes"] = (c["quotes"] + [(t_hms, text)])[-6:]
            self._recompute(sid)
            self.last_sid, self.last_end = sid, t_end
            self.now_info = {"sid": sid, "t": t_hms}
            if member:
                self._automerge(sid)
            self._save()
            return sid

    def observe_late(self, t_hms: str, t_start: float, t_end: float, emb, dur: float, text: str) -> str | None:
        """v37.1: the line was already written untagged (tips never wait for speakers). When the
        embedding arrives, assign it and record the tag as a line override, so read_delta, lt and
        named.md show the name for that line."""
        sid = self.observe(t_hms, t_start, t_end, emb, dur, text)
        if sid:
            with self.lock:
                self.overrides.setdefault(t_hms, sid)
                self.rev += 1
                self._save()
        return sid

    def after_line(self, sid: str | None) -> None:
        """Called after the line is in the transcript: may open a "Who is speaking?" ask."""
        if not sid:
            return
        with self.lock:
            self._maybe_ask(self.resolve(sid))

    # ---- merges
    def _merge(self, src: str | None, dst: str | None) -> bool:
        src, dst = self.resolve(src), self.resolve(dst)
        if not src or not dst or src == dst or src not in self.clusters or dst not in self.clusters:
            return False
        a, b = self.clusters[src], self.clusters[dst]
        b["members"] = sorted(b["members"] + a["members"], key=lambda m: m["t"])
        b["seconds"] += a["seconds"]
        b["first"] = min(x for x in (a["first"], b["first"]) if x) if (a["first"] or b["first"]) else None
        b["quotes"] = sorted(b["quotes"] + a["quotes"])[-6:]
        if not b["name"] and a["name"]:
            b["name"] = a["name"]
        self.merged[src] = dst
        for k, v in list(self.merged.items()):
            if v == src:
                self.merged[k] = dst
        for k, v in list(self.overrides.items()):
            if v == src:
                self.overrides[k] = dst
        if self.last_sid == src:
            self.last_sid = dst
        del self.clusters[src]
        self._recompute(dst)
        self.rev += 1
        if self.ask_open == src or (self.ask_open == dst and b["name"]):
            self.ask_open = None
            self._next_ask()
        return True

    def _automerge(self, sid: str) -> None:
        c = self.clusters.get(sid)
        if not c or c["centroid"] is None or len(c["members"]) < 2:
            return
        for other, o in list(self.clusters.items()):
            if other == sid or o["centroid"] is None or len(o["members"]) < 2:
                continue
            if c["name"] and o["name"] and c["name"] != o["name"]:
                continue
            if float(np.dot(c["centroid"], o["centroid"])) >= self._f("speaker_automerge"):
                keep, drop = sorted((sid, other), key=lambda s: int(s[1:]))   # the older label stays
                log(f"speakers: {drop} merged into {keep} (same voice)")
                self._merge(drop, keep)
                return

    # ---- asks
    def _quote(self, c: dict) -> tuple[str | None, str]:
        parts, t = [], None
        for qt, qx in reversed(c["quotes"]):
            parts.insert(0, qx)
            t = qt
            if sum(len(p) + 1 for p in parts) >= 120:
                break
        text = " ".join(parts)
        if len(text) > 120:
            cut = text[-120:]
            text = "…" + (cut.split(" ", 1)[1] if " " in cut[:30] else cut)
        return t, text

    def known_names(self, n: int = 8) -> list[str]:
        """Names offered on a "Who is speaking?" card: `people` from start.json not yet named in
        this call, then names already used in this call (to merge), then frequent library names."""
        used = {c["name"].casefold() for c in self.clusters.values() if c["name"]}
        out, seen = [], set()

        def add(x):
            if x and x.casefold() not in seen:
                seen.add(x.casefold())
                out.append(x)
        for p in self.people:
            if p.casefold() not in used:
                add(p)
        for c in sorted(self.clusters.values(), key=lambda c: -c["seconds"]):
            add(c["name"])
        for name in (self.lib.frequent(20) if self.lib else []):
            add(name)
        return out[:n]

    def _name(self, raw) -> str | None:
        n = clean_name(raw)
        return normalize_person(n, self.people) if n else None

    def _maybe_ask(self, sid: str | None) -> None:
        c = self.clusters.get(sid or "")
        if not c or c["name"] or sid in self.skipped or sid in self.asked:
            return
        if c["seconds"] < self._f("speaker_prompt_s"):
            return
        self.asked.add(sid)
        if self.ask_open or self.paused:
            if sid not in self.ask_queue:
                self.ask_queue.append(sid)
            return
        self._open_ask(sid)

    def _open_ask(self, sid: str) -> None:
        c = self.clusters[sid]
        t, quote = self._quote(c)
        self.ask_open = sid
        self.emit({"kind": "speaker_ask", "sid": sid, "t": t, "at": hhmmss(now()), "quote": quote,
                   "seconds": round(c["seconds"], 1), "suggestions": list(c["suggestions"]),
                   "known": self.known_names()})

    def _next_ask(self) -> None:
        if self.paused or self.ask_open:
            return
        while self.ask_queue:
            s = self.resolve(self.ask_queue.pop(0))
            c = self.clusters.get(s or "")
            if c and not c["name"] and s not in self.skipped:
                self._open_ask(s)
                return

    def _ask_answered(self) -> None:
        """Close the open ask when its speaker got a name, was merged away, skipped or removed."""
        if self.ask_open:
            orig = self.ask_open
            c = self.clusters.get(self.resolve(orig) or "")
            if orig in self.merged or not c or c["name"] or self.resolve(orig) in self.skipped:
                self.ask_open = None
        self._next_ask()

    def set_paused(self, on: bool) -> None:
        with self.lock:
            self.paused = bool(on)
            if not on:
                self._next_ask()

    # ---- window settings
    def apply_setting(self, key: str, value) -> bool:
        """speaker_name "S2|Name", speaker_merge "S4|S2", speaker_fix "<HH:MM:SS>|S1" or
        "<HH:MM:SS>|name:Name", speaker_skip "S2". Returns True when something changed."""
        v = _s(value)
        with self.lock:
            changed = False
            if key == "speaker_name":
                sid, sep, raw = v.partition("|")          # split on the first "|" only
                sid = self.resolve(sid.strip())
                if sid not in self.clusters or not sep:
                    return False
                name = self._name(raw) if raw.strip() else ""    # "S2|" clears the name
                if name is None:
                    return False
                other = self.by_name(name, exclude=sid) if name else None
                if other:
                    changed = self._merge(sid, other)      # the name already belongs to a speaker of this call
                    sid = other
                else:
                    self.clusters[sid]["name"] = name or None
                    self._recompute(sid)
                    changed = True
                self._ask_answered()
            elif key == "speaker_merge":
                a, _, b = v.partition("|")
                a, b = self.resolve(a.strip()), self.resolve(b.strip())
                changed = self._merge(a, b)
                self._ask_answered()
            elif key == "speaker_fix":
                t, _, target = v.partition("|")
                changed = self._fix(t.strip(), target.strip())
            elif key == "speaker_skip":
                sid = self.resolve(v.strip())
                if sid in self.clusters:
                    self.skipped.add(sid)
                    changed = True
                    self._ask_answered()
            else:
                return False
            if changed:
                self.rev += 1
                self._lib_sync()
                self._save()
            return changed

    def _fix(self, t: str, target: str) -> bool:
        if not t or not target:
            return False
        if target.lower().startswith("name:"):
            name = self._name(target[5:])
            if not name:
                return False
            dst = self.by_name(name) or self._new_cluster(name)
        else:
            dst = self.resolve(target)
            if dst not in self.clusters:
                return False
        seg = self.segs.get(t)
        owner = self.resolve(self.overrides.get(t) or (seg or {}).get("sid"))
        if owner == dst:
            return False
        if seg:
            if owner in self.clusters:
                o = self.clusters[owner]
                o["members"] = [m for m in o["members"] if m["t"] != t]
                o["seconds"] = max(0.0, o["seconds"] - seg["dur"])
                o["quotes"] = [q for q in o["quotes"] if q[0] != t]
                self._recompute(owner)
                if not o["members"] and o["seconds"] < 0.05 and not o["name"]:
                    del self.clusters[owner]
                    self.asked.discard(owner)
                    if self.ask_open == owner:
                        self.ask_open = None
            d = self.clusters[dst]
            if seg.get("emb") is not None:
                d["members"] = sorted(d["members"] + [{"t": t, "emb": seg["emb"], "dur": seg["dur"]}], key=lambda m: m["t"])
            d["seconds"] += seg["dur"]
            d["first"] = min(x for x in (d["first"], t) if x)
            self._recompute(dst)
        self.overrides[t] = dst
        self._next_ask()
        return True

    # ---- library
    def _lib_sync(self) -> None:
        if self.lib is None:
            return
        desired: dict[str, list] = {}
        for c in self.clusters.values():
            if not c["name"] or not c["members"]:
                continue
            good = [m for m in c["members"] if m["emb"] is not None and m["dur"] >= self._f("speaker_new_min_s")]
            good = good or [m for m in c["members"] if m["emb"] is not None]
            desired.setdefault(c["name"], []).extend(_round_emb(m["emb"]) for m in good[-10:])
        if desired == self.lib_added:
            return
        try:
            self.lib.apply_call(self.lib_added, desired)
            self.lib.save()
            self.lib_added = desired
        except Exception as e:  # noqa: BLE001
            log(f"voices: cannot update the library ({e!r})")

    # ---- output
    def snapshot(self) -> dict:
        with self.lock:
            cl = {}
            for sid in sorted(self.clusters, key=lambda s: int(s[1:])):
                c = self.clusters[sid]
                t, q = self._quote(c) if c["quotes"] else (None, "")
                cl[sid] = {"name": c["name"], "seconds": round(c["seconds"], 1), "first": c["first"],
                           "last_quote": {"t": t, "text": q} if t else None, "suggestions": list(c["suggestions"])}
            return {"clusters": cl, "overrides": dict(self.overrides), "merged": dict(self.merged),
                    "skipped": sorted(self.skipped), "rev": self.rev, "updated": hhmmss(now())}

    def _save(self) -> None:
        try:
            write_json_atomic(self.path, self.snapshot())
        except Exception as e:  # noqa: BLE001
            log(f"speakers: cannot write {self.path.name} ({e!r})")

    def status_fields(self) -> dict:
        with self.lock:
            sn = None
            if self.now_info:
                s = self.resolve(self.now_info["sid"])
                c = self.clusters.get(s or "")
                if c:
                    sn = {"sid": s, "name": c["name"], "t": self.now_info["t"]}
            return {"speakers_rev": self.rev, "speaker_now": sn, "speaker_ask_open": self.ask_open,
                    "speakers_count": len(self.clusters)}

    def finalize(self, transcript: Path, them_label: str) -> Path | None:
        """On stop: final library sync, speakers.json, and <stem>.named.md (the md stays untouched)."""
        with self.lock:
            self._lib_sync()
            self._save()
            if not self.clusters and not self.overrides:
                return None
            named = transcript.with_name(transcript.stem + ".named.md")
            text = transcript.read_text(encoding="utf-8")
            tmp = named.with_name(named.name + f".{os.getpid()}.tmp")
            tmp.write_text(apply_speaker_names(text, them_label, self.label), encoding="utf-8")
            os.replace(tmp, named)
            return named


def voices_check(cfg: dict) -> int:
    """`transcriber.py --voices-check`: load the speaker model and run a self-test (used by
    bin/install-voices.sh). Prints one line, exit 0 = speakers will work."""
    emb, reason = load_embedder(cfg)
    if emb is None:
        print(f"voices: OFF - {reason}")
        return 1
    t = np.arange(2 * SR) / SR
    x = (0.1 * np.sin(2 * np.pi * 140 * t) * (1 + np.sin(2 * np.pi * 3 * t)) +
         0.02 * np.random.default_rng(0).standard_normal(len(t))).astype(np.float32)
    t0 = time.time()
    a = emb.embed(x)
    ms = 1000 * (time.time() - t0)
    b = emb.embed(x * 0.1)
    inv = cosine(a, b)
    if len(a) != emb.dim or not np.all(np.isfinite(a)) or inv < 0.99:
        print(f"voices: FAIL - dim {len(a)}, loudness invariance {inv:.3f} (expected > 0.99)")
        return 1
    print(f"voices: OK - model {emb.path.name}, {emb.dim} floats, {ms:.0f} ms per 2 s, loudness invariance {inv:.3f}")
    return 0


# --------------------------------------------------------------------------- Capture

MIC_INPUTS: list = [[]]   # input devices the Mac sees now (uid, name, builtin, default); filled by mic_inputs_poller


def mic_inputs_poller(stop: threading.Event) -> None:
    """Every 4 s ask audiocap for the Mac's input devices, for the window's Mic menu (2026-10-22).
    An older audiocap without --list-inputs just exits with an error: the list stays empty and the
    window keeps its two fixed choices."""
    while not stop.is_set():
        try:
            r = subprocess.run([str(BIN), "--list-inputs"], capture_output=True, text=True, timeout=6)
            if r.returncode == 0:
                data = json.loads(r.stdout.strip() or "[]")
                if isinstance(data, list):
                    MIC_INPUTS[0] = [d for d in data if isinstance(d, dict) and d.get("uid") and d.get("name")]
        except Exception:
            pass
        stop.wait(4)


class Capture(threading.Thread):
    def __init__(self, source: str, seg: Segmenter, stop: threading.Event, device: str = "default"):
        super().__init__(daemon=True)
        self.source = source
        self.device = device
        self.seg = seg
        self.stop_ev = stop
        self.proc: subprocess.Popen | None = None
        self.error: str | None = None
        self.restarts = 0
        self.switching = False   # a device switch from the tips window, not a failure
        self.stalled = False     # watchdog restart: audiocap alive but no audio (2026-10-21 bug)
        self.started_at = 0.0    # wall time the current audiocap process started
        self.stall_restarts = 0
        self.last_stall_restart = 0.0
        self.stall_streak = 0     # restarts in a row without audio in between (reset when audio flows)
        self.auto_switched = False   # the watchdog moved the mic to the built-in microphone
        self.fed_samples = 0      # samples delivered by the current audiocap process

    @property
    def fed_s(self) -> float:
        return self.fed_samples / SR

    def _stop_proc(self) -> None:
        """terminate, then kill after 2 s if audiocap does not exit (a frozen CoreAudio thread)."""
        p = self.proc
        if not p or p.poll() is not None:
            return
        try:
            p.terminate()
        except OSError:
            return

        def _kill() -> None:
            if p.poll() is None:
                log(f"audiocap {self.source}: did not exit after SIGTERM, killing it")
                try:
                    p.kill()
                except OSError:
                    pass
        t = threading.Timer(2.0, _kill)
        t.daemon = True
        t.start()

    def restart_stalled(self, silent_s: float, why: str = "no audio") -> None:
        """audiocap is alive but delivers no audio: kill it, run() starts a fresh one."""
        self.stalled = True
        self.stall_restarts += 1
        self.stall_streak += 1
        self.last_stall_restart = now()
        log(f"audiocap {self.source} stalled: {why} for {silent_s:.0f} s, restarting it")
        self._stop_proc()

    def auto_switch_builtin(self, silent_s: float) -> None:
        """Two restarts in a row did not help: move the mic to the Mac's own microphone (the
        same mechanism as the window's mic_device setting). Counts as a stall restart."""
        self.stall_restarts += 1
        self.stall_streak += 1
        self.last_stall_restart = now()
        self.auto_switched = True
        log(f"audiocap {self.source} stalled {silent_s:.0f} s after {self.stall_streak - 1} restarts: "
            "switching to the built-in microphone")
        self.switch_device("builtin")

    def switch_device(self, device: str) -> None:
        """Restart the mic capture on another input (default | builtin) during the call."""
        if self.source != "mic" or device == self.device:
            return
        self.device = device
        self.switching = True
        self._stop_proc()

    def run(self) -> None:
        LOGS.mkdir(parents=True, exist_ok=True)
        while not self.stop_ev.is_set():
            errlog = open(LOGS / f"audiocap-{self.source}.log", "a")
            try:
                cmd = [str(BIN), "--source", self.source]
                if self.source == "mic" and (self.device == "builtin" or self.device.startswith("uid:")):
                    cmd += ["--device", self.device]
                self.fed_samples = 0
                self.proc = subprocess.Popen(cmd,
                                             stdout=subprocess.PIPE, stderr=errlog)
                self.started_at = now()
            except OSError as e:
                # Never give up for good: retry with a backoff capped at 60 s.
                self.restarts += 1
                self.error = f"cannot start audiocap: {e}"
                log(self.error)
                errlog.close()
                self.stop_ev.wait(min(60.0, 1.5 * 2 ** min(self.restarts - 1, 6)))
                continue
            assert self.proc.stdout is not None
            while not self.stop_ev.is_set():
                data = self.proc.stdout.read(6400)   # 0.1 s of float32 mono
                if not data:
                    break
                usable = len(data) - len(data) % 4
                self.fed_samples += usable // 4
                self.seg.feed(np.frombuffer(data[:usable], dtype=np.float32))
                if self.error and self.fed_s >= 2:
                    log(f"audiocap {self.source} recovered after restart")
                    self.error = None   # audio flows again: do not report a stale error
                    self.restarts = 0
            errlog.close()
            if self.stop_ev.is_set():
                break
            code = self.proc.wait()
            if self.switching:
                self.switching = False
                log(f"audiocap {self.source}: switched to {self.device}")
                continue
            if self.stalled:
                self.stalled = False
                time.sleep(0.5)
                continue
            self.restarts += 1
            self.error = f"audiocap {self.source} exited with {code} (see logs/audiocap-{self.source}.log)"
            log(self.error)
            # No permanent stop after N crashes: back off 1.5, 3, 6 ... s, capped at 60 s.
            self.stop_ev.wait(min(60.0, 1.5 * 2 ** min(self.restarts - 1, 6)))
        self.terminate()

    def terminate(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()


# --------------------------------------------------------------------------- Main

def listener_age() -> int | None:
    """Seconds since the skill's last read_delta poll (it touches state/listener).
    None until the first poll. The tips window warns when it grows: the skill stopped
    listening (its chat turn ended) and the PM must write "продовжуй" in the chat."""
    try:
        return round(time.time() - (STATE / "listener").stat().st_mtime)
    except OSError:
        return None


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
    for k in ("project_dir", "title", "slug", "prompt", "me_lang", "me_langs", "langs", "model", "prompter", "mic_device",
              "setup", "call_type", "hiring_role", "prompt_en", "prompt_uk", "stem_suffix"):
        v = getattr(args, k, None)
        if v:
            req[k] = v
    for key in ("langs", "me_langs"):
        if isinstance(req.get(key), str):
            req[key] = [l.strip() for l in req[key].replace("+", ",").split(",") if l.strip()]
    cfg.update({k: v for k, v in req.items() if v not in (None, "")})
    raw_md = str(cfg.get("mic_device") or "default").strip()
    md = raw_md.lower().replace(" ", "_")
    if raw_md.startswith("uid:") and len(raw_md) > 4:
        cfg["mic_device"] = raw_md          # one chosen input, UID from audiocap --list-inputs
    else:
        cfg["mic_device"] = "builtin" if md in ("builtin", "built-in", "mac", "mac_mic", "macbook", "internal") else "default"
    if not cfg.get("project_dir"):
        sys.exit("project_dir is required")
    if cfg["me_lang"] not in ("auto", None) and cfg["me_lang"] not in cfg["langs"]:
        cfg["langs"] = [cfg["me_lang"]] + list(cfg["langs"])
    me_langs = [l for l in (cfg.get("me_langs") or []) if l]
    if me_langs and cfg["me_lang"] not in ("auto", None) and cfg["me_lang"] not in me_langs:
        me_langs = [cfg["me_lang"]] + me_langs
    cfg["me_langs"] = me_langs
    for l in me_langs:
        if l not in cfg["langs"]:
            cfg["langs"] = list(cfg["langs"]) + [l]
    return cfg


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from-control", action="store_true")
    ap.add_argument("--project-dir")
    ap.add_argument("--title")
    ap.add_argument("--slug")
    ap.add_argument("--prompt")
    ap.add_argument("--me-lang", dest="me_lang")
    ap.add_argument("--me-langs", dest="me_langs", help="languages the PM may switch between, e.g. uk+en")
    ap.add_argument("--langs")
    ap.add_argument("--mic-device", dest="mic_device", help="default | builtin (the Mac's own microphone)")
    ap.add_argument("--model")
    ap.add_argument("--fake-whisper", action="store_true", help="test mode without MLX")
    ap.add_argument("--voices-check", action="store_true",
                    help="load the speaker model, run a self-test, print one line and exit (install-voices.sh)")
    args = ap.parse_args()
    if args.voices_check:
        vcfg = dict(DEFAULTS)
        try:
            vcfg.update(json.loads((ROOT / "config.json").read_text(encoding="utf-8")))
        except Exception:  # noqa: BLE001
            pass
        vcfg["speakers_enabled"] = True
        return voices_check(vcfg)

    cfg = load_request(args)
    title = cfg.get("title") or "Meeting"
    started = now()
    call_type, audience = normalize_meeting(cfg.get("call_type"), cfg.get("audience"))
    # stem_suffix (".app" from the Live Tips app): two recorders on the same call never share files.
    suffix = re.sub(r"[^a-z0-9.-]", "", str(cfg.get("stem_suffix") or "").lower())
    out = Path(cfg["project_dir"]) / "live" / f"{dt.datetime.fromtimestamp(started):%Y-%m-%d-%H%M}-{slugify(title)}{suffix}.md"
    tips_file = out.with_name(out.stem + ".tips.jsonl")
    inbox_file = out.with_name(out.stem + ".inbox.jsonl")
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / "pid").write_text(str(os.getpid()))
    try:
        (STATE / "listener").unlink()   # a poll from a previous call must not count
    except OSError:
        pass
    stop_file = CONTROL / "stop"
    if stop_file.exists():
        stop_file.unlink()
    if (CONTROL / "prompter").exists():
        (CONTROL / "prompter").unlink()
    mute_file = CONTROL / "mic_muted"     # created / removed by the mute button in the tips window
    if mute_file.exists():
        mute_file.unlink()                # every call starts unmuted

    status = {"state": "loading_model", "pid": os.getpid(), "file": str(out), "title": title,
              "slug": cfg.get("slug"), "started_at": dt.datetime.fromtimestamp(started).astimezone().isoformat(timespec="seconds"),
              "timezone": mac_timezone(),
              "langs": cfg["langs"], "me_lang": cfg["me_lang"], "me_langs": cfg["me_langs"],
              "mic_device": cfg["mic_device"],
              "tips_file": str(tips_file), "inbox_file": str(inbox_file), "lines": 0, "queue": 0,
              "system_audio": "starting", "mic": "starting", "errors": [],
              "setup_open": bool(cfg.get("setup")), "call_type": call_type, "audience": audience,
              "proactive": normalize_proactive(cfg.get("proactive")),
              "hiring_role": normalize_hiring_role(cfg.get("hiring_role")), "req_id": cfg.get("req_id"), "seq": 0,
              "mic_stall_restarts": 0, "mic_stall_streak": 0, "mic_auto_switched": False,
              "last_question": None, "tips_paused": "off",
              "speakers": "loading" if cfg.get("speakers_enabled", True) not in (False, "false", "off", "0", 0) else "off",
              "speakers_reason": None, "speakers_rev": 0, "speaker_now": None,
              "people": clean_people(cfg.get("people") or []), "ui_lang": cfg.get("ui_lang") or None,
              "semantic": "off", "semantic_reason": None, "semantic_switch": "on", "index_state": "off", "index_files": None,
              "index_chunks": None}
    sem_on = cfg.get("semantic_enabled", True) not in (False, "false", "off", "0", 0)
    if not sem_on:
        status["semantic_reason"] = "disabled in config.json (semantic_enabled)"
    elif SEM is None:
        status["semantic_reason"] = SEM_ERR
    else:
        status["semantic"] = "loading"
    idx_on = sem_on and SEM is not None and cfg.get("index_enabled", True) not in (False, "false", "off", "0", 0)
    status["index_reason"] = None if idx_on else ("disabled in config.json (index_enabled)" if sem_on and SEM else
                                                  status["semantic_reason"])

    def put_status() -> None:
        """Write status.json; `seq` grows on every write so readers can tell a live recorder
        from a stale file without trusting file mtimes across machines."""
        status["seq"] = int(status.get("seq") or 0) + 1
        write_json_atomic(STATE / "status.json", status)

    put_status()
    log(f"live-transcriber: {title} -> {out}")
    if cfg.get("prompter", True) not in (False, "false", "0", 0):
        launch_prompter(title, tips_file, inbox_file)
    log(f"languages: me={cfg['me_lang']} allowed={'+'.join(cfg['langs'])} model={cfg['model']}")
    log("microphone: " + ("the Mac's built-in microphone" if cfg["mic_device"] == "builtin" else "system default input"))

    try:
        whisper = FakeWhisper(cfg) if args.fake_whisper else Whisper(cfg)
    except Exception as e:  # noqa: BLE001
        status.update(state="error", errors=[f"whisper load failed: {e!r}"])
        put_status()
        log(status["errors"][0])
        return 1

    header = (f"# Live transcript: {title}\n\n"
              f"- Проєкт: {cfg.get('slug') or Path(cfg['project_dir']).name}\n"
              f"- Початок: {dt.datetime.fromtimestamp(started):%Y-%m-%d %H:%M:%S}\n"
              f"- Мови: {cfg['me_label']} = {'+'.join(cfg['me_langs']) or cfg['me_lang']}, дозволені = {'+'.join(cfg['langs'])}\n"
              f"- Модель: {cfg['model']}\n"
              f"- Канали: {cfg['me_label']} = мікрофон, {cfg['them_label']} = системний звук\n"
              f"- Мікрофон: {'вбудований мікрофон Мака' if cfg['mic_device'] == 'builtin' else 'системний вхід за замовчуванням (навушники або Мак)'}\n\n")
    # Speakers (v37): the model loads in the background; until it is ready lines have no [Sx] tag.
    flags = {"tips_paused": False}
    spk: dict = {"worker": None, "ready": False}
    tracker: SpeakerTracker | None = None
    if status["speakers"] == "loading":
        lib = VoiceLibrary(ROOT / str(cfg.get("voices_dir") or "voices") / "voices.json")
        tracker = SpeakerTracker(cfg, out.with_name(out.stem + ".speakers.json"), lib,
                                 emit=lambda item: _append_json(tips_file, item))

        def load_speakers() -> None:
            emb, reason = load_embedder(cfg)
            if emb is None:
                status.update(speakers="off", speakers_reason=reason)
                log(f"speakers: off ({reason})")
                return
            w = EmbedWorker(emb.embed, int(cfg.get("speaker_queue") or 8))
            w.start()
            spk["worker"] = w
            spk["ready"] = True
            status.update(speakers="on", speakers_reason=None)
            log(f"speakers: on ({emb.path.name}, library: {len(lib.people)} people)")
        threading.Thread(target=load_speakers, daemon=True).start()
    else:
        status["speakers_reason"] = "disabled in config.json (speakers_enabled)"
    segq: "queue.Queue[Segment]" = queue.Queue()
    stop_ev = threading.Event()
    flushed = threading.Event()
    segs = {"me": Segmenter("me", cfg, segq), "them": Segmenter("them", cfg, segq)}
    writer = Writer(out, cfg, header, them_speech=lambda: segs["them"].last_speech_at)
    caps = [Capture("mic", segs["me"], stop_ev, cfg["mic_device"]), Capture("system", segs["them"], stop_ev)]
    # Mic first, the system tap once the mic delivers audio (max 6 s): started together, the tap's
    # aggregate device creation blocked the mic start in CoreAudio (2026-10-22, 17:08: four 10 s hangs).
    caps[0].start()
    t_mic = now()
    while segs["me"].last_feed is None and now() - t_mic < 6:
        time.sleep(0.1)
    caps[1].start()
    threading.Thread(target=mic_inputs_poller, args=(stop_ev,), daemon=True).start()

    def on_signal(*_):
        stop_ev.set()
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGHUP, on_signal)   # Terminal window closed: stop cleanly, keep the transcript

    last_lang = {"me": cfg["me_lang"] if cfg["me_lang"] != "auto" else cfg["langs"][0],
                 "them": cfg["langs"][0]}
    prompt = cfg.get("prompt")
    prompt_words = set(re.findall(r"\w+", (prompt or "").lower()))
    global PROMPT_HEAD
    PROMPT_HEAD = re.findall(r"\w+", (prompt or "").lower())[:2]
    # The Whisper prompt biases the language: a Ukrainian prompt makes English speech come out
    # as Ukrainian gibberish. When the window switches the call language, the prompt follows.
    cards = Cards(out, tips_file)
    facts = FactBook(out, tips_file)
    outline = Outline(out, tips_file)
    slides = Slides(out, tips_file)
    # Semantic layer (Ollama): its own thread; the transcript path never waits for it.
    sem_live: SemanticLive | None = None
    sem_index = None          # read-only project index for SOS snippets and search requests
    if status["semantic"] == "loading":
        sem_live = SemanticLive(cfg, out, tips_file, facts, cards, flags, SEM.client_from_cfg(cfg))
        sem_live.start()
        extras = cfg.get("index_extra") or []
        extras = [extras] if isinstance(extras, str) else list(extras)
        sem_index = SEM.ProjectIndex(cfg["project_dir"], extras, sem_live.client)
        sem_live.index = sem_index
    else:
        log(f"semantic: off: {status['semantic_reason']}")
    talk = {"me": 0.0, "them": 0.0, "last_ch": None, "mono": 0.0, "mono_end": 0.0, "lags": []}
    pcell = [prompt]
    pwords = [prompt_words]
    recent: list[tuple[float, str, str]] = []   # (t, channel, text) of the last ~2 min, for SOS
    recent_lock = threading.Lock()

    def process(seg: Segment) -> None:
        job = None
        if (seg.channel == "them" and spk["worker"] is not None
                and seg.speech_s >= float(cfg.get("speaker_min_s", 1.0))):
            job = spk["worker"].submit(seg.audio)   # runs in parallel with the ASR below
        me_set = cfg["me_langs"] if len(cfg["me_langs"]) > 1 else None
        if seg.channel == "me" and cfg["me_lang"] != "auto" and not me_set:
            lang = cfg["me_lang"]
        elif seg.duration < cfg["sticky_short"]:
            lang = last_lang[seg.channel]
        elif seg.channel == "me" and me_set:
            # The PM switches only between own languages (e.g. uk <-> en), never to ru by mistake.
            lang = whisper.pick_language(seg.audio, me_set)
        else:
            lang = whisper.pick_language(seg.audio)
        t_asr0 = time.time()
        text, lang = whisper.transcribe(seg.audio, lang, pcell[0])
        t_asr1 = time.time()
        text = clean_text(text, pwords[0])
        if not text or not norm(text):
            return
        last_lang[seg.channel] = lang
        sid = None
        late_job = None
        if seg.channel == "them" and tracker is not None and spk["ready"]:
            try:
                wait_s = float(cfg.get("speaker_wait_s", 0) or 0)
                if job is not None and not job.done.is_set() and wait_s <= 0:
                    late_job = job          # do not hold the line: tag it when the embedding is ready
                else:
                    emb = job.wait(wait_s) if job else None
                    sid = tracker.observe(hhmmss(seg.t_start), seg.t_start, seg.t_end, emb, seg.duration, text)
            except Exception as e:  # noqa: BLE001
                log(f"speakers: {e!r}")
        line_obj = Line(seg.channel, seg.t_start, lang, text, sid=sid)
        writer.add(line_obj)
        if sid:
            try:
                tracker.after_line(sid)
            except Exception as e:  # noqa: BLE001
                log(f"speakers: {e!r}")
        if late_job is not None:
            def _tag_late(j=late_job, t_hms=hhmmss(seg.t_start), t0=seg.t_start, t1=seg.t_end,
                          dur=seg.duration, txt=text):
                try:
                    emb = j.wait(10.0)
                    s_late = tracker.observe_late(t_hms, t0, t1, emb, dur, txt)
                    if s_late:
                        tracker.after_line(s_late)
                except Exception as e:  # noqa: BLE001
                    log(f"speakers: late tag {e!r}")
            threading.Thread(target=_tag_late, daemon=True).start()
        with recent_lock:
            recent.append((seg.t_start, seg.channel, text))
            while recent and seg.t_start - recent[0][0] > 120:
                recent.pop(0)
        paused = flags["tips_paused"]
        q = None
        if seg.channel == "them":
            # Instant "❓" item in the window; the skill's tip for the question replaces it later.
            # While tips are paused nothing automatic is shown (v37 A); the status still tracks it.
            q = question_item(text, hhmmss(seg.t_start), hhmmss(now()), cfg.get("name_aliases") or [])
            if q:
                if not paused:
                    _append_json(tips_file, q)
                status["last_question"] = {"t": q["t"], "text": text[:200]}
        if sem_live is not None:
            sem_live.submit(line_obj, q is not None)      # O(1); embedding happens in its own thread
        try:
            if not paused:
                cards.check(line_obj)
                facts.check(line_obj)
            outline.check(line_obj)
        except Exception as e:  # noqa: BLE001
            log(f"cards: {e!r}")
        # Talk meter and transcription lag (shown in the tips window footer).
        talk[seg.channel] += seg.duration
        if seg.channel == "me" and talk["last_ch"] == "me" and seg.t_start - talk["mono_end"] < 6:
            talk["mono"] += seg.duration
        elif seg.channel == "me":
            talk["mono"] = seg.duration
        talk["last_ch"], talk["mono_end"] = seg.channel, seg.t_end
        talk["lags"] = (talk["lags"] + [t_asr1 - seg.t_end])[-5:]
        # Timing sidecar (latency analysis): where time goes between speech and the line.
        try:
            with open(str(out) + ".timing.jsonl", "a", encoding="utf-8") as tf:
                tf.write(json.dumps({
                    "t": dt.datetime.fromtimestamp(seg.t_start).strftime("%H:%M:%S"),
                    "ch": seg.channel, "lang": lang, "dur": round(seg.duration, 1),
                    "seg_end": dt.datetime.fromtimestamp(seg.t_end).strftime("%H:%M:%S.%f")[:-3],
                    "queued_s": round(t_asr0 - seg.t_end, 2),
                    "asr_s": round(t_asr1 - t_asr0, 2),
                    "written": dt.datetime.fromtimestamp(t_asr1).strftime("%H:%M:%S.%f")[:-3],
                    "chars": len(text)}, ensure_ascii=False) + "\n")
        except Exception:  # noqa: BLE001
            pass

    # Standby (2026-10-22): the window opens before the call; nothing is transcribed or written until
    # the PM presses Start (window button, control/go) or the other side speaks for standby_auto_s.
    standby = {"on": bool(cfg.get("standby")), "heard": [], "buf": []}
    try:
        (CONTROL / "go").unlink()        # a Start from a previous call must not count
    except OSError:
        pass

    def go_live(why: str) -> None:
        if not standby["on"]:
            return
        standby["on"] = False
        status.update(state="recording", standby=False)
        writer.marker("дзвінок почався")
        log(f"standby -> recording: {why}")
        # The speech that started the call (last 20 s) is transcribed, not lost.
        for sg in standby["buf"]:
            segq.put(sg)
        standby["buf"] = []
        put_status()

    def standby_seg(seg: Segment) -> None:
        cut = now() - 20
        standby["buf"] = [x for x in standby["buf"] if x.t_end >= cut] + [seg]
        if seg.channel != "them":
            return                      # the PM's own voice (talking in the room) never starts the call
        t = now()
        standby["heard"] = [(a, d) for a, d in standby["heard"] if t - a < 30] + [(t, seg.speech_s)]
        if sum(d for _, d in standby["heard"]) >= float(cfg.get("standby_auto_s", 5)):
            go_live("the other side is speaking")

    def worker() -> None:
        while True:
            try:
                seg = segq.get(timeout=0.5)
            except queue.Empty:
                if flushed.is_set():
                    return
                continue
            try:
                if standby["on"]:
                    standby_seg(seg)
                else:
                    process(seg)
            except Exception as e:  # noqa: BLE001
                log(f"transcribe error: {e!r}")
            finally:
                segq.task_done()

    wt = threading.Thread(target=worker, daemon=True)
    wt.start()
    status["state"] = "standby" if standby["on"] else "recording"
    status["standby"] = standby["on"]
    log(("standby: waiting for the call (Start in the window, control/go, or the other side speaking). "
         if standby["on"] else "recording. ") + "Stop: Ctrl+C here, or the skill writes control/stop")

    # Settings chosen in the tips window after a fast start (⚙︎): the window appends them to
    # the inbox; language and mic are applied here at once, type and role are for the skill.
    LANG_SETS = {"uk": ("uk", ["uk", "en"], ["uk", "en"]), "en": ("en", ["en", "uk"], ["en", "uk"]),
                 "mix": ("uk", ["uk", "en"], ["uk", "en"])}
    inbox_pos = [0]

    def speaker_status() -> None:
        if tracker is None:
            return
        f = tracker.status_fields()
        last = segs["them"].last_speech_at
        if f["speaker_now"] and (last is None or now() - last > 6):
            f["speaker_now"] = None        # 6 s of system silence: nobody is speaking
        status.update(f)

    def apply_window_settings() -> None:
        try:
            size = inbox_file.stat().st_size
        except OSError:
            return
        if size <= inbox_pos[0]:
            return
        with open(inbox_file, "rb") as f:
            f.seek(inbox_pos[0])
            chunk = f.read()
        cut = chunk.rfind(b"\n")
        if cut < 0:
            return
        inbox_pos[0] += cut + 1
        changed = False
        for raw in chunk[:cut].decode("utf-8", errors="replace").splitlines():
            try:
                d = json.loads(raw)
            except Exception:  # noqa: BLE001
                continue
            if not isinstance(d, dict):
                continue
            if d.get("kind") != "setting":
                if _s(d.get("text")).lower() == "sos":
                    sos_now()
                continue
            key, val = d.get("key"), d.get("value")
            if key == "go":
                go_live("Start pressed in the window")
                continue
            if key == "call_lang" and val in LANG_SETS:
                me, me_langs, langs = LANG_SETS[val]
                cfg.update(me_lang=me, me_langs=me_langs, langs=langs)
                whisper.langs = list(langs)
                last_lang["me"], last_lang["them"] = me, langs[0]
                status.update(call_lang=val, me_lang=me, me_langs=me_langs, langs=langs)
                newp = cfg.get("prompt_" + val) or (None if val == "en" else cfg.get("prompt"))
                pcell[0] = newp
                pwords[0] = set(re.findall(r"\w+", (newp or "").lower()))
                writer.marker(f"мова: {'+'.join(langs)}")
                log(f"languages switched in the tips window: me={me} allowed={'+'.join(langs)}")
            elif key == "mic_device" and (val in ("default", "builtin") or (val.startswith("uid:") and len(val) > 4)):
                caps[0].switch_device(val)
                cfg["mic_device"] = val
                status["mic_device"] = val
                if val.startswith("uid:"):
                    nm = next((i.get("name") for i in MIC_INPUTS[0] if "uid:" + str(i.get("uid")) == val), val[4:])
                    writer.marker("мікрофон: " + str(nm))
                else:
                    writer.marker("мікрофон: " + ("Мак" if val == "builtin" else "за замовчуванням"))
            elif key == "call_type":
                # Shown back in the window; the skill reads it as @@SET. Legacy values are mapped.
                ct, au = normalize_meeting(val, status.get("audience"))
                status.update(call_type=ct, audience=au)
            elif key == "audience":
                status["audience"] = normalize_meeting(status.get("call_type"), val)[1]
            elif key == "proactive":
                status["proactive"] = normalize_proactive(val)
            elif key == "hiring_role":
                status[key] = normalize_hiring_role(val)
            elif key == "comment_rate_seconds":
                status[key] = val
            elif key == "ui_lang":
                if _s(val).lower() in ("en", "uk"):
                    status["ui_lang"] = _s(val).lower()     # echoed for the skill and a reopened window
                    changed = True
            elif key == "tips_paused":
                on = _s(val).lower() in ("on", "true", "1", "yes")
                flags["tips_paused"] = on
                status["tips_paused"] = "on" if on else "off"
                if tracker is not None:
                    tracker.set_paused(on)
                log("tips paused in the window" if on else "tips resumed")
                changed = True
            elif key == "semantic":
                # Window switch "Local AI (Ollama)": off stops every embedding call and the indexing at once.
                on = _s(val).lower() in ("on", "true", "1", "yes")
                status["semantic_switch"] = "on" if on else "off"
                if sem_live is not None:
                    sem_live.set_enabled(on)
                    status.update(sem_live.status_fields())
                    if not on:
                        status.update(index_state="off", index_reason="Local AI turned off in the window")
                else:
                    log(f"semantic: switch {'on' if on else 'off'} in the window, but unavailable: {status.get('semantic_reason')}")
                changed = True
            elif key == "tip_feedback":
                if sem_live is not None:
                    sem_live.note_feedback(val)
            elif key in ("speaker_name", "speaker_merge", "speaker_fix", "speaker_skip"):
                if tracker is not None and tracker.apply_setting(key, val):
                    log(f"speakers: {key}={val}")
                    changed = True
        if changed:
            speaker_status()
            put_status()     # echo at once (speakers_rev, tips_paused)

    def sos_now() -> None:
        """The red HELP NOW button: show up to 2 matching facts / cards (no LLM). With the semantic
        layer on, picks follow the live topic and up to 2 project index snippets are added; this runs
        in a short-lived thread so the main loop never waits for an embedding."""
        threading.Thread(target=_sos, daemon=True).start()

    sos_lock = threading.Lock()

    def _sos() -> None:
        try:
            with recent_lock:
                last = recent[-1][0] if recent else now()
                texts = [x[2] for x in recent if last - x[0] <= 90]
            sem = None
            if sem_live is not None:
                with sos_lock:
                    sem = sem_live.sos_context(texts, sem_index)
            items = sos_pick(texts, list(facts.facts), cards.snapshot(), sem=sem)
            t = hhmmss(last) if recent else hhmmss(now())
            for it in items:
                it.setdefault("t", hhmmss(now()))
                it.update(src=t, at=hhmmss(now()), sos=True)
                _append_json(tips_file, it)
                if sem_live is not None and it.get("sem") is not None:
                    g = str(it.get("gist") or "")
                    sem_live.add_hit("sos", str(it.get("card") or it.get("doc") or g), it["sem"], g, it["t"],
                                     f"{it.get('card') or ''}|{it['t']}|{g[:60]}")
            log(f"sos: {len(items)} item(s) shown" + (" (semantic)" if sem else ""))
        except Exception as e:  # noqa: BLE001
            log(f"sos: {e!r}")

    def index_loop() -> None:
        """Keep <project>/.livetips-index fresh during the call: only new or changed files, newest
        first, small batches, only while the ASR queue is empty, with pauses (Whisper comes first).
        The lock in the index folder keeps it from writing at the same time as `lt index`."""
        client = SEM.client_from_cfg(cfg, timeout=30.0, cache_size=8)
        idx = SEM.ProjectIndex(cfg["project_dir"], sem_index.extras, client)
        idx.load()
        status.update(index_files=idx.counts()[0], index_chunks=idx.counts()[1])
        budget = int(cfg.get("index_live_max_chunks", 1500) or 0)
        exclude = {str(out.with_name(out.stem)) + "*"}       # this call's own files
        ok, reason = client.health()
        status.update(index_state="idle" if ok else "off", index_reason=None if ok else reason)
        stop_ev.wait(20)                                      # let the call settle first
        more = False

        class _StopOrOff:
            """update() stops between batches when the call stops or the window switch turns Local AI off."""
            @staticmethod
            def is_set() -> bool:
                return stop_ev.is_set() or (sem_live is not None and not sem_live.enabled)
        while not stop_ev.is_set():
            if sem_live is not None and not sem_live.enabled:
                status.update(index_state="off", index_reason="Local AI turned off in the window")
                stop_ev.wait(1)
                continue
            ok, reason = client.health()
            if not ok:
                status.update(index_state="off", index_reason=reason)
                stop_ev.wait(30)
                continue
            if budget <= 0:
                status.update(index_state="idle", index_reason="per-call budget used: run lt index after the call")
                stop_ev.wait(60)
                continue
            if segq.qsize() == 0:
                status.update(index_state="indexing", index_reason=None)
                try:
                    res = idx.update(batch=int(cfg.get("index_batch", 4) or 4), max_chunks=min(200, budget),
                                     should_yield=lambda: segq.qsize() > 0 or (sem_live is not None and len(sem_live.q) > 0),
                                     yield_sleep=0.5, pause_s=0.2, stop=_StopOrOff, lock_wait=0, exclude=exclude, timeout=30)
                    budget -= res["chunks_added"]
                    if sem_live is not None and res["chunks_added"]:
                        sem_live.count("index_chunks", res["chunks_added"])
                    more = res["remaining_files"] > 0
                    if res["chunks_added"] or res["removed"]:
                        log(f"index: +{res['chunks_added']} chunks ({res['new']} new, {res['changed']} changed, "
                            f"{res['removed']} removed files) in {res['seconds']} s")
                except SEM.IndexBusy:
                    more = False
                    status["index_reason"] = "busy: lt index is running"
                except SEM.SemanticError as e:
                    more = False
                    status["index_reason"] = e.reason
                except Exception as e:  # noqa: BLE001
                    more = False
                    log(f"index: {e!r}")
                f_n, c_n = idx.counts()
                status.update(index_state="idle", index_files=f_n, index_chunks=c_n)
            stop_ev.wait(3 if more else 60)
        status["index_state"] = "idle" if status.get("index_state") == "indexing" else status.get("index_state")

    if sem_index is not None and idx_on:
        threading.Thread(target=index_loop, daemon=True).start()
    elif sem_index is not None:
        f_n, c_n = sem_index.counts()
        status.update(index_files=f_n, index_chunks=c_n)

    search_dir = CONTROL / "search"
    search_out = STATE / "search"

    def search_requests() -> None:
        """`lt search` from a machine that cannot reach Ollama (the Cowork VM) asks the recorder:
        control/search/<id>.json {"q", "k"} -> state/search/<id>.json {"hits": [...]} or {"error"}."""
        try:
            reqs = sorted(search_dir.glob("*.json"))
        except OSError:
            return
        for rp in reqs[:4]:
            try:
                req = json.loads(rp.read_text(encoding="utf-8"))
                rp.unlink()
            except Exception:  # noqa: BLE001
                try:
                    rp.unlink()
                except OSError:
                    pass
                continue

            def answer(req=req, rid=rp.stem):
                res: dict = {"id": rid}
                try:
                    if sem_live is None or sem_live.state != "on":
                        raise SEM.SemanticError((sem_live.reason if sem_live else status.get("semantic_reason")) or "semantic off")
                    reader = SEM.ProjectIndex(cfg["project_dir"], sem_index.extras, sem_live.client)
                    res["hits"] = reader.search(str(req.get("q") or ""), int(req.get("k") or 5), timeout=10)
                    res["root"] = str(reader.root)
                except Exception as e:  # noqa: BLE001
                    res["error"] = getattr(e, "reason", None) or repr(e)
                search_out.mkdir(parents=True, exist_ok=True)
                write_json_atomic(search_out / f"{rid}.json", res)
            threading.Thread(target=answer, daemon=True).start()

    last_status = 0.0
    while not stop_ev.is_set():
        time.sleep(0.5)
        writer.tick()
        try:
            apply_window_settings()
        except Exception as e:  # noqa: BLE001
            log(f"window settings: {e!r}")
        if sem_index is not None and search_dir.is_dir():
            search_requests()
        if int(now() * 2) % 4 == 0:      # every ~2 s: pick up a new or changed fact book / outline
            try:
                facts.refresh()
                outline.refresh()
                slides.refresh()
            except Exception as e:  # noqa: BLE001   (refresh never raises; belt and braces)
                log(f"prep refresh: {e!r}")
        if stop_file.exists():
            stop_ev.set()
        go_file = CONTROL / "go"
        if go_file.exists():
            try:
                go_file.unlink()
            except OSError:
                pass
            go_live("control/go")
        # Mic watchdog (2026-10-21: the mic stream froze 3 min after an unmute, audiocap logged
        # nothing, status kept saying "ok" from a stale peak, the PM's update was lost).
        # audiocap always sends audio for the mic, silence included, so no chunks = stalled;
        # chunks of exact zeros for > mic_zero_s while not muted are a stall too.
        mic_cap = caps[0]
        action, mic_silent_s, mic_zero_s = mic_watchdog(
            now_t=now(), alive=mic_cap.proc is not None and mic_cap.proc.poll() is None,
            switching=mic_cap.switching, stalled=mic_cap.stalled, muted=segs["me"].muted,
            started_at=mic_cap.started_at, last_feed=segs["me"].last_feed,
            last_nonzero=segs["me"].last_nonzero, unmuted_at=segs["me"].unmuted_at,
            last_restart=mic_cap.last_stall_restart, streak=mic_cap.stall_streak, fed_s=mic_cap.fed_s,
            device=mic_cap.device, auto_switched=mic_cap.auto_switched,
            stall_s=float(cfg.get("mic_stall_s", 12)), zero_s=float(cfg.get("mic_zero_s", 10)))
        if action == "restart":
            # One transcript marker per stall episode (not one per restart).
            if mic_cap.stall_streak == 0:
                writer.marker("мікрофон завис, перезапускаю")
            why = "no audio" if mic_silent_s > float(cfg.get("mic_stall_s", 12)) else "digital silence (all zeros)"
            mic_cap.restart_stalled(max(mic_silent_s, mic_zero_s), why)
        elif action == "switch_builtin":
            mic_cap.auto_switch_builtin(max(mic_silent_s, mic_zero_s))
            cfg["mic_device"] = "builtin"
            status.update(mic_device="builtin", mic_auto_switched=True)
            writer.marker("мікрофон: перемкнув на мікрофон Мака")
        elif action == "recovered":
            writer.marker(f"мікрофон відновився після {mic_cap.stall_streak} перезапуск(ів)")
            log(f"audiocap mic recovered after {mic_cap.stall_streak} stall restart(s)")
            mic_cap.stall_streak = 0
        muted = mute_file.exists()
        if muted != segs["me"].muted:
            segs["me"].set_muted(muted)
            writer.marker("мікрофон вимкнено" if muted else "мікрофон увімкнено")
            log("mic muted in the tips window" if muted else "mic unmuted")
        reopen = CONTROL / "prompter"
        if reopen.exists():
            # Reopen the tips window (closed by accident): `touch control/prompter`,
            # or ask the skill ("відкрий суфлер"). The window reloads all tips so far.
            try:
                reopen.unlink()
            except OSError:
                pass
            launch_prompter(title, tips_file, inbox_file)
        if now() - last_status >= 2:
            last_status = now()
            errs = [c.error for c in caps if c.error]
            status.update(lines=writer.lines, queue=segq.qsize(), errors=errs,
                          last_line_at=hhmmss(writer.last_line_at) if writer.last_line_at else None,
                          audio_lost_s={k: round(v.lost) for k, v in segs.items()},
                          mic=("muted" if segs["me"].muted else
                               "stalled" if mic_silent_s > 4 or mic_zero_s > float(cfg.get("mic_zero_s", 10)) else
                               "ok" if segs["me"].recent_peak() > 0.001 else "silent"),
                          mic_stall_restarts=caps[0].stall_restarts, mic_stall_streak=caps[0].stall_streak,
                          mic_auto_switched=caps[0].auto_switched,
                          mic_inputs=MIC_INPUTS[0],
                          system_audio="ok" if segs["them"].recent_peak() > 0.0005 else "silent",
                          listener_age_s=listener_age(),
                          noise_dropped={k: v.noise_dropped for k, v in segs.items()},
                          talk_me_pct=(round(100 * talk["me"] / (talk["me"] + talk["them"]))
                                       if talk["me"] + talk["them"] > 30 else None),
                          monologue_s=(round(talk["mono"]) if talk["last_ch"] == "me"
                                       and now() - talk["mono_end"] < 8 else 0),
                          asr_lag_s=(round(sorted(talk["lags"])[len(talk["lags"]) // 2], 1)
                                     if talk["lags"] else None))
            if spk["worker"] is not None:
                w = spk["worker"]
                status["speaker_embed"] = {"done": w.done_n, "dropped": w.dropped,
                                           "ms": round(sorted(w.ms)[len(w.ms) // 2]) if w.ms else None}
            if sem_live is not None:
                status.update(sem_live.status_fields())
            speaker_status()
            put_status()
            if segq.qsize() > 6:
                log(f"warning: {segq.qsize()} segments waiting, transcription is behind")

    log("stopping...")
    status["state"] = "stopping"
    put_status()
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
    if spk["worker"] is not None:
        spk["worker"].stop()
    if sem_live is not None:
        sem_live.stop()
        status.update(sem_live.status_fields())
        try:
            sem_live.summary(out, tips_file)
        except Exception as e:  # noqa: BLE001
            log(f"semantic: summary failed ({e!r})")
    if tracker is not None and spk["ready"]:
        try:
            named = tracker.finalize(out, cfg["them_label"])
            if named:
                status["named_file"] = str(named)
                log(f"speakers: {named.name} written")
            speaker_status()
            status["speaker_now"] = None
        except Exception as e:  # noqa: BLE001
            log(f"speakers: finalize failed ({e!r})")
    status.update(state="stopped", lines=writer.lines, stopped_at=hhmmss(now()))
    put_status()
    for f in (CONTROL / "active.json", stop_file, CONTROL / "prompter", mute_file, STATE / "pid", STATE / "launching"):
        try:
            f.unlink()
        except FileNotFoundError:
            pass
    log(f"done: {writer.lines} lines -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
