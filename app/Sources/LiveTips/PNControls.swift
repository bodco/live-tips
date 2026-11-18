// Pacenote: own controls for Roadbook and Broadsheet (redesign 0.23.0, review 18.11).
// The native segmented picker, switch, checkbox and the sidebar selection stay system blue in every style, and
// .tint(accent) does not fit (Roadbook Dark would get a yellow segment with white text). These draw the controls from
// the style's tokens instead (boards SG-General r11, Settings-Appearance r3, SU/QP r9: _set.js seg, tg, navG, segs).
// Classic keeps the native controls exactly as before.

import SwiftUI

private var pnClassic: Bool { PNThemeModel.shared.style == .classic }

/// Colours of a selected row or segment: Roadbook = highlight plate (hlBg/hlFg), Broadsheet = ink plate with the ground as text.
enum PNSelect {
    static var fill: Color {
        switch PNThemeModel.shared.style {
        case .classic: return PN.C.accent.opacity(0.14)
        case .roadbook: return PN.C.highlight
        case .broadsheet: return PN.C.text
        }
    }
    static var ink: Color {
        switch PNThemeModel.shared.style {
        case .classic: return PN.C.text
        case .roadbook: return PN.C.onHighlight
        case .broadsheet: return PN.C.bg
        }
    }
    /// The icon colour of a selected sidebar row.
    static var icon: Color { pnClassic ? PN.C.accent : ink }
}

// MARK: - Segmented

/// A segmented choice. Classic: the native segmented Picker. Roadbook and Broadsheet: square segments with a 1.5 px
/// frame, the picked one on the selection plate, labels in the display face (capitals in Roadbook).
/// Modifiers the call site used on the Picker (labelsHidden, fixedSize, frame, disabled) keep working.
struct PNSegmented<T: Hashable>: View {
    let label: String
    @Binding var selection: T
    let options: [(T, String)]
    @Environment(\.pnTheme) private var t
    @Environment(\.isEnabled) private var enabled

    init(_ label: String = "", selection: Binding<T>, options: [(T, String)]) {
        self.label = label; self._selection = selection; self.options = options
    }

    var body: some View {
        if t.style == .classic {
            Picker(label, selection: $selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].1).tag(options[i].0) }
            }
            .pickerStyle(.segmented)
        } else if label.isEmpty {
            segments
        } else {
            LabeledContent(label) { segments }
        }
    }

    private var segments: some View {
        let line = PN.C.ruleStrong
        return HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].0 == selection
                Button { selection = options[i].0 } label: {
                    Text(t.cased(options[i].1))
                        .font(t.font(.display, t.bSize - 2, .heavy))
                        .tracking((t.bSize - 2) * t.bTrack)
                        .lineLimit(1)
                        .foregroundStyle(on ? PNSelect.ink : PN.C.text)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                        .background(on ? PNSelect.fill : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .leading) { if i > 0 { Rectangle().fill(line).frame(width: 1.5) } }
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .overlay(Rectangle().strokeBorder(line, lineWidth: 1.5))
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - Tabs (Settings groups: Basics / During calls / Data)

/// Pane tabs. Classic: the native segmented Picker. Roadbook and Broadsheet: text tabs with a 3 px line under the picked one.
struct PNTabs: View {
    @Binding var selection: String
    let options: [(String, String)]
    @Environment(\.pnTheme) private var t

    var body: some View {
        if t.style == .classic {
            PNSegmented(selection: $selection, options: options)
        } else {
            HStack(spacing: 22) {
                ForEach(options, id: \.0) { o in
                    let on = o.0 == selection
                    Button { selection = o.0 } label: {
                        Text(t.cased(o.1))
                            .font(t.font(.display, t.tabSize, on ? .heavy : .semibold))
                            .tracking(t.tabSize * t.bTrack)
                            .foregroundStyle(on ? PN.C.text : PN.C.text2)
                            .padding(.top, 6).padding(.bottom, 5)
                            .overlay(alignment: .bottom) { Rectangle().fill(on ? PN.C.accent : .clear).frame(height: 3) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
        }
    }
}

// MARK: - Switch and checkbox

/// A switch. Classic: the native switch. Roadbook: square, Broadsheet: round; on = accent fill with an onAccent knob.
struct PNSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { PNSwitchBody(configuration: configuration) }
}

private struct PNSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.pnTheme) private var t
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        if t.style == .classic {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        } else {
            let on = configuration.isOn
            let round = t.style == .broadsheet
            LabeledContent {
                Button { configuration.isOn.toggle() } label: {
                    ZStack(alignment: on ? .trailing : .leading) {
                        RoundedRectangle(cornerRadius: round ? 10 : 0)
                            .fill(on ? PN.C.accentFill : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: round ? 10 : 0).strokeBorder(on ? PN.C.accentFill : PN.C.field, lineWidth: 1.5))
                        RoundedRectangle(cornerRadius: round ? 6.5 : 0)
                            .fill(on ? PN.C.onAccent : PN.C.text3)
                            .frame(width: 13, height: 13).padding(.horizontal, 3.5)
                    }
                    .frame(width: 38, height: 20)
                    .contentShape(Rectangle())
                    .animation(.easeOut(duration: 0.12), value: on)
                }
                .buttonStyle(.plain)
                .opacity(enabled ? 1 : 0.45)
                .accessibilityLabel(Text("")).accessibilityHidden(true)
            } label: { configuration.label }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(on ? "1" : "0")
            .accessibilityAction { configuration.isOn.toggle() }
        }
    }
}

/// A checkbox. Classic: the native checkbox. Roadbook: square, Broadsheet: 3 pt corners; on = accent fill, onAccent tick.
struct PNCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { PNCheckboxBody(configuration: configuration) }
}

private struct PNCheckboxBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.pnTheme) private var t
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        if t.style == .classic {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        } else {
            let on = configuration.isOn
            let r: CGFloat = t.style == .broadsheet ? 3 : 0
            Button { configuration.isOn.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: r).fill(on ? PN.C.accentFill : Color.clear)
                        RoundedRectangle(cornerRadius: r).strokeBorder(on ? PN.C.accentFill : PN.C.field, lineWidth: 1.5)
                        if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(PN.C.onAccent) }
                    }
                    .frame(width: 14, height: 14)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(on ? "1" : "0")
        }
    }
}

extension ToggleStyle where Self == PNSwitchStyle { static var pnSwitch: PNSwitchStyle { .init() } }
extension ToggleStyle where Self == PNCheckboxStyle { static var pnCheckbox: PNCheckboxStyle { .init() } }
