import SwiftUI
import LiveTipsCore

// 0.25 (R3b): the shared look of the preparation screens (boards SU, QP, EA, EB): flat sections under a heavy rule
// with a mono number, mono field labels, square framed fields and square status marks. The call pages (R2) use
// PageSectionHead; these are the same lines with the number the setup boards add.

/// A numbered section head (board SECROW: mono "01" and the H2 of the style over a heavy rule).
struct PrepSectionHead<Trailing: View>: View {
    let number: Int?
    let title: String
    /// 0.25 (R3c-2): the short line after the title (boards EA: "A preset only sets...", counts in mono).
    var note: String = ""
    var mono = false
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.pnTheme) private var t

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let number {
                Text(String(format: "%02d", number)).font(t.homeMono(11, .semibold)).foregroundStyle(PN.C.text3)
                    .accessibilityHidden(true)
            }
            Text(title).pnSection().foregroundStyle(PN.C.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !note.isEmpty {
                Text(note).font(mono ? t.homeMono(11) : t.homeText(13)).foregroundStyle(PN.C.text3)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.top, 10).padding(.bottom, 2)
        .overlay(alignment: .top) { Rectangle().fill(PN.C.ruleStrong).frame(height: t.ruleHeavy) }
    }
}

extension PrepSectionHead where Trailing == EmptyView {
    init(number: Int?, title: String, note: String = "", mono: Bool = false) {
        self.init(number: number, title: title, note: note, mono: mono, trailing: { EmptyView() })
    }
}

/// The head of an Expert step (boards EA, EB): the display face at 34, capitals where the style sets them, and the
/// line under it.
struct PrepPageHead: View {
    let title: String
    let sub: String
    @Environment(\.pnTheme) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.cased(title)).font(t.homeDisplay(34, t.heroWeight)).tracking(t.dTrack * 34).foregroundStyle(PN.C.text)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            if !sub.isEmpty {
                Text(sub).font(t.homeText(15)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The label over a field (board LBL): mono 11, upper case in the styles that set caps, ink3.
struct PrepFieldLabel: View {
    let text: String
    @Environment(\.pnTheme) private var t
    var body: some View {
        Text(t.cased(text))
            .font(t.style == .classic ? PN.Font.caption.weight(.semibold) : t.homeMono(11, t.labelWeight))
            .tracking(t.style == .classic ? 0 : t.lblTrack * 11)
            .foregroundStyle(t.style == .classic ? PN.C.text2 : PN.C.text3)
    }
}

extension View {
    /// The frame of an input (board: 1.5 px in the field colour on the surface; square outside Classic).
    func prepField(height: CGFloat? = nil, border: Color? = nil) -> some View {
        modifier(PrepFieldFrame(height: height, border: border))
    }
}

private struct PrepFieldFrame: ViewModifier {
    let height: CGFloat?
    let border: Color?
    @Environment(\.pnTheme) private var t
    func body(content: Content) -> some View {
        let r: CGFloat = t.style == .classic ? PN.Radius.s : 0
        content
            .padding(.horizontal, 10)
            .frame(minHeight: height, alignment: .leading)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: r))
            .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(border ?? PN.C.field, lineWidth: 1.5))
    }
}

/// A status mark (board TAG): a 10 px square (a dot in Classic) and the status in mono capitals.
struct PrepStatusTag: View {
    let text: String
    let color: Color
    @Environment(\.pnTheme) private var t
    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: t.statusSquare ? 0 : 5).fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(t.style == .classic ? text : text.uppercased())
                .font(t.style == .classic ? PN.sys(12, .semibold) : t.homeMono(11, .semibold))
                .tracking(t.style == .classic ? 0 : 0.4)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// The readiness of a built sheet as a status mark (QP, SU block 4, the call pages).
struct SheetReadinessTag: View {
    let badge: ReadinessBadge
    var body: some View {
        PrepStatusTag(text: SheetLabels.readinessLine(badge), color: SheetLabels.readiness(badge).color)
    }
}

// MARK: - 0.25 (R3c-2): the controls of the Expert boards (EA)

/// A menu shown as a framed field with "▾" (board SELECT: Project, Sheet language, Remind me).
struct PrepMenuField<Items: View>: View {
    let value: String
    @ViewBuilder var items: () -> Items
    @Environment(\.pnTheme) private var t
    var body: some View {
        Menu { items() } label: {
            Text(value + " ▾").font(t.homeText(15, .medium)).foregroundStyle(PN.C.text).lineLimit(1)
                .padding(.horizontal, 10).frame(height: 34)
                .background(PN.C.surface)
                .overlay(RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0).strokeBorder(PN.C.field, lineWidth: 1.5))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

/// A text link of the boards: underlined, in ink ("+ Add a block", "Show all 18", "What can I add?").
struct PrepLink: View {
    let text: String
    let action: () -> Void
    @Environment(\.pnTheme) private var t
    var body: some View {
        Button(action: action) {
            Text(text).font(t.homeText(13, .semibold)).underline().foregroundStyle(PN.C.text)
        }
        .buttonStyle(.plain)
    }
}

/// A chip that can be picked (board CHIP): framed, the picked one on the selection plate.
struct PrepChip<Content: View>: View {
    let on: Bool
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.pnTheme) private var t
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0)
        Button(action: action) {
            content()
                .foregroundStyle(on ? PNSelect.ink : PN.C.text)
                .padding(.horizontal, 12).frame(minHeight: 34)
                .background(on ? PNSelect.fill : PN.C.surface, in: shape)
                .overlay(shape.strokeBorder(on ? Color.clear : PN.C.field, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
    }
}

/// Two or three joined choices in the text face (board "From the calendar | Without an event").
struct PrepChoice<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Environment(\.pnTheme) private var t
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0)
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].0 == selection
                Button { selection = options[i].0 } label: {
                    Text(options[i].1).font(t.homeText(14, on ? .semibold : .medium)).lineLimit(1)
                        .foregroundStyle(on ? PNSelect.ink : PN.C.text)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(on ? PNSelect.fill : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
                if i < options.count - 1 { Rectangle().fill(PN.C.field).frame(width: 1.5, height: 30) }
            }
        }
        .background(PN.C.surface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(PN.C.field, lineWidth: 1.5))
        .fixedSize()
        .opacity(enabled ? 1 : 0.5)
    }
}

/// A ticked square that is not a control (board READY MEANS: the rules of the preset).
struct PrepTick: View {
    @Environment(\.pnTheme) private var t
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: t.style == .classic ? 3 : 0).fill(PNSelect.fill)
            Image(systemName: "checkmark").font(PN.sys(9, .bold)).foregroundStyle(PNSelect.ink)
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}
