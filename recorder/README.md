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
- State: `state/status.json` (`state`, `file`, `started_at`, `lines`, `queue`, `mic`, `system_audio`, `errors`,
  `seq` (+1 on every write, about every 2 s), `req_id` (copied from `start.json`), `call_type`, `audience`,
  `proactive`, `mic_stall_streak`, `mic_auto_switched`, `last_question`, `tips_paused`, `speakers`
  (`on` | `off` | `loading`) with `speakers_reason`, `speakers_rev`, `speaker_now`, `speaker_ask_open`).
- The skill drives everything with `bin/lt` (`lt start|status|stop|prep-check|state|wrapup-data|speakers`, run `bin/lt`
  for the usage). In the Cowork VM pass `--mac-root <work_root>` (or set `LT_MAC_ROOT`): the Mac folder that is
  mounted as `$HOME/mnt/<basename>`; paths are never guessed.
- The skill reads only new lines with
  `bin/read_delta.py FILE auto --wait 25 --settle 2 --status state/status.json --tips TIPS --emit-stdin --inbox INBOX`
  (a numeric OFFSET still works). Its own state goes in the same heredoc as the tips, as a line
  `{"kind": "state", ...}`; it is merged into `<stem>.state.json` under a lock, not shown as a tip.
  Besides the transcript it prints `@@` lines: `@@ASK`, `@@SOS`, `@@OFFTOPIC`, `@@SET`, `@@OFFSET`, `@@CARD`,
  `@@LATE`, `@@STATUS` (or `@@STATUS stale ...` when the recorder stopped updating), `@@MODE`, `@@SPEAKERS`
  and `@@DUE` reminders (`prep`, `state`, `ack <key>`, `wrapup`). The full list is in the script's docstring.
  Lines tagged `Співрозмовник [S2]` are printed with the speaker's name (`Ірина`, or `Speaker 2`).

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
Try it without a call: `bin/prompter --demo`.
Buttons: `🎙` mutes the mic transcription (creates `control/mic_muted`; the recorder drops mic
audio and writes "мікрофон вимкнено / увімкнено" lines), `💬` sets how often the skill may
suggest a comment (written to the inbox as `{"kind":"setting",...}`, read as `@@SET`).

## Pause tips

The ⏸ button next to 🆘 in the window sends the setting `tips_paused=on` (▶ sends `off`). While paused the
recorder keeps recording and transcribing but writes no automatic items to the window: no instant cards,
no 📌 auto facts, no ❓ question markers; "Who is speaking?" cards wait in a queue and appear after play.
The fact search, 🆘 and answers to typed questions still work. `status.json` shows `tips_paused`.

## Speaker identification (optional)

Install once in Terminal (also offered at the end of `install.sh`; safe to re-run):

```
bash ~/work/Tools/live-transcriber/bin/install-voices.sh
```

It installs `sherpa-onnx` into `.venv`, downloads `wespeaker_en_voxceleb_resnet34_LM.onnx` (~26 MB) into
`models/` and runs a self-test (`src/transcriber.py --voices-check`). Without it everything works as before
(`speakers: "off"` and the reason in `status.json`).

How it works: the system channel (everyone on the other side) is split per voice. Every phrase with 1 s or
more of speech gets a voice embedding in a separate thread (ASR is never blocked; when the thread is behind,
the oldest job is dropped). Phrases join the closest speaker when the cosine to its centroid is at least
`speaker_join`; a phrase of 1.5 s or more that matches nobody opens a new speaker `S1`, `S2`, ... Lines are
written as `[12:30:13] Співрозмовник [S2] (uk): ...` (the md stays append-only). After 8 s of speech of an
unnamed speaker the window asks "Who is speaking?" with suggestions from the voice library; the answer, the
"Now speaking" chip and its popover send `speaker_name`, `speaker_merge`, `speaker_fix`, `speaker_skip`.
Files: `<stem>.speakers.json` (mapping, merges, per-line fixes), `<stem>.named.md` (written on stop: the
transcript with names), and the voice library `voices/voices.json` (max 20 voice prints per person; it only
suggests, a name is never assigned automatically). Everything stays on this Mac; keep `voices/` out of any
repository. `bin/lt speakers "<transcript>"` prints the mapping.

Thresholds (`config.json`): `speaker_join` 0.45, `speaker_suggest` 0.5, `speaker_prompt_s` 8,
`speakers_enabled`; finer ones (`speaker_new_min_s`, `speaker_automerge`, `speaker_inherit_s`) are in
`DEFAULTS`. They were tuned on real recordings of 7 people (sherpa-onnx speaker test set): phrase to phrase,
the same person scores about 0.45 (2 s phrases) and different people about 0.05 (99 % below 0.31); with
0.45 the online clustering kept 4 people apart with purity 1.00 on clean audio. A stricter value splits one
person into several speakers (merge them in the window); a looser one mixes people.
Note: sherpa-onnx normalises the features of this model only when the model says so, so the recorder adds
that key to the downloaded file once (without it two different people scored 0.6-0.9).

## Semantic layer (Ollama)

Optional. Keyword tips work as before; with a local embedding model the recorder also understands
paraphrases ("how long will the admin history take?" finds the fact "Admin audit logs: 16 h") in
Ukrainian, English and Spanish.

Install once (Terminal on the Mac):

```
brew install ollama        # or the Ollama app from ollama.com; it must be running during calls
ollama pull bge-m3         # ~1.2 GB, multilingual embeddings
```

Pre-index the project before calls (the first run takes a few minutes for a big `_notion/` mirror;
later runs only re-embed new or changed files):

```
~/work/Tools/live-transcriber/bin/lt index "$HOME/work/Acme"
~/work/Tools/live-transcriber/bin/lt index "$HOME/work/Acme" --extra "$HOME/work/_notion"   # plus a workspace mirror
~/work/Tools/live-transcriber/bin/lt index "$HOME/work/Acme" --rebuild                      # after changing the model
~/work/Tools/live-transcriber/bin/lt search "who approves prod deploys" --root "$HOME/work/Acme" -k 5
```

`lt search` prints score, date (`last_edited` from front matter, else the file date), path and a
preview (`--json` for the skill). When Ollama cannot be reached (for example from the Cowork VM) it
asks the running recorder, and otherwise falls back to a plain text search and says so in a `NOTE:` line.

What the index holds: `.md`, `.txt`, `.csv` (first 30 rows) and small `.json` files of the project
folder, its `_notion/` mirror and `--extra` folders, in chunks of about 1000 characters split at
headings and paragraphs. Skipped: `.git`, `node_modules`, `repos/`, `_archived/`, call artefacts in
`live/` (only the transcripts are indexed), `*.timing*`, binaries and files over 2 MB. It lives in
`<project>/.livetips-index/` (float16 vectors, `meta-*.jsonl`, `manifest.json`); add it to `.gitignore`.
Updates are incremental (mtime + size) and atomic, and a lock keeps the recorder and `lt index` from
writing at the same time.

During a call:
- Every transcript line of 3+ words is embedded in a separate thread (2 s timeout; when it is behind,
  the oldest line is dropped). ASR, the writer and the speaker worker never wait for it.
- A line of the other side that is close in meaning to a fact shows the 📌 fact when it is a question or
  the topic held for 2+ lines. Cards also fire by meaning. Cooldowns are shared with the keyword path
  (no duplicates); nothing automatic while tips are paused.
- 🆘 HELP NOW picks facts and cards by the topic of the last minute, plus 1-2 snippets from the project
  index (file name and date in the note).
- New or changed project files are indexed in the background, newest first, in small batches, only
  while the transcription queue is empty (at most `index_live_max_chunks` per call).
- Every semantic hit and near miss is logged with its score to `<stem>.semantic.jsonl`; fact and card
  vectors are cached in `<stem>.semantic.npz`.
- `status.json`: `semantic` (`on` | `off` | `loading`), `semantic_reason`, `semantic_stats`,
  `index_state` (`idle` | `indexing` | `off`), `index_files`, `index_chunks`, `index_reason`.
  `lt status` prints them. When Ollama is not running or the model is missing, `semantic` is `off`
  with the reason and the recorder retries every 30 s.

Thresholds (`config.json`): `semantic_fact_min` 0.55 and `semantic_card_min` 0.60 (bge-m3 cosine),
and `semantic_margin` 0.08: the line must also beat the entry's "small talk" score (its best cosine to
neutral phrases such as "can you hear me?") by this much, which removes most false hits on chit-chat.
Too many 📌 on unrelated talk: raise the minimums by 0.05; too few: lower them. The scores in
`<stem>.semantic.jsonl` show where real hits and misses fall. `semantic_enabled: false` turns it all off,
`index_enabled: false` only the background indexing.

Resources (16 GB Mac): bge-m3 in Ollama takes about 1.2 GB of memory next to Whisper (about 1.6 GB);
one call is about 7 short embedding requests a minute (tens of milliseconds each on Apple Silicon).
Pre-index before the call, so the recorder has little to do. If the Mac is under memory pressure, set
`index_enabled: false` or `semantic_enabled: false`. Ollama keeps the model loaded for 30 minutes after the
last request (`keep_alive`).

Privacy: everything stays on this Mac. The recorder talks only to Ollama on `127.0.0.1` (never through a
proxy); the index and logs are files in the project folder.

## Configuration

`config.json`: model, channel labels, default languages, `launchd_label` (LaunchAgent name,
default `com.pm-control-tower.live-transcriber`). Fields from `start.json` override it.
Fine parameters (VAD, phrase length, echo window, hallucination list) are in `DEFAULTS` and
`HALLUCINATIONS` in `src/transcriber.py`.

## Which microphone

`"mic_device": "default"` (default) records whatever the Mac uses as input now: AirPods, Jabra or
other headsets, or the Mac itself. `"mic_device": "builtin"` always records the Mac's own
microphone, whatever headset is connected (set it in `config.json` or `start.json`, in the tips
window's ⚙ menu during the call, or run `bin/audiocap --source mic --device builtin`). The headset
stays your output and your voice in the meeting app. Use it when a headset switches to its
low-quality call mode and your voice is transcribed badly.

The mic watchdog restarts `audiocap` when the mic sends nothing for 12 s, or only exact digital
zeros for 10 s while not muted. Retries back off up to 60 s and never stop; after 2 failed restarts
in a row the recorder switches to the Mac's built-in microphone by itself (`mic_auto_switched` in
`status.json`, a "перемкнув на мікрофон Мака" marker in the transcript).

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
