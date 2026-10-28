"""The built-in embedding server's HTTP side with a fake engine (no model files needed)."""
import json
import threading
import urllib.error
import urllib.request

import pytest

np = pytest.importorskip("numpy")
from livetips_m0 import embed_server as E  # noqa: E402


class FakeEngine:
    def __init__(self):
        self.seen = []

    def embed(self, texts):
        self.seen.append(texts)
        return np.array([[float(len(t)), 1.0] for t in texts], dtype=np.float32)


@pytest.fixture
def server():
    eng = FakeEngine()
    srv = E.ThreadingHTTPServer(("127.0.0.1", 0), E.make_handler(eng))
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    base = "http://127.0.0.1:%d" % srv.server_address[1]

    def call(path, body=None, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(base + path, data=data, method="POST" if data is not None else "GET")
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())
    yield call, eng
    srv.shutdown()


def test_get_routes(server):
    call, _ = server
    assert call("/api/version") == (200, {"version": E.VERSION})
    assert call("/api/tags")[1]["models"][0]["name"] == "bge-m3:latest"
    code, ps = call("/api/ps")
    assert code == 200 and ps["models"][0]["size"] > 0
    assert call("/nope")[0] == 404


def test_post_routes(server):
    call, eng = server
    code, r = call("/api/embed", {"model": "bge-m3:latest", "input": ["ab", "c"]})
    assert code == 200 and r["embeddings"] == [[2.0, 1.0], [1.0, 1.0]] and r["model"] == "bge-m3"
    assert call("/api/embed", {"input": "abc"})[1]["embeddings"] == [[3.0, 1.0]]
    assert call("/api/embed", {"input": None})[1]["embeddings"] == []
    assert call("/api/embeddings", {"prompt": "abcd"}) == (200, {"embedding": [4.0, 1.0]})
    assert call("/api/embeddings", {}) == (200, {"embedding": [0.0, 1.0]})
    assert call("/api/embed", {"model": "other", "input": "x"})[0] == 404
    assert call("/api/other", {"input": "x"})[0] == 404
    assert call("/api/embed", raw=b"{bad")[0] == 400


def test_embed_orders_short_texts_first_in_batches():
    eng = E.Engine.__new__(E.Engine)
    eng.lock = threading.Lock()
    batches = []

    def run(texts):
        batches.append(texts)
        return np.array([[float(len(t))] for t in texts], dtype=np.float32)
    eng._run = run
    texts = ["x" * n for n in range(20, 0, -1)] + [""]
    out = E.Engine.embed(eng, texts)
    assert [b[0] for b in batches] == [" ", "x" * 16] and len(batches[0]) == E.BATCH
    assert out[:, 0].tolist() == [float(n) for n in range(20, 0, -1)] + [1.0]
    assert E.Engine.embed(eng, []).shape == (0, 1024)


def test_engine_with_fake_runtime(tmp_path, monkeypatch):
    import sys
    import types
    calls = {}

    class Sess:
        def __init__(self, path, so, providers):
            calls["init"] = (path, so.intra_op_num_threads, providers)

        def get_inputs(self):
            return [types.SimpleNamespace(name=n) for n in ("input_ids", "attention_mask", "token_type_ids")]

        def run(self, _, feed):
            calls["feed"] = sorted(feed)
            n = feed["input_ids"].shape[0]
            return [np.ones((n, 3, 4), dtype=np.float32) * 2]

    class Tok:
        @staticmethod
        def from_file(p):
            calls["tok"] = p
            return Tok()

        def enable_truncation(self, max_length):
            pass

        def enable_padding(self):
            pass

        def encode_batch(self, texts):
            return [types.SimpleNamespace(ids=[1, 2], attention_mask=[1, 1]) for _ in texts]
    ort = types.SimpleNamespace(SessionOptions=lambda: types.SimpleNamespace(intra_op_num_threads=0, graph_optimization_level=None),
                                GraphOptimizationLevel=types.SimpleNamespace(ORT_ENABLE_ALL=99), InferenceSession=Sess)
    monkeypatch.setitem(sys.modules, "onnxruntime", ort)
    monkeypatch.setitem(sys.modules, "tokenizers", types.SimpleNamespace(Tokenizer=Tok))
    with pytest.raises(SystemExit):
        E.Engine(tmp_path)
    (tmp_path / "model_quantized.onnx").write_text("")
    eng = E.Engine(tmp_path, threads=2)
    assert calls["init"][1] == 2 and calls["init"][2] == ["CPUExecutionProvider"]
    v = eng.embed(["a", "bb"])
    assert calls["feed"] == ["attention_mask", "input_ids", "token_type_ids"]
    assert v.shape == (2, 4) and abs(float(np.linalg.norm(v[0])) - 1.0) < 1e-6
