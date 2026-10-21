"""Embedding engine benchmark for the local semantic layer (runs on the Mac).

Compares (a) Ollama bge-m3 (external service, as in live-transcriber v38) with (b) bge-m3 ONNX
inside the process (onnxruntime, CPU and CoreML execution providers, int8 and fp16), on the same
lines: latency per line (live path, one line per call), vector agreement with Ollama, memory, and
the interaction with Whisper (MLX) running at the same time: ASR time per segment alone vs with
embeddings, and embedding latency alone vs with ASR.

  python -m livetips_m0.embed_bench --texts runs/sem/candidates.jsonl --onnx-dir models/bge-m3-onnx \
      --whisper-python ~/work/Tools/live-transcriber/.venv/bin/python --out runs/bench
"""
import argparse
import json
import os
import random
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

import numpy as np


def pct(a, p):
    a = sorted(a)
    if not a:
        return None
    k = (len(a) - 1) * p
    f = int(k)
    c = min(f + 1, len(a) - 1)
    return round(a[f] + (a[c] - a[f]) * (k - f), 1)


def summ(ms):
    return {"n": len(ms), "p50_ms": pct(ms, .5), "p90_ms": pct(ms, .9), "max_ms": round(max(ms), 1) if ms else None}


def rss_mb(pid):
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return round(int(out) / 1024) if out else None
    except Exception:
        return None


def pids(name):
    out = subprocess.run(["pgrep", "-f", name], capture_output=True, text=True).stdout.split()
    return [int(x) for x in out]


def cpu_of(name):
    tot = 0.0
    for pid in pids(name):
        out = subprocess.run(["ps", "-o", "pcpu=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        try:
            tot += float(out)
        except ValueError:
            pass
    return tot


def wait_quiet(max_wait_s, log):
    """Wait until llama-server (Ollama runner) is idle, i.e. no background indexing."""
    t0 = time.time()
    while time.time() - t0 < max_wait_s:
        samples = []
        for _ in range(6):
            samples.append(cpu_of("llama-server"))
            time.sleep(5)
        avg = sum(samples) / len(samples)
        log("llama-server cpu avg over 30 s: {:.0f}%".format(avg))
        if avg < 15:
            return True, avg
    return False, avg


class Ollama:
    def __init__(self, url="http://127.0.0.1:11434", model="bge-m3"):
        self.url, self.model = url, model

    def embed(self, texts, timeout=5.0):
        body = json.dumps({"model": self.model, "input": texts, "keep_alive": "15m"}).encode()
        req = urllib.request.Request(self.url + "/api/embed", data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            v = np.asarray(json.loads(r.read())["embeddings"], dtype=np.float32)
        return v / np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-12)


class Onnx:
    def __init__(self, model_path, tok_path, providers):
        import onnxruntime as ort
        from tokenizers import Tokenizer
        so = ort.SessionOptions()
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        self.sess = ort.InferenceSession(str(model_path), so, providers=providers)
        self.tok = Tokenizer.from_file(str(tok_path))
        self.tok.enable_truncation(max_length=512)
        self.inputs = [i.name for i in self.sess.get_inputs()]
        self.providers = self.sess.get_providers()

    def embed(self, texts):
        self.tok.enable_padding()
        enc = self.tok.encode_batch(texts)
        ids = np.array([e.ids for e in enc], dtype=np.int64)
        mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in self.inputs:
            feed["token_type_ids"] = np.zeros_like(ids)
        out = self.sess.run(None, feed)[0]
        v = out[:, 0, :] if out.ndim == 3 else out          # bge-m3 dense = CLS token
        v = v.astype(np.float32)
        return v / np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-12)


WHISPER_WORKER = r'''
import sys, time, json, mlx_whisper
wav, model, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
mlx_whisper.transcribe(wav, path_or_hf_repo=model, language="uk")   # warm up and load
print("READY", flush=True)
for i in range(n):
    t0 = time.monotonic()
    mlx_whisper.transcribe(wav, path_or_hf_repo=model, language="uk")
    print(json.dumps({"i": i, "asr_s": round(time.monotonic() - t0, 3)}), flush=True)
    sys.stdin.readline()          # wait for the next go
'''


def make_audio(tmp, log):
    """6 s of synthetic Ukrainian speech, 16 kHz mono wav (macOS say + ffmpeg)."""
    aiff, wav = os.path.join(tmp, "a.aiff"), os.path.join(tmp, "a.wav")
    text = "Добрий день. Коли буде готовий реліз платіжного модуля і хто відповідає за тестування на наступному тижні?"
    voices = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    voice = "Lesya" if "Lesya" in voices else None
    cmd = ["say", "-o", aiff] + (["-v", voice] if voice else []) + [text]
    subprocess.run(cmd, check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", aiff, "-ar", "16000", "-ac", "1", wav], check=True)
    log("audio: voice {}".format(voice or "default"))
    return wav


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--texts", required=True)
    ap.add_argument("--onnx-dir", required=True, type=Path)
    ap.add_argument("--whisper-python")
    ap.add_argument("--whisper-model", default="mlx-community/whisper-large-v3-turbo")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--wait-quiet-s", type=int, default=5400)
    a = ap.parse_args(argv)
    a.out.mkdir(parents=True, exist_ok=True)
    logf = (a.out / "bench.log").open("a")

    def log(m):
        line = "{} {}".format(time.strftime("%H:%M:%S"), m)
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    res = {"started": time.strftime("%Y-%m-%d %H:%M:%S")}
    quiet, cpu = wait_quiet(a.wait_quiet_s, log)
    res["quiet"] = {"ok": quiet, "llama_server_cpu_pct": round(cpu)}
    texts = [json.loads(l)["text"] for l in open(a.texts, encoding="utf-8") if '"text"' in l]
    random.Random(5).shuffle(texts)
    texts = texts[:a.n]

    # (a) Ollama, live path: one line per call
    ol = Ollama()
    ol.embed(["warm up"])
    lat, vecs_ol = [], []
    for t in texts:
        t0 = time.monotonic()
        vecs_ol.append(ol.embed([t])[0])
        lat.append((time.monotonic() - t0) * 1000)
    res["ollama"] = summ(lat)
    res["ollama"]["llama_server_rss_mb"] = sum(rss_mb(p) or 0 for p in pids("llama-server"))
    log("ollama {}".format(res["ollama"]))
    V_ol = np.stack(vecs_ol)

    # (b) ONNX variants
    import onnxruntime as ort
    avail = ort.get_available_providers()
    res["onnx_providers_available"] = avail
    variants = []
    for fname in ("model_quantized.onnx", "model_fp16.onnx"):
        if (a.onnx_dir / fname).exists():
            variants.append((fname, ["CPUExecutionProvider"]))
            if "CoreMLExecutionProvider" in avail:
                variants.append((fname, ["CoreMLExecutionProvider", "CPUExecutionProvider"]))
    res["onnx"] = {}
    for fname, prov in variants:
        key = "{}|{}".format(fname, prov[0])
        try:
            rss0 = rss_mb(os.getpid())
            t0 = time.monotonic()
            m = Onnx(a.onnx_dir / fname, a.onnx_dir / "tokenizer.json", prov)
            load_s = time.monotonic() - t0
            m.embed(["warm up"])
            lat, vecs = [], []
            for t in texts:
                t0 = time.monotonic()
                vecs.append(m.embed([t])[0])
                lat.append((time.monotonic() - t0) * 1000)
            V = np.stack(vecs)
            agree = (V * V_ol).sum(1)
            r = summ(lat)
            r.update({"load_s": round(load_s, 1), "rss_delta_mb": (rss_mb(os.getpid()) or 0) - (rss0 or 0),
                      "providers": m.providers, "cos_to_ollama_p50": round(float(np.median(agree)), 4),
                      "cos_to_ollama_min": round(float(agree.min()), 4)})
            res["onnx"][key] = r
            log("onnx {} {}".format(key, r))
            del m
        except Exception as e:
            res["onnx"][key] = {"error": "{}: {}".format(type(e).__name__, str(e)[:300])}
            log("onnx {} error {}".format(key, e))

    # (c) Whisper together with embeddings
    if a.whisper_python and os.path.exists(os.path.expanduser(a.whisper_python)):
        tmp = tempfile.mkdtemp()
        try:
            wav = make_audio(tmp, log)
            wp = os.path.join(tmp, "w.py")
            open(wp, "w").write(WHISPER_WORKER)
            n = 12
            p = subprocess.Popen([os.path.expanduser(a.whisper_python), wp, wav, a.whisper_model, str(3 * n)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            while True:
                line = p.stdout.readline()
                if not line or line.startswith("READY"):
                    break
            res["whisper_rss_mb"] = rss_mb(p.pid)

            def asr_round(k):
                out = []
                for _ in range(k):
                    out.append(json.loads(p.stdout.readline())["asr_s"])
                    p.stdin.write("\n")
                    p.stdin.flush()
                return out
            alone = asr_round(n)

            def with_load(embed_fn):
                stop = threading.Event()
                lat = []

                def loader():
                    i = 0
                    while not stop.is_set():
                        t0 = time.monotonic()
                        try:
                            embed_fn([texts[i % len(texts)]])
                            lat.append((time.monotonic() - t0) * 1000)
                        except Exception:
                            pass
                        i += 1
                        time.sleep(0.3)        # busier than a live call (a line every few seconds)
                th = threading.Thread(target=loader, daemon=True)
                th.start()
                asr = asr_round(n)
                stop.set()
                th.join(5)
                return asr, lat
            with_ol, ol_lat = with_load(ol.embed)
            onnx_int8 = Onnx(a.onnx_dir / "model_quantized.onnx", a.onnx_dir / "tokenizer.json", ["CPUExecutionProvider"])
            with_ox, ox_lat = with_load(onnx_int8.embed)
            p.stdin.close()
            p.wait(30)
            ms = lambda xs: [x * 1000 for x in xs]
            res["asr_with_embeddings"] = {
                "asr_alone": summ(ms(alone)), "asr_with_ollama": summ(ms(with_ol)), "asr_with_onnx_int8_cpu": summ(ms(with_ox)),
                "ollama_while_asr": summ(ol_lat), "onnx_int8_cpu_while_asr": summ(ox_lat)}
            log("asr {}".format(res["asr_with_embeddings"]))
        except Exception as e:
            res["asr_with_embeddings"] = {"error": "{}: {}".format(type(e).__name__, str(e)[:300])}
            log("asr error {}".format(e))
    try:
        res["ollama_ps"] = subprocess.run(["ollama", "ps"], capture_output=True, text=True, timeout=5).stdout
        vm = subprocess.run(["memory_pressure"], capture_output=True, text=True, timeout=10).stdout.strip().splitlines()[-1:]
        res["memory_pressure"] = vm
    except Exception:
        pass
    res["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
    (a.out / "bench.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    log("done")


if __name__ == "__main__":
    main()
