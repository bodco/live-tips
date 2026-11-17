# live-tips module: Speech writer (a speech document for a deck, before the call)

Read when the PM asks for a talk to a deck outside a call: "напиши промову", "промова до слайдів", "текст до
презентації", "write my talk", "speech for the deck", "speaker notes for these slides". No recording, no
window, no Notion: the result is one file the app's Prepare reads. The rules of the speech itself are
`talk.md`; read it first and follow it for every slide. This module only adds the input, the file format and
the checks.

### 1. Input
- **The deck** (required): PPTX, PDF, or a Keynote export (PDF or PPTX). Read every slide's title, text and
  speaker notes. PPTX: `python-pptx` (slide shapes, `notes_slide`); PDF: `pdftotext -layout` per page, one page
  is one slide. A deck you cannot read: say so in one line and stop, never guess the slides.
- **The PM's notes** (optional): files or text he gives. They win over the deck text: keep his wording, phrases
  and numbers (`talk.md` 6).
- **Length**: the talk time in minutes and the Q&A time at the end. Not given: ask once, in one question with
  all missing items; no answer means 20 minutes of talk and 5 of Q&A, said at the top of the file.
- **Language** of the call (the speech is written in it) and **who presents which slides** ("me" by default; a
  colleague's slides are written too, as the PM's backup, `talk.md` 1).
- **The project**: where the file goes. Not clear from the deck's folder or the request: ask, listing the
  projects; never pick one silently.

### 2. Budgets
Split the talk time over the slides the way the app does: a title or section slide 20-30 s, a content slide by
its weight (text, numbers, a chart), the PM's last slide with the ask at least 60 s. All slides together equal
the talk time. About 2 words per second (`talk.md` 4).

### 3. Output: `<project>/pacenote/speech/<deck stem>.speech.md`
`<deck stem>` is the deck's file name without its extension, exactly (Prepare matches the deck by it). An older
file of the same name: keep its slides the PM edited by hand when he says so, else write it anew and say that
the old one was replaced. Format:

```
# Speech: <deck title>
Deck: <deck file name> · Talk: 20 min · Q&A: 5 min · Language: en · Speakers: Me, Emily

## Slide 1: <slide title>
Who: me
Time: 45 s
<what the PM says, one paragraph per line group, by talk.md>
Can skip: <a paragraph that can go when behind>
Ask: <a question to the audience, at most one>
Stage: <a note for the PM, not said, up to 12 words>
Numbers: 216 calls · 4 meetings
Short: <the slide in one sentence>
```

- One `## Slide N: <title>` per deck slide, N = the deck slide number, all slides, none merged or dropped.
- `Who:` `me`, `shared` or the colleague's name. Plain paragraphs are said aloud (`p`); `Can skip:` is `s`,
  `Ask:` is `c`, `Stage:` is `h` (`talk.md` 5).
- `Numbers:` every figure said on the slide; `Short:` one sentence. No long dashes, no markdown inside the
  paragraphs.

### 4. Checks before writing
- `talk.md` 7 for every slide: a point in the first sentence, nothing describes the slide, words fit `Time`.
- The sum of `Time` equals the talk time (within 30 s).
- Every number is in the deck or the PM's notes. Never invent a figure, a name or a date.

### 5. After writing
One short message: the file path, the slide count, the talk time, and that the app's Prepare for a
Presentation call with this deck now takes the speech from this file (Prepare again when the deck is already
prepared). Nothing is sent to anyone.
