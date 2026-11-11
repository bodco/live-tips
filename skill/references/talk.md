# live-tips module: The presentation talk (the `body` of `slides.json`)

Read whenever you write or rewrite the talk of a presentation: `slides.json` from an attached deck
(`presentation.md` 8b), Prepare again, a rehearsal rewrite (`presentation.md` 9). The app's Prepare on Claude
reads this file; the packed ways (Codex, OpenAI, Gemini, local) put it into the talk prompt as it is, so it is
the one source of the rules for both.

The owner's rule (11.11): **the text on every slide is what the PM himself says, and it is a real speech, not a
retelling of the slide.** The audience already sees the slide; the talk says what it means for them.

### 1. Voice
- First person, the PM speaking to this audience, in the call language: "I", "we" for our team, "you" for the
  audience. Use the audience's own names for things (their product, their team, their terms).
- Never describe the slide: no "this slide shows", "here we see", "on this slide", "the next slide is about",
  "на цьому слайді", "тут ми бачимо", "цей слайд про". Say the point instead.
- **Every slide, a colleague's (`who: other`) too.** A colleague's slides are written the same way, so the PM can
  say them word for word if he takes the slide over ("Take this slide" in the window). Keep the colleague's own
  wording when their speech document has the slide; "I" then means whoever is speaking.

### 2. A speech, not a retelling
- Pick the 1-3 things the slide is for and say them as full sentences with the conclusion. Do not read a bullet
  list aloud, do not list every label of a chart.
- Each slide opens with its point in one sentence (the claim, the finding, the ask). Then the evidence: the
  numbers, said in sentences with their unit and period. Then what follows from it for the audience.
- The last sentence of a slide leads into the next one (a bridge) when the same person goes on: "So the question is
  who owns the data. That is the next part." Before a colleague's block, hand over by name and topic: "Emily will
  now show what we found in the CRM."
- The first slide of the PM's talk: a greeting when it opens the call, what the audience gets today and what
  decision is asked. The PM's last slide: the ask or the next steps said plainly, then the move to questions.

### 3. Spoken style
- Short sentences, about 20 words at most. Plain words. No parentheses, no slashes, no abbreviations the
  audience does not use, no markdown, no bullet syntax inside `t`.
- Numbers as they are said aloud: "about two thousand three hundred of almost six thousand" or "2 311 of 5 946"
  when the exact figure matters; keep the exact figure in `numbers` either way. Dates as said ("on 22 October").
- One question to the audience at most per slide, and only where an answer helps (a check, a missing fact).
- No long dashes.

### 4. Length fits the budget
- About 2 words per second of `sec` (120-130 words a minute): 60 s is about 120 words, 30 s about 60. The said
  paragraphs (`p` plus `s`) of a slide stay within `sec * 2.2` words; the window warns when the pace needed goes
  over 150 words a minute.
- 1-4 paragraphs per slide. At least one `p`.

### 5. Paragraph kinds (`body: [{"k", "t"}]`)
| k | What | Window |
|---|---|---|
| `p` | said aloud | always shown |
| `s` | can be skipped when behind: an example, a detail, a second number | dimmed with "can skip"; Trim hides it |
| `h` | a stage note for the PM, not said, up to 12 words ("Pause for questions", "Point at the June column") | small grey line |
| `c` | a question to the audience or a check said aloud ("Mike, is that still the case?") | orange |
Old files with plain strings or only `p` stay valid.

### 6. Sources and facts
- From the PM's speech documents when they have the slide: keep his wording, phrases and numbers; tighten, do not
  rewrite them into another style. Else from the deck text, the speaker notes in `deck.json` (`notes`), the brief
  and the fact book.
- Never invent a figure, a name, a date or a result. Unsure means left out, not guessed. A number in `body` is in
  `numbers` too, and the `qa` answers carry their numbers.

### 7. Check before writing the file
- No sentence describes the slide; every slide has a point in its first sentence.
- Every slide has `body`, `numbers`, `qa` and `short` (a colleague's too).
- Words fit `sec`; the bridge to the next slide is there; no long dash.

### Example (one PM slide, 60 s)
Bad (a retelling): "This slide shows the activities in the CRM. There are calls, meetings and emails. Calls are
216, meetings are 4."

Good:
```json
{"n": 21, "sec": 60, "body": [
 {"k": "p", "t": "Almost nothing in the CRM is logged by itself. All 216 calls this year were typed in by hand, and there are only 4 meetings."},
 {"k": "s", "t": "Emails go the same way: 1 192 in the first quarter of last year, 258 in the third quarter of this one."},
 {"k": "c", "t": "Mike, do you know why the call notes stopped in January?"},
 {"k": "p", "t": "So we do not need to build this from zero, we need to switch back on what already worked. That is where the plan starts."}],
 "numbers": ["216 calls", "4 meetings", "1 192 → 258 emails"], "short": "Activities are logged by hand; switch the call notes back on first."}
```
