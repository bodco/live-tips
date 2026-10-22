# live-tips module: The PM's speech (Step 2a) and the opening

Read at the start when a speech is due (a status round, a client or topic call with a position to state). Not needed for an interview (see hiring.md) or a presentation (see presentation.md).

### Step 2a - Speech theses (target: in the window within ~30-40 s of the start)

**Focus sources first.** If this session already holds a meeting prep, an agenda, a prep
report (`daily-team-prep`, `client-meeting-prep`), interview questions, or the user named
specific Notion pages, documents or a folder for this call, take the points from there. They
are a priority, not a limit.

**Status mode** (a round of updates is expected: a stand-up or daily slot, a sync where
everyone reports, audience `team` or `boss`; also when the round starts unannounced). Generate the status immediately, without being asked:

1. **Period.** From the end of the previous meeting of this type (Meetings DB, last page of
   that type; the calendar if the Meetings DB has none) to the START of today. Work done
   today before the call belongs to the next status, not this one (it is said at the next
   meeting of this type). If the previous meeting cannot be found: yesterday, and for
   Monday since Friday. Say the period in the first line ("за період 12.10-13.10").
   **No repeats.** Before writing the speech, read the `{me_label}` lines of the previous
   transcript of this type in `<project_root>/live/` (and its `.brief.md` "My update") and
   drop every point the PM already said there. A point comes back only if it changed since
   (a new status, a new date, a new blocker), and then only the change is said.
2. **Read the Current State page first** when the config has one (see `sweep.md`, "Current State
   first"; it already lists recent changes and what waits on whom), then **collect in
   parallel, only what is needed for the status:** task tracker (per
   `task_tracker.api_access`): tickets of the PM and of the team changed in the period
   (moved to Done, Dev Done, deployed, new blockers) and in progress now; Meetings DB:
   action items and promises of the last meeting of this type; Reports DB: today's prep
   report; the Threads DB: `Awaiting Reply` / `Need Follow-up`; **the newest documents of the
   claude.ai Project** (see `sweep.md`, sweep step 1) for what was researched in the period.
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

**Any other call (a discussion, a client call, a call with the boss)**: the speech is the PM's position and key points for
the subject: 3-6 theses (what we want from this call, our position, facts to state, what we
should not say), plus an opening sentence. If the PM plans to ask the client questions, the
planned questions in order. For a hiring interview: see "Hiring interview mode" (Prep), the speech is replaced by
the role's prep item.

**Refresh.** The PM can ask "онови спіч" in the chat or the window at any time (or the window
button): regenerate from fresh data and emit again. After each other participant's report in
a round, when the PM's turn is near, re-emit "Your turn" (see Triggers).

**If the PM opens the meeting** (the PM hosts it, the user says so, or the first 30 s of the
call are silent on the other side): right after the speech post the "Your turn" tip
(see Tip format) as an opening: greeting plus the goal of the meeting in one sentence, then
the agenda order, or the speech if the meeting starts with it.

### Formats: the speech item and the "Your turn" tip

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
