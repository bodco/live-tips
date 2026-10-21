# live-tips module: Hiring interview mode

Read when `call_type` is `interview` (at the start or by `@@SET call_type=interview`; legacy `hiring`). It covers
the prep (Step 2a for hiring), the live tips by role, the analysis (Step 4 for hiring) and
Step 5 for hiring. Step 5 for hiring refers to `references/wrapup.md` for the destination rule.

### Hiring interview mode

Type `interview` (`references/start.md`, Step 0 item 3). The goal is different from a work call: no project status, no
scope, no commitments. Tips are about the questions asked and the answers given.

**What is off in hiring mode:** the speech (status) and "Your turn" from the speech, comment
moments, initiative tips, the new-request, commitment, frustration and contradiction
triggers, the answer check of the PM's own replies (except in the `coach` role, below),
the 2/3 and 5-minute checklist triggers (except `interviewer`). Side talk in another
language stays on. The Insight Bank sweep of project documents is skipped unless the
position belongs to the PM's own project (then only Team tables, stack and the open roles).

**Speakers.** `{me_label}` = the PM's mic, `{them_label}` = everyone else in ONE channel: the
interviewer(s), the candidate and any colleague are not separated in the transcript. Tell them
apart by content: who asks (short questions, "tell me about", "how would you") and who answers
(long first-person replies, "I", "in my last project"). Use names said aloud (introductions)
and keep them in state. If unsure who spoke, mark the tip "(?)".

**Roles** (`hiring_role`): `observer`, `coach` (the PM is the one being asked; the legacy
value `candidate` means `coach`), `interviewer`. In this file "the candidate" is always the
OTHER person being interviewed (roles `observer` and `interviewer`), never the PM.

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
  (4-5 sentences) for each of those topics (see "Reference answers: depth and speed" at the end of this file).
- `coach`: the prep is done by the **coach prep subagent** (see "Context sweep"
  for how subagents are used) with this brief, everything from `settings.hiring.coach`
  (fallback `settings.hiring.candidate`):
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
  5. **Story cards from the PM's own work (mandatory).** Topic documents rule applied to the
     PM: from the claude.ai Project and the project folder take the newest design,
     investigation, incident, review and report documents of the PM's current projects and
     the 3-5 that best match the role's requirements and the stage. For each write a story
     card: context, the PM's role, the hardest decision or investigation (steps, not prose),
     numbers, outcome, file and date; mark what is confidential. Put them into the Answer
     Bank. Facts only from documents or the Truth Bank, never from memory of the model.
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
- `coach` (the PM answers):
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
   PM in `coach`), with confidence (висока / середня / низька) and why.
2. **Питання і відповіді**: table: питання (тема) | що відповів | оцінка (сильна /
   прийнятна / слабка / не почули) | чого бракувало для сильної відповіді.
3. **Сильні сторони** and **Прогалини і ризики**: 2-5 items each, every one with a quote or
   a time from the transcript.
4. **Сигнали з боку того, хто питав**: depth of follow-ups, topics they returned to, what
   they explained about the project, the next step they named.
5. **Рекомендації**: `observer`: what to tell the candidate before the next round and
   whether to put them forward again; `coach`: what to prepare for the next round;
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
candidate's answer VERBATIM as plain paragraphs, "Question: ..." then "Answer: ...", in
call order. Build the list with a script from the transcript (the lines are often one channel:
merge consecutive lines of one speaker, attribute by content, merge rephrased questions into
the question, keep ASR errors as they are, add one caveat line about that), save it locally as
`<transcript name>.qa.md`, and append to Notion in chunks if it is too large. The `coach`
branch below gets the same two sections in the Job Tracker row page.
`coach`: no Meetings DB page. Write into the company's Job Tracker row page: append a
section `## Співбесіда {YYYY-MM-DD}: {stage}` with the full analysis, plus the transcript in a
toggle "Транскрипт"; append one line to `Stages log` ("N. YYYY-MM-DD {stage} - очікуємо
результат", N = `Stage #` + 1) and set `Stage #` to N. `Status`, `Last response` and
`Next step on` change only on the PM's word. If no row exists, create one with `Company`,
`Vacancy`, `Status` = `Interview`, then write as above. The coach analysis adds a
**Ретро** block: the weakest answer, where the PM spoke too long, the question that
surprised, what to add to the Truth Bank or the recap, what to prepare for the next stage.
The local `.analysis.md` stays too in every role.

### Reference answers: depth and speed (moved from SPEED in SKILL.md)

1. Do NOT shorten the reference answer to gain speed. Keep 4-5 substantive sentences
   (the concrete terms, a tool or example, the usual pitfall), never a surface summary. Gain
   speed from the process instead: no preamble, no second draft, no hedging, the answer is
   written straight into the heredoc in the interview language.
2. The best way to be fast AND deep: during the quiet start (Prep) write a reference answer
   of full depth for each likely topic into the brief (an internal Answer Bank). When the
   question arrives, adapt that answer to the exact wording instead of composing from zero.
3. Reasoning effort is a balance: medium for interviews. Read `think_gap_s` in `.polls.jsonl`
   after the call: if the median is above ~8 s, lower the effort one step; if answers turn
   shallow, raise it. Never trade answer substance for speed.
