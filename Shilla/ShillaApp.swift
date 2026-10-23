import SwiftUI

@main
struct ShillaApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if app.isSetup { HomeView() } else { WelcomeView() }
            }
            .environmentObject(app)
            .environment(\.layoutDirection, .rightToLeft)
            .tint(Color(red: 0.40, green: 0.36, blue: 0.98))
            .overlay(alignment: .top) {
                if let t = app.toast {
                    Text(t).font(.footnote).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut, value: app.toast)
            .onAppear { app.start() }
            .onChange(of: phase) { p in if p == .active { app.start() } }
        }
    }
}
