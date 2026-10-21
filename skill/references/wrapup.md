# live-tips module: Wrap-up, Meetings DB page, Lessons

Read right after the status is `stopped` and the final delta is read. For hiring calls,
Step 4 and the hiring part of Step 5 are in `references/hiring.md`; this file still gives the
Step 5 destination rule and Step 6. The last action (keepalive marker) is in SKILL.md.

## Step 4 - Wrap-up

**Numbers first, by command.** Run `python3 <tool_root>/bin/lt wrapup-data "<transcript>"` once
(device_bash). It returns JSON with every number this step and Step 5 need: real and dropped
transcript lines, languages and speakers, tips shown by kind, ratings (verdicts, reasons,
comments), late tips, cards fired, facts shown, delay median and max, loop gaps, mic stall
restarts, `find:` asks, and writes `clean_file` (the transcript without artefacts, escaped for
Notion; speaker names already applied from `speakers.json` / `named.md`, unnamed voices stay "Speaker N"). Use these numbers as they are, never count by eye. Read the skill's own state keys
(`theses_used`, `answers`, `action_items`, ...) with `lt state "<transcript>"`.

One short message, Ukrainian, no abbreviations:

```
## Підсумок дзвінка {title}
Джерела: Transcript OK ({N} рядків, {мови}) · Brief OK · Current State {Last updated | missing | stale} · Jira {state} · Notion DBs {state}
Action items: ... (хто / що / коли)
Нові вимоги (кандидати на зміну обсягу): ...
Зобов'язання з нашого боку: ...
Відкриті питання: ...
Тези спічу, які не прозвучали: ...
Відповіді, до яких варто повернутись: ... (питання -> що не так -> як закрити)
Підказки: показано {N}, ✓ {N}, ~ {N}, ✕ {N} (причини: ...), запізнілих {N}, миттєвих карток {N}, фактів 📌 {N}; затримка медіана {N} с, макс {N} с
Фонові пошуки: запущено {N}, дали підказку {N}, запізнились {N}, втрачено {N}
Знайдено, але не знадобилось: ... (теми і факти з пошуків, до яких розмова не повернулась)
Відповіді на мої питання: ... (якщо я питав: питання -> відповідь -> статус)
Не покрито з чекліста: ...
Ollama: ... (рядок `semantic.line_uk` з `lt wrapup-data`, як є; якщо Ollama була вимкнена, пропусти рядок)
Сигнали клієнта: ... (лише для аудиторії client: цитати з часом і прочитання через culture lens, `culture.md`)
Транскрипт: {project folder}/live/{file}
Notion: {посилання на сторінку з Step 5}
Далі: звіт по мітингу, change-request, risk-register?
```

The Data Completeness line follows `projects/SKILL.md` (OK / EMPTY / STALE / SKIPPED /
FAILED). Do not run the next skills without the user's command. If the call went to a
different subject than the checklist, say so in one line instead of listing every checklist
item as missed.

With the tips window on, ALWAYS also emit a short `kind: wrapup` item (missed on 2026-10-21): gist "Дзвінок завершено",
up to 5 `items` (action items and open questions), `note` = the Notion page link once Step 5
is done (one extra read call with `--wait 0` just to emit it).

## Step 5 - Meetings DB page (automatic after every stop: existing page first, new only if none)

**Destination: never create a duplicate.** The PM often records the same call with Notion
AI Meeting Notes in parallel, so a page for this meeting may already exist. Find it first,
create a new page only when there is none.
1. The user gave a Notion page link (in the request, during the call or with "стоп"): that
   page, no search.
2. Otherwise search, in this order, for a page of THIS meeting (started within 20 minutes
   of `started_at`, or created between `started_at` - 20 min and now):
   a. Notion AI meeting notes of that time window (`notion-query-meeting-notes` when the
      tool exists);
   b. the project's Meetings DB (`{config.notion.meetings_db}`): pages whose `Date` or
      created time falls in the window (`notion-query-data-sources` or a search with a
      created-date filter, sorted by newest);
   c. a workspace search for pages created in the window with a meeting-notes block or
      the meeting title words.
   Notion AI may finish its page a minute after the call: if nothing is found, wait ~60 s
   (the recording is already stopped: one `sleep 60` call is fine) and search once more.
3. Exactly one match: write into it. Several: pick the one whose time AND topic match; if
   still unsure, write into none, list the candidates in the final message and ask which
   one (do not create a new page). None after the second search: create one new page in
   the Meetings DB as described below.

**Writing into an existing page.** Fetch it first. Append ONE section at the very end with
`insert_content`, whatever the body already holds (Notion AI summary, notes, transcript,
other text): `## Live Tips: підсумок і роздуми ({HH:MM})` with the Step 4 wrap-up (or the
hiring analysis) plus what Notion AI cannot give: tips that mattered, answers worth
revisiting, contradictions with decisions and the tracker, risks, open questions, next
steps with owners, the tip statistics. Never edit, move or delete existing blocks, the
title or the `Summary`. Transcript: if the page already has a Notion AI transcript, do not
add ours (name the local file in the section); if it has none, add our cleaned transcript
in a toggle "Транскрипт (Live Tips)". Properties: set `Project`, `Workspace` and `Date`
only if they are empty, never overwrite. If the page is outside the Meetings DB, leave it
where it is and say so in the final message. A second run for the same meeting (the
section already exists) appends `## Live Tips: доповнення ({HH:MM})` instead of a duplicate.

**Creating a new page** (no existing page found) in the project's Meetings DB
(`{config.notion.meetings_db}`, fetch the data source first for exact property names), as
described below.

Hosted Notion MCP (`notion-create-pages`, `notion-update-page`).

**ALWAYS pass `parent: {"type": "data_source_id", "data_source_id": "<meetings_db id>"}` in `notion-create-pages`.** Without a parent the page is created as a private
workspace page, outside the DB, with no properties (verified 2026-10-14). After creating, fetch the page and check that
`ancestor-path` shows the Meetings data source; if not, `notion-move-pages` it into the data
source, then set the properties. Relation values (`Project`, `Workspace`) are given as page
IDs copied exactly from the config; never retype an ID by hand from memory, copy it.

1. **Name.** Generate a short meaningful meeting name in the language of the call from what
   was actually discussed (2-6 words, e.g. "Fraud Engine scope sync"), not "Meeting".
   Property `Meeting Name` (the title property of the Meetings DB; check the schema).
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
   - `<zone>` for the title mention: `timezone` from `status.json` (the Mac clock; it may say
     `Europe/Uzhgorod`, which Notion may reject: use `Europe/Kiev` then). Missing
     (older live-transcriber): `settings.user.timezone`, else the zone named in the config
     Meetings Schedule, else ask once. Notion accepts `Europe/Kiev` (verified): write
     `Europe/Kyiv` as `Europe/Kiev`.
   - `Project`: the project page (`{config.notion.project_page_id}`) as a JSON array.
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
   spec. Take the lines from `clean_file` of `lt wrapup-data` (header, footer, markers and
   artefacts already dropped, `[ ] < > *` already escaped); drop by hand only what it missed
   (short repeats of the Whisper prompt's opening such as "Дзвінок команди ..." with a garbled
   ending) and say so in one line with the COUNT from its numbers: "відкинуто {N} з {M} рядків
   як артефакти". Never count by eye: a
   transcript with 20+ real lines always goes into the page, even if many lines were
   artefacts. Skipping the transcript is allowed only when fewer than 20 real lines remain.
   **Notion API limit (verified 2026-10-11):** the `<transcript>` and `<summary>` sections of
   a meeting-notes block cannot be written through the API (the spec says writing
   `<transcript>` errors), and Notion AI summary generation cannot be triggered through the
   API. So the transcript goes into the `<notes>` section of the block, and the summary is
   written by this skill (Summary property + "Підсумок" section). The PM can still press
   Notion AI in the block manually.
   Long transcripts: if the content is rejected as too large, create the page with the first
   ~300 lines, then append the rest in chunks with `update_content` (old_str = the current
   last line of the notes, new_str = that line + the next chunk, same indentation). If the
   transcript is too large to retype reasonably (more than ~150 useful lines), write the
   wrap-up only, name the local transcript file, and offer to add the transcript on request.
4. **Verify** with a fetch: parent is the Meetings DB, properties set, title has the date mention, wrap-up present (and line count in notes equals the transcript line
   count when the transcript was added). Put the page link into the wrap-up.
5. Client-facing rule does not apply: the Meetings DB is internal. Restricted 🔒 content may
   go into the "Підсумок" section.

If the hosted Notion MCP is unavailable, say so in the wrap-up and give the transcript path;
do not retry in a loop.

## Step 6 - Lessons from the PM's notes (after Step 5, before the final text)

During the call the PM may type notes in the chat or the window that are not questions
(including "ти мені не допоміг по темі X": log it with the topic, and check afterwards whether
a document on that topic existed and was not in the Insight Bank; if so, the lesson is a gap in
the topic documents rule of Step 2b):
corrections ("тут правильніше було відповісти так"), wishes ("такі підказки не треба",
"давай частіше по цінах"), complaints ("запізно"). Log every such note in state
(`pm_notes`: time, text, the tip or moment it refers to) as it arrives, together with ✓ / ✕
ratings (`feedback`) and loop facts from the state file (`max_gap_s`, `stalls_over_60s`,
median tip delay). After Step 5:
0. **Ratings with reasons and comments** (`<transcript name>.feedback.jsonl`, last line per
   tip wins): group them by reason and by topic. A `partly` with a comment is split into the
   useful part (keep, maybe make it a card or a fact) and the off part (the change). Only a
   pattern seen 2+ times, or one comment that names an exact rule ("такі не треба"), becomes
   a proposed change; a single ✕ never removes a topic, a fact or a 🔴 trigger.
   **Late-tip patterns** (when `<transcript name>.late.jsonl` has lines). `late` ratings join them. For each late tip
   look at the transcript around it: what triggered it, what the PM said first, how long
   the model took. Sort into causes and count them:
   - **predictable**: the question or topic was in the agenda, an open thread, the current
     state or the last meeting of this type -> it should have been a card or a fact in the
     prep (name which);
   - **in the book, missed**: the fact existed but the keywords did not match what people
     said -> add those words as keywords;
   - **slow loop**: the topic was fresh, the model needed the time -> loop speed (model,
     effort, the size of the polls);
   - **unpredictable**: a new topic -> nothing to change.
   Only a cause that repeats (2+ tips on this call, or the same cause on earlier calls in
   `<project_root>/live/lessons.md`) becomes a proposed change; a single case is just
   listed. Put the result into the lessons below as project lessons (cards, facts, keywords
   for the next prep of this meeting type) or skill changes.
1. Sort them into two kinds and show them in ONE `SendUserMessage`, Ukrainian, numbered:
   - **Project lessons** (facts and wording for this project or this kind of call: "клієнт
     називає X як Y", "на питання про ціни відповідати так"): proposed lines for
     `<project_root>/live/lessons.md`;
   - **Skill changes** (behaviour of live-tips itself: what triggers, how often, the tip
     format, the window): each as "проблема -> зміна -> де в скілі".
   Ask: "Застосувати? (всі / номери / ні)". This is the one place a question is allowed
   before the end, and the turn may end with it after the marker is removed (below).
2. On approval (the PM's next message):
   - project lessons: append to `<project_root>/live/lessons.md` (device_bash, append only,
     one dated line each). The prep and the sweep read this file first on every next call
     of the project and turn the lessons into cards and brief rules;
   - skill changes: the synced skill files are read-only. The skill has several files
     (`SKILL.md`, `settings.yaml`, `references/*.md`); change only the files the approved
     changes touch, copy every other file byte for byte from the installed skill, keep the
     rest of each touched file word for word, check there is no long dash, and package the
     WHOLE skill as `live-tips-<date>.skill` (zip with the folder `live-tips/` and all its
     files) into `{settings.paths.work_root}/Skills` and say which files changed. Never offer
     a `propose_skills` card for this skill: a card carries only SKILL.md and would drop the
     modules. Also append each approved change in
     one line to `{settings.paths.work_root}/Skills/live-tips-changelog.md` (create if
     missing) so other sessions see what changed.
   - Nothing is changed without the PM's yes.
3. With no notes, no ratings and no loop problems, skip Step 6 silently.
