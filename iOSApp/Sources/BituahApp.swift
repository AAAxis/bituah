import SwiftUI
import BituahCore

@main
struct BituahApp: App {
    @StateObject private var history = HistoryStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { ScanView() }
                    .tabItem { Label("סריקה", systemImage: "camera.viewfinder") }
                NavigationStack { HistoryView() }
                    .tabItem { Label("היסטוריה", systemImage: "clock.arrow.circlepath") }
            }
            .environmentObject(history)
            .environment(\.layoutDirection, .rightToLeft)
            .tint(Color(red: 0.05, green: 0.42, blue: 0.75))
        }
    }
}
