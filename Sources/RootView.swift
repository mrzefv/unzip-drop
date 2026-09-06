//
//  RootView.swift
//  App shell. The app is a signer first: Library (sign + install), Browse
//  (GitHub repos → releases / artifacts / files → IPA), Signed (history),
//  Settings. The GitHub workspace tools (Import · Contents · Push · Build)
//  live behind Settings › GitHub as a full-screen hub.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var signQueue = SignQueue.shared
    @ObservedObject private var hub = GitHubHub.shared
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ZStack {
                switch tab {
                case 0: SignView()
                case 1: RepoBrowseView()
                case 2: SignedView()
                default: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            TabBar(selected: $tab)
        }
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: signQueue.requestedTab) { t in
            if let t { tab = t; signQueue.requestedTab = nil }
        }
        .fullScreenCover(isPresented: $hub.isPresented) {
            GitHubHubScreen()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Tab bar

private struct TabBar: View {
    @Binding var selected: Int
    private let tabs: [(label: String, icon: String)] = [
        ("Library",  "square.stack.3d.up.fill"),
        ("Browse",   "safari.fill"),
        ("Signed",   "signature"),
        ("Settings", "gearshape.fill"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                Button { selected = i } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 20))
                        Text(t.label).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(selected == i ? Theme.accent : Theme.subtle)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 50)
        .padding(.top, 8)
        .background(
            Theme.bg
                .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - GitHub hub (Import · Contents · Push · Build) presented from Settings

@MainActor
final class GitHubHub: ObservableObject {
    static let shared = GitHubHub()
    @Published var isPresented = false
    @Published var page = 0
    private init() {}

    func open(_ page: Int) { self.page = page; isPresented = true }
}

struct GitHubHubScreen: View {
    @ObservedObject private var hub = GitHubHub.shared
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

    private let pages: [(label: String, icon: String)] = [
        ("Import",   "tray.and.arrow.down.fill"),
        ("Contents", "folder.fill"),
        ("Push",     "arrow.up.circle.fill"),
        ("Build",    "hammer.fill"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                    Text("UNZIP DROP").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
                    Spacer()
                }
                Text("GitHub").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34).background(Theme.accent.opacity(0.14)).clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.bg)
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)

            // Segmented pages
            HStack(spacing: 6) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    Button { hub.page = i } label: {
                        HStack(spacing: 6) {
                            Image(systemName: p.icon).font(.system(size: 12, weight: .semibold))
                            Text(p.label).font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.vertical, 8).frame(maxWidth: .infinity)
                        .background(hub.page == i ? Theme.accent.opacity(0.16) : Theme.card)
                        .foregroundStyle(hub.page == i ? Theme.accent : Theme.subtle)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hub.page == i ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.bg)

            ZStack {
                switch hub.page {
                case 0: ImportView()
                case 1: ContentsView()
                case 2: PushView()
                default: BuildView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: session.lastEventID) { _ in hub.page = 1 }   // after an import/generate, show Contents
    }
}
