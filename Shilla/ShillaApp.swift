import SwiftUI

@main
struct ShillaApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var phase

    init() {
        let bg = UIColor(red: 0.031, green: 0.051, blue: 0.110, alpha: 1)
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(red: 0.055, green: 0.078, blue: 0.157, alpha: 1)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = bg
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if app.isSetup { RootTabs() } else { WelcomeView() }
            }
            .environmentObject(app)
            .environment(\.layoutDirection, .rightToLeft)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .overlay(alignment: .top) {
                if let t = app.toast {
                    Text(t).font(.footnote).foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.surface2, in: Capsule())
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
