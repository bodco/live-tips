# Handoff: контекст підготовки, слайди колеги, трекер, live-фікси (2026-11-11)

Продовження розбору `research/pacenote-prep-context-findings-2026-11-11.md` (кейс 11.11, презентація з двома доповідачами).
Гілка main, **нічого не закомічено**. У робочому дереві є і чужі незакомічені зміни попередніх сесій (MeetingEndWatch, виділення тексту, адженда в кінці дзвінка тощо): не мої, не чіпав, при коміті розділяти.

## Зроблено

### H7 (відтворено в пісочниці, live/ не чіпав)
- `private/live-tips-app/prepctx1111/h7/`: точний запит прогону 2 (state/localprep-request.json) + part2, codex, старий код. Результат: 62 факти, слайди 28-31 є (F41-F48), 242/40, 2 311 з 5 946, 185, хибного "відсутні закриті угоди" немає. **Висновок: codex упорався б, причина прогону 2 в обрізанні (20 000 символів) і відсутньому деку, а не в маршруті.**
- `plan` без part2 не запускав ($4): Claude Read бере файл на 351 рядок повністю, ліміту 20 000 у нього немає. Висновок з коду, живим прогоном не перевірено.

### Блок A: бюджет контексту (усі packed маршрути: local, codex, openai, gemini, agy)
- Новий `spikes/m0/livetips_m0/prepcontext.py`: пріоритети (pinned: контекст, дек, файли PM > стан: конфіг, decisions, Current State, digest > попередні дзвінки > файли папки за 14 днів / збігом з назвою, людьми, контекстом > решта), виключення (`_archived`, приховані, prep-runs, згенеровані файли дзвінків, бінарники, старі версії `-vN`), стискання по розділах з видимою позначкою, бюджет на маршрут (local 120K, хмарні 280K символів), manifest + summary, `mark_read` для Claude-маршрутів, CLI `--request --read --write`.
- `localprep.build_pack` тепер обгортка над `build_pack_ex` (prepcontext); виправлено H3: маркер обрізання в `read_text` всередині ліміту.
- `codexprep` (і openai/gemini/agy через `route`): дек у пак, новий п'ятий прохід `slides` (SLIDES_SYS) пише `<base>.slides.json` з текстом і для `other`; `<base>.context.json`; рядок "Preparation context: ..." під назвою брифу.
- `PrepRunner.swift`: запит містить `deck` і `deck_lines`; той самий запит пишеться в `state/prepcontext-request.json` для plan/api, після прогону `contextManifest()` запускає `prepcontext --read --write` (context.json + рядок у бриф); `prep.json` отримує `context` (summary); `runFiles` + `context.json`.
- Симуляція на реальній папці: прогін 1 (уся папка) тепер бере дек, зустрічі 11.11 і 10.11, спіч v3, аудит, нотатки live; `_archived` і 144 згенеровані файли виключені.

### Блок B: слайди колеги
- `TalkFiles.prompt` (Deck.swift) і `skill/references/presentation.md` 8b: body/numbers/qa/short і для `other`.
- `rules/presentation.yaml > backup`; `tips.js` `backupBlock`: "Take this slide / Взяти слайд" у блоці колеги, клік відкриває текст; CSS у tips.css.

### Блок C: трекер
- `transcriber.py` Outline: `PRESENT_HOLD_S = 90` після ручного `set_slide` (і Keynote/PowerPoint); репліки `them` рухають лише на наступну секцію і лише якщо вона колеги. `rules/presentation.yaml > slide_sync > hold_s, colleague_follow`.

### Блок D: live
- Картки `on: them` не спрацьовують на мовця з side=team (`Cards.our_side`, `SpeakerTracker.side_for`, і для семантичних карток).
- Адженда: стан `raised` (`agenda.states(..., raised)`, `Engine._raised_idx` за стабільним id), вікно, CallPage, CallPageEdit, rules/agenda.yaml, згенерована секція SKILL.md.
- Whisper: `glossary_terms` з брифу (розділ 5 і латинські терміни, що трапляються 2+ рази), `with_glossary`; бриф підхоплюється, коли з'являється (кожні 20 с), echo-фільтр лишається на іменах.

### Живий прогін нового коду (`prepctx1111/v097/`, codex, уся папка як у прогоні 1, з деком)
- Контекст: 19 повністю, 14 стиснуто, 103 пропущено, 465 виключено, дек використано; 64 факти; 242/40, 2 311 з 5 946, 185, слайди 28-31 є; "фінальні слайди недоступні" зник.
- Перший прохід `slides` одним запитом впав за таймаутом акаунта (300 с). Виправлено: по 10 слайдів за прохід і менший матеріал (дек, документи спічу, бриф). Повторний прохід: 31 слайд за 366 с, у слайдів Марії 1-17 є body, numbers, qa, short.
- Застереження: у цій пісочниці папка вже містила нотатки дзвінка 16:57, тож порівняння з 14:20 не чисте.

### Перевірки
- pytest через чергу: 551 passed, 1 skipped (нові: test_prepcontext_097, test_slide_hold_097, test_live_fixes_097). tools/tests 16 passed. `node --check` tips.js, feed.js ок.
- `swift build -c release` ок (swifterr RC 0), CoreChecks 9073 passed.
- Встановлено 0.9.6 (196); 197 з поділом слайдів на проходи в черзі appupdatewhenidle.
- GUI не перевірено: блок "Take this slide", рядок контексту в брифі на сторінці дзвінка, стан raised у вікні.
- CHANGELOG (Unreleased, 7 записів), docs EN/UK 14.1w.

## Не зроблено (наступна сесія)
1. **Розкладка як у v0.7.5** (split view: картки слайдів з повним текстом + потік підказок). Потрібне рішення PM і side-by-side на цьому деку.
2. **Уламки мовців** (17 кластерів по 2-19 с): поглинати короткі кластери, орієнтир на кількість учасників з Meet. Потрібен реплей на embeddings.
3. **Пороги фактів**: калібрування на 1 120 near misses з `.app.semantic.jsonl` 11.11; факти колеги в панелі слайда.
4. **Затримка 17 с**: розкладка по етапах (ASR vs модель).
5. **Ехо `1|manual`** у вікні в ту ж секунду, що й рух трекера: не відтворено.
6. **UI до підготовки**: список кандидатів "візьму N з M" у Start call (зараз лише рядок після).
7. Перевірити живим прогоном `plan` з новим manifest (офлайн `mark_read` на read-списку 11.11 дав "7 прочитано, дек: використано").
8. Скіл у `~/work/Skills/src/live-tips` відрізняється від `app/skill`: зміну 8b перенести карткою або через реліз скіла.

## Команди
- Черга: `private/live-tips-app/queue/<n>-<cmd>.job` (pytest, swifterr, pyrun <шлях>, appupdatewhenidle <ver> <build>).
- Симуляція паку без моделі: `prepcontext.build(request, route="codex")`.
- Пісочниця: `private/live-tips-app/prepctx1111/` (h7, v097, _to_delete з одним службовим файлом).

## Пастки
- Notion-дзеркало пише всі файли з часом синку: дата береться з імені файлу.
- `prepcontext.rank` читає кожен файл папки (кількасот файлів, ~1-2 с) і для Claude-маршруту запускається синхронно після прогону.
- `clean_text` відкидає 1-2 слова з промпту: глосарій навмисно не входить у `prompt_words`.

Стартер: «Pacenote: прочитай claude/handoff-pacenote-0.9.7-prep-context.md, подивись результат prepctx1111/v097 і зроби розкладку презентації як у v0.7.5».
