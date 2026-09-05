//
//  RootView.swift
//  Custom shell — no SwiftUI TabView (its iOS 26 default is a floating glass bar
//  that also pushes content down). A plain VStack: pinned wordmark header on top,
//  the active screen in the middle, a docked custom tab bar flush at the bottom.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var signQueue = SignQueue.shared
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            TopBar()

            ZStack {
                switch tab {
                case 0: ImportView()
                case 1: ContentsView()
                case 2: PushView()
                case 3: BuildView()
                case 4: SignView()
                default: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TabBar(selection: $tab)
        }
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: session.lastEventID) { _ in tab = 0 }
        .onChange(of: signQueue.requestedTab) { t in
            if let t { tab = t; signQueue.requestedTab = nil }
        }
    }
}

private struct TabBar: View {
    @Binding var selection: Int

    private let tabs: [(label: String, icon: String)] = [
        ("Import",   "tray.and.arrow.down.fill"),
        ("Contents", "folder.fill"),
        ("Push",     "arrow.up.circle.fill"),
        ("Build",    "hammer.fill"),
        ("Sign",     "signature"),
        ("Settings", "gearshape.fill"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                Button { selection = i } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 19))
                        Text(t.label).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selection == i ? Theme.accent : Theme.subtle)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 50)
        .padding(.top, 8)
        .background(alignment: .top) {
            Theme.bg
                .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
