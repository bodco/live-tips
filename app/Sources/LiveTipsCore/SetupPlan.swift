import Foundation

/// 0.24.1 (F1, Bohdan 18.11): the base set Pacenote installs in one go, what each step needs first, and the one loader's
/// numbers (progress, MB, ETA). Pure, so CoreChecks can test it; the app runs setup.sh (SetupModel).
public enum SetupPlan {
    /// Everything a call needs, in install order. bge-m3 (localai) and voices are part of it (decision 11): without
    /// them tips get worse and nobody is named in the notes. Claude Code is not here (decision 10): it comes with a
    /// Claude account, like Codex with a ChatGPT account.
    public static let base = ["python", "core", "venv", "recorder", "tips", "whisper", "localai", "voices"]
    /// The part of the base set without which a call does not start (decision 9); localai and voices only degrade.
    public static let callBlocking = ["python", "core", "venv", "recorder", "whisper", "tips"]
    /// The command line tools installed when an account is connected, never from the components list.
    public static let accountTools = ["claude", "codex"]

    /// What a step needs installed before it (setup.sh): the venv needs Python, the packages need the venv, the model
    /// load needs the recorder packages. core and localai need nothing.
    public static func needs(_ step: String) -> [String] {
        switch step {
        case "venv": return ["python"]
        case "recorder", "tips", "voices": return ["venv"]
        case "whisper": return ["recorder"]
        default: return []
        }
    }

    /// The step this one waits for that failed (directly or through its own needs); nil when it can run.
    public static func blockedBy(_ step: String, failed: Set<String>) -> String? {
        for n in needs(step) {
            if failed.contains(n) { return n }
            if let b = blockedBy(n, failed: failed) { return b }
        }
        return nil
    }

    /// How much one step weighs in the loader (bytes it downloads, roughly; a few MB for the quick ones so they move).
    public static func weight(_ step: String) -> Double {
        switch step {
        case "python": return 25e6
        case "core": return 2e6
        case "venv": return 5e6
        case "recorder": return 260e6     // mlx, torch, numpy, scipy, numba
        case "tips": return 60e6          // onnxruntime, tokenizers, anthropic
        case "whisper": return 1_620e6
        case "localai": return 590e6
        case "voices": return 30e6
        case "claude": return 70e6
        case "codex": return 115e6
        default: return 5e6
        }
    }

    /// One "PROGRESS <done> <total> <B|pkg>" line from setup.sh: the step's fraction 0...1 and, for downloads, bytes.
    public struct Progress: Equatable {
        public let fraction: Double
        public let bytes: Int64?
        public let total: Int64?
        public init(fraction: Double, bytes: Int64?, total: Int64?) { self.fraction = fraction; self.bytes = bytes; self.total = total }
    }

    public static func parse(_ line: String) -> Progress? {
        let p = line.split(separator: " ")
        guard p.count == 4, p[0] == "PROGRESS", let d = Double(p[1]), let t = Double(p[2]), t > 0, d >= 0 else { return nil }
        let f = min(1, d / t)
        return p[3] == "B" ? Progress(fraction: f, bytes: Int64(d), total: Int64(t)) : Progress(fraction: f, bytes: nil, total: nil)
    }

    /// The whole run's fraction from each step's own: done steps count whole, the running one by its fraction.
    public static func overall(steps: [String], done: Set<String>, running: String?, fraction: Double) -> Double {
        let all = steps.reduce(0) { $0 + weight($1) }
        guard all > 0 else { return 0 }
        let d = steps.filter { done.contains($0) }.reduce(0) { $0 + weight($1) }
        let r = running.map { done.contains($0) ? 0 : weight($0) * min(1, max(0, fraction)) } ?? 0
        return min(1, (d + r) / all)
    }

    /// Seconds left at the speed so far (nil until 5 s and 2 % are in: an early guess jumps around).
    public static func eta(fraction: Double, elapsed: TimeInterval) -> TimeInterval? {
        guard elapsed >= 5, fraction >= 0.02, fraction < 1 else { return nil }
        return elapsed / fraction * (1 - fraction)
    }

    /// "about 3 min", "about 40 s", "less than a minute" in the app's words is the caller's; here whole minutes or seconds.
    public static func etaText(_ s: TimeInterval) -> String {
        s >= 90 ? "\(Int((s / 60).rounded())) min" : s >= 45 ? "1 min" : "\(max(5, Int((s / 5).rounded()) * 5)) s"
    }

    /// The error code a failed step's log gives (F7 telemetry, never text): python_unsupported, module_missing, ...
    public static func errorCode(step: String, log: [String]) -> String {
        let t = log.joined(separator: "\n").lowercased()
        if t.contains("checksum mismatch") { return "checksum" }
        if t.contains("could not download") || t.contains("download failed") || t.contains("could not resolve") || t.contains("timed out") { return "network" }
        if t.contains("no matching distribution") || t.contains("requires-python") || t.contains("unsupported") { return "python_unsupported" }
        if t.contains("no space left") { return "disk_full" }
        if t.contains("needs ") && t.contains("first") { return "blocked" }
        return step == "whisper" || step == "localai" ? "model_missing" : "install_failed"
    }
}

/// 0.24.1 (F1): signing in to an account's command line tool from the app, without Terminal. The tool runs as a child
/// process; the browser opens for the sign-in; if the tool asks for a code, the app shows a field and writes it to
/// the tool's input.
public enum CLILogin {
    public static func arguments(_ kind: String) -> [String] {
        switch kind {
        case "claude": return ["auth", "login"]
        case "codex": return ["-c", "forced_login_method=\"chatgpt\"", "login"]
        default: return []          // agy: the sign-in is its first run
        }
    }

    public enum Event: Equatable { case url(String), askCode, done, failed(String) }

    /// What one line of the tool's output means for the app.
    public static func event(_ line: String) -> Event? {
        let l = line.trimmingCharacters(in: .whitespaces)
        if let r = l.range(of: #"https://[^\s"'<>]+"#, options: .regularExpression) { return .url(String(l[r])) }
        let low = l.lowercased()
        if (low.contains("paste") || low.contains("enter")) && low.contains("code") { return .askCode }
        if low.contains("successfully logged in") || low.contains("login successful") || low.contains("logged in as") || low.contains("signed in") { return .done }
        if low.hasPrefix("error") || low.contains("login failed") { return .failed(String(l.prefix(200))) }
        return nil
    }
}

/// 0.24.1 (F2, decision 5): an onboarding that was not finished comes back at the next launch, at the step it was left
/// on (the first outside user restarted the app on the permissions step and never saw it again). People who closed
/// it with "Set up later" before 0.24.1 and have everything installed are not asked again.
public enum OnboardingResume {
    public static func shouldShow(done: Bool, legacyShown: Bool, baseLikelyReady: Bool) -> Bool {
        if done { return false }
        return !legacyShown || !baseLikelyReady
    }

    /// The step to open on: the saved one (clamped), else the first.
    public static func step(saved: Int?, count: Int) -> Int {
        guard let s = saved, count > 0 else { return 0 }
        return min(max(0, s), count - 1)
    }
}

/// 0.24.1 (F6, decision 9): whether a call can start, one answer for every start point (Home, the call page, the menu
/// bar, the hot key, Up next). Without the base a call is not started: there would be no transcript, no tips, no
/// notes. Without any AI a call is recording and transcript only. bge-m3 and voices only degrade the call.
public enum CallReadiness {
    public enum Verdict: Equatable {
        case ready
        case transcriptOnly(String)     // "no_ai" or "account_tool"
        case blocked([String])          // the missing steps that block, in install order
    }

    public static let accountRoutes: Set<String> = ["code", "codex", "agy"]

    /// `missing`: the base steps not in place; `connected`: the AIs that can run now; `routes`: the AI of each job.
    public static func check(missing: [String], connected: Set<String>, routes: [String]) -> Verdict {
        let block = SetupPlan.callBlocking.filter { missing.contains($0) }
        if !block.isEmpty { return .blocked(block) }
        if connected.isEmpty {
            return .transcriptOnly(routes.contains { accountRoutes.contains($0) } ? "account_tool" : "no_ai")
        }
        return .ready
    }

    /// What is missing but does not block (offered, never in the way).
    public static func degraded(missing: [String]) -> [String] { ["localai", "voices"].filter { missing.contains($0) } }

    /// The telemetry reason of a refused or reduced start (call_blocked.reason), nil when ready.
    public static func reason(_ v: Verdict) -> String? {
        switch v {
        case .ready: return nil
        case .blocked: return "base_missing"
        case .transcriptOnly(let r): return r
        }
    }
}

/// 0.24.1 (F6): the base set by its files, fast and without running anything (setup.sh `check` runs Python and takes
/// seconds; a start button cannot wait for it). `exists` and `list` are the file system, so CoreChecks can test it.
public enum BaseFiles {
    public static let whisperRepo = "mlx-community/whisper-large-v3-turbo"

    public static func missing(appRoot r: String, home: String, exists: (String) -> Bool, list: (String) -> [String]) -> [String] {
        func p(_ s: String) -> String { (r as NSString).appendingPathComponent(s) }
        let lib = p(".venv/lib")
        let site = list(lib).sorted().first { $0.hasPrefix("python3") }.map { lib + "/" + $0 + "/site-packages" }
        func pkg(_ names: String...) -> Bool { guard let s = site else { return false }; return names.allSatisfy { exists(s + "/" + $0) } }
        let hub = home + "/.cache/huggingface/hub/models--" + whisperRepo.replacingOccurrences(of: "/", with: "--") + "/snapshots"
        var out: [String] = []
        if !(exists(p("python/bin/python3")) || exists(p("python.fallback")) || exists(p(".venv/bin/python"))) { out.append("python") }
        if !exists(p("src/transcriber.py")) { out.append("core") }
        if !exists(p(".venv/bin/python")) { out.append("venv") }
        if !pkg("mlx_whisper", "numpy") { out.append("recorder") }
        if !pkg("anthropic", "yaml", "jsonschema", "onnxruntime", "tokenizers") { out.append("tips") }
        if list(hub).isEmpty { out.append("whisper") }
        if !exists(p("models/bge-m3-int8/model_quantized.onnx")) { out.append("localai") }
        if !(pkg("sherpa_onnx") && exists(p("models/wespeaker_en_voxceleb_resnet34_LM.onnx"))) { out.append("voices") }
        return out
    }
}

/// 0.24.1 (F6): why a call has no transcript lines, kept next to the transcript (<file>.norec.json) for the call page.
public enum NothingRecorded {
    /// model_loading: ended while the speech model was loading; not_started: the recorder never started recording;
    /// silence: it recorded but heard no speech.
    public static func reason(sawLoading: Bool, sawRecording: Bool) -> String {
        sawRecording ? "silence" : sawLoading ? "model_loading" : "not_started"
    }
    public static func path(transcript: String) -> String { transcript + ".norec.json" }
}
