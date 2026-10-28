# Pacenote 0.8: редизайн і ребрендинг. Специфікація для реалізації

Цей документ - єдине джерело правди для редизайну 0.8 і перейменування Live Tips на Pacenote. Його читає Cowork / Claude Code і реалізує фазами з розділу 11. Візуальні макети лежать на полотні «Live Tips redesign» (Design artifact): рядки «Pacenote · бренд і екрани» та «Pacenote · логотип і menu bar» - актуальний бренд, усе, що вище, - макети розкладки (на них ще стара назва, бренд-шар береться з цього документа).

Склад пакета:

| Шлях | Що це |
|---|---|
| `REDESIGN-SPEC.md` | цей документ |
| `COWORK-PROMPT.md` | готовий промпт для Cowork, по фазах |
| `BRAND.md` | brand notes: ідея, кольори, поле, розміри, так / ні |
| `brand/` | іконка (майстри + `AppIcon.appiconset`), menu bar template (SVG, PDF, PNG), символ, вордмарк, lockup-и, favicon |
| `strings/rebrand-strings.md`, `.csv` | таблиця всіх рядків, що змінюються: key, old EN, new EN, new UK |
| `tokens/tokens.css` | кольори, відступи, радіуси для веб-частини (світла і темна тема) |
| `swift/PacenoteTheme.swift` | ті самі токени для SwiftUI, 3 стилі кнопок, бейдж статусу |
| `swift/MenuBarPanel.swift` | скелет нової панелі з menu bar (`MenuBarExtra`, стиль `.window`) |
| `tips-window/` | робоча референсна реалізація вікна підказок (Concept A) зі станами Ready і Listening: `index.html`, `tips.css`, `tips.js`, `tokens.css`. Відкривається в браузері з демо-даними: `?theme=dark`, `?lang=uk`, `?state=ready`, `?state=empty`, `?mode=compact`, `?mode=presentation`, `?left=4` |

Мова інтерфейсу: англійська і українська. Ніде в текстах інтерфейсу немає довгого тире, лише дефіс, кома або крапка.

---

## 0. Ребрендинг: Live Tips → Pacenote

- Нова назва **Pacenote**, tagline `Your co-driver on calls` / `Ваш штурман на дзвінках`. Деталі в `BRAND.md`.
- **Не змінюємо** (поза скоупом): bundle identifier (інакше macOS скине дозволи на мікрофон і запис екрана), імена файлів і папок, CLI, ключі конфігів, формат локального індексу (`.livetips-index/`), імена скілів у Cowork, `live-transcriber`. Імʼя `.app`-файлу і репозиторію - окреме рішення, не в цій задачі.
- Міняємо лише те, що бачить користувач: назву, іконку, тексти, бренд-шар (розділ 9).
- Скіл `live-tips` і застосунок мають поводитися функціонально однаково (спільні `rules/`): якщо зміна торкається поведінки, а не лише тексту, вона йде через спільні правила.

## 1. Принципи

1. **Одне питання на екран.** Вікно підказок відповідає на «що мені сказати або зробити зараз». Home - на «що далі і чи я готовий». Усе інше доступне, але не на першому плані.
2. **Читається за 1-2 секунди.** Найважливіше - найбільшим шрифтом, решта згортається в один рядок. Службові дані (секунди, джерела, дії) - тихо або на hover.
3. **Стан замість кнопок.** Рядок показує статус і одну дію, що з нього випливає. Не три однакові кнопки на кожному рядку.
4. **Людська мова.** Жодних рядків як із логів («from the call picture, unchecked», «Meeting type = Presentation: sent»). Технічні деталі - у тултіп або лог.
5. **Нічого не відправляємо самі.** Листи і Notion-сторінки, які йдуть назовні, апка лише готує як чернетку. Відправляє користувач.

## 2. Дизайн-система

Токени: `tokens/tokens.css` (веб) і `swift/PacenoteTheme.swift` (SwiftUI, простір імен `PN`). Значення в обох файлах однакові, міняти лише парою.

**Кольори.** Фон вікна `bg`, картки `surface`, текст у трьох рівнях `text`, `text-2`, `text-3`. `text-3` - найсвітліший дозволений сірий: 5.1:1 у світлій темі, не темніше `#98989D` на `#2C2C2E` у темній. Акцент для тексту `accent` (Blue Deep #0058B0 / Blue Light #4D9DFF), для заливки кнопки `accent-fill` (Pacenote Blue #0A6CFF, білий текст 4.6:1), для графіки `brand`. Червоний - лише запис і End call.

**Типи подій** (картки, рядки, бейджі) кодуються текстовим лейблом UPPERCASE 11 px + кольором, ніколи лише кольором:

| Тип | Лейбл EN / UK | Токен |
|---|---|---|
| Відповідь на питання | ANSWER / ВІДПОВІДЬ | `k-answer` (синій) |
| Твоя черга | YOUR TURN / ТВОЯ ЧЕРГА | `k-turn` (зелений) |
| На мені | ON ME / НА МЕНІ | `k-onme` (помаранчевий) |
| З документів | FROM DOCS / З ДОКУМЕНТІВ | `k-docs` (фіолетовий) |
| N хв лишилось | N MIN LEFT / N ХВ ЛИШИЛОСЬ | `k-onme` |
| Відповіли | ANSWERED / ВІДПОВІЛИ | `k-answer`, рядок 60% прозорості |

**Кнопки - рівно три рівні** (`PNPrimaryButtonStyle`, `PNSecondaryButtonStyle`, `PNTertiaryButtonStyle`, у коді `.pnPrimary` / `.pnSecondary` / `.pnTertiary`):
- Primary: заливка, одна на вікно, прив'язана до Return.
- Secondary: з рамкою, нейтральна.
- Tertiary: текст кольору акценту без фону, для дій у рядках.
- Радіус 6-7 px, висота 32 px (28 для tertiary). Капсул немає. Деструктивні дії - лише в меню або з підтвердженням.

**Заборонено:** емодзі як іконки, кольорові ліві смуги на картках, градієнтні фони, текст менше 12 px, сірий нижче 4.5:1, текстові посилання як основна дія вікна.

**Довжина текстів.** Під українську закладати +30% ширини. Лейбли не обрізаються, а переносяться. Перевіряти кожен екран з `uk`.

**Іконки** - SF Symbols у SwiftUI, у веб-вікні - inline SVG 1.3-1.5 px stroke.

## 3. Вікно підказок (Concept A, Focus)

Референсна реалізація: `tips-window/`. Її можна підключити до WKWebView майже як є: замінити поточну сторінку, прив'язати міст (див. 3.9). Макети: артборди «Concept A · Focus · narrow, dark» і «... wide, light», «Concept C · Glance strip» (компактний режим).

### 3.1 Структура зверху вниз

1. **Нативний заголовок вікна:** назва дзвінка по центру, `End call` праворуч (червоний тонований). Пін і інші іконки з заголовка прибрати.
2. **Смуга 48 px:** червона крапка запису, таймер `32:14`, статус (`Listening` / `Paused` / `Mic off`), кнопка `On me N` (ховається, коли N = 0), три кнопки керування дзвінком, меню `⋯`. Більше нічого.
   - **Кнопки керування** (оновлено 2026-10-28 за досвідом користування: пауза, мікрофон і proactive tips потрібні за секунду і їхній стан має бути видно, тому вони не в меню). Три іконки 28 px праворуч від `On me`, перед `⋯`, у такому порядку: мікрофон, пауза, лампочка (proactive tips).
   - **Стан з першого погляду:** вимкнений мікрофон - перекреслена іконка червоним (`danger`); пауза - крапка запису і таймер сіріють, а кнопка стає помітною primary-кнопкою `▶ Resume` (`Продовжити`); proactive tips увімкнені - лампочка на тонованому синьому фоні (`accent-soft`, колір `accent`).
   - **Доступність:** кожна кнопка має тултіп з гарячою клавішею (`Turn mic off (⌃⌥M)`, `Pause listening (⌃⌥P)`, `Proactive tips: off`), `aria-label` і `aria-pressed` (мікрофон: pressed = вимкнено; пауза: pressed = на паузі; лампочка: pressed = увімкнено). Підписи клавіш беруться з фактичних налаштувань (`setState({keys: {mute, pause, proactive}})`), а не літералом. Для proactive tips гаряча клавіша поки не задана, тултіп без неї.
3. **Агенда:** сегменти за кількістю пунктів брифу (done - зелений, now - синій, todo - сірий) і підпис `Agenda 2 of 3 · <поточний>` + праворуч `Not raised: <перший todo> +N`. Ховається, якщо в брифі немає агенди.
4. **Героїня-картка:** лейбл типу, хто/коли, питання (15 px, `text-2`), фраза «що сказати» (22 px semibold у вузькому, 24 px у широкому), джерело одним рядком з іконкою документа, тихі дії `Said it`, `Shorter`, `Pin`, `Hide`.
5. **Earlier:** однорядкові рядки `ЛЕЙБЛ | текст | 2m`. Клік по рядку робить його героєм (Esc повертає). На hover замість часу - `Pin`, `Hide`.
6. **Наступний дзвінок:** лише якщо до нього ≤ 10 хв: `Team retro in 8 min · not prepared` + `Prepare` (або `brief ready` + `Open`).
7. **Поле питання + Help:** `Ask about this project` і синя кнопка `Help ⌃⌥H`. Help більше не червоний.

### 3.2 Правило вибору героя (порядок важливий)

1. Закріплена (pinned) активна картка.
2. Активна ANSWER або YOUR TURN, що прийшла менше 90 с тому.
3. Картка «N min left», якщо до кінця ≤ 5 хв (див. 3.4).
4. Найновіша активна картка дії (answer, turn).
5. Найновіша будь-яка активна.

Відповідь, на яку користувач натиснув `Said it` або яку система розпізнала як сказану, стає `done`: гасне і йде в Earlier з лейблом ANSWERED. `Call summary` більше не картка посеред дзвінка (див. 3.5).

### 3.3 Вузький і широкий режим

- Брейкпоінт - ширина вікна 760 px (container query в `tips.css`).
- < 760: одна колонка. `On me`, Transcript і Brief відкриваються як sheet поверх вікна (кнопка `On me` або пункт меню).
- ≥ 760: праворуч панель `min(40%, 420px)` з сегментованим контролом `Transcript | On me · N | Brief`.
- < 460: `On me` показує лише лічильник (з `aria-label` `On me: N`), щоб мікрофон, пауза, лампочка і `⋯` завжди вміщались.
- < 400: ховається слово статусу і хінт гарячої клавіші в Help.
- У стані Ready (до старту) кнопки керування сховані.
- Режим «вікно з панеллю підготовки зліва» (`tips-prep-pane`) замінюється вкладкою Brief у правій панелі.

### 3.4 Агенда і фініш (ідея 02 частково)

- Пункти агенди беруться з брифу (секція Checklist / агенда). Стан кожного: `todo` → `now` (про нього говорять) → `done` (обговорено / вирішено). Визначає класифікатор, що вже бачить транскрипт; користувач може клікнути сегмент і змінити стан вручну.
- Коли `minutesLeft ≤ 5` (з календаря або заданої тривалості), зʼявляється картка `5 MIN LEFT`: питання = `Not raised: <todo пункти>` або `All agenda items raised`, фраза = `Recap: <рішення і хто що робить>` для підсумку вголос.

### 3.5 Підсумок дзвінка

Картку `Call summary` прибрати зі стрічки. Підсумок збирається тихо і видно:
- у вкладці On me (обіцянки),
- у картці `N MIN LEFT` (recap),
- після End call - у вікні підсумку перед записом у Notion.

### 3.6 Спікери

- Блок `Speakers` над транскриптом прибрати.
- Невідомий голос: у панелі транскрипту зверху банер `New voice: Speaker 3` + `Name`.
- Клік по будь-якому імені в транскрипті відкриває поповер: поле імені + сегмент `Client | Team` + `Save`. Відправляє `name-speaker`.
- `Clear speakers` - у меню `⋯` як `Forget speaker names`.
- `Follow` - автоматичний: транскрипт слідкує, поки користувач унизу; прокрутив вгору - у футері `Jump to latest`.

### 3.7 Меню `⋯`

`Compact mode ⌃⌥T`, `Presentation mode`, `Transcript`, `Brief`, роздільник, `Forget speaker names`, `Switch to next call…`, `Call settings… ⌘,`.

Пауза і мікрофон у меню більше не дублюються: вони в смузі (3.1). Proactive tips теж у смузі, а в `Call settings…` лишається лише значення за замовчуванням для нових дзвінків.

Поточний великий лист налаштувань (`tips-menu`: Type, Audience, Language, Mic, Up next, Display) переїжджає у `Call settings…` як окреме нативне вікно-шит. Розмір тексту - `⌘+` / `⌘-` без слайдера.

### 3.8 Компактний режим (Concept C як режим вікна A)

- `⌃⌥T` або пункт меню. Вікно стає смугою ~560 × 48-140 px, завжди зверху.
- Видно лише смугу (запис, таймер, On me) і героїню без питання, джерела і дій, фраза 19 px.
- Стани: тиша (лише смуга), питання (виростає), твоя черга, фініш. Hover або повторний `⌃⌥T` - назад у повне вікно.
- Нативно: змінити розмір NSWindow, рівень `.floating`, `sharingType = .none` (вікно не потрапляє в демонстрацію екрана, як і зараз).

### 3.9 Режим презентації

- Замість героя - блок кроку: `1 / 3`, великий таймер кроку (червоний, коли перебрав), назва кроку, текст, `Can skip if short on time` для кроків, які можна пропустити, `Next: <назва> (2:00)`, кнопки `Back` і `Next`/`Start`.
- Налаштування презентації (Auto, Trim, дзвіночок, джерело слайдів, загальна тривалість) - у поповері перед стартом, не на панелі.
- Пунктирний банер `Meeting type = Presentation: sent, waiting for confirmation...` прибрати. Під час перемикання - статус у смузі `Switching to presentation…`.
- Earlier під час презентації показує лише питання з залу.

### 3.10 Міст Swift ↔ веб (контракт)

Native → web (через `evaluateJavaScript`):

```js
window.LiveTips.setState({ ...partial })  // поверхневе злиття; call і speakers зливаються, масиви замінюються
window.LiveTips.setLang('en' | 'uk')
window.LiveTips.setTheme('auto' | 'light' | 'dark')
```

Форма стану:

```js
{
  call: { title, startedAt /*ms*/, paused, micOff, proactive, minutesLeft /*int|null*/, mode: 'normal'|'compact'|'presentation', recap /*string*/ },
  agenda: [{ id, title, state: 'todo'|'now'|'done' }],
  cards: [{ id, kind: 'answer'|'turn'|'onme'|'docs'|'neutral', who, question, say, source, at /*ms*/, state: 'active'|'done'|'hidden', pinned }],
  onMe: [{ id, text, due, done }],
  next: { title, startsInMin, prepared } | null,
  speakers: { [speakerId]: { name, side: 'client'|'team', label } },
  transcript: [{ speakerId, text }],
  brief: { goal, sections: [{ title, items: [string] }] },
  presentation: { index, running, elapsedInStep, steps: [{ title, say, secs, canSkip }] },
  keys: { mute, pause, proactive }   // actual shortcut labels for tooltips, e.g. '⌃⌥M'
}
```

Web → native (`window.webkit.messageHandlers.liveTips.postMessage`), поле `action`:

| action | payload | що робить нативна частина |
|---|---|---|
| `said` | `id` | позначає картку сказаною (для статистики і рейтингу підказок) |
| `shorter` | `id` | просить Claude скоротити фразу, повертає оновлену картку |
| `pin` | `id, pinned` | |
| `hide` | `id` | |
| `help` | | HELP NOW |
| `ask` | `text` | пошук/питання по проєкту, результат приходить карткою |
| `onme-toggle` | `id, done` | оновлює реєстр обіцянок (ідея 01) |
| `name-speaker` | `speakerId, name, side` | зберігає голос |
| `prepare-next`, `open-next` | | |
| `present-next`, `present-prev` | | |
| `mute` | `micOff` | вмикає або вимикає мікрофон (кнопка в смузі, ⌃⌥M) |
| `pause` | `paused` | пауза або продовження прослуховування (кнопка в смузі, ⌃⌥P) |
| `proactive` | `on` | proactive tips для цього дзвінка (лампочка в смузі) |
| `menu` | `item, mode` | `compact`, `present`, `transcript`, `brief`, `clear-speakers`, `switch-call`, `settings` |

Гарячі клавіші глобальні, реєструються нативно: `⌃⌥H` Help, `⌃⌥P` пауза, `⌃⌥M` мікрофон, `⌃⌥T` компактний режим.

### 3.11 Копірайтинг: було → стало

| Було | Стало |
|---|---|
| `Not said from the speech: Blocker: test accounts from the client` | `Not raised yet: test accounts from the client` |
| `You: find: pilot users` | лейбл `FROM DOCS`, meta `You searched: pilot users` |
| `export release plan · Dana · yours` | прибрати (це дублює героя) |
| `from the call picture, unchecked` | прибрати; якщо потрібно - тултіп `Not verified against documents` |
| `10:34:00` | `3m` / `3 хв` |
| `Meeting type = Presentation: sent, waiting for confirmation...` | `Switching to presentation…` |
| `Next call: Team retro · 13:00 · no preparation` + `Switch...` | `Team retro in 8 min · not prepared` + `Prepare` (лише ≤ 10 хв) |
| `Help` (червоний) | `Help ⌃⌥H` (синій) |
| `Clear speakers`, `Follow` | меню / автоматично |

### 3.12 Критерії приймання

- [ ] Від верху вікна до фрази героя ≤ 170 px у вузькому режимі.
- [ ] Мікрофон, пауза і proactive tips у смузі на 380, 440 і 1000 px; стан кожної кнопки видно без наведення; тултіпи з фактичними гарячими клавішами; `aria-pressed` міняється разом зі станом.
- [ ] Жодного емодзі і жодної лівої кольорової смуги у вікні.
- [ ] 380, 560, 1000 px: нічого не обрізається, в `uk` теж.
- [ ] Світла і темна тема з `tokens.css`, перемикання без перезавантаження.
- [ ] Відповіла картка за ≤ 1 с переходить у Earlier з ANSWERED.
- [ ] Картка `N MIN LEFT` зʼявляється за 5 хв і не перебиває свіже питання.
- [ ] Компактний режим працює з гарячої клавіші і не видно в screen share.

## 4. Home

Макет: артборд «Home · Up next · light».

### 4.1 Структура

- **Тулбар:** `Today` + `Wednesday, 28 October · 4 calls, 2 h 15 min`; праворуч `Plan a call` (secondary) і `Start call` (primary).
- **Ліва колонка:**
  1. **Up next** - велика картка найближчого дзвінка (або поточного, якщо дзвінок іде: тоді бейдж `Live · 32:14` і кнопка `Show tips`). Назва 26 px, проєкт, учасники, платформа.
  2. **Are you ready?** - список перевірок (4.2) і загальний висновок праворуч (`Ready` / `Mostly · 1 thing to do` / `Not prepared`).
  3. Кнопки: `Start tips for this call` (primary), `Edit setup` (secondary).
  4. **Later** - решта дзвінків сьогодні і найближчі дні, рядок: час | назва + проєкт + учасники | бейдж стану + одна дія.
- **Права колонка (360 px):** `On you` (ідея 01), `This week`, `Recent`.
- **Рядок стану внизу:** `Claude connected`, `Notion synced`, `3 calendars` з крапками-індикаторами. Червона крапка і текст проблеми лише коли щось не так. Ліміт витрат і баланс - у Settings › AI, на Home лише попередження, якщо ліміт близько.

### 4.2 Перевірки готовності

Кожна перевірка - рядок: іконка-статус, текст, підтекст, одна tertiary-дія.

| Перевірка | Джерело | Дія |
|---|---|---|
| `Brief ready · updated 09:40 · goal, 3 agenda items, 1 risk` | файл брифу | `Open brief` |
| `Brief is 2 days old · 3 changes since` (ідея 03) | дата брифу vs зміни в проєкті | `Refresh` |
| `No brief yet` | | `Prepare` |
| `On you, still open: <обіцянка>` | реєстр обіцянок (ідея 01), лише цей проєкт | `Mark done` |
| `N questions left open last time` | підсумок попереднього дзвінка серії | - |
| `Overlaps with <інший дзвінок>` | календар | `Skip <інший>` (ховає його з Home, нічого не міняє в календарі) |

### 4.3 Стан → одна дія (рядки Later і Up next)

| Стан | Бейдж | Дія |
|---|---|---|
| бриф відсутній | `Not prepared` (помаранчевий) | `Prepare` |
| готується | `Preparing…` (сірий, спінер) | `Cancel` у контекстному меню |
| бриф свіжий | `Ready` (зелений) | `Open` |
| бриф застарів (ідея 03) | `Brief 3 days old` (сірий) | `Refresh` |
| дзвінок іде | `Live` (червоний) | `Show tips` |

Решта дій (`Set up…`, приховати подію, показати в календарі) - у контекстному меню рядка (правий клік і кнопка `⋯` на hover).

### 4.4 Права колонка

- **On you:** обіцянки з усіх дзвінків, незакриті, сортування: прострочені → з датою → решта. Чекбокс закриває. Підпис: проєкт · коли пообіцяв. Клік відкриває дзвінок у момент обіцянки (ідея 05).
- **This week:** три числа (`calls`, `on calls`, `prepared X of Y`) і міні-гістограма Пн-Пт. Без доларів. `Details` відкриває повну статистику (ідея 07) з фільтрами тиждень/проєкт, які зараз стоять на Home.
- **Recent:** назва, дата, результат: `2 decisions · 1 on you · 1 open question`. Клік - сторінка дзвінка з підсумком. Файлові дії (Notion, Transcript, Show in Finder) - у контекстному меню.
- Налаштування «Show this week's numbers on Home» лишається і ховає блок This week.

## 5. Налаштування дзвінка: одна форма замість трьох

`Prepare`, `Start call` і `Plan an upcoming call` → один `CallSetupView` з параметром режиму.

Завжди видно:
1. Проєкт (picker з іконкою папки).
2. Назва дзвінка.
3. Дата і час; праворуч підказка з календаря `From calendar: Orbit weekly, 12:18`.
4. `What matters on this call` - поле з плейсхолдером-шаблоном (`Goal:`, `Participants:`, `Open questions:`, `Where to look:`). Під полем - чіпи доданих папок/файлів і `Add folder or file`.
5. Статус підготовки одним рядком: `No brief yet` / `Brief ready · 09:40` / `Brief 2 days old` + дія.

Під розкриттям `Options` (з лейблами!): `Audience` (Auto / Client / Team), `Call type` (Regular / Presentation / Interview…), `Language`, `Mic`, `Proactive tips` (тогл з одним рядком пояснення).

Кнопки внизу за режимом:
- Prepare: primary `Prepare`, secondary `Cancel`.
- Start: primary `Start call`, secondary `Prepare first`, tertiary `Save for later`.
- Plan (під час дзвінка): primary `Save`, secondary `Switch to this call…` (з підтвердженням: поточний дзвінок завершиться і збережеться).

Прибрати: криптичний рядок `Team 2 · client 2 · Claude tips on · first call here · no Notion mirror` (замінити на зрозумілі підказки лише там, де щось не так, наприклад `Notion is not set up, the summary stays in the project folder`), довгі абзаци пояснень (в `(i)`).

## 6. Документ підготовки (prep-doc)

- Рендерити markdown з чекбоксами як справжні `Toggle`/чекбокси. Стан чекбоксів = стан агенди у вікні підказок (одне джерело).
- Редагування inline (клік по блоку), без окремого режиму `Edit`. `Show in Finder` - у меню `⋯`.
- Заголовок: назва дзвінка + `Prepared 09:40 · for 12:18` (виправити розбіжність часу на кшталт `prep, today 11:00` для дзвінка о 12:19).

## 7. Перший запуск і онбординг

Макети: «First launch · dark», «First launch · light», «Logo · app icon».

1. **Splash (новий):** іконка 144 px, вордмарк Pacenote 40 px заввишки (з `brand/wordmark`), tagline `Your co-driver on calls`, primary `Get started`, підпис `Setup takes about 3 minutes`, внизу `Audio never leaves your Mac · Pacenote 0.8`. Світла і темна тема. Без кнопки Skip. Макети: «1. Splash · dark / light».
2. **Permissions:** мікрофон, системне аудіо, календарі (optional) - як зараз, але з одним поясненням.
3. **Work folder and projects:** вибір папки + список знайдених проєктів з чекбоксами (зараз це два кроки, злити в один).
4. **Connect Claude:** ключ або Claude account, `Continue without a key` - tertiary.
5. **Done:** `Start a demo call` (primary) - відкриває вікно підказок на демо-даних, `Go to Home` (secondary).

Установка моделей (Python, Whisper, bge-m3) іде **у фоні** з першого кроку: один прогрес у футері онбордингу `Getting speech recognition ready · 1.2 of 2.5 GB`. Технічний список компонентів - лише в `Settings › About › Components` і в разі помилки.

Відкладені кроки (імʼя на дзвінках, Notion, календарі, якщо пропущені) - картки `Finish setup` вгорі Home, поки не зроблено. Чекліст `Get ready for the first call` з Settings › General і About прибрати.

## 8. Settings

- **General:** прибрати чекліст. `Work folder` - як Path Control з іконкою і `Change…`. `Your name on calls` - поле з плейсхолдером `e.g. Alex, Alexander, Sasha`.
- **Keys:** кожен ключ - поле (SecureField) + статус `Connected ✓` / `Not set` + одна кнопка `Replace` / `Remove` у меню. Три іконки без підписів прибрати.
- **Projects:** без змін логіки, кнопки за 3 рівнями.
- **Calendars:** нумеровані кроки лишити, але згорнути `1. Your accounts`, якщо акаунти вже є.
- **Notion:** токен як у Keys; `Write a meeting page after each call` - головний тогл зверху.
- **AI:** сюди переїжджають витрати місяця, ліміти, баланс.
- **How it works:** прибрати з налаштувань; лінк `How Pacenote works` у меню Help (веб-сторінка або окреме вікно).
- **About:** версія, `Your data` текст, лінки; новий розділ `Components` (технічний статус установки).

## 9. Бренд Pacenote: де він зʼявляється

Усі ассети в `brand/`, правила в `BRAND.md`, рядки в `strings/rebrand-strings.md`.

| # | Місце | Що зробити | Макет |
|---|---|---|---|
| 1 | Splash | розділ 7, пункт 1 | «1. Splash · dark / light» |
| 2 | Онбординг | заголовок вікна `Pacenote setup`, символ над заголовком кроку, `Let Pacenote hear your calls`, фінал `Pacenote is ready` з іконкою 112 px і підказкою про значок у menu bar, кнопки `Try a demo call` / `Go to Home`. Усі тексти онбордингу з «Pacenote» - за таблицею рядків | «2. Onboarding · brand layer» |
| 3 | Вікно підказок | нативний заголовок: білий/чорний символ 14 px + назва дзвінка (без «Pacenote:»); стан Ready до старту (символ, `Ready when you are`, рядок брифу, `Start listening`, `Open brief`, `Audio stays on this Mac`); стан Listening без карток (символ у кільці, що повільно «дихає», `Listening`, підказка про ⌃⌥H; без анімації при Reduce Motion). Реалізовано в `tips-window/` (`call.state: 'ready'|'live'`, `call.startsAt`, `call.briefLine`, дії `start`, `open-brief`) | «3. Tips window · brand, empty, listening» |
| 4 | Menu bar | значок `PacenoteTemplate` (очікування), `PacenoteRecordingTemplate` + таймер (запис), панель з розділу 9a | «4. Menu bar panel» |
| 5 | Settings › About | іконка 88 px, вордмарк, tagline, `Version {version} ({build}) · macOS {os}`, `Check for updates`, блок Your data, Components, рядок `Formerly Live Tips. Your calls, folders and permissions carry over.` Заголовок вікна `About Pacenote` | «5. Settings · About» |
| 6 | Сторінка в Notion | футер останнім блоком: роздільник + `Notes by Pacenote · transcribed on device` (UK: `Нотатки Pacenote · транскрибовано на пристрої`, мовою сторінки). Назва сторінки без префікса продукту | «6. Notion summary page» |
| 7 | Продуктова сторінка | hero: lockup у навігації, eyebrow, H1 = tagline, підзаголовок, `Download for Mac`, `See how it works`, футнот; favicon з `brand/favicon`, `<title>Pacenote - Your co-driver on calls</title>`. Сторінка зараз живе за адресою продукту Live Tips; адреса - окреме рішення | «7. Product page hero» |

Також:
- `Assets.xcassets/AppIcon` замінити на `brand/icon/AppIcon.appiconset` повністю.
- `Info.plist`: `CFBundleDisplayName` і `CFBundleName` = `Pacenote`, тексти дозволів (мікрофон, системне аудіо, календарі) за таблицею рядків, `LSHasLocalizedDisplayName` = YES, якщо додаємо українську локалізацію `InfoPlist.strings`.
- Сповіщення, тултіпи, назви вікон: «Live Tips» → «Pacenote».

### 9a. Панель з menu bar замість системного меню

Системне `NSMenu` малює фон саме (на macOS 26 сірий Liquid Glass), стилізувати можна лише пункти. Тому меню замінюємо на `MenuBarExtra { MenuBarPanel(...) }.menuBarExtraStyle(.window)`. Скелет: `swift/MenuBarPanel.swift`.

Без дзвінка (ширина 340): шапка (символ, `Pacenote`, `· not recording`, шестерня Settings), картка Up next з бейджем готовності і `Start tips` / `Open brief` або `Prepare`, до двох наступних дзвінків з бейджами, `Open Home ⌘0`, `Start a call… ⌘N`, витрати за місяць тонкою смугою + рядок останнього дзвінка, футер `Help and About ▸` (Setup…, Welcome tour, About Pacenote) і `Quit Pacenote ⌘Q`.

Під час дзвінка: шапка `Recording · 32:14`, картка дзвінка з рядком агенди і `Show tips` / `Pause` / `End call`, «On me», наступний дзвінок з `Prepare`, `Help now ⌃⌥H`, `Compact tips ⌃⌥T`, `This call $0.21`.

Гарячі клавіші з меню (⌘0, ⌘N, ⌘,, ⌘Q) лишаються глобальними командами застосунку (`.commands` / `NSApp.mainMenu`).

## 10. Нові функції

Ідея «автопідготовка на ніч» **не робимо**: за ніч усе змінюється, різні часові пояси. Замість неї - «Свіжість брифу» (03).

### 01. Реєстр обіцянок
- Що: усі `On me` / `On them` з усіх дзвінків в одному сховищі (`commitments.json` у робочій папці або SQLite).
- Поля: id, text, owner (me / імʼя), projectId, callId, transcript offset, createdAt, due (якщо названо), status (open/done), doneAt, doneSource (manual / detected on call).
- Автозакриття: якщо на наступному дзвінку серії прозвучало «done/sent/зроблено» про цей пункт - класифікатор пропонує закрити; у вікні підказок тиха картка `ON ME · Done? Send the test account list` з кнопкою `Mark done`.
- Jira в апці немає і не буде (рішення продукту). Експорт - лише `Copy` пункту як тексту.
- UI: Home › On you, вкладка On me у вікні підказок, сторінка дзвінка.

### 02. Агенда як контракт
- Див. 3.4. Додатково: після дзвінка в підсумку Notion - розділ `Agenda` зі статусами пунктів; непідняті пункти автоматично пропонуються в `What matters` наступного дзвінка серії.

### 03. Свіжість брифу (замість нічної автопідготовки)
- Бриф зберігає `preparedAt` і зліпок джерел (хеші/mtime файлів проєкту, останній id задачі, події календаря).
- Home і форма дзвінка порівнюють зліпок з поточним станом: якщо є зміни - `Brief is 2 days old · 3 changes since` + `Refresh`.
- `Refresh` - інкрементальне оновлення: Claude отримує старий бриф + diff джерел і оновлює лише змінені секції. Ніколи не запускається сам.

### 04. Драфт follow-up листа
- Після End call у вікні підсумку кнопка `Draft follow-up email`.
- Мова листа - мова клієнта з конфігу проєкту (за замовчуванням англійська). Структура: подяка одним рядком, рішення, хто що робить і до коли, відкриті питання.
- Виводиться в редагованому полі + `Copy`, `Open in Mail` (mailto з тілом). Нічого не відправляє.

### 05. Пам'ять дзвінків
- Поле пошуку на Home (`⌘F`) і поле `Ask about this project` у вікні підказок: питання природною мовою по всіх транскриптах і підсумках проєкту.
- Відповідь: 1-2 речення + цитата + `Jump to 12:34` (відкриває транскрипт дзвінка на цьому місці).
- Індекс: наявний локальний bge-m3 по транскриптах, Claude формулює відповідь.

### 06. Серія як сторінка
- Дзвінки з однаковою (проєкт + назва) - серія (вже є логіка «Regular calls remembered»).
- Сторінка серії: таймлайн рішень, обіцянки серії, питання, що висять N дзвінків поспіль (`open for 3 weeks`), що змінилось з минулого разу.
- Відкривається з Recent і з Up next (`Series: 6 calls`).

### 07. Корисна статистика
- На сторінці `Details`: частка часу, коли говорив PM; питання клієнта без відповіді; дзвінки без жодного рішення; дзвінки з підготовкою vs без.
- Долари - лише в Settings › AI.

### 08. Автостарт за календарем
- Коли запущено Zoom / Google Meet (вкладка браузера) / Teams і в календарі зараз подія ±5 хв: тиха нотифікація або банер на Home `Start tips for Orbit weekly?` з проєктом, вибраним за минулими дзвінками серії.
- Ніколи не починає запис сам. Налаштування `Suggest starting tips when a call begins` (за замовчуванням увімкнено).

### 09. Ризики з розмови
- Класифікатор ловить умовні загрози («if X then Y slips», «we might not make…»).
- Під час дзвінка - тиха картка `RISK` (колір `k-onme`), в Earlier.
- Після дзвінка - секція `Risks` у підсумку; дія `Add to risk register` (Notion база ризиків проєкту, якщо налаштована) - лише з підтвердженням.

### 10. Репетиція презентації
- З Home або форми дзвінка: `Rehearse` для дзвінка типу Presentation.
- Вікно підказок у режимі презентації без запису дзвінка; таймер по кроках; наприкінці 3-4 складні питання від Claude в ролі клієнта на основі брифу; користувач відповідає голосом, отримує коротку оцінку.

## 11. Фази впровадження

Кожна фаза закінчується робочою апкою, новими скрінами на демо-даних (обидві теми, `en` і `uk`) і коротким changelog.

| Фаза | Скоуп | Залежить від |
|---|---|---|
| **F0. Ребрендинг** | розділ 0 і 9: іконка, menu bar значки, Info.plist, усі рядки з `strings/`, splash, About, футер Notion | - |
| **F1. Фундамент** | токени (`PacenoteTheme.swift`), 3 стилі кнопок і бейдж по всій апці, контраст і мін. 12 px, панель menu bar (9a) | F0 |
| **F2. Вікно підказок** | розділ 3 повністю: нова сторінка з `tips-window/`, міст, меню, спікери inline, компактний режим, презентація, гарячі клавіші, копірайтинг | F1 |
| **F3. Home** | розділ 4 (без ідей 01, 03, 07 - для них заглушки з наявних даних) | F1 |
| **F4. Форми і онбординг** | розділи 5, 6, 7, 8 + Splash | F1 |
| **F5. Ядро ідей** | 02 агенда, 01 реєстр обіцянок, 03 свіжість брифу, 08 автостарт | F2, F3 |
| **F6. Розширення** | 04 follow-up, 05 памʼять, 06 серії, 07 статистика, 09 ризики, 10 репетиція | F5 |

## 12. Перевірка перед кожним релізом

- [ ] Усі 54+ скрінів перегенеровані: світла і темна тема.
- [ ] Ті самі скріни з `uk`: нічого не обрізано.
- [ ] Вікно підказок: 380, 560, 1000 px.
- [ ] Жодного довгого тире (U+2014) у рядках інтерфейсу: `grep -rn $'\u2014' <локалізації і sources>` порожній.
- [ ] Жодного емодзі в UI-рядках.
- [ ] VoiceOver: усі icon-only кнопки мають label.
- [ ] Нічого не відправляється назовні без дії користувача.
