import LiveTipsCore
import SwiftUI

/// Languages the speech model (Whisper) knows, for the call's language choice (2026-10-27, owner:
/// English and Ukrainian on top, then every language with a search, several at once).
enum Languages {
    static let top = ["en", "uk"]
    static let all: [(code: String, name: String)] = [
        ("af", "Afrikaans"), ("sq", "Albanian"), ("am", "Amharic"), ("ar", "Arabic"), ("hy", "Armenian"), ("as", "Assamese"),
        ("az", "Azerbaijani"), ("ba", "Bashkir"), ("eu", "Basque"), ("be", "Belarusian"), ("bn", "Bengali"), ("bs", "Bosnian"),
        ("br", "Breton"), ("bg", "Bulgarian"), ("my", "Burmese"), ("yue", "Cantonese"), ("ca", "Catalan"), ("zh", "Chinese"),
        ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"), ("en", "English"), ("et", "Estonian"),
        ("fo", "Faroese"), ("fi", "Finnish"), ("fr", "French"), ("gl", "Galician"), ("ka", "Georgian"), ("de", "German"),
        ("el", "Greek"), ("gu", "Gujarati"), ("ht", "Haitian Creole"), ("ha", "Hausa"), ("haw", "Hawaiian"), ("he", "Hebrew"),
        ("hi", "Hindi"), ("hu", "Hungarian"), ("is", "Icelandic"), ("id", "Indonesian"), ("it", "Italian"), ("ja", "Japanese"),
        ("jw", "Javanese"), ("kn", "Kannada"), ("kk", "Kazakh"), ("km", "Khmer"), ("ko", "Korean"), ("lo", "Lao"),
        ("la", "Latin"), ("lv", "Latvian"), ("ln", "Lingala"), ("lt", "Lithuanian"), ("lb", "Luxembourgish"), ("mk", "Macedonian"),
        ("mg", "Malagasy"), ("ms", "Malay"), ("ml", "Malayalam"), ("mt", "Maltese"), ("mi", "Maori"), ("mr", "Marathi"),
        ("mn", "Mongolian"), ("ne", "Nepali"), ("no", "Norwegian"), ("nn", "Norwegian Nynorsk"), ("oc", "Occitan"), ("ps", "Pashto"),
        ("fa", "Persian"), ("pl", "Polish"), ("pt", "Portuguese"), ("pa", "Punjabi"), ("ro", "Romanian"), ("ru", "Russian"),
        ("sa", "Sanskrit"), ("sr", "Serbian"), ("sn", "Shona"), ("sd", "Sindhi"), ("si", "Sinhala"), ("sk", "Slovak"),
        ("sl", "Slovenian"), ("so", "Somali"), ("es", "Spanish"), ("su", "Sundanese"), ("sw", "Swahili"), ("sv", "Swedish"),
        ("tl", "Tagalog"), ("tg", "Tajik"), ("ta", "Tamil"), ("tt", "Tatar"), ("te", "Telugu"), ("th", "Thai"),
        ("bo", "Tibetan"), ("tr", "Turkish"), ("tk", "Turkmen"), ("uk", "Ukrainian"), ("ur", "Urdu"), ("uz", "Uzbek"),
        ("vi", "Vietnamese"), ("cy", "Welsh"), ("yi", "Yiddish"), ("yo", "Yoruba"),
    ]
    static func englishName(_ code: String) -> String { all.first { $0.code == code }?.name ?? code }
    /// The language name in the interface language (macOS knows them all), English as the fallback.
    static func name(_ code: String) -> String {
        guard L10n.lang != "en", let n = Locale(identifier: L10n.lang).localizedString(forLanguageCode: code), !n.isEmpty else { return englishName(code) }
        return n.prefix(1).uppercased() + n.dropFirst()
    }
    static func label(_ codes: [String]) -> String {
        guard !codes.isEmpty else { return L("lang.choose") }
        if codes.count > 2 { return L("lang.more", ["name": name(codes[0]), "n": "\(codes.count - 1)"]) }
        return codes.map(name).joined(separator: " + ")
    }
}

/// Search and tick one or more languages; the first ticked is the main one. One language = the
/// transcript is written in it (other languages come out translated); several = each as spoken.
struct LanguagePicker: View {
    @Binding var codes: [String]
    @State private var q = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $q, prompt: Text(L("lang.findALanguage"))).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if q.isEmpty {
                        ForEach(Languages.top, id: \.self) { c in row(c, Languages.name(c)) }
                        Divider().padding(.vertical, 4)
                    }
                    ForEach(Languages.all.filter { q.isEmpty ? !Languages.top.contains($0.code) : ($0.name.lowercased().contains(q.lowercased()) || Languages.name($0.code).lowercased().contains(q.lowercased())) }, id: \.code) { l in
                        row(l.code, Languages.name(l.code))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(codes.count == 1 ? L("lang.one", ["name": Languages.name(codes[0])])
                                  : L("lang.several"))
                .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(width: 300, height: 380)
    }

    func row(_ code: String, _ name: String) -> some View {
        let on = codes.contains(code)
        return Button {
            if on { if codes.count > 1 { codes.removeAll { $0 == code } } } else { codes.append(code) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : .secondary)
                Text(name)
                Spacer()
                if on && codes.first == code && codes.count > 1 { Text(L("lang.main")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            }
            .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A choice in Start call: icon, current value, chevron; all the same width and colour (owner 2026-10-27).
struct ChoicePill<Content: View>: View {
    let symbol: String
    let label: String
    let help: String
    @ViewBuilder var content: (_ close: @escaping () -> Void) -> Content
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 18)
                Text(label).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(PN.Font.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: LT.radius).fill(Color.accentColor.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $open, arrowEdge: .bottom) { content({ open = false }) }
    }
}

/// A short list of options inside a ChoicePill popover.
struct OptionList: View {
    let options: [(tag: String, label: String, hint: String)]
    @Binding var selection: String
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(options, id: \.tag) { o in
                Button { selection = o.tag; close() } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark").opacity(selection == o.tag ? 1 : 0).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.label)
                            if !o.hint.isEmpty { Text(o.hint).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 6).padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10).frame(width: 300)
    }
}

// MARK: - 0.8.7 (G4, J2): short language choices

extension Languages {
    private static let recentKey = "recentCallLangs"

    /// The languages to offer first: English and Ukrainian, the languages of the PM's projects, the last 3 used.
    @MainActor
    static func suggested(including current: [String] = []) -> [String] {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let fromProjects = reg.projects.filter { $0.status != "archived" }.flatMap { $0.defaultLanguage.split(separator: "+").map(String.init) }
        let recent = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        var seen = Set<String>(), out: [String] = []
        for c in top + fromProjects + recent + current where all.contains(where: { $0.code == c }) && seen.insert(c).inserted { out.append(c) }
        return out
    }

    /// Keeps the last 3 languages chosen (newest first).
    static func remember(_ codes: [String]) {
        var r = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        for c in codes.reversed() { r.removeAll { $0 == c }; r.insert(c, at: 0) }
        UserDefaults.standard.set(Array(r.prefix(3)), forKey: recentKey)
    }

    static func toggle(_ code: String, in codes: [String]) -> [String] {
        if codes.contains(code) { return codes.count > 1 ? codes.filter { $0 != code } : codes }
        return codes + [code]
    }
}

/// 0.8.7 (J2): the language as a row of chips (the suggested languages) plus "More…", a popover with search.
struct LanguageChips: View {
    @Binding var codes: [String]
    @State private var more = false

    var body: some View {
        let list = Languages.suggested(including: codes)
        HStack(spacing: 6) {
            ForEach(list, id: \.self) { c in
                let on = codes.contains(c)
                Button { codes = Languages.toggle(c, in: codes); Languages.remember(codes) } label: {
                    HStack(spacing: 4) {
                        if on { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                        Text(Languages.name(c))
                    }
                    .font(PN.Font.caption.weight(on ? .semibold : .regular))
                    .foregroundStyle(on ? PN.C.accent : PN.C.text2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(on ? PN.C.accent.opacity(0.14) : PN.C.surface2))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Button(L("lang.moreButton")) { more = true }.buttonStyle(.pnTertiary)
                .popover(isPresented: $more, arrowEdge: .bottom) {
                    LanguagePicker(codes: Binding(get: { codes }, set: { codes = $0; Languages.remember($0) }))
                }
        }
    }
}

/// 0.8.7 (G4): the language as a pop-up: the suggested languages with ticks, then "More…" with search.
struct LanguageMenu: View {
    @Binding var codes: [String]
    @State private var more = false

    var body: some View {
        Menu {
            ForEach(Languages.suggested(including: codes), id: \.self) { c in
                Toggle(Languages.name(c), isOn: Binding(get: { codes.contains(c) }, set: { _ in
                    codes = Languages.toggle(c, in: codes); Languages.remember(codes) }))
            }
            Divider()
            Button(L("lang.moreButton")) { more = true }
        } label: { Text(Languages.label(codes)) }
        .menuStyle(.borderlessButton).fixedSize()
        .popover(isPresented: $more, arrowEdge: .bottom) {
            LanguagePicker(codes: Binding(get: { codes }, set: { codes = $0; Languages.remember($0) }))
        }
    }
}
