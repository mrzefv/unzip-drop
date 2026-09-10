//
//  SettingsView.swift
//  mSign-style settings: sectioned rows (icon tile · title · subtitle · open
//  glyph). Tapping a row pushes a dedicated screen. Rows have a fixed height
//  so the list stays compact and never fights the keyboard.
//

import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Root list

private enum Screen: Identifiable, Hashable {
    case about, repo, token
    case dylibTemplate, ipaTemplate
    case certificates, otaDomain, certInspector, transparency
    case tutorials
    var id: String {
        switch self {
        case .about: return "about"; case .repo: return "repo"; case .token: return "token"
        case .dylibTemplate: return "tpl-dylib"; case .ipaTemplate: return "tpl-ipa"
        case .certificates: return "certs"; case .otaDomain: return "ota"; case .certInspector: return "inspect"; case .transparency: return "transparency"
        case .tutorials: return "tutorials"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var config: Config
    @EnvironmentObject var session: Session
    @ObservedObject private var certs = CertificateStore.shared
    @State private var screen: Screen?

    var body: some View {
        ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {

                        SettingsSection("General", trailing: "\(Theme.appName.uppercased()) \(Theme.appVersion)") {
                            SettingsRow(icon: "info.circle.fill", title: "About", subtitle: "App information and version") { screen = .about }
                        }

                        SettingsSection("GitHub") {
                            SettingsRow(icon: "tray.and.arrow.down.fill", title: "Import zip",
                                        subtitle: "Extract a zip into the workspace") { GitHubHub.shared.open(0) }
                            SettingsRow(icon: "folder.fill", title: "Contents",
                                        subtitle: session.root == nil ? "Workspace is empty" : "\(session.fileCount) files · \(session.archiveName ?? "")") { GitHubHub.shared.open(1) }
                            SettingsRow(icon: "arrow.up.circle.fill", title: "Push",
                                        subtitle: "Commit the workspace to \(config.owner.isEmpty ? "a repo" : "\(config.owner)/\(config.repo)")") { GitHubHub.shared.open(2) }
                            SettingsRow(icon: "hammer.fill", title: "Build",
                                        subtitle: "Actions runs, steps, artifacts") { GitHubHub.shared.open(3) }
                        }

                        SettingsSection("Target") {
                            SettingsRow(icon: "point.3.connected.trianglepath.dotted",
                                        title: "Repository",
                                        subtitle: repoSubtitle) { screen = .repo }
                        }

                        SettingsSection("Security") {
                            SettingsRow(icon: "key.fill",
                                        title: "Access token",
                                        subtitle: config.hasToken ? "GitHub PAT stored in Keychain" : "No token set") { screen = .token }
                        }

                        SettingsSection("Signing") {
                            SettingsRow(icon: "checkmark.seal.fill", title: "Certificates",
                                        subtitle: certs.active?.name ?? "No signing certificate") { screen = .certificates }
                            SettingsRow(icon: "network", title: "On-Device OTA Domain",
                                        subtitle: "\(ServerConfig.installHost) · certbot via Actions") { screen = .otaDomain }
                        }

                        SettingsSection("Transparency") {
                            SettingsRow(icon: "doc.text.magnifyingglass", title: "Certificate inspector",
                                        subtitle: "Every cert the app can serve, field by field") { screen = .certInspector }
                            SettingsRow(icon: "eye.trianglebadge.exclamationmark", title: "What leaves this device",
                                        subtitle: "Endpoints, what's sent, and live self-checks") { screen = .transparency }
                        }

                        SettingsSection("Templates") {
                            SettingsRow(icon: "puzzlepiece.extension.fill", title: "Dylib project",
                                        subtitle: "Theos · runtime swizzle · Actions build") { screen = .dylibTemplate }
                            SettingsRow(icon: "app.badge.fill", title: "IPA app project",
                                        subtitle: "SwiftUI · XcodeGen · unsigned Actions build") { screen = .ipaTemplate }
                        }

                        SettingsSection("Learn") {
                            SettingsRow(icon: "book.fill", title: "Tutorials",
                                        subtitle: "\(TutorialLibrary.all.count) guides · phone-only workflow, FLEX, hooking, certs") { screen = .tutorials }
                        }

                        SettingsSection("Support") {
                            SettingsLink(icon: "globe", title: "MRzefV", subtitle: "mrzefv.com | Founder MRzefv",
                                         url: URL(string: "https://mrzefv.com")!)
                            SettingsLink(icon: "chevron.left.forwardslash.chevron.right", title: "GitHub",
                                         subtitle: "github.com/mrzefv",
                                         url: URL(string: "https://github.com/mrzefv")!)
                        }

                        StatusFooter()
                            .padding(.top, 26)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 20)
            }
        }
        .fullScreenCover(item: $screen) { s in
            Group {
                switch s {
                case .about: AboutScreen()
                case .repo:  RepoScreen()
                case .token: TokenScreen()
                case .certificates:  CertificatesScreen()
                case .otaDomain:     OTADomainScreen()
                case .certInspector: CertInspectorScreen()
                case .transparency:  TransparencyScreen()
                case .dylibTemplate: DylibTemplateScreen()
                case .ipaTemplate:   IPATemplateScreen()
                case .tutorials: TutorialsListScreen()
                }
            }
            .environmentObject(config)
            .environmentObject(session)
            .preferredColorScheme(.dark)
        }
    }

    private var repoSubtitle: String {
        guard !config.owner.isEmpty, !config.repo.isEmpty else { return "Set owner, repo and branch" }
        return "\(config.owner)/\(config.repo) @ \(config.branch.isEmpty ? "main" : config.branch)"
    }
}

// MARK: - Section

private struct SettingsSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.trailing = trailing; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold)).kerning(1.1)
                    .foregroundStyle(Theme.subtle)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.subtle.opacity(0.8))
                }
            }
            .padding(.top, 18).padding(.bottom, 6)

            VStack(spacing: 0) { content }
        }
    }
}

// MARK: - Rows

private let rowHeight: CGFloat = 64

private struct RowBody: View {
    let icon: String
    let title: String
    let subtitle: String
    var trailingIcon: String = "arrow.up.forward.square"

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.subtle).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: trailingIcon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 0.5).padding(.leading, 52)
        }
    }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RowBody(icon: icon, title: title, subtitle: subtitle)
        }
        .buttonStyle(RowPressStyle())
    }
}

private struct SettingsLink: View {
    let icon: String
    let title: String
    let subtitle: String
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(url) } label: {
            RowBody(icon: icon, title: title, subtitle: subtitle, trailingIcon: "safari")
        }
        .buttonStyle(RowPressStyle())
    }
}

private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.05) : .clear)
    }
}

// MARK: - Footer (mSign-style identity + status pill)

private struct StatusFooter: View {
    @EnvironmentObject var config: Config

    private var ready: Bool { config.hasToken && !config.owner.isEmpty && !config.repo.isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                Text(config.owner.isEmpty ? "MRzefv" : config.owner)
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                Text(ready ? "READY" : "SETUP")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced)).kerning(1)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background((ready ? Color.green : Color.orange).opacity(0.18))
                    .foregroundStyle(ready ? Color.green : Color.orange)
                    .overlay(Capsule().stroke((ready ? Color.green : Color.orange).opacity(0.5), lineWidth: 1))
                    .clipShape(Capsule())
            }
            (Text("TARGET: ")
                .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(Theme.subtle)
            + Text(config.repo.isEmpty ? "—" : "\(config.owner)/\(config.repo)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(Theme.accent))
            Text(Theme.owner).font(.footnote).foregroundStyle(Theme.subtle).padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Detail screen shell

private struct DetailScreen<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                    Text("UNZIP DROP")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .kerning(1).foregroundStyle(Theme.text)
                    Spacer()
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 140)
                    .lineLimit(1)
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34)
                            .background(Theme.accent.opacity(0.14))
                            .clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.bg)
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) { content }
                    .padding(16)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct Field: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var secure = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(Theme.subtle)
            Group {
                if secure { SecureField(placeholder, text: $text) }
                else { TextField(placeholder, text: $text) }
            }
            .keyboardType(keyboard)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .padding(12).background(Theme.bg).foregroundStyle(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
        }
    }
}

// MARK: - About

private struct AboutScreen: View {
    var body: some View {
        DetailScreen(title: "About") {
            Card {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent)
                        Image(systemName: "archivebox.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(.black)
                    }
                    .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Theme.appName).font(.title3.bold()).foregroundStyle(Theme.text)
                        Text("Version \(Theme.appVersion)").font(.caption).foregroundStyle(Theme.subtle)
                        Text("by MRzefv").font(.caption).foregroundStyle(Theme.accent)
                    }
                    Spacer()
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What it does").font(.headline).foregroundStyle(Theme.text)
                    Text("Drop a zip, extract it on-device, then push the files straight into a GitHub repo as a single commit. Built for working from an iPhone without a Mac.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Privacy").font(.headline).foregroundStyle(Theme.text)
                    Text("Nothing leaves the device except pushes to api.github.com using your own token. No analytics, no accounts.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                }
            }
        }
    }
}

// MARK: - Repository

private struct RepoScreen: View {
    @EnvironmentObject var config: Config
    @State private var checking = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        DetailScreen(title: "Repository") {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Target repo", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline).foregroundStyle(Theme.text)
                    Field(label: "Owner", text: config.cleaned(\.owner), placeholder: "mrzefv")
                    Field(label: "Repo", text: config.cleaned(\.repo), placeholder: "my-repo")
                    Field(label: "Branch", text: config.cleaned(\.branch), placeholder: "main")
                    Field(label: "Subpath (optional)", text: config.cleaned(\.subpath), placeholder: "e.g. incoming")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.headline).foregroundStyle(Theme.text)
                    Text("Checks the repo and branch are reachable with the saved token.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    Button { Task { await check() } } label: {
                        HStack {
                            if checking { ProgressView().tint(.black) }
                            else { Image(systemName: "checkmark.shield.fill") }
                            Text(checking ? "Checking…" : "Test connection").fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 12).padding(.horizontal, 14)
                        .background(canCheck ? Theme.accent : Theme.subtle)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!canCheck || checking)
                    if let result {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(ok ? .green : .red)
                            Text(result).font(.caption).foregroundStyle(Theme.text)
                        }
                    }
                }
            }
        }
    }

    private var canCheck: Bool { config.hasToken && !config.owner.isEmpty && !config.repo.isEmpty }

    private func check() async {
        checking = true; result = nil
        let client = GitHubClient(owner: config.owner, repo: config.repo,
                                  branch: config.branch.isEmpty ? "main" : config.branch, token: config.token)
        do {
            let v = try await client.verify()
            ok = true
            result = "\(v.fullName) · branch \(v.branch) · \(v.permission)"
        } catch {
            ok = false
            result = error.localizedDescription
        }
        checking = false
    }
}

// MARK: - Token

private struct TokenScreen: View {
    @EnvironmentObject var config: Config
    @State private var show = false

    var body: some View {
        DetailScreen(title: "Access token") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("GitHub PAT", systemImage: "key.fill").font(.headline).foregroundStyle(Theme.text)
                    Text("Fine-grained or classic PAT with Contents: read & write on the target repo. Stored in the Keychain, never leaves the device except to api.github.com.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    HStack(spacing: 10) {
                        Field(label: "Token", text: config.cleaned(\.token), placeholder: "github_pat_… / ghp_…", secure: !show)
                        Button { show.toggle() } label: {
                            Image(systemName: show ? "eye.slash" : "eye")
                                .font(.system(size: 17)).foregroundStyle(Theme.subtle)
                                .frame(width: 40, height: 40)
                        }
                        .padding(.top, 18)
                    }
                    if config.hasToken {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("Saved · \(config.token.prefix(11))…")
                                .font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                        }
                        Button(role: .destructive) { config.token = "" } label: {
                            Label("Clear token", systemImage: "trash").font(.caption)
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Required scope").font(.headline).foregroundStyle(Theme.text)
                    Text("Fine-grained: Repository permissions → Contents: Read and write, Actions: Read and write (Build tab), Workflows: Read and write (if the drop has .github/workflows).\nClassic: repo + workflow.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    Link("Create a token on GitHub", destination: URL(string: "https://github.com/settings/tokens")!)
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}


// MARK: - Templates

private struct DylibTemplateScreen: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var name = "MRvEKTweak"
    @State private var target = ""
    @State private var author = "MRzefv"

    var body: some View {
        DetailScreen(title: "Dylib project") {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Theos dylib, no Substrate", systemImage: "puzzlepiece.extension.fill")
                        .font(.headline).foregroundStyle(Theme.text)
                    Text("Makefile + Tweak.xm with a runtime-swizzle helper and an example overlay hook, bundle-filter plist, control, and a GitHub Actions workflow that installs Theos and uploads the .dylib as an artifact. Works sideloaded via mSign or on a jailbreak.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    Field(label: "Tweak name", text: $name, placeholder: "MRvEKTweak")
                    Field(label: "Target bundle id", text: $target, placeholder: "com.audiomack.iphone")
                    Field(label: "Author handle", text: $author, placeholder: "MRzefv")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files").font(.headline).foregroundStyle(Theme.text)
                    ForEach(["Makefile", "Tweak.xm", "<name>.plist", "control", ".github/workflows/build.yml", "README.md"], id: \.self) {
                        Text("· " + $0).font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                    }
                }
            }
            generate("Generate dylib project") {
                ProjectTemplate.dylib(name: name, target: target, author: author.isEmpty ? "MRzefv" : author)
            }
            Text("Then: Push → Build tab → download <name>-dylib → inject with mSign. See Tutorials for the FLEX walkthrough.")
                .font(.caption2).foregroundStyle(Theme.subtle)
        }
    }

    private func generate(_ title: String, _ make: @escaping () -> [(path: String, content: String)]) -> some View {
        Button {
            session.loadGenerated(name: name.isEmpty ? "MRvEKTweak" : name, files: make())
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } label: {
            HStack { Image(systemName: "wand.and.stars"); Text(title).fontWeight(.semibold); Spacer() }
                .padding(.vertical, 12).padding(.horizontal, 14)
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct IPATemplateScreen: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var name = "MRvEKApp"
    @State private var bundle = ""
    @State private var author = "MRzefv"

    var body: some View {
        DetailScreen(title: "IPA app project") {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("SwiftUI app, unsigned IPA", systemImage: "app.badge.fill")
                        .font(.headline).foregroundStyle(Theme.text)
                    Text("project.yml (XcodeGen) so there's no pbxproj to maintain by hand, a custom-shell RootView with the same header/tab-bar pattern as this app, launch screen set so it's full-screen, and a workflow that generates the project, builds unsigned and uploads <name>.ipa. Sign with mSign to install.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    Field(label: "App name", text: $name, placeholder: "MRvEKApp")
                    Field(label: "Bundle id", text: $bundle, placeholder: "party.mrvek.app")
                    Field(label: "Author handle", text: $author, placeholder: "MRzefv")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files").font(.headline).foregroundStyle(Theme.text)
                    ForEach(["project.yml", "Sources/<name>App.swift", "Sources/Theme.swift", "Sources/RootView.swift", "Assets.xcassets/…", ".github/workflows/build.yml", "README.md"], id: \.self) {
                        Text("· " + $0).font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                    }
                }
            }
            Button {
                session.loadGenerated(name: name.isEmpty ? "MRvEKApp" : name,
                                      files: ProjectTemplate.ipaApp(name: name, bundleID: bundle, author: author.isEmpty ? "MRzefv" : author))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } label: {
                HStack { Image(systemName: "wand.and.stars"); Text("Generate IPA project").fontWeight(.semibold); Spacer() }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(Theme.accent).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text("Then: Push → Build tab → download <name>-ipa → sign in mSign.")
                .font(.caption2).foregroundStyle(Theme.subtle)
        }
    }
}


// MARK: - OTA domain (VPS-renewed zefv.dev cert · own TLS cert · fully local CA)

private struct OTADomainScreen: View {
    @EnvironmentObject var config: Config
    @State private var domain = ServerConfig.certDomain
    @State private var host = ServerConfig.installHost
    @State private var saved = false
    @State private var mode = ServerConfig.certMode
    @State private var dnsLoopback: Bool?
    @State private var dnsChecking = false
    @State private var sans = ZefvCert.effectiveSANs
    @State private var showLocalCA = false

    // Public (VPS) cert
    @State private var refreshing = false
    @State private var expires = ZefvCert.effectiveNotAfter
    @State private var cached = ZefvCert.hasCached
    @State private var fetchedAt = ZefvCert.meta?.fetchedAt
    @State private var sourceURL = ServerConfig.certSourceURL
    @State private var sourceToken = ServerConfig.certSourceToken
    @State private var sourceSaved = false
    @State private var error: String?
    @State private var note: String?

    // Own cert
    @State private var showCertPicker = false
    @State private var hasCustom = ZefvCert.hasCustom
    @State private var customSANs = ZefvCert.customSANs
    @State private var customExpires = ZefvCert.customNotAfter

    // Local CA trust
    @State private var rootTrusted = LocalCAManager.isRootTrusted()

    private var clean: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private var cleanDomain: String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "*.", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/."))
    }
    private var domainOK: Bool { cleanDomain.contains(".") && !cleanDomain.contains(" ") }
    private var hostOK: Bool { domainOK && (clean.lowercased().hasSuffix("." + cleanDomain) || clean.lowercased() == cleanDomain) }
    private var liveSANs: [String] {
        switch mode { case "local": return LocalCAManager.leafSANs(); case "custom": return customSANs; default: return sans }
    }
    private var certCoversHost: Bool {
        let h = clean.isEmpty ? "mr.\(cleanDomain)" : clean
        return mode == "local" ? LocalCAManager.covers(h) : ZefvCert.covers(h, sans: liveSANs)
    }

    var body: some View {
        DetailScreen(title: "On-Device OTA Domain") {
            modeCard
            activeCertCard
            hostCard
            switch mode {
            case "local":  localModeCard
            case "custom": customCertCard
            default:       vpsCertCard
            }
        }
        .fullScreenCover(isPresented: $showLocalCA) { LocalCAScreen().environmentObject(config).preferredColorScheme(.dark) }
        .sheet(isPresented: $showCertPicker) {
            DocPicker(types: [.item]) { urls in
                guard !urls.isEmpty else { return }
                do {
                    try ZefvCert.importCustom(files: urls)
                    error = nil; note = "Imported \(urls.count) file\(urls.count == 1 ? "" : "s")."
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch { self.error = error.localizedDescription }
                reload()
            }
        }
        .onChange(of: host) { _ in saved = false }
        .onChange(of: domain) { _ in saved = false; dnsLoopback = nil }
        .onChange(of: sourceURL) { _ in sourceSaved = false }
        .onChange(of: sourceToken) { _ in sourceSaved = false }
        .onAppear { reload(); Task { await checkLoopback() } }
        // Re-check trust every time the app comes back — the user installs the
        // profile in Settings.app and returns here.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            rootTrusted = LocalCAManager.isRootTrusted()
        }
    }

    // MARK: Cards

    private var modeCard: some View {
        let modes: [(key: String, name: String, icon: String)] = [
            ("public", "zefv.dev", "globe"),
            ("custom", "Own cert", "doc.badge.plus"),
            ("local",  "Local CA", "iphone"),
        ]
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Certificate mode", systemImage: "lock.rotation").font(.headline).foregroundStyle(Theme.text)
                HStack(spacing: 8) {
                    ForEach(modes, id: \.key) { m in
                        Button {
                            mode = m.key; ServerConfig.setCertMode(m.key)
                            if m.key == "public", cleanDomain != ServerConfig.defaultDomain || cleanDomain.isEmpty {
                                // zefv.dev mode implies the zefv.dev domain.
                                domain = ServerConfig.defaultDomain
                                if !hostOK { host = "mr.\(ServerConfig.defaultDomain)" }
                                ServerConfig.setCertDomain(domain); ServerConfig.setInstallHost(host); saved = true
                            }
                            reload()
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: m.icon).font(.system(size: 16))
                                Text(m.name).font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.vertical, 12).frame(maxWidth: .infinity)
                            .background(mode == m.key ? Theme.accent.opacity(0.18) : Theme.card)
                            .foregroundStyle(mode == m.key ? Theme.accent : Theme.subtle)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(mode == m.key ? Theme.accent : Theme.stroke, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(mode == "public"
                     ? "Real Let's Encrypt wildcard for *.zefv.dev, renewed automatically on the VPS (certbot + Cloudflare DNS-01) and pulled here. Trusted by iOS out of the box — nothing to install, nothing to renew."
                     : mode == "custom"
                     ? "Your own TLS cert for your own domain. Import the fullchain + private key (PEM). Point *.<your domain> at 127.0.0.1 and iOS trusts it like any public cert."
                     : "Your own root CA — no DNS, no external CA, instant and offline. iOS trusts it only after you install the root profile once (you can inspect it first).")
                    .font(.caption).foregroundStyle(Theme.subtle)
            }
        }
    }

    private var activeCertCard: some View {
        let hostOKNow = mode == "local" ? LocalCAManager.covers(host) : ZefvCert.covers(host, sans: liveSANs)
        let have = mode == "local" ? LocalCAManager.hasLeaf : (mode == "custom" ? hasCustom : ZefvCert.isAvailable)
        let ready = have && hostOKNow && (mode != "local" || rootTrusted)
        let exp: Date? = mode == "local" ? LocalCAManager.leafExpiry : (mode == "custom" ? customExpires : expires)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Active cert", systemImage: mode == "local" ? "iphone" : (mode == "custom" ? "doc.badge.plus" : "globe")).font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    Text(ready ? "READY" : (have ? (hostOKNow ? "NOT TRUSTED" : "MISMATCH") : "MISSING"))
                        .font(.system(size: 10, weight: .heavy, design: .monospaced)).kerning(0.5)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((ready ? Color.green : Color.orange).opacity(0.18))
                        .foregroundStyle(ready ? .green : .orange).clipShape(Capsule())
                }
                kvRow("Mode", mode == "local" ? "Fully local (root CA)" : (mode == "custom" ? "Own TLS cert" : "zefv.dev (VPS · auto-renew)"))
                kvRow("Install host", host)
                kvRow("Cert covers", liveSANs.isEmpty ? "—" : liveSANs.joined(separator: ", "))
                kvRow("Expires", exp.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                if mode == "local" {
                    HStack(spacing: 6) {
                        Image(systemName: rootTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(rootTrusted ? .green : .orange)
                        Text(rootTrusted ? "Root CA is installed and trusted on this device."
                                         : "Root CA is NOT trusted on this device yet — install the profile, then enable it in Settings › General › About › Certificate Trust Settings.")
                            .font(.caption2).foregroundStyle(rootTrusted ? .green : .orange)
                    }
                }
                if have && !hostOKNow {
                    Text(mode == "local"
                         ? "Issue a leaf for \(host) in Local CA settings — instant, the root you trusted covers any host it signs."
                         : mode == "custom"
                         ? "The imported cert doesn't cover \(host). Import a cert for *.\(cleanDomain) or change the install host."
                         : "Pull latest so the zefv.dev cert covers \(host).")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private func kvRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(Theme.subtle)
            Spacer()
            Text(v).font(.caption.monospaced()).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
        }
    }

    private var hostCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Domain & install host", systemImage: "network").font(.headline).foregroundStyle(Theme.text)
                Text(mode == "public"
                     ? "Installs run over an on-device Vapor HTTPS server. *.zefv.dev already points at 127.0.0.1 — just pick any label under it as your install host."
                     : "Installs run over an on-device Vapor HTTPS server. Point `*.<domain>` (A record) at 127.0.0.1 — iOS silently drops the install prompt if the host doesn't resolve to loopback.")
                    .font(.caption).foregroundStyle(Theme.subtle)
                if mode != "public" {
                    Field(label: "Domain", text: $domain, placeholder: "example.com", keyboard: .URL)
                }
                Field(label: "Install host", text: $host, placeholder: "mr.\(cleanDomain.isEmpty ? ServerConfig.defaultDomain : cleanDomain)", keyboard: .URL)
                if !domainOK { Text("Enter a domain like example.com").font(.caption).foregroundStyle(.orange) }
                else if !hostOK { Text("Host must be under \(cleanDomain).").font(.caption).foregroundStyle(.orange) }
                else if !certCoversHost, !liveSANs.isEmpty {
                    Text("Cert covers \(liveSANs.joined(separator: ", ")) — not \(clean).").font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Image(systemName: dnsChecking ? "hourglass" : (dnsLoopback == true ? "checkmark.circle.fill" : (dnsLoopback == false ? "xmark.octagon.fill" : "questionmark.circle")))
                        .foregroundStyle(dnsLoopback == true ? .green : (dnsLoopback == false ? .red : Theme.subtle))
                    Text(dnsChecking ? "Resolving *.\(cleanDomain)…"
                         : dnsLoopback == true ? "*.\(cleanDomain) → 127.0.0.1 ✓"
                         : dnsLoopback == false ? "*.\(cleanDomain) does not resolve to 127.0.0.1 — add a wildcard A record"
                         : "DNS not checked")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    Spacer()
                    Button { Task { await checkLoopback() } } label: { Text("Check").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent) }
                        .disabled(!domainOK || dnsChecking)
                }
                accentButton(saved ? "Saved" : "Save", saved ? "checkmark.circle.fill" : "network", enabled: hostOK) {
                    ServerConfig.setCertDomain(cleanDomain)
                    ServerConfig.setInstallHost(clean.isEmpty ? "mr.\(cleanDomain)" : clean)
                    domain = ServerConfig.certDomain; host = ServerConfig.installHost; saved = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    Task { await checkLoopback() }
                }
            }
        }
    }

    private var vpsCertCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("zefv.dev certificate", systemImage: "arrow.triangle.2.circlepath.circle").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    statusPill(expires)
                }
                kv("In use", cached ? "Pulled from VPS" : "Bundled in IPA")
                kv("Covers", sans.isEmpty ? "—" : sans.joined(separator: ", "))
                kv("Expires", expires.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                kv("Last pull", fetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never")
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                if let note { Text(note).font(.caption).foregroundStyle(.green) }
                HStack(spacing: 10) {
                    accentButton(refreshing ? "Fetching…" : "Pull latest from VPS", "arrow.down.circle", busy: refreshing) { Task { await refresh() } }
                    if cached {
                        Button { ZefvCert.clearCache(); reload() } label: {
                            Image(systemName: "trash").frame(width: 46, height: 46)
                                .background(Theme.card).foregroundStyle(.orange)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                Text("certbot on the VPS renews *.zefv.dev via the Cloudflare DNS API and drops the new pair at the source below. The app auto-pulls on install when within \(ServerConfig.refreshBufferDays) days of expiry — Pull latest just forces it now.")
                    .font(.caption2).foregroundStyle(Theme.subtle)
                Divider().overlay(Theme.stroke)
                Text("Cert source").font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                Field(label: "URL", text: $sourceURL, placeholder: ServerConfig.defaultCertSourceURL, keyboard: .URL)
                Field(label: "Token (X-OTA-Token)", text: $sourceToken, placeholder: ServerConfig.defaultCertSourceToken, keyboard: .asciiCapable)
                accentButton(sourceSaved ? "Saved" : "Save source", sourceSaved ? "checkmark.circle.fill" : "server.rack") {
                    ServerConfig.setCertSourceURL(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines))
                    ServerConfig.setCertSourceToken(sourceToken.trimmingCharacters(in: .whitespacesAndNewlines))
                    sourceURL = ServerConfig.certSourceURL; sourceToken = ServerConfig.certSourceToken; sourceSaved = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        }
    }

    private var customCertCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Own TLS certificate", systemImage: "doc.badge.plus").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    if hasCustom { statusPill(customExpires) }
                }
                Text("Bring the cert you already have for your domain — Let's Encrypt, ZeroSSL, Cloudflare Origin, anything iOS trusts. Pick the fullchain (.pem/.crt) and the private key (.pem/.key), or one combined PEM. The key must be unencrypted PEM; it stays on this device.")
                    .font(.caption).foregroundStyle(Theme.subtle)
                if hasCustom {
                    kv("Covers", customSANs.isEmpty ? "—" : customSANs.joined(separator: ", "))
                    kv("Expires", customExpires.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    if !ZefvCert.covers(host, sans: customSANs) {
                        Text("This cert doesn't cover \(host). Set the install host to a name it covers (wildcard *.\(cleanDomain) covers any single label).")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text("No cert imported yet.").font(.caption).foregroundStyle(.orange)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                if let note { Text(note).font(.caption).foregroundStyle(.green) }
                HStack(spacing: 10) {
                    accentButton(hasCustom ? "Replace cert + key" : "Import cert + key", "square.and.arrow.down") { error = nil; note = nil; showCertPicker = true }
                    if hasCustom {
                        Button { ZefvCert.clearCustom(); reload() } label: {
                            Image(systemName: "trash").frame(width: 46, height: 46)
                                .background(Theme.card).foregroundStyle(.orange)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                Text("Nothing renews automatically in this mode — when the cert expires, import the renewed pair.")
                    .font(.caption2).foregroundStyle(Theme.subtle)
            }
        }
    }

    private var localModeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Fully local CA", systemImage: "iphone").font(.headline).foregroundStyle(Theme.text)
                Text(LocalCAManager.hasRoot
                     ? "Root CA ready. Leaf for \(LocalCAManager.meta?.host ?? ServerConfig.installHost): \(LocalCAManager.hasLeaf ? "issued" : "not issued")."
                     : "No local root yet.")
                    .font(.caption).foregroundStyle(Theme.subtle)
                HStack(spacing: 6) {
                    Image(systemName: rootTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(rootTrusted ? .green : .orange)
                    Text(rootTrusted ? "Root profile installed & trusted" : "Root profile not trusted on this device")
                        .font(.caption.weight(.semibold)).foregroundStyle(rootTrusted ? .green : .orange)
                    Spacer()
                    Button { rootTrusted = LocalCAManager.isRootTrusted() } label: { Text("Re-check").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent) }
                }
                accentButton("Open local CA settings", "chevron.right") { showLocalCA = true }
            }
        }
    }

    // MARK: Helpers

    private func accentButton(_ title: String, _ icon: String, enabled: Bool = true, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if busy { ProgressView().tint(.black) } else { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
                Spacer()
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(enabled ? Theme.accent : Theme.subtle).foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!enabled || busy)
    }

    private func statusPill(_ exp: Date?) -> some View {
        let days = exp.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 } ?? -1
        let color: Color = exp == nil ? .orange : (days < 0 ? .red : (days < ServerConfig.refreshBufferDays ? .orange : .green))
        let text = exp == nil ? "MISSING" : (days < 0 ? "EXPIRED" : (days < ServerConfig.refreshBufferDays ? "\(days)D LEFT" : "READY"))
        return Text(text).font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(Theme.subtle)
            Spacer()
            Text(v).font(.caption.monospaced()).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
        }
    }

    private func reload() {
        expires = ZefvCert.effectiveNotAfter; cached = ZefvCert.hasCached; fetchedAt = ZefvCert.meta?.fetchedAt
        sans = mode == "custom" ? ZefvCert.customSANs : ZefvCert.effectiveSANs
        hasCustom = ZefvCert.hasCustom; customSANs = ZefvCert.customSANs; customExpires = ZefvCert.customNotAfter
        rootTrusted = LocalCAManager.isRootTrusted()
    }

    private func checkLoopback() async {
        guard domainOK else { return }
        dnsChecking = true
        dnsLoopback = await ZefvCert.resolvesToLoopback("ota-probe.\(cleanDomain)")
        dnsChecking = false
    }

    private func refresh() async {
        refreshing = true; error = nil; note = nil
        do {
            _ = try await ZefvCert.fetch(); reload()
            note = "Pulled from \(URL(string: ServerConfig.certSourceURL)?.host ?? "VPS")"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = error.localizedDescription }
        refreshing = false
    }
}

private struct LocalCAScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = ServerConfig.installHost
    @State private var working = false
    @State private var error: String?
    @State private var note: String?
    @State private var showProfileText = false
    @State private var share: URLItem?
    @State private var refresh = 0            // bump to re-read files
    @State private var dnsLoopback: Bool?
    @State private var dnsChecking = false

    private var hasRoot: Bool { _ = refresh; return LocalCAManager.hasRoot }
    private var hasLeaf: Bool { _ = refresh; return LocalCAManager.hasLeaf }
    private var meta: LocalCAManager.Meta? { _ = refresh; return LocalCAManager.meta }

    var body: some View {
        DetailScreen(title: "Local CA") {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Fully local OTA certificate", systemImage: "iphone.and.arrow.forward").font(.headline).foregroundStyle(Theme.text)
                    Text("Generates a root CA on this device (OpenSSL), signs a leaf for your OTA host, and serves installs with it. No DNS, no external CA, works offline. Private keys never touch disk in the clear — they're stored in the Keychain with ThisDeviceOnly protection, excluded from backups. iOS trusts it only after you install the root profile below — inspect it first; nothing is signed by anyone but your device.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Host", systemImage: "network").font(.headline).foregroundStyle(Theme.text)
                    Field(label: "OTA host", text: $host, placeholder: "mr.zefv.dev")
                    Text("The leaf covers this host and *.<host>. This is separate from trust: the host must ALSO resolve to 127.0.0.1 via a real DNS A record (or use a free *.nip.io / *.sslip.io name, e.g. 127-0-0-1.nip.io) — iOS silently drops the install prompt if it doesn't, with no error.")
                        .font(.caption2).foregroundStyle(Theme.subtle)
                    HStack(spacing: 8) {
                        Image(systemName: dnsChecking ? "hourglass" : (dnsLoopback == true ? "checkmark.circle.fill" : (dnsLoopback == false ? "xmark.octagon.fill" : "questionmark.circle")))
                            .foregroundStyle(dnsLoopback == true ? .green : (dnsLoopback == false ? .red : Theme.subtle))
                        Text(dnsChecking ? "Resolving \(host)…"
                             : dnsLoopback == true ? "\(host) → 127.0.0.1 ✓"
                             : dnsLoopback == false ? "\(host) does NOT resolve to 127.0.0.1 — install sheet will not appear"
                             : "DNS not checked yet")
                            .font(.caption).foregroundStyle(Theme.subtle)
                        Spacer()
                        Button { Task { await checkDNS() } } label: { Text("Check").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent) }
                    }
                    accentButton(working ? "Working…" : (hasLeaf ? "Re-issue leaf for host" : "Create CA & issue leaf"), "checkmark.seal.fill", busy: working) {
                        Task { await issue() }
                    }
                }
            }

            if let error { Card { Text(error).font(.caption).foregroundStyle(.orange) } }
            if let note { Card { Text(note).font(.caption).foregroundStyle(.green) } }

            if hasRoot { rootCard }
            if hasRoot { profileCard }

            if hasRoot {
                Card {
                    Button(role: .destructive) { LocalCAManager.reset(); bump(); note = "Local CA deleted." } label: {
                        Label("Delete local CA", systemImage: "trash").font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
        .sheet(isPresented: $showProfileText) { ProfileInspector(text: profileXML) }
        .task { await checkDNS() }
    }

    // MARK: Root details

    private var rootCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Root CA", systemImage: "checkmark.shield.fill").font(.headline).foregroundStyle(Theme.text)
                kv("Subject", "MRvEK Local Root CA")
                kv("Fingerprint", fingerprint)
                if let m = meta {
                    kv("Created", m.rootCreated.formatted(date: .abbreviated, time: .shortened))
                    kv("Leaf host", m.host)
                    kv("Leaf issued", m.leafIssued.formatted(date: .abbreviated, time: .shortened))
                }
                kv("Key usage", "CA · certificate signing only")
                kv("Private key storage", "Keychain · ThisDeviceOnly (never backed up)")
            }
        }
    }

    // MARK: Profile (inspect + install)

    private var profileCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Trust profile", systemImage: "doc.badge.gearshape").font(.headline).foregroundStyle(Theme.text)
                Text("This .mobileconfig contains one payload: the root cert above, as a com.apple.security.root (trusted root) payload. It is NOT signed by Apple or anyone else — it's plain text you can read in full. After installing, enable it in Settings › General › About › Certificate Trust Settings.")
                    .font(.caption).foregroundStyle(Theme.subtle)
                HStack(spacing: 10) {
                    accentButton("View profile contents", "doc.text.magnifyingglass") { showProfileText = true }
                }
                Button {
                    if let u = LocalCAManager.writeMobileConfig() { share = URLItem(url: u) }
                    else { error = "Couldn't build the profile." }
                } label: {
                    HStack { Image(systemName: "square.and.arrow.down"); Text("Install profile").fontWeight(.semibold); Spacer() }
                        .padding(.vertical, 12).padding(.horizontal, 14)
                        .background(Theme.accent).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text("Opening the profile takes you to Settings to review and install it. You confirm every step; iOS shows a red 'Unmanaged Root Certificate' warning because it grants trust — that's expected for a root you made.")
                    .font(.caption2).foregroundStyle(Theme.subtle)
            }
        }
    }

    // MARK: helpers

    private var profileXML: String {
        (LocalCAManager.mobileConfig()).flatMap { String(data: $0, encoding: .utf8) } ?? "(no profile — create the CA first)"
    }

    private var fingerprint: String {
        guard let der = LocalCAManager.rootDER() else { return "—" }
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private func kv(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(Theme.subtle)
            Text(v).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                .lineLimit(3).textSelection(.enabled)
        }
    }

    private func accentButton(_ title: String, _ icon: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { if busy { ProgressView().tint(.black) } else { Image(systemName: icon) }; Text(title).fontWeight(.semibold); Spacer() }
                .padding(.vertical, 12).padding(.horizontal, 14)
                .background(Theme.accent).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 12))
        }.disabled(busy)
    }

    private func bump() { refresh += 1 }

    private func checkDNS() async {
        dnsChecking = true
        let h = Config.clean(host).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "*.", with: "")
        dnsLoopback = await ZefvCert.resolvesToLoopback(h)
        dnsChecking = false
    }

    private func issue() async {
        working = true; error = nil; note = nil
        let h = Config.clean(host).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "*.", with: "")
        guard h.contains(".") else { error = "Enter a host like mr.zefv.dev"; working = false; return }
        do {
            try LocalCAManager.issueLeaf(host: h)
            ServerConfig.setInstallHost(h)
            ServerConfig.setCertMode("local")
            bump()
            await checkDNS()
            if dnsLoopback == false {
                note = "Root + leaf ready for \(h) — but that host does NOT resolve to 127.0.0.1, so the install sheet won't appear. Point an A record at 127.0.0.1, or use a free name like 127-0-0-1.nip.io."
            } else {
                note = "Root + leaf ready for \(h). Cert mode set to local. Install the profile, then Sign & Install."
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = error.localizedDescription }
        working = false
    }
}

// Plain-text profile viewer.
private struct ProfileInspector: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(".mobileconfig").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Certificate inspector (public vs local, same fields)

private struct CertInspectorScreen: View {
    @State private var publicChain: [CertFacts] = []
    @State private var localLeaf: [CertFacts] = []
    @State private var localRoot: [CertFacts] = []

    var body: some View {
        DetailScreen(title: "Certificate inspector") {
            Card {
                Text("Same parser, same fields, for every certificate this app can present to iOS. Compare what a public CA issued against what this phone issued. Active mode: \(ServerConfig.certMode == "local" ? "Fully local" : (ServerConfig.certMode == "custom" ? "Own TLS cert" : "zefv.dev (VPS)")).")
                    .font(.caption).foregroundStyle(Theme.subtle)
            }
            chainSection("PUBLIC (ACME) CERT", publicChain, empty: "No public cert loaded.")
            chainSection("LOCAL CA — LEAF", localLeaf, empty: "No local leaf issued.")
            chainSection("LOCAL CA — ROOT", localRoot, empty: "No local root created.")
        }
        .onAppear(perform: load)
    }

    private func load() {
        if let u = ZefvCert.crtURL { publicChain = CertInspector.inspect(fileURL: u) }
        localLeaf = CertInspector.inspect(fileURL: LocalCAManager.leafCertURL)
        localRoot = CertInspector.inspect(fileURL: LocalCAManager.rootCertURL)
    }

    @ViewBuilder
    private func chainSection(_ title: String, _ chain: [CertFacts], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
            if chain.isEmpty {
                Card { Text(empty).font(.caption).foregroundStyle(Theme.subtle) }
            } else {
                ForEach(chain) { certCard($0) }
            }
        }
    }

    private func certCard(_ c: CertFacts) -> some View {
        let days = c.daysLeft ?? -1
        let color: Color = days < 0 ? .red : (days < 21 ? .orange : .green)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(c.label).font(.headline).foregroundStyle(Theme.text)
                    if c.isCA { tag("CA", Theme.accent) }
                    if c.selfSigned { tag("SELF-SIGNED", .orange) }
                    Spacer()
                    tag(days < 0 ? "EXPIRED" : "\(days)D LEFT", color)
                }
                row("Subject", c.subjectCN + (c.subjectO.isEmpty ? "" : " · \(c.subjectO)"))
                row("Issuer", c.issuerCN + (c.issuerO.isEmpty ? "" : " · \(c.issuerO)"))
                row("Covers", c.sans.isEmpty ? "— (no SANs)" : c.sans.joined(separator: ", "))
                row("Valid", "\(fmt(c.notBefore)) → \(fmt(c.notAfter))")
                row("Key", c.keyType)
                row("Serial", c.serialHex)
                row("SHA-256", c.sha256)
            }
        }
    }

    private func fmt(_ d: Date?) -> String { d?.formatted(date: .abbreviated, time: .omitted) ?? "—" }
    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(0.5)
            .padding(.horizontal, 6).padding(.vertical, 3).background(c.opacity(0.18)).foregroundStyle(c).clipShape(Capsule())
    }
    private func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(Theme.subtle)
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
        }
    }
}

// MARK: - What leaves this device

private struct TransparencyScreen: View {
    @State private var checks: [TransparencyReport.Check] = []
    @State private var running = false

    var body: some View {
        DetailScreen(title: "What leaves this device") {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Self-check", systemImage: "checkmark.shield").font(.headline).foregroundStyle(Theme.text)
                    Text("The app verifies its own privacy claims at runtime instead of asserting them. Run it any time.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    ForEach(checks) { c in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: c.pass ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(c.pass ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                Text(c.detail).font(.caption2).foregroundStyle(Theme.subtle)
                            }
                        }
                    }
                    Button { run() } label: {
                        HStack { if running { ProgressView().tint(.black) } else { Image(systemName: "arrow.clockwise") }; Text("Run self-check").fontWeight(.semibold); Spacer() }
                            .padding(.vertical, 12).padding(.horizontal, 14)
                            .background(Theme.accent).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(running)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("NEVER SENT ANYWHERE").font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(TransparencyReport.neverSent, id: \.self) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.green)
                                Text(line).font(.caption).foregroundStyle(Theme.text)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("EVERY ENDPOINT THIS APP CAN CONTACT").font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
                ForEach(TransparencyReport.endpoints) { e in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(e.host).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
                            Text(e.purpose).font(.subheadline).foregroundStyle(Theme.text)
                            kv("Sends", e.sends)
                            kv("When", e.when)
                        }
                    }
                }
                Text("This list is declared in source (TransparencyReport.endpoints) and shipped with the app — if the app talked to anything not on it, that would be a bug you could diff.")
                    .font(.caption2).foregroundStyle(Theme.subtle)
            }
        }
        .onAppear(perform: run)
    }

    private func run() {
        running = true
        let r = TransparencyReport.selfCheck()
        checks = r
        running = false
    }

    private func kv(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption2.weight(.semibold)).foregroundStyle(Theme.subtle)
            Text(v).font(.caption).foregroundStyle(Theme.text)
        }
    }
}
