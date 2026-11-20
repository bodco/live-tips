"""Built-in local embedding engine for Live Tips (bge-m3 int8, ONNX Runtime, CPU).

Serves the small part of the Ollama HTTP API the recorder core and `lt` use, so the core needs no
code change: it only points `ollama_url` at this server.

  GET  /api/version   -> {"version": "livetips-embedded-1"}
  GET  /api/tags      -> {"models": [{"name": "bge-m3:latest"}]}
  GET  /api/ps        -> {"models": [{"name": "bge-m3", "size": <rss bytes>}]}
  GET  /api/keepalive -> {"ok": true}   (0.26.3: counts as use, the app sends it during a call)
  POST /api/embed     {"model", "input": str | [str]} -> {"model", "embeddings": [[...]]}
  POST /api/embeddings {"model", "prompt": str}      -> {"embedding": [...]}

Listens on 127.0.0.1 only. Text in, vectors out; nothing leaves the Mac.

  python -m livetips_m0.embed_server --model-dir <dir with model_quantized.onnx and tokenizer.json> [--port 11435]
                                     [--idle-exit <seconds>]

0.26.3 (owner, 20.11): with --idle-exit the server quits after that many seconds without an embedding request or a
keepalive (status calls such as /api/version do not count), so the model does not hold memory and CPU for days after a
call. It binds the port before it loads the model: a second copy started at the same moment exits at once instead of
loading the model twice. The app and the recorder core start it again when they need it (semantic.wake_builtin).
"""
from __future__ import annotations

import argparse
import json
import os
import resource
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np

VERSION = "livetips-embedded-2"     # 2: /api/version also gives pid and idle_exit_s, /api/keepalive
MODEL_NAME = "bge-m3"
BATCH = 16


class Engine:
    def __init__(self, model_dir: Path, threads: int = 0):
        import onnxruntime as ort
        from tokenizers import Tokenizer
        model = model_dir / "model_quantized.onnx"
        if not model.exists():
            raise SystemExit(f"model not found: {model}")
        so = ort.SessionOptions()
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        if threads:
            so.intra_op_num_threads = threads
        self.sess = ort.InferenceSession(str(model), so, providers=["CPUExecutionProvider"])
        self.tok = Tokenizer.from_file(str(model_dir / "tokenizer.json"))
        self.tok.enable_truncation(max_length=512)
        self.tok.enable_padding()
        self.inputs = [i.name for i in self.sess.get_inputs()]
        self.lock = threading.Lock()

    def _run(self, texts: list[str]) -> np.ndarray:
        enc = self.tok.encode_batch(texts)
        ids = np.array([e.ids for e in enc], dtype=np.int64)
        mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in self.inputs:
            feed["token_type_ids"] = np.zeros_like(ids)
        out = self.sess.run(None, feed)[0]
        v = (out[:, 0, :] if out.ndim == 3 else out).astype(np.float32)   # bge-m3 dense = CLS token
        return v / np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-12)

    def embed(self, texts: list[str]) -> np.ndarray:
        # Short texts first in each batch keeps padding small (live queries are one short line).
        order = sorted(range(len(texts)), key=lambda i: len(texts[i]))
        res: list[np.ndarray | None] = [None] * len(texts)
        with self.lock:
            for s in range(0, len(order), BATCH):
                idx = order[s:s + BATCH]
                vec = self._run([texts[i] or " " for i in idx])
                for j, i in enumerate(idx):
                    res[i] = vec[j]
        return np.stack(res) if res else np.zeros((0, 1024), dtype=np.float32)


def rss_bytes() -> int:
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(r if sys.platform == "darwin" else r * 1024)


class Activity:
    """When the server was last used (an embedding request or a keepalive)."""

    def __init__(self, idle_exit_s: float = 0.0):
        self.idle_exit_s = float(idle_exit_s or 0)
        self.last = time.monotonic()

    def touch(self) -> None:
        self.last = time.monotonic()

    def idle_for(self) -> float:
        return time.monotonic() - self.last

    def expired(self) -> bool:
        return self.idle_exit_s > 0 and self.idle_for() >= self.idle_exit_s


GET_ROUTES = {
    "/api/version": lambda: {"version": VERSION},
    "/api/tags": lambda: {"models": [{"name": MODEL_NAME + ":latest", "model": MODEL_NAME + ":latest"}]},
    "/api/ps": lambda: {"models": [{"name": MODEL_NAME, "size": rss_bytes(), "size_vram": 0}]},
}


def post_reply(engine, path: str, body):
    """(HTTP code, JSON reply) for an Ollama-style embedding request."""
    if not isinstance(body, dict):
        return 400, {"error": "bad json"}
    model = str(body.get("model") or MODEL_NAME).split(":")[0]
    if model != MODEL_NAME:
        return 404, {"error": f"model \"{model}\" not found, the built-in engine has only {MODEL_NAME}"}
    if path == "/api/embed":
        inp = body.get("input")
        texts = [inp] if isinstance(inp, str) else [str(t) for t in (inp or [])]
        t0 = time.monotonic()
        v = engine.embed(texts)
        return 200, {"model": MODEL_NAME, "embeddings": v.tolist(), "total_duration": int((time.monotonic() - t0) * 1e9)}
    if path == "/api/embeddings":
        return 200, {"embedding": engine.embed([str(body.get("prompt") or "")])[0].tolist()}
    return 404, {"error": "not found"}


def make_handler(engine, activity: "Activity | None" = None):
    act = activity or Activity()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):  # quiet: no request text in logs
            pass

        def _send(self, code: int, obj: dict):
            b = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            if self.path == "/api/keepalive":
                act.touch()
                return self._send(200, {"ok": True})
            if self.path == "/api/version":
                return self._send(200, {"version": VERSION, "pid": os.getpid(), "idle_exit_s": act.idle_exit_s})
            get = GET_ROUTES.get(self.path)
            return self._send(200, get()) if get else self._send(404, {"error": "not found"})

        def do_POST(self):
            act.touch()
            try:
                code, obj = post_reply(engine, self.path, self._body())
            finally:
                act.touch()                 # a long batch counts until it ends
            return self._send(code, obj)

        def _body(self):
            try:
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n) or b"{}")
            except Exception:  # noqa: BLE001
                return None
    return H


class _Later:
    """The engine, set after the port is bound (requests wait in the listen queue until then)."""

    def __init__(self):
        self.engine = None

    def embed(self, texts):
        return self.engine.embed(texts)


def watch_idle(srv, activity: Activity, check_s: float = 15.0) -> threading.Thread:
    """Stops the server once `activity` has expired (0.26.3)."""
    def loop():
        while True:
            time.sleep(check_s)
            if activity.expired():
                print(json.dumps({"idle_exit": True, "idle_s": round(activity.idle_for())}), flush=True)
                srv.shutdown()
                return
    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return t


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True, type=Path)
    ap.add_argument("--port", type=int, default=11435)
    ap.add_argument("--threads", type=int, default=int(os.environ.get("LT_EMBED_THREADS", "4")))
    ap.add_argument("--idle-exit", type=float, default=float(os.environ.get("LT_EMBED_IDLE_EXIT", "0")),
                    help="quit after this many seconds without use; 0 = never")
    a = ap.parse_args(argv)
    t0 = time.monotonic()
    later, activity = _Later(), Activity(a.idle_exit)
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(later, activity))
    except OSError as e:            # another copy already serves the port: nothing to do
        print(json.dumps({"ready": False, "port": a.port, "error": "port in use (%s)" % e.strerror}), flush=True)
        return 0
    later.engine = Engine(a.model_dir, a.threads)
    later.engine.embed(["warm up"])
    activity.touch()
    if activity.idle_exit_s > 0:
        watch_idle(srv, activity)
    print(json.dumps({"ready": True, "port": a.port, "load_s": round(time.monotonic() - t0, 2), "version": VERSION,
                      "pid": os.getpid(), "idle_exit_s": activity.idle_exit_s}), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
