import SwiftUI

@main
struct ShillaApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if app.isConfigured { ChatView() } else { SettingsView(firstRun: true) }
            }
            .environmentObject(app)
            .environment(\.layoutDirection, .rightToLeft)
            .onAppear { app.start() }
            .onChange(of: phase) { p in if p == .active { app.start() } }
        }
    }
}
