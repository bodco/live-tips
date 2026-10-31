import AppKit
import SwiftUI
import LiveTipsCore

// Pacenote 0.8.7 (L1): "What Pacenote can do". One registry of features: a name, one sentence, Try it, the condition
// when it shows up, and how often it was used (the local usage log, M). Shown in Help, in the menu bar's Help and as a
// card on Home for the first 14 days. A new feature is one entry here and two lines in each language file.

@MainActor
enum FeatureRegistry {
    struct Feature: Identifiable { let id: String; let event: String; let hasWhen: Bool; let tryIt: () -> Void }

    static var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    static var all: [Feature] { [
        Feature(id: "start", event: "call_started", hasWhen: false) { if let a = app { StartCallWindow.show(delegate: a) } },
        Feature(id: "prepare", event: "prepare_run", hasWhen: true) { if let a = app { StartCallWindow.show(delegate: a, planOnly: true) } },
        Feature(id: "presentation", event: "presentation_mode_on", hasWhen: true) { startWith(type: "presentation") },
        Feature(id: "rehearse", event: "rehearsal_started", hasWhen: true) { startWith(type: "presentation") },
        Feature(id: "upnext", event: "prepare_run", hasWhen: false) { if let a = app { StartCallWindow.show(delegate: a, planOnly: true) } },
        Feature(id: "transcribe", event: "transcribe_run", hasWhen: false) { TranscribeWindow.show() },
        Feature(id: "search", event: "search_calls", hasWhen: false) { MemoryWindow.show() },
        Feature(id: "followup", event: "followup_written", hasWhen: false) {
            if let r = CallHistory.shared.visible.first { FollowUpWindow.show(file: r.file) } else { app?.showDemo() }
        },
        Feature(id: "series", event: "series_opened", hasWhen: true) {
            if let r = CallHistory.shared.visible.first(where: { CallPageView.series(of: $0).count > 1 }) ?? CallHistory.shared.visible.first {
                SeriesWindow.show(record: r)
            }
        },
        Feature(id: "notionTasks", event: "notion_task_ticked", hasWhen: true) { SettingsWindow.show(tab: "notion") },
        Feature(id: "sales", event: "call_started", hasWhen: false) { startWith(type: "", sales: true) },
        Feature(id: "demo", event: "demo_opened", hasWhen: false) { app?.showDemo() },
        Feature(id: "demoPresentation", event: "demo_opened", hasWhen: false) { app?.showDemoPresentation() },
    ] }

    static func startWith(type: String, sales: Bool = false) {
        guard let a = app else { return }
        let m = StartCallModel()
        if !type.isEmpty { m.callType = type }
        if sales { m.salesEnabled = true }
        StartCallWindow.show(delegate: a, prepared: m)
    }

    static func tryIt(_ f: Feature) {
        UsageLog.log("feature_try_it", ["feature": f.id])
        f.tryIt()
    }

    nonisolated static var usageDir: URL {
        let c = AppConfig.load(from: AppPaths.config)
        return URL(fileURLWithPath: c.effectiveAppRoot(appSupport: AppPaths.support.path)).appendingPathComponent("usage")
    }
}

struct FeaturesView: View {
    var compact = false
    var onClose: (() -> Void)? = nil
    @State private var counts: [String: Int] = [:]

    var body: some View {
        let list = FeatureRegistry.all.sorted { (counts[$0.event] ?? 0 == 0 ? 0 : 1) < (counts[$1.event] ?? 0 == 0 ? 0 : 1) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("feat.title")).font(compact ? PN.Font.section : PN.Font.title).foregroundStyle(PN.C.text)
                    Text(L("feat.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
                Spacer()
                if let onClose { Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.pnTertiary).help(L("feat.close")).accessibilityLabel(L("feat.close")) }
            }
            ForEach(compact ? Array(list.prefix(5)) : list) { f in
                let n = counts[f.event] ?? 0
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(L("feat." + f.id)).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                            Text(n == 0 ? L("feat.notTried") : L("feat.used", ["n": "\(n)"])).font(PN.Font.caption)
                                .padding(.horizontal, 6).background(Capsule().fill(Color.secondary.opacity(0.12))).foregroundStyle(PN.C.text3)
                        }
                        Text(L("feat." + f.id + ".what")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                        if f.hasWhen { Text(L("feat.when", ["when": L("feat." + f.id + ".when")])).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 8)
                    Button(L("feat.try")) { FeatureRegistry.tryIt(f) }.buttonStyle(.pnTertiary)
                }
                .padding(.vertical, 4)
            }
            if compact {
                Button(L("feat.all")) { FeaturesWindow.show() }.buttonStyle(.pnTertiary)
            }
        }
        .padding(compact ? 20 : 24)
        .onAppear { counts = UsageLog.counts(dir: FeatureRegistry.usageDir) }
    }
}

@MainActor
enum FeaturesWindow {
    static var window: NSWindow?
    static func show() {
        UserDefaults.standard.set(false, forKey: "featuresCardClosed")       // Help brings the Home card back
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { ScrollView { FeaturesView() }.background(PN.C.bg) }))
            w.tabbingMode = .disallowed
            w.title = L("feat.title")
            w.setContentSize(NSSize(width: 620, height: 640))
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The Home card: the first 14 days after the first launch, until closed.
    static var showOnHome: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: "firstLaunchDate") == nil { d.set(Date(), forKey: "firstLaunchDate") }
        guard !d.bool(forKey: "featuresCardClosed"), let first = d.object(forKey: "firstLaunchDate") as? Date else { return false }
        return Date().timeIntervalSince(first) < 14 * 86400
    }
}
