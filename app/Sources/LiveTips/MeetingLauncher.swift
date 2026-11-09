import AppKit
import SwiftUI
import LiveTipsCore

/// 0.9.6 (owner, 2026-11-09): Start call also opens the meeting, in the right place. The place is never set up
/// per project: the link tells the platform, this Mac tells the ways it can open (Chrome profiles by email, the
/// Google Meet app of a profile, Teams and Zoom apps, the default browser), and the PM's own choices rank them.
/// A series with a way that worked opens at once with a small "Opened in ..." panel and a Wrong place button;
/// anything new asks once. Rules and ranking: LiveTipsCore/MeetingLaunch.swift.
@MainActor
final class MeetingLauncher {
    static let shared = MeetingLauncher()
    static let enabledKey = "meetOpenOnStart"

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    private var history: [LaunchRecord] = []
    private var path: URL { AppPaths.support.appendingPathComponent("meeting-launches.json") }
    private var panel: NSPanel?
    private var meetAppID: String?                   // the Chrome app id of the Google Meet app

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: path), let h = try? dec.decode([LaunchRecord].self, from: d) { history = h }
    }

    var rememberedCount: Int { history.count }
    func forgetAll() { history = []; save() }

    // MARK: this Mac

    static let chromeApp = "/Applications/Google Chrome.app"
    private static var chromeSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome")
    }

    func environment() -> LaunchEnvironment {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.chromeApp),
              let ls = try? Data(contentsOf: Self.chromeSupport.appendingPathComponent("Local State")) else {
            return LaunchEnvironment(profiles: [], teamsApp: Self.has("com.microsoft.teams2") || Self.has("com.microsoft.teams"), zoomApp: Self.has("us.zoom.xos"))
        }
        var profiles = ChromeProfile.parse(localState: ls)
        for i in profiles.indices {
            let pref = Self.chromeSupport.appendingPathComponent(profiles[i].dir).appendingPathComponent("Preferences")
            profiles[i].accounts = (try? Data(contentsOf: pref)).map(ChromeProfile.accounts) ?? []
        }
        // The Google Meet app: one shim for all profiles (~/Applications/Chrome Apps.localized/Google Meet.app names
        // the app id); a profile has it when its "Web Applications/Manifest Resources/<id>" exists.
        meetAppID = nil
        let appsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized")
        for name in (try? fm.contentsOfDirectory(atPath: appsDir.path)) ?? [] where name.hasSuffix(".app") {
            let plist = appsDir.appendingPathComponent(name).appendingPathComponent("Contents/Info.plist")
            if let d = try? Data(contentsOf: plist),
               let o = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
               (o["CrAppModeShortcutURL"] as? String ?? "").contains("meet.google.com"), let id = o["CrAppModeShortcutID"] as? String {
                meetAppID = id; break
            }
        }
        let dirs = meetAppID.map { id in
            profiles.map(\.dir).filter { fm.fileExists(atPath: Self.chromeSupport.appendingPathComponent($0).appendingPathComponent("Web Applications/Manifest Resources/" + id).path) }
        } ?? []
        return LaunchEnvironment(profiles: profiles, meetAppDirs: dirs,
                                 teamsApp: Self.has("com.microsoft.teams2") || Self.has("com.microsoft.teams"), zoomApp: Self.has("us.zoom.xos"))
    }

    private static func has(_ bundle: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil }

    static func label(_ w: LaunchWay) -> String {
        switch w.kind {
        case .chrome, .meetApp:
            let base = L(w.kind == .chrome ? "launch.way.chrome" : "launch.way.meetApp", ["profile": w.profile])
            return w.account.isEmpty ? base : base + " " + L("launch.as", ["account": w.account])
        case .teamsApp: return L("launch.way.teamsApp")
        case .zoomApp: return L("launch.way.zoomApp")
        case .browser: return L("launch.way.browser")
        }
    }

    /// The domain most attendees share, for a series not seen yet ("orbit.com" for the client's calls).
    static func organizer(_ e: CalendarService.CalEvent) -> String {
        let doms = e.emails.compactMap { $0.split(separator: "@").last.map(String.init) }.filter { !["gmail.com", "googlemail.com"].contains($0) }
        return Dictionary(grouping: doms, by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key ?? ""
    }

    // MARK: Start call

    /// Called once a call has started. Opens the event's meeting: at once when this series already has a way that
    /// worked, otherwise asks where. Nothing happens without a link or with the setting off.
    func open(_ e: CalendarService.CalEvent) {
        guard enabled, let link = e.link, !link.isEmpty else { return }
        let platform = MeetingPlatform.of(link)
        let env = environment()
        let r = LaunchRanking.rank(env.ways(for: platform, invited: e.accounts), history: history, platform: platform, series: e.seriesKey,
                                   organizer: Self.organizer(e), invited: e.accounts)
        guard let first = r.ways.first else { return }
        let ctx = Context(event: e, link: link, platform: platform, ways: r.ways, profiles: env.profiles)
        if r.auto {
            if launch(first, ctx) { show(ctx, opened: first) } else { show(ctx, opened: nil) }
        } else {
            show(ctx, opened: nil)
        }
    }

    struct Context {
        var event: CalendarService.CalEvent
        var link: String
        var platform: MeetingPlatform
        var ways: [LaunchWay]
        var profiles: [ChromeProfile]
    }

    /// Opens one way and remembers it as right (Wrong place turns it around). Returns false when it could not open.
    @discardableResult
    func launch(_ w: LaunchWay, _ c: Context) -> Bool {
        let url = MeetingURL.forWay(c.link, w)
        var ok = false
        switch w.kind {
        case .chrome:
            if let dir = ChromeProfile.dir(for: w.profile, in: c.profiles) {
                ok = run("/usr/bin/open", ["-na", Self.chromeApp, "--args", "--profile-directory=" + dir, url])
            }
        case .meetApp:
            if let dir = ChromeProfile.dir(for: w.profile, in: c.profiles), let id = meetAppID {
                ok = run("/usr/bin/open", ["-na", Self.chromeApp, "--args", "--profile-directory=" + dir, "--app-id=" + id,
                                           "--app-launch-url-for-shortcuts-menu-item=" + url])
            }
        case .teamsApp, .zoomApp, .browser:
            let target = w.kind == .teamsApp ? Self.teamsAppURL(c.link) : url
            if let u = URL(string: target) { ok = NSWorkspace.shared.open(u) }
        }
        if ok {
            history.append(LaunchRecord(at: Date(), platform: c.platform, series: c.event.seriesKey,
                                        organizer: Self.organizer(c.event), way: w.id, ok: true))
            save()
        }
        return ok
    }

    /// Wrong place: the last start of this series with this way was not right; the panel then offers the others.
    func markWrong(_ w: LaunchWay, _ c: Context) {
        if let i = history.lastIndex(where: { $0.way == w.id && $0.series == c.event.seriesKey }) { history[i].ok = false; save() }
    }

    /// https://teams.microsoft.com/l/meetup-join/... -> msteams:/l/meetup-join/... (the Teams app's own link)
    static func teamsAppURL(_ link: String) -> String {
        guard let r = link.range(of: "teams.microsoft.com/") else { return link }
        return "msteams:/" + link[r.upperBound...]
    }

    private func run(_ exe: String, _ args: [String]) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(Array(history.suffix(400))).write(to: path, options: .atomic)
    }

    // MARK: the panel

    private func show(_ c: Context, opened: LaunchWay?) {
        panel?.orderOut(nil)
        let m = LaunchPanelModel(ctx: c, opened: opened)
        let host = NSHostingView(rootView: LaunchPanelView(model: m) { [weak self] in self?.panel?.orderOut(nil) })
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.setContentSize(host.fittingSize)
        if let s = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: s.maxX - p.frame.width - 16, y: s.maxY - p.frame.height - 16)) }
        p.orderFrontRegardless()
        panel = p
        m.resize = { [weak p, weak host] in if let p = p, let h = host { let top = p.frame.maxY; p.setContentSize(h.fittingSize); p.setFrameOrigin(NSPoint(x: p.frame.minX, y: top - p.frame.height)) } }
        if opened != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak m] in
                if let m = m, !m.choosing, self?.panel === p { p.orderOut(nil) }
            }
        }
    }
}

@MainActor
final class LaunchPanelModel: ObservableObject {
    let ctx: MeetingLauncher.Context
    @Published var opened: LaunchWay?
    @Published var choosing: Bool
    @Published var failed = false
    var resize: () -> Void = {}

    init(ctx: MeetingLauncher.Context, opened: LaunchWay?) {
        self.ctx = ctx; self.opened = opened; self.choosing = opened == nil
    }

    var others: [LaunchWay] { ctx.ways.filter { $0 != opened } }

    func pick(_ w: LaunchWay) {
        if MeetingLauncher.shared.launch(w, ctx) { opened = w; choosing = false; failed = false } else { failed = true }
        resize()
    }

    func wrong() {
        if let o = opened { MeetingLauncher.shared.markWrong(o, ctx) }
        choosing = true
        resize()
    }
}

struct LaunchPanelView: View {
    @ObservedObject var model: LaunchPanelModel
    var close: () -> Void
    @State private var all = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.ctx.event.title).font(PN.Font.section).foregroundStyle(PN.C.text).lineLimit(1)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(PN.C.text3)
                    .accessibilityLabel(L("common.close"))
            }
            if let o = model.opened, !model.choosing {
                Text(L("launch.opened", ["way": MeetingLauncher.label(o)])).font(PN.Font.body).foregroundStyle(PN.C.text2)
                HStack {
                    Button(L("launch.wrong")) { model.wrong() }.buttonStyle(.pnSecondary)
                    Spacer()
                }
            } else {
                Text(model.opened == nil ? L("launch.where") : L("launch.whereInstead")).font(PN.Font.body).foregroundStyle(PN.C.text2)
                let list = model.choosing && model.opened != nil ? model.others : model.ctx.ways
                ForEach(all ? list : Array(list.prefix(4))) { w in
                    Button { model.pick(w) } label: {
                        HStack { Text(MeetingLauncher.label(w)).lineLimit(1); Spacer(minLength: 0) }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pnSecondary)
                }
                if !all && list.count > 4 {
                    Button(L("launch.more", ["n": "\(list.count - 4)"])) { all = true; DispatchQueue.main.async { model.resize() } }
                        .buttonStyle(.plain).foregroundStyle(PN.C.accent).font(PN.Font.caption)
                }
                if model.failed { Text(L("launch.failed")).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
                Text(L("launch.remember")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: PN.Radius.l).fill(PN.C.surface))
        .overlay(RoundedRectangle(cornerRadius: PN.Radius.l).stroke(PN.C.text3.opacity(0.2)))
    }
}
