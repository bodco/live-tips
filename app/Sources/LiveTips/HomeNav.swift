import AppKit
import LiveTipsCore
import SwiftUI

/// Pacenote 0.8.7 (A2): Home is one window with a navigation stack. The call page, the series, the transcript and
/// Statistics are pushed into it with a Back bar (chevron and the previous screen's name) and Command-[. The old
/// window entry points (CallPageWindow, SeriesWindow, InsightsWindow, TranscriptWindow, FollowUpWindow) push here.
@MainActor
final class HomeNav: ObservableObject {
    static let shared = HomeNav()
    enum Route: Hashable {
        case call(String)                    // transcript file
        case series(String)                  // a record's file
        case transcript(String, String?)     // file, moment
        case stats
    }
    @Published var path: [Route] = []
    @Published var followUp: String?         // the call page whose follow-up panel is open (A3)

    func open(_ r: Route) {
        if let app = NSApp.delegate as? AppDelegate { HomeWindow.show(delegate: app) }
        if path.last == r { return }
        path.append(r)
    }

    func back() { if !path.isEmpty { path.removeLast() } }

    func title(_ r: Route) -> String {
        switch r {
        case .call(let f): return CallPageView.title(f)
        case .series(let f): return CallHistory.shared.records.first { $0.file == f }?.title ?? L("series.title", ["title": ""])
        case .transcript(let f, _): return L("call.page.transcript") + " · " + CallPageView.title(f)
        case .stats: return L("home.week.detailsTitle")
        }
    }

    /// The name on the Back bar of the screen at `index` in the path: the screen below it, or Home.
    func backTitle(at index: Int) -> String { index == 0 ? L("home.window.title") : title(path[index - 1]) }
}

/// The screen for a route, under a Back bar.
struct HomeRouteView: View {
    let route: HomeNav.Route
    @ObservedObject var nav = HomeNav.shared

    var body: some View {
        let i = nav.path.firstIndex(of: route) ?? 0
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { nav.back() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(nav.backTitle(at: i)).lineLimit(1)
                    }
                }
                .buttonStyle(.pnTertiary)
                .keyboardShortcut("[", modifiers: .command)
                .help(L("nav.back.help"))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            content
        }
        .navigationBarBackButtonHidden(true)
        .background(PN.C.bg)
    }

    @ViewBuilder private var content: some View {
        switch route {
        case .call(let f):
            // 0.8.7 (A3): the follow-up email is the call page's right panel; in a window narrower than 760 pt a sheet
            GeometryReader { g in
                let narrow = g.size.width < 760
                CallPageView(file: f)
                    .inspector(isPresented: Binding(get: { !narrow && nav.followUp == f }, set: { if !$0 && !narrow { nav.followUp = nil } })) {
                        FollowUpView(file: f).inspectorColumnWidth(min: 320, ideal: 380, max: 560)
                    }
                    .sheet(isPresented: Binding(get: { narrow && nav.followUp == f }, set: { if !$0 { nav.followUp = nil } })) {
                        VStack(spacing: 0) {
                            HStack {
                                Text(L("call.page.followup")).font(PN.Font.section)
                                Spacer()
                                Button(L("common.close")) { nav.followUp = nil }.buttonStyle(.pnSecondary).keyboardShortcut(.cancelAction)
                            }
                            .padding(.horizontal, 20).padding(.top, 14)
                            ScrollView { FollowUpView(file: f) }
                        }
                        .frame(width: 520, height: 600)
                    }
            }
        case .series(let f):
            if let r = CallHistory.shared.records.first(where: { $0.file == f }) { SeriesView(record: r) } else { Text(L("call.page.empty")).padding() }
        case .transcript(let f, let at): TranscriptView(file: f, at: at)
        case .stats: ScrollView { WeekStats().padding(20) }
        }
    }
}
