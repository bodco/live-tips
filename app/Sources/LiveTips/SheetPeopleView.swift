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

/// Who is on the call: their side and our side, next to each other. A person moves between the sides by drag and
/// drop or by the arrow on the chip (keyboard, VoiceOver, automation). You stay on our side.
struct SheetPeopleView: View {
    @ObservedObject var draft: SheetDraft
    @State private var newOurs = ""
    @State private var newTheirs = ""
    @State private var target: Bool?          // true = our side is under the drag, false = their side
    @State private var dragging: UUID?

    private var m: StartCallModel { draft.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L("sheet.people.title").uppercased()).font(PN.Font.label).kerning(0.4).foregroundStyle(PN.C.text3)
                Text(L("sheet.people.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 12) {
                zone(ours: false)
                zone(ours: true)
            }
            Text(sourceLine).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
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
        let org = ours ? m.targetName : (draft.theirs.first { !$0.company.isEmpty }?.company ?? m.project?.crmCompanyName ?? "")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L(ours ? "sheet.ui.s1.ours" : "sheet.ui.s1.theirs")).font(PN.Font.section).foregroundStyle(PN.C.text)
                if !org.isEmpty { PagePill(text: org, color: ours ? PN.C.answer : PN.C.docs) }
                Spacer(minLength: 0)
                Text(L(list.count == 1 ? "sheet.people.one" : "sheet.people.n", ["n": "\(list.count)"]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3).monospacedDigit()
            }
            FlowLayout {
                ForEach(list) { p in chip(p, ours: ours) }
            }
            if hot {
                Text(L(ours ? "sheet.people.dropOurs" : "sheet.people.dropTheirs"))
                    .font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(PN.C.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                TextField(L("sheet.ui.s1.personPh"), text: ours ? $newOurs : $newTheirs)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L(ours ? "sheet.people.addOurs" : "sheet.people.addTheirs"))
                    .onSubmit { add(ours: ours) }
                Button(L("sheet.ui.add")) { add(ours: ours) }.buttonStyle(.pnTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: PN.Radius.m).fill(hot ? PN.C.accent.opacity(0.10) : PN.C.bg))
        .overlay(RoundedRectangle(cornerRadius: PN.Radius.m).strokeBorder(hot ? PN.C.accent : Color.primary.opacity(0.12), lineWidth: hot ? 2 : 1))
        .dropDestination(for: String.self) { items, _ in
            defer { target = nil; dragging = nil }
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            return move(id, toOurs: ours)
        } isTargeted: { on in
            if on { target = ours } else if target == ours { target = nil }
        }
    }

    private func chip(_ p: DraftPerson, ours: Bool) -> some View {
        let tint = ours ? PN.C.answer : PN.C.docs
        let other = L(ours ? "sheet.ui.s1.theirs" : "sheet.ui.s1.ours")
        return HStack(spacing: 6) {
            Text(p.you ? String(p.name.prefix(1)).uppercased() : PeopleSides.initials(p.name))
                .font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                .frame(width: 22, height: 22).background(Circle().fill(tint.opacity(0.14)))
                .accessibilityHidden(true)
            Text(p.name).font(.system(size: 13, weight: .medium)).foregroundStyle(PN.C.text)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: 190, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if !p.company.isEmpty {
                Text(p.company).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1).fixedSize()
            }
            if p.you {
                Text(L("sheet.people.always")).font(.system(size: 11)).foregroundStyle(PN.C.text3).lineLimit(1).fixedSize().padding(.trailing, 4)
            } else {
                Button { _ = move(p.id, toOurs: !ours) } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20)
                }
                .buttonStyle(.plain).foregroundStyle(PN.C.text2)
                .help(L("sheet.people.move", ["name": p.name, "side": other]))
                .accessibilityLabel(L("sheet.people.move", ["name": p.name, "side": other]))
                Button {
                    if ours { draft.ours.removeAll { $0.id == p.id } } else { draft.theirs.removeAll { $0.id == p.id } }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20)
                }
                .buttonStyle(.plain).foregroundStyle(PN.C.text3)
                .help(L("call.remove")).accessibilityLabel(L("call.remove"))
            }
        }
        .padding(.leading, 3).padding(.trailing, 4).padding(.vertical, 3)
        .background(Capsule().fill(PN.C.surface))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
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
