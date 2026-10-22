# 17. Live tips: a co-pilot on the call

[Українською](../uk/17-live-tips.md) · [Back to contents](README.md)

Live tips listens to a call together with the PM and posts tips in the Cowork chat. Audio is
transcribed locally on the Mac and never leaves it. The skill reads the transcript line by
line and checks it against the project context. It shows your speech or status at the start, then tips when they help: a request that
looks like a change request, a date or an estimate being promised, a statement that
contradicts a recorded decision, an inaccurate or incomplete answer, the other side switching
language, a moment where you can add a fact or ask a question. Instant cards from the prep
appear within 1-2 s of a trigger phrase, and the 🆘 HELP NOW button gives you the next
sentence to say when you are stuck mid-answer. Optional local add-ons tell the voices on the
other side apart (you name them, nothing is guessed) and find facts by meaning, not only by
keywords. Presentations and interviews are covered too (observer, interviewer, coach).
Live tips is in **beta**, and it is mostly glue around other people's open-source models: see
[section 13](#13-what-is-open-source-and-what-is-built-here). After the call the wrap-up
goes into the Meetings DB: into the meeting's existing page (for example the one Notion AI
Meeting Notes created) or into a new one when there is none.

There is also a **Live Tips app (beta)**: a native macOS menu bar app that runs the same loop
without a Cowork chat, with your own Claude API key. It reads the same rules and shows the same
tips window. See [section 14](#14-live-tips-app-beta).

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
  `state/status.json` and the transcript itself. Since 1.8.0 the skill does the mechanical
  steps (start, stop, status, prep check, state, wrap-up numbers) through one helper,
  `bin/lt`, instead of re-enacting them from prose.
- **The fast things run without a model.** A model loop is 10-20 s behind the
  conversation. So everything that must be instant runs in the recorder itself: instant
  cards, the fact book search, the ❓ question marker, the local part of 🆘 HELP NOW and the
  presentation tracker. The skill's main job before the call is to prepare those files.
- **Optional local layers.** Speaker identification (sherpa-onnx) and a semantic layer
  (Ollama with `bge-m3`) run on the Mac too. Both are off until installed, and neither ever
  delays a transcript line or a tip.

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
| `bin/read_delta.py` | One call per skill iteration: appends new tips for the window (`--emit-stdin`), merges the skill's `{"kind":"state"}` line into `<stem>.state.json`, waits up to `--wait` s for new transcript lines or window input (no wait on a question: adaptive settle), prints only what is new plus the `@@` lines (table in "How the skill is built"). `auto` as the offset takes it from the state file |
| `bin/lt` | The skill's helper: `start`, `status`, `stop`, `prep-check [--adopt-prep] [--fix]`, `state`, `wrapup-data`, `speakers`, `index`, `search`. Maps paths between the Mac and the Cowork folder with `--mac-root <work_root>` (or `LT_MAC_ROOT`) and says plainly what failed. Run `bin/lt` for the usage |
| `bin/install-voices.sh` | Optional: installs speaker identification (`sherpa-onnx` in `.venv`, the WeSpeaker model in `models/`, a self-test). Safe to re-run |
| `src/semantic.py` | Optional semantic layer: embeddings through a local Ollama (`bge-m3`), the per-project index, search by meaning |
| `src/prompter.swift`, `src/prompter.html` | The tips window (layout in "The tips window"); shows `*.tips.jsonl`, writes questions and settings to `*.inbox.jsonl`. Built into `bin/prompter` |
| `launchd/live-transcriber.plist.template` | LaunchAgent template (`WatchPaths` on `control/`) |
| `plugin/skills/live-tips/SKILL.md` | The skill core: invariants, priority order, the start checklist, the poll loop, the `@@` table, stop |
| `plugin/skills/live-tips/references/*.md` | Modules the core reads on demand (list in "How the skill is built") |
| `plugin/skills/live-tips/settings.yaml` | Everything personal: labels, paths, languages, tip rules, time zone |

Runtime folders (not in git): `.venv/`, `bin/audiocap`, `logs/`, `state/`, `control/`,
`models/` (the voice model), `voices/` (your local voice library: never put it in a repository).

### How the skill is built (1.8.0)

Until 1.7.0 the skill was one SKILL.md of about 97 KB, and long calls showed it: rules from
the middle of the file were forgotten. Since 1.8.0 it is a small core plus modules that are
read only when needed.

| Part | What is in it |
|---|---|
| `SKILL.md` (core) | The job in one sentence, six invariants, the priority order, the start checklist (each step with "done when"), the per-poll checklist, the `@@` line table, health and mic stall handling, triggers, tip diet and format, stop |
| `references/start.md` | Paths, project, the meeting concept (audience, type, mode), languages, fast start, the Whisper prompt |
| `references/speech.md` | Your speech or status round at the start, leading a stand-up, the opening |
| `references/sweep.md` | The context sweep in a subagent: brief, Insight Bank, instant cards, fact book |
| `references/window.md` | Window protocol: quick asks, ratings, settings and acks, `find:`, focus, language switching, chat questions, context refresh |
| `references/checks.md` | Answer check and questioning stretches (client and boss calls) |
| `references/culture.md` | Culture lens for client calls |
| `references/proactive.md` | Comment moments and initiative tips (only when proactive is on) |
| `references/research.md` | Background research jobs during the call |
| `references/presentation.md`, `references/hiring.md` | The two custom meeting types |
| `references/wrapup.md` | Wrap-up, the Meetings DB page, lessons |
| `references/start-chat.md`, `references/fallback-notion.md` | Start questions in the chat; the Notion AI fallback |

The rules that are never broken: the turn never ends during a call (every message goes
through `SendUserMessage`, the next action is always the next poll); one iteration is one
`device_bash` call with no blocking work after the recording started; facts or silence (a
tip carries a number, date, name, status, source, concrete question or next step, never
generic advice); no commitments for the PM (no estimates, dates or scope the PM does not
own); nothing is sent to anyone except the call summary in the internal Meetings DB; never
invent, never the long dash, no abbreviations in tips.

**Priority, highest first:** 🆘 HELP NOW > 🔴 (a direct question to you, "your turn", a new
requirement, a commitment, a serious error on a client call) > answers to your questions and
pending setting acks > a fact for the topic being discussed now > overdue state or prep >
proactive tips (only if on) > the plan (speech, checklist). The live topic always beats the
plan.

**Each poll** is one mechanical pass: anything urgent (`@@SOS`, `@@DUE`, an unacked
`@@SET`)? A 🔴 trigger or a typed question? A fact from the brief, cards or fact book that
fits the last ~60 s? Otherwise silence, and the next poll.

What `read_delta.py` prints besides the new lines:

| Line | Meaning |
|---|---|
| `@@SOS [t]` | 🆘 HELP NOW was pressed: top priority, the next sentence to say |
| `@@ASK [t] <text>` | You typed in the window (`find:`, `focus:`, quick asks, "стоп") |
| `@@SET <key>=<value>` | A setting from the window (`tips_paused`, `audience`, `call_type`, `proactive`, ratings, ...) |
| `@@CARD`, `@@LATE` | An instant card already showed; a tip landed after you started answering |
| `@@MODE presenting\|discussion` | You speak most of the last 2+ minutes, or not |
| `@@SPEAKERS S2="Name" S3=?` | Speaker names changed or a late voice tag arrived |
| `@@DUE prep\|state\|ack <key>\|wrapup` | Reminders: cards or facts missing, state not saved for 5 min, a setting not confirmed, no wrap-up item after the stop |
| `@@STATUS ...` | Health; `@@STATUS stale` when the recorder stopped updating `status.json` |
| `@@NOW HH:MM:SS` | The Mac time of this poll |

### Control and state files

| Path | Written by | Meaning |
|---|---|---|
| `control/start.json` | `lt start` or a person | Start request: `project_dir`, `title`, `slug`, `me_lang`, `langs`, `me_label`, `them_label`, `prompt`, and in the fast start `call_type`, `audience`, `proactive`, `hiring_role`, `people` (full names the window offers when it asks who is speaking), plus a unique `req_id`. Renamed to `control/active.json` on start |
| `control/stop` | `lt stop` or a person (`touch`) | Stop request. Content does not matter |
| `state/status.json` | transcriber | `state` (`loading_model` → `recording` → `stopping` → `stopped`, or `error`), `file`, `started_at` (with offset), `timezone`, `lines`, `queue`, `mic` (`ok`, `silent`, `muted`, `stalled`), `system_audio`, `errors`; since 1.8.0 also `seq` (+1 on every write, about every 2 s), `req_id`, `audience`, `call_type`, `proactive`, `tips_paused`, `ui_lang`, `mic_stall_streak`, `mic_auto_switched`, `last_question`, `speakers` and `speaker_now`, `semantic` and `index_state` (each with a reason when `off`) |
| `state/pid`, `state/launching` | transcriber / on-control.sh | Guard against a double start |
| `logs/transcriber.log`, `logs/launcher.log`, `logs/install.log`, `logs/audiocap-*.log` | all | First place to look when something fails |

### Transcript format

`<project folder>/live/<YYYY-MM-DD-HHMM>-<title>.md`:

```
# Live transcript: Status sync

- Проєкт: acme-portal
- Початок: 2026-10-10 23:48:02
- Мови: Я = en, дозволені = en+es
- Мікрофон: системний вхід за замовчуванням (навушники або Мак)
...
[23:48:11] Я (en): Can you hear me?
[23:48:15] Співрозмовник (es): Sí, perfecto.
[23:48:19] Співрозмовник [S2] (es): Empezamos con el reporte.

--- кінець запису 00:31:40 ---
```

With speaker identification on, lines of the other side carry a voice tag (`[S2]`); the
file stays append-only, and on stop the recorder writes `<title>.named.md` with the names
you gave. Next to the transcript live the call's working files: `<title>.brief.md` (the Live
Brief), `<title>.cards.json` (instant cards), `<title>.facts.json` (the fact book),
`<title>.state.json` (read offsets, poll stats and the skill's own keys: tips given, answers,
action items), `<title>.polls.jsonl` (every poll), `<title>.tips.jsonl` and
`<title>.inbox.jsonl` (the window), `<title>.speakers.json` and `<title>.semantic.jsonl`
(when those layers are on).

---

## 3. Requirements

- An Apple Silicon Mac (M1 or newer), macOS 14.2 or newer.
- Xcode Command Line Tools (`xcode-select --install`; `install.sh` offers it if missing).
- Python 3.10+ (`brew install python@3.12`).
- ~2.5 GB free disk (model + venv). Optional: ~30 MB for speaker identification, ~1.2 GB
  for Ollama with `bge-m3` (the semantic layer). 16 GB of memory is enough for all of it
  (section 5, "Local semantic layer").
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
4a. **Speaker identification (optional).** `install.sh` offers it at the end, or run
   `bash ~/work/Tools/live-transcriber/bin/install-voices.sh` (safe to re-run). It installs
   `sherpa-onnx`, downloads the WeSpeaker model (~26 MB) into `models/` and runs a
   self-test. Without it everything works, with one label for the whole other side.
4b. **Semantic layer (optional).** Install Ollama (`brew install ollama` or the app from
   ollama.com; it must be running during calls) and the model: `ollama pull bge-m3`
   (~1.2 GB). Then pre-index each project once, so the recorder has little to do during a call:
   ```
   ~/work/Tools/live-transcriber/bin/lt index "$HOME/work/Acme Portal"
   ```
   Later runs only re-embed new or changed files. Details: section 5, "Local semantic layer".
4c. **Updating from an older version.** Re-run `install.sh`: it rebuilds `audiocap` and the
   tips window (`bin/prompter`). The stealth switch and the new window need that rebuild.
5. **The skill.** The `pm-control-tower` plugin (1.8.0+) contains `live-tips` as a core
   `SKILL.md`, the `references/` modules and `settings.yaml`; upload all of them together. Fill
   in `plugin/skills/live-tips/settings.yaml`: `paths.work_root`, `paths.tool_root`, labels,
   languages, `user.name_aliases`, `user.timezone`. Plugin setup substitutes `~~home-folder` for you.
5a. **Keepalive plugin (recommended).** Install `tools/live-tips-keepalive` as a Cowork
   plugin (zip the folder into `live-tips-keepalive.plugin`). While a call is recorded, its
   Stop hook does not let Claude end its turn, so the tips loop cannot fall silent by itself.
   It fails open: no marker, an expired marker (2.5 h) or 400 blocks and it does nothing.
   The skill writes the marker at the start and removes it after the wrap-up.
6. **Cowork.** Connect the `work_root` folder in Claude desktop ("Add folder"). The skill
   reaches it as `$HOME/mnt/<folder name>`.
7. **Project config.** `projects/<slug>.md` needs `Local Paths` (the project folder, where
   `live/` is written), `notion.meetings_db`, `notion.project_page_id`,
   `notion.workspace_page_id`, and `client_language` for client calls. Optional: a
   `## Cultural Profile` section turns on the culture lens for client calls (section 5.0),
   and the team and client tables give the full names the window offers for speakers.
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

**Switching language mid-call.** Internal calls can mix Ukrainian and English.
Your microphone is recognised only among your own languages (`me_langs`, e.g. Ukrainian and
English), so Ukrainian never turns into Russian and an English part is recognised
correctly. The skill keeps a "language of the moment": when you are asked "say it in
English" or a guest asks you in English, a tip arrives at once with the gist in your
language and the phrase already in English, and phrases stay in English until you switch
back. Russian is not in the default sets on purpose: a Russian phrase is written as
Ukrainian. Add `ru` to `langs` only if a call really needs it.

> **🟠 Тепер англійською: статус релізу** (Now in English: release status)
> "Short update in English. The release is on track for Friday."

**The meeting: audience, type, mode.** Since 1.8.0 a call is described by two settings, both
`auto` by default, so you never have to pick anything to get a useful call. Correct them in
the window's ⚙ menu (Call) or say them in the request.

| Setting | Values | What it changes |
|---|---|---|
| Audience | `auto`, `team`, `client`, `boss` | Who is on the other side. `team`: our own people, candid, Ukrainian by default, no corrections of you on the call. `client`: English or the project's client language, strict 🔒 rules, the culture lens, the answer check. `boss`: an internal project where your own manager acts as the client: client rules for wording and commitments, Ukrainian by default, no culture lens. `auto` comes from your words, then the meeting schedule slot in the config, then the project config, and is corrected by the language and names heard |
| Type | `auto`, `presentation`, `interview` | Only the two custom types need a choice, because they need their own prep: a presentation gets an outline and a Now/Next tracker, an interview needs a role (below). Everything else (status, stand-up, a client sync, a deep dive into one subject) is `auto` |
| Mode | `presenting`, `discussion` | Never asked: detected live. When you speak most of the last 2+ minutes you are presenting and only 🔴 tips, 📌 facts and direct answers come; otherwise normal discussion |

There is no separate "working session" type any more: any call can turn into one. A round of
updates is handled by your speech and the "your turn" tip. When you lead a stand-up the
agenda shows who to hear from, and tips suggest follow-ups on vague updates and owners and
dates to fix.

**Interview** (type `interview`), pick your role. **Observer**: someone else is
interviewed, you see what a strong answer contains, then a ✓ / ~ / ✗ line on the answer.
**Coach** (you are the one being asked; value `coach`, the old `candidate` still works): a
steering committee, questions after a demo, a quarterly review, an audit, or a rehearsal before
any of these. Like a coach at the edge of the field: short cues during the game, while you play
it yourself. It keeps your prepared talking points, numbers and results at hand, reminds you of
the part of a question you have not answered yet and helps you keep the answer short and
structured. It uses only what you prepared (a talking points doc in your Knowledge Base: key
messages, numbers, results, prepared answers) and never invents facts; without a project, the call is filed under your personal Workspace. **Interviewer**: follow-up questions on weak answers and planned questions
not asked yet. After the call: a full analysis (answers table, strengths, gaps, signals,
recommendation, how the prompter performed).

**Client calls: culture lens and answer check.** With audience `client` and a
`## Cultural Profile` section in the project config, the prep adds a short culture lens to
the brief (where our culture and the client's differ most, and per attendee how to read
them). Ready phrases follow it (softer disagreement for an indirect client, short and
explicit for a direct one), and a downgraded complaint ("a bit concerning") or a change of
tone shows as a 🟠 signal. The answer check (did you answer what was asked, are the facts
right, did you promise something you do not own) runs on client and boss calls; on team
calls it stays silent, because there you think aloud.

**Proactive tips are off by default.** Comment moments ("you can add ...") and initiative
tips had the worst ratings in real calls ("we were not talking about that"). Since 1.8.0 the
default is facts or silence: answers to questions, facts for the live topic, "fix owner and
date", "your turn" and red flags. Turn proactive tips on in ⚙ Call when you want them
(`tips.proactive` in `settings.yaml`).

**When you ask the questions.** Any call can switch between you asking and you being asked.
The skill notices the stretches where you ask and the other side answers, tracks your
planned questions (asked, answered, partial) and tips where an answer is vague. The wrap-up
lists your questions with the answers.

**Prep ahead, and how early to start.** For an important call write "підготуй live tips до
<call>" (prepare live tips for <call>) any time before it. The skill reads every source in a
subagent (meetings, threads, topics, decisions, risks, reports, the tracker, project
documents, the newest files in the project folder, `live/lessons.md`) and saves the brief,
the instant cards and the fact book. At the start a prep younger than 3 hours is picked up
(`lt prep-check --adopt-prep`), so facts are there from the first second. Without a prep,
start a minute before the call or during it: the recording starts at once, the brief is built
in the first 1-3 minutes, and you can ask for a fresh one any time (⚙ Context, Refresh, or
"refresh context").

**Which prep is picked up.** Only a prep whose title matches the call title is used. The match
ignores case, spaces and hyphens, and one title may contain the other: "Weekly Standup" matches
`prep-...-acme-weekly-stand-up`. A prep made for another call is never used, so its brief and
internal facts cannot leak into the wrong meeting. Give the prep and the call the same title.

**The prep is done only when the files exist.** A sweep that returns a nice summary but no
`cards.json` and `facts.json` gave you nothing instant. So the sweep counts as done only when
`lt prep-check "<transcript>"` prints `verdict: OK` (brief, cards, facts and, for a
presentation, the outline are present and valid). On `FIX` the skill runs `--fix` (cards
derived from the facts) and writes what is still missing between polls; until then
`read_delta` keeps printing `@@DUE prep`.

### 5.1 During the call

1. A minute before the call, write in Cowork: **`live tips <project>`** (or "лайв
   підказки", "я на дзвінку", "дзвінок почався"). If no project is named, the skill asks.
   Language and length can be added: "live tips acme, internal, Ukrainian, 30 min".
2. The skill runs `lt start`: it checks the install, reuses a recording of the same call,
   refuses another project's recording (`BUSY`), drops `control/start.json` and waits for
   `recording` (5-20 s to load the model). The "Live
   transcriber" Terminal window opens by itself: you do not start it. The recording lives
   in it, because the macOS microphone and system audio permissions belong to Terminal.
   Minimise it (Cmd+M) or keep it behind other windows, but do not close it. If it is
   closed anyway, the recording stops cleanly and the transcript so far is kept.
3. The chat shows `Запис іде: <file>. Мови: я en, дозволені en+es.` ("Recording: …") with
   the detected audience and type, your speech appears in the window within ~30-40 s, and
   a minute or two later the sources line (which Current State and documents were used), the
   meeting checklist from the Live Brief (open topics, decisions, risks, promises from
   previous meetings, tickets) and "Підкажу, коли буде що додати." ("I will prompt you when
   there is something to add").
4. From then on the skill speaks only when a trigger fires, and only with a fact. Silence is
   a valid answer: a generic tip is worse than none.

| Level | When |
|---|---|
| 🔴 immediately | A direct question to you; "your turn"; a request that looks like a new requirement; you name a date or an estimate; a contradiction with a recorded decision; a dissatisfaction signal; on client and boss calls, you state a fact that contradicts the tracker or decisions |
| 🟠 as soon as it is ready | A fact for the topic being discussed right now (from the brief, cards or fact book); a decision, owner or date discussed but not fixed |
| 🟠 at most once per `active_rate_seconds` | A question unanswered for ~2 min; the other side switched to another language (short gist); 2/3 of the time with checklist items uncovered; 5 min before the end with decisions not obtained |
| 🟠 only with proactive on, at most once per `comment_rate_seconds` | Comment moments and initiative tips (`references/proactive.md`) |
| silent | Action items, new requests, commitments: they go into the wrap-up |

**Fast start.** By default (`start.mode: window`) the chat asks only what decides where
the recording goes: the project when you did not name it, or the company for your own
interview. Everything else starts from `auto` or the defaults and you correct it in the
window's ⚙ menu: the language and the microphone switch at once without losing the
transcript, audience, type and your interview role rebuild the prep. `start.mode: chat`
keeps the start questions in the chat. You can also steer with one line at any moment:
the format ("discussion", "my presentation", "with the boss") and where to look ("look at
epic X", "the thread about Y").

**Standby start: open the window before the call.** Start a few minutes early (`"standby": true`
in `lt start`; in the app, **Recording starts: When the call begins**). The tips window opens at
once, but nothing is transcribed or written and there are no microphone warnings while you wait
(`state: standby` in `status.json`). Recording starts by itself when the other side has been
speaking for about 5 seconds (`standby_auto_s` in `config.json`), or at once when you press the
green **Start** in the window (or `touch control/go`). Your own voice in the room never starts
it. The last 20 s heard before the switch are transcribed, so the first sentence is not lost, and
the transcript gets a `--- дзвінок почався ---` (call started) marker.

**Context refresh during a call.** For an unexpected call, or when the talk moves to
something the brief does not cover: press ⚙ Context, Refresh, or write "онови контекст" / "refresh context" /
"глянь треди по X" (look at the threads about X). A subagent re-reads the sources plus the
topics of the last 10 minutes, the brief and the cards are updated, and the skill catches up
with everything said meanwhile: 1-3 minutes without new facts, nothing is lost.

**The loop must not fall silent.** Tips exist only while Claude's turn runs. The skill never
ends its turn with a text answer during a call, the keepalive plugin (section 4) blocks it
mechanically, and the window shows a red "Claude is not listening" alert after 75 s
without a poll: then write "continue" in the Cowork chat. The skill then reads the gap from
`lt state`, tells you how long it was and catches up on the missed lines. `read_delta` also
nudges the skill itself: `@@DUE state` when its state was not saved for 5 minutes, `@@DUE
ack` for a setting it has not confirmed, `@@STATUS stale` when the recorder stopped updating.

### The tips window

So you do not have to look at the Cowork window during a call, tips appear in a separate
small window on top of everything else. The recorder opens it when the recording starts,
at the top centre of the screen, under the camera.

The layout since 1.8.0, top to bottom (hover any control for a hint):

- **Top bar:** a recording dot, the call title, the timer, your talk share, `🎙` mic mute
  and `⚙` (one menu for everything else). A small "Tips paused" pill shows while tips are
  paused.
- **"Now speaking" line** under it (with speaker identification on): `🗣 Maria` or
  `🗣 Speaker 2`. Click it to rename that speaker, move one line to someone else ("this line
  was someone else") or merge two speakers. Hidden when you speak or nobody does.
- **One alert slot:** only the most important warning at a time, with an action button
  where one helps: "Use Mac mic" when the headset mic froze, "Back to headset" after an
  automatic switch, the red "Claude is not listening".
- **Dock:** the agenda as one line with progress (click to expand: the points with ✓ / ○;
  for an interview the questions, when you lead a stand-up the people), Now/Next in a
  presentation, then pinned cards: 📌 on any tip pins it, the speech, the checklist, the
  status and the wrap-up can be pinned too. An unpinned card goes back to its place in the
  list.
- **Tips:** the newest on top in a large font, older ones below and dimmer.
- **Bottom row:** one input, `⏸` / `▶` and `🆘`, plus the quick-ask chips (below).
- **`🎙` mute.** The recorder listens to the Mac's microphone and cannot see whether you are
  muted in Meet or Zoom: the state of a meeting app's mute button is not readable from outside,
  and a wrong guess would silently drop your words, so it is a manual button on purpose. Why it
  exists: in a cafe, with music or people talking nearby, you are muted in the meeting, but
  the microphone still hears the room and Whisper would write it down as if you said it. What
  the button does: it turns red (`🔇`), the recorder stops transcribing the microphone (the
  other side is still recorded), the transcript gets the lines `--- мікрофон вимкнено HH:MM:SS ---`
  and `--- мікрофон увімкнено HH:MM:SS ---`, the status shows `mic=muted`, and the skill does
  not count your silence as a problem and does not run the answer check for that time. Press
  it again when you unmute. Every call starts unmuted.
- **The input.** Typing searches the fact book on the Mac at once, no model involved: the
  matching facts show under the field as you type. Enter sends the text to Claude as a
  question (`find: <words>` when the local search found nothing useful: Claude then searches
  the fact book, the project index and one narrow lookup, and adds the fact to the book).
  Typing "стоп" (stop) ends the call like in the chat.
- **`⏸` / `▶` pause tips.** The talk went aside (small talk, an unrelated topic)? Press
  `⏸`: the recorder keeps recording and transcribing and the skill keeps listening and
  logging action items, but nothing automatic appears: no instant cards, no 📌 auto facts, no
  ❓ markers, "Who is speaking?" cards wait in a queue. The input, 🆘 and answers to your
  questions still work. `▶` resumes from the live topic of the last ~2 minutes, not from
  where tips stopped.
- **`🆘` HELP NOW.** For the moment you are speaking and cannot type. At once, with no model,
  the recorder shows the best matching facts and cards for the topic of the last minute (by
  meaning with the semantic layer, by keywords without it) and up to 2 snippets from the
  project folder. Claude then sends one 🔴 item with the next sentence you can say right now:
  the answer to the open question, the fact with its number, or a bridge ("Let me give you
  the exact number after the call."). It ignores every rate limit.
- **❓ question marker.** When the other side asks something, the recorder marks it in the
  window at once (`❓` and the first words of the question); Claude's answer replaces it.
  Since 2026-10-22 only real work questions get it: a line that names you and asks, a line
  with a work word (estimate, deadline, status, price, release...) or a question about time or
  amount ("when...?", "how much...?"). Songs, small talk and a bare "?" do not.
- **Quick asks** (chips by the input): **Suggest reply** (a ready answer or comment on the
  current topic), **Catch me up** (the last ~5 minutes in 3-5 lines), **Decided so far**
  (decisions and action items with owners and dates), **What to ask now** (1-2 questions for
  the open points). Answers come from the transcript, no lookups, in a few seconds.
- **⚙ menu**, five parts:
  - **Call:** type, interview role, audience, language, microphone, proactive tips (and their
    comment rate when on). Language and microphone are applied by the recorder at once (a
    `--- мова ---` / `--- мікрофон ---` line marks the switch); the rest goes to the skill and
    shows as pending until the skill confirms it.
  - **Display:** text size slider (also Cmd+ and Cmd-), opacity (only the background fades: the text stays fully opaque
    with a soft halo and stays readable at low opacity), always on top, the interface
    language (English by default, or Ukrainian), Stealth (below) and the "Local AI (Ollama)"
    switch (the semantic layer on or off for this call).
  - **Context:** "Brief from HH:MM" and Refresh (a context refresh, above).
  - **Diagnostics:** what the old status line showed: recording state, line count, delays,
    warnings.
  - **Help:** every button and option explained in the window itself.
- **Interface language.** English by default; Ukrainian in ⚙ Display. Tip gists follow it: in
  Ukrainian when the interface or the call is Ukrainian, otherwise in English. Ready phrases
  always come in the language you are expected to speak. Quick asks reach the skill in English
  whatever the interface language.
- **⚡ Instant cards.** The prep writes 15-40 cards (trigger phrases in every call language
  and a ready tip) into `<transcript>.cards.json`. The recorder matches every new line itself
  (by keywords, and by meaning with the semantic layer) and shows a card within 1-2 s,
  before Claude thinks; Claude then only adds what the card could not know.
- **✓ / ~ / ✕ on every tip.** Used it, partly, or not useful. After ~ or ✕ the window offers
  reason chips (late, off topic, wrong fact, too long, not now) and a short comment. The skill
  acts by the reason: a wrong fact is checked and fixed at once, "too long" makes tips of
  that kind shorter, two "off topic" switch a card off for the rest of the call. 🔴 tips and
  📌 facts are never muted. The wrap-up counts all of it.
- **Delay on view.** Each tip shows how long after the phrase it appeared ("+18s", orange
  over 20 s); Diagnostics shows the median and "transcript N s behind" when speech
  recognition is slow. A tip that lands after you started answering is shown dimmed and
  logged for the lessons.
- **Talk meter** in the top bar: your share of the talk time and your current monologue
  (orange after 1:30).
- **It is an ordinary window:** drag it, resize it, minimise it (yellow button or Cmd+M)
  and close it (red button or Cmd+W). Closing it does not stop the recording. It remembers
  its position and size.
- **Closed it by accident?** Write "відкрий суфлер" (open the prompter) in the chat, or run
  `touch ~/work/Tools/live-transcriber/control/prompter` in Terminal. The window opens again
  within a second with every tip since the start of the call.
- **Stealth and screen sharing.** ⚙ Display, Stealth is on by default: the window asks macOS
  to keep it out of screen sharing and screenshots (`sharingType = none`). Turn it off when
  you want to demo the window or take a screenshot of it. The switch needs the window built
  by 1.8.0 (re-run `install.sh` after updating). Whether a given meeting app honours stealth
  depends on how it captures the screen, so check it once yourself (section 10).
  **Verified 2026-10-11:** Google Meet in Chrome on macOS 26, sharing the entire screen, the
  window is not in the shared image. Other apps (Zoom, Teams) not verified yet. If in doubt:
  share a window or a tab, not the entire screen.
- **Where tips go** is set by `tips.output` in `settings.yaml`: `window` (the template
  default), `chat` or `both` (when the key is missing). The chat stays as a fallback.
- **Demo without a call:** `python3 ~/work/Tools/live-transcriber/bin/demo_prompter.py`
  opens the real window with a scripted call (about 2 minutes). `bin/prompter --demo` shows
  only three static tips.

Under the hood: the skill appends tips as JSON lines to `<transcript>.tips.jsonl`, the
window shows them; questions typed in the window go to `<transcript>.inbox.jsonl`, and
`read_delta.py` hands them to the skill as `@@ASK` lines. Settings, ratings, 🆘 and ⏸ go
the same way and arrive as `@@SET` and `@@SOS`.

### Presentation split view

With meeting type **Presentation** and a prep that has slides (`<stem>.slides.json`, written by
the presentation prep next to the outline), the tips window becomes twice as wide and splits into
2 halves: slide cards with the full text of your speech, and the usual tips stream. The skill and
the app behave the same.

- **One slide at a time.** Cards snap into place; move with the arrow keys, the ◀ ▶ buttons or
  the mouse wheel.
- **Timer.** Set the limit in minutes: the planned time of every slide scales to fit it. The
  pace line shows your words per minute (slow, ok, fast).
- **Auto** turns the cards on schedule with a short signal and warns 10 s before the end of a
  slide. Turn it off to move by hand.
- **Trim** hides the paragraphs marked as safe to skip, for when you run late.
- **My slides / All slides.** When several people present, show only your part or the whole deck.
- **Paragraph kinds** on a card: read aloud; may skip (dimmed, labelled); a hint for you, not to
  be read (small, grey); a colleague's line right before your part (orange), so you know when to
  start.
- **Plan vs actual.** At the end a table compares the planned and the actual time of every slide.
- **📑** hides or shows the cards, **⇄** swaps the 2 sides (remembered between calls). The window
  grows towards the cards, so the tips stream stays where you put it.

### Speaker identification (optional)

The system channel holds everyone on the other side, so without this layer they are all
`Співрозмовник` (them). With `bin/install-voices.sh` installed, the recorder tells the voices
apart on the Mac (sherpa-onnx with a WeSpeaker voice model) and you name them.

- **Clusters.** Every phrase of 1 s or more gets a voice print in a separate thread. Phrases
  join the closest speaker, a new voice opens `Speaker 1`, `Speaker 2`, ... Lines are tagged
  in the transcript (`Співрозмовник [S2] (es): ...`).
- **"Who is speaking?"** After ~8 s of speech of a new voice, a card asks for a name, with
  the last quote and its time. The suggestions come from your local voice library (people
  you named on earlier calls, with a match dot) and from the project people (full names from
  the project config). Pick one, type a name, or Skip. **A name is never assigned
  automatically:** you decide, the skill never guesses.
- **Fix it live.** The "Now speaking" line opens rename, "this line was someone else" and
  merge (one person split into two speakers). Every change applies to the whole call, past
  and future lines.
- **It never slows anything down.** A line and a tip never wait for a speaker: the voice tag
  may arrive a few seconds after the line, and the skill gets it as `@@SPEAKERS`. Tips,
  action items and the wrap-up use the names when they are known.
- **After the call** the recorder writes `<title>.named.md`, the transcript with names (the
  original file stays untouched), and the wrap-up counts lines per person.
- **Where voice prints live:** only on this Mac, in `<tool_root>/voices/voices.json` (at most
  20 prints per person). Never put `voices/` in a repository. Section 11 has the privacy side.

Thresholds and how they were tuned: the tools README, "Speaker identification".

### Microphone reliability

A headset mic can freeze without any notice from macOS, typically right after you unmute
in Meet: no audio at all arrives, and the call goes on without your words. Since 1.8.0 the
recorder watches for it:

- **Watchdog.** No mic audio for 12 s, or only exact digital zeros for 10 s while you are not
  muted, counts as a stall. The recorder restarts `audiocap` (terminate, then kill), backs off
  up to 60 s between tries and never gives up. Recovery counts only when real audio arrives
  after the restart.
- **Automatic switch.** After 2 failed restarts in a row it switches to the Mac's own
  microphone (`--- мікрофон: перемкнув на мікрофон Мака ---` in the transcript). The window
  alert offers "Back to headset"; while the mic is stalled it offers "Use Mac mic".
- **Direct capture (2026-10-22).** Some USB headsets and dongles deliver no audio at all to
  macOS's usual audio engine (AVAudioEngine), and a start could hang there. `audiocap` now reads the input device
  directly when the engine gives no frames (`--mic-backend direct`), and the recorder starts the
  microphone before the system audio tap, because starting both at once could hang the mic.
- **Start-up watchdog.** `audiocap` that hangs at start (for example on a permission prompt
  nobody answers) is stopped after a timeout and started again, so the recording does not
  sit silently.
- **One marker per episode.** The transcript gets one `--- мікрофон завис ---` line per
  stall episode and `--- мікрофон відновився ---` when audio is back, not a line per retry.
  The skill sends one 🔴 "Мікрофон не пишеться" (mic is not recording) and one "Мікрофон
  повернувся" (mic is back), and never claims you have not spoken while the mic was stalled
  or muted. The wrap-up lists the restarts and the minutes of your speech that may be missing.

### Local semantic layer (optional)

Keyword tips work without it. With a local embedding model (Ollama with `bge-m3`) the
recorder also understands paraphrases in Ukrainian, English and Spanish: "how long will the
admin history take?" finds the fact "Admin audit logs: 16 h".

- **During the call:** facts and cards fire by meaning, not only by keywords; 🆘 HELP NOW
  picks facts by the topic of the last minute plus 1-2 snippets from the project index; the
  `find:` search and `lt search` look through the project's files. Every line is embedded in
  a separate thread with a short timeout: transcription and tips never wait for it.
- **The project index.** `lt index "<project folder>"` embeds the project's text files
  (`.md`, `.txt`, `.csv`, small `.json`), including the local Notion mirror (`_notion/`),
  into `<project>/.livetips-index/`. It is incremental (only new or changed files) and
  during a call the recorder indexes fresh files in the background, only while transcription
  is idle. Skipped: `.git`, `repos/`, archives, binaries, files over 2 MB, call artefacts
  (only transcripts are indexed) and anything that looks like a secret (`secrets` folders,
  `.env`, names with password, token, credential or API key). Add `.livetips-index/` to
  `.gitignore`.
- **Per project, not the whole work folder.** One index per project keeps clients apart (a
  snippet from another client's folder must never surface on a call), stays small enough to
  build in minutes instead of hours, and keeps the hits precise. A shared folder can be added
  with `--extra`.
- **Is it worth it?** Every hit and near miss is logged with its score to
  `<title>.semantic.jsonl`, and the wrap-up adds one line with the numbers for the call, so
  you can judge on your own calls whether it helps. The "Local AI (Ollama)" switch in ⚙
  Display turns it off for a call; when Ollama is not running the layer is `off` with the
  reason and the recorder retries every 30 s.
- **16 GB Mac.** `bge-m3` takes about 1.2 GB next to Whisper (about 1.6 GB); a call makes
  about 7 short embedding requests a minute. Pre-index before the call. Under memory
  pressure set `index_enabled: false` (no background indexing) or `semantic_enabled: false`
  in `config.json`.

Commands, thresholds and the index format: the tools README, "Semantic layer (Ollama)".

### What a tip looks like

Built for a small Cowork window at the top centre of the screen, under the camera, so the
eyes do not wander. Every tip is 2-5 short lines (~45 characters), no tables, headings or
links.

1. **Gist**, bold: emoji and what is happening, max 7 words. Always first, to get the point
   in one second. Language: Ukrainian when the window interface or the call is Ukrainian,
   otherwise English.
2. **Phrase**, in quotes, in the language of the call. A ready speech to read aloud as is,
   not bullet points. 1-2 sentences. In English: simple sentences up to 12 words,
   everyday words, present or future simple, active voice, no idioms or long clauses.
3. **Facts**: up to 3 lines of up to 8 words, with numbers. A tip carries one phrase or one
   fact line; longer only for the speech, "your turn", the agenda, catch me up and 🆘.
4. **Source**: one short italic line (topic and date).

**No abbreviations:** "a new request", not CR; "date", not ETA. No ticket keys either, the
topic name instead. People and product names stay as they are.

Examples on an English call with the Ukrainian interface (the English interface gives the same gists in English):

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
   `end live` (or type "стоп" in the window). The skill saves its state and runs `lt stop`,
   which waits up to 60 s for the last phrases to be transcribed; then it reads the final lines.
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
covered, the transcript path, the link to the Notion page. People are named as you named
them in the window; unnamed voices stay "Speaker N". Then the skill only offers next steps
(report, change-request, risk-register) and runs nothing without a command.

All numbers come from `lt wrapup-data`, never counted by eye: lines, languages and lines per
speaker, tips shown by kind, ratings with reasons, cards fired, 📌 facts, late tips, tip
delays (median and max), the longest gap between polls, mic stall restarts and one line on
the semantic layer. A short wrap-up item ("Дзвінок завершено", call ended) always goes into
the window too; `read_delta` prints `@@DUE wrapup` until it is there. Client calls add the
client signals (quotes with times) for `client-satisfaction-tracker`.

### 7.2 The Meetings DB page (automatic)

**No duplicates.** You often record the same call with Notion AI Meeting Notes. So the skill
first looks for this meeting's page: the link you gave, else Notion AI meeting notes started
within 20 minutes of the recording, else Meetings DB pages of that time window (it searches
again after ~60 s: Notion AI may finish its page late). Found one: it appends one section
"Live Tips: підсумок і роздуми" at the end, whatever the page already holds, never edits
existing blocks, adds its transcript only when the page has none, and fills `Project`,
`Workspace`, `Date` only when empty. Several candidates: it asks which one. None: it creates
one page in the project's `notion.meetings_db`:

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

### 7.3 Lessons from your notes

Anything you write during the call that is not a question ("here the better answer was ...",
"no such tips", "too late") is collected together with the ✓ / ✕ ratings and loop problems.
After the call the skill shows two numbered lists: **project lessons** (they go into
`<project folder>/live/lessons.md`, which every next prep of that project reads first and
turns into brief rules and cards) and **skill changes** (problem, change, where). Nothing
changes without your "yes"; approved skill changes come as a card to save (or a `.skill`
package) plus a line in `Skills/live-tips-changelog.md`.

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
| `user.tips_language` | Language of the chat wrap-up. Tip gists follow the window interface language (English by default) unless the call is in Ukrainian |
| `user.name_aliases` | How people call you on calls (all forms and languages): the "Your turn" trigger and a hint for Whisper |
| `user.timezone` | Fallback IANA zone. Usually not needed: live-transcriber writes the Mac clock zone and offset into `status.json` itself (Notion accepts `Europe/Kiev`) |
| `start.mode` | `window` (default): the recording starts at once with defaults (audience and type `auto`); audience, type, role, language and microphone are corrected in the window's ⚙ menu. `chat`: the start questions are asked in the chat first |
| `start.ask` | Only with `start.mode: chat`: `true` asks the call language and the microphone; `false` uses the defaults from this file |
| `audio.mic` | Which microphone to record: `default` = whatever the Mac uses as input now (AirPods, Jabra or other headsets, or the Mac itself), `mac_mic` = always the Mac's own microphone. You can also say it when starting: "live tips, mac mic" |
| `workspaces` | Optional: general calls about several projects (title, `project_root`, list of project slugs); listed first in the project question |
| `project_roots` | Optional: the recording folder per project slug, overrides the project config |
| `hiring.coach` | Optional, for the Coach role (the old key `hiring.candidate` is still read): `root` (recordings of calls without a project), `workspace` (your personal area in the Workspaces DB: Coach calls without a project are filed there, and Knowledge Base docs linked to it serve as prep notes), `facts_doc` (a Knowledge Base doc with your talking points: key messages, numbers, results, prepared answers; the only source of facts about you), `notes_folder` (optional local prep notes) |
| `paths.work_root` | Mac folder connected to Cowork |
| `paths.tool_root` | Where live-transcriber lives |
| `languages.internal` | `me_lang` (main mic language), `me_langs` (languages you may switch to, e.g. `[uk, en]`), `langs` (all call languages, the first is the main one, e.g. `[uk, en]`) for internal calls |
| `languages.client` | The same for client calls; `from_project` = `client_language` from the config |
| `languages.per_project.<slug>.<internal\|client>` | Override for a specific project |
| `tips.active_rate_seconds` | Minimum gap between non-red tips that do not answer the live topic (default 45). A tip that answers what is being discussed goes out as soon as it is ready |
| `tips.rate_seconds` | The same, when active mode is off (default 90) |
| `tips.proactive` | `off` (default since 1.8.0) or `on`: comment moments and initiative tips. Also in ⚙ Call |
| `tips.comment_rate_seconds` | Only with proactive on: minimum gap between comment and initiative tips (default 60; ⚙ Call overrides it, `0` = off). `tips.comment_prompts` from older settings still works as the on/off for comment moments |
| `tips.late_after_s` | `read_delta` marks a tip late when you started answering more than this many seconds before it landed (default 6) |
| `tips.research` | Background research jobs during the call: `enabled`, `max_jobs`, `max_running` |
| `tips.answer_check` | Check your own answers (client and boss calls; silent on team calls) |
| `tips.side_talk_summary` | Summarise the other side talking among themselves in another language |
| `tips.output` | Where tips go: `window` (the tips window, template default), `chat` or `both` (when the key is missing) |
| `tips.idle_stop_minutes`, `tips.hard_cap_minutes` | Auto-stop |
| `model_hint` | Which Claude model to use for the session (see section 5.0) |

**Where `settings.yaml` lives.** It is a file inside the `live-tips` skill in your Claude
account, not a separate file on the Mac. To change it, edit the file in the skill folder and
upload the skill again (a zip with the `live-tips/` folder holding `SKILL.md`, the
`references/` folder and `settings.yaml`; a zip without `references/` gives a skill that
says a module is missing) in Claude settings, Skills section. The template in this
repository is `plugin/skills/live-tips/settings.yaml`.

Fine recognition parameters (`vad_mode`, `end_silence`, `max_segment`, echo window,
`lang_bias`, `gap_resync`) are in
`DEFAULTS` in `src/transcriber.py` and can be overridden in `config.json`. The optional
layers are tuned there too: `speakers_enabled`, `speaker_join` (0.45), `speaker_suggest`
(0.5), `speaker_prompt_s` (8); `semantic_enabled`, `index_enabled`, `semantic_fact_min`
(0.55), `semantic_card_min` (0.60), `semantic_margin` (0.08). The tools README explains each.

---

## 10. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Red "Claude is not listening" in the window | Claude's turn ended and nothing reads the call. Write "continue" in the Cowork chat. Install the keepalive plugin (section 4) so it does not happen |
| No ⚡ cards appear, the fact search finds nothing | Cards and facts come from the prep: `<transcript>.cards.json` or `.facts.json` is missing (the brief is still being built, or the sweep returned without them). `lt prep-check "<transcript>"` says what is missing; `--fix` derives cards from the facts. Refresh in ⚙ Context or prep ahead |
| Red "Мікрофон не пишеться" (mic is not recording), `mic=stalled` | The mic stream froze (often after an unmute in the meeting app). The recorder restarts it by itself and switches to the Mac mic after 2 failures; press "Use Mac mic" to switch at once. `lt status` shows `mic_frames_growing=yes\|NO`. If it keeps happening with one headset, set `audio.mic: mac_mic` |
| The mic switched to the Mac by itself | The automatic switch after 2 failed restarts. Press "Back to headset" in the alert, or ⚙ Call, Mic |
| No "Who is speaking?" card, no "Now speaking" line | Speaker identification is not installed or failed: `lt status` / `status.json` show `speakers: off` with the reason. Run `bin/install-voices.sh`. The card also waits while tips are paused |
| One person shows as two speakers, or two people as one | Thresholds: merge the two in the "Now speaking" popover, or fix one line. If it happens on every call, adjust `speaker_join` in `config.json` (stricter splits people, looser mixes them) |
| `semantic: off` in Diagnostics or `lt status` | Ollama is not running or the model is missing (`ollama pull bge-m3`); the reason is in `semantic_reason`, the recorder retries every 30 s. Keyword tips keep working |
| `lt search` prints `NOTE: plain text search` | Ollama could not be reached (from the Cowork VM it asks the running recorder); start Ollama on the Mac or pre-index with `lt index` |
| The Mac slows down during calls (16 GB) | Turn off "Local AI (Ollama)" in ⚙ Display, or set `index_enabled: false` / `semantic_enabled: false` in `config.json`; pre-index before calls |
| The stealth switch does nothing, or the window shows in screen sharing with stealth on | The window was built by an older version: re-run `install.sh` to rebuild `bin/prompter`. If it still shows, the meeting app ignores `sharingType = none` (see the next rows) |
| `lt` says the path is not mounted or not found | Pass `--mac-root <work_root>` (or set `LT_MAC_ROOT`): the Mac folder mounted in Cowork as `$HOME/mnt/<basename>`. Paths are never guessed |
| `lt start` prints `BUSY` | Another project is being recorded. Stop it first (`lt stop`); the skill never mixes two calls |
| `@@STATUS stale` | The recorder stopped updating `status.json` (Terminal window closed, the Mac asleep, a crash). `lt status` and the tail of `logs/transcriber.log` say which |
| Two pages for one meeting in the Meetings DB | An older skill version created a page without looking for the Notion AI one. Current versions search first; merge the two by hand once |
| Closed the tips window by accident during a call | Write "відкрий суфлер" (open the prompter) in the chat, or `touch ~/work/Tools/live-transcriber/control/prompter`. It reopens within a second with every tip so far; the recording never stopped |
| The tips window did not open | `bin/prompter` is not built: re-run `install.sh` and check the `build prompter` block in `logs/install.log`; launch errors are in `logs/prompter.log`. Tips go to the chat meanwhile |
| Participants see the window while you share the entire screen | The meeting app captures the screen in a way that ignores `sharingType = none`. Share a window or a tab instead of the entire screen, or minimise the window while sharing |
| `start.json` is there but the recording does not start within 60 s | The LaunchAgent is not loaded or the install was never run. `launchctl list \| grep live-transcriber`; if empty, run `install.sh`. The skill then renames the file to `start.json.pending` so the recording does not start by surprise later |
| `system=silent`, the transcript has only "Я" lines | No permission to record system audio. System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only → Terminal. Check: play sound and run `bin/audiocap --source system --seconds 5 \| wc -c`, it must be above zero |
| Your voice is thin or garbled with a headset (the headset switched to its call mode) | Record the Mac's own microphone: `audio.mic: mac_mic`, or say "mac mic" when starting. Keep the headset in the meeting app. In a noisy place the Mac microphone also picks up the room, so use the `🎙` mute |
| `mic=silent` | Microphone permission for Terminal (Privacy & Security → Microphone) or the wrong input device |
| Many `mic restart: engine configuration change` in `audiocap-mic.log`, several a minute; "Я" lines garbled and their times lag behind | A restart loop, fixed in 1.6.3: re-run `install.sh` to rebuild `audiocap`. The `health` line shows `restarts=N`; one restart per headphone switch is normal |
| `no IO from tap-only aggregate, retrying with output device as clock` | Normal: the fallback clock mode of the system tap |
| `queue` grows, tips arrive late | The Mac is busy (video, builds). Transcription catches up; the skill warns once |
| Ukrainian recognised as another language, names garbled | Check `me_lang` and that the main language is first in `langs`; the skill puts names into `prompt` as one short sentence |
| Lines like "Субтитры создавал ...", "Продолжение следует...", "Thanks for watching", a list of names repeated many times | Whisper artefacts: the model learned subtitle credits from internet videos and recalls them on silence, music or chopped audio, and repeats the `prompt` names in a loop. Not in the audio, not a virus. Filtered by `HALLUCINATION_PATTERNS` and the loop check in `transcriber.py`; add new patterns there |
| One-word lines such as "Дзвінок.", "Наступного року.", "Відповідь.", "м-м-м", and Ukrainian lines tagged `(en)` | The first is Whisper repeating the first word of the `prompt` on noise, the others are its noise phrases and fillers. They are dropped (`clean_text`: one or two words that all come from the prompt, standalone noise phrases, pure fillers). A Cyrillic line tagged `(en)` is a wrong language tag by the model: the tag now follows the script of the text. Order of lines can differ by up to ~15 s from the real order: every line carries the time its phrase started |
| The transcript is readable but weak for Ukrainian | Try `"model": "mlx-community/whisper-large-v3-mlx"` in `config.json`: more accurate, but it needs 2-3 times more processing time per phrase, so lines and tips appear later. First compare both models on your own audio with `bin/bench.py` (section "Comparing models" in the tools README) |
| After reinstalling with another `launchd_label` Terminal opens twice | Two LaunchAgents are running. Unload the old one: `launchctl bootout gui/$(id -u)/<old label>` and delete its plist in `~/Library/LaunchAgents` |
| The Notion page title shows `<mention-date …>` as text | The title was set on create, not on update. See section 7.2 |

---

## 11. Privacy and etiquette

- Audio is not stored: recognised phrases are appended to the `.md` immediately, audio
  buffers live only in memory.
- Transcripts live in the project folder (`<project>/live/`). Do not add them to public
  repositories.
- The Meetings DB page is internal. The skill never sends anything to the client.
- **Voice prints are biometric data.** Speaker identification stores voice prints of the
  people you name (clients included) in `voices/` on your Mac only; nothing leaves it. In many
  jurisdictions a voice print is personal biometric data that needs a legal basis or consent.
  Tell participants, follow your company's and the client's rules, and do not use the layer
  where you may not. Delete a person from `voices/voices.json` when asked; delete the folder to
  forget everyone. Never put `voices/` in a repository.
- The semantic index (`.livetips-index/`) and its logs are local files in the project folder;
  the recorder talks only to Ollama on `127.0.0.1`. Secrets are excluded from the index;
  keep the index out of git.
- Tell participants you are keeping a transcript, as with any note taker. Consent rules
  differ by country and by client contract.

---

## 12. Checklist for a colleague

1. Apple Silicon Mac, macOS 14.2+, Python 3.10+, Xcode CLT.
2. `tools/live-transcriber` → `~/work/Tools/live-transcriber`, `bash install.sh`, both
   permissions for Terminal, both peaks above zero in `install.log`.
3. `pm-control-tower` plugin 1.8.0+ (the skill with its `references/` folder),
   `live-tips/settings.yaml` filled in, including `user.name_aliases`.
3a. Optional: `bin/install-voices.sh` for speaker names; Ollama with `ollama pull bge-m3` and
   `lt index "<project folder>"` for the semantic layer.
4. `~/work` connected in Cowork, the Notion connector enabled.
5. The project config has `Local Paths` and the Notion IDs from section 4, step 7.
6. A test call: `live tips <project>` → talk → try 🆘 and ⏸ → `стоп` → check the wrap-up
   item in the window, the wrap-up in the chat and the Meetings DB page.

---

## 13. What is open source and what is built here

Honest bookkeeping. The heavy lifting (speech recognition, voice embeddings, text embeddings,
the language model that writes the tips) is other people's work, mostly open source. This
project is the glue, the workflow and the product decisions around those models. If that is
"own development", it is development of a tool around ready engines, not of the engines.
The same list is on the website: [tower.bodco.pm/open-source](https://tower.bodco.pm/open-source/).

### 13.1 Third-party components

| Component | What it does here | Licence | Source |
|---|---|---|---|
| OpenAI Whisper, `large-v3-turbo` weights | Speech recognition of both channels | MIT (code and weights) | [github.com/openai/whisper](https://github.com/openai/whisper) |
| Apple MLX | Runs Whisper on the Apple Silicon GPU | MIT | [github.com/ml-explore/mlx](https://github.com/ml-explore/mlx) |
| `mlx-whisper` and the `mlx-community` weights | Whisper port for MLX and the converted weights | MIT | [pypi.org/project/mlx-whisper](https://pypi.org/project/mlx-whisper/), [github.com/ml-explore/mlx-examples](https://github.com/ml-explore/mlx-examples) |
| py-webrtcvad (WebRTC VAD) | Speech or silence for every 30 ms frame | MIT (wrapper), BSD-3-Clause (WebRTC code) | [github.com/wiseman/py-webrtcvad](https://github.com/wiseman/py-webrtcvad) |
| NumPy | Audio buffers, vectors, cosine similarity | BSD-3-Clause | [numpy.org](https://numpy.org/) |
| sherpa-onnx (k2-fsa) | Computes speaker embeddings from audio | Apache-2.0 | [github.com/k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) |
| ONNX Runtime | Inference engine under sherpa-onnx | MIT | [github.com/microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) |
| WeSpeaker ResNet34 (`wespeaker_en_voxceleb_resnet34_LM`) | The voice model that tells speakers apart | Apache-2.0 (WeSpeaker code); the pretrained model is trained on VoxCeleb, which is CC BY 4.0: see the model page | [WeSpeaker pretrained models](https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md), [VoxCeleb licence](https://www.robots.ox.ac.uk/~vgg/data/voxceleb/) |
| Ollama | Local server for the text embedding model (optional) | MIT | [github.com/ollama/ollama](https://github.com/ollama/ollama) |
| BAAI `bge-m3` | Multilingual text embeddings: facts by meaning, project index (optional) | MIT | [huggingface.co/BAAI/bge-m3](https://huggingface.co/BAAI/bge-m3) |
| Apple system frameworks: AVAudioEngine, Core Audio process taps, AppKit, WKWebView | Microphone and system audio capture, the tips window | Part of macOS, Apple SDK terms | [developer.apple.com](https://developer.apple.com/documentation/) |
| Claude (Anthropic), in Claude Cowork | Reads the transcript and writes tips, the brief and the wrap-up | Commercial service under your Claude plan, not open source | [anthropic.com](https://www.anthropic.com/) |
| Notion API | Reads project context, writes the meeting page | Commercial service, Notion terms | [developers.notion.com](https://developers.notion.com/) |

Licences change; the links above are the authority, this table is a snapshot of October 2026.

### 13.2 What is built here

- **Audio capture helper** (`audiocap`, Swift): microphone and system audio as two separate
  streams, device switching, and the watchdogs: a frozen stream is restarted, a start that
  hangs is killed and retried, after repeated failures it switches to the Mac's own microphone.
- **The pipeline around Whisper** (`transcriber.py`): segmentation on top of the VAD, the noise
  gate, the filters for Whisper's invented lines (subtitle credits, prompt echoes, sound
  descriptions), fixed languages per call and per channel, the transcript format, the talk
  meter.
- **The tips window** (`prompter.html` + `prompter.swift`): layout, the gear menu, the alert
  slot, pinning, ratings, 🆘 and pause, the speaker card, stealth, the two interface languages.
- **The protocol between the recorder and Claude:** `read_delta.py` (long poll, tips in, window
  input out, state, reminders) and the `lt` helper (start, status, stop, prep check, state,
  wrap-up numbers, search).
- **Instant cards and the fact book:** the formats, the local matching, the question marker and
  the local 🆘 reaction, with no model in the loop.
- **Speaker identification on top of the voice model:** online clustering, the "Who is
  speaking?" flow, fixes and merges, the local voice library, names applied to the whole call.
- **The semantic layer on top of the text model:** matching facts and cards by meaning, the
  live topic, the per-project index with its exclusions, the usage logs.
- **The skill** (`live-tips`): the prep (brief, cards, facts), the live rules (facts or silence,
  priorities, triggers, tip format), the wrap-up into Notion and the lessons loop.

### 13.3 Status: beta

- Tested by one person on one Mac (Apple Silicon) on real work calls since October 2026, mostly
  in Google Meet, in Ukrainian and English.
- Thresholds (speaker matching, semantic matching, tip rates) are still being tuned on real
  calls; expect them to change between versions.
- Known limits: Zoom and Teams are not fully verified; speaker naming and the semantic layer
  are new and optional; stealth depends on the meeting app honouring the macOS window flag, so
  check it in your app before a sensitive call.
- Something wrong or missing: open an issue in the
  [repository](https://github.com/bodco/pm-control-tower/issues) with the log lines (never with
  transcripts or client data).

---

## 14. Live Tips app (beta)

A native macOS menu bar app that runs the same live-tips loop without a Cowork chat. Code and
details: [`tools/live-tips-app/`](../../tools/live-tips-app/README.md).

**Download:**
[LiveTips-0.4.3-beta.dmg](https://github.com/bodco/pm-control-tower/releases/download/live-tips-app-v0.4.3/LiveTips-0.4.3-beta.dmg)

What it does:

- records the call on the Mac and transcribes it there with MLX Whisper (the same recorder core);
- calls the Claude API directly with your own key, stored in the macOS Keychain, on events
  (a question, your name, a new request) instead of a chat loop that can fall silent;
- spending limits: a soft and a hard limit per call and a monthly cap; at the hard limit only the
  local layer runs. Usually $0.10 to $1.20 per hour of a call;
- built-in local AI (`bge-m3`) for facts and cards by meaning, 🆘 HELP NOW and project search,
  with no Ollama needed;
- standby start, a choice of microphone that stays put when macOS switches devices, the
  presentation split view and the same tips window;
- speaker identification as in the skill: the "Who is speaking?" card offers the project's
  people, names go into the tips and the summary, the voice library stays on the Mac
  (**Settings > AI > Speakers**).

**It is a beta.**

- Not notarized yet: the first time, right-click the app, choose **Open** and confirm.
- macOS 14.4 or newer on Apple silicon.
- Python 3.10 or newer. The **Setup** window checks it and installs the rest (Python modules,
  the speech model, the local AI model; about 2.5 GB in total) with a tick next to each step.
  Nothing needs an administrator password.
- Expect rough edges, and report them with log lines, never with transcripts.

### 14.1 App or skill

Both do roughly the same job: the same rules (the app and the skill read one shared
`rules/` folder), "facts or silence", the same tips window. It is your choice.

| | Skill in Cowork | App |
|---|---|---|
| Model access | Your Claude plan, no API key | Your own Claude API key, billed per use |
| During the call | The Cowork chat stays busy for the whole call | Nothing to keep open, one click from the menu bar |
| Context lookups mid-call | Notion, the tracker, project files through a subagent | The call context, the prep, local search over the project folder |
| Cost control | Plan limits | Per call and monthly limits in Settings |

They work best together. Make the prep in Cowork (brief, fact cards, an outline and slides for a
presentation): the app picks it up by itself when the prep title matches the call title (rule
in section 5.0). In **Start call** press **Copy request for Cowork** to get a ready prep request.
Without a prep the app uses the call context you type in Start call, the project's current state
and local search over the project folder.

### 14.2 After the call: the meeting page in Notion

With **Settings > General > Write the call summary to Notion** on, the app writes the wrap-up
into Notion by itself when you end the call. You can also send the last call later from the
menu bar: **Send last call to Notion**.

1. One Claude call turns the transcript and the tips into a wrap-up: action items with owners
   and dates, decisions, your commitments, new requests (scope change candidates), open
   questions and risks.
2. The app looks for this meeting's page in the project's Meetings DB: a page whose `Date` is
   within 20 minutes of the call start (a Notion AI Meeting Notes page created from the calendar
   counts).
3. Found: it appends a **Live Tips** section to that page. Not found: it creates a new page with
   the project and workspace relations and a real date mention in the title, like the skill.
4. The transcript is attached to the page as `<call>-transcript.md`.

What it needs:

- a Notion token in **Settings > Keys** (an internal integration from
  [notion.so/my-integrations](https://www.notion.so/my-integrations)) that has access to the
  Meetings DB;
- the project config with `meetings_db` and `project_page_id` (section 4, step 7).

Only the transcript text goes to Claude and Notion; audio never leaves the Mac. A finished
write shows an alert with **Open in Notion**. If the skill already wrote a page for the same
meeting, the app adds its section to that page instead of creating a second one.

### 14.3 The app and the skill on the same call

You can run both on one call, for a fair comparison or as a backup. The app records with its
own recorder in its own app folder and names its files `<call>.app.*`
(`2026-10-22-1500-team-daily.app.md`), so the two never share a transcript, control or state
files. Both run Whisper, so expect about twice the CPU and memory. Compare afterwards:

```bash
python -m livetips_m0.report <app folder>/runs/<call>.app --calls-root <project folder>/live
python -m livetips_m0.judge --config <cfg.json> --md <project folder>/live/<call>.md \
  --run <app folder>/runs/<call>.app --out <app folder>/runs/judge-<call>
```

`report` gives the tip count, latency and cost of each side; `judge` is a blind quality judge
that scores every tip of both sides 1 to 5 without knowing which side wrote it.

### 14.4 Shortcuts

- **Control-Option-H**: HELP NOW, also when the meeting app has the focus.
- **Control-Option-P**: pause or resume tips.

The same two actions are in the menu bar menu during a call, with the shortcut next to them.
The HELP button shows its shortcut, the pause button shows it in its tooltip, and
**Settings > General > Shortcuts** lists both.
