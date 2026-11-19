import SwiftUI
import LiveTipsCore

/// 0.14.0 (D1, Get Ready redesign): chips that wrap as whole chips. The old HStack squeezed every chip until the
/// names broke into syllables ("Ole/na/S.").
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = fitted(v, width)
            if x > 0, x + s.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += s.width + spacing; line = max(line, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: subviews.isEmpty ? 0 : y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = fitted(v, bounds.width)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; line = max(line, s.height)
        }
    }

    /// The chip's own width, never wider than the row (a very long name is cut with "…", not broken).
    private func fitted(_ v: LayoutSubview, _ width: CGFloat) -> CGSize {
        let ideal = v.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return v.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}

/// Who is on the call: our side and their side, next to each other. A person moves between the sides by drag and
/// drop or by the arrow on the chip (keyboard, VoiceOver, automation). You stay on our side.
/// 0.25 (R3c-2, boards EA step 1 and QP attn): Our side on the left, framed chips without avatars, the arrow points
/// to the other side, the field and Add at the bottom of each side.
struct SheetPeopleView: View {
    @ObservedObject var draft: SheetDraft
    /// The small head of its own (Quick); Expert puts the view under its section head.
    var head = true
    @Environment(\.pnTheme) private var th
    @State private var newOurs = ""
    @State private var newTheirs = ""
    @State private var target: Bool?          // true = our side is under the drag, false = their side
    @State private var dragging: UUID?

    private var m: StartCallModel { draft.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if head {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    PrepFieldLabel(text: L("sheet.people.title"))
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                zone(ours: true)
                zone(ours: false)
            }
            Text(sourceLine + " " + L("sheet.people.hint") + ".").font(th.homeText(13)).foregroundStyle(PN.C.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceLine: String {
        let invite = PeopleSides.merge(m.participants).count     // 0.14.0: people, not spellings
        if m.audience == "team" { return L("sheet.people.sourceInternal", ["n": "\(invite)"]) }
        return L("sheet.people.source", ["n": "\(invite)", "project": m.targetName])
    }

    private func zone(ours: Bool) -> some View {
        let list = ours ? draft.ours : draft.theirs
        // Lit only when the person under the drag comes from the other side (dropping on your own side does nothing).
        let from = dragging.flatMap { id in draft.ours.contains { $0.id == id } ? true : (draft.theirs.contains { $0.id == id } ? false : nil) }
        let hot = target == ours && from == !ours
        let shape = RoundedRectangle(cornerRadius: th.style == .classic ? PN.Radius.m : 0)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PrepFieldLabel(text: L(ours ? "sheet.ui.s1.ours" : "sheet.ui.s1.theirs")).accessibilityAddTraits(.isHeader)
                Text(L(list.count == 1 ? "sheet.people.one" : "sheet.people.n", ["n": "\(list.count)"]))
                    .font(th.homeMono(11)).foregroundStyle(PN.C.text3).monospacedDigit()
                Spacer(minLength: 0)
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(list) { p in chip(p, ours: ours) }
            }
            if hot {
                Text(L(ours ? "sheet.people.dropOurs" : "sheet.people.dropTheirs"))
                    .font(th.homeText(13, .semibold)).foregroundStyle(PN.C.text)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .overlay(Rectangle().strokeBorder(PN.C.text, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                TextField(L("sheet.ui.s1.personPh"), text: ours ? $newOurs : $newTheirs)
                    .textFieldStyle(.plain).font(th.homeText(14)).prepField(height: 30)
                    .accessibilityLabel(L(ours ? "sheet.people.addOurs" : "sheet.people.addTheirs"))
                    .onSubmit { add(ours: ours) }
                Button { add(ours: ours) } label: {
                    Text(L("sheet.ui.add")).font(th.homeText(14, .semibold)).foregroundStyle(PN.C.text)
                }
                .buttonStyle(.plain).accessibilityLabel(L(ours ? "sheet.people.addOurs" : "sheet.people.addTheirs"))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(hot ? PNSelect.fill.opacity(0.25) : Color.clear, in: shape)
        .overlay(shape.strokeBorder(hot ? PN.C.text : PN.C.rule, lineWidth: hot ? 1.5 : 1))
        .dropDestination(for: String.self) { items, _ in
            defer { target = nil; dragging = nil }
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            return move(id, toOurs: ours)
        } isTargeted: { on in
            if on { target = ours } else if target == ours { target = nil }
        }
    }

    private func chip(_ p: DraftPerson, ours: Bool) -> some View {
        let other = L(ours ? "sheet.ui.s1.theirs" : "sheet.ui.s1.ours")
        let shape = RoundedRectangle(cornerRadius: th.style == .classic ? 6 : 0)
        return HStack(spacing: 6) {
            Text(p.name).font(th.homeText(14, .semibold)).foregroundStyle(PN.C.text)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: 190, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if !p.company.isEmpty {
                Text("· " + p.company).font(th.homeText(13)).foregroundStyle(PN.C.text2).lineLimit(1).fixedSize()
            }
            if p.you {
                Text(L("sheet.people.always")).font(th.homeText(11)).foregroundStyle(PN.C.text3).lineLimit(1).fixedSize().padding(.trailing, 2)
            } else {
                Button { _ = move(p.id, toOurs: !ours) } label: {
                    Image(systemName: ours ? "arrow.right" : "arrow.left").font(PN.sys(11, .semibold)).frame(width: 20, height: 20)
                }
                .buttonStyle(.plain).foregroundStyle(PN.C.text2)
                .help(L("sheet.people.move", ["name": p.name, "side": other]))
                .accessibilityLabel(L("sheet.people.move", ["name": p.name, "side": other]))
                Button {
                    if ours { draft.ours.removeAll { $0.id == p.id } } else { draft.theirs.removeAll { $0.id == p.id } }
                } label: {
                    Image(systemName: "xmark").font(PN.sys(10, .semibold)).frame(width: 18, height: 20)
                }
                .buttonStyle(.plain).foregroundStyle(PN.C.text3)
                .help(L("call.remove")).accessibilityLabel(L("call.remove") + ": " + p.name)
            }
        }
        .padding(.leading, 10).padding(.trailing, 6).frame(minHeight: 30)
        .background(PN.C.surface, in: shape)
        .overlay(shape.strokeBorder(PN.C.field, lineWidth: 1.5))
        .help(p.company.isEmpty ? p.name : p.name + ", " + p.company)
        .modifier(ChipDrag(enabled: !p.you, id: p.id, dragging: $dragging))
    }

    @discardableResult
    private func move(_ id: UUID, toOurs: Bool) -> Bool {
        var o = draft.ours, t = draft.theirs
        let moved = toOurs ? PeopleSides.move({ $0.id == id }, from: &t, to: &o, locked: { $0.you })
                           : PeopleSides.move({ $0.id == id }, from: &o, to: &t, locked: { $0.you })
        if moved { draft.ours = o; draft.theirs = t }
        return moved
    }

    private func add(ours: Bool) {
        let raw = ours ? newOurs : newTheirs
        // 0.10.0 (Meeting Sheet, hardening): "·" alone used to crash (parts[0] of an empty list)
        guard let p = SheetPipeline.person(raw) else { return }
        let d = DraftPerson(name: p.name, company: p.company)
        if ours { draft.ours.append(d); newOurs = "" } else { draft.theirs.append(d); newTheirs = "" }
    }
}

/// Only people other than you can be dragged.
private struct ChipDrag: ViewModifier {
    let enabled: Bool
    let id: UUID
    @Binding var dragging: UUID?
    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { dragging = id; return NSItemProvider(object: id.uuidString as NSString) }
        } else {
            content
        }
    }
}
