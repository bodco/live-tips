import Foundation

/// 0.15.0 (D2): search in Settings. A fixed list of the settings people look for, each with the pane it lives on,
/// the group to open there (the UserDefaults keys the panes keep their segment in) and an anchor id that the row
/// or section in the app carries. Pure, so CoreChecks can test what a query finds.
public struct SettingsSearchEntry: Equatable, Sendable {
    /// Also the anchor id of the row or the section header in the app.
    public let id: String
    /// Settings pane id ("general", "ai", "integrations", ...).
    public let pane: String
    /// UserDefaults to set before showing the pane: the group (segment) and, for AI keys, the provider tab.
    public let defaults: [String: String]
    /// The page under Integrations ("notion", "hubspot", ...), if any.
    public let integration: String?
    /// The setting lives on a project's own page (Settings > Projects > a project).
    public let projectPage: Bool
    /// The interface string used as the result's title.
    public let titleKey: String
    /// Other words people type for it, English and Ukrainian.
    public let words: String

    public init(_ id: String, _ pane: String, _ defaults: [String: String] = [:], integration: String? = nil,
                projectPage: Bool = false, title: String, words: String = "") {
        self.id = id; self.pane = pane; self.defaults = defaults; self.integration = integration
        self.projectPage = projectPage; self.titleKey = title; self.words = words
    }

    /// The setting sits under the pane's collapsed Advanced (0.25 R5): the search opens it before it scrolls there.
    public var advanced: Bool { defaults.keys.contains { $0.hasPrefix(SettingsSearch.advancedPrefix) } }

    /// The group shown in the result's path: a HubSpot tab, else "advanced" for what sits under Advanced, else none.
    public var group: String? {
        for k in SettingsSearch.groupKeys { if let g = defaults[k] { return g } }
        return advanced ? "advanced" : nil
    }
}

public enum SettingsSearch {
    public static let hubspotGroupKey = "settingsHubSpotGroup"
    static let groupKeys = [hubspotGroupKey]

    /// 0.25 (R5, owner 18.11): every pane shows what is needed on top and the rest under one collapsed Advanced.
    /// Whether a pane's Advanced is open is kept in UserDefaults under `advancedKey(scope)` ("1" open, "0" closed).
    public static let advancedPrefix = "settingsAdvanced."
    public static let advancedScopes = ["account", "general", "ai", "projects", "integrations", "notion", "recording", "transcription", "sheet"]
    public static func advancedKey(_ scope: String) -> String { advancedPrefix + scope }

    /// The tabs of the HubSpot page, in order. The app draws its segments from these.
    public static let hubspotGroups = ["conn", "match", "data", "qual"]

    private static func adv(_ scope: String) -> [String: String] { [advancedKey(scope): "1"] }
    private static func h(_ group: String) -> [String: String] { [hubspotGroupKey: group] }

    public static let entries: [SettingsSearchEntry] = [
        // General
        .init("gen.name", "general", title: "set.yourNameOnCalls", words: "name alias me імʼя ім'я псевдонім"),
        .init("gen.folder", "general", adv("general"), title: "set.workFolder", words: "folder work root тека папка робоча"),
        .init("gen.lang", "general", title: "callSettings.uiLang", words: "language english ukrainian мова англійська українська"),
        .init("gen.theme", "general", title: "set.appearance", words: "appearance style mode theme dark light classic roadbook broadsheet вигляд стиль режим тема темна світла"),
        .init("gen.dock", "general", adv("general"), title: "settings.general.dock", words: "dock icon док іконка"),
        .init("gen.stealth", "general", adv("general"), title: "set.hideTheTipsWindow", words: "stealth hide screen sharing tips window приховати вікно підказок"),
        .init("gen.tipsMode", "general", adv("general"), title: "set.tipsMode", words: "compact card camera tips window mode компактна картка камера вікно підказок"),
        .init("gen.floating", "general", adv("general"), title: "floating.setting", words: "floating controls call buttons кнопки дзвінка"),
        .init("gen.shortcuts", "general", adv("general"), title: "set.shortcuts", words: "shortcuts hotkeys keys keyboard клавіші гарячі"),
        .init("gen.usage", "general", adv("general"), title: "usage.toggle", words: "usage log statistics статистика лог"),
        .init("gen.telemetry", "general", adv("general"), title: "telemetry.toggle", words: "telemetry share privacy телеметрія приватність"),
        .init("gen.addons", "general", adv("general"), title: "comp.addons", words: "add-on link downloader video yt-dlp відео"),
        .init("gen.appfolder", "general", adv("general"), title: "set.appFolder", words: "app folder data storage дані тека застосунку"),
        // Call recording
        .init("rec.what", "recording", title: "rec.set.what", words: "record recording audio video screen запис відео екран звук"),
        .init("rec.consent", "recording", adv("recording"), title: "set.recordingConsent", words: "consent agree permission recording згода дозвіл запис"),
        .init("rec.privacy", "recording", adv("recording"), title: "rec.set.privacy", words: "screen permission privacy дозвіл приватність"),
        .init("rec.picture", "recording", adv("recording"), title: "rec.set.picture", words: "screen window display picture екран вікно дисплей"),
        .init("rec.quality", "recording", adv("recording"), title: "rec.set.qualityHead", words: "quality codec size hevc якість кодек розмір"),
        .init("rec.drive", "recording", adv("recording"), title: "rec.set.drive", words: "google drive upload folder вивантаження диск папка"),
        // Transcription, Meeting Sheet, Account, Modules
        .init("tr.lang", "transcription", title: "tr.lang.head", words: "language languages call english ukrainian мова мови дзвінка англійська українська"),
        .init("tr.speakers", "transcription", adv("transcription"), title: "set.speakers", words: "speakers voices voice library who is speaking голоси спікери мовці хто говорить"),
        .init("tr.dict", "transcription", adv("transcription"), title: "dict.head", words: "dictionary words spelling transcript словник слова транскрипт"),
        .init("sh.mode", "sheet", title: "sheet.ui.set.modeTitle", words: "quick expert prep підготовка"),
        .init("sh.focus", "sheet", adv("sheet"), title: "sheet.ui.myFocus", words: "focus фокус"),
        .init("sh.timing", "sheet", adv("sheet"), title: "sheet.ui.set.timing", words: "reminder timing when нагадування коли"),
        .init("sh.presets", "sheet", adv("sheet"), title: "sheet.ui.set.presets", words: "presets template шаблони пресети"),
        .init("acc.head", "account", title: "account.head", words: "account sign in login server акаунт вхід сервер"),
        .init("acc.methods", "account", adv("account"), title: "account.methods.head", words: "password google sign-in methods change reset пароль спосіб входу змінити"),
        .init("acc.orgs", "account", adv("account"), title: "org.head", words: "organization team invite join manage default private організація команда запрошення приєднатися керувати приватний"),
        .init("acc.plan", "account", title: "plan.head", words: "plan plans compare switch team beta price trial limit seats storage request upgrade план плани порівняти змінити команда бета ціна тріал ліміт місця сховище запит"),
        .init("acc.usage", "account", adv("account"), title: "usage.head", words: "usage use overview calls hours active days використання огляд дзвінки години активні дні"),
        .init("mod.tracker", "modules", title: "modules.tracker", words: "tracker tasks module трекер задачі модуль"),
        // Components (0.16.0, D3)
        .init("comp.disk", "components", title: "cmp.disk", words: "disk space size storage free gb місце диск розмір вільно"),
        .init("comp.optional", "components", title: "settings.tab.components", words: "components remove uninstall delete add-on ollama gemma local model agent yt-dlp компоненти видалити прибрати додаткові модель агент"),
        .init("comp.required", "components", title: "cmp.repair", words: "repair reinstall whisper speech required відновити перевстановити мовлення обовʼязкові"),
        .init("help.whatsnew", "help", title: "wn.history", words: "what's new changes release notes update що нового зміни оновлення"),
        // after Components: "видалити" / "remove" open Components first
        .init("acc.devices", "account", adv("account"), title: "account.devices.head", words: "devices mac sign out everywhere пристрої вийти"),
        .init("acc.delete", "account", adv("account"), title: "account.delete.head", words: "delete export server data видалити експорт дані сервер"),
        // AI
        .init("ai.claude", "ai", title: "keys.claude.title", words: "claude anthropic api key ключ"),
        .init("ai.openai", "ai", title: "keys.openai.title", words: "openai chatgpt gpt api key ключ"),
        .init("ai.gemini", "ai", title: "keys.gemini.title", words: "gemini google api key ключ"),
        .init("ai.prep", "ai", adv("ai"), title: "ai.job.prep", words: "prep preparation model brief підготовка модель"),
        .init("ai.tips", "ai", adv("ai"), title: "ai.job.tips", words: "tips model hints підказки модель"),
        .init("ai.after", "ai", adv("ai"), title: "ai.job.after", words: "summary notes after model нотатки підсумок"),
        .init("ai.chain", "ai", adv("ai"), title: "ai.chain.header", words: "fallback out backup chain резерв ланцюг"),
        .init("ai.spend", "ai", adv("ai"), title: "set.spendingLimits", words: "limit spend budget money cost витрати ліміт гроші"),
        .init("ai.economy", "ai", adv("ai"), title: "economy.header", words: "economy cheap save економ"),
        .init("ai.local", "ai", adv("ai"), title: "local.section", words: "ollama gemma local offline локальна модель"),
        .init("ai.localLayer", "ai", adv("ai"), title: "set.localAi", words: "embedding bge search index пошук індекс"),
        .init("ai.salesWeb", "ai", adv("ai"), title: "ai.salesWeb.header", words: "web search company research пошук компанія"),
        .init("ai.agent", "ai", adv("ai"), title: "agent.header", words: "agent call agent агент"),
        // Integrations
        .init("int.notion.token", "integrations", integration: "notion", title: "keys.notion.title", words: "notion token key connect ключ токен"),
        .init("int.notion.meetDB", "integrations", integration: "notion", title: "nset.whereMeetingPagesGo", words: "notion meetings database meeting notes база мітингів нотатки"),
        .init("int.notion.dbs", "integrations", adv("notion"), integration: "notion", title: "ntset.databases", words: "notion database meetings tasks risks decisions бази"),
        .init("int.notion.pages", "integrations", integration: "notion", title: "set.meetingPages", words: "notion meeting page summary сторінка зустрічі"),
        .init("int.notion.tasks", "integrations", adv("notion"), integration: "notion", title: "ntset.header", words: "notion my tasks on you задачі"),
        .init("int.notion.local", "integrations", adv("notion"), integration: "notion", title: "set.localCopyOfNotion", words: "notion mirror local copy sync копія дзеркало"),
        .init("int.calendars", "integrations", integration: "calendars", title: "settings.tab.calendars", words: "calendar events календар"),
        .init("int.google", "integrations", integration: "google", title: "search.google", words: "google drive docs account гугл диск"),
        .init("int.hubspot.key", "integrations", h("conn").merging(adv("integrations")) { a, _ in a }, integration: "hubspot", title: "search.hubspotKey", words: "hubspot crm key connect ключ"),
        .init("int.hubspot.match", "integrations", h("match"), integration: "hubspot", title: "int.hubspot.matching", words: "hubspot owner company domain власник"),
        .init("int.hubspot.write", "integrations", h("data"), integration: "hubspot", title: "int.hubspot.canWrite", words: "hubspot write note deal task запис"),
        .init("int.hubspot.qual", "integrations", h("qual"), integration: "hubspot", title: "int.hubspot.qualification", words: "hubspot bant qualification кваліфікація"),
        // Projects
        .init("pr.scan", "projects", adv("projects"), title: "set.scanWorkFolder", words: "scan add project folder workspace сканувати додати проєкт"),
        .init("pr.import", "projects", title: "set.importControlTowerConfigs", words: "control tower import configs імпорт"),
        .init("pr.notion", "projects", projectPage: true, title: "proj.inNotion", words: "notion name project property назва в notion"),
        .init("pr.sales", "projects", projectPage: true, title: "proj.sales", words: "sales bant spiced meddic продажі"),
        .init("pr.cards", "projects", projectPage: true, title: "search.cards", words: "answer cards картки відповідей"),
        .init("pr.ai", "projects", projectPage: true, title: "set.useClaudeForTips", words: "ai tips api allowed підказки"),
        .init("pr.index", "projects", projectPage: true, title: "set.searchThisFolder", words: "index search folder reindex індекс пошук"),
        .init("pr.sync", "projects", projectPage: true, title: "set.syncToServer", words: "sync server account синхронізація сервер"),
        .init("pr.orgMove", "projects", projectPage: true, title: "proj.org.move", words: "move organization transfer перенести організація"),
        .init("pr.card", "projects", projectPage: true, title: "proj.card.head", words: "card about client goal terms glossary links sample картка клієнт мета терміни посилання приклад"),
        .init("pr.orgProject", "projects", projectPage: true, title: "proj.org.project", words: "organization project link private організація проєкт прив'язати приватний"),
        .init("pr.orgCard", "projects", projectPage: true, title: "orgcard.head", words: "shared card organization project team people rules спільна картка організація проєкт люди правила"),
        .init("pr.orgState", "projects", projectPage: true, title: "orgctx.state.head", words: "current state status organization project поточний стан статус"),
        .init("pr.orgSources", "projects", projectPage: true, title: "orgctx.src.head", words: "sources drive notion links folder джерела посилання папка"),
        .init("pr.orgIndex", "projects", projectPage: true, title: "orgctx.idx.head", words: "file index search files embeddings індекс файлів пошук"),
        .init("pr.orgHistory", "projects", projectPage: true, title: "orgctx.hist.head", words: "history restore undo changes історія відновити зміни"),
    ]

    /// Lower case, no accents, one kind of apostrophe, single spaces.
    public static func normalize(_ s: String) -> String {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ʼ", with: "'").replacingOccurrences(of: "’", with: "'")
        return f.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 0 when a word of the query is missing. A title that starts with the query ranks first, then a word of a
    /// title that starts with it, then the query inside a title, then the other words only.
    public static func score(_ query: String, titles: [String], extra: String) -> Double {
        let q = normalize(query)
        guard !q.isEmpty else { return 0 }
        let ts = titles.map(normalize), hay = (ts + [normalize(extra)]).joined(separator: " ")
        for w in q.split(separator: " ") where !hay.contains(w) { return 0 }
        if ts.contains(where: { $0.hasPrefix(q) }) { return 4 }
        if ts.contains(where: { t in t.split(separator: " ").contains { $0.hasPrefix(q) } }) { return 3 }
        if ts.contains(where: { $0.contains(q) }) { return 2 }
        return 1
    }

    /// The entries that match, best first; equal ones keep the list's order.
    public static func find(_ query: String, in list: [SettingsSearchEntry] = entries,
                            titles: (SettingsSearchEntry) -> [String], extra: (SettingsSearchEntry) -> String = { _ in "" }) -> [SettingsSearchEntry] {
        var hits: [(Int, SettingsSearchEntry, Double)] = []
        for (i, e) in list.enumerated() {
            let sc: Double = score(query, titles: titles(e), extra: e.words + " " + extra(e))
            if sc > 0 { hits.append((i, e, sc)) }
        }
        hits.sort { a, b in a.2 != b.2 ? a.2 > b.2 : a.0 < b.0 }
        return hits.map { $0.1 }
    }
}
