# live-tips module: Presentation

Read when `call_type=presentation` is set (at the start or by `@@SET`). Two parts: the
outline file written in Step 2b, and the live rules of Step 3.

**Presentation outline (`<transcript name>.outline.json`, presentation only).** A JSON
object `{"sections": [...]}` with 5-15 sections in speaking order:
`{"id": "s3", "title": "Demo: reports", "points": ["Open the monthly report", "Filter by company", "Export to Excel"], "keywords": ["report", "звіт", "filter", "фільтр", "export", "експорт"], "numbers": ["12 reports/month", "2.4 s export"]}`.
`numbers` (optional, up to 6) are the figures the PM says in this section; the window shows
them in one bold line on the Now card (and on the slide card from `slides.json`).
`title` max 6 words, 2-4 `points` of max 8 words in the call language (what to say, not a
script), 4-10 `keywords` the PM will actually say in that section. The recorder follows the
PM's mic lines through the sections and the window pins **Now** (the current section with
its points) and **Next** (the next one), see "Presentation mode".

### Presentation mode (`call_type=presentation`)

The PM speaks most of the time; the job is to keep the PM on track and ready for the next
part, not to interrupt.
1. **Start.** Build `outline.json` (Step 2b) from the focus sources: the speech or deck the
   PM gave, the slides made in this session, the notes. Emit a short `speech` item (the
   section titles only); the Now / Next box carries the details.
2. **Tracking is local.** The recorder follows the PM's mic lines through the sections and
   writes `kind: outline_pos` (`cur`, `next`) into the tips file; the window pins Now and
   Next. Read the position with `grep '"outline_pos"' "<tips_file>" | tail -1` in the same
   device_bash call as a poll, when needed.
3. **Look-ahead in pauses.** When the position moves to section N, rewrite section N+1
   (and N+2 if time allows) in `outline.json`, read-modify-write, keeping `id` and
   `keywords`: drop points already said, add a one-line bridge from what the PM actually
   said, add the answer to a question the audience asked, add one fact from the fact book.
   The recorder reloads the file and the window updates Next. Max one rewrite per section.
4. **No interrupting tips** while the PM speaks: no comment, initiative or answer-check
   tips. Allowed: 📌 facts and cards on audience questions (local), a 🟠 `answer` with one
   phrase to a direct question, the time check at 2/3 and 5 minutes before the end
   ("Лишилось {N} хв, ще {K} розділів: {які пропустити}").
5. If the PM leaves the outline and improvises, do not force it back; the tracker catches
   up when the PM returns to a section's words.
6. **Quiet local layer during the PM's block** (recorder since 2026-10-23, `call_type=presentation`):
   no keyword 📌 facts and no "❓" cards unless a line has "?" (and the PM's name for "❓");
   semantic facts only on questions. On the real presentation 28 keyword facts fired during
   the colleague's talk and 71% scored 1-2.
7. **One time line, about the PM's own slides only.** The time check (2/3 and 5 minutes before
   the end) is ONE pinned line "⏱ {N} хв лишилось, {K} слайдів: пропусти {які}" that is
   updated in place, never five red cards, never advice about a colleague's slides while the
   colleague speaks.
8. **Numbers on the slides.** `slides.json` carries, per slide, the numbers the PM will say
   (`"numbers": ["840 680 UAH", "63 h"]`) and the 1-2 questions this slide usually raises with
   the answer (`"qa": [{"q": "...", "a": "..."}]`); the window shows the numbers in Now, and
   the Q&A entries go into the fact book so a question after the talk gets a local 📌 answer
   within 2 s. The PM garbled a number from his own slide and skipped the hours figure on the
   real call: the slide text alone does not help, the numbers must be on the Now card.
9. **Rehearsal results go back into the files.** After a rehearsal wrap-up ("+3.5 min",
   "slide 38 not reached", a decision not to ask for decisions today) rewrite `slides.json`
   and the brief at once, in the same session: the real call on 22.10 ran on an unchanged
   plan although the rehearsal had found both problems.
10. **Handoffs between two presenters** come from `slides.json` `who`: when the position
   moves to a slide whose `who` is `me` after a colleague's block, pin the PM's entry
   sentence as a 🔴 card BEFORE the handoff (the colleague's last slide), not on hearing
   the name: the handoff cues were never said as scripted and ASR wrote the name as "Body".
