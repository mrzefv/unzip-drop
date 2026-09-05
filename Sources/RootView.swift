//
//  RootView.swift
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: Session
    @State private var tab = 0

    init() {
        let a = UITabBarAppearance()
        a.configureWithOpaqueBackground()
        a.backgroundColor = UIColor(Theme.bg)
        UITabBar.appearance().standardAppearance = a
        UITabBar.appearance().scrollEdgeAppearance = a
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            TabView(selection: $tab) {
                ImportView()
                    .tabItem { Label("Import", systemImage: "tray.and.arrow.down.fill") }.tag(0)
                ContentsView()
                    .tabItem { Label("Contents", systemImage: "folder.fill") }.tag(1)
                PushView()
                    .tabItem { Label("Push", systemImage: "arrow.up.circle.fill") }.tag(2)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
            }
            .tint(Theme.accent)
        }
        .background(Theme.bg.ignoresSafeArea())
        // Jump to Import whenever a new file comes in (e.g. via Open With), so the
        // progress/result/error is visible.
        .onChange(of: session.lastEventID) { _ in tab = 0 }
    }
}
