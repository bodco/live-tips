import AppKit
import SwiftUI
import LiveTipsCore

// Pacenote 0.24 (R1, boards HM-Home, HS-HomeStates, HB-HomeBanners): the pieces of Home's layout, set from the
// style's tokens. One layout for every style (Classic too); only the tokens change.

extension PNTheme {
    /// The text face (Classic: the system font).
    func homeText(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        style == .classic ? .system(size: size, weight: weight) : font(.text, size, weight)
    }
    /// The mono face of labels, times and tags.
    func homeMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        style == .classic ? .system(size: size, weight: weight).monospacedDigit() : font(.mono, size, weight)
    }
    /// The display face of numbers, titles and buttons.
    func homeDisplay(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        style == .classic ? .system(size: size, weight: weight == .black ? .heavy : weight) : font(.display, size, weight)
    }
    /// Weight of the big numbers (board heroW: Roadbook 800, Broadsheet 900).
    var heroWeight: Font.Weight { style == .broadsheet ? .black : style == .roadbook ? .heavy : .bold }
    /// Weight of the call title (board tW: Roadbook 700, Broadsheet 800).
    var titleWeight: Font.Weight { style == .broadsheet ? .heavy : .bold }
    /// Weight of mono labels (board lblW: Roadbook 600, Broadsheet 400).
    var labelWeight: Font.Weight { style == .roadbook ? .semibold : .regular }
    /// Tracking of the big numbers in em (board numLS).
    var numTrack: CGFloat { style == .broadsheet ? -0.075 : style == .classic ? -0.02 : 0 }
    /// Side padding of text on the highlight plate (board hlPad).
    var plateInset: CGFloat { hlBg != nil ? 10 : 0 }

    /// The countdown of the hero (board HM): Roadbook sets the words as large as the number on one line,
    /// Broadsheet puts a small line over a very large number, Classic the same at a quieter size.
    struct Countdown { let pre, num, unit: CGFloat; let preOwnLine: Bool }
    var countdown: Countdown {
        switch style {
        case .roadbook: return Countdown(pre: 88, num: 88, unit: 88, preOwnLine: false)
        case .broadsheet: return Countdown(pre: 20, num: 220, unit: 44, preOwnLine: true)
        case .classic: return Countdown(pre: 20, num: 96, unit: 32, preOwnLine: true)
        }
    }
}

/// The kind of a status tag: the colour of its dot and text, and the plate of "not ready".
enum HomeTag {
    case notReady, ready, rec, answer, neutral

    static func of(_ s: CallState) -> HomeTag {
        switch s {
        case .notReady, .failed, .noBrief, .notTranscribed: return .notReady
        case .ready, .recorded: return .ready
        case .live: return .rec
        case .preparing, .queued: return .answer
        }
    }

    func text(_ t: PNTheme) -> Color {
        switch self {
        case .notReady: return Color(pnHex: t.notreadyText)
        case .ready: return Color(pnHex: t.readyText)
        case .rec: return Color(pnHex: t.recText)
        case .answer: return Color(pnHex: t.answer)
        case .neutral: return Color(pnHex: t.ink2)
        }
    }
    func dot(_ t: PNTheme) -> Color {
        switch self {
        case .notReady: return Color(pnHex: t.notready)
        case .ready: return Color(pnHex: t.ready)
        case .rec: return Color(pnHex: t.rec)
        case .answer: return Color(pnHex: t.answer)
        case .neutral: return Color(pnHex: t.ink3)
        }
    }
    func plate(_ t: PNTheme) -> Color? { self == .notReady ? t.nrBg.map { Color(pnHex: $0) } : nil }
}

/// A status dot with an edge: square in Roadbook, round elsewhere (board stR).
struct HomeDot: View {
    let color: Color
    var size: CGFloat = 10
    @Environment(\.pnTheme) private var t
    var body: some View {
        RoundedRectangle(cornerRadius: t.statusSquare ? 0 : size / 2)
            .fill(color)
            .overlay(RoundedRectangle(cornerRadius: t.statusSquare ? 0 : size / 2).strokeBorder(Color(pnHex: t.edge), lineWidth: 1.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Theme pass (19.11, prototype "soft"): the quiet tag of Later today: a small mark in the state's colour and the
/// words in ink3, the text face, as written (no capitals, no plate).
struct HomeQuietTag: View {
    let kind: HomeTag
    let text: String
    @Environment(\.pnTheme) private var t
    var body: some View {
        HStack(spacing: 6) {
            HomeDot(color: kind.dot(t), size: 7)
            Text(text).font(t.homeText(13, .medium)).foregroundStyle(PN.C.text3).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Theme pass (19.11, prototype "btn q"): a quiet header button, no fill, a 1.5 pt line in the rule colour, text in ink2.
/// For actions that are not this meeting's (Plan a call, New call).
struct PNQuietButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    @Environment(\.isEnabled) private var enabled
    @Environment(\.pnTheme) private var t
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.style == .classic ? 7 : 0)
        configuration.label
            .font(t.buttonFont)
            .tracking(t.buttonTracking)
            .textCase(t.caps ? .uppercase : nil)
            .foregroundStyle(PN.C.text2)
            .padding(.horizontal, 12).frame(height: height)
            .background(PN.C.text.opacity(configuration.isPressed ? 0.08 : 0), in: shape)
            .overlay(shape.strokeBorder(t.style == .classic ? Color.primary.opacity(0.15) : PN.C.rule, lineWidth: 1.5))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.45)
    }
}

/// How long a preparation usually takes (PrepEstimate over state/spend-ledger.jsonl), read again only when the file changes.
enum HomePrepEstimate {
    nonisolated(unsafe) private static var stamp: Date?
    nonisolated(unsafe) private static var value: Int?
    static func seconds() -> Int? {
        let path = ((AIRoute.statePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("spend-ledger.jsonl")
        let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if m != stamp {
            stamp = m
            value = m == nil ? nil : (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { PrepEstimate.seconds(ledger: $0) }
        }
        return value
    }
    /// "Prepare brief · ~40 s", or "Prepare brief" without an estimate.
    static var label: String {
        guard let s = seconds() else { return L("home.prepareBrief") }
        let (n, min) = PrepEstimate.rounded(s)
        return L("home.prepareBrief.est", ["t": L(min ? "home.est.min" : "home.est.sec", ["n": "\(n)"])])
    }
}

/// The status tag of a row (board TAG), or the big status line of the hero (board BIG) with its explanation.
struct HomeTagView: View {
    let kind: HomeTag
    let text: String
    var big = false
    var sub = ""
    @Environment(\.pnTheme) private var t

    var body: some View {
        let plate = kind.plate(t)
        HStack(spacing: big ? 8 : 6) {
            HomeDot(color: kind.dot(t), size: big ? 12 : 10)
            Text(big ? t.cased(text) : (t.caps ? text.uppercased() : text))
                .font(big ? t.homeDisplay(20, .heavy) : t.homeMono(11, .semibold))
                .tracking(big && t.style != .classic ? t.bTrack * 20 : 0)
                .foregroundStyle(kind.text(t))
                .padding(.horizontal, plate == nil ? 0 : 5)
                .background(plate ?? .clear)
                .lineLimit(1).fixedSize()
            if big && !sub.isEmpty {
                Text(sub).font(t.homeText(15)).foregroundStyle(PN.C.text2).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The mono line over a block: date, times, project, meeting app (board LBL).
struct HomeMeta: View {
    let text: String
    @Environment(\.pnTheme) private var t
    var body: some View {
        Text(t.caps ? text.uppercased() : text)
            .font(t.homeMono(12, t.labelWeight))
            .tracking(t.style == .classic ? 0 : t.lblTrack * 12)
            .foregroundStyle(PN.C.text3)
            .lineLimit(2)
    }
}

/// A text link in the link colour (board LINK).
struct HomeLink: View {
    let title: String
    var size: CGFloat = 14
    var color: Color? = nil
    let run: () -> Void
    @Environment(\.pnTheme) private var t
    init(_ title: String, size: CGFloat = 14, color: Color? = nil, run: @escaping () -> Void) {
        self.title = title; self.size = size; self.color = color; self.run = run
    }
    var body: some View {
        Button(action: run) {
            Text(title).font(t.homeText(size, .semibold)).foregroundStyle(color ?? PN.C.accent).underline(t.style != .classic)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The bordered button of the boards (BTNS): no fill, a 1.5 pt line in ruleStrong, the display face.
/// 32 pt in the header, 40 pt in the short hero, 48 pt next to the big button.
struct PNOutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    @Environment(\.isEnabled) private var enabled
    @Environment(\.pnTheme) private var t
    func makeBody(configuration: Configuration) -> some View {
        let big = height >= 44
        let shape = RoundedRectangle(cornerRadius: t.style == .classic ? (big ? 12 : 7) : 0)
        configuration.label
            .font(big ? t.heroFont : t.buttonFont)
            .tracking(t.style == .classic ? 0 : t.bTrack * (big ? t.bigBtn : t.bSize))
            .textCase(t.caps ? .uppercase : nil)
            .foregroundStyle(PN.C.text)
            .padding(.horizontal, big ? 20 : 12).frame(height: height)
            .background(PN.C.text.opacity(configuration.isPressed ? 0.08 : 0), in: shape)
            .overlay(shape.strokeBorder(t.style == .classic ? Color.primary.opacity(0.22) : PN.C.ruleStrong, lineWidth: t.style == .classic ? 1 : 1.5))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.45)
    }
}

/// The main button at a height other than 48 (the short hero of HB: 40 pt).
struct PNSolidButtonStyle: ButtonStyle {
    var height: CGFloat = 40
    @Environment(\.isEnabled) private var enabled
    @Environment(\.pnTheme) private var t
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.style == .classic ? 9 : 0)
        configuration.label
            .font(t.buttonFont).tracking(t.buttonTracking).textCase(t.caps ? .uppercase : nil)
            .foregroundStyle(PN.C.onAccent)
            .padding(.horizontal, 20).frame(height: height)
            .background(PN.C.accentFill.opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4), in: shape)
            .overlay(shape.strokeBorder(t.framedAccent ? PN.C.actEdge.opacity(enabled ? 1 : 0.4) : Color.clear, lineWidth: 2))
            .contentShape(shape)
    }
}

/// The face of a filter menu (board FIELD): a 1.5 pt frame in the field colour, mono text.
struct HomeField: View {
    let text: String
    var height: CGFloat = 30
    @Environment(\.pnTheme) private var t
    var body: some View {
        Text((t.caps ? text.uppercased() : text) + " ▾")
            .font(t.homeMono(12, .semibold))
            .foregroundStyle(PN.C.text)
            .lineLimit(1)
            .padding(.horizontal, 10).frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0).strokeBorder(t.style == .classic ? Color.primary.opacity(0.22) : PN.C.field, lineWidth: 1.5))
            .contentShape(Rectangle())
    }
}

/// A 32 pt icon button of the header in ink2.
struct HomeIconButton: View {
    let symbol: String
    let label: String
    let run: () -> Void
    var body: some View {
        Button(action: run) {
            Image(systemName: symbol).font(PN.sys(15, .medium)).foregroundStyle(PN.C.text2)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

/// Text on a plate when a fill is given; otherwise plain text. Theme pass (19.11, owner): on Home the yellow fill is the
/// main button's only, so the countdown and the big words no longer sit on the highlight plate.
struct HomePlate: View {
    let text: String
    let font: Font
    var tracking: CGFloat = 0
    var fill: Color? = nil
    var ink: Color? = nil
    @Environment(\.pnTheme) private var t
    var body: some View {
        Text(text).font(font).tracking(tracking)
            .foregroundStyle(ink ?? PN.C.text)
            .padding(.horizontal, fill == nil ? 0 : 8)
            .background(fill ?? .clear)
    }
}

/// The problems pill of the header (board HB, row 2): it takes the place of "AI ok" when something needs the PM.
struct HomeProblemPill: View {
    let text: String
    @Environment(\.pnTheme) private var t
    var body: some View {
        HStack(spacing: 6) {
            HomeDot(color: PN.C.notready, size: 8)
            Text(t.caps ? text.uppercased() : text).lineLimit(1)
        }
        .font(t.homeMono(12, .semibold))
        .foregroundStyle(PN.C.notreadyText)
        .padding(.horizontal, 10).frame(height: 28)
        .background(PN.C.notreadyPlate, in: RoundedRectangle(cornerRadius: t.style == .classic ? 14 : 0))
        .overlay(RoundedRectangle(cornerRadius: t.style == .classic ? 14 : 0).strokeBorder(PN.C.notready, lineWidth: 1.5))
        .contentShape(Rectangle())
    }
}

/// "AI ok" in the header (board HM): a dot and a word; a click opens the limits of the AIs the jobs use.
struct HomeAIStatus: View {
    @ObservedObject private var m = AIStatusModel.shared
    @State private var open = false
    @Environment(\.pnTheme) private var t
    var body: some View {
        let dot: Color = m.level == .out ? PN.C.rec : m.level == .warn ? PN.C.notready : PN.C.ready
        let word = L(m.level == .out ? "home.ai.out" : m.level == .warn ? "home.ai.warn" : "home.ai.ok")
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                HomeDot(color: dot)
                Text(t.caps ? word.uppercased() : word).font(t.homeMono(12, .semibold)).foregroundStyle(PN.C.text2).lineLimit(1)
            }
            .frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.title).accessibilityLabel(m.title)
        .popover(isPresented: $open, arrowEdge: .bottom) { AIStatusList(m: m).frame(width: 380) }
        .onChange(of: open) { if open { AIUsageProbe.shared.popoverOpened() } }
        .onAppear { m.refresh(force: true) }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in m.refresh() }
    }
}

/// One Home banner (board HB, row 1): a soft band with a 4 pt edge in the colour of its kind, a square icon,
/// a title and a line under it, "later" as a link and one main button. Banners stack over the hero.
struct HomeBanner: View {
    let icon: String
    let title: String
    let sub: String
    let edge: Color
    let iconFill: Color
    let iconInk: Color
    var problem: String? = nil
    var extra: (String, () -> Void)? = nil
    var later: (String, () -> Void)? = nil
    let go: String
    var goDisabled = false
    /// The button's work is running (the update downloads or installs): a spinner next to its label.
    var busy = false
    let run: () -> Void
    @Environment(\.pnTheme) private var t

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(icon).font(t.homeDisplay(16, .heavy)).foregroundStyle(iconInk)
                .frame(width: 30, height: 30)
                .background(iconFill, in: RoundedRectangle(cornerRadius: t.statusSquare || t.style != .classic ? 0 : 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(t.homeText(16, .semibold)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                if !sub.isEmpty { Text(sub).font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
                if let p = problem { Text(p).font(t.homeText(13)).foregroundStyle(PN.C.notreadyText) }
            }
            Spacer(minLength: 8)
            if let e = extra { HomeLink(e.0, size: 14, color: PN.C.text2, run: e.1) }
            if let l = later { HomeLink(l.0, size: 14, color: PN.C.text2, run: l.1) }
            Button(action: run) {
                HStack(spacing: 8) {
                    if busy { PNSpinner(size: 14, line: PN.C.onAccent, track: PN.C.onAccent.opacity(0.3)) }
                    Text(go)
                }
            }
            .buttonStyle(.pnPrimary).disabled(goDisabled).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface2)
        .overlay(alignment: .leading) { Rectangle().fill(edge).frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: t.style == .classic ? 8 : 0))
        .accessibilityElement(children: .contain)
    }
}

/// A Recent calls row (board HM): the date, the title with what came out of the call, the state of its notes.
struct HomeRecentRow: View {
    let r: CallHistory.Record
    var onHide: () -> Void
    @Environment(\.pnTheme) private var t

    var body: some View {
        let transcribed = (r.lines ?? 1) > 0
        let notes = transcribed && RecentCard.summary(r.file) != nil
        let kind: HomeTag = !transcribed ? .notReady : notes ? .ready : .neutral
        let tag = L(!transcribed ? "home.tag.notTranscribed" : notes ? "home.tag.notesReady" : "home.tag.transcriptOnly")
        let mins = r.minutes.map { L("call.page.minutes", ["n": "\(max(1, Int($0.rounded())))"]) } ?? ""
        let sub = [r.project, mins, RecentCard.counts(OutcomeCache.shared.outcome(r.file))].filter { !$0.isEmpty }.joined(separator: " · ")
        let series = CallPageView.series(of: r).count
        Button { CallPageWindow.show(file: r.file) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.day(r.start)).font(t.homeMono(12)).foregroundStyle(PN.C.text3).frame(width: 86, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(r.title).font(t.homeText(16, .semibold)).foregroundStyle(PN.C.text).lineLimit(1)
                        if let src = r.source {
                            Text(L(src == "link" ? "tr.mark.link" : "tr.mark.file")).font(t.homeMono(10, .semibold)).foregroundStyle(PN.C.text2)
                                .padding(.horizontal, 4).background(PN.C.surface2)
                        }
                    }
                    if !sub.isEmpty { Text(sub).font(t.homeText(13)).foregroundStyle(PN.C.text2).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HomeTagView(kind: kind, text: tag)
            }
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("home.recent.help.page"))
        .contextMenu {
            if let u = r.notionURL.flatMap({ URL(string: $0) }) { Button(L("home.recent.notion")) { NSWorkspace.shared.open(u) } }
            Button(L("home.recent.transcript")) { TranscriptWindow.show(file: r.file) }
            Button(L("call.page.followup")) { FollowUpWindow.show(file: r.file) }
            if series > 1 { Button(L("call.page.series", ["n": "\(series)"])) { SeriesWindow.show(record: r) } }
            Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.file)]) }
            Button(L("reassign.menu")) { ReassignPanel.show(file: r.file) }
            Divider()
            Button(L("home.recent.hide"), action: onHide)
        }
    }

    /// "Mon 16 Nov"
    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f.string(from: d)
    }
}

/// One row of a key and a value under This week (board HM: AI spend, account limits, not transcribed yet).
struct HomeFactRow<V: View>: View {
    let key: String
    @ViewBuilder let value: () -> V
    @Environment(\.pnTheme) private var t
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).font(t.homeText(15)).foregroundStyle(PN.C.text).frame(maxWidth: .infinity, alignment: .leading)
            value()
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
    }
}
