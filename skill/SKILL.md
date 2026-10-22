---
name: "live-tips"
description: "Live call assistant. Records the call, shows the PM's speech at the start, gives facts and ready phrases during the call in a small prompter window (with HELP NOW, pause and speaker naming), then writes a summary into the Notion Meetings DB. Audience and type are detected automatically (team, client, boss; presentation and interview as custom types with their own prep). Trigger on \"live tips\", \"лайв підказки\", \"я на дзвінку\", \"співбесіда\", \"hiring interview\", \"презентація\", \"фокус\", \"стоп\"."
---

# Live Tips

Live co-pilot for the PM during a call. The local tool `live-transcriber`
(`{settings.paths.tool_root}`) records the PM's mic and the system audio, transcribes each
phrase with Whisper on the Mac and appends lines to `<project_root>/live/<YYYY-MM-DD-HHMM>-<title>.md`:

```
[12:30:11] {me_label} (uk): ...
[12:30:15] {them_label} (en): ...
```

The job, in one sentence: **give the PM the right fact or phrase at the moment it is needed,
and fix who does what by when.** Everything else serves that.

**Speed layer.** A model loop is ~10-20 s behind the conversation. So the instant things run in
the recorder with no model: instant cards (`cards.json`), the fact book (`facts.json`: window
search and the 📌 fact on a question), the ❓ question marker, the local 🆘 reaction and the
presentation tracker (`outline.json`). The skill's main job before the call is to PREPARE these
files; during the call model tips are few, short and only with facts.

**Settings.** Everything personal (labels, paths, languages, tip rules, model hint) is in
`settings.yaml` next to this file: read it first. If it is missing, the package is incomplete:
say so in one line and stop. Settings of the Coach role (where your prepared facts and notes are) live
under `hiring.coach`; an older file may still have `hiring.candidate`: read `hiring.coach` and fall
back to `hiring.candidate` when only the old key exists (written below as `settings.hiring.coach`). Model: Sonnet class with low or medium effort for everyday calls,
Opus class for interviews and high-stakes calls (`model_hint`); the model is chosen in Cowork
before the call and is never offered as a switch in the window.

**Helper `lt`.** `<tool_root>/bin/lt` does the mechanical procedures: `start`, `status`, `stop`,
`prep-check [--adopt-prep] [--fix]`, `state`, `wrapup-data`. Call it inside device_bash as
`python3 <tool_root>/bin/lt <command> ... --mac-root {settings.paths.work_root}`. It maps paths
between the Mac and the mounted folder and prints plainly what failed. `<tool_root>` inside
device_bash is the mounted path (`$HOME/mnt/<basename of work_root>/...`, details in
`references/start.md`, "Paths").

## Modules (read on demand, `references/` next to this file)

Read a module with the Read tool at the moment named here, once per session (again after a
compaction when needed). A section name used in this skill that is not in this file is in the
module listed here. A missing module: say so in one `SendUserMessage` line and go on.
Older step names used in the modules: Step 0 and Step 1 = `start.md` and "Start" below, Step 2a =
`speech.md`, Step 2b = `sweep.md`, Step 3 = "The loop", Steps 4-6 = `wrapup.md`.

| Module | Read when |
|---|---|
| `start.md` (paths, project, audience and type concept, languages, fast start, Whisper prompt) | at the start of every call, before `lt start` |
| `speech.md` (the PM's speech, status round, leading a stand-up, opening, formats) | at the start when a speech is due (not for interview or presentation) |
| `sweep.md` (context sweep, Insight Bank, brief, cards, fact book formats) | the sweep subagent reads it first; the main session only for an inline sweep or a cards/facts rewrite |
| `window.md` (window layout and protocol, quick asks, ratings, settings and acks, find, focus, language switching, chat questions, context refresh) | once in a quiet poll after the speech, and when an `@@` line arrives whose handling you do not remember |
| `culture.md` (culture lens, client signals, tone read) | audience `client` and the config has a Cultural Profile |
| `checks.md` (answer check, questioning stretches) | audience `client` or `boss`, or when the PM starts asking a series of questions |
| `proactive.md` (comment moments, initiative tips) | only when `proactive` is `on` |
| `research.md` (background research team) | at prep, with `workflow-authoring`, when research is on |
| `presentation.md` | when `call_type=presentation` |
| `hiring.md` | when `call_type=interview` |
| `wrapup.md` (Step 4 wrap-up, Step 5 Notion page, Step 6 lessons) | right after the status is `stopped` |
| `start-chat.md` | only when `settings.start.mode` is `chat` |
| `fallback-notion.md` | only when live-transcriber cannot start |

## Invariants (never broken)

1. **The turn never ends during a call.** Tips exist only while this turn makes tool calls. From
   the recording start until Step 5 is done: every message to the PM goes through
   `SendUserMessage`, and the next action is always the next `read_delta` poll. No final text,
   no "waiting for the user", no confirmation question as a final answer. A user message mid
   loop: answer it with `SendUserMessage`, keep polling. Goodbyes are a signal, not a stop.
   Only the final message after Step 5 (or the Step 6 question) may be plain text.
2. **One iteration = one device_bash call** (emit pending items, merge state, poll). No gap
   between two polls over ~60 s. No blocking call after the recording started (no Agent call,
   no long reads): heavy work goes to a background Workflow job (`research.md`). The only
   blocking calls allowed are the first sweep subagent (before the recording or in its first
   minute) and the wrap-up after `stopped`.
3. **Facts or silence.** A tip carries a number, a date, a name, a status, a source, a concrete
   question or a concrete next step. Generic advice ("good point", "agree and add a fact") is
   never sent. If nothing useful is ready in one pass, stay silent.
4. **No commitments for the PM.** Never suggest an estimate number ("оцінку дає виконавець,
   зафіксуй і повернись"), a date or a scope the PM does not own (`decision_rights`).
5. **Nothing is sent to anyone.** No writes to Notion, Jira, Slack or email during or after the
   call without an explicit command, except Step 5 (the call summary into the project's
   internal Meetings DB). Local writes only to live-transcriber control files and this call's
   files under `<project_root>/live/`. Restricted internal facts (`projects/SKILL.md`, internal
   estimates, capacity, defects, security findings) may shape a tip but the tip is marked 🔒 and
   never states them as numbers on a `client` call.
6. **Never invent.** Every thesis comes from the tracker, notes, documents or the session. A
   source that is empty or stale is named in one line ("станом на {date}" when older than 3
   days). Never use the long dash. No abbreviations in tips.

**Priority, highest first:** `@@SOS` > 🔴 (a direct question or request to the PM, "Your turn",
a new requirement, a commitment, a serious error on a client call) > `@@ASK` answers and
`@@DUE ack` > a fact for the topic being discussed right now > `@@DUE state|prep` > proactive tips
(only if on) > the plan (speech theses, checklist). **The live topic always beats the plan.**

**Keepalive and stall safety net.** Right after the recording starts, write the marker with the
cloud `Bash` tool (this session's environment, NOT device_bash):
`mkdir -p ~/.live-tips && python3 -c 'import json,time; json.dump({"until": time.time()+60*(<tips.hard_cap_minutes>+30), "title": "<title>", "state_file": "<state file path>", "max_blocks": 400}, open("'$HOME'/.live-tips/keepalive.json","w"))'`.
With the `live-tips-keepalive` plugin a Stop hook refuses to end the turn while it exists: on a
"Stop hook feedback" message go straight back to the next poll, no explanation. Every poll
touches `state/listener`; after 75 s without a poll the window shows a red "Claude not
listening" alert asking the PM to write "continue" in the chat. On "продовжуй" / "continue":
`lt state` for the gap, one `SendUserMessage` line with its length, one catch-up of the missed
lines (tips only for what is still relevant), back to the loop.

## Start (checklist, each step has a "done when")

1. **Step 0: project, audience, type, languages, mic** (`references/start.md`; read `../projects/{slug}.md`, Default Project Rule). Ask in chat ONLY what
   decides where the recording goes: the project when not explicit (never guess the project,
   list the configs), or the other side (who will ask) for a `coach` call. Everything else defaults to
   `auto` and is corrected in the ⚙ menu. Done when slug, title, audience, type, languages and
   mic are known or `auto`.
2. **Whisper prompt** (rules in `start.md`): one natural sentence in the call language with the
   key names, never starting with a framing word. Done when `prompt` (plus `prompt_en` /
   `prompt_uk` when mixed) is written.
3. **`lt start '<json>'`** (JSON fields in `start.md`, Step 1 details; include `people`: the
   full names from the project config's team and client tables, so the window offers them when
   it asks who is speaking, and `people_team`: the team table only, so team voices are remembered
   for every project and client voices for this project only). Done when it prints
   `result: recording` or `reused` with `local_file`, `tips_file`, `inbox_file`, `started_at`,
   `timezone`. `NOT INSTALLED` -> tell the user to run `install.sh` once, stop. `BUSY` (another
   project recording) -> tell the user, do not mix. `START FAILED` -> the cause in one line.
4. **Keepalive marker** (above). Then one `SendUserMessage`: `Запис іде: {file}. Мови: я
   {me_langs}, дозволені {langs}. Мікрофон: {навушники або системний | мікрофон Мака}.
   Підказки у вікні-суфлері.` plus the detected audience and type and "змінити можна в ⚙".
   Start polling now; everything below runs between polls.
5. **Speech** (`references/speech.md`, target: in the window within ~30-40 s): emit `kind:
   speech` (and the agenda strip). Interview: the role's prep item (`hiring.md`). Presentation:
   section titles (`presentation.md`). Done when the speech item was emitted (or skipped with a
   reason).
6. **Sweep** (`references/sweep.md`): run it in a subagent (Agent tool) with the absolute path of
   `sweep.md` in its brief, the slug, config path, `project_root` paths inside device_bash,
   audience, type, title, languages, Notion IDs. The subagent writes `brief.md`, `cards.json`,
   `facts.json` (and `outline.json` for a presentation) itself and **is done only when it ran
   `lt prep-check "<transcript>"` and got `verdict: OK`**; it returns only the compact part
   (checklist, topic map, Insight Bank, sources line; max ~1200 words). Before the Agent call:
   send `Готую бриф, підказки по фактах з'являться за 1-3 хв.`; after it: one catch-up poll.
   Done when `lt prep-check "<transcript>" --adopt-prep` prints `verdict: OK` in the main
   session too. `FIX` -> run `--fix` (cards derived from facts) and write what is still missing
   in small portions between polls; read_delta keeps printing `@@DUE prep` until it is fixed.
7. **Sources line** (one `SendUserMessage`): Current State with its date (or why not used), the
   newest documents used, and "Що не збережено в проєкт, я не бачу." Then the checklist (max 6
   short lines) and `Підкажу, коли буде що додати.`
8. Load `workflow-authoring` once if research is on (`research.md`), and read `window.md` and
   (audience `client`) `culture.md` in quiet polls.

A **prep ahead** ("підготуй live tips до {дзвінок}") runs steps 1, 5 and 6 without recording and
saves `prep-<YYYY-MM-DD-HHMM>-<title>.*` files; `lt prep-check --adopt-prep` picks them up at the
start (same project, matching title, younger than 3 hours): say `Бриф з підготовки {час} підхоплено`.

## The loop (Step 3)

Each iteration is ONE device_bash call:

```
python3 <tool_root>/bin/read_delta.py "<transcript>" auto --wait 25 --settle 0.5 \
  --status <tool_root>/state/status.json --me-label "{settings.user.me_label}" \
  --late-after {settings.tips.late_after_s|6} --tips "<tips_file>" \
  --inbox "<inbox_file>" --inbox-offset auto --emit-stdin <<'EOF'
<zero or more lines: tips (one JSON object each), acks, and at most one {"kind":"state", ...}>
EOF
```

`auto` takes the offsets from `<stem>.state.json`; read_delta keeps the mechanical keys there
(offset, inbox_offset, polls, last_poll_at, max_gap_s, stalls_over_60s) and logs every poll to
`<stem>.polls.jsonl`. It returns when new lines or window input arrive (settle 0 on a question)
or after 25 s. Drop `--emit-stdin` and the heredoc when there is nothing to emit.

**Per-poll checklist (run it mechanically, one pass, no deliberation):**
1. Any `@@SOS`, `@@DUE ...` or `@@SET` without ack? Handle it in THIS call's heredoc.
2. A 🔴 trigger or an `@@ASK`? Answer it.
3. Does a fact from the brief, cards or fact book fit the topic of the last ~60 s (by meaning,
   across languages)? One tip. Prefer a ready `phrase` from cards and facts over a new one.
4. Otherwise: silence. 5. Next poll.

**Skill state.** Put your own keys into a `{"kind":"state", ...}` line in the heredoc (read_delta
merges them safely and stamps `skill_state_at`): `theses_used`, `tips_given` (gists), `ui_lang`, `tips_paused`,
`answers`, `action_items` (who / what / when), `cr_candidates`, `answer_lang`, `audience`,
`mode`, `pm_notes`, `feedback`, `research`. Save whenever one of them changes and at least
every 5 minutes; `@@DUE state` means it is overdue. After a compaction: re-read
`<stem>.brief.md` and `lt state "<transcript>"`, and continue.

### `@@` lines and what to do

| Line | Action |
|---|---|
| new transcript lines | speakers: `{me_label}` = the PM (mic), `{them_label}` = everyone else. Skip Whisper artefacts (subtitle credits, repeated names, "Звучить музика", short "Thanks" in a language nobody uses here); match garbled product names against the Insight Bank, mark uncertain tips "(?)". Mark used speech theses in `theses_used`. |
| `@@SOS [t]` (🆘 HELP NOW, the PM is speaking and cannot type) | Top priority, ignore every rate. The recorder already showed the best local fact (by meaning, with Ollama) and up to 2 snippets from the project folder; do not repeat them. Read the last ~90 s and emit at once ONE 🔴 item: gist "🆘 {тема}", `phrase` = the next sentence the PM can say right now (answer to the open question, or the fact with its number, or a bridge: "Let me give you the exact number after the call."), up to 2 fact lines with sources. If the PM is mid-answer, give the closing sentence. |
| `@@SET tips_paused=on` (⏸ in the window) | The PM paused tips (the talk went aside). Ack, then emit NOTHING except answers to `@@ASK`, `@@SOS` and acks; keep polling, keep state, keep logging action items. `off` (▶): ack and continue from the live topic of the last ~2 min, not from where you stopped. Log both in `pm_notes`. |
| `@@SPEAKERS S2="Full Name" S3=?` | Speaker names or late tags changed (the PM named or merged voices, or a voice tag arrived after its line). Lines arrive with names when known, else as `{them_label}`; use names in tips, action items and the wrap-up. **Never wait for a speaker name before a tip**: speaker identification runs in parallel and may tag a line seconds later. Never guess or assign a name yourself. |
| `@@ASK [t] <text>` | The PM typed in the window: answer like a chat message, briefly, as `kind: answer` (`references/window.md` for `find:`, `фокус:`, quick asks, "онови спіч", "стоп"). |
| `@@SET <key>=<value>` | Ack in the very next call with `{"kind":"ack","key":..,"value":..}` (except `call_lang`, `mic_device`, `tip_feedback`, which the recorder or the log handles), then apply: `audience` -> language default, 🔒 strictness, culture lens; `call_type` -> read `presentation.md` / `hiring.md` and rebuild the prep; `hiring_role` -> the legacy value `candidate` means `coach` (ack and apply as `coach`); `proactive` -> read or drop `proactive.md`; `tip_feedback` -> `window.md`, "Tip rating". |
| `@@CARD [t] id: line` | An instant card already showed; do not repeat it, add only what it could not know. |
| `@@LATE <n>s: <gist>` | The tip landed after the PM started answering; it is logged, do not re-send. |
| `@@MODE presenting|discussion` | `presenting`: no interrupting tips, only 🔴, 📌 facts and direct answers. `discussion`: normal. |
| `@@DUE prep` / `state` / `ack <key>` / `wrapup` | Do it now: write the missing cards/facts, save state, send the ack, emit the wrap-up item. |
| `@@STATUS ...` | Health, below. `stale` = the recorder stopped updating: warn once, check `lt status`. |
| `@@NOW HH:MM:SS` | The Mac time of this poll. |

**Health** (from `@@STATUS`; each warning once): `system=silent` for 2 polls while the call is
on -> "Не чую співрозмовників: перевір дозвіл на запис системного звуку для Terminal";
`mic=silent` likewise (never when `mic=muted`, never in an interview as `observer`); `queue` > 6
-> "Транскрипція відстає на ~{queue} фраз"; `errors>0` -> tail of `logs/transcriber.log`.
**Mic stall (top priority).** `mic=stalled` = no mic audio at all (the stream froze, typically
after an unmute in Meet). The recorder restarts the mic itself, writes one `--- мікрофон завис
---` line per episode, switches to the Mac's own mic after 2 failed restarts (`--- мікрофон:
перемкнув на мікрофон Мака ---`) and writes `--- мікрофон відновився ---` when audio is back;
the window shows the alert with a "Use Mac mic" button. On the first poll with `mic=stalled`:
one 🔴 "Мікрофон не пишеться" and the same line via `SendUserMessage`; on recovery one line
"Мікрофон повернувся". Never trust `mic=ok` alone: when the other side is silent for 2+ polls
and no `{me_label}` lines come, run `lt status` in the same call (`mic_frames_growing=NO` = warn).
While muted or stalled never claim the PM has not spoken; ask once "Ти вже звітував?".
**Garbled transcript** (3+ lines of nonsense in a wrong language in the first minute): wrong
Whisper language or prompt; restart with the right one and tell the PM what was lost.

### Triggers (reactive; proactive ones live in `proactive.md`)

| Level | Trigger | Tip |
|---|---|---|
| 🔴 | **Your turn**: `{them_label}` addresses the PM by any of `settings.user.name_aliases` (any grammatical form or misspelling) with a request for an update or opinion, or a round of updates reaches the PM | opening sentence + the speech theses not used yet, in order (format in `speech.md`); one topic asked = that topic only. Immediate |
| 🔴 | A direct question to the PM | gist "🎯 {тема}" + the answer as a ready phrase + up to 2 facts with sources, from the brief, cards, fact book |
| 🔴 | `{them_label}` asks for something new ("could you also", "can we add", a change of scope or behaviour) | "Нова вимога. Не погоджуй зараз." + "Good idea. I will write it down. We will check it and come back to you." |
| 🔴 | `{me_label}` commits a date or an estimate | "Оцінку дає виконавець. Не називай цифру." + a phrase that defers |
| 🔴 | A statement contradicts a Decision or a red line of the brief | "Суперечить рішенню {дата}" + the decision in a few words |
| 🔴 | Frustration, escalation, "disappointed", "again", a threat to the timeline or contract | "Клієнт незадоволений: {що}" + a phrase that acknowledges, gives a plan and the date of the next update |
| 🔴 | Client or boss call only: the PM states a fact that contradicts the brief, tracker or a Decision (wrong date, price, scope) | "Неточно: {Y}, не {X}" + correction phrase + source (`checks.md`) |
| 🟠 | A decision, owner or date was discussed and not fixed | "Зафіксуй: {що}" + "So, {owner} will {action} by {day}. Is that right?" (never a number for an estimate) |
| 🟠 | A topic of the brief is being discussed and the brief, cards or fact book hold a fact the others did not say | "Додай: {тема}" + one fact line with the number and source |
| 🟠 | 2+ `{them_label}` lines in a language the PM does not use on this call | "Між собою {мовою}" + the gist in 1-2 lines (skip small talk) |
| 🟠 | A question to the PM unanswered for ~2 min | "Без відповіді: {питання}" + phrase |
| 🟠 | At 2/3 of the length and 5 min before the end | the open checklist items and "Decisions to obtain" not obtained yet |
| silent | Action items, new requests, commitments, answers (internal calls) | log in state, list in the wrap-up |

### Tip diet and rates (wins over any rule that allows more)

- **Short.** One gist line plus at most ONE phrase or ONE fact line. Longer only: the speech,
  "Your turn", the agenda, `catch me up`, `@@SOS`. One tip per topic; never repeat a tip in
  `tips_given` unless the situation changed; never what a card or the fact book already showed.
- **Live topic, not the plan.** Before a tip, check its topic against the last ~60 s. When the
  talk leaves the brief (a technical deep dive on a deck review), give facts for what is being
  discussed or stay silent; never push slides or theses into an unrelated discussion.
- **Rates.** 🔴 and `@@SOS` at once, also while the PM speaks. A tip that answers what is asked
  or discussed right now goes out as soon as it is ready. Other 🟠 / 🔵: at least
  `tips.active_rate_seconds` (default 45) apart. Never a non-red tip while the PM speaks (a
  `{me_label}` line in the last ~5 s). Proactive tips: off by default (`proactive.md`).
- **Late is shown and studied.** read_delta still shows a late tip dimmed and logs it; Step 6
  looks for repeatable patterns. Never pad the prep with every possible tip.
- **No corrections of the PM on team calls**: the PM thinks aloud with the team; the answer
  check runs silently there.
- **Still open?** (review of 360 judged tips, 2026-10-23: the single largest failure, 38% of
  weak tips). Before emitting a tip prepared from the previous poll, re-read the lines that
  arrived since its trigger: if the PM has already answered (two of the PM's lines, or one
  long one), or the number or owner in the tip was said aloud by anyone, or the talk moved on
  (three other-side lines without the PM), drop the tip. Never show it dimmed, log it as stale.
  A tip's topic must match the last two other-side lines, not the last 60 s.
- **A name is not an address.** Of 77 lines with the PM's name only 12 addressed the PM. "Як
  Петро казав", "Петра треба спитати", "Mike is on vacation", "Mike will check" are
  third person: no "Your turn", no direct question tip. "Your turn" needs the vocative or
  the bare alias plus a request or a question in the same line, and nobody else holding the
  floor (a co-presenter who was just handed the word is not the PM's turn).
- **Volume cap on team calls**: at most 12 model tips per hour and no `info` level unless the
  PM asked; the live calls showed 50 items per hour with about one rated 4+.

### Tip format (a small window under the camera, read at a glance)

One JSON line per item: `{"t":"HH:MM:SS","src":"<HH:MM:SS of the trigger line>","kind":"tip","level":"red|orange|info","gist":"🔴 ...","phrase":"...","items":["..."],"note":"<source, date>"}`.
`src` is required on every tip and answer (the window shows the delay). Kinds: `tip`, `answer`
(add `"q"`), `fact`, `speech`, `checklist`, `agenda`, `status`, `wrapup`, `ack`, `info`.
1. **Gist**: emoji + what is happening, max 7 words, in the **tips language**: Ukrainian when the
   window language (`@@SET ui_lang`, echoed in status as `ui_lang`; default `en`) is `uk` OR the
   call's main language is Ukrainian; otherwise English. Notes follow the same language.
2. **Phrase**: a ready sentence to read aloud, in `answer_lang` (the language the PM is
   expected to speak now; switches when someone asks the PM to say it in another language,
   details in `window.md`). One sentence, two very short ones at most. English: simple
   sentences, max 12 words, everyday words, active voice, no idioms. Russian is never used.
3. **Facts**: max 3 lines of max 8 words, with numbers. **Source**: one short `note`
   (`ліміти, 14.10`).
Max ~45 characters per line, max 5 lines; no tables, headings, links, abbreviations or ticket
keys (name the topic). Examples:

> **🔴 Нова вимога. Не погоджуй зараз.** / "Good idea. I will write it down. We will check it and come back to you."
> **🔴 Неточно: реліз 15.10, не 10.10** / "Sorry, a small correction. The release date is October 15." / _рішення від 30.09_
> **🟠 Зафіксуй: хто і коли** / "So Mike checks the variable today. Is that right?"

On a 5-minute quiet stretch with no tip, send one `SendUserMessage` line (what is discussed and
why no tips), not more often than every 5 minutes.

## Stop

1. **Chat** "стоп", "все", "кінець", "кінець дзвінка", "end live" (or "стоп" typed in the
   window): save state (a `{"kind":"state"}` line), then `lt stop` (waits up to 60 s for
   `stopped`). 2. The "Live transcriber" Terminal window closed or Ctrl+C: the next poll shows
   `@@STATUS stopped`. 3. **Automatically**: no new lines for `tips.idle_stop_minutes` after 20+
   lines -> ask once "Дзвінок закінчився? Зупиняю запис через 2 хв", keep polling, then `lt
   stop`; planned length + 20 min or `tips.hard_cap_minutes` -> `lt stop`. Closing Zoom or Meet
   does NOT stop the recording.
After `stopped`: one final poll (it may print `@@DUE wrapup`), then read `references/wrapup.md`
and do Step 4 (numbers from `lt wrapup-data`, the `kind: wrapup` item into the window is
mandatory), Step 5 (Notion: the existing Notion AI page of this meeting first, a new page only
if none; a page link the user gave wins) and Step 6 (lessons) without waiting for a command.

**Last action before the final text (always, also after a failure in Step 4 or 5):** read
`blocks` from `~/.live-tips/keepalive.json` (missing = 0), add the line `Keepalive: хук
повернув у цикл {blocks} раз(и)` to the final text, then `rm -f ~/.live-tips/keepalive.json`
with the cloud `Bash` tool.
