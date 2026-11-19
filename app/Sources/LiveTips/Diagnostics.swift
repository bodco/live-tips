import AppKit
import LiveTipsCore

/// 0.24.1 (F7): Help > Export diagnostics. One zip with logs/, state/, the versions and the list of components, in a
/// folder the PM picks (Desktop by default), without Terminal. Keys and tokens never are in these folders (Keychain);
/// every text file still goes through LogFile.redact (the home folder as "~", anything that looks like a key cut).
@MainActor
enum Diagnostics {
    nonisolated static let textExt: Set<String> = ["log", "json", "jsonl", "txt", "md", "yaml", "yml", "csv"]
    nonisolated static let maxFile = 20_000_000

    static func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.prompt = L("diag.save"); panel.message = L("diag.message")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        AppLog.app("diagnostics: export")
        let setup = SetupWindow.model
        Task {
            await setup.checkAll()
            let info = summary(setup)
            let out = await Task.detached(priority: .utility) { build(into: dir, info: info) }.value
            // 0.26.0 (block 3): a notice with Show in Finder, not an alert.
            if let z = out {
                NoticeCenter.shared.post(L("diag.done") + ": " + (z.path as NSString).abbreviatingWithTildeInPath,
                                         level: .info, action: .finder(z.path))
            } else {
                NoticeCenter.shared.post(L("diag.failed"), level: .error)
            }
        }
    }

    static func summary(_ setup: SetupModel) -> String {
        var lines = [LogFile.header("diagnostics", app: AppLog.appVersion, build: AppLog.build, os: AppLog.macOS, extra: AppLog.runtimeExtra)]
        lines.append("components:")
        for s in setup.steps + setup.tools { lines.append("  \(s.id): \(s.state) \(s.detail)") }
        lines.append("base missing (files): " + CallEngine.shared.baseMissing.joined(separator: ","))
        let c = AppConfig.load(from: AppPaths.config)
        lines.append("ai: prep=\(c.ai.prep) tips=\(c.ai.tips) after=\(c.ai.after) connected=\(AIRoute.connected().sorted().joined(separator: ","))")
        lines.append("onboarding: done=\(UserDefaults.standard.bool(forKey: "onboardingDone")) step=\(UserDefaults.standard.integer(forKey: OnboardingModel.stepKey))")
        return lines.map { LogFile.redact($0) }.joined(separator: "\n") + "\n"
    }

    nonisolated static func build(into dir: URL, info: String) -> URL? {
        let fm = FileManager.default
        let root = AppLog.root
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "Pacenote-diagnostics-" + f.string(from: Date())
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try? fm.removeItem(at: tmp)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? info.write(to: tmp.appendingPathComponent("versions.txt"), atomically: true, encoding: .utf8)
        for sub in ["logs", "state"] {
            let src = URL(fileURLWithPath: root).appendingPathComponent(sub)
            guard let e = fm.enumerator(at: src, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard v?.isRegularFile == true, (v?.fileSize ?? 0) <= maxFile else { continue }
                let ext = u.pathExtension.lowercased(), base = u.lastPathComponent
                // rotated logs (app.log.1) are text too
                let isText = textExt.contains(ext) || base.range(of: #"\.log\.\d+$"#, options: .regularExpression) != nil
                guard isText, let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
                let rel = u.path.replacingOccurrences(of: src.path + "/", with: "")
                let dst = tmp.appendingPathComponent(sub).appendingPathComponent(rel)
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? LogFile.redact(t).write(to: dst, atomically: true, encoding: .utf8)
            }
        }
        let zip = dir.appendingPathComponent(name + ".zip")
        try? fm.removeItem(at: zip)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", tmp.path, zip.path]
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        try? fm.removeItem(at: tmp)
        return p.terminationStatus == 0 && fm.fileExists(atPath: zip.path) ? zip : nil
    }
}
