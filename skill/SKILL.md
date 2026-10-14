---
name: "live-tips"
description: "Live call assistant. Records the call, shows the PM's speech theses and a ready status at the start, posts active tips during the call, then writes a summary to the Notion Meetings DB. Hiring interviews in three roles (observer, candidate, interviewer) with live model answers and a post-interview analysis. Trigger on \"live tips\", \"лайв підказки\", \"я на дзвінку\", \"співбесіда\", \"hiring interview\", \"стоп\"."
---

# Live Tips

Live co-pilot for the PM during a call. The local tool `live-transcriber`
(`{settings.paths.tool_root}`, see its README) records the PM's mic and
the system audio, transcribes each phrase with Whisper on the Mac and appends lines to
`<project_root>/live/<YYYY-MM-DD-HHMM>-<title>.md`:

```
[12:30:11] {me_label} (uk): ...
[12:30:15] {them_label} (en): ...
```

**Settings.** Everything personal (labels, paths, language defaults, tip rules, model hint)
is in `settings.yaml` next to this file. Read it first. Nothing user-specific is hard-coded
in this file; examples below use the author's values only as illustration.
Full human documentation: `docs/uk/17-live-tips.md` in the pm-control-tower repository.

This skill starts the recording, **at once shows the PM's speech as theses** (and, for status
calls, a ready status: what was done, what is next), then reads only the NEW lines, matches
them against a pre-built Live Brief and Insight Bank of the project and **actively helps the PM
take part in the conversation**: it offers things to add, questions to ask, and a way back to
the agenda. Silence is the default only when the PM is already speaking well or nothing useful
can be added. Notion AI Meeting Notes is the fallback source (section "Fallback: Notion").

Model: every iteration's thinking time adds to the tip delay. See `model_hint` in
settings: Sonnet class with low or medium effort for everyday calls, Opus class for
interviews and high-stakes calls when a delay of 10-30 s is fine. Not Haiku class: the
answer check and multilingual nuance need judgement.
The model cannot be changed from the tips window or by this skill: it is chosen in Cowork
before the call (and a Whisper swap mid-call would lose speech). Never offer a model
switch in the window or in a tip; if the PM asks, say it is set in Cowork before the call.

Typical session: the PM first runs a prep in the same session (`client-meeting-prep`,
`daily-team-prep` or a free-form "prepare me for X" with meeting details, Notion pages or a
folder to focus on), then starts this skill right before the call. Everything prepared
earlier in the session is input for the speech and the Live Brief (Step 2).

Hard rules:
- **SPEED (tip delay is measured and must stay low).** Target: tip in the window within ~8-10 s
  of the end of the question. Where the time goes, from `<transcript>.timing.jsonl` (per line:
  `seg_end`, `queued_s`, `asr_s`, `written`) and `<transcript>.polls.jsonl` (per poll:
  `think_gap_s` = my thinking and tool time between two polls). Note: the time stamp of a
  transcript line is the START of the segment, not its end. Rules for me:
  1. In a hiring or any tip-heavy moment do NOT deliberate: decide in one pass, write the tip
     straight into the `--emit-stdin` heredoc of the NEXT `read_delta` call (emit and poll in
     ONE call). No separate tool call for emitting, no state writes in between.
  2. In `window` mode do not also `SendUserMessage` every tip (an extra round trip); chat copies
     only in `both` mode and only for 🔴.
  3. No lookups, no file reads and no state writes while a question is open. Update the state
     file at most once per ~5 minutes, in the same call as a poll when possible (`read_delta`
     already keeps `offset` and counters current).
  4. Use `--settle 1` in hiring and when a question is expected, `--settle 2` otherwise.
  5. Do NOT shorten the reference answer to gain speed. Keep 4-5 substantive sentences
     (the concrete terms, a tool or example, the usual pitfall), never a surface summary. Gain
     speed from the process instead: no preamble, no second draft, no hedging, the answer is
     written straight into the heredoc in the interview language.
  6. The best way to be fast AND deep: during the quiet start (Prep) write a reference answer
     of full depth for each likely topic into the brief (an internal Answer Bank). When the
     question arrives, adapt that answer to the exact wording instead of composing from zero.
  7. Reasoning effort is a balance: medium for interviews. Read `think_gap_s` in `.polls.jsonl`
     after the call: if the median is above ~8 s, lower the effort one step; if answers turn
     shallow, raise it. Never trade answer substance for speed.
- **LOOP DISCIPLINE (most important).** Tips exist only while the loop runs, and the loop runs
  only while this turn is alive and makes tool calls. A plain text answer ends the turn, which
  kills the loop: tips stop and the PM sees a silent window. Therefore, from the moment the
  recording starts until the transcript is closed (status `stopped`) and Step 5 is done:
  1. NEVER end the turn with a text answer. Every message to the PM goes through
     `SendUserMessage` (start message, speech notice, replies, health warnings, 5 minute
     lines), and the very next action is always the next `read_delta` call.
  2. Do not pause to "wait for the user" and do not ask a confirmation question as a final
     text. A question to the PM is sent with `SendUserMessage` and the loop keeps polling.
  3. If the call looks over (goodbyes, silence), say so with `SendUserMessage`, keep polling,
     and let the user's "стоп" or the idle auto stop (Step 3, "How the meeting ends") finish it.
  4. Preparation work (reading docs, building the brief, Insight Bank) is also done by tool
     calls inside the same turn, and a `read_delta` poll is never skipped for more than
     ~60 s while preparation runs: start polling first, prepare in between.
  5. If a user message arrives mid loop, answer it with `SendUserMessage` and continue.
  6. Keep each iteration short: decide, emit, poll. Heavy work (a deep lookup, a long
     analysis) is split so that no gap between two `read_delta` calls exceeds ~60 s.
  7. Safety net: every `read_delta` call touches `state/listener`; when no poll happened for
     75 s while recording, the tips window turns its status line red: "⚠ Claude не слухає
     N с. Напиши в чаті Cowork: продовжуй". A question typed in the window cannot revive a
     finished turn, only a chat message can. On "продовжуй" (or any chat message after a
     stall): read `<transcript name>.state.json`, say in one `SendUserMessage` line how long
     the gap was, catch up on the missed lines in one batch (tips only for what is still
     relevant) and continue the loop.
  8. **Keepalive hook.** With the `live-tips-keepalive` plugin installed, a Stop hook refuses
     to end the turn while the marker `$HOME/.live-tips/keepalive.json` exists in this
     session's own environment (written in Step 1, removed at the very end). If a "Stop hook
     feedback" message arrives, it means the turn tried to end: do not explain or apologise,
     go straight back to the next `read_delta` poll. Without the plugin the marker does no
     harm.
  Only the final wrap-up message after Step 5 may be a plain text answer.
- No writes to Notion, Jira, Slack or email during or after the call without an explicit
  command, with ONE exception: Step 5 writes the call summary into the project's Meetings DB
  (internal hub, never the client's workspace): into the page the PM names, else one new page.
  Nothing is ever sent to the client. The only local files written are the control files of
  live-transcriber and this skill's own state/brief under `<project_root>/live/`.
- Tips follow the section "Tip format": a short gist in `{settings.user.tips_language}`,
  then a ready phrase in the language of the call. No abbreviations. Never use the long dash.
- **Tips must carry project insight.** A tip without a concrete fact from the Insight Bank
  (number, name, date, source), a concrete question or a concrete next step is not sent.
  Generic advice ("agree and add a fact", "good point", "discuss pricing") is forbidden.
- Restricted internal sources (`projects/SKILL.md`) may shape a tip, but such a tip is
  marked 🔒 so the PM never repeats it aloud to the client.
- Estimates: never suggest a number (`_standards.md`, rule 7). Only "оцінку дає
  виконавець, зафіксуй і повернись".
- Never invent status. Every thesis in the speech comes from the tracker, the notes, the prep
  report, the project documents or the session. If a source is empty or stale, say so in one
  line instead of guessing.
- Dates of facts: a fact older than the last relevant research doc may be stale. Say "станом
  на {date}" in the note line when the source is older than 3 days.

## Paths

| What | On the Mac | Inside device_bash |
|---|---|---|
| Tool root | `{tool_root}` | `$HOME/mnt/<basename of the tool_root folder>` if only the tool folder is connected, else `{tool_root}` with `{work_root}` replaced by `$HOME/mnt/<basename of work_root>` |
| Project folder | `{config.project_root}` | same replacement; check `ls $HOME/mnt/` to see what is mounted |

`work_root` and `tool_root` come from `settings.paths`. `project_root` comes from the
project config `Local Paths`. Missing: use the parent of `repos_root` / `reports_root`,
else `{work_root}/{project_name}` if it exists, else ask. If the tool folder is not mounted,
call `device_request_folder_access` for the tool root (one request, with a reason), do not
wait for the user to find the button.

## Step 0 - Project and meeting

1. **Project.** Slug from the request, or from the instructions of the claude.ai Project
   this session is attached to when they name the slug explicitly (for example
   "Проєкт: Acme Portal (slug: acme-portal)"). That counts as explicit. Otherwise ask, listing
   configs in `projects/` (Default Project Rule).
2. Read `../projects/{slug}.md` (fallback: Glob `**/projects/{slug}.md`), the `PM Profile`
   and `projects/_standards.md` section 5 (agendas).
3. **Meeting type, title, length.** From the user's words, else from the config Meetings
   Schedule by day and time when the clock is within 30 minutes of a scheduled slot (the
   `Type` column is the title), else it is asked in the start questions (item 5). Never
   guess a type from a project alone: a wrong type builds a wrong brief. Length: default 60 min.
   Type decides:
   - **status call**: PM stand-up, a daily team sync, any internal sync or planning call where everyone reports (window name:
     **Internal standup**). One type, two ways to take part, and they can mix in one call:
     the PM **reports** (others ask the PM) and/or the PM **leads** (the PM asks the devs and
     the team for statuses and digs into problem spots). The speech is a ready status
     (Step 2a, "Status" mode) plus, when the PM leads, the "Lead" part below.
   - **client call**: client phrasing, 🔒 rule.
   - **topic call**: a call about one subject (an incident, a contract, a decision). The
     speech is the PM's position and key points on that subject.
   - **hiring interview**: a job interview, whatever the position or the project ("співбесіда",
     "інтерв'ю з кандидатом", "hiring", "interview for <position>", "показуємо кандидата
     клієнту"). It has a **role** (`hiring_role`), asked in the start questions when the
     user's words do not settle it:
     - `observer`: the PM listens; another person (often our candidate shown to the client)
       is interviewed by someone else. The PM's mic stays silent;
     - `candidate`: the PM is the one being interviewed (the PM's own job search). There
       is no project here: the **company** takes the place of the project (Default Project
       Rule becomes "never guess the company"), the context comes from the PM's job search
       hub (`settings.hiring.candidate`), and the recording goes to
       `settings.hiring.candidate.root`;
     - `interviewer`: the PM asks the questions (hiring for the PM's own project or for
       someone else; the PM adds details).
     Rules: section "Hiring interview mode". The position (for example QA automation) comes
     from the user's words; if missing, ask it in the start questions as "Other" text.
4. **Languages.** `me_lang` = the PM's main mic language on this call, `me_langs` = the
   languages the PM may switch to on this call (the mic picks only among them, so Ukrainian
   is never heard as Russian), `langs` = all languages expected on the call. Resolution order:
   1. the user's words ("сьогодні англійською", "будуть іспанською");
   2. `settings.languages.per_project.{slug}.{internal|client}`;
   3. `settings.languages.internal` or `settings.languages.client`, where `from_project`
      means the project config `client_language` (as an ISO code: English -> en).

5. **Fast start (default, `settings.start.mode: window`).** Speed first: the recording must
   start within ~20 s of the request, nothing said on the call may be lost to questions.
   - In chat ask ONLY what decides where the recording goes: the Project when it is not
     explicit (Default Project Rule), or the company for a `candidate` interview when the
     words say it is one and do not name the company. One AskUserQuestion call, or none.
   - Everything else starts from defaults: type from the user's words, else the schedule
     slot within 30 minutes, else **unset** (no speech yet: emit one `info` item "Set the
     meeting type in ⚙ to get your speech" and only listen, generic tips allowed; build the
     speech the moment `@@SET call_type` arrives, or after 2 minutes from what is being
     discussed); language from item 4; mic from
     `settings.audio.mic`. Write `"setup": true` (and `call_type` / `hiring_role` when known)
     into `start.json`: the tips window then opens its ⚙︎ row with Тип, Роль, Мова,
     Мікрофон, and the PM corrects them during the call. Language and mic are applied by
     the recorder itself at once (a `--- мова: ... ---` / `--- мікрофон: ... ---` line marks
     the switch in the transcript, nothing is lost). Type and role reach this skill as
     `@@SET call_type=...` / `@@SET hiring_role=...`: rebuild the speech / prep for the new
     type at once (Step 2a), keep everything already said.
   - The start message names the defaults in one line and says "змінити можна в ⚙︎ у вікні".
   - A **prep ahead** makes the start instant: "підготуй live tips до {дзвінок}" (any time
     before the call) runs Step 0 and Step 2 without recording and saves the brief as
     `<project_root>/live/prep-<YYYY-MM-DD-HHMM>-<title>.brief.md`. At the start, a prep brief
     of the same project (or company) younger than 3 hours is reused: no sweep, the speech
     and tips are ready from the first second. Say "Бриф з підготовки {час} підхоплено".
   `settings.start.mode: chat` keeps the start questions below (the older flow).

   **Start questions (`start.mode: chat` only, in chat, before anything is written or
   started).** Ask with the AskUserQuestion tool, ONE call, in this order, and skip any question the user's words
   or the claude.ai Project instructions already answered:
   1. **Project** (only if not explicit, Default Project Rule): options = the configs in
      `projects/`, plus the workspace entries from `settings.workspaces`. The FIRST option
      is the first workspace entry, when there is one (a general company call about all
      the projects listed in it). Choosing a workspace entry is an explicit choice: no project
      guess happens. For a workspace entry: `project_root` = `settings.workspaces.<key>.project_root`; for a project slug in `settings.project_roots`, that path wins
      (the recording goes to its `live/` folder), the Live Brief covers EVERY project listed
      in that entry (one brief section per project, each from its own `projects/{slug}.md`),
      and the Notion destination is the Meeting page the user names, else ask.
   2. **Call type** (skip when the user's words or the schedule slot in item 3 settled it):
      options = the `Type` values from the config Meetings Schedule (for example
      `Team Stand Up`, `Client Weekly`), plus `Співбесіда (hiring)` and
      `Інша тема` (the user names the subject in "Other"; it becomes the title and the focus
      of the brief). Max 4 options: keep the 2 schedule slots nearest to the current time.
      Mark as recommended the slot nearest to the current time. The answer sets the call kind
      (status, client, topic, hiring) and the title.
      **Hiring role.** When the user's words already say it is a hiring interview, ask
      instead of the call type: `Твоя роль на співбесіді` with options `Спостерігач`
      (observer), `Мене інтерв'юють` (candidate), `Я питаю` (interviewer); "Other" = details.
      When `Співбесіда (hiring)` was picked as the call type, ask the role right after in a
      second AskUserQuestion call (the only case with two calls). The words settle the role
      when they say it ("я спостерігаю", "мене співбесідують", "я наймаю", "я інтерв'юю").
      **Company (role `candidate` only).** When the role is or may be `candidate` and the
      words do not name the company: before asking, query the Job Tracker
      (`settings.hiring.candidate.job_tracker`) for rows with `Status` in `Recruiter screen`,
      `Interview`, `Final`, nearest `Next step on` first; ask `З якою компанією?` with up to 3
      of them (`Company` + `Vacancy`) as options, "Other" = free text. When the role is
      still unknown, put this question in the same call as the role and label it "(якщо
      мене інтерв'юють)". The Project question is skipped for `candidate`. If the query tool
      fails, ask with "Other" only and find the row by name later.
   3. **Call language**: options `Українська` (me_lang `uk`, me_langs `uk+en`, langs `uk+en`),
      `English` (me_lang `en`, me_langs `en+uk`, langs `en+uk`), `Мікс` (main language and
      lists from the resolution order in item 4, which already default to a mix). Mark as
      recommended the option that matches the resolved default for this project and call kind.
      "Other" = free text: take the language(s) named there (for example Spanish) as the
      main language and add `uk` and `en` to `me_langs` / `langs`. Never offer Russian.
   4. **Microphone**: options `За замовчуванням` (`mic_device` `default`: the Mac's current
      input, headset or built-in) and `Мікрофон Мака` (`builtin`: the Mac's own microphone,
      even when AirPods or another headset are connected). Mark as recommended the option
      from `settings.audio.mic`.
   After the start, check `logs/audiocap-mic.log`: if `frames=0` repeats or `mic restart`
   lines pile up, tell the user at once and offer to restart with `default`.
   If `settings.start.ask` is `false`, do not ask the language and microphone questions:
   use the defaults and state them in the start message. If the AskUserQuestion tool is
   not available, or nobody is there to answer (scheduled run), use the defaults and state
   them. Meeting length is never asked: use the default.

## Step 1 - Start the recording (first, before the brief)

0. Check the install: `<tool_root>/.venv/bin/python` and `<tool_root>/bin/audiocap` exist.
   If not, stop and tell the user to run `bash <tool_root>/install.sh` in Terminal once
   (5-10 min, ~1.6 GB model) and to allow Terminal both the microphone and System Audio
   Recording. Do not write `start.json` before that.
1. Check that nothing is recording: read `state/status.json`. If `state` is `recording`
   for the same project, reuse it (take `file` from the status). If another project is
   recording, stop and tell the user, do not mix. Stale status: if `state` is `recording`
   but `state/status.json` has not updated for 10+ minutes (the process is dead), write
   `control/stop`, wait a few seconds, and if it still does not clear, go on with the new
   `start.json` anyway (the new run replaces it) and tell the user in one line.
2. Build `prompt` for Whisper: ONE short natural sentence in the main call language, max
   ~150 chars, with the key proper names and terms from the config (team, client, product,
   module names) plus `settings.user.name_aliases`, e.g. "Дзвінок команди Acme Portal: Іван,
   Олена, реліз, Jira." It improves spelling of names. Not a bare comma list of names: on
   silence Whisper repeats such a list back in a loop (live-transcriber drops those lines).
   The prompt MUST be in the language of the speech: a Ukrainian prompt on English speech
   turns it into Ukrainian gibberish. For an English call write an English prompt. Also
   give `prompt_en` and `prompt_uk` in `start.json`: when the window switches the language
   the recorder swaps to the matching prompt (or drops it for `en` if none).
3. Write `control/start.json` with a small python one-liner inside device_bash
   (`json.dump`, UTF-8, `ensure_ascii=False`):
   `{"project_dir": "<Mac path of project_root>", "title": "...", "slug": "...", "me_lang": "...", "me_langs": "xx+yy", "langs": "xx+yy+zz", "me_label": "...", "them_label": "...", "prompt": "...", "prompter": true, "mic_device": "default", "setup": true, "call_type": "status|client|topic|hiring", "hiring_role": "observer|candidate|interviewer"}`
   (`setup`, `call_type`, `hiring_role` only in the fast start; omit unknown ones;
   `prompt_en` / `prompt_uk` are optional and allowed)
   (labels from `settings.user`; `prompter` = `settings.tips.output` is not `chat`;
   `mic_device` = `default` (the Mac's current input: AirPods, other headsets) or `builtin`
   (the Mac's own microphone). Take it from the answer to the start question (Step 0, item 5), else from the user's words ("з мікрофона маку", "mac mic",
   "на мікрофон ноутбука" -> `builtin`; "на навушниках" -> `default`), else from
   `settings.audio.mic` (`default` | `mac_mic`; missing = `default`). It cannot change during
   a call: to switch, stop and start again.)
   The LaunchAgent opens a Terminal window "Live transcriber" with the recording by itself;
   the PM does not start it, may minimise it, should not close it.
4. Poll `state/status.json` every 3 s up to 60 s (model load takes 5-20 s):
   - `recording` -> take `file`, `tips_file` and `inbox_file`, map them to device_bash paths, go on;
   - `error` or nothing after 60 s -> rename `control/start.json` to `control/start.json.pending`
     (`mv -n`, so the recording does not start by surprise later), then show `logs/transcriber.log` tail (last 15 lines) and
     `logs/launcher.log`, say what failed. Common fixes: install.sh not run, Terminal has no
     microphone / system audio permission, LaunchAgent not loaded
     (`launchctl list | grep live-transcriber` on the Mac).
5. **Keepalive marker.** Right after `recording`, write the marker with the cloud `Bash`
   tool (this session's own environment, NOT device_bash):
   `mkdir -p ~/.live-tips && python3 -c 'import json,time; json.dump({"until": time.time()+60*(<tips.hard_cap_minutes>+30), "title": "<title>", "state_file": "<state file path>", "max_blocks": 400}, open("'$HOME'/.live-tips/keepalive.json","w"))'`.
   If the session has no `Bash` tool, skip it.
6. One `SendUserMessage` (NOT a final answer, see LOOP DISCIPLINE): `Запис іде: {file name}. Мови: я {me_langs or me_lang}, дозволені {langs}. Мікрофон: {навушники або системний за замовчуванням | мікрофон Мака}.` With the tips window on, add `Підказки у вікні-суфлері.` Do NOT wait for the brief: go to Step 2 right away, and keep the loop alive.

## Step 2 - Context sweep, the PM's speech, the Live Brief

The PM wants to see their own speech as theses the moment the call starts, and wants tips
that know the whole research, not generic advice. So Step 2 has three parts: 2a is fast and
goes out first, 2b builds the Insight Bank and the brief, and polling continues in between
(LOOP DISCIPLINE, item 4).

### Step 2a - Speech theses (target: in the window within ~30-40 s of the start)

**Focus sources first.** If this session already holds a meeting prep, an agenda, a prep
report (`daily-team-prep`, `client-meeting-prep`), interview questions, or the user named
specific Notion pages, documents or a folder for this call, take the points from there. They
are a priority, not a limit.

**Status mode** (call kind = status: stand-up, a team sync, internal daily, any
round of updates). Generate the status immediately, without being asked:

1. **Period.** From the end of the previous meeting of this type (Meetings DB, last page of
   that type; the calendar if the Meetings DB has none) to now. If it cannot be found:
   yesterday, and for Monday since Friday. Say the period in the first line ("за період
   12.10-13.10").
2. **Collect in parallel, only what is needed for the status:** task tracker (per
   `task_tracker.api_access`): tickets of the PM and of the team changed in the period
   (moved to Done, Dev Done, deployed, new blockers) and in progress now; Meetings DB:
   action items and promises of the last meeting of this type; Reports DB: today's prep
   report; the Threads DB: `Awaiting Reply` / `Need Follow-up`; **the newest documents of the
   claude.ai Project** (see 2b, sweep step 1) for what was researched in the period.
   Collectors and git are not run here, they are too slow.
3. **Compress into the speech**, in the language of the call, max 8 words per line:
   - **Було** (done in the period): 3-5 outcomes, results not activity;
   - **Зараз у роботі** (in progress): 2-3 points;
   - **Далі** (plans for the next period): 2-4 points;
   - **Блокери і потрібні рішення**: 0-3 points, each with who must decide;
   - one ready opening sentence.
   For a meeting that covers several projects, one short block per project.
4. Emit it to the window as `kind: speech` (see "Tips window") and send it to the chat in
   `both` mode with `SendUserMessage`. A speech item may have up to 12 lines, it is the only
   tip allowed to be longer. Then continue to 2b.
5. If the tracker or notes are unreachable, say which source failed in one line and give the
   speech from what is available; never fill gaps with guesses.
6. **Lead part** (the PM hosts the standup, says so, or starts asking others "що в тебе",
   "які апдейти", "what's the status"): emit a second item `kind: checklist`, gist "🧭 Веду
   стендап": per person 1-2 lines, what to ask them about (their tickets in progress, a
   blocker, a promise from the last meeting, a date that is close), then 1-3 problem spots
   to raise (stuck tickets, overdue items, open client questions). During the call, while
   the PM leads:
   - track who has reported; near the end, "Ще не звітували: {імена}";
   - a vague update from someone ("працюю над цим", "майже готово") -> 🟠 "Уточни: {що}" with
     a ready question about the date, the blocker or what "done" means;
   - a blocker or a problem without an owner or a date -> 🟠 "Зафіксуй: {що}" with a ready
     closing phrase ("Тоді {owner} робить {action} до {day}, так?"), never a number for an
     estimate;
   - an update that contradicts the tracker or the last meeting -> 🟠 "Розбіжність: {що}"
     with the source;
   - comment moments and "Your turn" still work when someone asks the PM.
   The wrap-up lists per person: update, blocker, next step and owner.

**Topic mode / client call / interview**: the speech is the PM's position and key points for
the subject: 3-6 theses (what we want from this call, our position, facts to state, what we
should not say), plus an opening sentence. If the PM plans to ask the client questions, the
planned questions in order. For a hiring interview: see "Hiring interview mode" (Prep), the speech is replaced by
the role's prep item.

**Refresh.** The PM can ask "онови спіч" in the chat or the window at any time (or the window
button): regenerate from fresh data and emit again. After each other participant's report in
a round, when the PM's turn is near, re-emit "Your turn" (see Triggers).

### Step 2b - Context sweep, Insight Bank and Live Brief

**Context budget (why the sweep runs in a subagent).** Everything this session reads stays
in its context for the whole call, and the loop itself adds a little every poll. Raw
documents read at the start can fill the context mid-call; Cowork then compacts the
conversation, which costs tens of seconds without tips and loses detail. So:
- The sweep (this section) and the `candidate` prep run in a **subagent** (the Agent tool,
  general-purpose type) when the session has it. The subagent reads the raw sources in its
  own context, writes the full `<transcript name>.brief.md` and `<transcript name>.cards.json` itself (device_bash, the path
  given in its brief) and returns ONLY the compact part: the checklist, the topic map with
  keywords, the Insight Bank (or the Answer Bank), and one line of sources loaded and not
  loaded. Give it everything it needs in its brief: slug, config path, `project_root`
  paths inside device_bash, the meeting type and title, the call languages, the Notion IDs
  from the config, the list below, the output format and size (max ~1200 words returned).
  If a source is not reachable from the subagent (for example the claude.ai Project
  documents), it says so and the main session reads only that source itself.
- The Agent call blocks the loop while it runs (usually 1-3 min). Before it: emit the speech
  and send `Готую бриф, підказки по фактах з'являться за 1-3 хв.` After it: one
  `read_delta` catch-up of everything said meanwhile, tips only for what is still relevant.
  If the PM starts the skill before the call begins ("дзвінок через 10 хв"), run the
  subagent first and start the recording right after, so nothing is missed.
- No Agent tool: do the sweep inline as before, keep it short, and never read a document
  that is not needed for this call.
- Deep lookups during the call stay small (one page, one ticket); a big one goes to a
  subagent too.
- **After a compaction** (earlier messages replaced by a summary): before the next tip,
  re-read `<transcript name>.brief.md` and `<transcript name>.state.json` and continue from
  `offset`. They hold everything the loop needs.

**Context sweep (what makes tips specific).** The PM does research in many other chats and
threads. This session cannot see those chats. It only sees what was SAVED: documents of the
claude.ai Project this session is attached to, the project folder on the Mac (`reports/`,
`research/`), Confluence pages, Notion pages. So the sweep (in the subagent) reads those,
newest first:

1. If a claude.ai Project is attached: call `project_info`, then read EVERY document modified
   in the last 14 days (all of them if there are fewer than ~15) with `project_read`, plus
   the research log. Read the newest findings documents fully, not only the log: logs are
   short and often outdated. Do this in parallel batches.
0. `<project_root>/live/lessons.md` (Step 6) if it exists: read it first, every line is a
   rule for this project's calls; turn the relevant ones into brief rules and cards.
2. Project folder on the Mac: the 15 newest documents anywhere under `project_root`
   (`.md`, `.pdf`, `.docx`, `.xlsx`, `.txt`; skip `live/`, repositories, `node_modules`,
   archives), by modification time, plus `reports/` and `research/`; read the 3-5 that fit
   this call and are not already covered by Project documents.
3. Notion, all scoped to this project: Meetings DB (the last 3 meetings of ANY type, plus
   the last 2 of this type: decisions, action items, promises, open questions), Threads DB
   (`Awaiting Reply`, `Need Follow-up`, `AI Review`, and threads updated in the last 7
   days), Topics (open), Decisions (last 30 days), Risks (open), Reports DB (the newest
   report of each type in the last 14 days); Confluence space of the project if the config
   names one (titles of pages changed in the last 7 days, then the relevant ones).
   The same full list is used by a prep ahead ("підготуй live tips до ...", "підготуйся до
   дзвінка"): a prep is never lighter than the sweep.
4. The main session says in ONE `SendUserMessage` line which sources were loaded (names and dates of the newest
   documents) and tell the PM that research done in other chats is invisible unless saved:
   "Що не збережено в проєкт, я не бачу. Збережи в проєкт або скажи в чаті." Offer nothing
   else. Do not end the turn.

**Insight Bank.** Distill the sweep into 15-40 one-line insights in the call languages,
each: fact with a number or a name, source document, date checked. Group by topic with
keywords (every language of `langs`) so the matching in Step 3 is quick. Include for every
competitor, tool or option discussed: price and plan, limits, language support, data
location, open questions, and the PM's own conclusions and recommendations. Include open
tasks and who owns them. Include contradictions found between documents (flag them).
This is the main source of "Додай", "Можеш додати" and "Твоя черга" tips.

Then collect in parallel, everything scoped to this project (relation `Project` =
`{config.notion.project_page_id}`; tracker queries via the JQL Isolation Validator):

| Source | What to take |
|---|---|
| Topics DB | open topics: one line each, current position, last decision |
| Decisions DB | last 30 days: decision + date (to catch contradictions) |
| Risks DB | open; for a client call only `External` / `Both` |
| Threads DB | `Awaiting Reply` / `Need Follow-up` |
| Meetings DB | last 2 meetings of this type: unclosed action items, promises |
| Task tracker | per `task_tracker.api_access`: in progress, blocked, awaiting client (else `fallback_source`) |
| Reports DB | today's prep report for this meeting (scheduled `daily-team-prep` / `client-meeting-prep` run, or one made earlier in the session); else the latest one of this meeting type |
| Config | Team tables + Transcript Alias Map, `pm_profile.milestones`, `decision_rights` |
| User | agenda items or goals the user typed in the request |

For a topic call on a subject outside the standard sources (an incident, a contract), build
the brief around the subject the user named, not around the stand-up agenda.

Compress into the **Live Brief**, max ~1500 words, saved next to the transcript as
`<transcript name>.brief.md`:

1. Checklist: what this meeting must cover + "Decisions to obtain".
2. Topic map: topic -> keywords (in every language of `langs`) and Jira keys -> 1-line status.
3. Commitments in flight: who promised what by when.
4. Red lines: decided items not to reopen, out-of-scope areas, decision rights.
5. Names and aliases (how Whisper may spell people), including the PM's own
   `settings.user.name_aliases`.
6. **My update**: the speech from Step 2a, kept in the file so it survives a long session,
   with a ready opening sentence. This is what "Your turn" tips reuse, so they are instant.
7. **Insight Bank**: the list above, so a long session keeps it after context is trimmed.

**Instant cards (`<transcript name>.cards.json`).** Written together with the brief (by the
sweep subagent, or by the main session when there is no subagent), and refreshed after a
context refresh. The recorder matches every new transcript line against them locally and
shows a card in the window within ~1-2 s, with no model in the loop; the skill then only
adds what the card does not cover. A JSON list of 15-40 cards:
`{"id": "new-request", "triggers": ["could you also", "can we add", "можна ще", "а давайте ще"], "on": "them", "level": "red", "gist": "🔴 Нова вимога. Не погоджуй зараз.", "phrase": "Good idea. I will write it down. We will check it and come back to you.", "note": "", "cooldown_s": 300}`
- `triggers`: lowercase phrases in EVERY language of `langs` (plain substring of the line,
  punctuation ignored) or a regex after `re:`. Use distinctive words: names, product and
  module names, competitor and tool names, ticket topics, "deadline", "price", "budget",
  "could you also"; never a common word alone ("so", "ok", "так").
- `on`: `them` (default for requests and questions), `me` (the PM's own risky phrases, e.g.
  a promised date), `any`.
- What to turn into cards: the PM's name aliases with an update request ("Your turn" with
  the speech theses), new-request phrases, commitment phrases ("we will deliver by"),
  each open topic and decision of the brief (the fact with its number and source), red
  lines, competitor or option facts from the Insight Bank, for interviews the Answer Bank
  (trigger = the topic words of each likely question).
- Same tip format rules (short gist, ready phrase in the call language, no abbreviations).
- The prep ahead saves `prep-...cards.json` next to the prep brief; at the start copy it to
  `<transcript name>.cards.json`.
- `@@CARD [time] id: line` lines in the `read_delta` output tell which cards fired. Count
  them in state (`cards_fired`); do not repeat a card's content as a tip; follow up only with
  what the card could not know (the exact question, a newer fact). A card the PM rates ✕
  (`@@SET tip_feedback=not_useful|<id>|...`) gets `"off": true` in the cards file
  (read-modify-write in the next poll call).

Show the user only the checklist (max 6 short lines, no abbreviations, ~45 characters per
line, via `SendUserMessage`) and `Підкажу, коли буде що додати.`

**If the PM opens the meeting** (the PM hosts it, the user says so, or the first 30 s of the
call are silent on the other side): right after the speech post the "Your turn" tip
(see Tip format) as an opening: greeting plus the goal of the meeting in one sentence, then
the agenda order, or the speech if the meeting starts with it.

## Step 3 - Live loop

State file `<transcript name>.state.json` next to the transcript: `offset` (bytes read),
`covered`, `tips_given`, `answers`, `action_items`, `cr_candidates`, `side_talk`, `last_tip_at`,
`last_comment_at`, `theses_used` (which speech theses the PM has already said),
`started_at` and `timezone` (from `status.json`: start time with the Mac's UTC offset and the Mac's IANA zone). Long state lives there, not in the conversation.
`read_delta.py` itself keeps the mechanical keys of this file current on every poll
(`offset`, `inbox_offset`, `polls`, `last_poll_at`, `max_gap_s`, `stalls_over_60s`), so the
file always exists; this skill adds and updates its own keys with a read-modify-write and
never drops the others. It also appends one line per poll to `<transcript name>.polls.jsonl`
(`think_gap_s`, `waited_s`, `emitted`), and the recorder appends one line per transcript line
to `<transcript name>.timing.jsonl`: both feed the latency analysis (see SPEED). Write the brief file in Step 2 (or let the subagent write it)
BEFORE the first tip; if it is missing at the first poll after the sweep, write it then.

Each iteration is ONE device_bash call that first writes any pending tips into the tips
window and then long-polls for new transcript lines and for questions typed in the window:

```
python3 <tool_root>/bin/read_delta.py "<transcript>" <offset> \
  --wait 25 --settle 2 --status <tool_root>/state/status.json \
  --tips "<tips_file>" --inbox "<inbox_file>" --inbox-offset <inbox_offset> --emit-stdin <<'EOF'
<zero or more tip JSON lines, one per line>
EOF
```

Drop `--emit-stdin` and the heredoc when there is nothing to emit, and drop `--tips`,
`--inbox`, `--inbox-offset` when `settings.tips.output` is `chat`. It returns as soon as new
transcript lines or new window questions exist (plus 2 s to collect a burst), or after 25 s
with nothing. Output: the new lines, `@@ASK [time] <text>` per new window question,
`@@SET <key>=<value>` per setting changed with a window button, `@@OFFSET <n>`, `@@INBOX_OFFSET <n>`, `@@EMITTED <n>` (an `@@EMIT_ERROR` line means a tip
was not valid JSON: fix and re-emit it) and `@@STATUS <state> lines=.. queue=.. mic=..
system=.. errors=.. err=<first error>` and `@@NOW HH:MM:SS` (the Mac time of this poll).
Emitted tips get an `at` field (the Mac time they landed in the window). An `errors` value
clears by itself once a restarted audio source delivers audio again (the recorder logs
"recovered after restart"); warn only while it stays. No sleep calls are needed.

**The loop never stops by itself.** After every poll the next action is the next poll (or a
tip emit combined with the next poll). Do not write a text answer between polls. If many
iterations pass with no tip and the user has not heard from you for about 5 minutes, send one
short line with `SendUserMessage` (what is being discussed and why no tips, for example
"слухаю, розмова поза чеклістом") and poll again in the same step. Not more often than every
5 minutes.

### Tips window (settings.tips.output)

- `window`: tips go only to the window; the chat gets the start message, health warnings
  and the wrap-up. `both` (default): window and chat. `chat`: no window, as before. A missing
  `tips.output` (older settings.yaml) means `both`.
- One tip = one JSON line (UTF-8, `ensure_ascii` not needed):
  `{"t":"HH:MM:SS","kind":"tip","level":"red","gist":"🔴 Нова вимога. Не погоджуй зараз.","phrase":"Good idea. I will write it down.","items":["..."],"note":"рішення від 30.09"}`
  - `kind`: `tip` | `answer` (reply to a window question, add `"q":"<the question>"`) |
    `checklist` | `speech` (the PM's theses, Step 2a; `phrase` = the opening sentence,
    `items` = the theses, group names go in the items as plain lines) | `status` | `wrapup` |
    `agenda` (see below); the recorder itself writes `card` items (instant cards);
  - **`src` is required on every tip and answer**: the `HH:MM:SS` of the transcript line that
    triggered it (for an answer: the time of the question). `read_delta` stamps `at` (when it
    landed); the window shows the difference on the card ("+18s", orange over 20 s) and a
    rolling median in the status line. The wrap-up and the hiring analysis report the
    median and max of `at - src`.
  - `level`: `red` | `orange` | `info`; `gist` keeps its emoji;
  - `phrase` without quotes (the window adds them), `items` for numbered points, `note`
    for the source; omit empty fields. The same "Tip format" rules apply.
- **Agenda strip** (`kind: agenda`): `{"kind":"agenda","gist":"<title>","items":[{"text":"Release date","done":true},{"text":"New export request","done":false}]}`.
  Emit it once the checklist is known (Step 2: the checklist; hiring: the planned or likely
  questions; standup you lead: the people to hear from) and again, whole, each time an item
  becomes covered. Max 8 items, ~30 characters each. It replaces the previous strip.
- **Quick asks** (window buttons) arrive as `@@ASK`: `catch me up` -> `kind: answer`, 3-5 lines
  on the last ~5 minutes (who said what, what is open); `what was decided` -> decisions and
  action items so far with owner and date ("не зафіксовано" where missing); `what to ask
  now` -> 1-2 ready questions for the open points; `suggest a reply` -> what the PM can say
  right now on the topic being discussed (the last ~2 minutes), even with no direct
  question yet: a 🟠 `answer` with gist "Можеш сказати: {тема}" and 1-2 ready phrases in
  `answer_lang`, each a different move (an answer to the question that is coming, a fact
  from the Insight Bank or a card with its number and source, a clarifying question, a next
  step with an owner); never a date, estimate or scope commitment; if the topic is not
  clear from the tail, say what was heard and give the most useful generic move. Answer from the transcript tail and state
  only, no lookups, in the next poll call (target under 10 s).
- **Tip rating** (✓ / ✕ on a card) arrives as `@@SET tip_feedback=used|<card id>|<t>|<gist>`
  or `not_useful|...`. Log it in state (`feedback`); after 2 ✕ on the same kind of tip,
  send that kind less often for the rest of the call. The wrap-up lists counts: shown,
  rated ✓, rated ✕, cards fired.
- **Talk meter** (status `talk_me_pct`, `monologue_s`, also in `@@STATUS` as `talk_me=`,
  `mono=`): the window shows it to the PM. Tip only on a client call or when the PM leads,
  when the PM's monologue passes ~2 minutes and a question from the other side is waiting:
  🟠 "Дай слово: {хто / питання}". Never in an interview where the PM is the candidate.
- `@@ASK` lines are the PM's questions or comments typed in the window: treat them exactly
  like chat messages during the loop (answer first, briefly), and send the answer back to
  the window as `kind: answer` (and to the chat too in `both`). "стоп" typed in the window
  stops the call like in the chat. "онови спіч" regenerates the speech (Step 2a).
- Keep `inbox_offset` in state next to `offset`.
- Window buttons. `💬` sets how often comment moments may fire for this call: it arrives as
  `@@SET comment_rate_seconds=N` (also once at the start when the PM's last choice is not
  the default); store it in state, it overrides `settings.tips.comment_rate_seconds`, `0` = comment
  moments off. No chat reply needed. `🎙` is the mic mute: the PM is muted in the meeting
  (cafe, music, people around), so the recorder stops transcribing the mic. `@@STATUS` shows
  `mic=muted`, and the transcript gets `--- мікрофон вимкнено HH:MM:SS ---` and
  `--- мікрофон увімкнено HH:MM:SS ---` lines. While muted: expect no `{me_label}` lines,
  skip the answer check for that time and the `mic=silent` warning; other tips go on. A 🔴
  "Your turn" while muted starts the gist with "Увімкни мікрофон." Treat a `{me_label}`
  line right after an unmute as a normal reply.
- The window UI is in English. The gear button opens the setup row (it opens by itself
  after a fast start): **Meeting** = `Internal standup` (`status`), `Client meeting` (`client`),
  `Working session` (`topic`), `Job interview` (`hiring`); **My role** = `Observer`,
  `Candidate (me)`, `Interviewer (me)`; **Language** = `Ukrainian` | `English` | `Mixed`;
  **Mic** = `System default` | `Mac built-in`. Changes arrive as `@@SET call_type=`,
  `@@SET hiring_role=`, `@@SET call_lang=` (`uk` | `en` | `mix`) and `@@SET mic_device=`
  (`default` | `builtin`). **Ack every setting**: the window shows a pending pill until the
  setting is confirmed. `call_lang` and `mic_device` are confirmed by the recorder through
  the status echo. For `call_type`, `hiring_role` and `comment_rate_seconds` (applied by
  you) emit in the VERY NEXT call, before any heavy work, a tip line
  `{"kind":"ack","key":"<key>","value":"<value>"}` (the window consumes it without a
  card; without it the pill ends in a warning after 30 s). The recorder applies language and mic itself (the mic restarts
  on the new input in about a second; a `--- мова ---` / `--- мікрофон ---` line marks it).
  This skill then updates `answer_lang`, the call kind and the prep; when the language
  changes and a speech was already emitted, re-emit the speech in the new language.
  `ⓘ` shows a help panel about every button and option. 🔄 sends `refresh context`.
  The status line is at the bottom, under the input field; its red warning asks the PM to
  write "continue" in the chat: treat "continue" like "продовжуй".
- The window may be closed or minimised by the PM; keep emitting, it does not matter.
- Reopen on request ("відкрий суфлер", "поверни вікно", "open the prompter"): `touch
  <tool_root>/control/prompter`. The recorder reopens the window within a second with all
  tips so far. Answer in the chat with `SendUserMessage`: `Суфлер відкрито знову.`

Then:

1. Store the new offset. Never re-read older lines; keep the last 3 lines as tail context.
2. Speakers: `{me_label}` = the PM (mic), `{them_label}` = everyone else (system audio). The
   language tag `(xx)` is per line. If the mic also picks up the other side (speakers, no
   headset), `{me_label}` lines may duplicate `{them_label}` lines or be Whisper noise like
   "Звучить музика": treat them as artefacts.
3. Match the new lines against the speech, the Live Brief, the Insight Bank and the triggers
   below, by meaning, across languages (a Spanish line can match a Ukrainian/English topic).
   Never react to Whisper artefacts that slipped through the filters (subtitle credits, a list of
   names repeated, one word repeated many times, "Звучить музика", short "Thanks" or "Mm-hmm"
   in a language the PM does not use): skip them silently. Whisper garbles product names
   (an unknown name may be a known tool): match against the Insight Bank before judging, and
   mark uncertain tips "(?)".
4. Mark in `theses_used` every speech thesis the PM has already said (by meaning, from the
   `{me_label}` lines). The speech tips only offer what is not used yet.
5. Deep lookup (Jira ticket, Notion page, a project document not yet in the Insight Bank) only
   when a trigger fires and the Insight Bank does not answer it. Max one per 2 min.
6. Post a tip if the rate rules allow: emit it to the window in the next read call and/or
   send it with `SendUserMessage`, per `settings.tips.output`. Otherwise produce no text and
   go straight to the next read.
7. Health from `@@STATUS`: `system=silent` for 2 polls while the call is on -> one message
   "Не чую співрозмовників: перевір дозвіл на запис системного звуку для Terminal";
   `mic=silent` likewise (never for `mic=muted`, never in hiring `observer`); `queue` > 6 -> "Транскрипція відстає на ~{queue} фраз";
   `errors>0` -> tail of `logs/transcriber.log`. Each warning once.
  Garbled transcript: if 3+ system lines in a row are nonsense or gibberish in the wrong
  language, warn within the first minute (wrong Whisper language or prompt) and restart the
  recording with the correct language and a prompt in that language (tell the PM what was lost).

### Language of the moment

The call language can change mid-call, mostly on internal calls (Ukrainian and English). Keep `answer_lang` in state = the language the PM is expected to
speak right now; every phrase in a tip goes in `answer_lang`, the gist line always stays
in `{settings.user.tips_language}`.

- Start: `answer_lang = me_lang`.
- Switch when someone asks the PM to say or explain something in another language
  ("розкажи це англійською", "скажи по-английски", "can you say it in English", "for Mark
  in English please"), or when a question to the PM comes in a language of `me_langs` other
  than the current one (e.g. an English-speaking guest asks in English). Post at once a
  🟠 tip: gist in Ukrainian with what to say, phrase in the new language:
  > **🟠 Тепер англійською: статус релізу**
  > "Short update in English. The release is on track for Friday."
- Switch back when the PM's own lines return to the main language for 2+ lines, or the
  request is clearly answered.
- Russian is never used: drop `ru` from every language set read from `settings.yaml` or
  the project config before writing `start.json`. A Russian phrase is written as Ukrainian.

### Active mode (default)

On by default; `settings.tips.active_mode: false` returns to the quiet style. The goal: the
PM should rarely sit through a minute of other people talking without a useful thing to add.
In active mode:

- The 🟠 rate is `tips.active_rate_seconds` (missing = 40) instead of `tips.rate_seconds`,
  and the comment rate is `tips.comment_rate_seconds` (missing = 20). The window button
  still overrides the comment rate.
- A comment moment fires on a complete thought even without a long pause, as long as the
  PM is not speaking right now (no `{me_label}` line in the last ~5 s).
- Initiative tips (below) are allowed on top of the triggers table, but at most one
  initiative or comment tip per comment rate period, and never while the PM is speaking.
- Quality over volume: every tip carries a concrete project fact from the Insight Bank, a
  concrete question or a concrete next step. Generic praise or "good point" tips are never sent.

### Triggers

| Level | Trigger | Tip |
|---|---|---|
| 🔴 | Your turn: `{them_label}` addresses the PM by any of `settings.user.name_aliases` (any grammatical form, e.g. vocative "Іване", or a misspelling) with a request for an update or opinion ("розкажи", "що в тебе", "які апдейти", "покажи", "your updates", "over to you", "what about you"), or the round of updates reaches the PM (the previous person finished and the next name is not yet said, or the PM is last), or the meeting starts with a status round | "Your turn" tip from the speech: opening sentence + the theses not used yet, in order. Immediate, ignores the rate limit |
| 🔴 | `{them_label}` asks for something new, "could you also", "can we add", a change in behaviour or scope | "Нова вимога. Не погоджуй зараз." + phrase, e.g. "Good idea. I will write it down. We will check it and come back to you." |
| 🔴 | `{me_label}` commits a date or an estimate | compare with milestones / tracker; "Оцінку дає виконавець. Не називай цифру." + phrase |
| 🔴 | A statement contradicts a Decision or red line | "Суперечить рішенню {дата}" + the decision in a few words |
| 🔴 | Frustration, escalation, "disappointed", "again", threat to timeline or contract | "Клієнт незадоволений: {що саме}" + phrase that acknowledges, gives a plan and the date of the next update |
| 🔴 | Answer check: `{me_label}` states a fact that contradicts the Insight Bank, brief, tracker or a Decision (wrong status, date, owner, scope, price, limit) | "Неточно: {Y}, не {X}" + correction phrase + source |
| 🟠 | Answer check: `{me_label}` answered, but not the question that was asked, or only part of it | "Питали про {що}, не про {інше}" + short phrase to close it |
| 🟠 | Answer check: `{me_label}` answered vaguely where the other side wanted a concrete thing (date, owner, yes/no) | "Розмито. Дай {дату / власника / так-ні}" + phrase |
| 🟠 | Side talk: 2+ consecutive `{them_label}` lines in a language the PM does not use on this call (not in `me_langs`), e.g. `es` while the call is `en` | "Між собою іспанською" + the gist in 1-2 lines. Skip small talk. |
| 🟠 | Comment moment: `{them_label}` finished a complete thought on a work topic and the PM has not reacted yet (see "Comment moments") | "Можеш додати: {тема}" + 1-2 ready phrases built from Insight Bank facts. Own rate `tips.comment_rate_seconds` |
| 🟠 | A topic from the speech, the brief or the Insight Bank comes up and the thesis is not used yet | "Додай: {тема}" + the thesis as a ready phrase + up to 3 facts with numbers |
| 🟠 | A question to the PM stays unanswered for ~2 min | "Без відповіді: {питання}" + phrase |
| 🟠 | The PM is asking (questioning stretch): an answer opens a follow-up worth asking, or a planned question is skipped | "Уточни: {що}" + the question as a ready phrase |
| 🟠 | Initiative: the PM has been silent for ~60 s while others discuss a topic where the PM has a fact, a risk or a question (see "Initiative tips") | "Можеш вставити: {тема}" + 1-2 ready phrases |
| 🟠 | Initiative: the conversation drifted for ~4 min away from the checklist and a checklist item is still open | "Поверни до: {пункт}" + a ready phrase that steers back politely |
| 🟠 | Initiative: a decision, owner or date was discussed but not fixed | "Зафіксуй: {що}" + a ready phrase ("So, {owner} will {action}. Is that right?") without naming a number for estimates |
| 🟠 | At 2/3 of the meeting length | uncovered checklist items (including the PM's planned questions not asked yet) and speech theses not used yet |
| 🟠 | 5 min before the end | "Decisions to obtain" not obtained yet, theses not said yet |
| silent | Action item (who / what / when), new request, commitment | log to state, show in the wrap-up |

### Comment moments (do not wait for a direct question)

Only when `tips.comment_prompts` is true (missing = true; missing `tips.comment_rate_seconds` = 20 in active mode, 45 otherwise; the `💬` window button overrides the rate for the call, `0` = off). On calls people rarely ask the PM directly. More
often someone finishes a thought and expects a reaction: an idea, a finding, a plan, a
worry, a summary ("ну от якось так", "що думаєте?", "виглядає валідно", "make sense?",
a pause after a long monologue). Treat such a moment as an implicit question to the PM.

It is a comment moment when all three hold:
1. `{them_label}` said 2+ lines (or one long line) on one work topic and the batch ended
   (read_delta returns after a pause, so a returned batch usually means a pause);
2. the thought is complete: a conclusion, proposal, finding, plan, worry, a question to the
   whole team, or a turn-yielding cue. Not the middle of a story, not small talk, not a joke;
3. the PM has not reacted to it in the new lines.

Then emit a 🟠 tip "Можеш додати: {тема}" with 1-2 ready phrases in `answer_lang`, each a
different useful move: a concrete fact from the Insight Bank that confirms, corrects or
extends what was said (with the number and the source in `note`); a clarifying
question that moves the work forward; a concrete next step with an owner; a risk or
dependency the speaker missed. Project facts beat generic praise. Never a phrase that
commits a date, estimate or scope (the commitment trigger still applies). If the PM reacts
before the tip lands, drop it. One comment tip per topic. If the Insight Bank has nothing
on the topic, send no tip rather than a generic one.

> **🟠 Можеш додати: порівняння цін**
> "Згоден. Пропоную таблицю: продукт, функції, ціна, ліміти."
> "Хто з нас збирає дані по двох конкурентах?"

### Initiative tips

These keep the PM an active participant, not a listener. Use them in active mode, with the
rate rules below.

- **Add a fact or a risk.** Others discuss a topic from the brief and miss something the
  brief or the Insight Bank knows: a blocker, a dependency, a past decision, a deadline, a
  price, a limit, a ticket status. Offer it as a short phrase the PM can say.
- **Ask a question.** Offer one sharp question that unblocks the work: who owns it, what is
  the date, what is the dependency, what happens if it slips.
- **Fix the outcome.** When a topic ends without an owner, a date or a yes/no, offer the
  closing phrase ("So Ivan checks the config today. Right?").
- **Steer back.** When the talk drifts and an open checklist item or a "Decision to obtain"
  remains, offer a polite steer back.
- **Use the speech.** If a speech thesis fits the current topic, offer the exact phrase for it.

Do not use initiative tips for: sensitive or legal discussions where the PM is clearly
thinking aloud with the team (an incident post-mortem, a contract position) unless the PM
asks; moments when the PM is speaking; small talk.

### When the PM asks (questioning stretches inside any call)

Not a separate call type: any work call can switch between the PM asking and the PM being
asked, several times (the PM clarifies requirements, then the client asks technical
questions back). Detect it by the lines, not by the call type: a stretch where `{me_label}`
asks questions and `{them_label}` answers is a questioning stretch; it ends when the
questions come from the other side again, and the normal triggers apply then. If the PM
listed questions to ask (the request, the session, a prep), they are part of the checklist.
During a questioning stretch: track each planned question in state as `asked`,
`answered`, `partial` or `not asked`, with a one-line answer summary. Tips focus on gaps:
a vague or partial answer ("Уточни: ..."), a contradiction with what is known, a new topic
worth a follow-up, planned questions left near the end. The wrap-up adds "Відповіді на мої питання":
question -> answer in one line -> status.

### Hiring interview mode

Call kind `hiring` (Step 0). The goal is different from a work call: no project status, no
scope, no commitments. Tips are about the questions asked and the answers given.

**What is off in hiring mode:** the speech (status) and "Your turn" from the speech, comment
moments, initiative tips, the new-request, commitment, frustration and contradiction
triggers, the answer check of the PM's own replies (except in the `candidate` role, below),
the 2/3 and 5-minute checklist triggers (except `interviewer`). Side talk in another
language stays on. The Insight Bank sweep of project documents is skipped unless the
position belongs to the PM's own project (then only Team tables, stack and the open roles).

**Speakers.** `{me_label}` = the PM's mic, `{them_label}` = everyone else in ONE channel: the
interviewer(s), the candidate and any colleague are not separated in the transcript. Tell them
apart by content: who asks (short questions, "tell me about", "how would you") and who answers
(long first-person replies, "I", "in my last project"). Use names said aloud (introductions)
and keep them in state. If unsure who spoke, mark the tip "(?)".

**State.** `hiring`: `role`, `position`, `candidate` (first name only), `questions`: a list of
`{q_at, topic, question, answer_summary, verdict, tip_at}` where `q_at` = the transcript time
of the question line and `tip_at` = the `at` time that read_delta stamps on the emitted tip
(or `@@NOW` of that call). They feed the latency line in the analysis.

**Prep (Step 2a for hiring, target: in the window within ~40 s).**
- `observer`: emit `kind: speech` "🟢 Співбесіда: {position}" with 6-10 likely topics for
  the position in the order they usually come (for QA automation, as an example: test
  design and techniques, API testing, automation framework and language, CI and reports,
  flaky tests, bug life cycle and severity, test strategy for a new feature, SQL, mobile or
  web specifics, behavioural questions). No status, no project facts. Then, silently, write into the brief a full-depth reference answer
  (4-5 sentences) for each of those topics (see SPEED, rule 6).
- `candidate`: the prep is done by the **candidate prep subagent** (see "Context sweep"
  for how subagents are used) with this brief, everything from `settings.hiring.candidate`:
  1. The Job Tracker row of the company (match `Company` / `Vacancy`, newest if several):
     `Vacancy`, `Role type`, `Status`, `Stage #`, `Stages log`, `Next step on`, `Notes`,
     `Feedback`, `Salary range`, `Що ми знаємо про компанію`, `Recruiter contact`, the page
     body and the job post at `Vacancy URL` if reachable.
  2. Prep pages for this company under the RECAP page (`recap_page`, titles like
     "Підготовка до співбесіди: {company}"), and the Truth Bank (`truth_bank_page`): the
     ONLY allowed source of facts about the PM (numbers, projects, dates).
  3. A short web check of the company (max ~5 searches): product, size, market, funding or
     news of the last 6 months, who the interviewers are if their names are known.
  4. **Stage** of this interview: from the user's words, else from `Status`, `Stages log`
     and `Next step on` (recruiter screen, technical or PM case, final with management,
     client interview). If unclear, say "етап не визначено" and prep for both likely ones.
  The subagent writes `<transcript name>.brief.md` (company card, stage, Answer Bank,
  "Розкажи про себе", questions to ask them, red lines: salary floor and notice period only
  if the hub states them) and returns the compact part: stage, the "Розкажи про себе" item,
  the 6 most likely questions, 3 questions to ask them. Main session emits them.
  The **Answer Bank**: 10-20 likely questions for THIS stage -> a ready answer of 2-3
  sentences + up to 3 facts (project, numbers, result) ONLY from the Truth Bank, the CV and
  the PM Profile. Never invent experience, dates or numbers: a generic answer is marked
  "(загальна)". By stage: screening = motivation, why leaving, expectations, availability,
  English, short self-intro; technical / case = delivery process, estimates and risks,
  metrics, conflicts with clients, a failed project, tools, AI in PM work; final = leadership,
  stakeholder management, decision making, culture, questions to them.
  **First item, right at the start: "Розкажи про себе".** Emit it before anything else as
  `kind: speech`, gist "🟢 Про себе", in the interview language: an opening sentence as
  `phrase` and 6-8 short lines as `items` (current role, years and domain, 2-3 projects with
  one result each, what the PM is looking for and why this role), about 60-90 s when said
  aloud. It stays on top of the window so the PM is calm from the first minute. Then emit
  the 5 next most likely questions as a second prep item.
- `interviewer`: the planned questions (from the user's words, the session or a prep) as the
  checklist; if none, propose 8-10 for the position and the level and emit them, marked
  "запропоновані".

**Live tips by role.** Hiring tips ignore the 🟠 rate limit for the items below (max 2 per
poll); speed matters more than batching. Never deep lookups during an answer.
- `observer` (the PM is silent). NO answer analysis during the call, it comes only after stop:
  1. A question to the candidate -> at once ONE 🟠 tip: `gist` = the interviewer's question
     VERBATIM (merge the interviewer's rephrasings and follow-ups into one question), `phrase`
     = a reference answer of 4-5 sentences in the interview language. Note: "для порівняння,
     не для озвучення". It is a benchmark for the PM to compare with what the candidate
     really says, not a script for the candidate. For this tip the usual gist limits (7 words,
     45 characters) and the 5-line limit do not apply.
  2. After the answer: nothing. No ✓ / ~ / ✗ lines, no gap remarks, no commentary on what the
     candidate said. Keep notes silently for the final analysis.
  3. No tips on small talk, introductions or company pitches; one 🔵 line at most when the
     client describes the project, the team or the process (useful for the analysis).
- `candidate` (the PM answers):
  0. Small talk is not idle: the interview often starts with it and questions grow out of it
     ("so where are you based?", "how is the weather in Ukraine?", "what are you working on
     these days?", "how long have you been at your company?"). Treat any question to the PM
     in small talk as a real question: a short friendly ready answer (1 sentence) that may
     lead into a strength from the Answer Bank. When the interviewer moves to "tell me about
     yourself", the 🟢 item is already in the window: re-emit it as 🔴 only if it scrolled away.
  1. A question to the PM -> 🔴 at once "🎯 {тема}" + `phrase`: a ready answer of 2-3
     sentences in the interview language from the Answer Bank (the closest question), + up to
     3 `items` with facts. If the Answer Bank has nothing, a short honest structure
     (situation, action, result) with "(загальна)", never invented facts.
  2. The answer check runs on the PM's reply: a missed part of the question -> 🟠 "Питали ще
     про {що}" + one sentence to add. No comments on tone or confidence.
  3. Salary, notice period, start date, other offers: 🔴 "Без цифр зараз" + a neutral phrase
     unless the PM's sources give a number to use.
- `interviewer` (the PM asks):
  1. After each answer: a weak, vague or partial answer -> 🟠 "Уточни: {що}" + the follow-up
     question as `phrase`; a strong one -> nothing, or the next planned question as an
     `info` line.
  2. A claim worth checking (a tool, a number, a role) -> one probing question.
  3. At 2/3 of the length: planned questions not asked yet.

**Analysis (Step 4 for hiring).** Written in Ukrainian into the chat AND saved next to the
transcript as `<transcript name>.analysis.md`. Judge the content of the answers and the
communication clarity, never personality, appearance, accent, age, health or other personal
traits. Sections:
1. **Підсумок**: one paragraph, how it went and the likely outcome for the client (or for the
   PM in `candidate`), with confidence (висока / середня / низька) and why.
2. **Питання і відповіді**: table: питання (тема) | що відповів | оцінка (сильна /
   прийнятна / слабка / не почули) | чого бракувало для сильної відповіді.
3. **Сильні сторони** and **Прогалини і ризики**: 2-5 items each, every one with a quote or
   a time from the transcript.
4. **Сигнали з боку того, хто питав**: depth of follow-ups, topics they returned to, what
   they explained about the project, the next step they named.
5. **Рекомендації**: `observer`: what to tell the candidate before the next round and
   whether to put them forward again; `candidate`: what to prepare for the next round;
   `interviewer`: hire / no hire / one more round, with evidence.
6. **Рішення на місці клієнта** (`observer` and `interviewer`): a verdict (hire / скоріше так /
   скоріше ні / no hire / one more round), 3-5 reasons each with a time or quote, what would
   flip the decision, and the limitations (one audio channel, ASR errors, one round only).
7. **Питання і відповіді дослівно**: the full list, see Step 5 for the format.
8. **Як працював суфлер**: questions caught N of M; median and max delay from the question
   to the tip (`tip_at - q_at`); how many tips landed before the answer started; what was
   missed (transcript gaps, mixed speakers); loop stalls (`max_gap_s` and `stalls_over_60s` from the state file; gaps between polls over 60 s, from
   state).
   **Затримка за етапами** (from `.timing.jsonl` and `.polls.jsonl`, computed with a script,
   median and max): end of the question -> line written (`queued_s` + `asr_s` + segment end
   silence), line written -> poll returned (settle), poll returned -> tip emitted (my thinking:
   `think_gap_s` of the next poll), and the biggest single loss with its time. Give one line
   with the stage that costs the most and one concrete fix. **Модель**: name the session model (from the system prompt) and say whether it
   was enough: if delays were long but tips good, a faster model or lower effort would help;
   if tips were late AND shallow or wrong on technical questions, a stronger model (Opus
   class) is worth the extra delay; give the verdict in one line with the evidence.
The Step 4 work-call template (action items, new requests, theses) is replaced by this; add
action items only if someone named a next step.

**Step 5 for hiring.** `observer` and `interviewer`: the Meetings DB page follows the Step 5
destination rule (an existing Notion AI page of this interview first, a new page only if
none; a new one gets the title "Співбесіда {position} {candidate first name}", transcript, a 2-3 line
summary) and the FULL analysis goes into it right away as the "Підсумок" section (the PM's
Notion is internal and confidential; nothing in it is ever sent to anyone). The page also gets
`## Рішення на місці клієнта` and `## Питання і відповіді дослівно`: every question and the
candidate's answer VERBATIM as plain paragraphs, "Question: ..." then "Answer: ...", in call
order. Build the list with a script from the transcript (the lines are often one channel:
merge consecutive lines of one speaker, attribute by content, merge rephrased questions into
the question, keep ASR errors as they are, add one caveat line about that), save it locally as
`<transcript name>.qa.md`, and append to Notion in chunks if it is too large. The `candidate`
branch below gets the same two sections in the Job Tracker row page.
`candidate`: no Meetings DB page. Write into the company's Job Tracker row page: append a
section `## Співбесіда {YYYY-MM-DD}: {stage}` with the full analysis, plus the transcript in a
toggle "Транскрипт"; append one line to `Stages log` ("N. YYYY-MM-DD {stage} - очікуємо
результат", N = `Stage #` + 1) and set `Stage #` to N. `Status`, `Last response` and
`Next step on` change only on the PM's word. If no row exists, create one with `Company`,
`Vacancy`, `Status` = `Interview`, then write as above. The candidate analysis adds a
**Ретро** block: the weakest answer, where the PM spoke too long, the question that
surprised, what to add to the Truth Bank or the recap, what to prepare for the next stage.
The local `.analysis.md` stays too in every role.

### Answer check (the PM's own replies)

Only when `tips.answer_check: true`. The side-talk trigger only when
`tips.side_talk_summary: true`.

Track question -> answer pairs: a question from `{them_label}` (explicit "?" or an
implied request) and the next `{me_label}` lines up to the next question or ~90 s. For each pair
judge three things against the brief, the Insight Bank and the tracker:

1. Relevance: did the answer address what was asked, all parts of it?
2. Accuracy: are the facts right (status, dates, owners, scope, decisions, prices, limits)?
3. Commitment: did it promise a date, estimate, scope or money that the PM does not own
   (`decision_rights`)?

Good answers produce no tip. Log every pair with a verdict in state (`answers`) and list
the weak ones in the wrap-up under "Відповіді, до яких варто повернутись". Judge the
content, not the person: no comments on tone, confidence or emotions.

Whisper can still garble words or misspell names: judge by meaning, mark
an uncertain tip "(?)", never quote a garbled line as fact.

### Rate rules

- 🔴 immediately.
- 🟠 / 🔵 max one message per `tips.rate_seconds` (in active mode per `tips.active_rate_seconds`, default 40); batch several into one message.
- Comment and initiative moments share their own limit: max one per `tips.comment_rate_seconds`.
- One tip = the block from "Tip format". Max 2 tips per message, separated by an empty line.
- Never repeat a tip already in `tips_given` unless the situation changed.
- Never send a tip while the PM is speaking (a `{me_label}` line in the last ~5 s), except 🔴.

### Tip format (small window under the camera)

The PM keeps the Cowork window small, at the top centre of the screen under the camera, and
reads tips with a glance while talking. Every tip is built for that:

1. **Gist line**, bold: emoji + what is happening, in `{settings.user.tips_language}`, max
   7 words. Always first, so the PM understands the point in one second.
2. **Phrase to say**, in quotes, in `answer_lang` (see "Language of the moment"). A ready speech the PM can read
   aloud as is, not theses. 1-2 sentences.
   - English: simple sentences, max 12 words each, everyday words, present or future
     simple, active voice. No idioms, no long subordinate clauses, no rare phrasal verbs.
     "We will check it and come back to you on Friday." Not "Let me circle back once we've
     had a chance to scope it out."
   - Ukrainian or another call language: the same rules, in that language.
   - No phrase when there is nothing to say (pure status or a side-talk summary).
3. **Facts** (status, side-talk and insight tips): max 3 short lines, max 8 words each, with
   numbers, in the language of the call for status (so they can be read out), in
   `{settings.user.tips_language}` for side talk.
4. **Source** (insight tips and 🔴 contradictions and inaccuracies): one short italic or `note`
   line with the document and date, e.g. `_ліміти, 14.10_`.

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

> **🟠 Зафіксуй: хто і коли**
> "So Ivan checks the config today. Is that right?"

Internal Ukrainian call: the gist and the phrase are both in Ukrainian.

**Speech item** (`kind: speech`, the only item allowed up to 12 lines): gist line with the
period, the opening sentence, then the theses in short groups. All in the language of the call.

> **🟢 Твій спіч: за 12-13.10**
> "Коротко по Acme: головне майже готове."
> Було
> 1. Закрили звіт по залишках на проді
> 2. Узгодили прапорець по компанії
> Далі
> 3. Деплой у вікно 16:00-18:00
> 4. Тікет на продовження домену
> Потрібне рішення: другий апрув у безпеці дашборду

**"Your turn" tip** (up to 7 lines): gist line, then a ready opening
sentence in quotes, then the theses not used yet in the order to say them, numbered, max 8
words each, all in the language of the call. If the question was about one topic, answer that
topic only, not the whole update, and take the facts for that topic from the Insight Bank.

> **🔴 Твоя черга: апдейт**
> "Коротко по Acme: все за планом, одне питання."
> 1. Звіт по транзакціях на тестуванні
> 2. Оплати: чекаємо відповідь клієнта
> 3. Потрібне рішення: дата релізу

> **🔴 Your turn: update**
> "Short update from my side. We are on track."
> 1. Transaction report is in testing
> 2. Payments: waiting for the client
> 3. We need a decision on the release date

### The PM's questions during the call

If the user writes in chat during the loop, answer first with `SendUserMessage` (short, in the
same tip format, from the brief, the Insight Bank, state and transcript tail; a deep lookup is
allowed), then continue the loop from `offset` in the same step. "продовжуй" or "continue" resumes after an
interruption. A user complaint that tips are silent or generic is a signal to check at once:
is the loop running, is the Insight Bank loaded; fix it and say what was wrong.

**Context refresh during the call** (an unexpected call started without prep, or the talk
moved to something the brief does not cover). Triggers in the chat or the window: "онови
контекст", "refresh context", "підготуй бриф", "глянь мітинги / треди / доки", "що в нас по {тема}", the
window button 🔄 (arrives as `@@ASK [..] refresh context`). Then:
1. `SendUserMessage` / window item: "Оновлюю контекст ({фокус}), 1-3 хв. Запис іде, нічого
   не губиться." Emit pending tips first.
2. Run the sweep subagent (full source list of "Context sweep", or only the focus the PM
   named, plus the topics of the last ~10 minutes of the transcript so the brief matches
   what is being discussed right now). It updates `<transcript name>.brief.md` in place
   (merge, keep the speech and what is still valid) and returns the new and changed
   insights only.
3. One `read_delta` catch-up of everything said meanwhile, then tips that use the new
   insights for the topics still open. Note the refresh time in state (`context_refreshed_at`).
The keepalive hook keeps the turn alive during the subagent. Max one full refresh per 10
minutes; a narrow one ("глянь тред про X") any time.

### How the meeting ends (Stop)

Three ways, all equivalent; the transcript file is closed with a `--- кінець запису HH:MM:SS ---` line:

1. **In chat** (normal way): the user writes "стоп", "все", "кінець", "кінець дзвінка",
   "end live" -> write an empty file `control/stop` (`touch`).
2. **In the "Live transcriber" Terminal window** (it opened by itself at the start): Ctrl+C
   or closing the window -> the next poll returns `@@STATUS stopped`. A backup path.
3. **Automatically**: no new lines for `tips.idle_stop_minutes` after at least 20 lines ->
   ask once with `SendUserMessage` "Дзвінок закінчився? Зупиняю запис через 2 хв", keep polling,
   then write `control/stop`; planned length + 20 min, or `tips.hard_cap_minutes` -> write
   `control/stop`.

Closing the Zoom/Meet window does NOT stop the recording (the tool keeps listening to the
system audio); one of the three ways above must happen. Goodbyes in the transcript are a
signal to tell the PM, never a reason to end the turn.

After writing `control/stop`, poll status until `stopped` (up to 60 s: the tool finishes
the last phrases), read the final delta, then Step 4 and Step 5 without waiting for a command.
If the user's stop message names a Notion page link, that is the destination for Step 5.

## Step 4 - Wrap-up

One short message, Ukrainian, no abbreviations:

```
## Підсумок дзвінка {title}
Джерела: Transcript OK ({N} рядків, {мови}) · Brief OK · Jira {state} · Notion DBs {state}
Action items: ... (хто / що / коли)
Нові вимоги (кандидати на зміну обсягу): ...
Зобов'язання з нашого боку: ...
Відкриті питання: ...
Тези спічу, які не прозвучали: ...
Відповіді, до яких варто повернутись: ... (питання -> що не так -> як закрити)
Підказки: показано {N}, ✓ {N}, ✕ {N}, миттєвих карток {N}; затримка медіана {N} с, макс {N} с
Відповіді на мої питання: ... (якщо я питав: питання -> відповідь -> статус)
Не покрито з чекліста: ...
Транскрипт: {project folder}/live/{file}
Notion: {посилання на сторінку з Step 5}
Далі: звіт по мітингу, change-request, risk-register?
```

For a hiring interview use the "Analysis" of "Hiring interview mode" instead of this template.

The Data Completeness line follows `projects/SKILL.md` (OK / EMPTY / STALE / SKIPPED /
FAILED). Do not run the next skills without the user's command. If the call went to a
different subject than the checklist, say so in one line instead of listing every checklist
item as missed.

With the tips window on, also emit a short `kind: wrapup` item: gist "Дзвінок завершено",
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
     an old zone name Notion may reject: use the current alias then). Missing
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
   spec. Header and footer lines of the transcript file are not copied. Drop pure Whisper
   artefact lines ("Звучить музика", short repeats of the Whisper prompt's opening such as
   "Дзвінок команди ..." with a garbled ending, and similar) and say so in one line with the
   COUNT: "відкинуто {N} з {M} рядків як артефакти". Count with a script, never by eye: a
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

During the call the PM may type notes in the chat or the window that are not questions:
corrections ("тут правильніше було відповісти так"), wishes ("такі підказки не треба",
"давай частіше по цінах"), complaints ("запізно"). Log every such note in state
(`pm_notes`: time, text, the tip or moment it refers to) as it arrives, together with ✓ / ✕
ratings (`feedback`) and loop facts from the state file (`max_gap_s`, `stalls_over_60s`,
median tip delay). After Step 5:
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
   - skill changes: the synced skill files are read-only, so build the complete updated
     SKILL.md (and settings.yaml if needed) from the installed one plus the approved
     changes, keep the rest word for word, check there is no long dash, and offer it with
     the `propose_skills` card tool when the session has it; otherwise package
     `live-tips-<date>.skill` (zip with `live-tips/SKILL.md` and `live-tips/settings.yaml`)
     into `{settings.paths.work_root}/Skills` and say so. Also append each approved change in
     one line to `{settings.paths.work_root}/Skills/live-tips-changelog.md` (create if
     missing) so other sessions see what changed.
   - Nothing is changed without the PM's yes.
3. With no notes, no ratings and no loop problems, skip Step 6 silently.

**Last action before the final text (always, also after a failure in Step 4 or 5):**
read `blocks` from `~/.live-tips/keepalive.json` (missing = 0) and add the line
`Keepalive: хук повернув у цикл {blocks} раз(и)` to the final text (and to "Як працював
суфлер" for hiring), then remove the marker with the cloud `Bash` tool:
`rm -f ~/.live-tips/keepalive.json`.
Otherwise the Stop hook keeps the turn alive until the marker expires.

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

Everything else (speech, brief, triggers, rate rules, wrap-up) is the same, except Step 5: the
Notion meeting page already holds the real transcript, so do not create a second page; write
the "Підсумок (Live Tips)" section into it. Only offer to set its `Project`, `Workspace` and
`Date` if they are empty.