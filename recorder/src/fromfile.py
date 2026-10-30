"""Transcribe a recording (Pacenote 0.8.6, rules/transcribe.yaml): a WAV file (16 kHz mono, decoded by the app)
becomes the same transcript as a call, with the same Whisper model, Whisper prompt and voices library.

Differences from a call: one channel (no "Me" from the microphone), faster than real time, and the voices are told
apart after the full pass (offline clustering), so the groups are better than live.

  transcriber.py --from-file <wav> --out <md> --langs uk [--project-dir DIR] [--slug S] [--speakers N]
                 [--title T] [--source file|link] [--source-ref REF] [--people "Ann Lee,Mike Johnson"]
  fromfile.py edit --md <md> (--name S2=Ann Lee | --merge S3=S1 | --fix 00:12:04=S2 | --remember S2=on|off)

Progress goes to stdout as JSON lines: {"stage": "...", "done_s": .., "total_s": .., "line": {...}}.
The run writes <stem>.md, <stem>.speakers.json and <stem>.named.md (the names applied)."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import wave
from pathlib import Path

import numpy as np

SR = 16000
FRAME = 480                 # 30 ms
MAX_SEG_S = 28.0            # Whisper's window is 30 s
GAP_S = 0.5                 # silence that ends a segment
MIN_SEG_S = 0.35


def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        ch, sw, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if sw == 2:
        a = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    elif sw == 4:
        a = np.frombuffer(raw, dtype="<i4").astype(np.float32) / 2147483648.0
    else:
        raise ValueError(f"unsupported sample width {sw}")
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    if rate != SR:              # the app writes 16 kHz; a plain resample for other WAVs
        x = np.arange(0, len(a), rate / SR)
        a = np.interp(x, np.arange(len(a)), a).astype(np.float32)
    return a


def segments(audio: np.ndarray, is_speech) -> list[tuple[int, int]]:
    """Speech spans (sample start, end): a span ends after GAP_S of silence or at MAX_SEG_S."""
    out, start, last = [], None, None
    gap = int(GAP_S * SR / FRAME)
    for i in range(0, len(audio) - FRAME + 1, FRAME):
        sp = is_speech(audio[i:i + FRAME])
        k = i // FRAME
        if sp:
            if start is None:
                start = i
            last = k
            if (i + FRAME - start) >= MAX_SEG_S * SR:
                out.append((start, i + FRAME)); start = None
        elif start is not None and last is not None and k - last > gap:
            out.append((start, (last + 1) * FRAME)); start = None
    if start is not None:
        out.append((start, len(audio)))
    pad = int(0.15 * SR)
    return [(max(0, a - pad), min(len(audio), b + pad)) for a, b in out if (b - a) >= MIN_SEG_S * SR]


def unit(v) -> np.ndarray:
    v = np.asarray(v, dtype=np.float32)
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


def cluster(embs: list, durs: list, n_speakers: int | None = None, join: float = 0.6, stop: float = 0.55) -> list[int]:
    """Offline speaker clustering. embs: unit vectors or None; returns a cluster index per item (-1 = no voice
    print). First a greedy pass into small groups (cosine >= join), then average-linkage merging of the groups:
    down to n_speakers when given, else while two groups are at least `stop` alike. Groups numbered by first use."""
    idx = [i for i, e in enumerate(embs) if e is not None]
    lab = [-1] * len(embs)
    if not idx:
        return lab
    groups: list[list[int]] = []
    cents: list[np.ndarray] = []
    for i in idx:
        e = unit(embs[i])
        if cents:
            sims = np.array([float(np.dot(e, c)) for c in cents])
            j = int(sims.argmax())
            if sims[j] >= join:
                groups[j].append(i)
                cents[j] = unit(np.mean([unit(embs[k]) for k in groups[j]], axis=0))
                continue
        groups.append([i]); cents.append(e)

    def weight(g):
        return sum(durs[k] for k in g)

    while len(groups) > 1:
        C = np.array(cents)
        S = C @ C.T
        np.fill_diagonal(S, -2)
        a, b = np.unravel_index(int(S.argmax()), S.shape)
        best = float(S[a, b])
        if n_speakers:
            if len(groups) <= n_speakers:
                break
        elif best < stop:
            break
        a, b = (a, b) if a < b else (b, a)
        groups[a] += groups[b]
        wa = np.mean([unit(embs[k]) for k in groups[a]], axis=0)
        cents[a] = unit(wa)
        del groups[b]; del cents[b]
    # tiny groups (under 3 s of speech, no fixed count) join the most alike bigger group
    if not n_speakers and len(groups) > 1:
        big = [g for g in range(len(groups)) if weight(groups[g]) >= 3.0] or list(range(len(groups)))
        for g in range(len(groups)):
            if g in big:
                continue
            j = max(big, key=lambda x: float(np.dot(cents[g], cents[x])))
            groups[j] += groups[g]; groups[g] = []
        keep = [g for g in groups if g]
        groups = keep
    order = sorted(range(len(groups)), key=lambda g: min(groups[g]))
    for n, g in enumerate(order):
        for k in groups[g]:
            lab[k] = n
    # lines without a voice print take the nearest line's speaker in time
    known = [i for i in range(len(lab)) if lab[i] >= 0]
    for i in range(len(lab)):
        if lab[i] < 0 and known:
            j = min(known, key=lambda k: abs(k - i))
            lab[i] = lab[j]
    return lab


def hms(sec: float) -> str:
    s = int(max(0, sec))
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def header(cfg: dict, title: str, source: str, ref: str, when: str, ui: str) -> str:
    langs = "+".join(cfg["langs"])
    if ui == "en":
        return (f"# Transcript: {title}\n\n- Project: {cfg.get('slug') or '-'}\n- Start: {when}\n"
                f"- Languages: allowed = {langs}\n- Model: {cfg['model']}\n- Channels: {cfg['them_label']} = the recording\n"
                f"- source: {source}\n- source_ref: {ref}\n\n")
    return (f"# Транскрипт: {title}\n\n- Проєкт: {cfg.get('slug') or '-'}\n- Початок: {when}\n"
            f"- Мови: дозволені = {langs}\n- Модель: {cfg['model']}\n- Канали: {cfg['them_label']} = запис\n"
            f"- source: {source}\n- source_ref: {ref}\n\n")


def snapshot_path(md: Path) -> Path:
    return md.with_name(md.stem + ".speakers.json")


def write_named(md: Path, snap: dict, T) -> Path:
    text = md.read_text(encoding="utf-8")
    cl, merged, over = snap.get("clusters") or {}, snap.get("merged") or {}, snap.get("overrides") or {}

    def resolve(s):
        seen = set()
        while s in merged and s not in seen:
            seen.add(s); s = merged[s]
        return s

    def label(t, sid):
        s = resolve(over.get(t) or sid)
        if not s:
            return None
        c = cl.get(s) or {}
        return T.speaker_display(s, c.get("name"))
    named = md.with_name(md.stem + ".named.md")
    named.write_text(T.apply_speaker_names(text, "", label), encoding="utf-8")
    return named


def run(args, T) -> int:
    """T is the transcriber module (Whisper, Vad, VoiceLibrary, load_embedder, DEFAULTS, ROOT)."""
    cfg = dict(T.DEFAULTS)
    try:
        cfg.update(json.loads((T.ROOT / "config.json").read_text(encoding="utf-8")))
    except Exception:  # noqa: BLE001
        pass
    langs = [l.strip() for l in (args.langs or "uk").replace("+", ",").split(",") if l.strip()]
    cfg["langs"] = langs
    if args.model:
        cfg["model"] = args.model
    cfg["slug"] = args.slug or ""
    people = [p.strip() for p in (args.people or "").split(",") if p.strip()]
    cfg["people"] = people
    cfg["title"] = args.title or Path(args.out).stem
    if args.prompt:
        cfg["prompt"] = args.prompt
    else:
        T.auto_prompt(cfg)
    ui = "en" if str(cfg.get("ui_lang") or args.ui_lang or "").lower().startswith("en") else "uk"
    if ui == "en":
        cfg["them_label"] = "Speaker"
    wav, out = Path(args.from_file), Path(args.out)
    emit({"stage": "prepare"})
    audio = T_read(wav)
    total = len(audio) / SR
    emit({"stage": "prepare", "done_s": 0, "total_s": round(total, 1)})
    try:
        whisper = T.FakeWhisper(cfg) if args.fake_whisper else T.Whisper(cfg)
    except Exception as e:  # noqa: BLE001
        emit({"stage": "error", "error": f"whisper load failed: {e!r}"}); return 1
    vad = T.Vad(int(cfg.get("vad_mode") or 2))
    spans = segments(audio, vad.is_speech)
    lines: list[dict] = []
    for a, b in spans:
        seg = audio[a:b]
        lang = whisper.pick_language(seg)
        text, lang = whisper.transcribe(seg, lang, cfg.get("prompt"))
        text = (text or "").strip()
        if text:
            ln = {"t": a / SR, "end": b / SR, "lang": lang or langs[0], "text": text}
            lines.append(ln)
            emit({"stage": "transcribe", "done_s": round(b / SR, 1), "total_s": round(total, 1),
                  "line": {"t": hms(ln["t"]), "text": text}})
        else:
            emit({"stage": "transcribe", "done_s": round(b / SR, 1), "total_s": round(total, 1)})
    emit({"stage": "speakers", "done_s": round(total, 1), "total_s": round(total, 1)})
    emb = None
    if not args.no_speakers:
        emb, reason = T.load_embedder(cfg)
        if emb is None:
            emit({"stage": "speakers", "note": reason})
    min_s = float(cfg.get("speaker_min_s") or 1.0)
    embs = []
    for ln in lines:
        d = ln["end"] - ln["t"]
        if emb is not None and d >= min_s:
            try:
                embs.append(unit(emb.embed(audio[int(ln["t"] * SR):int(ln["end"] * SR)])))
            except Exception:  # noqa: BLE001
                embs.append(None)
        else:
            embs.append(None)
    durs = [ln["end"] - ln["t"] for ln in lines]
    lab = cluster(embs, durs, args.speakers or None) if emb is not None else [0 if lines else -1] * len(lines)
    lib = None
    if emb is not None:
        lib = T.VoiceLibrary(T.ROOT / str(cfg.get("voices_dir") or "voices") / "voices.json", project=cfg["slug"],
                             team_names=people, remember=True, workspace=args.workspace or "")
    clusters: dict[str, dict] = {}
    for ln, k, e in zip(lines, lab, embs):
        sid = f"S{k + 1}" if k >= 0 else "S1"
        ln["sid"] = sid
        c = clusters.setdefault(sid, {"name": None, "seconds": 0.0, "first": hms(ln["t"]), "first_quote": None,
                                      "last_quote": None, "suggestions": [], "side": None, "how": None, "score": None,
                                      "sample": None, "_embs": []})
        c["seconds"] += ln["end"] - ln["t"]
        if c["first_quote"] is None and len(ln["text"].split()) >= 3:
            c["first_quote"] = {"t": hms(ln["t"]), "text": ln["text"][:200]}
        c["last_quote"] = {"t": hms(ln["t"]), "text": ln["text"][:200]}
        if c["sample"] is None and ln["end"] - ln["t"] >= 3:
            c["sample"] = {"start": round(ln["t"], 2), "end": round(min(ln["end"], ln["t"] + 5), 2)}
        if e is not None:
            c["_embs"].append(e)
    used: dict[str, tuple[str, float]] = {}
    auto = float(cfg.get("speaker_auto") or 0.72)
    for sid, c in clusters.items():
        c["seconds"] = round(c["seconds"], 1)
        if c["sample"] is None and c["last_quote"]:
            ln = next(l for l in lines if l["sid"] == sid)
            c["sample"] = {"start": round(ln["t"], 2), "end": round(min(ln["end"], ln["t"] + 5), 2)}
        cent = unit(np.mean(c["_embs"], axis=0)) if c["_embs"] else None
        c["centroid"] = [round(float(x), 5) for x in cent] if cent is not None else None
        c["embs"] = [[round(float(x), 5) for x in e] for e in c["_embs"][-10:]]
        del c["_embs"]
        if lib is not None and cent is not None:
            c["suggestions"] = lib.suggest(cent, float(cfg.get("speaker_suggest") or 0.5), limit=5)
            name, sc = lib.best(cent)
            if name and sc >= auto and (name not in used or used[name][1] < sc):
                if name in used:
                    clusters[used[name][0]].update(name=None, how=None, score=None)
                used[name] = (sid, sc)
                c.update(name=name, how="voice", score=round(sc, 2), side=lib.side(name) or None)
    when = args.when or dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(header(cfg, cfg["title"], args.source or "file", args.source_ref or wav.name, when, ui))
        for ln in lines:
            f.write(f"[{hms(ln['t'])}] {cfg['them_label']} [{ln['sid']}] ({ln['lang']}): {ln['text']}\n")
    snap = {"clusters": clusters, "roster": [], "overrides": {}, "merged": {}, "skipped": [], "rev": 1,
            "updated": dt.datetime.now().strftime("%H:%M:%S"), "source": args.source or "file",
            "remember": {sid: True for sid in clusters}}
    snapshot_path(out).write_text(json.dumps(snap, ensure_ascii=False, indent=1), encoding="utf-8")
    write_named(out, snap, T)
    emit({"stage": "done", "file": str(out), "lines": len(lines), "speakers": len(clusters), "total_s": round(total, 1)})
    return 0


def T_read(path: Path) -> np.ndarray:
    return read_wav(path)


def edit(argv, T) -> int:
    """Renames, merges, line fixes and "Remember this voice", applied to speakers.json; named.md is rewritten.
    A name with Remember on goes to the voices library (the same apply_call as on calls)."""
    ap = argparse.ArgumentParser(prog="fromfile.py edit")
    ap.add_argument("--md", required=True)
    ap.add_argument("--name", action="append", default=[])
    ap.add_argument("--merge", action="append", default=[])
    ap.add_argument("--fix", action="append", default=[])
    ap.add_argument("--remember", action="append", default=[])
    ap.add_argument("--side", action="append", default=[])
    ap.add_argument("--project", default="")
    ap.add_argument("--workspace", default="")
    a = ap.parse_args(argv)
    md = Path(a.md)
    sp = snapshot_path(md)
    snap = json.loads(sp.read_text(encoding="utf-8"))
    cl = snap.setdefault("clusters", {})
    for x in a.name:
        sid, _, name = x.partition("=")
        if sid in cl:
            name = name.strip()
            cl[sid].update(name=name or None, how="you" if name else None, score=None)
    for x in a.merge:
        src, _, dst = x.partition("=")
        if src in cl and dst in cl and src != dst:
            snap.setdefault("merged", {})[src] = dst
            cl[dst]["seconds"] = round(cl[dst]["seconds"] + cl[src]["seconds"], 1)
    for x in a.fix:
        t, _, sid = x.partition("=")
        snap.setdefault("overrides", {})[t] = sid
    for x in a.remember:
        sid, _, v = x.partition("=")
        snap.setdefault("remember", {})[sid] = v != "off"
    for x in a.side:
        sid, _, v = x.partition("=")
        if sid in cl and v in ("team", "client"):
            cl[sid]["side"] = v
    snap["rev"] = int(snap.get("rev") or 0) + 1
    # the voices library learns the named voices marked Remember (replacing this file's earlier contribution)
    cfg = dict(T.DEFAULTS)
    lib = T.VoiceLibrary(T.ROOT / str(cfg.get("voices_dir") or "voices") / "voices.json", project=a.project,
                         remember=True, workspace=a.workspace)
    desired, sides = {}, {}
    for sid, c in cl.items():
        if sid in (snap.get("merged") or {}) or not c.get("name") or not (snap.get("remember") or {}).get(sid, True):
            continue
        embs = list(c.get("embs") or [])
        for src, dst in (snap.get("merged") or {}).items():
            if dst == sid:
                embs += list((cl.get(src) or {}).get("embs") or [])
        if embs:
            desired.setdefault(c["name"], []).extend(embs[-10:])
            if c.get("side"):
                sides[c["name"]] = c["side"]
    prev = snap.get("lib_added") or {}
    try:
        if desired != prev:
            lib.apply_call(prev, desired, sides)
            lib.save()
            snap["lib_added"] = desired
    except Exception as e:  # noqa: BLE001
        print(f"voices: cannot update the library ({e!r})", file=sys.stderr)
    sp.write_text(json.dumps(snap, ensure_ascii=False, indent=1), encoding="utf-8")
    write_named(md, snap, T)
    emit({"ok": True, "rev": snap["rev"]})
    return 0


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import transcriber as _T  # noqa: E402
    if len(sys.argv) > 1 and sys.argv[1] == "edit":
        sys.exit(edit(sys.argv[2:], _T))
    print(__doc__)
    sys.exit(2)
