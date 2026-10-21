# live-tips module: Answer check and questioning stretches

Read when the audience is `client` or `boss` (answer check matters there), or when the PM starts asking a series of questions.

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

Tips only as in "Tip diet and rates": on internal calls never, on client calls only the serious 🔴
case, sent at once. Good answers produce no tip. Log every pair with a verdict in state (`answers`) and list
the weak ones in the wrap-up under "Відповіді, до яких варто повернутись". Judge the
content, not the person: no comments on tone, confidence or emotions.

Whisper can still garble words or misspell names: judge by meaning, mark
an uncertain tip "(?)", never quote a garbled line as fact.
