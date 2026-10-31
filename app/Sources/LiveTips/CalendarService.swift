import AppKit
import EventKit
import SwiftUI
import UserNotifications
import LiveTipsCore

/// 2026-10-27 (owner): calendars through macOS. The PM adds the Google and Microsoft accounts in System
/// Settings > Internet Accounts; Calendar syncs them and Live Tips reads every calendar of every account
/// through EventKit with one permission. No Google or Microsoft sign-in in the app itself.
/// Read only: Live Tips never creates, changes or deletes events.
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    enum Access { case unknown, granted, denied }

    struct CalEvent: Identifiable, Hashable {
        var id: String               // one occurrence: event id + start
        var seriesKey: String        // the same for every occurrence of a recurring event
        var title: String
        var start: Date
        var end: Date
        var calendar: String
        var account: String
        var color: NSColor
        var attendees: [String]      // names, the PM left out
        var link: String?            // Meet, Zoom or Teams link
        var recurring: Bool
        var emails: [String] = []    // 0.8.7 (I3): attendee emails for the CRM match (the PM left out); never written to files

        static func == (a: CalEvent, b: CalEvent) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }

        var timeRange: String {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return f.string(from: start) + "-" + f.string(from: end)
        }
        func overlaps(_ o: CalEvent) -> Bool { start < o.end && o.start < end && id != o.id }
        /// "in progress", "in 12 min", "ended 5 min ago" or "" (later).
        func relative(_ now: Date = Date()) -> String {
            if start <= now && end > now { return "in progress" }
            let m = Int((start.timeIntervalSince(now) / 60).rounded())
            if m > 0 && m <= 90 { return "in \(m) min" }
            if end <= now { return "ended \(max(1, Int(now.timeIntervalSince(end) / 60))) min ago" }
            return ""
        }
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [CalEvent] = []          // from 3 h ago to 36 h ahead, no all-day, not declined
    @Published private(set) var calendars: [EKCalendar] = []
    @Published var excluded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "calExcluded") ?? []) {
        didSet { UserDefaults.standard.set(Array(excluded), forKey: "calExcluded"); refresh() }
    }
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "calHidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden.suffix(300)), forKey: "calHidden") }
    }
    /// Off by default (owner: the calendar already reminds; no double notifications).
    @Published var remind = UserDefaults.standard.bool(forKey: "calRemind") {
        didSet { UserDefaults.standard.set(remind, forKey: "calRemind"); if remind { askNotifications() } }
    }
    @Published var remindMinutes = max(1, UserDefaults.standard.object(forKey: "calRemindMin") as? Int ?? 2) {
        didSet { UserDefaults.standard.set(remindMinutes, forKey: "calRemindMin") }
    }

    let store = EKEventStore()
    private var reminded: Set<String> = []
    private var timer: Timer?

    private init() {
        updateAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(); self?.checkReminders() }
        }
        refresh()
    }

    func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }

    /// Asks macOS for read access to the calendars (once); afterwards System Settings decides.
    func connect() {
        if access == .denied {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(u) }
            return
        }
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.store.reset(); self?.updateAccess(); self?.refresh() } }
        }
    }

    /// Screenshot mode only: demo events instead of the Mac's calendars.
    private var demo: [CalEvent]?
    func useDemo(_ evs: [CalEvent]) { demo = evs; access = .granted; events = evs }

    func refresh() {
        if let d = demo { events = d; access = .granted; return }
        updateAccess()
        guard access == .granted else { events = []; calendars = []; return }
        calendars = store.calendars(for: .event).sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
        let use = calendars.filter { !excluded.contains($0.calendarIdentifier) }
        guard !use.isEmpty else { events = []; return }
        let now = Date()
        events = fetch(from: now.addingTimeInterval(-3 * 3600), to: now.addingTimeInterval(36 * 3600), calendars: use)
    }

    /// 0.8.5: the next event whose title contains a text within `days` (a comparison of preparations, PrepBench).
    func next(titleContains want: String, days: Double = 14) -> CalEvent? {
        guard demo == nil, access == .granted else { return nil }
        let use = calendars.filter { !excluded.contains($0.calendarIdentifier) }
        guard !use.isEmpty else { return nil }
        let now = Date()
        return fetch(from: now, to: now.addingTimeInterval(days * 86400), calendars: use)
            .first { $0.title.lowercased().contains(want.lowercased()) && $0.start > now }
    }

    private func fetch(from: Date, to: Date, calendars use: [EKCalendar]) -> [CalEvent] {
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: use)
        var out: [CalEvent] = []
        for e in store.events(matching: pred) where !e.isAllDay {
            if let me = e.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { continue }
            if e.status == .canceled { continue }
            let key = e.hasRecurrenceRules
                ? "cal:" + (e.calendarItemExternalIdentifier ?? e.calendarItemIdentifier)
                : "title:" + StartCallModel.slugify(e.title ?? "")
            let names = (e.attendees ?? []).filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
                .compactMap { a -> String? in
                    if let n = a.name, !n.isEmpty, !n.contains("@") { return n }
                    // 2026-10-28: an attendee without a display name: "o.starodubtseva@..." -> "O. Starodubtseva".
                    let local = a.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").components(separatedBy: "@").first ?? ""
                    let parts = local.split(whereSeparator: { ".-_".contains($0) }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    return parts.isEmpty ? nil : parts.enumerated().map { $0.offset < parts.count - 1 && $0.element.count == 1 ? $0.element + "." : $0.element }.joined(separator: " ")
                }
            let emails = (e.attendees ?? []).filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
                .map { $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").lowercased() }.filter { $0.contains("@") }
            let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
            out.append(CalEvent(id: (e.eventIdentifier ?? e.calendarItemIdentifier) + "@" + String(Int(e.startDate.timeIntervalSince1970)),
                                seriesKey: key, title: (e.title ?? "").isEmpty ? L("cal.untitled") : e.title!,
                                start: e.startDate, end: e.endDate, calendar: e.calendar.title, account: e.calendar.source.title,
                                color: e.calendar.color ?? .systemBlue, attendees: names, link: Self.meetingLink(in: text),
                                recurring: e.hasRecurrenceRules, emails: emails))
        }
        return out.sorted { $0.start < $1.start }
    }

    nonisolated static func meetingLink(in text: String) -> String? {
        let pat = "https://[A-Za-z0-9.-]*(meet\\.google\\.com|zoom\\.us|teams\\.microsoft\\.com|teams\\.live\\.com)/[^\\s<>\"]+"
        guard let r = text.range(of: pat, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    func event(_ id: String) -> CalEvent? { events.first { $0.id == id } }

    static func openInternetAccounts() {
        for s in ["x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension", "x-apple.systempreferences:com.apple.preferences.internetaccounts"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    /// The calls to choose from now: in progress, just ended (15 min) or starting in the next 3 h.
    /// Several at the same time are normal (owner): the PM picks the one he is actually going to.
    func aroundNow(_ now: Date = Date()) -> [CalEvent] {
        events.filter { !hidden.contains($0.id) && $0.end > now.addingTimeInterval(-15 * 60) && $0.start < now.addingTimeInterval(3 * 3600) }
    }

    func upcoming(_ now: Date = Date()) -> [CalEvent] {
        events.filter { !hidden.contains($0.id) && $0.end > now }
    }

    // MARK: optional reminder (Settings > General > Calendars)

    private func askNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkReminders() {
        guard remind, access == .granted else { return }
        let now = Date()
        for e in upcoming(now) where !reminded.contains(e.id) {
            let mins = e.start.timeIntervalSince(now) / 60
            guard mins > 0, mins <= Double(remindMinutes) else { continue }
            reminded.insert(e.id)
            let c = UNMutableNotificationContent()
            c.title = e.title
            c.body = L("notification.callSoon", ["time": DateFormatter.localizedString(from: e.start, dateStyle: .none, timeStyle: .short)])
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lt-" + e.id, content: c, trigger: nil))
        }
    }
}

/// 2026-10-27 (owner): Settings > Calendars, everything about calendars in one place. Nothing to install:
/// macOS signs in to Google and Microsoft (Internet Accounts) and Live Tips reads the calendars through EventKit.
struct CalendarsPane: View {
    @ObservedObject var cal = CalendarService.shared
    @State private var accountsOpen = false
    @State private var remembered = SeriesMemory.shared.count
    @AppStorage(AutoStart.defaultsKey) private var autoSuggest = true

    var body: some View {
        Form {
            Section {
                // Pacenote 0.8 (F4, spec 8): folded once the accounts are there.
                let hasAccounts = !cal.calendars.isEmpty
                DisclosureGroup(isExpanded: Binding(get: { !hasAccounts || accountsOpen }, set: { accountsOpen = $0 })) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("cal.addEachGoogleOr"))
                    Text(L("cal.googleAddAccountGoogle"))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    let accounts = Set(cal.calendars.map { $0.source.title }).sorted()
                    Text(accounts.isEmpty ? L("cal.noAccounts") : accounts.joined(separator: ", ")).foregroundStyle(PN.C.text3).lineLimit(2)
                    Spacer()
                    Button(L("cal.openInternetAccounts")) { CalendarService.openInternetAccounts() }
                }
                } label: { Text(Set(cal.calendars.map { $0.source.title }).sorted().joined(separator: ", ")).foregroundStyle(PN.C.text3).lineLimit(1) }
            } header: { Text(L("cal.1YourAccounts")) } footer: {
                Text(L("settings.calendars.note") + " " + L("settings.calendars.blocked"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Section {
                HStack {
                    Image(systemName: cal.access == .granted ? "checkmark.circle.fill" : "circle").foregroundStyle(cal.access == .granted ? PN.C.turn : PN.C.text3)
                    Text(cal.access == .granted ? L("settings.calendars.granted") : cal.access == .denied ? "Access is off in System Settings" : "Not connected yet")
                    Spacer()
                    if cal.access != .granted { Button(cal.access == .denied ? L("cal.openPrivacy") : L("cal.connect")) { cal.connect() } }
                    else { Button(L("cal.refresh")) { cal.refresh() } }
                }
            } header: { Text(L("cal.2Access")) }
            if cal.access == .granted {
                Section {
                    if cal.calendars.isEmpty {
                        Text(L("cal.noCalendarsYetAdd")).foregroundStyle(PN.C.text3)
                    }
                    CalendarList()
                } header: { Text(L("cal.3CalendarsWithYour")) } footer: {
                    Text(L("cal.onlyTheTickedCalendars"))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
                Section {
                    // Pacenote 0.8 (idea 08): a quiet offer to start tips when a meeting app is on at a calendar call.
                    Toggle(L("auto.setting"), isOn: $autoSuggest).help(L("auto.settingHelp"))
                    Toggle(L("cal.remindMeBeforeCalendar"), isOn: $cal.remind)
                    if cal.remind { Stepper(L("cal.minBefore", ["n": "\(cal.remindMinutes)"]), value: $cal.remindMinutes, in: 1...15) }
                    HStack {
                        Text(cal.hidden.isEmpty ? L("cal.noHidden") : L("cal.hiddenN", ["n": "\(cal.hidden.count)"]))
                        Spacer()
                        Button(L("cal.showThemAgain")) { cal.hidden = [] }.disabled(cal.hidden.isEmpty)
                    }
                    HStack {
                        Text(L("cal.remembered", ["n": "\(remembered)"]))
                        Spacer()
                        Button(L("cal.forgetAll")) { SeriesMemory.shared.forgetAll(); remembered = 0 }.disabled(remembered == 0)
                    }
                } header: { Text(L("set.behaviour")) } footer: {
                    Text(L("cal.theReminderIsOff"))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { cal.refresh(); remembered = SeriesMemory.shared.count }
    }
}

/// The calendars grouped by account, with All and None per account. Shared by Settings > Calendars and Home.
struct CalendarList: View {
    @ObservedObject var cal = CalendarService.shared

    var body: some View {
        let groups = Dictionary(grouping: cal.calendars, by: { $0.source.title })
        ForEach(groups.keys.sorted(), id: \.self) { acc in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(acc).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3)
                    Spacer()
                    Button(L("cal.all")) { for c in groups[acc] ?? [] { cal.excluded.remove(c.calendarIdentifier) } }.buttonStyle(.pnTertiary).font(PN.Font.caption)
                    Button(L("cal.none")) { for c in groups[acc] ?? [] { cal.excluded.insert(c.calendarIdentifier) } }.buttonStyle(.pnTertiary).font(PN.Font.caption)
                }
                ForEach(groups[acc] ?? [], id: \.calendarIdentifier) { c in
                    Toggle(isOn: Binding(get: { !cal.excluded.contains(c.calendarIdentifier) },
                                         set: { on in if on { cal.excluded.remove(c.calendarIdentifier) } else { cal.excluded.insert(c.calendarIdentifier) } })) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(nsColor: c.color ?? .systemBlue)).frame(width: 8, height: 8)
                            Text(c.title).lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }
}

/// The same list as a popover in Home.
struct CalendarPicker: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("cal.calendarsWithYourCalls")).font(.headline)
            Text(L("cal.onlyTheTickedOnes")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            ScrollView { VStack(alignment: .leading, spacing: 10) { CalendarList() } }
            Button(L("cal.moreInSettingsCalendars")) { SettingsWindow.show(tab: "calendars") }.buttonStyle(.pnTertiary).font(PN.Font.caption)
        }
        .padding(14)
        .frame(width: 340, height: 400)
    }
}
