# live-transcriber

[Українською](README.uk.md) · Full guide: [docs/en/17-live-tips.md](../../docs/en/17-live-tips.md)

Local call transcription for the `live-tips` skill. Records the microphone and the system
audio as two channels, transcribes every phrase on the Mac with Whisper large-v3-turbo (MLX)
and appends lines to `<project folder>/live/<YYYY-MM-DD-HHMM>-<title>.md`:

```
[12:30:11] Я (uk): ...
[12:30:15] Співрозмовник (ru): ...
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
  `{"project_dir": "/Users/you/work/Acme Portal", "title": "Sync", "slug": "acme-portal", "me_lang": "uk", "me_langs": "uk+en", "langs": "uk+ru+en", "prompt": "Acme, Portal, Jira"}`.
  The LaunchAgent sees it and opens a "Live transcriber" Terminal window.
- Stop: `touch control/stop`, or Ctrl+C in that window. Closing Zoom/Meet does NOT stop it.
- State: `state/status.json` (`state`, `file`, `started_at`, `lines`, `queue`, `mic`, `system_audio`, `errors`).
- The skill reads only new lines with `bin/read_delta.py FILE OFFSET --wait 25 --settle 2 --status state/status.json`.

By hand, without the skill:

```
cd ~/work/Tools/live-transcriber
.venv/bin/python src/transcriber.py --project-dir "$HOME/work/Test" --title "Test" --me-lang uk --langs uk+en
```

## Configuration

`config.json`: model, channel labels, default languages, `launchd_label` (LaunchAgent name,
default `com.pm-control-tower.live-transcriber`). Fields from `start.json` override it.
Fine parameters (VAD, phrase length, echo window, hallucination list) are in `DEFAULTS` and
`HALLUCINATIONS` in `src/transcriber.py`.
