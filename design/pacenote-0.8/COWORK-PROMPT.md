# Промпт для Cowork: Pacenote 0.8

Пакет уже лежить у репозиторії: `~/work/live-tips/design/pacenote-0.8/`.

Як користуватися:

1. У Cowork підключи папку `~/work/live-tips` (і більше нічого).
2. Встав блок «Старт». Після погодження плану - блок «Фаза» для кожної фази по черзі: F0, F1, ... F6.
3. Після кожної фази Cowork показує скріни, а ти кидаєш їх мені на ревʼю в чат з полотном.

---

## Старт (один раз)

```
Робимо Pacenote 0.8: ребрендинг Live Tips → Pacenote і редизайн 0.8. Репозиторій: ~/work/live-tips (у Cowork підключений як папка live-tips). Увесь пакет лежить у ~/work/live-tips/design/pacenote-0.8/:

- REDESIGN-SPEC.md - єдине джерело правди, читай повністю першим;
- BRAND.md - бренд (кольори, поле, розміри, так / ні);
- strings/rebrand-strings.md - усі рядки, що змінюються (key, old EN, new EN, new UK);
- brand/ - іконка (AppIcon.appiconset), menu bar template PDF, символ, вордмарк, lockup-и, favicon;
- swift/PacenoteTheme.swift, swift/MenuBarPanel.swift - токени, кнопки, бейдж, скелет панелі menu bar;
- tips-window/ - референсна реалізація вікна підказок (Concept A) зі станами Ready і Listening; відкрий index.html у браузері з ?state=ready, ?state=empty, ?theme=dark, ?lang=uk, щоб побачити очікуваний результат.

Код пиши через Claude Code. Спершу вивчи репозиторій: SwiftUI-екрани (Home, Start call, Prepare, Plan call, prep-doc, Settings, Onboarding), меню в menu bar, сторінку WKWebView вікна підказок і як Swift шле в неї дані, локалізації en/uk (xcstrings), Info.plist, генерацію скрінів на демо-даних, спільні rules/ зі скілом live-tips.

Потім склади план за фазами з розділу 11 специфікації (F0 ребрендинг першим): які файли міняються, що видаляється, що з поточної логіки треба зберегти, ризики. Окремо випиши, де специфікація суперечить коду, і питання до мене. Код не пиши, поки я не погоджу план.

Правила на весь проєкт:
- Не змінювати: bundle identifier, імена файлів і папок, CLI, ключі конфігів, формат .livetips-index/, імена скілів, live-transcriber (його не чіпати взагалі без мого явного «так»).
- Скіл live-tips і застосунок поводяться однаково: зміни поведінки йдуть через спільні rules/.
- Жодного довгого тире (U+2014) в текстах інтерфейсу, коментарях, комітах. Дефіс, кома або перебудована фраза.
- Кожен новий рядок інтерфейсу - одразу en і uk.
- Жодних емодзі в UI. Лише 3 стилі кнопок з PacenoteTheme.swift.
- Jira в застосунку немає.
- Нічого не відправляти назовні (Notion, пошта) без явної дії користувача.
- Нічого не комітити і не пушити без мого дозволу: готуєш гілку redesign/F<N> і драфт коміту, комітю я.
- У робочому дереві вже є моя незакомічена зміна в app/Sources/LiveTips/ShotMode.swift: не перезаписуй і не відкочуй її, спитай, якщо заважає.
- Папку design/pacenote-0.8/ не редагуй: це вхідні матеріали. Чи комітити її в репо, вирішу я.
- Після кожної фази: збірка без помилок, тести зелені, скріни на демо-даних у світлій і темній темі та в uk, короткий запис у CHANGELOG.md.
```

## Фаза

```
Реалізуй фазу F<N> з ~/work/live-tips/design/pacenote-0.8/REDESIGN-SPEC.md за погодженим планом.
Наприкінці: збери проєкт, прожени тести, перегенеруй скріни (світла, темна, uk), пройди чекліст розділу 12 і критерії приймання цієї фази. Покажи: список зробленого, скріни, що не вдалося і чому, драфт коміту.
```

## Підказки по фазах

**F0, ребрендинг.** `Assets.xcassets/AppIcon` ← `brand/icon/AppIcon.appiconset`. Нові image sets `PacenoteTemplate`, `PacenoteRecordingTemplate` (PDF, Render As: Template Image) і `PacenoteSymbol` (`brand/symbol/pacenote-symbol-ink.svg`, для темної появи `-white.svg`). `Info.plist`: CFBundleDisplayName, CFBundleName, тексти дозволів. Пройти `strings/rebrand-strings.md` і пошук «Live Tips» по всіх рядках, що бачить користувач (Swift, xcstrings, HTML вікна підказок, шаблон сторінки Notion, сповіщення). Splash першим екраном онбордингу, About, футер Notion. Ідентифікатори і шляхи не чіпати.

**F1, фундамент.** Додай `PacenoteTheme.swift` у таргет. Заміни кастомні кнопки на `.pnPrimary` / `.pnSecondary` / `.pnTertiary`, хардкод-кольори на `PN.C`. Меню з menu bar → `MenuBarExtra(.window)` за `MenuBarPanel.swift` і розділом 9a.

**F2, вікно підказок.** `tips-window/` як основа сторінки WKWebView. `WKScriptMessageHandler` з імʼям `liveTips` (імʼя внутрішнє, лишається), дії - таблиця 3.10 + `start`, `open-brief`. Нативна частина збирає state і шле `LiveTips.setState` з дебаунсом 100-200 мс. Компактний режим: розмір і рівень NSWindow + `setState({call:{mode:'compact'}})`.

**F3, Home.** Розділ 4. `On you` і свіжість брифу до F5 - з наявних даних.

**F4, форми, онбординг, налаштування.** Один `CallSetupView(mode:)`, онбординг 4 кроки після splash, установка моделей у фоні з одним прогресом.

**F5 / F6, ідеї.** Кожна ідея - окрема гілка. Спершу модель даних і міграція, потім UI.
