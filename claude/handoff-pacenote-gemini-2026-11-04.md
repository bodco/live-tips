# Handoff: Gemini API і запасний варіант (0.9.3, не закомічено)

## Стан
Гілка та сама, що в 0.9.2. Нічого не закомічено і не запушено. У робочому дереві також лишились чужі незакомічені
правки OpenAI (cache, effort) з попередньої сесії: cost.py, openai_provider.py, test_openai_provider.py.

## Що зроблено
- `spikes/m0/livetips_m0/gemini_provider.py`: класичний streamGenerateContent (без стану), ключ у заголовку
  x-goog-api-key, thinking на мінімумі (minimal для Flash-Lite, low для Flash/Argon), thoughts не потрапляють у
  відповідь, але рахуються як output, обрізка по ліміту як в OpenAI (json prefix, повтор x3), помилки лише статус+код.
- `geminiprep.py`: підготовка через Gemini (як openaiprep).
- `cost.py`: ціни Gemini + `PRICE_CHANGES` (Argon $4/$20 з 2026-12-01, Flash $1.50/$7.50 з 2027-01-01).
- `routing.py`: маршрут `gemini`, опційний plan B (`gemini_fallback`, env `LT_GEMINI_FALLBACK=1`, cfg ai.gemini_fallback):
  вибраний спосіб out (credit/auth/limit/missing) -> Gemini, повернення, коли вибраний знову відповідає.
  Обраний Gemini не має автоперемикання.
- `providers.make_provider`: види `openai`, `gemini`, `fake` для реплеїв.
- Swift: SecretStore.geminiAPIKey, AIRoutes.gemini*/geminiFallback, AIRoute (маршрут, env, outReason, статуси),
  PrepRunner (route gemini, plan B під час запуску і після збою), SettingsView (вкладка Gemini, KeyRow, GeminiModelPicker,
  перемикач plan B), HomeWindow, CallEngine (deep_lookup вимкнено для Gemini), i18n en/uk.
- Docs: rules/ai.yaml, CHANGELOG (0.9.3 unreleased), PRIVACY EN/UK, docs/en|uk 14.1p.
- Тести: test_gemini_provider.py (23), test_geminiprep.py (2). Усього 450 passed, 2 skipped (Linux, Python 3.10).
- Бенч: `Fixtures/bench/*.md` (5 вигаданих мітів, американські імена), `tools/provider_bench.py` (--dry перевірено).

## Не перевірено
- `swift build`: з цього середовища неможливо. Усі Swift-правки написані за зразком OpenAI, але не скомпільовані.
- Реальні відповіді Gemini API: ні з хмарного середовища, ні з Mac-віртуалки немає мережі до generativelanguage.googleapis.com.
  Формат (usageMetadata.promptTokenCount включає cachedContentTokenCount; candidatesTokenCount без thoughtsTokenCount;
  finishReason; thinkingConfig.thinkingLevel) узято з офіційних доків. Перший реальний запит звірити з білінгом.
- Чи приймає thinkingLevel всі три моделі: якщо ні, провайдер один раз повторює запит без thinkingConfig.

## Далі
1. Ключ: aistudio.google.com/apikey, проєкт з білінгом (Tier 1). Додати GEMINI_API_KEY у secrets.env і/або в Settings > AI > Gemini.
2. `python3 tools/provider_bench.py --out ~/work/Bodco/Pacenote/private/bench-out` на Маку (мережа до трьох вендорів),
   потім прочитати bench-report.md і порівняти якість підказок.
3. swift build + CoreChecks, перевірити вкладку Gemini і перемикач plan B в Settings > AI.
4. Рішення по Onboarding: вкладка Gemini там не додана (лише Settings).

## Пастки
- Безкоштовний tier Google використовує вміст для покращення продуктів: ключ лише платного проєкту.
- Тест ключа в Settings (GET models/...) проходить і для free-tier ключа: різниці не показує.
- Ціни ростуть (Argon 1 грудня, Flash 1 січня): враховано в cost.py, оновлювати підписи в GeminiModelPicker.
- Plan B відправляє текст дзвінка до Google: лише за явним вмиканням.

## Стартер для нового чату
"Продовжуємо Pacenote Gemini: прочитай claude/handoff-pacenote-gemini-2026-11-04.md, зберіть swift build і прогони provider_bench."

## Оновлення (2026-11-04, вечір)
- Локальний коміт 6540435 у main, не запушено. Туди ж увійшли незакомічені правки OpenAI cache з попередньої сесії (cost.py спільний).
- Додано Settings > Usage: "AI through API keys" (AIUsageCore.swift + AIUsageView.swift), фільтр Today / Last 7 days (типово) / This month / Dates, таблиці за етапами (prep, live, after, total) і за моделями. Дані: state/spend-ledger.jsonl, лише маршрути api, openai, gemini.
- Підготовка через OpenAI/Gemini тепер пише cost_usd (раніше $0), рядок підготовки в ledger має model.
- Gemini: до maxOutputTokens додається запас на thinking (minimal +128, low +512). Перевірити на бенчі stop MAX_TOKENS.
- З підписів моделей Gemini прибрано "like Haiku/Sonnet".
- Не зроблено: swift build, CoreChecks (застосунок був у роботі, збирати заборонено).

## Оновлення (2026-11-05): маршрут Gemini account (agy)
- Коміт 18a53e5 у main, запушено. Застосунок 0.9.3/160 встановлено.
- agy_provider.py, agyprep.py, AgyCLI.swift, AgyAccount.swift (рядок акаунта, моделі, AgyTermsWarning), маршрут лише prep/after.
- Червоне застереження з посиланням на antigravity.google/terms показується, коли маршрут обрано. Умови: п.6 забороняє доступ через сторонні програми (ризик блокування акаунта), п.5 Interactions використовуються і переглядаються, Telemetry off не зупиняє зберігання.
- План B: ключ Gemini API, потім акаунт (ніколи під час дзвінка).
- Не перевірено очима: вкладка Gemini і червоний текст (GUI-QA не обирали).
