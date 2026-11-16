# Pacenote: редизайн Home, сторінок дзвінка, Tracker. Фаза 0 (інвентаризація)

2026-11-03. Гілка `redesign/0.9.0` від `origin/feature/0.8.8-decisions` (`e413cda`). Нічого не закомічено.
Макет: канвас "Pacenote Home Redesign". Промпт: dev-промпт від 2026-11-03.

## Що прочитано
- CHANGELOG.md (Unreleased: ChatGPT/Codex, OpenAI API, On me, Agenda Skipped), DEVELOPMENT.md.
- ROADMAP: лише `private/live-tips-app/ROADMAP.md`, стан на 0.5.0 (23.10), застарів.
- Handoff `claude/handoff-pacenote-*.md`: **жодного не знайдено** ні в репо, ні в `work/`. Цей файл перший.
- Екрани: `HomeWindow.swift` (1110 р.), `HomeStats.swift`, `Features.swift`, `CallSetup.swift` (StartCallWindow: Start / Plan / Upcoming / Prepare), `CallPage.swift` + `CallPageEdit.swift`, `Memory.swift` (Call memory, Series), `Prompter.swift` + `Resources/tips/` (live-вікно), `SettingsView.swift` (General, Projects, AI, Integrations, How it works, About), `TranscribeWindow.swift`.

## Перевірка припущень з промпту

| Припущення | Що в коді | Висновок |
|---|---|---|
| Запис і транскрипт без Claude | ASR локальний (MLX). Start у CallSetup вимагає лише project/workspace (`model.target`), не AI. Є тип дзвінка Transcript (без підказок) | Так. Але без проєкту/workspace старт заблокований: "Start call" на Home без календаря відкриватиме вибір проєкту |
| Ручний старт без календаря | `StartCallWindow.show` працює без календаря, Plan a call теж | Так |
| "The project folder and the last 3 calls are always included" | `PrepRunner.previousCallsBlock`: останні 3 дзвінки **тієї самої зустрічі (та сама назва)** у live-теці проєкту. Теку проєкту людина може виключити ("Left out", кнопка Remove) | Текст неточний. Пропоную: "The project folder and the last 3 calls of this meeting are included" і лишити можливість виключити теку |
| Приховування дзвінків | `CalendarService.hidden`: на **одне входження** (event id + start), UserDefaults `calHidden`, останні 300. Up next-модель видаляється з черги. Повернути можна лише в Settings > Calendars "Show them again" (усі разом). Undo немає | Поведінка очевидна, лишаю як є, додаю Undo (повертає останній id). Питання 4 закрите |
| Експорт Word / MD / Notion | Уже є в `TranscribeWindow`: `.md` через NSSavePanel, `.docx` через `NSAttributedString` officeOpenXML (вбудовано в AppKit, **без залежностей**), Notion-сторінка в Meetings DB | Винести в спільний `Exporter` і перевикористати на сторінці дзвінка. Важкої залежності не треба |
| "Runs on: Claude account / API key" | Підготовка зараз: Claude Code, Claude API, local (Ollama), ChatGPT account (Codex). OpenAI API для підготовки недоступний. Авто-перемикання є лише для Claude -> local ("Use it when Claude does not answer"), ChatGPT/OpenAI не перемикаються | Селектор Runs on має показувати всі 4 маршрути з `rules/ai.yaml`, а не два |
| Колір проєкту | У `Projects.swift` поля кольору немає | Стабільний колір з палітри за slug (новий код). Поле в налаштуваннях проєкту: окреме рішення |
| Prepare again під час дзвінка | Є `Freshness` + `refreshBase` (легке оновлення) і `brief.prev.md` (одна попередня версія, "Restore previous version"). Повна підготовка з транскриптом "до цієї хвилини" не існує | Фаза 4 нова робота. Правило "одна попередня версія" вже реалізоване, перевикористовую |

## Конфлікт з правилами (Rule zero для застосунку: rules/)
- `rules/decisions.yaml`: рішення йдуть у Control Tower Decisions DB, "**never to a register of Pacenote's own**". Ризики теж пишуться прямо в Notion. Локальне сховище є лише для commitments (`<project>/live/commitments.jsonl`). Фаза 3 ("локальне сховище Pacenote як джерело, синк у Notion") суперечить цьому правилу і змінює поведінку скіла. Потрібне твоє рішення до фази 3.

## Таблиця "було -> стало"

### Home

| Було | Стало | Статус |
|---|---|---|
| "What Pacenote can do" (Features, "Hide from Home", "Try it", "All features") | Settings > Help / What's new (нова панель на основі How it works) + одноразові підказки в контексті | за промптом |
| On you (задачі, фільтр Project, Mark done, Copy, Open the call, Add to Notion tasks, Hide here, Remove/Move to trash, Undo, Show all) | Вкладка Tasks на сторінці дзвінка + Tracker. Notion-задачі без дзвінка (бейдж N) і "Move to trash" -> лише Tracker | за промптом |
| This week (calls, on calls, prepared x of y, Details -> InsightsWindow) | ? | **питання 1** |
| Статус-рядок (AI connected, Notion synced/stale, N calendars, ліміт витрат) | Пігулка в шапці лише при проблемі -> Settings > Integrations. Попередження про ліміт витрат теж у пігулці | за промптом |
| Plan a call (шапка) | "Plan a call by hand" у стані без календаря + пункт у меню "Start a call now" (стрілка) | пропозиція |
| Start call (Cmd-N) | "Start a call now", Cmd-N лишається | за промптом |
| Search calls (Cmd-F, Call memory) | Пошук у шапці | за промптом |
| Transcribe a recording (шапка) | **немає місця в макеті** | **питання** |
| Finish setup (install, name, calendars, Claude, Notion, Later, x) | Перший запуск "Three steps" + пігулка. "Speech recognition is not installed" і "Add how people call you" -> пігулка | пропозиція |
| Hero "Last call" (рішення, Open call) і "Today on you" | Recent calls (перша картка) | за промптом |
| Live-банер (Recording: Waiting for the call, Show tips, End call) | Лишається над карткою, коли йде дзвінок (у макеті немає, але губити не можна) | пропозиція |
| Auto-start банер ("Start tips for X?", Not now) | Лишається | пропозиція |
| Картка Up next: Start tips for this call, Edit setup, Prepare again, Rehearse, Your talk, Series: N calls | Get ready / Start call + посилання (таблиця 1.2). Edit setup -> назва дзвінка (сторінка, вкладка Setup). Rehearse, Your talk -> сторінка дзвінка. Series -> вкладка Earlier calls | за промптом |
| "Are you ready?" чекліст: Brief ready/Preparing %/In line/Failed/No brief, Open brief, On you still open, Notion tasks on you, Waiting on X, Overlaps with Y + Skip Y | Стан брифу -> рядок картки + вкладка Brief. On you / Waiting -> вкладка Tasks. **Overlaps + Skip** -> рядок на картці "Overlaps with Y · Hide it" | пропозиція |
| Бейджі стану: Not prepared, Ready, Stale + Refresh, In line, Preparing…, Failed + Prepare, Live | Ready / Not ready. Preparing, In line, Failed, Live: та сама м'яка пігулка з текстом (без помаранчевих заливок). Stale = Not ready з підказкою | пропозиція |
| Later: рядки, Calendars… (вибір календарів), Nothing else planned | Coming up (таймлайн), "All 16 calls". Calendars… -> Settings > Integrations | за промптом |
| Меню рядка: Set up…, Start now / Switch…, Cancel (черга / підготовка), Show in Calendar, Hide here / Remove from Up next | "…": Get ready / Prepare again, Not my call, hide it. Start, Switch, Cancel, Show in Calendar -> сторінка дзвінка | за промптом + пропозиція |
| Recent: рядки, Series pill + "Why this is a series", меню Summary / Follow-up / Series / Open in Notion / Open transcript / Draft follow-up / Show in Finder / Remove from this list | Сітка 3 карток, клік -> сторінка минулого дзвінка. Notion, Finder, Follow-up -> шапка сторінки ("More"). "Remove from this list" -> контекстне меню картки | пропозиція |

### Майбутній дзвінок (StartCallWindow -> сторінка дзвінка, вкладка Setup)

| Було | Стало |
|---|---|
| Project / Workspace (пошук) | More settings > Project |
| Call name, "Use its settings" (запам'ятаний дзвінок) | Назва в шапці (редагується), "Use its settings" як рядок у Setup |
| Date, Time, From calendar… | Мета-рядок шапки; ручне редагування лише для дзвінка без календаря (More settings) |
| Call type: Regular, Presentation, Interview, **Transcript** | "What kind of call is it?" зі списку з коду. Workshop у коді немає: не додаю без тебе. Transcript лишається типом ("Records only") |
| Audience (Auto/Client/Team), My role (Interviewer/Observer/Coach), Language | More settings (Role лише для Interview) |
| Sales toggle + About the method | "Sales mode" галочка під типом, метод у More settings |
| What matters on this call | Питання 2 |
| Project folder on/off, Add folder or file, Include/Remove | Питання 3 "Files for the brief" |
| Mic, Proactive tips, Start recording (when other side speaks / right away), Public call, Brief to use, Copy request for Cowork, Preparation settings… | More settings |
| How many tips, Runs on | More settings (Runs on: 4 маршрути, див. вище) |
| Брифа стан: Writing {stage}, Stop, In line, Take out of line, Open, Brief ready, (the one found is for…) | Вкладка Brief + головна кнопка шапки |
| Hints: no Claude Code, not signed in, no key, no Notion | Вкладка Brief, порожній стан |
| Prepare again? (тримає попередню версію), Brief is N days old | Посилання "Prepare again" + той самий діалог |
| Rehearse, Your talk | Шапка / вкладка Brief для Presentation |
| Save, Save for later, Cancel, Remove from Up next | Save, Cancel. Remove from Up next -> меню "…" у шапці |
| Start now / Switch to this call… | Start call у шапці (Switch, коли йде інший дзвінок) |

### Минулий дзвінок (CallPage)

| Було | Стало |
|---|---|
| Agenda (чипи not raised / raised / discussed / skipped) | **Немає вкладки в макеті.** Пропоную блок у Summary |
| Open questions + "Save as answer card" | Пропоную блок у Summary |
| On you / On them (редагування, owner, due, Add to Notion tasks) | Вкладка Tasks (Add to Tracker) |
| Decisions (Add to register, Add all, Replaces…?) | Вкладка Decisions (Add to Tracker, Add all, Replaces лишається) |
| Risks (Add to risk register + підтвердження) | Вкладка Risks |
| Sales: критерії, objections, next step, scorecard | **Немає в макеті.** Пропоную вкладку Sales лише для sales-дзвінка |
| Draft follow-up email (Rewrite, Copy, Open in Mail, Write again) | **Немає в макеті.** Пропоную кнопку в шапці поруч з Export |
| Transcript (окреме вікно), пошук | Вкладка Transcript |
| Series: N calls (SeriesWindow) | Посилання в мета-рядку -> Series |
| Open in Notion, Show in Finder, Update CRM, More | Меню "…" у шапці |
| Синк правок у Notion (Synced · ago, Retry) | Мета-рядок |
| (нове, не було) | Ask about this call (Call memory з фільтром на дзвінок), Export |

### Live-вікно
Шапка (Recording, mic, пауза, Proactive, End) і вся решта (hero, Earlier, agenda, On me, transcript, brief, compact, presentation) без змін. Додається лише плашка брифу (фаза 4).

### Settings
Нове: Help / What's new, Modules (Tracker), можливо Usage. Решта без змін.

## План фаз
0. Ця таблиця + відповіді на питання. (зараз)
1. Home: прибрати блоки, шапка + пігулка, картка наступного дзвінка, Coming up з кольорами і Undo, Recent calls, 3 стани інтеграцій. Help / What's new у Settings.
2. Сторінки дзвінка: спільний каркас, Setup (Save + незбережені зміни), Brief, Tasks, Earlier calls; минулий дзвінок з вкладками; спільний Exporter з TranscribeWindow.
3. Tracker: після рішення по конфлікту з rules/decisions.yaml.
4. Підготовка під час дзвінка: PrepRunner з транскриптом до хвилини, атомарна підміна, заміри затримки; скіл через rules/.
Після кожної фази: CHANGELOG, docs EN/UK, handoff `claude/handoff-pacenote-<ver>.md`.

## Відповіді власника (2026-11-03)
1. This week -> Settings > Usage (нова панель, ті самі числа + Insights).
2. Версія 0.9.0. Гілка `redesign/0.9.0` (перейменована після дозволу на видалення lock-файлів).
3. Prepare again під час дзвінка робимо і в скілі live-tips у цій самій ітерації (через rules/ + SKILL.md).
4. Приховані дзвінки: поточна поведінка (на входження, UserDefaults `calHidden`), додається Undo.
5. Перевірки фази 1: swift build + тести ядра + smoke GUI (скріни Home у 4 станах).

## Ще відкрито (до старту фази 1 або відповідної фази)
- Transcribe a recording: немає місця в макеті (пропозиція: пункт у меню біля "Start a call now").
- Таблиця "було -> стало" загалом: погодити пропозиції (live-банер, Overlaps, бейджі станів, Recent меню).
- Фаза 2: Agenda + Open questions у Summary, вкладка Sales, Follow-up email у шапці.
- Фаза 3: конфлікт з rules/decisions.yaml ("never to a register of Pacenote's own").

## Стартер для нового чату
"Продовжуємо редизайн Pacenote 0.9.0: гілка redesign/0.9.0, прочитай claude/handoff-pacenote-0.9.0.md фази 1-4 зроблені в коді, далі: живий дзвінок з Prepare now і заміри затримки, перевірка експорту і OpenAI-підготовки, потім pacenote-ship."

## Рішення власника, раунд 2 (2026-11-03)
1. rules/ не міняємо. Tracker читає те, що вже в Notion (локальне дзеркало синкає сторінки). Конфлікту з decisions.yaml немає.
2. Transcribe a recording у шапці поруч із пошуком і Start a call now (зроблено).
3. Past call: Agenda + Open questions у Summary, вкладка Sales для sales-дзвінків, Follow-up у шапці, CRM / Notion / Finder у "…" (фаза 2).
4. Live-банер, автостарт, Overlaps, стани Preparing / In line / Failed / Stale: розставлено (фаза 1).
5. "Runs on": має бути і **ChatGPT API (OpenAI API) для підготовки**, якщо нема, доробити. Ті самі опції для after-call (summary) і для live tips. Зараз OpenAI API є для tips і after, для preparation немає: **окремий пункт, фаза 2** (rules/ai.yaml + PrepRunner).
6. Дзвінок без проєкту: тека live у теці застосунку (зроблено, workspace "My calls").
7. Кольори за статусом, не за проєктом (зроблено: not ready помаранчевий, ready зелений, preparing синій, live червоний, recorded темно-синій, no transcript сірий).
8. Типи дзвінків без змін, Workshop не додаємо.

## Фаза 1: зроблено (не закомічено)
Файли: `HomeWindow.swift` (новий HomeView, CallState, StatePill, RecentCard, PastCallsView, TrackerView), нові `OnYouView.swift` (старий On you без змін логіки), `WeekSummary.swift` (This week), `HomeNav.swift` (маршрути pastCalls, tracker), `SettingsView.swift` (панелі Usage і Help, прибрано перемикач "Show this week on Home"), `CallSetup.swift` + `MenuBar.swift` (`useDefaultTargetIfEmpty`, підготовка "My calls" не читає теку застосунку), `LiveTipsCore/Projects.swift` (`defaultWorkspaceName`, `addDefaultWorkspace`), `ShotMode.swift` (набір p090), i18n en/uk (+57 ключів), CHANGELOG, docs 14.1m EN/UK.
Перевірки: swift build OK, CoreChecks 7195/0, feed tests 31/0, check_anonymized 0, smoke GUI: `~/work/Control Tower/private/tmp/shots-0.9.0/p090-*` (4 стани x 2 теми x en/uk + Settings Usage/Help).

### Поки тимчасово
- Назва дзвінка на Home відкриває форму Start call (setup), поки фаза 2 не дасть сторінку майбутнього дзвінка.
- Tracker у навігації показує старий On you (OnYouView), поки фаза 3. Перемикач модуля: `@AppStorage("moduleTracker")`, за замовчуванням увімкнено, UI в Settings > Modules у фазі 3.
- Workspace "My calls" має англійську назву і в UK (живе в Core без L10n).

### Пастки
- Збірка лише на Маці: `private/live-tips-app/queue/<n>-swiftbuild.job` (агент m0-host.sh), помилки: `swifterr`; знімки: `pyrun .../shots_090.py`.
- `claude/` не в .gitignore: не стейджити.
- `.git/stale-index-lock-1103` лишився від старої сесії, не мій, не чіпав.

## Раунд 3 (2026-11-03, вечір): фази 2-4 і правки власника

Власник: AI в Settings і онбордингу двома вкладками Claude / ChatGPT; ChatGPT API для підготовки; не готовий дзвінок помаранчевий (не коричневий); редизайн вікна в menu bar; "закінчуй все до кінця".

### Зроблено (не закомічено)
- **Кольори:** `PN.C.pending` (#C2410C, темна тема #FF9F45) для Not ready / Failed / No brief, пігулки інтеграцій і Overlaps.
- **AI:** Settings > AI, секція доступу з сегментами Claude (акаунт Claude Code, ключ Claude API) і ChatGPT (акаунт через Codex, ключ OpenAI API), футер на кожну вкладку; онбординг так само, кнопки "Use ChatGPT" (Codex) і "Use the OpenAI API" для всіх трьох робіт. RoutePicker підготовки тепер з OpenAI.
- **OpenAI API для підготовки:** `spikes/m0/livetips_m0/openaiprep.py` (той самий пакет і проходи, що codexprep; ключ лише в дочірній процес), `codexprep.Preparation` має `label` і `head_route`; PrepRunner: маршрут openai як packed, помилка без ключа, без автоперемикання. rules/ai.yaml оновлено. Тест `tests/test_openaiprep.py`.
- **Фаза 2:** `UpcomingCallPage.swift` (маршрут `.upcoming`, вкладки Setup / Brief / Tasks / Earlier calls, дії справа, Save-семантика через SetupSnap, питання при виході з незбереженим), `CallSetupMode.page` у CallSetup (3 питання + More settings + "Use for every ..." через SeriesMemory). Минулий дзвінок: вкладки Summary / Decisions / Tasks / Risks / Transcript (+ Sales), дії Ask about this call / Draft follow-up / Export / "…". `CallExport.swift`: CallNotes (секції notes.md) і ExportPanel (.docx через AppKit officeOpenXML, .md, Notion в Meetings DB, редагування перед експортом). "Add to Tracker" / "In Tracker" замість register.
- **Фаза 3:** `Tracker.swift`: дані з локального дзеркала Notion (`_notion/{tasks,decisions,risks}`) + локальні commitments, фільтри Workspace / Project / Call / Owner / Status / Find, групи, "Synced with Notion · ago" / "Kept on this Mac" з банером. Settings > Modules > Tracker (`moduleTracker`). New decision / New risk відкривають базу в Notion (або Settings без Notion).
- **Фаза 4:** `LivePrep.swift` + дія `liveprep` у Prompter, смужка брифу у вікні підказок (index.html `#briefBar`, tips.js `renderBriefBar`, feed.js `prepInfo`, tips.css), `CallEngine.adoptLatePrep` зберігає `<stem>.brief.prev.md` і шле "refresh context". Правило `rules/live_prep.yaml`, скіл: `skill/references/sweep.md` > "Prepare during the call".
- **Menu bar:** м'які пігулки, одна головна кнопка за правилом Home, назва відкриває сторінку дзвінка, "Start a call now".
- CHANGELOG, docs 14.1m EN/UK, README EN/UK (вкладки AI, OpenAI для підготовки).

### Перевірки
swift build OK, CoreChecks 7523/0, pytest 368 passed / 1 skipped (до openaiprep-тесту: перевірити, що він у прогоні), feed tests 31/0, gen_skill_section --check OK, check_anonymized 0. Smoke GUI: `~/work/Control Tower/private/tmp/shots-0.9.0/` (p090-*, settings-*, menubar-panel-*).

### Не перевірено / ризики
- Живий дзвінок з Prepare now: затримка підказок до і під час підготовки **не заміряна** (вимога промпту, лишилось).
- Експорт у Notion і .docx на реальних даних не проганявся; Notion-сторінка без властивостей Project / Workspace (лише назва і дата).
- OpenAI-підготовка: не проганялась наживо з ключем; витрати в SpendLedger за цим маршрутом не перевірені.
- Tracker сканує всю `workRoot` до глибини 6: на великій теці може бути повільним (у фоні); New decision / risk не створює рядок у Pacenote.
- SKILL.md (скіл у Cowork) не переустановлено; зміна лише в репо `skill/references/sweep.md`.
- OnYouView.swift лишився в коді без використання (стара логіка On you, Notion trash). Видалити після погодження.

## Коміт і пуш (2026-11-03)
`5e2d364` на `redesign/0.9.0`, запушено в origin. Останні правки центрування зібрані, але не перезняті.
