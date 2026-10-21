#!/usr/bin/env python3
"""Local semantic layer for live-tips: Ollama embeddings (bge-m3 by default), an LRU cache,
cosine top-k, a rolling "live topic" vector and the project index (.livetips-index/).

Everything stays on this Mac: the only network call goes to the local Ollama server
(http://127.0.0.1:11434 by default, never through a proxy). Every public entry point degrades
gracefully: when Ollama is not running, the model is not pulled or a call times out, callers get
a SemanticError (or `health()` returns (False, reason)) and keep their keyword behaviour.

Imported by src/transcriber.py (live matching, SOS, background indexing) and bin/lt
(`lt index`, `lt search`). Needs only numpy and the standard library.
"""

from __future__ import annotations

import collections
import datetime as dt
import hashlib
import json
import os
import re
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import numpy as np

try:
    import fcntl
except ImportError:  # pragma: no cover (not on macOS / Linux)
    fcntl = None

DEFAULT_URL = "http://127.0.0.1:11434"
DEFAULT_MODEL = "bge-m3"
INDEX_DIR = ".livetips-index"
INDEX_VERSION = 1

# Short neutral sentences (small talk, call logistics) in the call languages. The highest cosine
# of an entry to these is its "noise floor": a line must beat the floor by a margin to count as
# a semantic hit. This cancels the language bias of an embedding model (Ukrainian small talk is
# closer to a Ukrainian fact than to an English one) and makes thresholds less model-specific.
NEUTRAL_ANCHORS = [
    "Hello, can you hear me?", "Добрий день, мене чути?", "Hola, ¿me escuchan?",
    "Let me share my screen.", "Зараз покажу екран.", "Déjame compartir mi pantalla.",
    "Sorry, I was on mute.", "Вибачте, у мене був вимкнений мікрофон.", "Perdón, estaba en silencio.",
    "Okay, sounds good, thank you.", "Так, добре, дякую.", "Vale, perfecto, gracias.",
    "The weather is nice today.", "Сьогодні гарна погода.", "Hoy hace buen tiempo.",
    "See you next week, bye.", "До зустрічі, бувайте.", "Nos vemos la próxima semana, chao.",
    "One moment, my internet is slow.", "Хвилинку, щось інтернет гальмує.",
    "How was your weekend?", "Як пройшли вихідні?",
    "Let's wait a minute for the others to join.", "Почекаємо ще хвилину, поки всі підключаться.",
]


class SemanticError(Exception):
    """An embedding call failed. `reason` is a short human-readable cause for status.json."""

    def __init__(self, reason: str, status: int | None = None, body: str = ""):
        super().__init__(reason)
        self.reason = reason
        self.status = status
        self.body = body


# --------------------------------------------------------------------------- math helpers

def l2norm(m) -> np.ndarray:
    """L2-normalised float32 rows (a 1-D vector is treated as one row and stays 1-D)."""
    a = np.asarray(m, dtype=np.float32)
    one = a.ndim == 1
    a = a.reshape(1, -1) if one else a
    n = np.linalg.norm(a, axis=1, keepdims=True)
    a = a / np.maximum(n, 1e-12)
    return a[0] if one else a


def cosine_scores(q, mat, block: int = 8192) -> np.ndarray:
    """Cosine of a normalised query to every normalised row of `mat` (float16 or float32)."""
    if mat is None or len(mat) == 0:
        return np.zeros(0, dtype=np.float32)
    q = np.asarray(q, dtype=np.float32)
    out = np.empty(len(mat), dtype=np.float32)
    for i in range(0, len(mat), block):
        out[i:i + block] = np.asarray(mat[i:i + block], dtype=np.float32) @ q
    return out


def topk(q, mat, k: int = 5, min_score: float | None = None) -> list[tuple[int, float]]:
    """Indices and scores of the k best rows, best first."""
    s = cosine_scores(q, mat)
    if not len(s):
        return []
    k = min(k, len(s))
    idx = np.argpartition(-s, k - 1)[:k]
    idx = idx[np.argsort(-s[idx])]
    return [(int(i), float(s[i])) for i in idx if min_score is None or s[i] >= min_score]


def text_hash(text: str, model: str = "") -> str:
    return hashlib.sha1((model + "\x00" + (text or "")).encode("utf-8")).hexdigest()


class LRU:
    """A small thread-safe LRU cache (text hash -> vector)."""

    def __init__(self, maxlen: int = 1024):
        self.maxlen = max(1, int(maxlen))
        self.d: "collections.OrderedDict[str, np.ndarray]" = collections.OrderedDict()
        self.lock = threading.Lock()

    def get(self, key: str):
        with self.lock:
            v = self.d.get(key)
            if v is not None:
                self.d.move_to_end(key)
            return v

    def put(self, key: str, v) -> None:
        with self.lock:
            self.d[key] = v
            self.d.move_to_end(key)
            while len(self.d) > self.maxlen:
                self.d.popitem(last=False)

    def __len__(self) -> int:
        return len(self.d)


# --------------------------------------------------------------------------- Ollama client

class OllamaClient:
    """Minimal client for the local Ollama embedding API.

    POST /api/embed {"model", "input": [...]} -> {"embeddings": [[...], ...]} (Ollama 0.3.4+);
    older servers only have POST /api/embeddings {"model", "prompt"} -> {"embedding": [...]},
    used automatically when /api/embed answers 404 for the route (not for a missing model).
    """

    def __init__(self, url: str = DEFAULT_URL, model: str = DEFAULT_MODEL, timeout: float = 2.0,
                 health_ttl: float = 30.0, keep_alive: str | None = "30m", cache_size: int = 1024,
                 batch: int = 32):
        self.url = (url or DEFAULT_URL).rstrip("/")
        self.model = model or DEFAULT_MODEL
        self.timeout = float(timeout)
        self.health_ttl = float(health_ttl)
        self.keep_alive = keep_alive
        self.batch = max(1, int(batch))
        self.cache = LRU(cache_size)
        self.legacy = False
        self.dim: int | None = None
        self._health: tuple[float, bool, str] | None = None
        self._lock = threading.Lock()
        # Never route localhost through HTTP(S)_PROXY from the environment.
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.calls = 0          # HTTP embedding requests sent
        self.texts = 0          # texts embedded by the server
        self.cached = 0         # texts answered from the LRU cache
        self.errors = 0
        self.ms: "collections.deque[float]" = collections.deque(maxlen=200)

    # ---- HTTP
    def _req(self, path: str, payload: dict | None, timeout: float) -> dict:
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(self.url + path, data=data, method="GET" if data is None else "POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with self._opener.open(req, timeout=timeout) as r:
                body = r.read()
        except urllib.error.HTTPError as e:
            try:
                txt = e.read().decode("utf-8", "replace")[:300]
            except Exception:  # noqa: BLE001
                txt = ""
            raise SemanticError(f"HTTP {e.code} from Ollama {path}: {txt or e.reason}", e.code, txt) from None
        except (TimeoutError, OSError, urllib.error.URLError) as e:
            r = getattr(e, "reason", e)
            if isinstance(r, (TimeoutError,)) or "timed out" in str(r):
                raise SemanticError(f"Ollama timeout after {timeout:g} s ({path})") from None
            if isinstance(r, ConnectionRefusedError) or "refused" in str(r).lower():
                raise SemanticError(f"Ollama is not running at {self.url} (ollama serve, or open the Ollama app)") from None
            raise SemanticError(f"Ollama not reachable at {self.url} ({r})") from None
        try:
            return json.loads(body.decode("utf-8"))
        except Exception:  # noqa: BLE001
            raise SemanticError(f"Ollama {path}: invalid JSON") from None

    @staticmethod
    def _model_missing(e: SemanticError) -> bool:
        b = (e.body or str(e)).lower()
        return "model" in b and ("not found" in b or "pull" in b)

    # ---- health
    def health(self, force: bool = False) -> tuple[bool, str]:
        """(ok, reason). Cached for `health_ttl` s (a failure for at most 10 s)."""
        h = self._health
        if h and not force:
            age = time.time() - h[0]
            if age < (self.health_ttl if h[1] else min(10.0, self.health_ttl)):
                return h[1], h[2]
        ok, reason = self._probe()
        self._health = (time.time(), ok, reason)
        return ok, reason

    def mark_down(self, reason: str) -> None:
        self._health = (time.time(), False, reason)

    def _probe(self) -> tuple[bool, str]:
        try:
            tags = self._req("/api/tags", None, min(self.timeout, 2.0))
        except SemanticError as e:
            return False, e.reason
        names = [str(m.get("name") or m.get("model") or "") for m in (tags.get("models") or []) if isinstance(m, dict)]
        want = self.model if ":" in self.model else self.model + ":latest"
        if not any(n == self.model or n == want for n in names):
            return False, f"model {self.model} is not pulled (run: ollama pull {self.model})"
        return True, "ok"

    def version(self) -> str | None:
        """Ollama server version (GET /api/version), None when unknown."""
        try:
            return str(self._req("/api/version", None, 1.5).get("version") or "") or None
        except SemanticError:
            return None

    def model_memory(self) -> dict | None:
        """Memory the loaded model takes in Ollama: {"size_mb", "vram_mb", "source"}, or None.
        GET /api/ps first; else `ollama ps` (2 s timeout). Optional and cheap."""
        try:
            for m in self._req("/api/ps", None, 1.5).get("models") or []:
                name = str(m.get("name") or m.get("model") or "")
                if name.split(":")[0] == self.model.split(":")[0]:
                    return {"size_mb": round(int(m.get("size") or 0) / 2**20), "vram_mb": round(int(m.get("size_vram") or 0) / 2**20),
                            "source": "api/ps"}
        except (SemanticError, TypeError, ValueError):
            pass
        try:
            import subprocess  # noqa: PLC0415
            out = subprocess.run(["ollama", "ps"], capture_output=True, text=True, timeout=2).stdout
            for ln in out.splitlines()[1:]:
                parts = ln.split()
                if parts and parts[0].split(":")[0] == self.model.split(":")[0] and len(parts) >= 4:
                    num, unit = float(parts[2]), parts[3].upper()
                    mb = num * (1024 if unit.startswith("G") else 1 if unit.startswith("M") else 1 / 1024)
                    return {"size_mb": round(mb), "vram_mb": None, "source": "ollama ps"}
        except Exception:  # noqa: BLE001
            pass
        return None

    # ---- embeddings
    def embed(self, texts: list[str], timeout: float | None = None, use_cache: bool = True) -> np.ndarray:
        """L2-normalised float32 matrix, one row per text. Raises SemanticError."""
        texts = [t if isinstance(t, str) else str(t) for t in texts]
        if not texts:
            return np.zeros((0, self.dim or 0), dtype=np.float32)
        keys = [text_hash(t, self.model) for t in texts]
        out: list = [None] * len(texts)
        missing: list[int] = []
        for i, k in enumerate(keys):
            v = self.cache.get(k) if use_cache else None
            if v is None:
                missing.append(i)
            else:
                out[i] = v
                self.cached += 1
        for j in range(0, len(missing), self.batch):
            part = missing[j:j + self.batch]
            vecs = self._embed_raw([texts[i] for i in part], self.timeout if timeout is None else timeout)
            for i, v in zip(part, vecs):
                out[i] = v
                if use_cache:
                    self.cache.put(keys[i], v)
        return np.stack(out).astype(np.float32)

    def embed_one(self, text: str, timeout: float | None = None) -> np.ndarray:
        return self.embed([text], timeout)[0]

    def _embed_raw(self, texts: list[str], timeout: float) -> np.ndarray:
        t0 = time.time()
        try:
            vecs = None
            if not self.legacy:
                payload = {"model": self.model, "input": texts}
                if self.keep_alive:
                    payload["keep_alive"] = self.keep_alive
                try:
                    r = self._req("/api/embed", payload, timeout)
                    self.calls += 1
                    vecs = r.get("embeddings")
                except SemanticError as e:
                    if e.status == 404 and not self._model_missing(e):
                        self.legacy = True       # an older Ollama without /api/embed
                    else:
                        raise
            if self.legacy:
                vecs = []
                for t in texts:
                    payload = {"model": self.model, "prompt": t}
                    if self.keep_alive:
                        payload["keep_alive"] = self.keep_alive
                    r = self._req("/api/embeddings", payload, timeout)
                    self.calls += 1
                    vecs.append(r.get("embedding"))
            if not isinstance(vecs, list) or len(vecs) != len(texts) or not all(isinstance(v, list) and v for v in vecs):
                raise SemanticError("Ollama returned no embeddings (is the model an embedding model?)")
            arr = l2norm(np.asarray(vecs, dtype=np.float32))
        except SemanticError as e:
            self.errors += 1
            if self._model_missing(e):
                self.mark_down(f"model {self.model} is not pulled (run: ollama pull {self.model})")
                raise SemanticError(f"model {self.model} is not pulled (run: ollama pull {self.model})", e.status) from None
            raise
        self.dim = arr.shape[1]
        self.texts += len(texts)
        self.ms.append(1000 * (time.time() - t0))
        return arr

    def stats(self) -> dict:
        ms = sorted(self.ms)
        return {"calls": self.calls, "texts": self.texts, "cached": self.cached, "errors": self.errors,
                "ms_p50": round(ms[len(ms) // 2]) if ms else None,
                "ms_p95": round(ms[min(len(ms) - 1, int(len(ms) * 0.95))]) if ms else None}


def client_from_cfg(cfg: dict, timeout: float | None = None, **kw) -> OllamaClient:
    return OllamaClient(url=str(cfg.get("ollama_url") or DEFAULT_URL), model=str(cfg.get("semantic_model") or DEFAULT_MODEL),
                        timeout=float(timeout if timeout is not None else cfg.get("semantic_timeout_s", 2.0)), **kw)


# --------------------------------------------------------------------------- vector cache on disk

def load_vec_cache(path: Path, model: str) -> dict[str, np.ndarray]:
    """{text hash: vector} from <stem>.semantic.npz; empty when missing, broken or another model."""
    try:
        with np.load(path, allow_pickle=False) as z:
            if str(z["model"]) != model:
                return {}
            return {str(h): v for h, v in zip(z["h"], z["v"].astype(np.float32))}
    except Exception:  # noqa: BLE001
        return {}


def save_vec_cache(path: Path, model: str, cache: dict[str, np.ndarray]) -> None:
    if not cache:
        return
    keys = sorted(cache)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.{threading.get_ident()}.tmp.npz")
    try:
        np.savez(tmp, model=np.array(model), h=np.array(keys), v=np.stack([cache[k] for k in keys]).astype(np.float32))
        os.replace(tmp, path)
    except Exception:  # noqa: BLE001
        try:
            tmp.unlink()
        except OSError:
            pass


# --------------------------------------------------------------------------- live topic

class LiveTopic:
    """A decayed mean of the line vectors of the last `window` s (both channels)."""

    def __init__(self, window: float = 60.0, tau: float = 30.0):
        self.window, self.tau = float(window), float(tau)
        self.items: "collections.deque[tuple[float, np.ndarray]]" = collections.deque()
        self.lock = threading.Lock()

    def add(self, t: float, vec) -> None:
        with self.lock:
            self.items.append((t, np.asarray(vec, dtype=np.float32)))
            self._trim(t)

    def _trim(self, t_now: float) -> None:
        while self.items and t_now - self.items[0][0] > self.window:
            self.items.popleft()

    def vector(self, t_now: float | None = None) -> np.ndarray | None:
        with self.lock:
            if not self.items:
                return None
            t_now = self.items[-1][0] if t_now is None else t_now
            self._trim(t_now)
            if not self.items:
                return None
            w = np.array([np.exp(-max(0.0, t_now - t) / self.tau) for t, _ in self.items], dtype=np.float32)
            m = np.stack([v for _, v in self.items])
            return l2norm((w[:, None] * m).sum(0))

    def __len__(self) -> int:
        return len(self.items)


# --------------------------------------------------------------------------- project index: files and chunks

TEXT_EXT = {".md", ".txt", ".csv", ".json"}
SKIP_DIRS = {".git", "node_modules", "repos", "_archived", INDEX_DIR, "__pycache__", ".venv", "venv",
             ".idea", ".vscode", ".Trash", ".cache",
             # never index secrets, deleted or archived material (2026-10-21)
             "Secrets", "secrets", "_to_delete", "_archive", "_Archive"}
SECRET_NAME = re.compile(r"(secret|credential|password|token|\.env$|apikey|api_key)", re.I)
MAX_BYTES = 2 * 1024 * 1024
JSON_MAX = 256 * 1024
CSV_ROWS = 30
FRONT_KEYS = re.compile(r"^\s*(last[_ ]?edited(?:[_ ]time)?|last[_ ]?modified|updated(?:[_ ]at)?|modified|date)\s*:\s*(.+?)\s*$",
                        re.I | re.M)
DATE_RX = re.compile(r"(\d{4}-\d{2}-\d{2})")


def skip_file(path: Path, rel_parts: tuple[str, ...]) -> bool:
    """Files that never go into the index (besides size and binary checks)."""
    name = path.name
    if path.suffix.lower() not in TEXT_EXT or name.startswith("."):
        return True
    if SECRET_NAME.search(name):
        return True
    if ".timing" in name or name.endswith(".semantic.jsonl"):
        return True
    if "live" in rel_parts[:-1]:
        # Call artefacts: keep only the transcripts themselves (not tips, state, prep or named copies).
        if path.suffix.lower() != ".md" or name.endswith(".named.md") or name.endswith(".clean.md"):
            return True
    return False


def iter_files(roots: list[tuple[Path, str]], exclude: set[str] | None = None):
    """Yield (abs path str, display rel, stat) for every indexable file under the roots.
    roots: [(dir, display prefix)], the prefix is "" for the project root."""
    exclude = exclude or set()
    seen = set()
    for base, prefix in roots:
        base = Path(base)
        if not base.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
            dp = Path(dirpath)
            for fn in filenames:
                p = dp / fn
                try:
                    rel = p.relative_to(base)
                except ValueError:
                    continue
                if skip_file(p, rel.parts):
                    continue
                ap = str(p)
                if ap in seen or ap in exclude or any(ap.startswith(x[:-1]) for x in exclude if x.endswith("*")):
                    continue
                try:
                    st = p.stat()
                except OSError:
                    continue
                if st.st_size > MAX_BYTES or st.st_size == 0:
                    continue
                seen.add(ap)
                yield ap, (prefix + "/" if prefix else "") + str(rel), st


def front_date(text: str) -> str | None:
    """`last_edited` from a front matter block (or a "Last edited: ..." line near the top)."""
    head = text[:3000]
    if head.startswith("---"):
        end = head.find("\n---", 3)
        block = head[3:end] if end > 0 else head
    else:
        block = "\n".join(head.splitlines()[:30])
    for m in FRONT_KEYS.finditer(block):
        d = DATE_RX.search(m.group(2))
        if d:
            return d.group(1)
    return None


def front_end(text: str) -> int:
    """Offset just after a leading front matter block (--- ... ---), else 0."""
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if 0 < end < 5000:
            nl = text.find("\n", end + 4)
            return len(text) if nl < 0 else nl + 1
    return 0


def read_doc(path: str) -> str | None:
    """Text to index, or None for a binary / unreadable file. CSV: the first rows; JSON: small files."""
    p = Path(path)
    try:
        raw = p.read_bytes()
    except OSError:
        return None
    if b"\x00" in raw[:4096]:
        return None
    text = raw.decode("utf-8", errors="replace")
    ext = p.suffix.lower()
    if ext == ".csv":
        return "\n".join(text.splitlines()[:CSV_ROWS + 1])
    if ext == ".json":
        if len(raw) > JSON_MAX:
            return None
        try:
            return json.dumps(json.loads(text), ensure_ascii=False, indent=1)
        except Exception:  # noqa: BLE001
            return text
    return text


HEADING_RX = re.compile(r"^#{1,6}\s+(.+)$")


def chunk_text(text: str, target: int = 1000, max_len: int = 1200, overlap: int = 120) -> list[tuple[int, int, str]]:
    """Split into (start, end, heading) chunks of ~target chars: a new chunk at every heading,
    paragraphs packed up to max_len, long paragraphs cut at sentence ends, `overlap` chars of
    the previous chunk repeated at the start of the next one inside the same section."""
    if not text.strip():
        return []
    # Paragraph spans with the heading in force.
    spans: list[tuple[int, int, str, bool]] = []   # start, end, heading, starts_section
    heading = ""
    pos = 0
    for block in re.split(r"(\n\s*\n)", text):
        start, end = pos, pos + len(block)
        pos = end
        if not block.strip():
            continue
        first = block.strip().splitlines()[0]
        m = HEADING_RX.match(first)
        new_sec = bool(m)
        if m:
            heading = m.group(1).strip()[:120]
        # Very long paragraphs: cut at sentence ends.
        s = start
        step = max(target // 2, max_len - overlap)   # room for the overlap when pieces are packed
        while end - s > max_len:
            cut = -1
            window = text[s:s + step]
            for rx in (r"[.!?]\s", r"\n", r"[;,]\s", r"\s"):
                ms = list(re.finditer(rx, window))
                ms = [x for x in ms if x.end() >= target * 0.5]
                if ms:
                    cut = s + ms[-1].end()
                    break
            if cut <= s:
                cut = s + step
            spans.append((s, cut, heading, new_sec))
            new_sec = False
            s = cut
        spans.append((s, end, heading, new_sec))
    chunks: list[tuple[int, int, str]] = []
    cur_s = cur_e = None
    cur_h = ""
    for s, e, h, new_sec in spans:
        if cur_s is not None and (new_sec or e - cur_s > max_len or (cur_e - cur_s >= target)):
            chunks.append((cur_s, cur_e, cur_h))
            if not new_sec and overlap and cur_e - cur_s > overlap:
                ov = max(cur_s, cur_e - overlap)
                sp = text.find(" ", ov, cur_e)
                cur_s = sp + 1 if 0 <= sp < cur_e else ov
                if e - cur_s > max_len:
                    cur_s = s
            else:
                cur_s = s
            cur_e, cur_h = e, h
            continue
        if cur_s is None:
            cur_s, cur_h = s, h
        cur_e = e
    if cur_s is not None:
        chunks.append((cur_s, cur_e, cur_h))
    return [(s, e, h) for s, e, h in chunks if text[s:e].strip()]


def preview(text: str, n: int = 220) -> str:
    t = re.sub(r"\s+", " ", text or "").strip()
    return t if len(t) <= n else t[:n].rsplit(" ", 1)[0] + "…"


def doc_title(rel: str) -> str:
    stem = Path(rel).stem
    stem = re.sub(r"\s+[0-9a-f]{32}$", "", stem)          # Notion export id suffix
    return stem.replace("_", " ").strip() or rel


# --------------------------------------------------------------------------- project index: storage

class IndexBusy(Exception):
    pass


class IndexLock:
    """An exclusive flock on <index>/lock, so the recorder thread and the CLI never write at once.
    wait=0: fail at once (IndexBusy) when someone else holds it."""

    def __init__(self, dirpath: Path, wait: float = 0.0):
        self.path = Path(dirpath) / "lock"
        self.wait = float(wait)
        self.f = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.f = open(self.path, "a+")
        if fcntl is None:
            return self
        deadline = time.time() + self.wait
        while True:
            try:
                fcntl.flock(self.f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError:
                if time.time() >= deadline:
                    self.f.close()
                    self.f = None
                    raise IndexBusy("the project index is being updated by another process") from None
                time.sleep(0.2)

    def __exit__(self, *exc):
        if self.f is not None:
            try:
                if fcntl is not None:
                    fcntl.flock(self.f.fileno(), fcntl.LOCK_UN)
            finally:
                self.f.close()
                self.f = None


def _write_atomic_bytes(path: Path, write_fn) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    try:
        with open(tmp, "wb") as f:
            write_fn(f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass


class ProjectIndex:
    """Chunk vectors of a project folder (plus optional extra dirs) under <root>/.livetips-index/:
      manifest.json         version, model, dim, gen, files {abs path: mtime, size, rel, n, last_edited}
      vectors-<gen>.npy     float16 [chunks, dim], rows grouped by file
      meta-<gen>.jsonl      one line per row: path, rel, start, end, heading, preview, last_edited
    A commit writes the new generation files, then replaces manifest.json (atomic), then removes
    generations older than the previous one, so a reader never sees a half-written index."""

    def __init__(self, root, extras=(), client: OllamaClient | None = None, model: str | None = None):
        self.root = Path(root).expanduser().resolve()
        self.extras = [Path(x).expanduser().resolve() for x in (extras or []) if x]
        self.dir = self.root / INDEX_DIR
        self.client = client
        self.model = model or (client.model if client else DEFAULT_MODEL)
        self.manifest: dict = {}
        self.vecs: np.ndarray | None = None
        self.meta: list[dict] = []
        self.gen_loaded = None

    # ---- read side
    def roots(self) -> list[tuple[Path, str]]:
        out = [(self.root, "")]
        for x in self.extras:
            if x != self.root:
                out.append((x, x.name))
        return out

    def read_manifest(self) -> dict:
        try:
            m = json.loads((self.dir / "manifest.json").read_text(encoding="utf-8"))
            return m if isinstance(m, dict) else {}
        except Exception:  # noqa: BLE001
            return {}

    def load(self, force: bool = False) -> bool:
        """Load (or reload when the generation changed). False when there is no usable index."""
        for _ in range(3):
            m = self.read_manifest()
            if not m or m.get("version") != INDEX_VERSION:
                self.manifest, self.vecs, self.meta, self.gen_loaded = m or {}, None, [], None
                return False
            gen = m.get("gen")
            if gen == self.gen_loaded and not force:
                return True
            try:
                vecs = np.load(self.dir / f"vectors-{gen}.npy", mmap_mode="r") if m.get("chunks") else \
                    np.zeros((0, int(m.get("dim") or 0)), dtype=np.float16)
                meta = []
                if m.get("chunks"):
                    with open(self.dir / f"meta-{gen}.jsonl", encoding="utf-8") as f:
                        meta = [json.loads(l) for l in f if l.strip()]
                if len(meta) != len(vecs):
                    raise ValueError("meta and vectors differ")
            except Exception:  # noqa: BLE001   (a commit replaced the files under us: retry)
                time.sleep(0.1)
                continue
            self.manifest, self.vecs, self.meta, self.gen_loaded = m, vecs, meta, gen
            return True
        return False

    def counts(self) -> tuple[int, int]:
        m = self.manifest or self.read_manifest()
        return len(m.get("files") or {}), int(m.get("chunks") or 0)

    def search_vec(self, q, k: int = 5, min_score: float | None = None) -> list[dict]:
        if self.vecs is None or not len(self.meta):
            return []
        if self.vecs.shape[1] != len(q):
            return []
        out = []
        per_file: dict[str, int] = {}
        for i, s in topk(q, self.vecs, k * 3, min_score):
            r = dict(self.meta[i])
            if per_file.get(r["path"], 0) >= 2:       # at most 2 chunks of one file
                continue
            per_file[r["path"]] = per_file.get(r["path"], 0) + 1
            r["score"] = round(s, 4)
            out.append(r)
            if len(out) >= k:
                break
        return out

    def search(self, query: str, k: int = 5, timeout: float = 15.0) -> list[dict]:
        if not self.load():
            return []
        if self.manifest.get("model") != self.model:
            raise SemanticError(f"the index was built with {self.manifest.get('model')}, not {self.model}: run lt index --rebuild")
        q = self.client.embed([query], timeout=timeout)[0]
        return self.search_vec(q, k)

    # ---- write side
    def update(self, rebuild: bool = False, batch: int = 16, should_yield=None, yield_sleep: float = 0.5,
               pause_s: float = 0.0, max_chunks: int | None = None, stop=None, progress=None,
               lock_wait: float = 0.0, exclude: set[str] | None = None, timeout: float = 60.0) -> dict:
        """Index new and changed files (by mtime + size), drop removed ones, commit atomically.
        Files are processed newest first. Returns a summary dict; raises IndexBusy or SemanticError
        (work done before an embedding error is committed)."""
        t0 = time.time()
        summary = {"new": 0, "changed": 0, "removed": 0, "chunks_added": 0, "files": 0, "chunks": 0,
                   "remaining_files": 0, "seconds": 0.0, "committed": False}
        with IndexLock(self.dir, wait=lock_wait):
            self.load(force=True)
            m = self.manifest if not rebuild else {}
            if m and (m.get("model") != self.model):
                m = {}                                   # another model: start over
            old_files: dict = dict(m.get("files") or {})
            # Current rows per file (kept until a file is re-embedded).
            rows: dict[str, tuple[list[dict], np.ndarray]] = {}
            if m and self.vecs is not None and len(self.meta):
                start = 0
                order = []
                for i, r in enumerate(self.meta):
                    if i == 0 or r["path"] != self.meta[i - 1]["path"]:
                        order.append(i)
                order.append(len(self.meta))
                for a, b in zip(order, order[1:]):
                    rows[self.meta[a]["path"]] = (self.meta[a:b], np.asarray(self.vecs[a:b], dtype=np.float16))
                del start
            files_now = {}
            for ap, rel, st in iter_files(self.roots(), exclude):
                files_now[ap] = (rel, st)
            removed = [p for p in old_files if p not in files_now]
            todo = []
            for ap, (rel, st) in files_now.items():
                o = old_files.get(ap)
                if o and o.get("mtime") == st.st_mtime and o.get("size") == st.st_size:
                    continue
                todo.append((st.st_mtime, ap, rel, st, bool(o)))
            todo.sort(key=lambda x: -x[0])
            for p in removed:
                old_files.pop(p, None)
                rows.pop(p, None)
            summary["removed"] = len(removed)
            dim = int(m.get("dim") or 0) or None
            added = 0
            dirty = bool(removed) or (rebuild and bool(self.manifest))
            done_files = 0
            for n_done, (_mt, ap, rel, st, existed) in enumerate(todo):
                if stop is not None and stop.is_set():
                    break
                if max_chunks is not None and added >= max_chunks:
                    break
                text = read_doc(ap)
                info = {"mtime": st.st_mtime, "size": st.st_size, "rel": rel, "n": 0}
                if text is None:
                    old_files[ap] = info
                    rows.pop(ap, None)
                    dirty = True
                    done_files += 1
                    continue
                le = front_date(text)
                if le:
                    info["last_edited"] = le
                body = front_end(text)
                ch = [(s + body, e + body, h) for s, e, h in chunk_text(text[body:])]
                title = doc_title(rel)
                inputs = [f"{title}{' > ' + h if h else ''}\n{text[s:e].strip()}" for s, e, h in ch]
                vec_parts = []
                try:
                    for j in range(0, len(inputs), max(1, batch)):
                        while should_yield is not None and should_yield():
                            if stop is not None and stop.is_set():
                                break
                            time.sleep(yield_sleep)
                        if stop is not None and stop.is_set():
                            break
                        vec_parts.append(self.client.embed(inputs[j:j + batch], timeout=timeout, use_cache=False))
                        if pause_s:
                            time.sleep(pause_s)
                except SemanticError:
                    if dirty or added:
                        self._commit(old_files, rows, dim)
                    raise
                if stop is not None and stop.is_set() and len(vec_parts) * max(1, batch) < len(inputs):
                    break
                if ch:
                    v = np.concatenate(vec_parts).astype(np.float16)
                    dim = v.shape[1]
                    meta = [{"path": ap, "rel": rel, "start": s, "end": e, "heading": h,
                             "preview": preview(text[s:e]), "last_edited": le, "mtime": st.st_mtime}
                            for s, e, h in ch]
                    rows[ap] = (meta, v)
                else:
                    rows.pop(ap, None)
                info["n"] = len(ch)
                old_files[ap] = info
                added += len(ch)
                dirty = True
                done_files += 1
                summary["changed" if existed else "new"] += 1
                if progress:
                    progress(n_done + 1, len(todo), rel, len(ch))
            summary["chunks_added"] = added
            summary["remaining_files"] = len(todo) - done_files
            if dirty:
                self._commit(old_files, rows, dim)
                summary["committed"] = True
            elif not self.manifest:
                self._commit(old_files, rows, dim)       # an empty project: write an empty index
                summary["committed"] = True
            self.load(force=True)
        summary["files"], summary["chunks"] = self.counts()
        summary["seconds"] = round(time.time() - t0, 2)
        return summary

    def _commit(self, files: dict, rows: dict, dim: int | None) -> None:
        old = self.read_manifest()
        gen = int(old.get("gen") or 0) + 1
        order = [p for p in sorted(rows, key=lambda p: files.get(p, {}).get("rel", p)) if p in files]
        metas = [r for p in order for r in rows[p][0]]
        vecs = np.concatenate([rows[p][1] for p in order]).astype(np.float16) if order else \
            np.zeros((0, dim or 0), dtype=np.float16)
        if len(vecs):
            dim = int(vecs.shape[1])
        self.dir.mkdir(parents=True, exist_ok=True)
        _write_atomic_bytes(self.dir / f"vectors-{gen}.npy", lambda f: np.save(f, vecs))
        _write_atomic_bytes(self.dir / f"meta-{gen}.jsonl",
                            lambda f: f.write("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in metas).encode("utf-8")))
        man = {"version": INDEX_VERSION, "model": self.model, "dim": dim, "gen": gen, "root": str(self.root),
               "extras": [str(x) for x in self.extras], "chunks": len(metas), "files": files,
               "updated": dt.datetime.now().astimezone().isoformat(timespec="seconds")}
        _write_atomic_bytes(self.dir / "manifest.json",
                            lambda f: f.write(json.dumps(man, ensure_ascii=False).encode("utf-8")))
        for p in self.dir.glob("vectors-*.npy"):
            g = p.stem.split("-")[-1]
            if g.isdigit() and int(g) < gen - 1:
                for q in (p, self.dir / f"meta-{g}.jsonl"):
                    try:
                        q.unlink()
                    except OSError:
                        pass


# --------------------------------------------------------------------------- plain text fallback

def text_search(roots: list[tuple[Path, str]], query: str, k: int = 5) -> list[dict]:
    """Substring search (no model): score = query words found, phrase bonus; newest first on ties."""
    words = [w for w in re.findall(r"[\w'’-]{3,}", query.lower())]
    phrase = query.strip().lower()
    if not words and not phrase:
        return []
    hits = []
    for ap, rel, st in iter_files(roots):
        text = read_doc(ap)
        if not text:
            continue
        low = text.lower()
        score = sum(1 for w in set(words) if w in low)
        if phrase and len(phrase) > 3 and phrase in low:
            score += 3
        if not score:
            continue
        pos = low.find(phrase) if phrase in low else min((low.find(w) for w in words if w in low), default=0)
        a = max(0, pos - 80)
        hits.append({"path": ap, "rel": rel, "score": float(score), "start": a, "end": a + 260,
                     "preview": preview(text[a:a + 260]), "last_edited": front_date(text), "mtime": st.st_mtime})
    hits.sort(key=lambda h: (-h["score"], -h["mtime"]))
    return hits[:k]


def hit_date(h: dict) -> str:
    if h.get("last_edited"):
        return str(h["last_edited"])
    try:
        return dt.datetime.fromtimestamp(float(h.get("mtime"))).strftime("%Y-%m-%d")
    except Exception:  # noqa: BLE001
        return "?"
