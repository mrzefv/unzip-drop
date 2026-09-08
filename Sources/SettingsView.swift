//
//  SettingsView.swift
//  mSign-style settings: sectioned rows (icon tile · title · subtitle · open
//  glyph). Tapping a row pushes a dedicated screen. Rows have a fixed height
//  so the list stays compact and never fights the keyboard.
//

import SwiftUI
import CryptoKit

// MARK: - Root list

private enum Screen: Identifiable, Hashable {
    case about, repo, token
    case dylibTemplate, ipaTemplate
    case certificates, otaDomain, certInspector, transparency
    case tutorials
    case zefvAccount
    var id: String {
        switch self {
        case .about: return "about"; case .repo: return "repo"; case .token: return "token"
        case .dylibTemplate: return "tpl-dylib"; case .ipaTemplate: return "tpl-ipa"
        case .certificates: return "certs"; case .otaDomain: return "ota"; case .certInspector: return "inspect"; case .transparency: return "transparency"
        case .tutorials: return "tutorials"
        case .zefvAccount: return "zefv-account"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var config: Config
    @EnvironmentObject var session: Session
    @ObservedObject private var certs = CertificateStore.shared
    @ObservedObject private var zefv  = ZefvClient.shared
    @State private var screen: Screen?

    var body: some View {
        ZStack {
                Color.clear.ignoresSafeArea()
                VStack(spacing: 0) {
                    AccentTopBar(title: "Settings", subtitle: "\(Theme.appName) \(Theme.appVersion)")
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

                        SettingsSection("zefv.dev Account", trailing: zefv.currentUser?.rank_name.uppercased()) {
                            SettingsRow(icon: "person.crop.circle.badge.checkmark",
                                        title: zefv.currentUser?.username ?? (zefv.isAuthenticated ? "Loading…" : "Sign in or register"),
                                        subtitle: zefvSubtitle) { screen = .zefvAccount }
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
                case .zefvAccount: ZefvAccountScreen()
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

    private var zefvSubtitle: String {
        guard let u = zefv.currentUser else {
            return zefv.isAuthenticated
                ? "Signed in — refresh account"
                : "Publish signed IPAs to your username.zefv.dev subdomain"
        }
        let quota = u.quota_bytes < 0 ? "unlimited" : byteString(u.quota_bytes)
        return "\(u.username).zefv.dev · Level \(u.level) · \(byteString(u.bytes_used)) / \(quota)"
    }

    private func byteString(_ n: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n); var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: v < 10 && i > 0 ? "%.1f %@" : "%.0f %@", v, units[i])
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
        .background(Color.clear.ignoresSafeArea())
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


// MARK: - OTA domain (zefv.dev, hand-rolled certbot pipeline)

private struct OTADomainScreen: View {
    @EnvironmentObject var config: Config
    @State private var domain = ServerConfig.certDomain
    @State private var host = ServerConfig.installHost
    @State private var saved = false
    @State private var mode = ServerConfig.certMode
    @State private var dnsLoopback: Bool?
    @State private var dnsChecking = false
    @State private var sans = ZefvCert.effectiveSANs

    @State private var certOwner = ServerConfig.certRepoOwner
    @State private var certRepo = ServerConfig.certRepoName
    @State private var certBranch = ServerConfig.certBranch
    @State private var sourceSaved = false
    @State private var leEmail = UserDefaults.standard.string(forKey: "uzd_le_email") ?? ""
    @State private var certCA = ServerConfig.certCA
    @State private var eabKID = ServerConfig.eabKID
    @State private var eabHMAC = ServerConfig.eabHMAC
    @State private var linking = false
    @State private var linkReport: String?
    @State private var showLocalCA = false

    @State private var refreshing = false
    @State private var renewing = false
    @State private var expires = ZefvCert.effectiveNotAfter
    @State private var cached = ZefvCert.hasCached
    @State private var fetchedAt = ZefvCert.meta?.fetchedAt
    @State private var error: String?
    @State private var note: String?
    @State private var probe: ZefvCert.BranchProbe?
    @State private var readiness: ZefvCert.DNSReadiness?
    @State private var checkingReady = false
    @State private var proceedAnyway = false
    @State private var lastRun: WorkflowRun?
    @State private var lastJobs: [WorkflowJob] = []
    @State private var runLogTail: String?
    @State private var loadingRun = false

    @State private var board: AcmeBoard?
    @State private var dnsSeen: [String: Bool] = [:]
    @State private var checking = false
    @State private var boardTimer: Timer?
    @State private var copied: String?
    @State private var forcing: String?
    @State private var forceOverride: AcmeChallenge?     // TXT not visible yet — ask before forcing
    @State private var forceVerify: [String: String] = [:] // value → last verification summary

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
    private var certCoversHost: Bool {
        let h = clean.isEmpty ? "mr.\(cleanDomain)" : clean
        return mode == "local" ? LocalCAManager.covers(h) : ZefvCert.covers(h, sans: sans)
    }

    var body: some View {
        DetailScreen(title: "On-Device OTA Domain") {
            modeCard
            activeCertCard
            if mode == "public" { hostCard
            if let board, !board.records.isEmpty || renewing { challengeCard(board) }
            certCard
            dnsReadinessCard
            lastRunCard
            sourceCard
            } else {
                localModeCard
            }
            if mode == "public" { Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How the cert is made").font(.headline).foregroundStyle(Theme.text)
                    Text("`.github/workflows/certs.yml` runs certbot with a manual DNS-01 challenge for *.<your domain>. It publishes each TXT value here, then polls DNS until your record is live before letting Let's Encrypt validate — so no burned attempts or rate limits. Result goes to the `certs` branch; Build.yml bakes it into every IPA.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    Text("No secrets, no computer: Link repo installs everything; Renew now sends your email and domain to the workflow. Weekly cron renews when < 30 days remain if you also set repo variable LE_EMAIL (optional).")
                        .font(.caption2).foregroundStyle(Theme.subtle)
                }
            } }
        }
        .fullScreenCover(isPresented: $showLocalCA) { LocalCAScreen().environmentObject(config).preferredColorScheme(.dark) }
        .alert("TXT record not visible yet", isPresented: Binding(get: { forceOverride != nil }, set: { if !$0 { forceOverride = nil } })) {
            Button("Re-check") { if let r = forceOverride { forceOverride = nil; Task { await force(r) } } }
            Button("Force anyway", role: .destructive) { if let r = forceOverride { forceOverride = nil; Task { await force(r, override: true) } } }
            Button("Cancel", role: .cancel) { forceOverride = nil }
        } message: {
            Text((forceOverride.flatMap { forceVerify[$0.value] } ?? "The record wasn't found.") + "\n\nForcing now tells certbot to ask Let's Encrypt immediately. If the record really isn't live, that attempt fails and counts against the rate limit. Wait a minute and Re-check, or Force anyway if you're sure it's saved.")
        }
        .onChange(of: host) { _ in saved = false }
        .onChange(of: domain) { _ in saved = false; dnsLoopback = nil }
        .onChange(of: certOwner) { _ in sourceSaved = false }
        .onChange(of: certRepo) { _ in sourceSaved = false }
        .onChange(of: certBranch) { _ in sourceSaved = false }
        .onAppear { reload(); Task { await loadBoard(); await checkLoopback() }; startBoardPolling() }
        .onDisappear { boardTimer?.invalidate(); boardTimer = nil }
    }

    // MARK: Challenge board (manual DNS-01)

    private func challengeCard(_ b: AcmeBoard) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("DNS challenge", systemImage: "list.bullet.clipboard").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    if checking { ProgressView().tint(Theme.accent) }
                    Button { Task { await loadBoard(); await checkDNS() } } label: {
                        Image(systemName: "arrow.clockwise").foregroundStyle(Theme.accent)
                    }
                }
                if let i = b.instructions { Text(i).font(.caption).foregroundStyle(Theme.subtle) }
                ForEach(b.records) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Step \(r.step)/\(r.of) · \(r.domain)").font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            statusTag(r)
                        }
                        copyRow("Name", r.name)
                        copyRow("TXT value", r.value)
                        checkDetails(r)
                        if r.status == "pending" {
                            Button { Task { await force(r) } } label: {
                                HStack {
                                    if forcing == r.value { ProgressView().tint(.black) } else { Image(systemName: "forward.fill") }
                                    Text(r.force == true ? "Force sent — continuing" : "Force continue (record is saved)").fontWeight(.semibold)
                                    Spacer()
                                }
                                .padding(.vertical, 10).padding(.horizontal, 12)
                                .background(r.force == true ? Theme.subtle : Color.orange).foregroundStyle(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .disabled(forcing != nil || r.force == true || !config.hasToken)
                            if let v = forceVerify[r.value] {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: dnsSeen[r.value] == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(dnsSeen[r.value] == true ? .green : .orange)
                                    Text(v).font(.caption2).foregroundStyle(Theme.subtle)
                                }
                            }
                        }
                    }
                    .padding(10).background(Theme.bg)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(r.status == "pending" ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if !b.pending.isEmpty {
                    Text("Add each pending value as a TXT record on \(b.pending.first!.name) at your DNS host (keep both). The workflow checks the zone's authoritative nameservers every 20s and continues on its own. Already saved it and it still says waiting? Tap Force continue.")
                        .font(.caption2).foregroundStyle(Theme.subtle)
                }
            }
        }
    }

    private func checkDetails(_ r: AcmeChallenge) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let c = r.lastCheck {
                if let auth = c.authoritative, !auth.isEmpty {
                    ForEach(auth.keys.sorted(), id: \.self) { ns in
                        let v = auth[ns]!
                        HStack(spacing: 6) {
                            Image(systemName: v.seen ? "checkmark.circle.fill" : "circle").foregroundStyle(v.seen ? .green : Theme.subtle)
                            Text("auth \(ns)").font(.caption2.monospaced()).foregroundStyle(Theme.subtle).lineLimit(1)
                            Spacer()
                            Text(v.seen ? "has value" : (v.txt?.isEmpty == false ? "other TXT only" : "no TXT")).font(.caption2).foregroundStyle(v.seen ? .green : .orange)
                        }
                    }
                } else {
                    Text("authoritative NS: not resolved yet").font(.caption2).foregroundStyle(Theme.subtle)
                }
                if let rs = c.resolvers {
                    HStack(spacing: 10) {
                        ForEach(rs.keys.sorted(), id: \.self) { k in
                            HStack(spacing: 3) {
                                Image(systemName: rs[k]! ? "checkmark" : "xmark").font(.system(size: 9, weight: .bold))
                                Text(k).font(.caption2)
                            }.foregroundStyle(rs[k]! ? .green : Theme.subtle)
                        }
                        Spacer()
                        Text("phone: \(dnsSeen[r.value] == true ? "sees it" : "not yet")").font(.caption2).foregroundStyle(dnsSeen[r.value] == true ? .green : Theme.subtle)
                    }
                }
                if let at = c.at { Text("workflow checked \(at)").font(.caption2).foregroundStyle(Theme.subtle) }
            } else {
                Text("Waiting for the workflow's first check…").font(.caption2).foregroundStyle(Theme.subtle)
            }
            Text("Gate is the authoritative NS row. Public resolvers can hold a cached miss for minutes — ignore them once auth shows the value.")
                .font(.caption2).foregroundStyle(Theme.subtle)
        }
        .padding(.top, 2)
    }

    /// Force continue — but VERIFY first. Queries the record over DNS-over-HTTPS
    /// (Cloudflare + Google + Quad9) and only forces when the exact TXT value is
    /// visible. If it isn't, asks for an explicit override instead of silently
    /// handing Let's Encrypt a record that isn't there (which burns an attempt).
    private func force(_ r: AcmeChallenge, override: Bool = false) async {
        forcing = r.value; error = nil
        let txts = await ZefvCert.txtRecords(r.name)
        let seen = txts.contains(r.value)
        dnsSeen[r.value] = seen
        forceVerify[r.value] = seen
            ? "Verified: \(r.name) returns the exact value (\(txts.count) TXT record\(txts.count == 1 ? "" : "s") found)."
            : (txts.isEmpty ? "No TXT records at \(r.name) yet." : "\(txts.count) TXT record\(txts.count == 1 ? "" : "s") at \(r.name), but none match this value.")
        if !seen && !override {
            forcing = nil
            forceOverride = r          // show confirm sheet
            return
        }
        do {
            try await ZefvCert.forceChallenge(value: r.value, token: config.token)
            note = (seen ? "TXT verified from the phone. " : "Forced without verification. ")
                 + "Force sent — the workflow picks it up on its next poll (≤ 20s) and validates."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await loadBoard()
        } catch { self.error = error.localizedDescription }
        forcing = nil
    }

    private func statusTag(_ r: AcmeChallenge) -> some View {
        let live = dnsSeen[r.value] == true
        let auth = r.lastCheck?.authoritativeSeen == true
        let (text, color): (String, Color) = {
            switch r.status {
            case "validated": return ("VALIDATED", .green)
            case "seen":      return ("SEEN · VALIDATING", .green)
            case "forced":    return ("FORCED · VALIDATING", .green)
            case "timeout":   return ("TIMED OUT", .red)
            default:
                if r.force == true { return ("FORCING", .green) }
                if auth { return ("AUTH HAS IT", .green) }
                return (live ? "SEEN BY PHONE" : "WAITING FOR TXT", live ? .yellow : .orange)
            }
        }()
        return Text(text).font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundStyle(Theme.subtle)
                Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = value; copied = value
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == value { copied = nil } }
            } label: {
                Image(systemName: copied == value ? "checkmark" : "doc.on.doc").font(.caption).foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30).background(Theme.accent.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func loadBoard() async {
        board = await ZefvCert.challengeBoard(token: config.token)
    }

    private func checkDNS() async {
        guard let b = board else { return }
        checking = true
        let names = Set(b.records.map(\.name))
        var seen: [String: Bool] = [:]
        for n in names {
            let txts = await ZefvCert.txtRecords(n)
            for r in b.records where r.name == n { seen[r.value] = txts.contains(r.value) }
        }
        dnsSeen = seen
        checking = false
    }

    private func startBoardPolling() {
        boardTimer?.invalidate()
        boardTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                await loadBoard()
                if board?.pending.isEmpty == false { await checkDNS() }
                // Cert landed? refresh the status card.
                if board?.pending.isEmpty ?? true, renewing == false { reload() }
            }
        }
    }

    /// Always-visible readout of exactly which cert is live right now, so it's
    /// obvious whether the app will actually use the trusted local leaf.
    private var activeCertCard: some View {
        let liveSANs = mode == "local" ? LocalCAManager.leafSANs() : sans
        let hostOKNow = mode == "local" ? LocalCAManager.covers(host) : ZefvCert.covers(host, sans: sans)
        let ready = (mode == "local" ? LocalCAManager.hasLeaf : ZefvCert.isAvailable) && hostOKNow
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Active cert", systemImage: mode == "local" ? "iphone" : "globe").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    Text(ready ? "MATCHES HOST" : "MISMATCH")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced)).kerning(0.5)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((ready ? Color.green : Color.orange).opacity(0.18))
                        .foregroundStyle(ready ? .green : .orange).clipShape(Capsule())
                }
                kvRow("Mode", mode == "local" ? "Fully local (root CA)" : "Public (ACME)")
                kvRow("Install host", host)
                kvRow("Cert covers", liveSANs.isEmpty ? "—" : liveSANs.joined(separator: ", "))
                if !ready {
                    Text(mode == "local"
                         ? "Issue a leaf for \(host) in Local CA settings — instant, the root you trusted covers any host it signs."
                         : "Renew or Pull latest so the ACME cert covers \(host).")
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

    private var modeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Certificate mode", systemImage: "lock.rotation").font(.headline).foregroundStyle(Theme.text)
                HStack(spacing: 8) {
                    ForEach(["public": "Public (ACME)", "local": "Fully local"].sorted(by: { $0.key > $1.key }), id: \.key) { k, name in
                        Button {
                            mode = k; ServerConfig.setCertMode(k)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: k == "public" ? "globe" : "iphone").font(.system(size: 16))
                                Text(name).font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.vertical, 12).frame(maxWidth: .infinity)
                            .background(mode == k ? Theme.accent.opacity(0.18) : Theme.card)
                            .foregroundStyle(mode == k ? Theme.accent : Theme.subtle)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(mode == k ? Theme.accent : Theme.stroke, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(mode == "public"
                     ? "Real ACME cert (Let's Encrypt/ZeroSSL), trusted by iOS out of the box. Needs the DNS TXT step, no profile."
                     : "Your own root CA — no DNS, no external CA, instant and offline. iOS trusts it only after you install the root profile once (you can inspect it first).")
                    .font(.caption).foregroundStyle(Theme.subtle)
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
                accentButton("Open local CA settings", "chevron.right") { showLocalCA = true }
            }
        }
    }

    private var hostCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Domain & install host", systemImage: "network").font(.headline).foregroundStyle(Theme.text)
                Text("Installs run over an on-device Vapor HTTPS server. Use any domain you control: point `*.<domain>` (A record) at 127.0.0.1, then issue a wildcard cert for it with Renew below. iOS trusts the cert, connects to loopback, installs. Default zefv.dev ships with a cert.")
                    .font(.caption).foregroundStyle(Theme.subtle)
                Field(label: "Domain", text: $domain, placeholder: ServerConfig.defaultDomain, keyboard: .URL)
                Field(label: "Install host", text: $host, placeholder: "mr.\(cleanDomain.isEmpty ? ServerConfig.defaultDomain : cleanDomain)", keyboard: .URL)
                if !domainOK { Text("Enter a domain like example.com").font(.caption).foregroundStyle(.orange) }
                else if !hostOK { Text("Host must be under \(cleanDomain).").font(.caption).foregroundStyle(.orange) }
                else if !certCoversHost {
                    Text("Loaded cert covers \(sans.isEmpty ? "—" : sans.joined(separator: ", ")) — not \(clean). Save, then Renew now to issue one for \(cleanDomain).")
                        .font(.caption).foregroundStyle(.orange)
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

    private func checkLoopback() async {
        guard domainOK else { return }
        dnsChecking = true
        dnsLoopback = await ZefvCert.resolvesToLoopback("ota-probe.\(cleanDomain)")
        dnsChecking = false
    }

    private var certCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Certificate", systemImage: "lock.shield.fill").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    statusPill
                }
                kv("In use", cached ? "Refreshed from repo" : "Bundled in IPA")
                kv("Covers", sans.isEmpty ? "—" : sans.joined(separator: ", "))
                kv("Expires", expires.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                kv("Refreshed", fetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never")
                if let p = probe {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: p.hasPackJson && p.hasServerCrt && p.hasServerPem ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(p.hasPackJson && p.hasServerCrt && p.hasServerPem ? .green : .orange)
                        Text(p.summary).font(.caption).foregroundStyle(Theme.subtle)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                if let note { Text(note).font(.caption).foregroundStyle(.green) }
                HStack(spacing: 10) {
                    accentButton(refreshing ? "Fetching…" : "Pull latest", "arrow.down.circle", busy: refreshing) { Task { await refresh() } }
                    if cached {
                        Button { ZefvCert.clearCache(); reload() } label: {
                            Image(systemName: "trash").frame(width: 46, height: 46)
                                .background(Theme.card).foregroundStyle(.orange)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                Button { Task { await renew() } } label: {
                    HStack {
                        if renewing { ProgressView().tint(Theme.accent) } else { Image(systemName: "bolt.fill") }
                        Text(renewing ? "Dispatching…" : "Renew now — issue cert for *.\(ServerConfig.certDomain)").fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(Theme.card).foregroundStyle(Theme.accent)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(renewing || !config.hasToken)
                Button { Task { probe = await ZefvCert.probeCertBranch(token: config.token) } } label: {
                    HStack { Image(systemName: "stethoscope"); Text("Check cert branch").fontWeight(.semibold); Spacer() }
                        .padding(.vertical, 10).padding(.horizontal, 14)
                        .background(Theme.card).foregroundStyle(Theme.accent)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text("Auto-pulls on install when within \(ServerConfig.refreshBufferDays) days of expiry. Renew forces a new issuance; watch it in the Build tab, then Pull latest.")
                    .font(.caption2).foregroundStyle(Theme.subtle)
            }
        }
    }

    /// Pre-issuance DNS check for Public/ACME so you don't dispatch a run that
    /// can't validate. Verifies the wildcard A record points at loopback and the
    /// domain's nameservers are reachable (so certbot's TXT will be seen).
    private var dnsReadinessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("DNS readiness", systemImage: "checkmark.shield").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    if checkingReady { ProgressView().tint(Theme.accent) }
                    Button { Task { await checkReady() } } label: { Image(systemName: "arrow.clockwise").foregroundStyle(Theme.accent) }
                }
                if let r = readiness {
                    readyRow(r.wildcardLoopback == true, "*.\(ServerConfig.certDomain) → 127.0.0.1",
                             fail: "Add a wildcard A record (Subdomain: *, or just leave label blank per Dynadot) → 127.0.0.1")
                    readyRow(!r.nameservers.isEmpty, "Nameservers reachable" + (r.nameservers.isEmpty ? "" : ": \(r.nameservers.prefix(2).joined(separator: ", "))"),
                             fail: "Domain's nameservers didn't answer — check the zone is active at your registrar.")
                    if !r.ready {
                        Text("Renew is disabled until these pass, so you don't burn a certbot attempt. Tap Force check to override.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                } else if !checkingReady {
                    Text("Not checked yet.").font(.caption).foregroundStyle(Theme.subtle)
                }
            }
        }
    }

    private func readyRow(_ ok: Bool, _ text: String, fail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(ok ? .green : .orange)
                Text(text).font(.caption).foregroundStyle(ok ? Theme.text : .orange)
            }
            if !ok { Text(fail).font(.caption2).foregroundStyle(Theme.subtle) }
        }
    }

    private func checkReady() async {
        checkingReady = true
        readiness = await ZefvCert.dnsReadiness(domain: ServerConfig.certDomain)
        checkingReady = false
    }

    /// Pulls the most recent certs.yml run and, if it failed, the failing step's log tail —
    /// so the real reason is on this screen instead of behind a GitHub login.
    private var lastRunCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Last certs run", systemImage: "clock.arrow.circlepath").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    if loadingRun { ProgressView().tint(Theme.accent) }
                    Button { Task { await loadLastRun() } } label: { Image(systemName: "arrow.clockwise").foregroundStyle(Theme.accent) }
                }
                if let r = lastRun {
                    HStack(spacing: 8) {
                        runPill(r)
                        Text("#\(r.runNumber) · \(r.headBranch) · \(r.event)").font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                        Spacer()
                        if let u = URL(string: r.htmlURL) { Link("Open", destination: u).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent) }
                    }
                    ForEach(lastJobs) { job in
                        ForEach(job.steps) { st in
                            HStack(spacing: 8) {
                                Image(systemName: stepIcon(st)).foregroundStyle(stepColor(st)).font(.caption)
                                Text(st.name).font(.caption).foregroundStyle(st.conclusion == "failure" ? .orange : Theme.subtle).lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                    if let tail = runLogTail {
                        Text("FAILED STEP LOG").font(.system(size: 10, weight: .bold)).kerning(1).foregroundStyle(.orange)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(tail).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
                        }
                        .frame(maxHeight: 220)
                        .padding(8).background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else if !loadingRun {
                    Text("No certs.yml run found yet, or the token can't read Actions.").font(.caption).foregroundStyle(Theme.subtle)
                }
            }
        }
    }

    private func runPill(_ r: WorkflowRun) -> some View {
        let (t, c): (String, Color) = r.isActive ? ("RUNNING", .yellow) : (r.conclusion == "success" ? ("SUCCESS", .green) : ("\((r.conclusion ?? "?").uppercased())", .orange))
        return Text(t).font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(0.5)
            .padding(.horizontal, 7).padding(.vertical, 3).background(c.opacity(0.18)).foregroundStyle(c).clipShape(Capsule())
    }
    private func stepIcon(_ s: WorkflowStep) -> String {
        s.status != "completed" ? (s.status == "in_progress" ? "circle.dotted" : "circle") : (s.conclusion == "success" ? "checkmark.circle.fill" : (s.conclusion == "skipped" ? "arrow.right.circle" : "xmark.octagon.fill"))
    }
    private func stepColor(_ s: WorkflowStep) -> Color {
        s.status != "completed" ? Theme.subtle : (s.conclusion == "success" ? .green : (s.conclusion == "skipped" ? Theme.subtle : .orange))
    }

    private func loadLastRun() async {
        guard config.hasToken else { return }
        loadingRun = true; runLogTail = nil
        let client = ActionsClient(owner: ServerConfig.certRepoOwner, repo: ServerConfig.certRepoName, token: config.token)
        do {
            guard let (run, jobs) = try await client.latestRun(workflowPath: ServerConfig.certWorkflowPath) else { lastRun = nil; loadingRun = false; return }
            lastRun = run; lastJobs = jobs
            // If something failed, fetch that job's log and keep the part around the failure.
            if let failedJob = jobs.first(where: { $0.steps.contains { $0.conclusion == "failure" } }),
               let failedStep = failedJob.steps.first(where: { $0.conclusion == "failure" }) {
                let log = try await client.jobLog(jobID: failedJob.id)
                runLogTail = Self.extract(log: log, stepName: failedStep.name)
            }
        } catch { self.error = error.localizedDescription }
        loadingRun = false
    }

    /// Keep the failing step's section (GitHub groups steps with ##[group] markers) and the
    /// last ~40 lines, stripping timestamps and ANSI so it fits on a phone.
    private static func extract(log: String, stepName: String) -> String {
        var lines = log.components(separatedBy: "\n").map { line -> String in
            var l = line
            if let r = l.range(of: "^[0-9T:.-]+Z ", options: .regularExpression) { l.removeSubrange(r) }   // ISO timestamp prefix
            l = l.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            return l
        }
        if let idx = lines.lastIndex(where: { $0.contains("##[group]") && $0.contains(stepName) }) {
            lines = Array(lines[idx...])
        }
        let errors = lines.filter { $0.contains("::error") || $0.contains("error:") || $0.contains("fatal:") || $0.contains("rejected") }
        let tail = lines.suffix(40)
        return (errors.isEmpty ? "" : "— errors —\n" + errors.joined(separator: "\n") + "\n\n— tail —\n") + tail.joined(separator: "\n")
    }

    private var sourceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Cert repo — no computer needed", systemImage: "iphone.and.arrow.forward").font(.headline).foregroundStyle(Theme.text)
                Text("Everything runs from this phone. Sign in to GitHub, paste a token in Settings › Access token, pick any repo you own, tap Link. Linking installs the certbot workflow on the repo and creates the `certs` folder (branch) for you on first link-up. Renewals, TXT challenges and the cert files all live there — no Mac, no server, no terminal.")
                    .font(.caption).foregroundStyle(Theme.subtle)
                Field(label: "Owner", text: $certOwner, placeholder: "your-github-user")
                Field(label: "Repo", text: $certRepo, placeholder: "unzip-drop")
                Field(label: "Branch (certs folder)", text: $certBranch, placeholder: "certs")
                Field(label: "ACME email", text: $leEmail, placeholder: "you@example.com", keyboard: .emailAddress)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Certificate authority").font(.caption).foregroundStyle(Theme.subtle)
                    HStack(spacing: 8) {
                        ForEach(["letsencrypt": "Let's Encrypt", "zerossl": "ZeroSSL"].sorted(by: { $0.key < $1.key }), id: \.key) { k, name in
                            Button { certCA = k } label: {
                                Text(name).font(.system(size: 13, weight: .semibold))
                                    .padding(.vertical, 9).frame(maxWidth: .infinity)
                                    .background(certCA == k ? Theme.accent.opacity(0.18) : Theme.card)
                                    .foregroundStyle(certCA == k ? Theme.accent : Theme.subtle)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(certCA == k ? Theme.accent : Theme.stroke, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if certCA == "zerossl" {
                    Field(label: "ZeroSSL EAB KID (optional)", text: $eabKID, placeholder: "auto from email if blank")
                    Field(label: "ZeroSSL EAB HMAC (optional)", text: $eabHMAC, placeholder: "auto from email if blank")
                    Text("Leave EAB blank to auto-request it from ZeroSSL using your email. Or paste from ZeroSSL → Developer → EAB.")
                        .font(.caption2).foregroundStyle(Theme.subtle)
                }
                if let linkReport { Text(linkReport).font(.caption).foregroundStyle(.green) }
                HStack(spacing: 10) {
                    accentButton(linking ? "Linking…" : "Link repo", "link", enabled: config.hasToken && !certOwner.isEmpty && !certRepo.isEmpty, busy: linking) {
                        Task { await link() }
                    }
                    Button { Task { await link(force: true) } } label: {
                        Image(systemName: "arrow.triangle.2.circlepath").frame(width: 46, height: 46)
                            .background(Theme.card).foregroundStyle(Theme.accent)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(linking || !config.hasToken)
                    Button { saveSource() } label: {
                        Image(systemName: sourceSaved ? "checkmark" : "square.and.arrow.down").frame(width: 46, height: 46)
                            .background(Theme.card).foregroundStyle(Theme.accent)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Text("↻ Update pipeline: force-pushes the app's current certs.yml + hooks over whatever is on main. Use it after an app update, or if Renew fails with 'unexpected inputs' / 'No email'.")
                    .font(.caption2).foregroundStyle(Theme.subtle)
                if !config.hasToken {
                    Text("Token needs: Contents, Actions, Workflows — all Read and write — on this repo.").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func saveSource() {
        ServerConfig.setCertSource(owner: Config.clean(certOwner).isEmpty ? "mrzefv" : Config.clean(certOwner),
                                   repo: Config.clean(certRepo).isEmpty ? "unzip-drop" : Config.clean(certRepo),
                                   branch: Config.clean(certBranch).isEmpty ? "certs" : Config.clean(certBranch))
        UserDefaults.standard.set(Config.clean(leEmail), forKey: "uzd_le_email")
        ServerConfig.setCertCA(certCA)
        ServerConfig.setEAB(kid: Config.clean(eabKID), hmac: eabHMAC.trimmingCharacters(in: .whitespacesAndNewlines))
        certOwner = ServerConfig.certRepoOwner; certRepo = ServerConfig.certRepoName; certBranch = ServerConfig.certBranch
        sourceSaved = true
    }

    private func link(force: Bool = false) async {
        saveSource()
        linking = true; error = nil; linkReport = nil
        do {
            let r = try await CertSourceLinker.link(owner: ServerConfig.certRepoOwner, repo: ServerConfig.certRepoName, token: config.token, forceUpdate: force)
            var parts: [String] = ["Linked \(ServerConfig.certRepoOwner)/\(ServerConfig.certRepoName)."]
            if !r.installedFiles.isEmpty { parts.append((force ? "Updated " : "Installed ") + "\(r.installedFiles.count) pipeline files on main.") }
            if r.branchCreated { parts.append("Created the certs folder.") }
            parts.append(contentsOf: r.notes)
            parts.append("Next: set your domain above, add the wildcard A record, tap Renew now.")
            linkReport = parts.joined(separator: " ")
            await loadBoard()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = error.localizedDescription }
        linking = false
    }

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

    private func reload() {
        expires = ZefvCert.effectiveNotAfter; cached = ZefvCert.hasCached; fetchedAt = ZefvCert.meta?.fetchedAt
        sans = ZefvCert.effectiveSANs
    }

    private var statusPill: some View {
        let days = expires.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 } ?? -1
        let color: Color = expires == nil ? .orange : (days < 0 ? .red : (days < ServerConfig.refreshBufferDays ? .orange : .green))
        let text = expires == nil ? "MISSING" : (days < 0 ? "EXPIRED" : (days < ServerConfig.refreshBufferDays ? "\(days)D LEFT" : "READY"))
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

    private func refresh() async {
        refreshing = true; error = nil; note = nil
        do {
            _ = try await ZefvCert.fetch(token: config.token); reload()
            note = "Pulled from \(ServerConfig.certRepoOwner)/\(ServerConfig.certRepoName)@\(ServerConfig.certBranch)"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = error.localizedDescription }
        refreshing = false
    }

    private func renew() async {
        // Pre-issuance DNS gate (skippable). Avoids dispatching a run that can't validate.
        if !proceedAnyway {
            checkingReady = true
            let r = await ZefvCert.dnsReadiness(domain: ServerConfig.certDomain)
            readiness = r; checkingReady = false
            if !r.ready {
                error = "DNS isn't ready for \(ServerConfig.certDomain): " +
                    ([r.wildcardLoopback == true ? nil : "wildcard A → 127.0.0.1 missing",
                      r.nameservers.isEmpty ? "nameservers unreachable" : nil].compactMap { $0 }.joined(separator: "; ")) +
                    ". Fix at your DNS host, or tap Renew again to force."
                proceedAnyway = true   // next tap proceeds
                return
            }
        }
        proceedAnyway = false
        renewing = true; error = nil; note = nil
        let client = ActionsClient(owner: ServerConfig.certRepoOwner, repo: ServerConfig.certRepoName, token: config.token)
        do {
            let wfs = try await client.workflows()
            guard let wf = wfs.first(where: { $0.path == ServerConfig.certWorkflowPath }) else {
                throw GitHubError.badConfig("certs.yml not found in \(ServerConfig.certRepoOwner)/\(ServerConfig.certRepoName). Tap Link repo below first — it installs the workflow for you.")
            }
            let email = UserDefaults.standard.string(forKey: "uzd_le_email") ?? ""
            guard !email.isEmpty else { throw GitHubError.badConfig("Enter a Let's Encrypt email in the Cert repo card and save.") }
            // Send only inputs the workflow on main actually declares — GitHub
            // rejects the whole dispatch (422) on any unexpected key, e.g. when
            // an older certs.yml without `ca`/`email` is still on main.
            var wanted = ["domain": ServerConfig.certDomain, "email": email, "ca": ServerConfig.certCA, "force": "true"]
            if ServerConfig.certCA == "zerossl" {
                if !ServerConfig.eabKID.isEmpty { wanted["eab_kid"] = ServerConfig.eabKID }
                if !ServerConfig.eabHMAC.isEmpty { wanted["eab_hmac"] = ServerConfig.eabHMAC }
            }
            let declared = await client.workflowInputs(path: ServerConfig.certWorkflowPath)
            let inputs = declared.isEmpty ? wanted : wanted.filter { declared.contains($0.key) }
            let dropped = Set(wanted.keys).subtracting(inputs.keys)
            if dropped.contains("email") {
                throw GitHubError.badConfig("The certs.yml on main is an old version with no `email` input — push the latest workflow (Link repo re-installs it) before renewing.")
            }
            try await client.dispatch(workflowID: wf.id, ref: "main", inputs: inputs)
            if !dropped.isEmpty {
                note = "Note: workflow on main doesn't declare \(dropped.sorted().joined(separator: ", ")) — sent without them. Push the latest certs.yml to enable them."
            }
            note = "certbot run dispatched for *.\(ServerConfig.certDomain) — TXT values appear above within ~1 min. Add them at your DNS host; the run finishes on its own. Then Pull latest."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = error.localizedDescription }
        renewing = false
    }
}

// MARK: - Local CA (fully offline OTA cert, inspect before installing)

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
            .background(Color.clear.ignoresSafeArea())
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
                Text("Same parser, same fields, for every certificate this app can present to iOS. Compare what a public CA issued against what this phone issued. Active mode: \(ServerConfig.certMode == "local" ? "Fully local" : "Public (ACME)").")
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
