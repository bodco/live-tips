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
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(36 * 3600), calendars: use)
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
                    return a.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").components(separatedBy: "@").first
                }
            let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
            out.append(CalEvent(id: (e.eventIdentifier ?? e.calendarItemIdentifier) + "@" + String(Int(e.startDate.timeIntervalSince1970)),
                                seriesKey: key, title: (e.title ?? "").isEmpty ? "Untitled event" : e.title!,
                                start: e.startDate, end: e.endDate, calendar: e.calendar.title, account: e.calendar.source.title,
                                color: e.calendar.color ?? .systemBlue, attendees: names, link: Self.meetingLink(in: text),
                                recurring: e.hasRecurrenceRules))
        }
        events = out.sorted { $0.start < $1.start }
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
            c.body = "Starts at \(DateFormatter.localizedString(from: e.start, dateStyle: .none, timeStyle: .short)). Open Live Tips to start or prepare it."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lt-" + e.id, content: c, trigger: nil))
        }
    }
}

/// 2026-10-27 (owner): Settings > Calendars, everything about calendars in one place. Nothing to install:
/// macOS signs in to Google and Microsoft (Internet Accounts) and Live Tips reads the calendars through EventKit.
struct CalendarsPane: View {
    @ObservedObject var cal = CalendarService.shared
    @State private var remembered = SeriesMemory.shared.count

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add each Google or Microsoft account once in macOS; several of each are fine.")
                    Text("Google: Add Account > Google, sign in, keep Calendars on. Microsoft 365 or Outlook: Add Account > Microsoft Exchange (work) or Outlook.com (personal).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    let accounts = Set(cal.calendars.map { $0.source.title }).sorted()
                    Text(accounts.isEmpty ? "No accounts with calendars yet" : accounts.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Open Internet Accounts") { CalendarService.openInternetAccounts() }
                }
            } header: { Text("1. Your accounts") } footer: {
                Text("Nothing to install: macOS keeps you signed in and syncs the calendars; Live Tips only reads them. A company that blocks Mail and Calendar on Macs blocks this too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Image(systemName: cal.access == .granted ? "checkmark.circle.fill" : "circle").foregroundStyle(cal.access == .granted ? Color.green : Color.secondary)
                    Text(cal.access == .granted ? "Live Tips can read your calendars" : cal.access == .denied ? "Access is off in System Settings" : "Not connected yet")
                    Spacer()
                    if cal.access != .granted { Button(cal.access == .denied ? "Open Privacy settings" : "Connect calendars") { cal.connect() } }
                    else { Button("Refresh") { cal.refresh() } }
                }
            } header: { Text("2. Access") }
            if cal.access == .granted {
                Section {
                    if cal.calendars.isEmpty {
                        Text("No calendars yet. Add an account above, wait a minute for the first sync, then Refresh.").foregroundStyle(.secondary)
                    }
                    CalendarList()
                } header: { Text("3. Calendars with your calls") } footer: {
                    Text("Only the ticked calendars show in Home and Start call. Untick holidays, birthdays and calendars of other people.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Remind me before calendar calls", isOn: $cal.remind)
                    if cal.remind { Stepper("\(cal.remindMinutes) min before", value: $cal.remindMinutes, in: 1...15) }
                    HStack {
                        Text(cal.hidden.isEmpty ? "No events hidden in Home" : "\(cal.hidden.count) events hidden in Home")
                        Spacer()
                        Button("Show them again") { cal.hidden = [] }.disabled(cal.hidden.isEmpty)
                    }
                    HStack {
                        Text("Regular calls remembered: \(remembered)")
                        Spacer()
                        Button("Forget all") { SeriesMemory.shared.forgetAll(); remembered = 0 }.disabled(remembered == 0)
                    }
                } header: { Text("Behaviour") } footer: {
                    Text("The reminder is off by default: your calendar already reminds you. A regular call starts from the settings and the context of its last call (project, audience, type, languages, what matters, folders), so you only correct them.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Text(acc).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("All") { for c in groups[acc] ?? [] { cal.excluded.remove(c.calendarIdentifier) } }.buttonStyle(.link).font(.caption)
                    Button("None") { for c in groups[acc] ?? [] { cal.excluded.insert(c.calendarIdentifier) } }.buttonStyle(.link).font(.caption)
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
            Text("Calendars with your calls").font(.headline)
            Text("Only the ticked ones show in Home and Start call.").font(.caption).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 10) { CalendarList() } }
            Button("More in Settings > Calendars") { SettingsWindow.show(tab: "calendars") }.buttonStyle(.link).font(.caption)
        }
        .padding(14)
        .frame(width: 340, height: 400)
    }
}
