"""ASR benchmark: MLX Whisper (live-transcriber) vs WhisperKit CLI on the same audio.

Synthetic fixtures (macOS `say`, uk/en/es meeting sentences with known text) give an exact
reference for WER; real recordings can be added later with a manifest of the same shape.

  python -m livetips_m0.asr_bench gen   --out runs/asr
  python -m livetips_m0.asr_bench mlx   --out runs/asr --python <live-transcriber venv python>
  python -m livetips_m0.asr_bench wk    --out runs/asr [--model large-v3-v20240930_turbo]
  python -m livetips_m0.asr_bench score --out runs/asr
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

SENTENCES = {
    "uk": [
        "Добрий день, давайте почнемо з короткого статусу по спринту.",
        "Реліз платіжного модуля переноситься на наступний вівторок.",
        "Олег закінчив інтеграцію з банком, але тести ще не пройдені.",
        "Скільки годин потрібно на виправлення помилки в дашборді?",
        "Оцінку дасть розробник після того, як подивиться логи.",
        "Клієнт просить додати експорт звіту в форматі таблиці.",
        "Ми не погоджуємо нові вимоги без перевірки обсягу робіт.",
        "Хто відповідає за деплой на продакшн у п'ятницю?",
        "Тікет з авторизацією досі висить у статусі на перевірці.",
        "Давайте зафіксуємо: Марта готує документацію до середи.",
        "Бюджет на третій етап ще не затверджений фінансовим відділом.",
        "У мене питання щодо доступів до тестового середовища.",
        "Ризик у тому, що постачальник не встигне до кінця місяця.",
        "Пропоную винести це обговорення на окремий дзвінок.",
        "Демо для клієнта заплановане на двадцять шосте жовтня о сьомій вечора.",
        "Чи можемо ми зменшити обсяг першої фази, щоб встигнути?",
        "Метрики показують, що швидкість команди впала на двадцять відсотків.",
        "Я надішлю підсумок зустрічі в чат одразу після дзвінка.",
    ],
    "en": [
        "Good morning everyone, let's start with a quick sprint status.",
        "The payment module release moves to next Tuesday.",
        "Oleg finished the bank integration, but the tests have not passed yet.",
        "How many hours do we need to fix the dashboard bug?",
        "The developer will give an estimate after checking the logs.",
        "The client asks us to add a spreadsheet export for the report.",
        "We do not agree to new requirements without checking the scope.",
        "Who is responsible for the production deployment on Friday?",
        "The authorization ticket is still stuck in review.",
        "Let's fix it: Marta prepares the documentation by Wednesday.",
        "The budget for phase three is not approved by finance yet.",
        "I have a question about access to the staging environment.",
        "The risk is that the vendor will not make it by the end of the month.",
        "I suggest we move this discussion to a separate call.",
        "The client demo is planned for October twenty sixth at seven pm.",
        "Can we reduce the scope of the first phase to make the deadline?",
        "The metrics show that team velocity dropped by twenty percent.",
        "I will send the meeting summary to the chat right after the call.",
    ],
    "es": [
        "Buenos días a todos, empecemos con un breve estado del sprint.",
        "El lanzamiento del módulo de pagos pasa al próximo martes.",
        "Oleg terminó la integración con el banco, pero las pruebas no han pasado.",
        "¿Cuántas horas necesitamos para corregir el error del panel?",
        "El desarrollador dará una estimación después de revisar los registros.",
        "El cliente pide añadir una exportación del informe a hoja de cálculo.",
        "No aceptamos nuevos requisitos sin revisar el alcance.",
        "¿Quién es responsable del despliegue a producción el viernes?",
        "El ticket de autorización sigue atascado en revisión.",
        "Dejémoslo claro: Marta prepara la documentación para el miércoles.",
        "El presupuesto de la fase tres aún no está aprobado por finanzas.",
        "Tengo una pregunta sobre el acceso al entorno de pruebas.",
        "El riesgo es que el proveedor no llegue a fin de mes.",
        "Propongo mover esta discusión a una llamada aparte.",
        "La demo para el cliente está prevista para el veintiséis de octubre a las siete de la tarde.",
        "¿Podemos reducir el alcance de la primera fase para cumplir el plazo?",
        "Las métricas muestran que la velocidad del equipo bajó un veinte por ciento.",
        "Enviaré el resumen de la reunión al chat justo después de la llamada.",
    ],
}
VOICES = {"uk": ["Lesya"], "en": ["Samantha", "Eddy (English (US))"], "es": ["Eddy (Spanish (Spain))", "Flo (Spanish (Mexico))"]}


def norm_words(t):
    t = unicodedata.normalize("NFC", t.lower()).replace("ʼ", "'").replace("’", "'")
    t = re.sub(r"[^\w' ]+", " ", t)
    return t.split()


def wer(ref, hyp):
    r, h = norm_words(ref), norm_words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev = cur
    return d[len(h)], len(r)


def cmd_gen(a):
    out = Path(a.out)
    avail = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    man = []
    for lang, sents in SENTENCES.items():
        d = out / "audio" / lang
        d.mkdir(parents=True, exist_ok=True)
        voices = [v for v in VOICES[lang] if v.split(" (")[0] in avail] or [None]
        for i, s in enumerate(sents):
            v = voices[i % len(voices)]
            base = d / "{}-{:02d}".format(lang, i)
            cmd = ["say", "-o", str(base) + ".aiff"] + (["-v", v] if v else []) + [s]
            subprocess.run(cmd, check=True)
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(base) + ".aiff", "-ar", "16000", "-ac", "1",
                            str(base) + ".wav"], check=True)
            os.remove(str(base) + ".aiff")
            dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                        str(base) + ".wav"], capture_output=True, text=True).stdout.strip() or 0)
            man.append({"lang": lang, "voice": v, "text": s, "wav": str(base) + ".wav", "dur": round(dur, 2)})
    (out / "manifest.jsonl").write_text("\n".join(json.dumps(m, ensure_ascii=False) for m in man) + "\n")
    print("generated", len(man))


MLX_WORKER = r'''
import json, sys, time, resource, mlx_whisper
man, model, out = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [json.loads(l) for l in open(man) if l.strip()]
mlx_whisper.transcribe(rows[0]["wav"], path_or_hf_repo=model, language=rows[0]["lang"])
with open(out, "w") as f:
    for r in rows:
        t0 = time.monotonic()
        res = mlx_whisper.transcribe(r["wav"], path_or_hf_repo=model, language=r["lang"], condition_on_previous_text=False)
        f.write(json.dumps({"wav": r["wav"], "text": res["text"].strip(), "s": round(time.monotonic() - t0, 3)}, ensure_ascii=False) + "\n")
print("peak_rss_mb", resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // (1024 * 1024))
'''


def cmd_mlx(a):
    out = Path(a.out)
    w = out / "mlx_worker.py"
    w.write_text(MLX_WORKER)
    t0 = time.monotonic()
    p = subprocess.run([os.path.expanduser(a.python), str(w), str(out / "manifest.jsonl"), a.model, str(out / "mlx.jsonl")],
                       capture_output=True, text=True)
    (out / "mlx.log").write_text(p.stdout + p.stderr)
    print("mlx done in", round(time.monotonic() - t0, 1), "s", p.stdout.strip()[-80:])


def cmd_wk(a):
    out = Path(a.out)
    rows = [json.loads(l) for l in (out / "manifest.jsonl").read_text().splitlines() if l.strip()]
    rep = out / "wk_reports"
    rep.mkdir(exist_ok=True)
    res = []
    model_dir = out / "wk_models"
    for lang in ("uk", "en", "es"):
        for r in [x for x in rows if x["lang"] == lang]:
            t0 = time.monotonic()
            cmd = ["whisperkit-cli", "transcribe", "--audio-path", r["wav"], "--model", a.model, "--language", lang,
                   "--download-model-path", str(model_dir), "--download-tokenizer-path", str(model_dir),
                   "--report", "--report-path", str(rep), "--without-timestamps", "--skip-special-tokens"]
            p = subprocess.run(cmd, capture_output=True, text=True)
            wall = time.monotonic() - t0
            stem = Path(r["wav"]).stem
            text, pipeline = None, None
            for jf in rep.glob(stem + "*.json"):
                try:
                    j = json.loads(jf.read_text())
                    text = j.get("text") or " ".join(s.get("text", "") for s in j.get("segments", []))
                    tm = j.get("timings") or {}
                    pipeline = tm.get("fullPipeline") or tm.get("pipelineStart")
                except Exception:
                    pass
            if text is None:
                text = p.stdout.strip().splitlines()[-1] if p.stdout.strip() else ""
            res.append({"wav": r["wav"], "text": re.sub(r"<\|[^>]*\|>", "", text or "").strip(), "wall_s": round(wall, 3),
                        "pipeline_s": pipeline, "rc": p.returncode, "err": p.stderr[-300:] if p.returncode else None})
            print(lang, stem, round(wall, 2), flush=True)
    (out / "wk.jsonl").write_text("\n".join(json.dumps(x, ensure_ascii=False) for x in res) + "\n")


def cmd_score(a):
    out = Path(a.out)
    man = {json.loads(l)["wav"]: json.loads(l) for l in (out / "manifest.jsonl").read_text().splitlines() if l.strip()}
    report = {}
    for eng, fn, tkey in (("mlx", "mlx.jsonl", "s"), ("whisperkit", "wk.jsonl", "pipeline_s")):
        p = out / fn
        if not p.exists():
            continue
        rows = [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
        for lang in ("uk", "en", "es"):
            e = n = 0
            ts = []
            for r in rows:
                m = man.get(r["wav"])
                if not m or m["lang"] != lang:
                    continue
                de, dn = wer(m["text"], r.get("text", ""))
                e += de
                n += dn
                t = r.get(tkey) if r.get(tkey) is not None else r.get("wall_s")
                if t is not None:
                    ts.append(float(t))
            ts.sort()
            report.setdefault(eng, {})[lang] = {"wer": round(e / n, 4) if n else None, "words": n,
                                                "sec_p50": ts[len(ts) // 2] if ts else None,
                                                "sec_p90": ts[int(len(ts) * 0.9)] if ts else None}
    (out / "asr_score.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))
    print(json.dumps(report, ensure_ascii=False))


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["gen", "mlx", "wk", "score"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--python")
    ap.add_argument("--model")
    a = ap.parse_args(argv)
    if a.cmd == "mlx":
        a.model = a.model or "mlx-community/whisper-large-v3-turbo"
    if a.cmd == "wk":
        a.model = a.model or "large-v3-v20240930_turbo"
    Path(a.out).mkdir(parents=True, exist_ok=True)
    {"gen": cmd_gen, "mlx": cmd_mlx, "wk": cmd_wk, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
