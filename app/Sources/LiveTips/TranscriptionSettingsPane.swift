import SwiftUI
import LiveTipsCore

/// 0.10.0 (owner 12.11): Settings > Transcription. The PM's own dictionary: the correct spelling of a word (a company,
/// a product, a name) and, optionally, what Whisper hears instead ("Lumenfield" heard as "Lumen field"). The correct
/// words go to Whisper's prompt before the brief's terms; the "heard as" variants are replaced in the transcript (whole
/// words, any case) before a line is shown, saved or sent to the tips model, in live calls and in recordings
/// transcribed after the call. Saved in the app's config.json and copied to the recorder's config.json.
struct TranscriptionSettingsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                if model.config.dictionary.isEmpty {
                    Text(L("dict.empty")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else {
                    HStack(spacing: 8) {
                        Text(L("dict.col.word")).frame(width: 170, alignment: .leading)
                        Text(L("dict.col.heard")).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 28, height: 1)
                    }
                    .font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.text3)
                    ForEach($model.config.dictionary) { $e in
                        DictionaryRow(entry: $e) { model.config.dictionary.removeAll { $0.id == e.id } }
                    }
                }
                HStack {
                    Button {
                        model.config.dictionary.append(DictionaryEntry())
                    } label: { Label(L("dict.add"), systemImage: "plus") }
                    Spacer()
                }
            } header: { Text(L("dict.head")) } footer: {
                Text(L("dict.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: model.config.dictionary) { LocalAIService.shared.writeCoreConfig() }
        }
        .formStyle(.grouped)
    }
}

/// One dictionary row: the correct word, the comma-separated "heard as" variants, remove.
private struct DictionaryRow: View {
    @Binding var entry: DictionaryEntry
    let remove: () -> Void
    @State private var heard = ""
    @State private var loaded = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $entry.word, prompt: Text(L("dict.word.placeholder")))
                .frame(width: 170)
                .accessibilityLabel(L("dict.col.word"))
            TextField("", text: $heard, prompt: Text(L("dict.heard.placeholder")))
                .onChange(of: heard) { entry.heard = DictionaryEntry.split(heard) }
                .accessibilityLabel(L("dict.col.heard"))
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(PN.C.text3)
            .help(L("dict.remove")).accessibilityLabel(L("dict.remove"))
        }
        .onAppear { if !loaded { heard = entry.heardText; loaded = true } }
    }
}
