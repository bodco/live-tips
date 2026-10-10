# 17. Live tips: a co-pilot on the call

[Українською](../uk/17-live-tips.md) · [Back to contents](README.md)

Live tips listens to a call together with the PM and posts tips in the Cowork chat. Audio is
transcribed locally on the Mac and never leaves it. The skill reads the transcript line by
line and checks it against the project context. It stays silent until a trigger fires: a
request that looks like a change request, a date or an estimate being promised, a statement
that contradicts a recorded decision, an inaccurate or incomplete answer from the PM, the
client team switching to another language between themselves. After the call, a page with
the transcript and a wrap-up appears in the Meetings DB.

This document is written for three situations:

1. rebuilding everything from scratch on a new Mac;
2. remembering how it works when something breaks;
3. a colleague who wants the same setup.

---

## 1. How it works

```
                    Mac (local)                                       Cowork (cloud)
┌──────────────────────────────────────────────────────────┐    ┌──────────────────────────┐
│ LaunchAgent  ──watches──>  control/                      │    │ live-tips skill          │
│     │ start.json appeared                                │<───│  writes control/start.json 
│     v                                                    │    │                          │
│ Terminal: bin/run.command                                │    │  long-poll:              │
│     v                                                    │    │  bin/read_delta.py       │
│ src/transcriber.py                                       │    │  -> new lines            │
│   ├─ bin/audiocap --source mic     (microphone)          │    │  -> triggers -> a tip    │
│   ├─ bin/audiocap --source system  (system audio)        │    │     in the chat          │
│   ├─ VAD cuts speech into phrases                        │    │                          │
│   ├─ Whisper large-v3-turbo (MLX) per phrase             │    │  "stop" -> control/stop  │
│   ├─ removes echo and hallucinations                     │    │                          │
│   └─> <project>/live/2026-10-10-2348-<title>.md ─────────┼───>│  wrap-up + a page in     │
│       state/status.json  (state for the skill) ──────────┼───>│  the Notion Meetings DB  │
└──────────────────────────────────────────────────────────┘    └──────────────────────────┘
```

Why it is built this way:

- **Local Whisper.** Client conversations do not go to a third-party transcription service.
  The `mlx-community/whisper-large-v3-turbo` model runs on Apple Silicon through MLX. The
  network is needed once, to download the model (~1.6 GB).
- **Two channels, not one.** `audiocap` (Swift) records the microphone and the system audio
  separately. System audio is captured with a Core Audio process tap (macOS 14.2+), so no
  BlackHole is needed and switching headphones or speakers does not break the recording.
  The two channels also tell the transcript who is speaking: `Я` (me) = microphone,
  `Співрозмовник` (them) = everyone else. Labels are configurable.
- **Fixed microphone language.** The PM's language on a call is known in advance
  (`me_lang`), and for everyone else Whisper picks only from the allowed set (`langs`, e.g.
  `en+es`). This is clearly better than full auto-detect: Ukrainian does not turn into
  Russian, Spanish lines are not translated into English.
- **Terminal, not a background daemon.** macOS grants microphone and system audio
  permissions to an app. The recording runs in a Terminal window, so the permissions belong
  to Terminal and are granted once. The LaunchAgent only opens that window when the skill
  drops `control/start.json`.
- **Files as the interface.** The skill talks to the Mac through the shell in the connected
  Cowork folder (`device_bash`) and knows nothing about audio. The only things between the
  skill and the recorder are files: `control/start.json`, `control/stop`,
  `state/status.json` and the transcript itself.

---

## 2. Components

The code is in [`tools/live-transcriber/`](../../tools/live-transcriber/), the skill in
[`plugin/skills/live-tips/`](../../plugin/skills/live-tips/).

| File | Role |
|---|---|
| `install.sh` | One-time install: builds `audiocap`, a venv with `mlx-whisper`, the model, the LaunchAgent, a permissions test. Safe to re-run |
| `config.json` | Model, channel labels, default languages, `launchd_label`. Fields from `start.json` take precedence |
| `src/audiocap.swift` | Audio capture: `--source mic` or `--source system`, float32 16 kHz mono to stdout. Reconnects by itself when the device changes |
| `src/Info.plist` | Embedded into the binary, holds the permission prompt texts |
| `src/transcriber.py` | The core: two capture threads, VAD (webrtcvad, or an energy VAD without it), Whisper, hallucination filter, echo removal, writing lines, `status.json` |
| `bin/run.command` | Runs `transcriber.py --from-control` in the "Live transcriber" Terminal window |
| `bin/on-control.sh` | Called by the LaunchAgent when `control/` changes. If `start.json` is there and nothing is recording, opens Terminal |
| `bin/read_delta.py` | Long-poll for the skill: waits up to `--wait` s for new lines, prints only new complete lines, `@@OFFSET` and `@@STATUS` |
| `launchd/live-transcriber.plist.template` | LaunchAgent template (`WatchPaths` on `control/`) |
| `plugin/skills/live-tips/SKILL.md` | The skill: start, Live Brief, tip loop, stop, wrap-up, Meetings DB page |
| `plugin/skills/live-tips/settings.yaml` | Everything personal: labels, paths, languages, tip rules, time zone |

Runtime folders (not in git): `.venv/`, `bin/audiocap`, `logs/`, `state/`, `control/`.

### Control and state files

| Path | Written by | Meaning |
|---|---|---|
| `control/start.json` | the skill or a person | Start request: `project_dir`, `title`, `slug`, `me_lang`, `langs`, `me_label`, `them_label`, `prompt`. Renamed to `control/active.json` on start |
| `control/stop` | the skill or a person (`touch`) | Stop request. Content does not matter |
| `state/status.json` | transcriber | `state` (`loading_model` → `recording` → `stopping` → `stopped`, or `error`), `file`, `started_at` (with offset), `timezone`, `lines`, `queue`, `mic`, `system_audio`, `errors` |
| `state/pid`, `state/launching` | transcriber / on-control.sh | Guard against a double start |
| `logs/transcriber.log`, `logs/launcher.log`, `logs/install.log`, `logs/audiocap-*.log` | all | First place to look when something fails |

### Transcript format

`<project folder>/live/<YYYY-MM-DD-HHMM>-<title>.md`:

```
# Live transcript: Status sync

- Проєкт: acme-portal
- Початок: 2026-10-10 23:48:02
- Мови: Я = en, дозволені = en+es
...
[23:48:11] Я (en): Can you hear me?
[23:48:15] Співрозмовник (es): Sí, perfecto.

--- кінець запису 00:31:40 ---
```

Next to it the skill keeps `<title>.brief.md` (the Live Brief) and `<title>.state.json`
(read offset, tips given, question-answer pairs, action items).

---

## 3. Requirements

- An Apple Silicon Mac (M1 or newer), macOS 14.2 or newer.
- Xcode Command Line Tools (`xcode-select --install`; `install.sh` offers it if missing).
- Python 3.10+ (`brew install python@3.12`).
- ~2.5 GB free disk (model + venv).
- Claude desktop (Cowork) with a connected folder that holds the tool and the project
  folders (`~/work` for the author).
- The `pm-control-tower` plugin with a project config in `projects/<slug>.md`. The skill
  takes the team, meetings, `Local Paths` and Notion IDs (`meetings_db`, `project_page_id`,
  `workspace_page_id`) from there.
- The Notion connector in Cowork (for the Live Brief and the Meetings DB page). Without it
  tips still work, but without Notion context and without the page after the call.

---

## 4. Installing from scratch

1. **Put the tool on the Mac.** Copy `tools/live-transcriber/` from this repository to
   `~/work/Tools/live-transcriber` (another path is fine, then change it in `settings.yaml`):
   ```
   mkdir -p ~/work/Tools
   cp -R "<repo clone>/tools/live-transcriber" ~/work/Tools/
   ```
2. **LaunchAgent name.** Default `com.pm-control-tower.live-transcriber`. For your own
   prefix change `launchd_label` in `config.json` before installing.
3. **Install:**
   ```
   bash ~/work/Tools/live-transcriber/install.sh
   ```
   Takes 5-10 minutes, mostly the model download. During the permissions test macOS asks
   to let Terminal use the microphone and record system audio: allow both. When the script
   asks, play any sound (YouTube) for 5 s.
4. **Check `logs/install.log`.** It must end with `=== install OK`, and both `mic: ... peak`
   and `sys: ... peak` should be above zero. `sys: 0.0 s, peak 0.0000` means one of two
   things: nothing was playing during the test (most common) or the permission is missing.
   Check: play YouTube and run
   `~/work/Tools/live-transcriber/bin/audiocap --source system --seconds 5 | wc -c`.
   A number above zero (~330,000 for 5 s) means it works. Zero: see section 10.
5. **The skill.** The `pm-control-tower` plugin (1.6.0+) already contains `live-tips`. Fill
   in `plugin/skills/live-tips/settings.yaml`: `paths.work_root`, `paths.tool_root`, labels,
   languages, `user.timezone`. Plugin setup substitutes `~~home-folder` for you.
6. **Cowork.** Connect the `work_root` folder in Claude desktop ("Add folder"). The skill
   reaches it as `$HOME/mnt/<folder name>`.
7. **Project config.** `projects/<slug>.md` needs `Local Paths` (the project folder, where
   `live/` is written), `notion.meetings_db`, `notion.project_page_id`,
   `notion.workspace_page_id`, and `client_language` for client calls.
8. **A test recording without the skill** (checks everything except Cowork):
   ```
   cd ~/work/Tools/live-transcriber
   .venv/bin/python src/transcriber.py --project-dir ~/work/Test --title "Test" --me-lang en --langs en+uk
   ```
   Talk for a minute, stop with Ctrl+C, open `~/work/Test/live/…-test.md`.

---

## 5. Running a call

### 5.0 Before the call: model and preparation

**Which model to use for the session.** Every second of the model's thinking adds to the
tip delay, so the choice depends on the call:

| Call | Model | Why |
|---|---|---|
| Regular syncs, stand-ups, status calls | Sonnet 5.5, low or medium effort | Keeps up with the conversation and is careful enough for the answer check |
| Client interview, escalation, steering, hard negotiation | Opus 5.5 | Sees contradictions and gaps better; a 10-30 s delay is acceptable on such calls |
| Haiku | not recommended | Too shallow for the answer check and multilingual nuance |

**Preparation in the same session.** Works best like this: open a session in the Cowork
project, do the prep first, and write `live tips` right before the call.

1. Prep: `client-meeting-prep` or `daily-team-prep`, or a free-form request like "prepare
   me for a client interview about transaction reports, take these Notion pages <links>
   and this folder <path> first". Meeting details, goals, questions, pages and folders to
   load first go here.
2. Right before the call: `live tips <project>`. The skill sees everything prepared
   earlier in the session and builds the Live Brief around it: goals and questions from
   the prep become the checklist, the named pages and folder become the core of the topic
   map. It is a priority, not a limit: the rest of the project context (decisions, risks,
   tracker, past meetings) is still loaded and used when the conversation goes elsewhere.

**Opening and "your turn".** At start the skill prepares "My update" in advance: 3-4 points
by priority (done, in progress, blockers or decisions needed, next) and a ready opening
sentence. It takes them from the prep report for this meeting in the Reports DB (the one a
scheduled task generates, e.g. `daily-team-prep`, or one made earlier in the session) and
from the tracker. For a meeting across several projects, like an internal PM sync, one line
per project.

- **You open the meeting** (you host it, you said so, or the other side is silent for the
  first 30 s): right after the checklist an opening arrives: greeting, the goal of the
  meeting in one sentence, the order of topics or your update.
- **You are called on:** when someone addresses you by any name in
  `settings.user.name_aliases` (all forms and languages, including Whisper misspellings)
  and asks for your updates, a 🔴 "Your turn" tip arrives immediately, with no rate limit:
  the opening sentence and the points in the order to say them. If the question was about
  one topic, only that topic.

> **🔴 Your turn: update**
> "Short update from my side. We are on track."
> 1. Transaction report is in testing
> 2. Payments: waiting for the client
> 3. We need a decision on the release date

**Switching language mid-call.** Internal calls can mix Ukrainian, Russian and English.
Your microphone is recognised only among your own languages (`me_langs`, e.g. Ukrainian and
English), so Ukrainian never turns into Russian and an English part is recognised
correctly. The skill keeps a "language of the moment": when you are asked "say it in
English" or a guest asks you in English, a tip arrives at once with the gist in your
language and the phrase already in English, and phrases stay in English until you switch
back. Ukrainian and Russian on one internal call count as one conversation, not side talk.

> **🟠 Тепер англійською: статус релізу** (Now in English: release status)
> "Short update in English. The release is on track for Friday."

**Client interview.** When the prep or your words make it clear this is an interview on a
topic, the skill switches to interview mode: the checklist is your planned questions. It
tracks which were asked and how fully they were answered. It tips where an answer is vague
and worth a follow-up (as a ready English question), where it contradicts what is known,
where a new topic deserves a question, and which questions are still not asked near the
end. The wrap-up adds "answers to the interview questions": question → one-line answer →
status.

### 5.1 During the call

1. A minute before the call, write in Cowork: **`live tips <project>`** (or "лайв
   підказки", "я на дзвінку", "дзвінок почався"). If no project is named, the skill asks.
   Language and length can be added: "live tips acme, internal, Ukrainian, 30 min".
2. The skill checks the install and that nothing else is recording, drops
   `control/start.json` and waits for `recording` (5-20 s to load the model). The "Live
   transcriber" Terminal window opens by itself: you do not start it. The recording lives
   in it, because the macOS microphone and system audio permissions belong to Terminal.
   Minimise it (Cmd+M) or keep it behind other windows, but do not close it. If it is
   closed anyway, the recording stops cleanly and the transcript so far is kept.
3. The chat shows `Запис іде: <file>. Мови: я en, дозволені en+es.` ("Recording: …"), and
   a minute later the meeting checklist from the Live Brief (open topics, decisions, risks,
   promises from previous meetings, tickets) and "Мовчу, поки нема що сказати." ("Staying
   quiet until there is something to say").
4. From then on the skill is silent until a trigger fires.

| Level | When |
|---|---|
| 🔴 immediately | A request that looks like a new requirement; the PM names a date or an estimate; a contradiction with a recorded decision; a dissatisfaction signal; the PM states a fact that contradicts the tracker or decisions |
| 🟠 at most once per `rate_seconds` | The PM answered a different question or only part of it; a vague answer where a date or an owner was expected; the other side switched to another language (short gist); a topic or ticket from the brief came up; a question unanswered for ~2 min; 2/3 of the time with checklist items uncovered; 5 min before the end with decisions not obtained |
| silent | Action items, new requests, commitments: they go into the wrap-up |

### What a tip looks like

Built for a small Cowork window at the top centre of the screen, under the camera, so the
eyes do not wander. Every tip is 2-5 short lines (~45 characters), no tables, headings or
links.

1. **Gist**, bold: emoji and what is happening, in the tips language (Ukrainian for the
   author), max 7 words. Always first, to get the point in one second.
2. **Phrase**, in quotes, in the language of the call. A ready speech to read aloud as is,
   not bullet points. 1-2 sentences. In English: simple sentences up to 12 words,
   everyday words, present or future simple, active voice, no idioms or long clauses.
3. **Facts** (only for status and side-talk tips): up to 3 lines of up to 8 words.
4. **Source** (only for 🔴 contradictions and inaccuracies): one short italic line.

**No abbreviations:** "a new request", not CR; "date", not ETA. No ticket keys either, the
topic name instead. People and product names stay as they are.

Examples on an English call:

> **🔴 Нова вимога. Не погоджуй зараз.** (New request. Do not agree now.)
> "Good idea. I will write it down. We will check it and come back to you."

> **🔴 Неточно: реліз 15.10, не 10.10** (Inaccurate: release 15.10, not 10.10)
> "Sorry, a small correction. The release date is October 15."
> _рішення від 30.09_ (decision of 30.09)

On an internal Ukrainian call both the gist and the phrase are in Ukrainian.

A 🔒 tip relies on an internal source and must never be repeated to the client. The skill
never suggests an estimate in hours: "the assignee gives the estimate, log it and come back".

**Questions during the call.** Type anything in the chat ("what did we promise on X?",
"status of ACME-123?"). The skill answers briefly from the brief and the transcript, then
keeps listening from the same place. If the loop stopped, write "продовжуй" (continue).

---

## 6. How to end the meeting

Three equivalent ways. Each closes the transcript with a
`--- кінець запису HH:MM:SS ---` (end of recording) line.

1. **In the chat (the normal way):** write `стоп`, `все`, `кінець`, `кінець дзвінка` or
   `end live`. The skill creates `control/stop`, waits up to 60 s for the last phrases to be
   transcribed and reads the final lines.
2. **In the "Live transcriber" Terminal window** (it opened by itself at the start): Ctrl+C
   or close the window. A backup path when the chat is not at hand. The skill sees
   `stopped` on the next poll.
3. **Automatically:** after at least 20 lines, if there are no new lines for
   `idle_stop_minutes`, the skill asks once "Has the call ended? Stopping in 2 min" and
   stops. Hard limit: planned length + 20 min, or `hard_cap_minutes`.

Important: **closing Zoom/Meet does not stop the recording.** The tool keeps listening to
the system audio (music, videos). One of the three ways above is required.

By hand, without the skill: `touch ~/work/Tools/live-transcriber/control/stop`.

---

## 7. What happens after the call

### 7.1 Wrap-up in the chat

Action items (who / what / when), new requests, our commitments, open questions, "answers
worth coming back to" (question → what is wrong → how to close it), checklist items not
covered, the transcript path, the link to the Notion page. Then the skill only offers next
steps (report, change-request, risk-register) and runs nothing without a command.

### 7.2 The Meetings DB page (automatic)

The skill creates one page in the project's `notion.meetings_db`:

| What | Value |
|---|---|
| Title | `<generated name> @<start date-time>`. The skill writes the name from what was actually discussed (2-6 words, in the language of the call). The date-time in the title is a Notion date mention, a clickable date like in native AI Meeting Notes |
| `Date` | Meeting start date and time (`started_at` from `status.json`, with the Mac's UTC offset) |
| `Project` | The project page (`notion.project_page_id`) |
| `Workspace` | The workspace the project belongs to: read from the `Workspace` relation on the project page (fallback `notion.workspace_page_id`). Example: the project belongs to the workspace of the company you work for |
| `Meeting type` | Only if the meeting type exactly matches an existing option; the skill never creates options |
| `Summary` | 1-2 sentences |
| Body | An AI Meeting Notes block with the transcript, then a "Підсумок" (wrap-up) section: action items as to-dos, new requests, open questions |

**Notion API limit (verified 2026-10-11).** The `Transcript` and `Summary` sections of an AI
Meeting Notes block cannot be written through the API: the Notion spec says writing
`<transcript>` errors. Notion AI summary generation cannot be triggered through the API
either. So:

- the transcript goes into the **Notes** section of the AI Meeting Notes block (one line per
  paragraph);
- the summary is written by the skill itself (`Summary` property and the wrap-up section);
- if you want Notion AI's own summary, press Notion AI in the block manually.

A technical detail, so nobody steps on it twice: `notion-create-pages` stores
`<mention-date …/>` in a title as literal text. The skill therefore creates the page with a
plain name and then sets the title with the date through `notion-update-page`
(`update_properties`), which does parse the mention. Then it fetches the page and checks
the title, the properties and the line count.

If the meeting was recorded with Notion AI Meeting Notes (fallback, section 8), no second
page is created: the real transcript is already in Notion.

---

## 8. Fallback: Notion AI Meeting Notes

If the Mac is offline or live-transcriber does not start, turn on Notion AI Meeting Notes
and give the skill the meeting page link. The skill then reads the transcript from Notion.
Tips are less precise: Notion has no speaker labels and sometimes renders Ukrainian speech
as rough English. There is a separate skill for this mode, `notion-live-tips` (not part of
the package).

---

## 9. `settings.yaml`

| Key | What it sets |
|---|---|
| `user.me_label`, `user.them_label` | Channel labels in the transcript |
| `user.tips_language` | Language of tips and the wrap-up |
| `user.name_aliases` | How people call you on calls (all forms and languages): the "Your turn" trigger and a hint for Whisper |
| `user.timezone` | Fallback IANA zone. Usually not needed: live-transcriber writes the Mac clock zone and offset into `status.json` itself (Notion accepts `Europe/Kiev`) |
| `paths.work_root` | Mac folder connected to Cowork |
| `paths.tool_root` | Where live-transcriber lives |
| `languages.internal` | `me_lang` (main mic language), `me_langs` (languages you may switch to, e.g. `[uk, en]`), `langs` (all call languages, e.g. `[uk, ru, en]`) for internal calls |
| `languages.client` | The same for client calls; `from_project` = `client_language` from the config |
| `languages.per_project.<slug>.<internal\|client>` | Override for a specific project |
| `tips.rate_seconds` | Minimum gap between non-urgent tips |
| `tips.answer_check` | Check the PM's own answers |
| `tips.side_talk_summary` | Summarise the other side talking among themselves in another language |
| `tips.idle_stop_minutes`, `tips.hard_cap_minutes` | Auto-stop |
| `model_hint` | Which Claude model to use for the session (see section 5.0) |

**Where `settings.yaml` lives.** It is a file inside the `live-tips` skill in your Claude
account, not a separate file on the Mac. To change it, edit the file in the skill folder and
upload the skill again (a zip with the `live-tips/` folder holding `SKILL.md` and
`settings.yaml`) in Claude settings, Skills section. The template in this repository is
`plugin/skills/live-tips/settings.yaml`.

Fine recognition parameters (`vad_mode`, `end_silence`, `max_segment`, echo window) are in
`DEFAULTS` in `src/transcriber.py` and can be overridden in `config.json`.

---

## 10. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `start.json` is there but the recording does not start within 60 s | The LaunchAgent is not loaded or the install was never run. `launchctl list \| grep live-transcriber`; if empty, run `install.sh`. The skill then renames the file to `start.json.pending` so the recording does not start by surprise later |
| `system=silent`, the transcript has only "Я" lines | No permission to record system audio. System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only → Terminal. Check: play sound and run `bin/audiocap --source system --seconds 5 \| wc -c`, it must be above zero |
| `mic=silent` | Microphone permission for Terminal (Privacy & Security → Microphone) or the wrong input device |
| Many `mic restart: engine configuration change` in `audiocap-mic.log` | Normal when headphones connect or disconnect: the microphone reconnects by itself |
| `no IO from tap-only aggregate, retrying with output device as clock` | Normal: the fallback clock mode of the system tap |
| `queue` grows, tips arrive late | The Mac is busy (video, builds). Transcription catches up; the skill warns once |
| Ukrainian recognised as Russian, names garbled | Check `me_lang`; add names to `prompt` (the skill builds ~200 chars of names and terms from the config) |
| Lines like "Дякую за перегляд", "Thanks for watching" | Whisper hallucinations on silence; the common ones are filtered (`HALLUCINATIONS` in `transcriber.py`), add new ones there |
| After reinstalling with another `launchd_label` Terminal opens twice | Two LaunchAgents are running. Unload the old one: `launchctl bootout gui/$(id -u)/<old label>` and delete its plist in `~/Library/LaunchAgents` |
| The Notion page title shows `<mention-date …>` as text | The title was set on create, not on update. See section 7.2 |

---

## 11. Privacy and etiquette

- Audio is not stored: recognised phrases are appended to the `.md` immediately, audio
  buffers live only in memory.
- Transcripts live in the project folder (`<project>/live/`). Do not add them to public
  repositories.
- The Meetings DB page is internal. The skill never sends anything to the client.
- Tell participants you are keeping a transcript, as with any note taker. Consent rules
  differ by country and by client contract.

---

## 12. Checklist for a colleague

1. Apple Silicon Mac, macOS 14.2+, Python 3.10+, Xcode CLT.
2. `tools/live-transcriber` → `~/work/Tools/live-transcriber`, `bash install.sh`, both
   permissions for Terminal, both peaks above zero in `install.log`.
3. `pm-control-tower` plugin 1.6.0+, `live-tips/settings.yaml` filled in.
4. `~/work` connected in Cowork, the Notion connector enabled.
5. The project config has `Local Paths` and the Notion IDs from section 4, step 7.
6. A test call: `live tips <project>` → talk → `стоп` → check the wrap-up and the Meetings
   DB page.
