#!/usr/bin/env python3
"""Compare Whisper models on one recording (run it in Terminal on the Mac).

Usage:
  ~/work/Tools/live-transcriber/.venv/bin/python bin/bench.py SAMPLE [--models REPO ...] [--lang uk] [--prompt "..."]

SAMPLE is any audio file ffmpeg can read (m4a, wav, mp3). A 2-3 minute clip of a real call is enough.
Each model transcribes the whole file once with the same settings the live recorder uses. For every
model it prints the load time, the transcription time, the speed (x realtime: 4.0 means the file
took a quarter of its length), the number of segments and the text. The text goes to
SAMPLE.<model>.txt next to the file, with timestamps, so the two versions can be compared line by line.
The live loop transcribes phrase by phrase, so the speed ratio between models is the useful number.
"""
import argparse
import pathlib
import time

import numpy as np
import mlx_whisper
from mlx_whisper.audio import load_audio

DEFAULT_MODELS = [
    "mlx-community/whisper-large-v3-turbo",
    "mlx-community/whisper-large-v3-mlx",
]


def stamp(sec: float) -> str:
    m, s = divmod(int(sec), 60)
    return f"{m:02d}:{s:02d}"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sample", type=pathlib.Path)
    ap.add_argument("--models", nargs="+", default=DEFAULT_MODELS)
    ap.add_argument("--lang", default="uk")
    ap.add_argument("--prompt", default=None, help="same kind of prompt the skill writes into start.json")
    args = ap.parse_args()

    audio = load_audio(str(args.sample))
    seconds = len(audio) / 16000
    print(f"file: {args.sample.name}, {seconds:.0f} s of audio, language {args.lang}\n")

    for repo in args.models:
        short = repo.split("/")[-1]
        t0 = time.time()
        # Loading the model (the first run downloads it, several GB, so the first load can take minutes).
        mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo=repo, language=args.lang)
        load_s = time.time() - t0

        t1 = time.time()
        res = mlx_whisper.transcribe(
            audio, path_or_hf_repo=repo, language=args.lang, initial_prompt=args.prompt or None,
            condition_on_previous_text=False, temperature=(0.0, 0.2, 0.4),
            no_speech_threshold=0.6, logprob_threshold=-1.0, compression_ratio_threshold=2.4,
            verbose=None,
        )
        run_s = time.time() - t1
        segments = res.get("segments", [])

        out = args.sample.with_name(f"{args.sample.stem}.{short}.txt")
        with open(out, "w", encoding="utf-8") as f:
            for s in segments:
                f.write(f"[{stamp(s.get('start', 0))}] {s.get('text', '').strip()}\n")

        print(f"model {short}")
        print(f"  load {load_s:.1f} s, transcription {run_s:.1f} s, speed {seconds / max(run_s, 1e-6):.1f}x realtime")
        print(f"  segments {len(segments)}, text written to {out.name}\n")


if __name__ == "__main__":
    main()
