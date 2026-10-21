# live-tips module: Context sweep, Insight Bank, Live Brief, cards, fact book

Part of Step 2b of SKILL.md. Read by the main session before the sweep, and by the sweep
subagent first thing (its brief gives the path of this file). Also read before a context
refresh or before a read-modify-write of the cards or the fact book.

## How the sweep runs (main session and subagent)

**Context budget (why the sweep runs in a subagent).** Everything this session reads stays
in its context for the whole call, and the loop itself adds a little every poll. Raw
documents read at the start can fill the context mid-call; Cowork then compacts the
conversation, which costs tens of seconds without tips and loses detail. So:
- The sweep (this section) and the `candidate` prep run in a **subagent** (the Agent tool,
  general-purpose type) when the session has it. The subagent reads the raw sources in its
  own context, writes the full `<transcript name>.brief.md`, `<transcript name>.cards.json` and
  `<transcript name>.facts.json` (plus `<transcript name>.outline.json` for a presentation) itself (device_bash, the path
  given in its brief) and returns ONLY the compact part: the checklist, the topic map with
  keywords, the Insight Bank (or the Answer Bank), and one line of sources loaded and not
  loaded. Give it everything it needs in its brief: slug, config path, `project_root`
  paths inside device_bash, the meeting type and title, the call languages, the Notion IDs
  from the config (including `notion.current_state_page`), the list below, the output format and size (max ~1200 words returned).
  If a source is not reachable from the subagent (for example the claude.ai Project
  documents), it says so and the main session reads only that source itself.
- The Agent call blocks the loop while it runs (usually 1-3 min), so it is used ONLY for the
  first sweep, before the recording starts or in the first minute. Every lookup after that goes
  through the background research team (Step 3), which does not block. Before the Agent call: emit the speech
  and send `Готую бриф, підказки по фактах з'являться за 1-3 хв.` After it: one
  `read_delta` catch-up of everything said meanwhile, tips only for what is still relevant.
  If the PM starts the skill before the call begins ("дзвінок через 10 хв"), run the
  subagent first and start the recording right after, so nothing is missed.
- No Agent tool: do the sweep inline as before, keep it short, and never read a document
  that is not needed for this call.
- **Prep check (mandatory, measured: on 2026-10-21 two calls ran with no cards and no fact
  book, so the instant layer showed nothing).** Right after the sweep (or a reused prep), in
  the same device_bash call as a poll: `python3 <tool_root>/bin/lt prep-check "<transcript>"
  --adopt-prep`. `verdict: OK` -> go on. `FIX: cards, facts` -> the subagent did not write
  them: write them now from the brief and the Insight Bank (15-40 cards, 40+ facts; formats in
  `references/sweep.md`), then run the check again. Never start the loop proper without them.
- Deep lookups during the call stay small (one page, one ticket); a big one goes to a
  subagent too.
- **After a compaction** (earlier messages replaced by a summary): before the next tip,
  re-read `<transcript name>.brief.md` and `<transcript name>.state.json` and continue from
  `offset`. They hold everything the loop needs.

**Required output of every sweep (no exceptions):** `<transcript name>.brief.md`,
`<transcript name>.cards.json` (15-40 cards) and `<transcript name>.facts.json` (40-200 facts),
plus `<transcript name>.outline.json` for a presentation. The main session verifies them with
`lt prep-check`; a sweep that returns without cards and facts is not finished.

**Local Notion mirror (read before Notion).** For history and context beyond the Current State
page, search the read-only mirror first. It has three levels, search all three with `grep -rl`
(exclude `_archived/`): `{config.local_paths.project_root}/_notion/` (rows linked to this project
only), `<workspace folder>/_notion/` (rows of this workspace without a project or with several
projects) and `{settings.paths.work_root}/_notion/` (rows without a workspace). Databases: meetings,
threads, tasks, reports, risks, decisions, topics, knowledge, inbox, plus `project.md` and
`current-state.md`; `{settings.paths.work_root}/_notion/INDEX.md` lists where every project lives. In a
cloud session reach it through the device bridge (`device_bash`; the same paths start with
`$HOME/mnt/<basename of work_root>/` instead of the work_root path); never grep wider than `_notion/` folders.
First read `MIRROR_STATUS.md` next to INDEX.md: if `last_run_utc` is older than 24 hours, `result`
is not OK, or the Mac is not reachable, skip the mirror and read Notion as before. The mirror is a
snapshot: for anything that may have changed since `last_run_utc` (statuses, new rows) query Notion
with `last_edited_time >= last_run_utc` as the delta. A file with `truncated: true` has blocks the
export could not render; open the page in Notion when the detail matters. Never write to the mirror;
every write goes to Notion. The client's Notion workspace is not mirrored. Rules: `projects/_standards.md` section 12.

**Context sweep (what makes tips specific).** The PM does research in many other chats and
threads. This session cannot see those chats. It only sees what was SAVED: documents of the
claude.ai Project this session is attached to, the project folder on the Mac (`reports/`,
`research/`), Confluence pages, Notion pages. So the sweep (in the subagent) reads those,
newest first:

**Current State first.** Before the items below, read the project's Current State page. The
page ID comes only from `{config.notion.current_state_page}` (never search for it by title;
a multi-project call reads one page per project). Note its `Last updated` date and put its
sections (Now, Blockers & risks, Waiting on us / on them, Decisions, Upcoming, Changes,
Manual notes) into the brief as the baseline. Do not read the child page
`Current State - History` unless the call is about older history. After it, the Notion part
of the sweep (item 3 and the table below) is a **delta only**: Threads, Meetings and
Decisions of this project newer than `Last updated`, plus whatever directly concerns this
call (checklist items, topics, tickets and people the user named, today's prep report);
Topics, Risks and other Reports only when a topic of the call needs them. Items 0, 1, 2 and
3a (lessons, Project documents, Mac folder, topic documents) run as before. For a client
call, risks and notes taken from Current State still pass the `External` / `Both` rule.
Fallback: no `current_state_page` in the config, the page is unreadable, or `Last updated`
is older than 3 days -> say so in the sources line (item 4) as
`Current State: missing | unreadable | stale since YYYY-MM-DD` and run the full sweep below.

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
3. Notion, all scoped to this project (after a fresh Current State only the delta, see
   "Current State first"): Meetings DB (the last 3 meetings of ANY type, plus
   the last 2 of this type: decisions, action items, promises, open questions), Threads DB
   (`Awaiting Reply`, `Need Follow-up`, `AI Review`, and threads updated in the last 7
   days), Topics (open), Decisions (last 30 days), Risks (open), Reports DB (the newest
   report of each type in the last 14 days); Confluence space of the project if the config
   names one (titles of pages changed in the last 7 days, then the relevant ones).
   The same full list is used by a prep ahead ("підготуй live tips до ...", "підготуйся до
   дзвінка"): a prep is never lighter than the sweep.
3a. **Topic documents rule (mandatory).** For EVERY item of the checklist and every topic
   expected on the call (the user's words, the prep report, the open threads), find the project
   documents that touch it, created or changed in the last 3 days (Project docs `DESIGN-`,
   `ROUTINE-`, `REVIEW-`, `INCIDENT-` and similar, then the project folder on the Mac:
   `Features/`, `Incidents/`, `reports/`, `research/`, previous `live/` transcripts and
   briefs), and read them in full, not only the research log. Their key facts (numbers,
   names, flows, open questions, who owns what, what is already decided) go into the Insight
   Bank with the document name and date. A topic with a fresh design or investigation
   document and no insights in the bank means the sweep is not finished: a call about 3DS
   cannot start without the 3DS design document in the bank. The sweep's returned summary
   lists, per topic, the documents used.
4. The main session says in ONE `SendUserMessage` line which sources were loaded (Current State with its `Last updated` or
   why it was not used, names and dates of the newest documents) and tell the PM that research done in other chats is invisible unless saved:
   "Що не збережено в проєкт, я не бачу. Збережи в проєкт або скажи в чаті." Offer nothing
   else. Do not end the turn.


**Insight Bank.** Distill the sweep into 15-40 one-line insights in the call languages,
each: fact with a number or a name, source document, date checked. Group by topic with
keywords (every language of `langs`) so the matching in Step 3 is quick. Include for every
competitor, tool or option discussed: price and plan, limits, language support, data
location, open questions, and the PM's own conclusions and recommendations. Include open
tasks and who owns them. Include contradictions found between documents (flag them).
This is the main source of "Додай", "Можеш додати" and "Твоя черга" tips.

Then collect in parallel (Notion rows as a delta after a fresh Current State, see "Current
State first"), everything scoped to this project (relation `Project` =
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
- **Trigger hygiene (cards misfire on common phrases).** Every trigger has 2+ distinctive
  words or one rare proper name. Never generic phrases ("what do you think", "давайте",
  "наступний слайд", "next slide", "slide", "make sense"), never a slide number. The "Your
  turn" card needs a name alias AND a request in the same line, as a regex, for example
  `re:(іван\w*|ван[яьі]\w*|ivan)\W+.{0,40}(розкаж|що в тебе|апдейт|update|over to you|your turn)` (built from `settings.user.name_aliases`).
  A name alone never fires: people mention the PM in passing ("як Іван казав").
- `on`: `them` (default for requests and questions), `me` (the PM's own risky phrases, e.g.
  a promised date), `any`.
- What to turn into cards: the PM's name aliases with an update request ("Your turn" with
  the speech theses), new-request phrases, commitment phrases ("we will deliver by"),
  each open topic and decision of the brief (the fact with its number and source), red
  lines, competitor or option facts from the Insight Bank, for interviews the Answer Bank
  (trigger = the topic words of each likely question).
- Same tip format rules (short gist, ready phrase in the call language, no abbreviations).
- The prep ahead saves `prep-...cards.json` (and `prep-...facts.json`, `prep-...outline.json`)
  next to the prep brief; at the start copy them to `<transcript name>.cards.json`,
  `.facts.json`, `.outline.json`.
- `@@CARD [time] id: line` lines in the `read_delta` output tell which cards fired. Count
  them in state (`cards_fired`); do not repeat a card's content as a tip; follow up only with
  what the card could not know (the exact question, a newer fact). A card gets `"off": true`
  in the cards file (read-modify-write in a poll call) only after TWO `off_topic` ratings
  (see "Tip rating"), never after one ✕, and never a fact card or a 🔴 card: those changes
  are proposed in Step 6 and the PM decides.

**Fact book (`<transcript name>.facts.json`).** The PM's main need on a call is instant
recall: "how long will X take", "when is Y", "how much is Z", "what is the status of W".
The recorder loads this file (and reloads it within ~2 s after any rewrite), sends the whole
book to the window (`kind: facts`, the 🔎 search box searches it locally as the PM types, no
model) and, when a `{them_label}` line has a question cue (how long, how much, when,
estimate, status, price, deadline, in every call language) and names a fact's keywords or
id, shows a 📌 fact card within ~1-2 s. Written by the sweep subagent together with the
brief, before the first poll when possible (it is the most useful file of the prep).
Questions like "how long will X take" are rare but costly when they come; most of the
book is the FRESH context of the project: what is happening now, what was decided, what the
PM investigated lately, with the numbers. A JSON list, 40-200 items:
`{"id": "AUTH-412", "title": "Audit logs in the admin panel", "text": "Estimate 16 h, To Do, assignee Dev A, sprint 42, no date yet", "keywords": ["logs", "логи", "audit", "аудит", "admin panel", "адмінка"], "source": "Jira, 14.10"}`
- **Where it comes from, freshest and local first** (device_bash, fast, no connector calls
  needed for most of it):
  1. The orientation sources the PM named, and for a deck or document review every number
     and claim on the slides with its source.
  2. The project current state (`notion.current_state_page`, or its local mirror
     `<project_root>/_notion/current-state.md` when it exists): Now, blockers, waiting on,
     decisions of the last 30 days, upcoming, changes. It is the backbone, but a summary:
     it rarely holds estimates or the details of an investigation, so it is not enough alone.
  3. The local Notion mirror of the project (`<project_root>/_notion/`: meetings, threads,
     decisions, risks, topics, tasks, reports), picked by the `last_edited` field in each
     file's front matter, NOT by the file time (the mirror rewrites all files at once): the
     last 14 days, the last 3 meetings of the same type, open threads.
  4. **What the PM worked on lately**: files under `<project_root>` changed in the last 14
     days by file time, excluding `_notion/`, `repos/`, `live/`, `.git`, raw data dumps
     (`.csv`, `.jsonl`, logs) and `.DS_Store`. Read the titles and headings and take the
     numbers (a decomposition with estimates, an analysis, a report): this is what the PM is
     most likely to be asked about.
  5. The tracker (when `task_tracker.api_access` allows): only tickets touched in the last
     14 days or named in the sources above, with original and remaining estimate, status,
     assignee, sprint and dates. Not the whole backlog.
  6. Prices, limits and dates from the brief and the Insight Bank; people (role, area).
- `id`: the ticket key for tickets (said aloud it scores high), else a short slug.
  `title`: max 6 words, the topic the way people say it. `text`: max ~140 characters, the
  numbers first. `keywords`: 4-12 words people use in speech, in every language of `langs`,
  including transliteration and slang ("авторайзер" and "authorizer", "логи" and "logs"),
  module and product names; never common words. `source`: the system and the date.
- Ticket keys are fine here (the window shows them in search results); the "no
  abbreviations" rule applies to tips.
- If the tracker is not reachable, say so in the checklist line ("трекер недоступний,
  факти лише з Notion").
