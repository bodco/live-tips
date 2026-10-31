Generated from `rules/sales.yaml` and `rules/crm.yaml`; do not edit here.

**Methods** (default `general`):
- `general` General sales: No formal qualification. Pacenote follows the client's pain, the value for them, objections, and whether there is a next step with a date. Criteria: `pain` Pain, `value` Value, `objections` Objections, `next_step` Next step.
- `bant` BANT: Budget, Authority, Need, Timeline: is there money, the person who decides, a real need and a time frame. Criteria: `budget` Budget, `authority` Authority, `need` Need, `timeline` Timeline.
- `spiced` SPICED: Situation, Pain, Impact, Critical event, Decision: the client's context, what hurts, what it costs, the deadline that forces a decision and how they decide. Criteria: `situation` Situation, `pain` Pain, `impact` Impact, `critical_event` Critical event, `decision` Decision.
- `meddic` MEDDIC: Metrics, Economic buyer, Decision criteria, Decision process, Identify pain, Champion: for larger deals with several people involved. Criteria: `metrics` Metrics, `economic_buyer` Economic buyer, `decision_criteria` Decision criteria, `decision_process` Decision process, `identify_pain` Identify pain, `champion` Champion.
- Call picture keys: `"deal": [{"criterion": "<criterion key>", "state": "unknown|partial|known", "what": "<what is known, max 14 words, call language>", "quote": "<the line, max 20 words>", "t": "<HH:MM:SS>"}], "objections": [{"what": "<the doubt, max 12 words>", "answer": "<how it was answered, or empty>", "t": "<HH:MM:SS>"}], "next_step": {"what": "<agreed next step or empty>", "due": "<date or empty>", "owner": "<name or me>"}, "signals": [{"what": "<buying signal, max 12 words>", "t": "<HH:MM:SS>"}]`
- Call picture rule: deal = the qualification CRITERIA (given with their keys) as heard on this call and before it: known when the client said it clearly, partial when only part of it, unknown otherwise; keep the strongest state reached and the line it came from. Only the client's words count, never the PM's guesses. objections = doubts of the client and how the PM answered. next_step = only a step agreed by both sides; due when a date was said. signals = clear buying signals (asking about price, start date, contract, onboarding).
- Tip `objection`: the doubt in one line and 1-2 sentences of answer; from an answer card when one matches
- Tip `qualify`: what is not clear yet and one question (from the criterion's ask) (a criterion is still unknown after 40% of the planned length or 10 minutes before the end, whichever comes first)
- Tip `pain`: the client named a pain without its size or consequence; ask about the scale or what happens if nothing changes
- Tip `next_step`: propose a concrete next step with a date (5 minutes before the end and next_step is empty or has no date)
- Tip `competitor`: a competitor was named; the answer card about it when there is one
- Tip `signal`: a buying signal; how to lock it in (the step to propose now)
- Priority: The PM triggers stay. In sales mode a sales tip wins over another tip of the same importance. The overall rate does not grow: the same limits apply.
- Ask and HELP NOW: answer cards first, then the brief and the project memory
- Coach mode: With Coach mode, tips address the person being observed (the seller): when the PM watches someone else sell (interview role observer, or a coach call with role mentor) every sales tip starts with "Seller:" / "Продавцю:" and its phrase is what the seller can say; when the PM is the one supported (role coach, "I am interviewed") the PM is the seller and tips stay as they are.
- Preparation, company: Company: what they do, size, news of the last 90 days, with links. Web search only in a sales preparation and only the company name or domain goes to the search, never the content of the project's files. Under it the line "Searched the web for: <name or domain>. Nothing from your files was sent." Settings > AI switch "Research the company on the web before sales calls", on by default.
- Preparation, from_crm: From CRM: the snapshot <stem>.crm.md (rules/crm.yaml > snapshot) with its age.
- Preparation, where_we_are: Where we are: the qualification from earlier calls of the series and the CRM: known, unknown, who said what.
- Preparation, objections: Likely objections: 3-5 with short answers, from the answer cards and past calls.
- Preparation, questions: Questions to ask: the questions that close the gaps.
- Preparation, goal: Goal of this call: one desired next step.
- After the call, section: The call page and the Notion meeting page get a Sales section: the criteria (state, what is known, quote), the objections and how they were answered, the next step with its date, and a suggested deal stage (a suggestion only).
- After the call, scorecard: For the PM only: criteria known, the PM's share of talk, open questions, whether there is a next step with a date. Facts of the call only, never a rating of people. Kept with the call (<stem>.sales.json); Statistics can filter sales calls.
- After the call, followup: a recap of the pain, the value, what was agreed and the next step
- Answer cards: `<project or workspace root>/pacenote/answer-cards.md`; "## <question or topic>" then the answer; optional lines "Tags: a, b" and "Use when: ..."

**CRM.** The participants' emails from the calendar find contacts, their domains the company, and the company's open deal updated last is the deal. The Start call row "CRM: <company> · Deal: <deal>" changes it or sets No deal; the choice is kept for the series.
- Snapshot: `<stem>.crm.md next to the brief`, before a preparation, before a call starts and on Refresh; kept for offline use; Company; deal (stage by name, amount, close date, owner, next step); contacts with roles; the last 10 activities in one line each; open tasks; the time it was taken.
- Write: Checkboxes: a note on the deal, the company and the contacts (summary, decisions, next steps, the Notion link when there is one; "Attach the transcript" off by default); deal fields (next step, close date when one was said, stage only when the PM picked one); qualification fields by the mapping; a follow-up task with a date. Texts come from the call page as the PM edited it.; "Updated in HubSpot · Open" and Undo for 8 s for what can be undone (deal fields back, the note and task deleted)
- Never: automatic writes
