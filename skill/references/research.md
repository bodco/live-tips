# live-tips module: Background research team

Part of Step 3 of SKILL.md. Read at prep together with `workflow-authoring` when research is
on for this call (not in the hiring roles `observer` and `interviewer`).

### Background research team (never blocks the loop)

Goal: when a topic is alive on the call and the Insight Bank covers it thinly, search the saved
project material in parallel while the main session keeps listening, then add the details as
soon as they arrive, if the topic is still alive. Defaults when `settings.tips.research` is
missing: enabled, `max_jobs` 6 per call, `max_running` 2, `agents_per_job` 4, `topic_cooldown_s`
300, `job_deadline_s` 90. Off in the hiring roles `observer` and `interviewer`. ON in the role
`coach`, with its own sources and rules (paragraph "Coach variant" below). Needs the
Workflow tool; without it, T1 tips only and one line in the wrap-up.

**Triggers** (any one, after the first 60 s of the call, not while a hiring answer is open):
1. a keyword of the topic map or the checklist is heard and the bank holds fewer than 2 insights
   on it;
2. a question addressed to the PM whose answer is not in the bank;
3. the PM says they checked, investigated or read something ("ми досліджували", "за
   документацією", "I reviewed", "we found in the documentation"), or the other side asks "did
   you check / find out": the PM's own documents on that subject are the answer, fetch them;
4. a topic holds the talk for more than ~60 s and the bank has no number, name or date for it.

**Sequence in ONE step** (decide, emit, start, poll):
1. emit the T1 tip into the window in the same `read_delta` call (fact from the bank, or the
   one-line "Шукаю в документах, деталі за ~1 хв");
2. start the job: ONE `Workflow` call with an inline script (`workflow-authoring` rules). It
   runs in the background and returns at once with a task id; save `{topic, started_at, task_id}`
   in state `research`. Do not wait, do not read the result, go straight to the next poll;
3. the script runs 3-4 agents in parallel with a hard deadline (`job_deadline_s`), each with a
   `schema` and a limit of ~150 words, and one merge step. Pass in `args`: topic, the exact
   wording of the last question or statement, the last 3 transcript lines, `answer_lang`, the
   project slug, `project_root` paths, the Notion ids from the config, the red lines of the
   brief. Agents (one per source, fewer if the topic is narrow):
   - A. claude.ai Project documents (`project_info`, `project_search`, `project_read`), newest
     first: design, investigation, review, incident and routine documents touching the topic;
   - B. the project folder on the Mac (`device_bash`: grep and `ls -t` by keywords in
     `Features/`, `Incidents/`, `reports/`, `research/`, previous `live/` transcripts and
     briefs, `lessons.md`);
   - C. Notion, scoped to the project: Meetings (last 3), Threads, Decisions, Topics, Risks,
     Reports by the keywords;
   - D. tracker, Slack, Confluence by the keywords (tracker queries scoped per
     `task_tracker.project_key`, never an unscoped query).
   Each returns `{insights: [{fact, source, date, restricted: true|false}], answer_phrases: []}`;
   a number, a name, a flow step or an open question beats prose. The merge step removes
   duplicates, ranks by relevance to the exact wording and returns max 8 insights and 2 ready
   phrases in `answer_lang`. Agents must not write to Notion, Jira, Slack or the project, and
   must say when a source is empty or unreachable instead of guessing.

**Limits.** At most `max_running` jobs at once, `max_jobs` per call, one job per topic per
`topic_cooldown_s`; a job older than 3 minutes without a result is marked `lost` in state, no
retry, no message. A second trigger on a running topic does not start a new job (the pending
one will answer it).

**Delivery (when the result arrives as a task notification, or on the poll after it).**
1. Read the last ~2 minutes of the transcript. If the topic is still being discussed (its
   keywords in the last ~90 s), emit one 🟠 "Деталі: {topic}" tip: up to 3 facts with numbers
   and the source, plus 1-2 ready phrases in `answer_lang`, in the Tip format. If the result is
   late, say so in the `note` ("із запізненням").
2. If the talk moved on, say nothing: append the insights to the Insight Bank (and to the
   `.brief.md` file) and list them in the wrap-up under "Знайдено, але не знадобилось".
3. Restricted facts (internal estimates, defects, security findings, internal capacity) may
   shape the tip but the tip is marked 🔒 and never states an estimate as a number; the red
   lines of the brief and the client-facing rules of the project config still apply.
4. A contradiction between what was just said on the call and what the research found is a 🔴
   "Неточно: ..." tip with the source, same as the answer check.
5. Add the useful insights as new cards to `<transcript name>.cards.json` when the topic can
   come back (read-modify-write in a poll call).

**Coach variant (the PM is being asked, coach role).** The failure to avoid: the interviewer digs
into the PM's own past work (a project, an investigation, a number, a decision) and the tip is
generic or steers away, while the facts sit in the PM's own documents. So:
- Trigger: a question or follow-up about the PM's own experience (a project, a case, a tool, a
  metric, "tell me more about X", "how did you decide") that the Answer Bank covers with fewer
  than 2 facts. The PM is speaking most of the time, so the "hiring answer is open" exception
  does not apply here; the T1 tip still goes first, from the Answer Bank, in the same poll.
- Sources (agents A-D are replaced by): A. the Truth Bank and the RECAP/prep pages
  (`settings.hiring.coach`); B. the PM's own project documents in the claude.ai Project and
  the project folder (design, investigation, incident, review, routine documents) for the
  project the question names; C. Notion pages of that project (Meetings, Decisions, Reports);
  D. the Job Tracker row and the job post (what the role actually needs).
- Output: facts about the PM (numbers, names of decisions, steps of the work, outcome) with the
  source. A fact found only in a project document and not in the Truth Bank is marked
  "(з документів, перевір)"; never state it as certain. Never invent. Client names, internal
  estimates and security findings are 🔒: give the shape of the answer without the client's name
  or confidential numbers, unless the Truth Bank allows them.
- Delivery: the "Деталі" tip is a short STAR-shaped phrase (situation, action, result, 2-3
  sentences) in the interview language plus up to 3 facts, so the PM can say it at once.
- Before the interview (Step 2a prep): the coach prep subagent runs the topic documents
  rule for the PM's strongest 3-5 projects and writes a story card per project (context, the
  PM's role, the hardest decision, numbers, outcome, the document it came from) into the
  Answer Bank, so most deep questions are already in T1.

**State.** `research`: list of `{topic, trigger, started_at, task_id, status:
running|done|lost, delivered: tip|bank|none, late_s}`. The wrap-up counts jobs started, tips
delivered from them and results that came too late.
