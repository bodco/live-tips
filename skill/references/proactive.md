# live-tips module: Proactive tips: comment moments and initiative tips

Read ONLY when `proactive` is `on` (⚙ menu or settings `tips.proactive: on`). Default is off since 2026-10-21: these tips had the worst ratings ("ми не про це говорили"). With proactive off, none of this applies.

With proactive on, these rows join the triggers table of SKILL.md. Rate: at most one comment or
initiative tip per `tips.comment_rate_seconds` (default 60; the ⚙ menu overrides it), never while the
PM speaks, and stop for 10 minutes after two ✕ in a row or a ⏸ pause.

| Level | Trigger | Tip |
|---|---|---|
| 🟠 | Comment moment: `{them_label}` finished a complete thought on a work topic and the PM has not reacted yet (see "Comment moments") | "Можеш додати: {тема}" + 1-2 ready phrases built from Insight Bank facts. Own rate `tips.comment_rate_seconds` |
| 🟠 | The PM is asking (questioning stretch): an answer opens a follow-up worth asking, or a planned question is skipped | "Уточни: {що}" + the question as a ready phrase |
| 🟠 | Initiative: the PM has been silent for ~60 s while others discuss a topic where the PM has a fact, a risk or a question (see "Initiative tips") | "Можеш вставити: {тема}" + 1-2 ready phrases |
| 🟠 | Initiative: the conversation drifted for ~4 min away from the checklist and a checklist item is still open | "Поверни до: {пункт}" + a ready phrase that steers back politely |
| 🟠 | Initiative: a decision, owner or date was discussed but not fixed | "Зафіксуй: {що}" + a ready phrase ("So, {owner} will {action}. Is that right?") without naming a number for estimates |

### Comment moments (do not wait for a direct question)

Only when `tips.comment_prompts` is true (missing = true; missing `tips.comment_rate_seconds` = 60 in active mode, 120 otherwise; the `💬` window button overrides the rate for the call, `0` = off). On calls people rarely ask the PM directly. More
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
rates of "Tip diet and rates".

- **Add a fact or a risk.** Others discuss a topic from the brief and miss something the
  brief or the Insight Bank knows: a blocker, a dependency, a past decision, a deadline, a
  price, a limit, a ticket status. Offer it as a short phrase the PM can say.
- **Ask a question.** Offer one sharp question that unblocks the work: who owns it, what is
  the date, what is the dependency, what happens if it slips.
- **Fix the outcome.** When a topic ends without an owner, a date or a yes/no, offer the
  closing phrase ("So Ivan checks the variable today. Right?").
- **Steer back.** When the talk drifts and an open checklist item or a "Decision to obtain"
  remains, offer a polite steer back.
- **Use the speech.** If a speech thesis fits the current topic, offer the exact phrase for it.

Do not use initiative tips for: sensitive or legal discussions where the PM is clearly
thinking aloud with the team (an incident post-mortem, a contract position) unless the PM
asks; moments when the PM is speaking; small talk.
