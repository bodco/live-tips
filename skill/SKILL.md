---
name: live-tips
description: Live call assistant. Starts local transcription of the call (live-transcriber on the Mac, Whisper, mic + system audio) into the project folder, reads only new lines and posts short tips to the PM in chat, answers the PM's questions during the call with project context. Trigger on "live tips", "лайв підказки", "асистент на дзвінку", "веди дзвінок", "я на дзвінку", "дзвінок почався", "start live", and to end it: "стоп", "кінець дзвінка", "end live". After the call it creates one page in the project's Notion Meetings DB with the transcript; nothing else is written anywhere and nothing is ever sent to anyone.
---

# Live Tips

Live co-pilot for the PM during a call. The local tool `live-transcriber`
(`{settings.paths.tool_root}`, see its README) records the PM's mic and
the system audio, transcribes each phrase with Whisper on the Mac and appends lines to
`<project_root>/live/<YYYY-MM-DD-HHMM>-<title>.md`:

```
[12:30:11] {me_label} (uk): ...
[12:30:15] {them_label} (ru): ...
```

**Settings.** Everything personal (labels, paths, language defaults, tip rules, model hint)
is in `settings.yaml` next to this file. Read it first. Nothing user-specific is hard-coded
in this file; examples below use the author's values only as illustration.
Full human documentation: `docs/uk/17-live-tips.md` in the pm-control-tower repository.

This skill starts it, reads only the NEW lines, matches them against a pre-built Live
Brief of the project and posts a tip only when a trigger fires. Silence is the default.
Notion AI Meeting Notes is the fallback source (section "Fallback: Notion").

Model: every iteration's thinking time adds to the tip delay. See `model_hint` in
settings. Not a small/fast-only model: the answer check and multilingual nuance need
judgement.

Hard rules:
- No writes to Notion, Jira, Slack or email during or after the call without an explicit
  command, with ONE exception: Step 5 creates exactly one page in the project's Meetings DB
  (internal hub, never the client's workspace). Nothing is ever sent to the client. The only
  local files written are the control files of live-transcriber and this skill's own
  state/brief under `<project_root>/live/`.
- Tips follow the section "Tip format": a short gist in `{settings.user.tips_language}`,
  then a ready phrase in the language of the call. No abbreviations. Never use the long dash.
- Restricted internal sources (`projects/SKILL.md`) may shape a tip, but such a tip is
  marked 🔒 so the PM never repeats it aloud to the client.
- Estimates: never suggest a number (`_standards.md`, rule 7). Only "оцінку дає
  виконавець, зафіксуй і повернись".

## Paths

| What | On the Mac | Inside device_bash |
|---|---|---|
| Tool root | `{tool_root}` | `{tool_root}` with `{work_root}` replaced by `$HOME/mnt/<basename of work_root>` |
| Project folder | `{config.project_root}` | same replacement |

`work_root` and `tool_root` come from `settings.paths`. `project_root` comes from the
project config `Local Paths`. Missing: use the parent of `repos_root` / `reports_root`,
else `{work_root}/{project_name}` if it exists, else ask. If the mount is missing, ask the
user to connect the `work_root` folder.

## Step 0 - Project and meeting

1. **Project.** Slug from the request, or from the instructions of the claude.ai Project
   this session is attached to when they name the slug explicitly (for example
   "Проєкт: Acme Portal (slug: acme-portal)"). That counts as explicit. Otherwise ask, listing
   configs in `projects/` (Default Project Rule).
2. Read `../projects/{slug}.md` (fallback: Glob `**/projects/{slug}.md`), the `PM Profile`
   and `projects/_standards.md` section 5 (agendas).
3. **Meeting type, title, length.** From the user's words, else from the config Meetings
   Schedule by day and time (the `Type` column is the title), else title "Meeting", 60 min.
   Type decides: client call (client phrasing, 🔒 rule) or internal call.
4. **Languages.** `me_lang` = the PM's own mic language on this call (fixed, not
   detected), `langs` = all languages expected on the call. Resolution order:
   1. the user's words ("сьогодні англійською", "будуть іспанською");
   2. `settings.languages.per_project.{slug}.{internal|client}`;
   3. `settings.languages.internal` or `settings.languages.client`, where `from_project`
      means the project config `client_language` (as an ISO code: English -> en).

The only allowed questions: the project (if not explicit) and nothing else. Do not ask
about languages or length: use defaults and state them in the start message.

## Step 1 - Start the recording (first, before the brief)

0. Check the install: `<tool_root>/.venv/bin/python` and `<tool_root>/bin/audiocap` exist.
   If not, stop and tell the user to run `bash <tool_root>/install.sh` in Terminal once
   (5-10 min, ~1.6 GB model) and to allow Terminal both the microphone and System Audio
   Recording. Do not write `start.json` before that.
1. Check that nothing is recording: read `state/status.json`. If `state` is `recording`
   for the same project, reuse it (take `file` from the status). If another project is
   recording, stop and tell the user, do not mix.
2. Build `prompt` for Whisper: max ~200 chars of proper names and terms from the config
   (team names, client names, product and module names). It improves spelling of names.
3. Write `control/start.json` with a small python one-liner inside device_bash
   (`json.dump`, UTF-8, `ensure_ascii=False`):
   `{"project_dir": "<Mac path of project_root>", "title": "...", "slug": "...", "me_lang": "...", "langs": "xx+yy", "me_label": "...", "them_label": "...", "prompt": "..."}`
   (labels from `settings.user`).
   The LaunchAgent opens a Terminal window "Live transcriber" with the recording by itself;
   the PM does not start it, may minimise it, should not close it.
4. Poll `state/status.json` every 3 s up to 60 s (model load takes 5-20 s):
   - `recording` -> take `file`, map it to the device_bash path, go on;
   - `error` or nothing after 60 s -> rename `control/start.json` to `control/start.json.pending`
     (`mv -n`, so the recording does not start by surprise later), then show `logs/transcriber.log` tail (last 15 lines) and
     `logs/launcher.log`, say what failed. Common fixes: install.sh not run, Terminal has no
     microphone / system audio permission, LaunchAgent not loaded
     (`launchctl list | grep live-transcriber` on the Mac).
5. One message: `Запис іде: {file name}. Мови: я {me_lang}, дозволені {langs}.` plus the
   checklist from Step 2 when ready.

## Step 2 - Live Brief (while the first minutes are being recorded)

Collect in parallel, everything scoped to this project (relation `Project` =
`{config.notion.project_page_id}`; tracker queries via the JQL Isolation Validator):

| Source | What to take |
|---|---|
| Topics DB | open topics: one line each, current position, last decision |
| Decisions DB | last 30 days: decision + date (to catch contradictions) |
| Risks DB | open; for a client call only `External` / `Both` |
| Threads DB | `Awaiting Reply` / `Need Follow-up` |
| Meetings DB | last 2 meetings of this type: unclosed action items, promises |
| Task tracker | per `task_tracker.api_access`: in progress, blocked, awaiting client (else `fallback_source`) |
| Config | Team tables + Transcript Alias Map, `pm_profile.milestones`, `decision_rights` |
| User | agenda items or goals the user typed in the request |

Compress into the **Live Brief**, max ~1200 words, saved next to the transcript as
`<transcript name>.brief.md`:

1. Checklist: what this meeting must cover + "Decisions to obtain".
2. Topic map: topic -> keywords (in every language of `langs`) and Jira keys -> 1-line status.
3. Commitments in flight: who promised what by when.
4. Red lines: decided items not to reopen, out-of-scope areas, decision rights.
5. Names and aliases (how Whisper may spell people).

Show the user only the checklist (max 6 short lines, no abbreviations, ~45 characters per
line) and `Мовчу, поки нема що сказати.`

## Step 3 - Live loop

State file `<transcript name>.state.json` next to the transcript: `offset` (bytes read),
`covered`, `tips_given`, `answers`, `action_items`, `cr_candidates`, `side_talk`, `last_tip_at`,
`started_at` and `timezone` (from `status.json`: start time with the Mac's UTC offset and the Mac's IANA zone). Long state lives there, not in the conversation.

Each iteration is ONE device_bash call that long-polls for new lines:

```
python3 <tool_root>/bin/read_delta.py "<transcript>" <offset> \
  --wait 25 --settle 2 --status <tool_root>/state/status.json
```

It returns as soon as new complete lines exist (plus 2 s to collect a burst), or after
25 s with nothing. Output: the new lines, then `@@OFFSET <n>` and
`@@STATUS <state> lines=.. queue=.. mic=.. system=.. errors=..`. No sleep calls are needed.

Then:

1. Store the new offset. Never re-read older lines; keep the last 3 lines as tail context.
2. Speakers: `{me_label}` = the PM (mic), `{them_label}` = everyone else (system audio). The
   language tag `(xx)` is per line.
3. Match the new lines against the Live Brief and the triggers below, by meaning, across
   languages (a Russian or Spanish line can match a Ukrainian/English topic).
4. Deep lookup (Jira ticket, Notion page) only when a trigger fires and the brief does not
   answer it. Max one per 2 min.
5. Post a tip with `SendUserMessage` if the rate rules allow. Otherwise produce no text and
   go straight to the next read.
6. Health from `@@STATUS`: `system=silent` for 2 polls while the call is on -> one message
   "Не чую співрозмовників: перевір дозвіл на запис системного звуку для Terminal";
   `mic=silent` likewise; `queue` > 6 -> "Транскрипція відстає на ~{queue} фраз";
   `errors>0` -> tail of `logs/transcriber.log`. Each warning once.

### Triggers

| Level | Trigger | Tip |
|---|---|---|
| 🔴 | `{them_label}` asks for something new, "could you also", "can we add", a change in behaviour or scope | "Нова вимога. Не погоджуй зараз." + phrase, e.g. "Good idea. I will write it down. We will check it and come back to you." |
| 🔴 | `{me_label}` commits a date or an estimate | compare with milestones / tracker; "Оцінку дає виконавець. Не називай цифру." + phrase |
| 🔴 | A statement contradicts a Decision or red line | "Суперечить рішенню {дата}" + the decision in a few words |
| 🔴 | Frustration, escalation, "disappointed", "again", threat to timeline or contract | "Клієнт незадоволений: {що саме}" + phrase that acknowledges, gives a plan and the date of the next update |
| 🔴 | Answer check: `{me_label}` states a fact that contradicts the brief, tracker or a Decision (wrong status, date, owner, scope) | "Неточно: {Y}, не {X}" + correction phrase + source |
| 🟠 | Answer check: `{me_label}` answered, but not the question that was asked, or only part of it | "Питали про {що}, не про {інше}" + short phrase to close it |
| 🟠 | Answer check: `{me_label}` answered vaguely where the other side wanted a concrete thing (date, owner, yes/no) | "Розмито. Дай {дату / власника / так-ні}" + phrase |
| 🟠 | Side talk: 2+ consecutive `{them_label}` lines in a language other than the one the PM is speaking (e.g. `es` while the call is `en`) | "Між собою іспанською" + the gist in 1-2 lines. Skip small talk. |
| 🟠 | A topic from the brief comes up | gist + up to 3 status facts from the brief |
| 🟠 | A question to the PM stays unanswered for ~2 min | "Без відповіді: {питання}" + phrase |
| 🟠 | At 2/3 of the meeting length | uncovered checklist items |
| 🟠 | 5 min before the end | "Decisions to obtain" not obtained yet |
| silent | Action item (who / what / when), new request, commitment | log to state, show in the wrap-up |

### Answer check (the PM's own replies)

Only when `tips.answer_check: true`. The side-talk trigger only when
`tips.side_talk_summary: true`.

Track question -> answer pairs: a question from `{them_label}` (explicit "?" or an
implied request) and the next `{me_label}` lines up to the next question or ~90 s. For each pair
judge three things against the brief and the tracker:

1. Relevance: did the answer address what was asked, all parts of it?
2. Accuracy: are the facts right (status, dates, owners, scope, decisions)?
3. Commitment: did it promise a date, estimate, scope or money that the PM does not own
   (`decision_rights`)?

Good answers produce no tip. Log every pair with a verdict in state (`answers`) and list
the weak ones in the wrap-up under "Відповіді, до яких варто повернутись". Judge the
content, not the person: no comments on tone, confidence or emotions.

Whisper can still mistake Ukrainian for Russian or misspell names: judge by meaning, mark
an uncertain tip "(?)", never quote a garbled line as fact.

### Rate rules

- 🔴 immediately.
- 🟠 / 🔵 max one message per `tips.rate_seconds`; batch several into one message.
- One tip = the block from "Tip format". Max 2 tips per message, separated by an empty line.
- Never repeat a tip already in `tips_given` unless the situation changed.

### Tip format (small window under the camera)

The PM keeps the Cowork window small, at the top centre of the screen under the camera, and
reads tips with a glance while talking. Every tip is built for that:

1. **Gist line**, bold: emoji + what is happening, in `{settings.user.tips_language}`, max
   7 words. Always first, so the PM understands the point in one second.
2. **Phrase to say**, in quotes, in the language of the call. A ready speech the PM can read
   aloud as is, not theses. 1-2 sentences.
   - English: simple sentences, max 12 words each, everyday words, present or future
     simple, active voice. No idioms, no long subordinate clauses, no rare phrasal verbs.
     "We will check it and come back to you on Friday." Not "Let me circle back once we've
     had a chance to scope it out."
   - Ukrainian or another call language: the same rules, in that language.
   - No phrase when there is nothing to say (pure status or a side-talk summary).
3. **Facts** (only for status and side-talk tips): max 3 short lines, max 8 words each, in
   the language of the call for status (so they can be read out), in
   `{settings.user.tips_language}` for side talk.
4. **Source** (only for 🔴 contradictions and inaccuracies): one short italic line, e.g.
   `_рішення від 30.09_`.

Layout rules: max ~45 characters per line, max 5 lines per tip; no tables, headings, code
blocks or links. **No abbreviations** anywhere in tips, the checklist or the wrap-up: write
"нова вимога" / "a new request", not CR; "термін" / "date", not ETA; no ticket keys either,
name the topic instead. Product and people names stay as they are.

Examples (English call):

> **🔴 Нова вимога. Не погоджуй зараз.**
> "Good idea. I will write it down. We will check it and come back to you."

> **🔴 Неточно: реліз 15.10, не 10.10**
> "Sorry, a small correction. The release date is October 15."
> _рішення від 30.09_

> **🟠 Питали про термін, не про обсяг**
> "About the date: I will confirm it with the team by Friday."

> **🟠 Між собою іспанською**
> Сумніваються, чи встигнуть протестувати до релізу.

Internal Ukrainian call: the gist and the phrase are both in Ukrainian.

### The PM's questions during the call

If the user writes in chat during the loop, answer first (short, in the same tip format,
from the brief, state and transcript tail; a deep lookup is allowed), then continue the
loop from `offset`. "продовжуй" resumes after an interruption.

### How the meeting ends (Stop)

Three ways, all equivalent; the transcript file is closed with a `--- кінець запису HH:MM:SS ---` line:

1. **In chat** (normal way): the user writes "стоп", "все", "кінець", "кінець дзвінка",
   "end live" -> write an empty file `control/stop` (`touch`).
2. **In the "Live transcriber" Terminal window** (it opened by itself at the start): Ctrl+C
   or closing the window -> the next poll returns `@@STATUS stopped`. A backup path.
3. **Automatically**: no new lines for `tips.idle_stop_minutes` after at least 20 lines ->
   ask once "Дзвінок закінчився? Зупиняю запис через 2 хв", then write `control/stop`;
   planned length + 20 min, or `tips.hard_cap_minutes` -> write `control/stop`.

Closing the Zoom/Meet window does NOT stop the recording (the tool keeps listening to the
system audio); one of the three ways above must happen.

After writing `control/stop`, poll status until `stopped` (up to 60 s: the tool finishes
the last phrases), read the final delta, then Step 4 and Step 5 without waiting for a command.

## Step 4 - Wrap-up

One short message, Ukrainian, no abbreviations:

```
## Підсумок дзвінка {title}
Джерела: Transcript OK ({N} рядків, {мови}) · Brief OK · Jira {state} · Notion DBs {state}
Action items: ... (хто / що / коли)
Нові вимоги (кандидати на зміну обсягу): ...
Зобов'язання з нашого боку: ...
Відкриті питання: ...
Відповіді, до яких варто повернутись: ... (питання -> що не так -> як закрити)
Не покрито з чекліста: ...
Транскрипт: {project folder}/live/{file}
Notion: {посилання на сторінку з Step 5}
Далі: звіт по мітингу, change-request, risk-register?
```

The Data Completeness line follows `projects/SKILL.md` (OK / EMPTY / STALE / SKIPPED /
FAILED). Do not run the next skills without the user's command.

## Step 5 - Meetings DB page (automatic after every stop)

Create one page in the project's Meetings DB (`{config.notion.meetings_db}`, fetch the
data source first for exact property names). Hosted Notion MCP (`notion-create-pages`,
`notion-update-page`).

1. **Name.** Generate a short meaningful meeting name in the language of the call from what
   was actually discussed (2-6 words, e.g. "Fraud Engine scope sync"), not "Meeting".
   Title = `<name> @<start date-time>`, where the date-time is a Notion date mention:
   `<name> <mention-date start="YYYY-MM-DD" startTime="HH:mm" timeZone="<zone>"/>`.
   `notion-create-pages` stores a mention in the title as literal text, so create the page
   with the plain `<name>` and then set the title with `notion-update-page`
   `update_properties` (that call parses the mention). Verify with a fetch: the title must
   read `<name> @...`.
2. **Properties.**
   - `Date`: start date-time of the meeting = `started_at` from `status.json` (it already
     carries the Mac's offset, e.g. `2026-10-10T23:48:02+03:00`), with
     `date:Date:is_datetime = 1`; no end.
   - `<zone>` for the title mention: `timezone` from `status.json` (the Mac clock). Missing
     (older live-transcriber): `settings.user.timezone`, else the zone named in the config
     Meetings Schedule, else ask once. Notion accepts `Europe/Kiev` (verified): write
     `Europe/Kyiv` as `Europe/Kiev`.
   - `Project`: the project page (`{config.notion.project_page_id}`) as a URL in a JSON array.
   - `Workspace`: read the `Workspace` relation of that project page (fetch it); fallback
     `{config.notion.workspace_page_id}`. Never guess.
   - `Meeting type`: only if the meeting type from Step 0 exactly matches an existing option;
     otherwise leave it empty (never create options).
   - `Summary`: 1-2 sentence summary (internal language).
3. **Body.** An AI Meeting Notes block with the transcript, then the wrap-up:
   ```
   <meeting-notes>
   	<name>
   	<notes>
   		\[12:30:11\] Я (en): ...
   		\[12:30:15\] Співрозмовник (es): ...
   	</notes>
   </meeting-notes>
   ## Підсумок
   <the Step 4 wrap-up as Notion blocks: action items as to-dos, new requests, open questions>
   ```
   One line of the transcript = one paragraph; escape `[ ] < > *` per the Notion markdown
   spec. Header and footer lines of the transcript file are not copied.
   **Notion API limit (verified 2026-10-11):** the `<transcript>` and `<summary>` sections of
   a meeting-notes block cannot be written through the API (the spec says writing
   `<transcript>` errors), and Notion AI summary generation cannot be triggered through the
   API. So the transcript goes into the `<notes>` section of the block, and the summary is
   written by this skill (Summary property + "Підсумок" section). The PM can still press
   Notion AI in the block manually.
   Long transcripts: if the content is rejected as too large, create the page with the first
   ~300 lines, then append the rest in chunks with `update_content` (old_str = the current
   last line of the notes, new_str = that line + the next chunk, same indentation).
4. **Verify** with a fetch: properties set, title has the date mention, line count in notes
   equals the transcript line count. Put the page link into the wrap-up.
5. Client-facing rule does not apply: the Meetings DB is internal. Restricted 🔒 content may
   go into the "Підсумок" section.

If the hosted Notion MCP is unavailable, say so in the wrap-up and give the transcript path;
do not retry in a loop.

## Fallback: Notion (Mac offline or live-transcriber broken)

If live-transcriber cannot start and the user records the call with Notion AI Meeting
Notes, ask for the Notion meeting page link and read the transcript from Notion instead:

- LOCAL Notion MCP `get-block-children`. The page has 2-3 top-level wrapper blocks
  (summary, notes, transcript) shown as `paragraph` with `has_children: true` and empty
  text; the transcript wrapper's children are one `paragraph` per utterance, created in
  time order (verified 2026-10-07). Find it by content, or poll twice: the one that grows.
- Read with `start_cursor` = last seen block id. The cursor is INCLUSIVE: the first result
  is the last seen block; if its text changed, the new part counts as new.
- No speaker labels, and Notion rendered Ukrainian speech as rough English on 2026-10-07:
  tips from this source are less precise; say so once.
- Poll every 20-30 s (sleep via Bash between calls). If even the local Notion MCP is
  unavailable, use hosted `notion-fetch` with `include_transcript: true` every 60 s and warn
  that this re-reads the whole transcript each time and is expensive.

Everything else (brief, triggers, rate rules, wrap-up) is the same, except Step 5: the
Notion meeting page already holds the real transcript, so do not create a second page.
Only offer to set its `Project`, `Workspace` and `Date` if they are empty.
