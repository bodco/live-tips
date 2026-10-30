import AppKit
import AVFoundation
import LiveTipsCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Pacenote 0.8.6 (B, rules/transcribe.yaml): Transcribe a recording. One window, three states: the input (a file or a
/// link), the progress, the result (transcript with a player, Speakers, Save). The work goes on when the window is
/// closed; a notification says when it is done. Never during a live call: it waits until the call ends.
@MainActor
final class TranscribeModel: ObservableObject {
    static let shared = TranscribeModel()
    enum Phase: Equatable { case input, waiting, running, result, failed(String) }
    struct Line: Identifiable, Equatable { let id: Int; let t: String; let sid: String; let lang: String; let text: String }
    struct Speaker: Identifiable { let id: String; var name: String?; var seconds: Double; var how: String?; var score: Double?
        var firstQuote: String; var suggestions: [(name: String, score: Double)]; var sample: (Double, Double)?; var side: String?; var remember: Bool }

    static let fileTypes = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "mp4", "mov", "m4v", "webm", "mkv"]

    @Published var phase: Phase = .input
    @Published var file: URL?
    @Published var link = ""
    @Published var langs: [String] = []
    @Published var people = 0                  // 0 = find out by itself
    @Published var target = ""                 // "" none, "project:<slug>", "workspace:<name>"
    @Published var stage = 0                   // 0 getting the file, 1 preparing, 2 transcribing, 3 voices
    @Published var doneS = 0.0
    @Published var totalS = 0.0
    @Published var soFar: [String] = []
    @Published var lines: [Line] = []
    @Published var speakers: [Speaker] = []
    @Published var overrides: [String: String] = [:]
    @Published var merged: [String: String] = [:]
    @Published var title = ""
    @Published var date: Date?
    @Published var saveTarget = ""
    @Published var note = ""
    @Published var notionURL = ""
    @Published var busy = false
    var md: URL?                               // the transcript in the work folder (cache or the project's live/)
    var audio: URL?                            // the player's .m4a
    var started = Date()
    var sourceKind = "file"
    var sourceRef = ""
    private var proc: Process?
    private var work: Task<Void, Never>?
    private var waitTimer: Timer?
    let player = AVPlayer()

    var cfg: AppConfig { AppConfig.load(from: AppPaths.config) }
    var appRoot: String { CallEngine.shared.appRoot }
    var python: String { cfg.engine.python }

    /// rules/transcribe.yaml > link_sources: the chip under the Link field.
    static func source(_ s: String) -> String {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(u.scheme ?? ""), let h = u.host?.lowercased() else { return "" }
        if h.hasSuffix("drive.google.com") || h.hasSuffix("docs.google.com") { return "drive" }
        if h.hasSuffix("youtube.com") || h.hasSuffix("youtu.be") { return "youtube" }
        if h.hasSuffix("vimeo.com") { return "vimeo" }
        if h.hasSuffix("dropbox.com") { return "dropbox" }
        return "direct"
    }

    func reset() {
        stop()
        phase = .input; file = nil; link = ""; soFar = []; lines = []; speakers = []; note = ""; notionURL = ""
        overrides = [:]; merged = [:]; md = nil; audio = nil; title = ""; date = nil
        if langs.isEmpty { langs = [cfg.uiLanguage == "en" ? "en" : "uk"] }
    }

    var duringCall: Bool {
        let st = EngineStatus.load(path: CallEngine.shared.statusPath)
        return CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(st.state)
    }

    func start() {
        guard file != nil || !Self.source(link).isEmpty else { return }
        saveTarget = target
        if duringCall {
            phase = .waiting
            waitTimer?.invalidate()
            waitTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self = self, !self.duringCall else { return }
                    t.invalidate(); self.run()
                }
            }
            return
        }
        run()
    }

    func stop() {
        waitTimer?.invalidate(); waitTimer = nil
        work?.cancel(); work = nil
        proc?.terminate(); proc = nil
        if phase == .running || phase == .waiting { phase = .input }
    }

    private var workDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pacenote/transcribe")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func run() {
        phase = .running; stage = 0; doneS = 0; totalS = 0; soFar = []; started = Date(); note = ""
        work = Task {
            let job = workDir.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            do {
                var src = file
                sourceKind = file == nil ? "link" : "file"
                sourceRef = file?.lastPathComponent ?? link
                if src == nil {                                       // 1. getting the file (rules/transcribe.yaml > link)
                    var res: [String: Any] = [:]
                    let rc = await runLines(python, [(appRoot as NSString).appendingPathComponent("src/fetchlink.py"), link, job.path]) { l in
                        guard let o = Self.json(l) else { return }
                        if let p = o["pct"] as? Double { self.doneS = p; self.totalS = 100 }
                        if o["ok"] != nil { res = o }
                    }
                    if (res["error"] as? String) == "needs_component" { throw Self.err(L("tr.needsLinkDl")) }
                    guard rc == 0, let f = res["file"] as? String else { throw Self.err((res["error"] as? String) ?? L("tr.downloadFailed")) }
                    src = URL(fileURLWithPath: f)
                    if title.isEmpty, let t = res["title"] as? String { title = t }
                    if date == nil, let d = res["date"] as? String, !d.isEmpty { date = Self.ymd.date(from: d) }
                }
                guard let input = src else { return }
                if title.isEmpty { title = input.deletingPathExtension().lastPathComponent }
                if date == nil, sourceKind == "file" { date = (try? input.resourceValues(forKeys: [.creationDateKey]))?.creationDate }
                stage = 1                                              // 2. preparing the audio (AVFoundation, no ffmpeg)
                let wav = job.appendingPathComponent("audio.wav")
                totalS = try await Self.decode(input, to: wav)
                let m4a = job.appendingPathComponent("audio.m4a")
                try? await Self.exportM4A(wav, to: m4a)
                audio = FileManager.default.fileExists(atPath: m4a.path) ? m4a : wav
                stage = 2                                              // 3. transcribing, 4. telling the voices apart
                let out = job.appendingPathComponent(StartCallModel.slugify(title) + ".md")
                var args = [(appRoot as NSString).appendingPathComponent("src/transcriber.py"), "--from-file", wav.path, "--out", out.path,
                            "--langs", langs.joined(separator: "+"), "--title", title, "--source", sourceKind, "--source-ref", sourceRef,
                            "--ui-lang", cfg.uiLanguage, "--when", Self.stamp.string(from: date ?? Date())]
                if people > 0 { args += ["--speakers", "\(people)"] }
                let reg = ProjectRegistry.load(from: AppPaths.projects)
                if target.hasPrefix("project:"), let p = reg.projects.first(where: { "project:" + $0.slug == target }) {
                    args += ["--slug", p.slug, "--people", p.people.map(\.name).joined(separator: ","), "--workspace", p.workspace]
                } else if target.hasPrefix("workspace:") {
                    args += ["--slug", String(target.dropFirst(10)).lowercased(), "--workspace", String(target.dropFirst(10))]
                }
                var final: [String: Any] = [:]
                let rc = await runLines(python, args) { l in
                    guard let o = Self.json(l) else { return }
                    switch o["stage"] as? String {
                    case "transcribe":
                        self.stage = 2
                        if let d = o["done_s"] as? Double { self.doneS = d }
                        if let t = o["total_s"] as? Double { self.totalS = t }
                        if let ln = o["line"] as? [String: Any], let tx = ln["text"] as? String {
                            self.soFar.append(((ln["t"] as? String) ?? "") + "  " + tx)
                            if self.soFar.count > 6 { self.soFar.removeFirst(self.soFar.count - 6) }
                        }
                    case "speakers": self.stage = 3
                    case "done": final = o
                    case "error": final = o
                    default: break
                    }
                }
                guard rc == 0, final["stage"] as? String == "done" else { throw Self.err((final["error"] as? String) ?? L("tr.failed")) }
                try? FileManager.default.removeItem(at: wav)           // rules/transcribe.yaml > files
                if sourceKind == "link" { try? FileManager.default.removeItem(at: input) }
                md = out
                load()
                phase = .result
                if !saveTarget.isEmpty { addToProject() }
                notifyDone()
            } catch is CancellationError {
                phase = .input
            } catch {
                phase = .failed(error.localizedDescription)
            }
            pruneCache()
        }
    }

    /// Cached results (no project) are kept 7 days.
    private func pruneCache() {
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let m = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, Date().timeIntervalSince(m) > 7 * 86400 {
                try? fm.removeItem(at: d)
            }
        }
    }

    private func notifyDone() {
        guard TranscribeWindow.window?.isVisible != true else { return }
        let c = UNMutableNotificationContent()
        c.title = L("tr.doneTitle"); c.body = title
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: TranscribeWindow.notificationId, content: c, trigger: nil))
    }

    nonisolated static func err(_ s: String) -> NSError { NSError(domain: "Transcribe", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
    static func json(_ l: String) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any] }
    static let ymd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    /// A process whose stdout lines arrive on the main actor; Stop terminates it.
    private func runLines(_ exe: String, _ args: [String], onLine: @escaping (String) -> Void) async -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: (appRoot as NSString).appendingPathComponent("src"))
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.forAppending(path: (appRoot as NSString).appendingPathComponent("logs/transcribe.log"))
        proc = p
        return await withCheckedContinuation { cont in
            var buf = Data()
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                buf.append(d)
                while let i = buf.firstIndex(of: 0x0A) {
                    let line = String(data: buf[..<i], encoding: .utf8) ?? ""
                    buf.removeSubrange(...i)
                    DispatchQueue.main.async { onLine(line) }
                }
            }
            p.terminationHandler = { pr in
                out.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async { cont.resume(returning: pr.terminationStatus) }
            }
            do { try p.run() } catch { out.fileHandleForReading.readabilityHandler = nil; cont.resume(returning: -1) }
        }
    }

    /// WAV 16 kHz mono 16-bit, streamed to disk (rules/transcribe.yaml > decode). Returns the duration in seconds.
    nonisolated static func decode(_ src: URL, to dst: URL) async throws -> Double {
        let asset = AVURLAsset(url: src)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !tracks.isEmpty else { throw err(L("tr.cannotRead")) }
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        if dur > 4 * 3600 { throw err(L("tr.tooLong")) }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                       AVLinearPCMIsNonInterleaved: false]
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        guard reader.canAdd(out) else { throw err(L("tr.cannotRead")) }
        reader.add(out)
        guard reader.startReading() else { throw err(L("tr.cannotRead")) }
        FileManager.default.createFile(atPath: dst.path, contents: Data(count: 44))
        let h = try FileHandle(forWritingTo: dst)
        h.seekToEndOfFile()
        var bytes = 0
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb)
            var chunk = Data(count: n)
            chunk.withUnsafeMutableBytes { p in _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: p.baseAddress!) }
            h.write(chunk)
            bytes += n
        }
        guard reader.status == .completed else { try? h.close(); throw err(L("tr.cannotRead")) }
        h.seek(toFileOffset: 0)
        h.write(wavHeader(dataBytes: bytes))
        try? h.close()
        return Double(bytes) / 32000
    }

    nonisolated static func wavHeader(dataBytes n: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(n))
        return d
    }

    nonisolated static func exportM4A(_ wav: URL, to dst: URL) async throws {
        guard let ex = AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A) else { return }
        ex.outputURL = dst; ex.outputFileType = .m4a
        await ex.export()
    }

    // MARK: the result

    static let tagged = try! NSRegularExpression(pattern: "^\\[(\\d\\d:\\d\\d:\\d\\d)\\] (.+?) \\[(S\\d+)\\] \\((\\w+)\\): (.*)$")

    func load() {
        guard let md = md, let text = try? String(contentsOf: md, encoding: .utf8) else { return }
        var out: [Line] = []
        for (i, raw) in text.split(separator: "\n").enumerated() {
            let s = String(raw)
            guard let m = Self.tagged.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            func g(_ k: Int) -> String { Range(m.range(at: k), in: s).map { String(s[$0]) } ?? "" }
            out.append(Line(id: i, t: g(1), sid: g(3), lang: g(4), text: g(5)))
        }
        lines = out
        loadSpeakers()
        if let a = audio { player.replaceCurrentItem(with: AVPlayerItem(url: a)) }
    }

    func loadSpeakers() {
        guard let md = md, let d = FileManager.default.contents(atPath: Self.sp(md).path),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        overrides = (o["overrides"] as? [String: String]) ?? [:]
        merged = (o["merged"] as? [String: String]) ?? [:]
        let rem = (o["remember"] as? [String: Bool]) ?? [:]
        let cl = (o["clusters"] as? [String: [String: Any]]) ?? [:]
        speakers = cl.keys.sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }.filter { merged[$0] == nil }.map { sid in
            let c = cl[sid] ?? [:]
            let smp = c["sample"] as? [String: Double]
            return Speaker(id: sid, name: c["name"] as? String, seconds: c["seconds"] as? Double ?? 0, how: c["how"] as? String,
                           score: c["score"] as? Double, firstQuote: ((c["first_quote"] as? [String: Any])?["text"] as? String) ?? ((c["last_quote"] as? [String: Any])?["text"] as? String) ?? "",
                           suggestions: ((c["suggestions"] as? [[String: Any]]) ?? []).compactMap { x in (x["name"] as? String).map { ($0, x["score"] as? Double ?? 0) } },
                           sample: smp.flatMap { s in s["start"].map { ($0, s["end"] ?? $0 + 5) } }, side: c["side"] as? String, remember: rem[sid] ?? true)
        }
    }

    static func sp(_ md: URL) -> URL { md.deletingPathExtension().appendingPathExtension("speakers.json") }

    func resolve(_ sid: String) -> String { var s = sid; var seen = Set<String>(); while let n = merged[s], !seen.contains(s) { seen.insert(s); s = n }; return s }
    func label(_ l: Line) -> String {
        let s = resolve(overrides[l.t] ?? l.sid)
        return speakers.first { $0.id == s }?.name ?? L("tr.speakerN", ["n": String(s.dropFirst())])
    }
    func color(_ sid: String) -> Color {
        let palette: [Color] = [PN.C.accent, Color(red: 0.55, green: 0.36, blue: 0.85), Color(red: 0.13, green: 0.6, blue: 0.45),
                                Color(red: 0.85, green: 0.45, blue: 0.1), Color(red: 0.8, green: 0.2, blue: 0.45), Color(red: 0.3, green: 0.55, blue: 0.75)]
        return palette[((Int(sid.dropFirst()) ?? 1) - 1) % palette.count]
    }

    /// Renames, merges, line fixes and Remember go through src/fromfile.py edit (the same names logic as a call).
    func edit(_ args: [String]) {
        guard let md = md else { return }
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let slug = saveTarget.hasPrefix("project:") ? String(saveTarget.dropFirst(8)) : ""
        let ws = reg.projects.first { $0.slug == slug }?.workspace ?? (saveTarget.hasPrefix("workspace:") ? String(saveTarget.dropFirst(10)) : "")
        busy = true
        Task {
            _ = await runLines(python, [(appRoot as NSString).appendingPathComponent("src/fromfile.py"), "edit", "--md", md.path,
                                        "--project", slug, "--workspace", ws] + args) { _ in }
            busy = false
            loadSpeakers()
        }
    }

    func play(_ t: String) {
        let p = t.split(separator: ":").compactMap { Double($0) }
        guard p.count == 3 else { return }
        player.seek(to: CMTime(seconds: p[0] * 3600 + p[1] * 60 + p[2], preferredTimescale: 600))
        player.play()
    }

    func sample(_ s: Speaker) {
        guard let (a, b) = s.sample else { return }
        player.seek(to: CMTime(seconds: a, preferredTimescale: 600))
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, b - a)) { [weak self] in self?.player.pause() }
    }

    // MARK: save (rules/transcribe.yaml > save)

    /// With a project: the transcript joins that project's live/ folder, named like a call, and call notes run.
    func addToProject() {
        guard let md = md else { return }
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        var root = ""
        if saveTarget.hasPrefix("project:") { root = reg.projects.first { "project:" + $0.slug == saveTarget }?.root ?? "" }
        if saveTarget.hasPrefix("workspace:") { root = reg.workspaces.first { "workspace:" + $0.name == saveTarget }?.root ?? "" }
        guard !root.isEmpty else { return }
        let live = URL(fileURLWithPath: root).appendingPathComponent("live")
        try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        let stem = f.string(from: date ?? Date()) + "-" + StartCallModel.slugify(title.isEmpty ? "recording" : title)
        let dst = live.appendingPathComponent(stem + ".md")
        if md.deletingLastPathComponent() == live { return }
        let fm = FileManager.default
        for (a, b) in [(md, dst), (Self.sp(md), live.appendingPathComponent(stem + ".speakers.json")),
                       (md.deletingPathExtension().appendingPathExtension("named.md"), live.appendingPathComponent(stem + ".named.md"))] {
            try? fm.removeItem(at: b); try? fm.copyItem(at: a, to: b)
        }
        if let a = audio, a.pathExtension == "m4a" {
            let b = live.appendingPathComponent(stem + ".m4a")
            try? fm.removeItem(at: b); try? fm.copyItem(at: a, to: b); audio = b
        }
        self.md = dst
        CallHistory.shared.scan()
        CallEngine.shared.writeCallNotes(file: dst.path, config: cfg, hasConfig: false)
        note = L("tr.addedToProject")
    }

    /// The transcript as people read it: names applied.
    func namedText() -> String {
        var out = "# " + (title.isEmpty ? "Transcript" : title) + "\n\n"
        if let d = date { out += Self.stamp.string(from: d) + "\n" }
        out += L("tr.people") + ": " + speakers.map { $0.name ?? L("tr.speakerN", ["n": String($0.id.dropFirst())]) }.joined(separator: ", ") + "\n\n"
        for l in lines { out += "[\(l.t)] \(label(l)): \(l.text)\n" }
        return out
    }

    func saveMarkdown() {
        let p = NSSavePanel(); p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        p.nameFieldStringValue = (title.isEmpty ? "transcript" : title) + ".md"
        guard p.runModal() == .OK, let u = p.url else { return }
        try? namedText().write(to: u, atomically: true, encoding: .utf8)
    }

    func saveWord() {
        let p = NSSavePanel(); p.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        p.nameFieldStringValue = (title.isEmpty ? "transcript" : title) + ".docx"
        guard p.runModal() == .OK, let u = p.url else { return }
        let doc = NSMutableAttributedString()
        doc.append(NSAttributedString(string: (title.isEmpty ? "Transcript" : title) + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
        let who = speakers.map { $0.name ?? L("tr.speakerN", ["n": String($0.id.dropFirst())]) }.joined(separator: ", ")
        doc.append(NSAttributedString(string: [date.map { Self.stamp.string(from: $0) } ?? "", who].filter { !$0.isEmpty }.joined(separator: " · ") + "\n\n",
                                      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        for l in lines {
            doc.append(NSAttributedString(string: l.t + " ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]))
            doc.append(NSAttributedString(string: label(l) + ": ", attributes: [.font: NSFont.boldSystemFont(ofSize: 11)]))
            doc.append(NSAttributedString(string: l.text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        }
        do {
            let d = try doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try d.write(to: u)
        } catch { note = error.localizedDescription }
    }

    /// Add to Notion: a page in the meetings database (the project's meetings_db, else Settings > Notion), the speakers,
    /// then the transcript in blocks of at most 2000 characters, 100 per request. Only on the PM's click.
    func addToNotion() {
        let c = cfg
        guard let tok = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").get(.notionToken) else { note = L("nset.saveToken"); return }
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let proj = reg.projects.first { "project:" + $0.slug == saveTarget }
        var db = proj.flatMap { c.notionMeetingsDBByProject[$0.slug] } ?? c.notionMeetingsDB
        if let p = proj, !p.config.isEmpty, let cfgText = try? String(contentsOfFile: p.config, encoding: .utf8),
           let m = cfgText.range(of: "meetings_db[^:\\n]*:\\s*\"?([0-9a-fA-F-]{32,36})", options: .regularExpression) {
            let s = String(cfgText[m]); if let id = s.range(of: "[0-9a-fA-F-]{32,36}", options: .regularExpression) { db = String(s[id]) }
        }
        guard !db.isEmpty else { note = L("tr.noMeetingsDb"); return }
        busy = true; note = L("nset.checking", ["name": "Notion"])
        let text = namedText(), titleV = title.isEmpty ? "Transcript" : title, d = date
        let who = speakers.map { $0.name ?? L("tr.speakerN", ["n": String($0.id.dropFirst())]) }
        let pname = proj?.name ?? ""
        Task {
            defer { busy = false }
            do {
                var props = (try? await NotionAPI.call(tok, "GET", "/data_sources/\(db)"))?["properties"] as? [String: [String: Any]] ?? [:]
                var dsId = db
                if props.isEmpty, let r = try? await NotionAPI.call(tok, "GET", "/databases/\(db)"),
                   let ds = ((r["data_sources"] as? [[String: Any]])?.first?["id"] as? String) {
                    dsId = ds
                    props = (try? await NotionAPI.call(tok, "GET", "/data_sources/\(ds)"))?["properties"] as? [String: [String: Any]] ?? [:]
                }
                let titleProp = props.first { ($0.value["type"] as? String) == "title" }?.key ?? "Name"
                var pp: [String: Any] = [titleProp: ["title": [["type": "text", "text": ["content": String(titleV.prefix(200))]]]]]
                if let d = d, let dp = props.first(where: { ($0.value["type"] as? String) == "date" })?.key {
                    let f = ISO8601DateFormatter(); f.timeZone = .current; pp[dp] = ["date": ["start": f.string(from: d)]]
                }
                if !pname.isEmpty, (props["Project"]?["type"] as? String) == "select" { pp["Project"] = ["select": ["name": pname]] }
                var blocks: [[String: Any]] = [Self.block("heading_2", L("tr.people")), Self.block("paragraph", who.joined(separator: ", ")),
                                               Self.block("heading_2", L("tr.transcript"))]
                var chunk = ""
                for line in text.split(separator: "\n").dropFirst(3) {
                    if chunk.count + line.count + 1 > 1900 { blocks.append(Self.block("paragraph", chunk)); chunk = "" }
                    chunk += (chunk.isEmpty ? "" : "\n") + line
                }
                if !chunk.isEmpty { blocks.append(Self.block("paragraph", chunk)) }
                let first = Array(blocks.prefix(100))
                let r = try await NotionAPI.call(tok, "POST", "/pages", ["parent": ["type": "data_source_id", "data_source_id": dsId], "properties": pp, "children": first])
                guard let id = r["id"] as? String else { throw Self.err(L("nset.noId")) }
                var i = 100
                while i < blocks.count {
                    _ = try await NotionAPI.call(tok, "PATCH", "/blocks/\(id)/children", ["children": Array(blocks[i..<min(i + 100, blocks.count)])])
                    i += 100
                }
                notionURL = r["url"] as? String ?? ""
                note = ""
            } catch { note = "Notion: " + error.localizedDescription }
        }
    }

    static func block(_ type: String, _ text: String) -> [String: Any] {
        ["object": "block", "type": type, type: ["rich_text": [["type": "text", "text": ["content": String(text.prefix(2000))]]]]]
    }
}

@MainActor
enum TranscribeWindow {
    static var window: NSWindow?
    static let notificationId = "pacenote-transcribe-done"

    static func show(file: URL? = nil) {
        let m = TranscribeModel.shared
        if let f = file, m.phase != .running, m.phase != .waiting { m.reset(); m.file = f }
        else if m.langs.isEmpty { m.reset() }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { TranscribeView() }))
            w.styleMask.insert(.resizable)
            w.setContentSize(NSSize(width: 980, height: 680))
            w.isReleasedWhenClosed = false
            _ = w.setFrameAutosaveName("PacenoteTranscribe")
            window = w
            w.center()
        }
        window?.title = L("tr.window")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func accepts(_ u: URL) -> Bool { TranscribeModel.fileTypes.contains(u.pathExtension.lowercased()) }
}

struct TranscribeView: View {
    @ObservedObject var m = TranscribeModel.shared
    @State private var dropHover = false
    @State private var query = ""
    @State private var nameFor: [String: String] = [:]

    var body: some View {
        Group {
            switch m.phase {
            case .input, .failed: input
            case .waiting, .running: progress
            case .result: result
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(PN.C.bg)
    }

    // MARK: 1. input

    private var input: some View {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        return VStack(alignment: .leading, spacing: 16) {
            WindowHeader(symbol: "waveform", title: L("tr.window"), subtitle: L("tr.subtitle"))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc").font(.system(size: 28)).foregroundStyle(PN.C.text3)
                Text(m.file?.lastPathComponent ?? L("tr.drop")).font(PN.Font.body).foregroundStyle(m.file == nil ? PN.C.text3 : PN.C.text)
                Button(L("tr.choose")) { choose() }.buttonStyle(.pnSecondary)
                Text(L("tr.types")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            .frame(maxWidth: .infinity).padding(24)
            .background(RoundedRectangle(cornerRadius: PN.Radius.m).strokeBorder(dropHover ? PN.C.accent : PN.C.text3.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
            .onDrop(of: [.fileURL], isTargeted: $dropHover) { items in
                _ = items.first?.loadObject(ofClass: URL.self) { u, _ in
                    if let u = u, TranscribeWindow.accepts(u) { DispatchQueue.main.async { m.file = u; m.link = "" } }
                }
                return true
            }
            HStack(spacing: 8) {
                Text(L("tr.link")).frame(width: 110, alignment: .leading)
                TextField("https://", text: $m.link).textFieldStyle(.roundedBorder)
                    .onChange(of: m.link) { if !m.link.isEmpty { m.file = nil } }
                    .disabled(!OptionalComponents.shared.isInstalled("link_downloader"))     // rules/components.yaml > dependants
                let src = TranscribeModel.source(m.link)
                if !src.isEmpty { Text(L("tr.src." + src)).font(PN.Font.caption).padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(PN.C.surface2)) }
            }
            HStack { Spacer().frame(width: 118); NeedsComponent(id: "link_downloader") }
            HStack(spacing: 8) {
                Text(L("tr.language")).frame(width: 110, alignment: .leading)
                LanguagePicker(codes: $m.langs)
            }
            Picker(L("tr.peopleSpeaking"), selection: $m.people) {
                Text(L("tr.findOut")).tag(0)
                ForEach(2..<5) { n in Text("\(n)").tag(n) }
                Text("5+").tag(5)
            }
            .frame(maxWidth: 360)
            Picker(L("tr.project"), selection: $m.target) {
                Text(L("tr.none")).tag("")
                ForEach(reg.projects.filter { $0.status != "archived" }, id: \.slug) { p in Text(p.name).tag("project:" + p.slug) }
                ForEach(reg.workspaces, id: \.name) { w in Text(w.name).tag("workspace:" + w.name) }
            }
            .frame(maxWidth: 360)
            if case .failed(let e) = m.phase { Text(e).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
            Spacer()
            HStack {
                Text(L("tr.privacy")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Spacer()
                Button(L("tr.transcribe")) { m.start() }
                    .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                    .disabled(m.file == nil && TranscribeModel.source(m.link).isEmpty || m.langs.isEmpty)
            }
        }
        .padding(24)
        .onAppear { OptionalComponents.shared.refresh() }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = TranscribeModel.fileTypes.compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { m.file = u; m.link = "" }
    }

    // MARK: 2. progress

    private var progress: some View {
        let steps = [L("tr.step.get"), L("tr.step.prepare"), L("tr.step.transcribe"), L("tr.step.voices")]
        let frac = m.totalS > 0 ? min(1, m.doneS / m.totalS) : 0
        let elapsed = Date().timeIntervalSince(m.started)
        let left = m.stage == 2 && frac > 0.03 ? elapsed / frac * (1 - frac) : 0
        return VStack(alignment: .leading, spacing: 14) {
            WindowHeader(symbol: "waveform", title: m.title.isEmpty ? L("tr.window") : m.title, subtitle: m.sourceRef)
            if m.phase == .waiting {
                HStack {
                    Image(systemName: "clock").foregroundStyle(PN.C.onMe)
                    Text(L("tr.afterCall")).font(PN.Font.body)
                    Spacer()
                    Button(L("tr.startNow")) {}.buttonStyle(.pnSecondary).disabled(true)
                }
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 8) {
                    Image(systemName: i < m.stage ? "checkmark.circle.fill" : i == m.stage && m.phase == .running ? "circle.dotted" : "circle")
                        .foregroundStyle(i < m.stage ? PN.C.turn : i == m.stage ? PN.C.accent : PN.C.text3)
                    Text(s).foregroundStyle(i <= m.stage ? PN.C.text : PN.C.text3)
                    if i == 2 && m.stage == 2 && m.totalS > 0 {
                        Text(L("tr.progress", ["done": TranscribeView.hm(m.doneS), "total": TranscribeView.hm(m.totalS)]) + (left > 0 ? " · " + L("tr.left", ["m": "\(Int(left / 60) + 1)"]) : ""))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
            }
            if m.stage == 2 { ProgressView(value: frac).frame(maxWidth: 420) }
            if !m.soFar.isEmpty {
                Text(L("tr.soFar")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(m.soFar, id: \.self) { Text($0).font(PN.Font.body).foregroundStyle(PN.C.text2).lineLimit(2) }
                }
            }
            Spacer()
            HStack {
                Text(L("tr.background")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Spacer()
                Button(L("tr.stop")) { m.stop() }.buttonStyle(.pnSecondary)
            }
        }
        .padding(24)
    }

    static func hm(_ s: Double) -> String { let x = Int(s); return x >= 3600 ? String(format: "%d:%02d:%02d", x / 3600, x % 3600 / 60, x % 60) : String(format: "%d:%02d", x / 60, x % 60) }

    // MARK: 3. result

    private var result: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(m.title).font(PN.Font.section).lineLimit(1)
                    Spacer()
                    TextField(L("tr.search"), text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(m.lines.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }) { l in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Button(l.t) { m.play(l.t) }.buttonStyle(.plain).font(PN.Font.caption.monospacedDigit()).foregroundStyle(PN.C.accent)
                                Text(m.label(l)).font(PN.Font.body.weight(.semibold)).foregroundStyle(m.color(m.resolve(m.overrides[l.t] ?? l.sid)))
                                Text(l.text).font(PN.Font.body).foregroundStyle(PN.C.text).textSelection(.enabled)
                            }
                            .contextMenu {
                                Menu(L("tr.split")) {
                                    ForEach(m.speakers) { s in Button(s.name ?? L("tr.speakerN", ["n": String(s.id.dropFirst())])) { m.edit(["--fix", l.t + "=" + s.id]) } }
                                }
                                Button(L("reg.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(l.text, forType: .string) }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                PlayerBar(player: m.player)
            }
            .frame(maxWidth: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    speakersCard
                    saveCard
                }
            }
            .frame(width: 330)
        }
        .padding(16)
    }

    private var speakersCard: some View {
        let team = ProjectRegistry.load(from: AppPaths.projects).projects.first { "project:" + $0.slug == m.saveTarget }?.people.map(\.name) ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack { Text(L("tr.speakers")).font(PN.Font.section); Spacer(); if m.busy { ProgressView().controlSize(.small) } }
            ForEach(m.speakers) { s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(m.color(s.id)).frame(width: 9, height: 9)
                        Text(s.name ?? L("tr.speakerN", ["n": String(s.id.dropFirst())])).font(PN.Font.body.weight(.semibold))
                        Text(L("tr.minutes", ["m": "\(max(1, Int((s.seconds / 60).rounded())))"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        Spacer()
                        if s.sample != nil { Button { m.sample(s) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain).help(L("tr.sample")) }
                    }
                    if let how = s.how {
                        Text(how == "voice" ? L("tr.namedByVoice", ["p": "\(Int((s.score ?? 0) * 100))"]) : L("tr.namedByYou")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    if s.name == nil {
                        if !s.firstQuote.isEmpty { Text("\u{201C}" + s.firstQuote + "\u{201D}").font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(2) }
                        let sug = s.suggestions.map { L("tr.soundsLike", ["name": $0.name, "p": "\(Int($0.score * 100))"]) }
                        ChipFlow(values: sug + team.filter { t in !s.suggestions.contains { $0.name == t } }, selected: []) { v in
                            let name = v.components(separatedBy: " · ").first ?? v
                            m.edit(["--name", s.id + "=" + name])
                        }
                        HStack {
                            TextField(L("tr.typeName"), text: Binding(get: { nameFor[s.id] ?? "" }, set: { nameFor[s.id] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { if let n = nameFor[s.id], !n.isEmpty { m.edit(["--name", s.id + "=" + n]); nameFor[s.id] = nil } }
                        }
                    }
                    HStack(spacing: 10) {
                        Menu(L("tr.samePerson")) {
                            ForEach(m.speakers.filter { $0.id != s.id }) { o in
                                Button(o.name ?? L("tr.speakerN", ["n": String(o.id.dropFirst())])) { m.edit(["--merge", s.id + "=" + o.id]) }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize().font(PN.Font.caption)
                        Toggle(L("tr.remember"), isOn: Binding(get: { s.remember }, set: { m.edit(["--remember", s.id + "=" + ($0 ? "on" : "off")]) }))
                            .toggleStyle(.checkbox).font(PN.Font.caption).disabled(s.name == nil)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: PN.Radius.s).fill(s.name == nil ? PN.C.onMe.opacity(0.08) : PN.C.surface))
            }
        }
        .padding(14).background(PN.C.surface2.opacity(0.5), in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    private var saveCard: some View {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        return VStack(alignment: .leading, spacing: 10) {
            Text(L("tr.save")).font(PN.Font.section)
            TextField(L("tr.title"), text: $m.title).textFieldStyle(.roundedBorder)
            HStack {
                Toggle(L("tr.date"), isOn: Binding(get: { m.date != nil }, set: { m.date = $0 ? (m.date ?? Date()) : nil })).toggleStyle(.checkbox)
                if m.date != nil {
                    DatePicker("", selection: Binding(get: { m.date ?? Date() }, set: { m.date = $0 })).labelsHidden()
                }
            }
            Picker(L("tr.project"), selection: Binding(get: { m.saveTarget }, set: { m.saveTarget = $0; if !$0.isEmpty { m.addToProject() } })) {
                Text(L("tr.none")).tag("")
                ForEach(reg.projects.filter { $0.status != "archived" }, id: \.slug) { p in Text(p.name).tag("project:" + p.slug) }
                ForEach(reg.workspaces, id: \.name) { w in Text(w.name).tag("workspace:" + w.name) }
            }
            Button(L("tr.addNotion")) { m.addToNotion() }.buttonStyle(.pnPrimary).disabled(m.busy)
            if !m.notionURL.isEmpty, let u = URL(string: m.notionURL) { Link(L("ntask.openNotion"), destination: u).font(PN.Font.caption) }
            HStack {
                Button(L("tr.saveMd")) { m.saveMarkdown() }.buttonStyle(.pnSecondary)
                Button(L("tr.saveWord")) { m.saveWord() }.buttonStyle(.pnSecondary)
            }
            if !m.note.isEmpty { Text(m.note).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            Text(L("tr.nothingSent")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            Button(L("tr.another")) { m.reset() }.buttonStyle(.pnTertiary)
        }
        .padding(14).background(PN.C.surface2.opacity(0.5), in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }
}

/// The player under the transcript: play or pause and a position slider.
struct PlayerBar: View {
    let player: AVPlayer
    @State private var pos = 0.0
    @State private var total = 1.0
    @State private var playing = false
    let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 10) {
            Button { if player.rate > 0 { player.pause() } else { player.play() } } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                .buttonStyle(.plain)
            Slider(value: Binding(get: { pos }, set: { pos = $0; player.seek(to: CMTime(seconds: $0, preferredTimescale: 600)) }), in: 0...max(1, total))
            Text(TranscribeView.hm(pos) + " / " + TranscribeView.hm(total)).font(PN.Font.caption.monospacedDigit()).foregroundStyle(PN.C.text3)
        }
        .padding(8).background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.s))
        .onReceive(tick) { _ in
            pos = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
            if let d = player.currentItem?.duration.seconds, d.isFinite { total = d }
            playing = player.rate > 0
        }
    }
}
