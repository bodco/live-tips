"""Built-in local embedding engine for Live Tips (bge-m3 int8, ONNX Runtime, CPU).

Serves the small part of the Ollama HTTP API the recorder core and `lt` use, so the core needs no
code change: it only points `ollama_url` at this server.

  GET  /api/version   -> {"version": "livetips-embedded-1"}
  GET  /api/tags      -> {"models": [{"name": "bge-m3:latest"}]}
  GET  /api/ps        -> {"models": [{"name": "bge-m3", "size": <rss bytes>}]}
  POST /api/embed     {"model", "input": str | [str]} -> {"model", "embeddings": [[...]]}
  POST /api/embeddings {"model", "prompt": str}      -> {"embedding": [...]}

Listens on 127.0.0.1 only. Text in, vectors out; nothing leaves the Mac.

  python -m livetips_m0.embed_server --model-dir <dir with model_quantized.onnx and tokenizer.json> [--port 11435]
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

VERSION = "livetips-embedded-1"
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


def make_handler(engine: Engine):
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
            if self.path == "/api/version":
                return self._send(200, {"version": VERSION})
            if self.path == "/api/tags":
                return self._send(200, {"models": [{"name": MODEL_NAME + ":latest", "model": MODEL_NAME + ":latest"}]})
            if self.path == "/api/ps":
                return self._send(200, {"models": [{"name": MODEL_NAME, "size": rss_bytes(), "size_vram": 0}]})
            return self._send(404, {"error": "not found"})

        def do_POST(self):
            try:
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
            except Exception:
                return self._send(400, {"error": "bad json"})
            model = str(body.get("model") or MODEL_NAME).split(":")[0]
            if model != MODEL_NAME:
                return self._send(404, {"error": f"model \"{model}\" not found, the built-in engine has only {MODEL_NAME}"})
            if self.path == "/api/embed":
                inp = body.get("input")
                texts = [inp] if isinstance(inp, str) else [str(t) for t in (inp or [])]
                t0 = time.monotonic()
                v = engine.embed(texts)
                return self._send(200, {"model": MODEL_NAME, "embeddings": v.tolist(),
                                        "total_duration": int((time.monotonic() - t0) * 1e9)})
            if self.path == "/api/embeddings":
                v = engine.embed([str(body.get("prompt") or "")])
                return self._send(200, {"embedding": v[0].tolist()})
            return self._send(404, {"error": "not found"})
    return H


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True, type=Path)
    ap.add_argument("--port", type=int, default=11435)
    ap.add_argument("--threads", type=int, default=int(os.environ.get("LT_EMBED_THREADS", "4")))
    a = ap.parse_args(argv)
    t0 = time.monotonic()
    engine = Engine(a.model_dir, a.threads)
    engine.embed(["warm up"])
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(engine))
    print(json.dumps({"ready": True, "port": a.port, "load_s": round(time.monotonic() - t0, 2), "version": VERSION}), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
