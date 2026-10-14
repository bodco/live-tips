# live-transcriber

[Українською](README.uk.md) · Full guide: [docs/en/17-live-tips.md](../../docs/en/17-live-tips.md)

Local call transcription for the `live-tips` skill. Records the microphone and the system
audio as two channels, transcribes every phrase on the Mac with Whisper large-v3-turbo (MLX)
and appends lines to `<project folder>/live/<YYYY-MM-DD-HHMM>-<title>.md`:

```
[12:30:11] Я (uk): ...
[12:30:15] Співрозмовник (en): ...
```

Nothing goes to the network except the one-time model download.

## Install (Apple Silicon, macOS 14.2+, Python 3.10+)

```
cp -R tools/live-transcriber ~/work/Tools/
bash ~/work/Tools/live-transcriber/install.sh
```

Allow Terminal both the microphone and System Audio Recording when macOS asks. The log is
`logs/install.log`; both `mic` and `sys` peaks must be above zero (play any sound during
the `sys` test).

## Control

- Start: write `control/start.json`, e.g.
  `{"project_dir": "/Users/you/work/Acme Portal", "title": "Sync", "slug": "acme-portal", "me_lang": "uk", "me_langs": "uk+en", "langs": "uk+en", "prompt": "Acme, Portal, Jira"}`.
  The LaunchAgent sees it and opens a "Live transcriber" Terminal window.
- Stop: `touch control/stop`, or Ctrl+C in that window. Closing Zoom/Meet does NOT stop it.
- State: `state/status.json` (`state`, `file`, `started_at`, `lines`, `queue`, `mic`, `system_audio`, `errors`).
- The skill reads only new lines with `bin/read_delta.py FILE OFFSET --wait 25 --settle 2 --status state/status.json`.

By hand, without the skill:

```
cd ~/work/Tools/live-transcriber
.venv/bin/python src/transcriber.py --project-dir "$HOME/work/Test" --title "Test" --me-lang uk --langs uk+en
```

## Tips window

`bin/prompter` (built by `install.sh` from `src/prompter.swift` and `src/prompter.html`) is a
small always-on-top window that shows the skill's tips and sends typed questions back. It
opens when a recording starts (`"prompter": false` in `start.json` or `config.json` turns it
off), can be moved, minimised and closed, and asks macOS to stay out of screen sharing.
Closed it by accident during a call? `touch control/prompter` reopens it with all tips so far.
Try it without a call: `python3 bin/demo_prompter.py` plays a scripted call in the real
window (cards, tips, agenda, setup row, quick asks, the red warning); `bin/prompter --demo`
shows three static tips.

Since 1.7.0 the recorder also: shows **instant cards** from `<transcript>.cards.json` the
moment a trigger phrase is transcribed (and logs them to `<transcript>.cards-fired.jsonl`,
which `read_delta.py` reports as `@@CARD`); applies the language and the microphone chosen
in the window's gear row on the fly; writes `talk_me_pct`, `monologue_s`, `asr_lag_s` and
`listener_age_s` (seconds since the skill's last poll) into `status.json`. `read_delta.py`
keeps `<transcript>.state.json` (offsets, polls, longest gap) and stamps every tip with
`at`, so the window can show the delay of each tip.
Buttons: `🎙` mutes the mic transcription (creates `control/mic_muted`; the recorder drops mic
audio and writes "мікрофон вимкнено / увімкнено" lines), `💬` sets how often the skill may
suggest a comment (written to the inbox as `{"kind":"setting",...}`, read as `@@SET`).

## Configuration

`config.json`: model, channel labels, default languages, `launchd_label` (LaunchAgent name,
default `com.pm-control-tower.live-transcriber`). Fields from `start.json` override it.
Fine parameters (VAD, phrase length, echo window, hallucination list) are in `DEFAULTS` and
`HALLUCINATIONS` in `src/transcriber.py`.

## Which microphone

`"mic_device": "default"` (default) records whatever the Mac uses as input now: AirPods, Jabra or
other headsets, or the Mac itself. `"mic_device": "builtin"` always records the Mac's own
microphone, whatever headset is connected (set it in `config.json` or `start.json`, or run
`bin/audiocap --source mic --device builtin`). The headset stays your output and your voice in
the meeting app. Use it when a headset switches to its low-quality call mode and your voice is
transcribed badly. The choice is fixed for the call.

## Transcript quality

- **Main language first.** The first language in `langs` (and in `me_langs`) is the main one.
  Another allowed language wins only when Whisper finds it `lang_bias` (2x) more likely, so
  short or noisy phrases do not flip language. Russian is not in the default sets: a Russian
  phrase is written as Ukrainian on purpose.
- **Whisper artefacts are dropped.** Whisper was trained on subtitled internet videos, and on
  silence, music or chopped audio it "recalls" their credit lines ("Субтитры создавал ...",
  "Редактор субтитров ...", "Продолжение следует..."). They are not in the audio and come from
  the model itself. `HALLUCINATION_PATTERNS` removes them, repetition loops ("one, two, one,
  two, ...") are collapsed or dropped, and a line that only repeats the names from `prompt`
  is dropped.
- **Mic restarts.** `audiocap` rebuilds the mic engine only when the input device or its
  format really changes. Before 1.6.3 a configuration change caused by the restart itself
  started a loop (several restarts a second), the mic lost about a quarter of its audio and
  the "me" lines were garbled and late. `health ... restarts=N` in `logs/audiocap-mic.log`
  shows the count; one restart per headphone switch is normal.
- **Times follow the clock.** If a source loses audio, its clock moves forward
  (`gap_resync`), so lines keep the right time and order; `status.json` shows
  `audio_lost_s` per channel.
- **Model.** `whisper-large-v3-turbo` is the default and is fast. `mlx-community/whisper-large-v3-mlx`
  is the larger model: it is more accurate for Ukrainian, but it needs 2-3 times more processing time
  per phrase. Each phrase is transcribed after it ends, so transcript lines and tips appear that much
  later. Set it in `config.json` (`"model"`); the skill does not ask about it. Compare the two on your
  own audio before you switch: `bin/bench.py SAMPLE` (see "Comparing models").

## Comparing models

Record 2-3 minutes of a real call (Voice Memos or QuickTime, export as m4a), then run in Terminal:

```
~/work/Tools/live-transcriber/.venv/bin/python ~/work/Tools/live-transcriber/bin/bench.py ~/Desktop/sample.m4a
```

For each model the script prints the load time, the transcription time, the speed (`x realtime`)
and writes `sample.<model>.txt` with timestamps next to the file. Compare the two text files
line by line. The first run downloads the model (several GB), so it can take a long time.
