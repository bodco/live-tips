import Foundation

/// S1-3 (skill/references/speech-writer.md): the PM's speech document for a deck, written by the live-tips skill
/// before the call. Prepare takes it when its name matches the deck: <project>/pacenote/speech/<deck stem>.speech.md.
public enum SpeechDocs {
    public static func path(root: String, deckFile: String) -> String {
        let stem = ((deckFile as NSString).lastPathComponent as NSString).deletingPathExtension
        return (((root as NSString).appendingPathComponent("pacenote") as NSString).appendingPathComponent("speech") as NSString)
            .appendingPathComponent(stem + ".speech.md")
    }

    /// The path when the file is there, else nil (no root or no deck: nil too).
    public static func existing(root: String, deckFile: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard !root.isEmpty, !deckFile.isEmpty else { return nil }
        let p = path(root: root, deckFile: deckFile)
        return exists(p) ? p : nil
    }

    /// The line for the preparation prompt (empty without a speech document).
    public static func promptLine(_ p: String?) -> String {
        guard let p else { return "" }
        return "\nThe PM's speech document for this deck: \(p) (written with references/speech-writer.md). Read it before " +
            "writing the talk: it has the PM's words for each slide; keep them as talk.md 6 says (tighten, do not rewrite)."
    }
}
