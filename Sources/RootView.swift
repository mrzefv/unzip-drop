//
//  RootView.swift
//  App shell. The app is a signer first: Library (sign + install), Browse
//  (repo.json sources → apps → IPA), Signed (history), Settings. The GitHub
//  tools (Import · Contents · Push · Build · Repos) live behind Settings ›
//  GitHub as a full-screen hub.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var signQueue = SignQueue.shared
    @State private var showSign = false
    @ObservedObject private var hub = GitHubHub.shared
    @State private var tab = 0
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var themePanel = ThemePanelState.shared
    @State private var wheelExpanded = true
    @State private var bgExpanded = false

    var body: some View {
        ZStack {
            // App-wide animated background — shows behind every tab, incl. Browse.
            ParticleBackground(accent: theme.accent, style: theme.background)

            ZStack {
                switch tab {
                case 0: LibraryView()
                case 1: SourcesView()
                case 2: SignedView()
                default: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if themePanel.open {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { withAnimation { themePanel.open = false } }
                VStack {
                    ThemePalettePanel(expandedWheel: $wheelExpanded, expandedBackground: $bgExpanded) { themePanel.open = false }
                        .padding(.top, 60)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabBar(selected: $tab)
        }
        // ─── Accent frame lives at the OUTERMOST level, above every tab AND
        // the TabBar. Nothing any tab draws (NavigationStack, List backgrounds,
        // etc.) can cover it because this overlay is applied last. ───
        .overlay(
            AccentFrame(color: theme.accent)
                .allowsHitTesting(false)
        )
        .tint(theme.accent)
        .preferredColorScheme(theme.darkMode ? .dark : .light)
        .onChange(of: signQueue.requestedTab) { t in
            // Signing is a flow, not a tab: present SignView over whatever's showing.
            if t != nil { showSign = true; signQueue.requestedTab = nil }
        }
        .fullScreenCover(isPresented: $showSign) { SignView().preferredColorScheme(.dark) }

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
        .background(BarBlur())
        .overlay(Rectangle().fill(Theme.accent).frame(height: 2), alignment: .top)
    }
}

// MARK: - Accent frame around the app content
// 2px vertical rails on the left and right, plus a top border that visually
// connects to the accent overlay on top of the TabBar. Everything is a
// non-interactive overlay so it never intercepts touches.

private struct AccentFrame: View {
    var color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Left sidebar (2px) — full height incl. safe areas
                Rectangle().fill(color)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Right sidebar (2px)
                Rectangle().fill(color)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                // Top border (2px) — spans full width, meets both sidebars at corners
                Rectangle().fill(color)
                    .frame(height: 2)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
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
        ("Repos",    "book.closed.fill"),
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
                        HStack(spacing: 4) {
                            Image(systemName: p.icon).font(.system(size: 11, weight: .semibold))
                            Text(p.label).font(.system(size: 11, weight: .semibold))
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
                case 3: BuildView()
                default: RepoBrowseView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: session.lastEventID) { _ in hub.page = 1 }   // after an import/generate, show Contents
    }
}
