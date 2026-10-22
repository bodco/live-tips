"""Equivalence check: built-in engine (ONNX int8) vs Ollama bge-m3 on the same texts and on `lt search`.

  python -m livetips_m0.embed_equiv --builtin http://127.0.0.1:11435 --ollama http://127.0.0.1:11434 \
      --lt <python> <lt> --root <project_root> --out runs/embed-equiv.json
"""
from __future__ import annotations

import argparse, json, subprocess, time, urllib.request
import numpy as np

TEXTS = [
    "Коли буде готовий реліз платіжного модуля для клієнта?", "When is the release of the payment module?",
    "¿Cuándo es el lanzamiento del módulo de pagos?", "Давайте домовимось про дедлайн на наступний тиждень",
    "The client asked for a demo of the dashboard on Friday", "Хто відповідає за міграцію бази даних?",
    "We need to estimate the effort for the integration with the CRM", "Бюджет на квартал вже погоджений",
    "Can you share the updated roadmap?", "Тестувальники знайшли критичний баг у продакшені",
    "Our velocity dropped in the last sprint", "Привіт, мене чути?", "Let's take this offline",
    "Ризик: ключовий розробник іде у відпустку", "The contract renewal is due next month",
    "Pipedrive vs HubSpot comparison for the sales team", "Скільки годин ми витратили на цей тікет?",
    "Please send me the meeting notes", "Нам треба погодити скоуп другої фази", "OK, thanks, bye",
]
QUERIES = ["release date of the payment module", "бюджет і години команди", "CRM comparison Pipedrive HubSpot",
           "ризики проєкту", "deck presentation slides", "client feedback on the demo", "deployment to production",
           "наступні кроки після дзвінка"]


def embed(url, texts):
    req = urllib.request.Request(url + "/api/embed", data=json.dumps({"model": "bge-m3", "input": texts}).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=60) as r:
        v = np.array(json.load(r)["embeddings"], dtype=np.float32)
    return v / np.linalg.norm(v, axis=1, keepdims=True), time.monotonic() - t0


def lt_hits(lt, root, q, url, k=8):
    out = subprocess.run(lt + ["search", q, "--root", root, "-k", str(k), "--json", "--url", url],
                         capture_output=True, text=True, timeout=60).stdout
    i = out.find("{")
    d = json.loads(out[i:]) if i >= 0 else {}
    return [h.get("rel") or h.get("path") for h in d.get("hits", [])]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--builtin", default="http://127.0.0.1:11435")
    ap.add_argument("--ollama", default="http://127.0.0.1:11434")
    ap.add_argument("--lt", nargs=2)
    ap.add_argument("--root")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    b, tb = embed(a.builtin, TEXTS)
    o, to = embed(a.ollama, TEXTS)
    cos = (b * o).sum(1)
    sb, so = b @ b.T, o @ o.T
    iu = np.triu_indices(len(TEXTS), 1)
    pair_diff = np.abs(sb[iu] - so[iu])
    lat_b = [embed(a.builtin, [t])[1] * 1000 for t in TEXTS]
    lat_o = [embed(a.ollama, [t])[1] * 1000 for t in TEXTS]
    res = {"n": len(TEXTS), "self_cosine_min": float(cos.min()), "self_cosine_mean": float(cos.mean()),
           "pair_score_absdiff_mean": float(pair_diff.mean()), "pair_score_absdiff_max": float(pair_diff.max()),
           "one_text_ms_builtin_p50": float(np.median(lat_b)), "one_text_ms_ollama_p50": float(np.median(lat_o)),
           "batch20_s_builtin": tb, "batch20_s_ollama": to}
    if a.lt and a.root:
        rows = []
        for q in QUERIES:
            hb, ho = lt_hits(list(a.lt), a.root, q, a.builtin), lt_hits(list(a.lt), a.root, q, a.ollama)
            rows.append({"q": q, "top1_same": bool(hb[:1] == ho[:1]), "overlap_at_8": len(set(hb) & set(ho)),
                         "n_builtin": len(hb), "n_ollama": len(ho)})
        res["search"] = rows
        res["search_top1_same"] = sum(r["top1_same"] for r in rows)
        res["search_overlap_mean"] = float(np.mean([r["overlap_at_8"] for r in rows]))
    json.dump(res, open(a.out, "w"), ensure_ascii=False, indent=1)
    print(json.dumps(res, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
