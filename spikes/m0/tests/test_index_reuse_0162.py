"""0.16.2 hotfix: a changed file re-embeds only the chunks whose text changed; a moved file re-embeds none."""
import importlib.util
import json
import zlib
from pathlib import Path

import pytest

np = pytest.importorskip("numpy")
SRC = Path(__file__).resolve().parents[3] / "recorder" / "src" / "semantic.py"


def semantic():
    spec = importlib.util.spec_from_file_location("semantic_0162", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeClient:
    model = "bge-m3"

    def __init__(self):
        self.texts = []

    def embed(self, texts, timeout=None, use_cache=True):
        self.texts += list(texts)
        out = np.zeros((len(texts), 32), dtype=np.float32)
        for i, t in enumerate(texts):
            out[i, zlib.crc32(t.encode()) % 32] = 1.0
        return out


def doc(sections):
    return "".join(f"## Section {n}\n" + (f"{body} " * 40) + "\n\n" for n, body in sections)


SECTIONS = [(i, f"Mike and Emily agreed on item {i} for the Orbit rollout") for i in range(6)]


def build(tmp_path):
    sem = semantic()
    (tmp_path / "notes.md").write_text(doc(SECTIONS), encoding="utf-8")
    client = FakeClient()
    idx = sem.ProjectIndex(tmp_path, client=client)
    first = idx.update()
    return sem, idx, client, first


def test_unchanged_chunks_are_reused(tmp_path):
    sem, idx, client, first = build(tmp_path)
    total = first["chunks_added"]
    assert total >= 3 and first["chunks_reused"] == 0
    before = {m["h"]: np.asarray(v) for m, v in zip(idx.meta, idx.vecs)}
    changed = list(SECTIONS)
    changed[2] = (2, "Emily moved item 2 to the next sprint")
    (tmp_path / "notes.md").write_text(doc(changed), encoding="utf-8")
    client.texts.clear()
    res = idx.update()
    assert res["changed"] == 1
    assert 1 <= res["chunks_added"] < total, "only the edited section is embedded again"
    assert res["chunks_added"] + res["chunks_reused"] == idx.counts()[1]
    assert all("item 2 to the next sprint" in t for t in client.texts)
    for m, v in zip(idx.meta, idx.vecs):           # reused rows keep their vectors
        if m["h"] in before:
            assert np.array_equal(before[m["h"]], np.asarray(v))


def test_moved_file_embeds_nothing(tmp_path):
    sem, idx, client, first = build(tmp_path)
    (tmp_path / "archive").mkdir()
    (tmp_path / "notes.md").rename(tmp_path / "archive" / "notes.md")
    client.texts.clear()
    res = idx.update()
    assert res["new"] == 1 and res["removed"] == 1
    assert res["chunks_added"] == 0 and res["chunks_reused"] == first["chunks_added"]
    assert client.texts == []
    assert {m["rel"] for m in idx.meta} == {"archive/notes.md"}


def test_rebuild_embeds_everything(tmp_path):
    sem, idx, client, first = build(tmp_path)
    client.texts.clear()
    res = idx.update(rebuild=True)
    assert res["chunks_added"] == first["chunks_added"] and res["chunks_reused"] == 0


def test_index_written_before_0162_pays_once(tmp_path):
    sem, idx, client, first = build(tmp_path)
    gen = idx.manifest["gen"]
    meta = idx.dir / f"meta-{gen}.jsonl"
    rows = [json.loads(l) for l in meta.read_text(encoding="utf-8").splitlines()]
    meta.write_text("".join(json.dumps({k: v for k, v in r.items() if k != "h"}) + "\n" for r in rows), encoding="utf-8")
    idx.load(force=True)
    p = tmp_path / "notes.md"
    p.write_text(p.read_text(encoding="utf-8") + "\n", encoding="utf-8")
    res = idx.update()
    assert res["chunks_reused"] == 0, "old rows carry no hash: the first change re-embeds the file"
    p.write_text(p.read_text(encoding="utf-8") + "\n", encoding="utf-8")
    assert idx.update()["chunks_added"] == 0, "after that the hashes are there"
