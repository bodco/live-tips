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

    /// The group shown in the result's path ("Basics", "Access", ...): the first *Group default.
    public var group: String? {
        for k in SettingsSearch.groupKeys { if let g = defaults[k] { return g } }
        return nil
    }
}

public enum SettingsSearch {
    public static let generalGroupKey = "settingsGeneralGroup"
    public static let aiGroupKey = "settingsAIGroup"
    public static let aiProviderKey = "settingsAIProvider"
    public static let notionGroupKey = "settingsNotionGroup"
    public static let hubspotGroupKey = "settingsHubSpotGroup"
    static let groupKeys = [generalGroupKey, aiGroupKey, notionGroupKey, hubspotGroupKey]

    /// The groups of each segmented pane, in order. The app draws its segments from these.
    public static let generalGroups = ["basics", "calls", "data"]
    public static let aiGroups = ["access", "jobs", "limits", "mac", "more"]
    public static let notionGroups = ["conn", "dbs", "after", "local"]
    public static let hubspotGroups = ["conn", "match", "data", "qual"]

    private static func g(_ group: String) -> [String: String] { [generalGroupKey: group] }
    private static func a(_ group: String, _ provider: String? = nil) -> [String: String] {
        var d = [aiGroupKey: group]; if let p = provider { d[aiProviderKey] = p }; return d
    }
    private static func n(_ group: String) -> [String: String] { [notionGroupKey: group] }
    private static func h(_ group: String) -> [String: String] { [hubspotGroupKey: group] }

    public static let entries: [SettingsSearchEntry] = [
        // General
        .init("gen.name", "general", g("basics"), title: "set.yourNameOnCalls", words: "name alias me імʼя ім'я псевдонім"),
        .init("gen.folder", "general", g("basics"), title: "set.workFolder", words: "folder work root тека папка робоча"),
        .init("gen.lang", "general", g("basics"), title: "callSettings.uiLang", words: "language english ukrainian мова англійська українська"),
        .init("gen.theme", "general", g("basics"), title: "set.theme", words: "theme dark light appearance тема темна світла"),
        .init("gen.dock", "general", g("basics"), title: "settings.general.dock", words: "dock icon док іконка"),
        .init("gen.stealth", "general", g("calls"), title: "set.hideTheTipsWindow", words: "stealth hide screen sharing tips window приховати вікно підказок"),
        .init("gen.floating", "general", g("calls"), title: "floating.setting", words: "floating controls call buttons кнопки дзвінка"),
        .init("gen.shortcuts", "general", g("calls"), title: "set.shortcuts", words: "shortcuts hotkeys keys keyboard клавіші гарячі"),
        .init("gen.usage", "general", g("data"), title: "usage.toggle", words: "usage log statistics статистика лог"),
        .init("gen.telemetry", "general", g("data"), title: "telemetry.toggle", words: "telemetry share privacy телеметрія приватність"),
        .init("gen.addons", "general", g("data"), title: "comp.addons", words: "add-on link downloader video yt-dlp відео"),
        .init("gen.appfolder", "general", g("data"), title: "set.appFolder", words: "app folder data storage дані тека застосунку"),
        // Call recording
        .init("rec.what", "recording", title: "rec.set.what", words: "record recording audio video screen запис відео екран звук"),
        .init("rec.consent", "recording", title: "set.recordingConsent", words: "consent agree permission recording згода дозвіл запис"),
        .init("rec.privacy", "recording", title: "rec.set.privacy", words: "screen permission privacy дозвіл приватність"),
        // Transcription, Meeting Sheet, Account, Modules
        .init("tr.dict", "transcription", title: "dict.head", words: "dictionary words spelling transcript словник слова транскрипт"),
        .init("sh.mode", "sheet", title: "sheet.ui.set.modeTitle", words: "quick expert prep підготовка"),
        .init("sh.focus", "sheet", title: "sheet.ui.myFocus", words: "focus фокус"),
        .init("sh.timing", "sheet", title: "sheet.ui.set.timing", words: "reminder timing when нагадування коли"),
        .init("sh.presets", "sheet", title: "sheet.ui.set.presets", words: "presets template шаблони пресети"),
        .init("acc.head", "account", title: "account.head", words: "account sign in login server акаунт вхід сервер"),
        .init("acc.orgs", "account", title: "org.head", words: "organization team invite join manage default private організація команда запрошення приєднатися керувати приватний"),
        .init("mod.tracker", "modules", title: "modules.tracker", words: "tracker tasks module трекер задачі модуль"),
        // Components (0.16.0, D3)
        .init("comp.disk", "components", title: "cmp.disk", words: "disk space size storage free gb місце диск розмір вільно"),
        .init("comp.optional", "components", title: "settings.tab.components", words: "components remove uninstall delete add-on ollama gemma local model agent yt-dlp компоненти видалити прибрати додаткові модель агент"),
        .init("comp.required", "components", title: "cmp.repair", words: "repair reinstall whisper speech required відновити перевстановити мовлення обовʼязкові"),
        .init("help.whatsnew", "help", title: "wn.history", words: "what's new changes release notes update що нового зміни оновлення"),
        // AI
        .init("ai.claude", "ai", a("access", "claude"), title: "keys.claude.title", words: "claude anthropic api key ключ"),
        .init("ai.openai", "ai", a("access", "chatgpt"), title: "keys.openai.title", words: "openai chatgpt gpt api key ключ"),
        .init("ai.gemini", "ai", a("access", "gemini"), title: "keys.gemini.title", words: "gemini google api key ключ"),
        .init("ai.prep", "ai", a("jobs"), title: "ai.job.prep", words: "prep preparation model brief підготовка модель"),
        .init("ai.tips", "ai", a("jobs"), title: "ai.job.tips", words: "tips model hints підказки модель"),
        .init("ai.after", "ai", a("jobs"), title: "ai.job.after", words: "summary notes after model нотатки підсумок"),
        .init("ai.chain", "ai", a("jobs"), title: "ai.chain.header", words: "fallback out backup chain резерв ланцюг"),
        .init("ai.spend", "ai", a("limits"), title: "set.spendingLimits", words: "limit spend budget money cost витрати ліміт гроші"),
        .init("ai.economy", "ai", a("limits"), title: "economy.header", words: "economy cheap save економ"),
        .init("ai.local", "ai", a("mac"), title: "local.section", words: "ollama gemma local offline локальна модель"),
        .init("ai.localLayer", "ai", a("mac"), title: "set.localAi", words: "embedding bge search index пошук індекс"),
        .init("ai.speakers", "ai", a("mac"), title: "set.speakers", words: "speakers voices voice library голоси спікери"),
        .init("ai.salesWeb", "ai", a("more"), title: "ai.salesWeb.header", words: "web search company research пошук компанія"),
        .init("ai.agent", "ai", a("more"), title: "agent.header", words: "agent call agent агент"),
        // Integrations
        .init("int.notion.token", "integrations", n("conn"), integration: "notion", title: "keys.notion.title", words: "notion token key connect ключ токен"),
        .init("int.notion.dbs", "integrations", n("dbs"), integration: "notion", title: "ntset.databases", words: "notion database meetings tasks risks decisions бази"),
        .init("int.notion.pages", "integrations", n("after"), integration: "notion", title: "set.meetingPages", words: "notion meeting page summary сторінка зустрічі"),
        .init("int.notion.tasks", "integrations", n("after"), integration: "notion", title: "ntset.header", words: "notion my tasks on you задачі"),
        .init("int.notion.local", "integrations", n("local"), integration: "notion", title: "set.localCopyOfNotion", words: "notion mirror local copy sync копія дзеркало"),
        .init("int.calendars", "integrations", integration: "calendars", title: "settings.tab.calendars", words: "calendar events календар"),
        .init("int.google", "integrations", integration: "google", title: "search.google", words: "google drive docs account гугл диск"),
        .init("int.hubspot.key", "integrations", h("conn"), integration: "hubspot", title: "search.hubspotKey", words: "hubspot crm key connect ключ"),
        .init("int.hubspot.match", "integrations", h("match"), integration: "hubspot", title: "int.hubspot.matching", words: "hubspot owner company domain власник"),
        .init("int.hubspot.write", "integrations", h("data"), integration: "hubspot", title: "int.hubspot.canWrite", words: "hubspot write note deal task запис"),
        .init("int.hubspot.qual", "integrations", h("qual"), integration: "hubspot", title: "int.hubspot.qualification", words: "hubspot bant qualification кваліфікація"),
        // Projects
        .init("pr.scan", "projects", title: "set.scanWorkFolder", words: "scan add project folder workspace сканувати додати проєкт"),
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
