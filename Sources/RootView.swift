//
//  RootView.swift
//  App shell. The app is a signer first: Browse (repo.json sources → apps →
//  IPA), Library (sign + install), Signed (history), Settings. Handing an IPA to
//  SignQueue opens SigningSheet directly — there is no intermediate Sign screen. The GitHub
//  tools (Import · Contents · Push · Build · Repos) live behind Settings ›
//  GitHub as a full-screen hub.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var signQueue = SignQueue.shared
    @ObservedObject private var hub = GitHubHub.shared
    @ObservedObject private var theme = AppTheme.shared
    @ObservedObject private var account = ZefvAccount.shared
    @ObservedObject private var nav = AppNav.shared
    @ObservedObject private var onboarding = Onboarding.shared
    @State private var tab = 0
    @State private var signItem: SignItem?
    @State private var signError: String?

    /// An IPA handed to the shell for signing — goes straight into SigningSheet.
    private struct SignItem: Identifiable {
        let url: URL
        let meta: IPAMeta
        var id: String { url.path }
    }

    var body: some View {
        ZStack {
            switch tab {
            case 0: SourcesView()
            case 1: LibraryView()
            case 2: SignedView()
            default: SettingsView()
            }
        }
        .id(theme.revision)                                   // re-skin every tab on a theme change
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(ThemeBackgroundLayer())                      // particle/grid network floats over the tab content
        .overlay(alignment: .topLeading) {
            // Invisible anchor under the palette button in the title bar; hosts the theme dropdown.
            Color.clear.frame(width: 44, height: 44)
                .padding(.leading, 26).padding(.top, 8)
                .allowsHitTesting(false)
                .popover(isPresented: $theme.panelShown, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    ThemePanel()
                        .then { view in
                            if #available(iOS 16.4, *) {
                                view.presentationCompactAdaptation(.popover)
                                    .presentationBackground(Theme.bg)
                            } else {
                                view
                            }
                        }
                        .preferredColorScheme(theme.colorScheme)
                }
        }
        .overlay(alignment: .topTrailing) {
            // Anchor under the account chip; hosts the account dropdown.
            Color.clear.frame(width: 44, height: 44)
                .padding(.trailing, 26).padding(.top, 8)
                .allowsHitTesting(false)
                .popover(isPresented: $account.panelShown, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    AccountDropdown()
                        .then { view in
                            if #available(iOS 16.4, *) {
                                view.presentationCompactAdaptation(.popover)
                                    .presentationBackground(Theme.bg)
                            } else {
                                view
                            }
                        }
                        .preferredColorScheme(theme.colorScheme)
                }
        }
        .onChange(of: nav.requestedTab) { t in
            guard let t else { return }
            nav.requestedTab = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = t }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabBar(selected: $tab)
        }
        .background(Theme.bg.ignoresSafeArea())
        .tint(Theme.accent)
        .preferredColorScheme(theme.colorScheme)
        .onChange(of: signQueue.requestedTab) { t in
            // Signing is a flow, not a tab: open SigningSheet directly over whatever's showing.
            guard t != nil else { return }
            signQueue.requestedTab = nil
            if let url = signQueue.pending { openSigningSheet(url) }
        }
        .fullScreenCover(item: $signItem) { it in
            SigningSheet(ipaURL: it.url, meta: it.meta) { _ in }
                .preferredColorScheme(theme.colorScheme)
        }
        .fullScreenCover(isPresented: $hub.isPresented) {
            GitHubHubScreen()
                .environmentObject(session)
                .preferredColorScheme(theme.colorScheme)
        }
        .alert("Couldn't read IPA", isPresented: Binding(get: { signError != nil }, set: { if !$0 { signError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(signError ?? "") }
        .fullScreenCover(isPresented: $onboarding.needsOnboarding) {
            OnboardingView { onboarding.complete() }
        }
    }

    private func openSigningSheet(_ url: URL) {
        Task {
            do {
                let m = try await Task.detached { try IPAMeta.read(url) }.value
                signQueue.pending = nil
                signItem = SignItem(url: url, meta: m)
            } catch {
                signQueue.pending = nil
                signError = error.localizedDescription
            }
        }
    }
}

// MARK: - View Extensions

extension View {
    @ViewBuilder
    func then<Content: View>(@ViewBuilder _ transform: (Self) -> Content) -> Content {
        transform(self)
    }
}

// MARK: - Tab bar

private struct TabBar: View {
    @Binding var selected: Int
    @ObservedObject private var theme = AppTheme.shared
    private let tabs: [(label: String, icon: String)] = [
        ("Browse",   "square.grid.3x3.fill"),
        ("Library",  "square.grid.2x2.fill"),
        ("Signed",   "signature"),
        ("Settings", "gearshape"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selected = i }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 22, weight: .regular))
                            .frame(height: 26)
                        Text(t.label).font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(selected == i ? Theme.accent : Theme.subtle)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        // Floating Liquid Glass capsule; the tabs' scroll views run underneath it.
        .floatingGlassBar(edge: .bottom, cornerRadius: 30)
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
            .padding(.horizontal, 16).padding(.vertical, 10)
            .floatingGlassBar(edge: .top)

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
