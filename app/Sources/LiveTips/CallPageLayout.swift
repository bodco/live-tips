import AppKit
import SwiftUI
import LiveTipsCore

// Pacenote 0.25 (R2, boards CP-CallPage, CT-CallTabsA/B, UP-Upcoming, UT-UpcomingTabs, SL-CallSales): the frame of
// both call pages, set from the style's tokens like Home (R1). One layout for every style, Classic too.
// A page is: the bar (‹ Home, what this is, the actions), the title block (mono meta line, the name, a row of facts),
// the status lines of the call (SL), the tabs with a 3 pt line under the chosen one, then sections. A section starts
// with a heavy rule and its name; its rows are split by thin rules. No cards.

/// Side padding of everything on a call page (board: 32 px).
enum PageMetrics {
    static let side: CGFloat = 32
}

/// The bar over a call page (board BACKHDR): "‹ Home", what the page is in mono, the actions on the right.
/// It takes the place of HomeRouteView's Back bar for the call pages.
struct PageBackBar<Right: View>: View {
    let crumb: String
    @ViewBuilder var right: () -> Right
    @ObservedObject private var nav = HomeNav.shared
    @Environment(\.pnTheme) private var t

    var body: some View {
        HStack(spacing: 10) {
            Button { nav.back() } label: {
                Text("‹ " + nav.backTitle(at: max(0, nav.path.count - 1)))
                    .font(t.homeText(14, .semibold)).foregroundStyle(PN.C.text).lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .help(L("nav.back.help"))
            Text(t.caps ? crumb.uppercased() : crumb)
                .font(t.homeMono(12, t.labelWeight)).tracking(t.style == .classic ? 0 : t.lblTrack * 12)
                .foregroundStyle(PN.C.text3).lineLimit(1)
                .padding(.leading, 10)
            Spacer(minLength: 8)
            right()
        }
        .padding(.leading, PageMetrics.side).padding(.trailing, 20)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
    }
}

extension PageBackBar where Right == EmptyView {
    init(crumb: String) { self.init(crumb: crumb, right: { EmptyView() }) }
}

/// The title block (board: LBL meta line, h1 40 px, a row of facts or the big status).
struct PageTitleBlock<Row: View>: View {
    let meta: String
    let title: String
    var bottom: CGFloat = 20
    @ViewBuilder var row: () -> Row
    @Environment(\.pnTheme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !meta.isEmpty {
                Text(t.caps ? meta.uppercased() : meta)
                    .font(t.homeMono(11, t.labelWeight)).tracking(t.style == .classic ? 0 : t.lblTrack * 11)
                    .foregroundStyle(PN.C.text3).lineLimit(2)
            }
            Text(title)
                .font(t.homeDisplay(t.style == .classic ? 32 : 40, t.titleWeight))
                .tracking(t.dTrack * 40)
                .foregroundStyle(PN.C.text)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            row()
        }
        .padding(.horizontal, PageMetrics.side).padding(.top, 24).padding(.bottom, bottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A count next to a tab or a section name: mono 11; "warn" sets it on the not-ready plate (board "2 open", "not built").
struct PageCount: View {
    let text: String
    var warn = false
    @Environment(\.pnTheme) private var t
    var body: some View {
        let plate = warn ? t.nrBg.map { Color(pnHex: $0) } : nil
        Text(text).font(t.homeMono(11, .semibold)).monospacedDigit()
            .foregroundStyle(warn ? PN.C.notreadyText : PN.C.text3)
            .padding(.horizontal, plate == nil ? 0 : 5)
            .background(plate ?? .clear)
            .lineLimit(1).fixedSize()
    }
}

/// Inside a tinted block (For the next call, Next step) a section head has no heavy rule of its own.
private struct PageInTintKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var pageInTint: Bool { get { self[PageInTintKey.self] } set { self[PageInTintKey.self] = newValue } }
}

/// The head of a section (board SECROW + H2): a heavy rule over the name, a count, and links or buttons on the right.
struct PageSectionHead<Trailing: View>: View {
    let title: String
    var count: String = ""
    var warn = false
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.pnTheme) private var t
    @Environment(\.pageInTint) private var inTint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).pnSection().foregroundStyle(PN.C.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !count.isEmpty { PageCount(text: count, warn: warn) }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.top, inTint ? 0 : 10).padding(.bottom, 8)
        .overlay(alignment: .top) { if !inTint { Rectangle().fill(PN.C.ruleStrong).frame(height: t.ruleHeavy) } }
    }
}

extension PageSectionHead where Trailing == EmptyView {
    init(title: String, count: String = "", warn: Bool = false) { self.init(title: title, count: count, warn: warn, trailing: { EmptyView() }) }
}

extension View {
    /// A row of a section: a thin rule over it (board ROW).
    func pageRow(_ v: CGFloat = 9) -> some View {
        self.padding(.vertical, v)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
    }
    /// The tinted block of the boards (For the next call, Next step): surface2 with a 3 pt line in the link colour on top.
    func pageTint() -> some View {
        self.environment(\.pageInTint, true)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.surface2)
            .overlay(alignment: .top) { Rectangle().fill(PN.C.accent).frame(height: 3) }
    }
}

/// The time of a line as a link to the transcript (board: mono 12, link colour).
struct PageTimeLink: View {
    let time: String
    let run: () -> Void
    @Environment(\.pnTheme) private var t
    var body: some View {
        Button(action: run) {
            Text(String(time.prefix(5))).font(t.homeMono(12, .semibold)).monospacedDigit().foregroundStyle(PN.C.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("page.mn.jump")).accessibilityLabel(L("page.mn.jumpTo", ["time": String(time.prefix(5))]))
    }
}

/// One status line of the call under the title (board SL): a mono key, a dot, what is true, a note, and the actions.
struct PageStatusLine<Trailing: View>: View {
    let key: String
    let kind: HomeTag
    let value: String
    var sub = ""
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.pnTheme) private var t

    var body: some View {
        let plate = kind.plate(t)
        HStack(alignment: .center, spacing: 14) {
            Text(t.caps ? key.uppercased() : key)
                .font(t.homeMono(11, t.labelWeight)).tracking(t.style == .classic ? 0 : t.lblTrack * 11)
                .foregroundStyle(PN.C.text3).lineLimit(1)
                .frame(width: 110, alignment: .leading)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: t.statusSquare ? 0 : 4).fill(kind.dot(t)).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(value).font(t.homeText(14))
                    .foregroundStyle(kind == .notReady ? kind.text(t) : kind == .neutral ? PN.C.text2 : PN.C.text)
                    .padding(.horizontal, plate == nil ? 0 : 5).background(plate ?? .clear)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !sub.isEmpty {
                    Text(sub).font(t.homeText(13)).foregroundStyle(PN.C.text3).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) { trailing() }.fixedSize()
        }
        .padding(.vertical, 7).frame(minHeight: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

extension PageStatusLine where Trailing == EmptyView {
    init(key: String, kind: HomeTag, value: String, sub: String = "") { self.init(key: key, kind: kind, value: value, sub: sub, trailing: { EmptyView() }) }
}

/// A small action of a status line (board: link 13 px).
struct PageLineLink: View {
    let title: String
    let run: () -> Void
    init(_ title: String, run: @escaping () -> Void) { self.title = title; self.run = run }
    var body: some View { HomeLink(title, size: 13, run: run) }
}

/// The 28 pt bordered button of a row (board BTNS height 28).
extension ButtonStyle where Self == PNOutlineButtonStyle {
    static var pnRow: PNOutlineButtonStyle { PNOutlineButtonStyle(height: 28) }
    static var pnBar: PNOutlineButtonStyle { PNOutlineButtonStyle(height: 32) }
}

/// The "add a line" field of a section: dashed frame, Return adds (board: "Type and press Return").
struct PageAddField: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 30
    let onSubmit: () -> Void
    @Environment(\.pnTheme) private var t
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(t.homeText(14))
            .padding(.horizontal, 10).frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0)
                .strokeBorder(PN.C.field, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .onSubmit(onSubmit)
    }
}

/// A plain field of a page (board: surface fill, 1.5 pt frame in the field colour).
struct PageFieldFrame: ViewModifier {
    var height: CGFloat = 36
    @Environment(\.pnTheme) private var t
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(t.homeText(15))
            .padding(.horizontal, 10).frame(height: height)
            .background(PN.C.surface)
            .overlay(RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0).strokeBorder(PN.C.field, lineWidth: 1.5))
    }
}
extension View { func pageField(_ h: CGFloat = 36) -> some View { modifier(PageFieldFrame(height: h)) } }

/// Two columns side by side on a wide page, one under the other on a narrow one (board grid 1fr 1fr / 1fr 360px).
/// The page says whether it is wide (environment pageWide, from its measured width): ViewThatFits measured the ideal
/// width of unwrapped text and always fell back to one column.
private struct PageWideKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var pageWide: Bool { get { self[PageWideKey.self] } set { self[PageWideKey.self] = newValue } }
}

struct PageColumns<L: View, R: View>: View {
    var side: CGFloat? = nil          // nil: equal columns
    var spacing: CGFloat = 40
    @ViewBuilder var left: () -> L
    @ViewBuilder var right: () -> R
    @Environment(\.pageWide) private var wide
    var body: some View {
        if wide {
            HStack(alignment: .top, spacing: spacing) {
                left().frame(maxWidth: .infinity, alignment: .topLeading)
                if let side { right().frame(width: side, alignment: .topLeading) }
                else { right().frame(maxWidth: .infinity, alignment: .topLeading) }
            }
        } else {
            VStack(alignment: .leading, spacing: 26) { left(); right() }
        }
    }
}

extension Notification.Name {
    /// Shot mode only: the tab a call page shows now (object: the tab's id).
    static let pnShotTab = Notification.Name("PNShotTab")
}

/// A risk waiting for the confirmation sheet.
struct RiskAsk: Identifiable { let text: String; var id: String { text } }

/// 0.25 (R2 tail, board CT row 4): a confirmation in the style: a display title, what happens, Cancel and the action.
struct PageConfirmSheet: View {
    let title: String
    let text: String
    let go: String
    let onCancel: () -> Void
    let onGo: () -> Void
    @Environment(\.pnTheme) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.cased(title)).font(t.homeDisplay(24, t.titleWeight)).tracking(t.dTrack * 24).foregroundStyle(PN.C.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(text).font(t.homeText(15)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button(L("common.cancel"), action: onCancel).buttonStyle(.pnBar).keyboardShortcut(.cancelAction)
                Button(go, action: onGo).buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)
        .frame(width: 460)
        .background(PN.C.bg)
    }
}
