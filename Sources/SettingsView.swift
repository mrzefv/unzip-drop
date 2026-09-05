//
//  SettingsView.swift
//  mSign-style settings: sectioned rows (icon tile · title · subtitle · open
//  glyph). Tapping a row pushes a dedicated screen. Rows have a fixed height
//  so the list stays compact and never fights the keyboard.
//

import SwiftUI

// MARK: - Root list

private enum Screen: Identifiable, Hashable {
    case about, repo, token
    case dylibTemplate, ipaTemplate
    case certificates, otaDomain
    case tutorial(String)
    var id: String {
        switch self {
        case .about: return "about"; case .repo: return "repo"; case .token: return "token"
        case .dylibTemplate: return "tpl-dylib"; case .ipaTemplate: return "tpl-ipa"
        case .certificates: return "certs"; case .otaDomain: return "ota"
        case .tutorial(let t): return "tut-" + t
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
                                        subtitle: "\(ServerConfig.installHost) · zefv.dev cert") { screen = .otaDomain }
                        }

                        SettingsSection("Templates") {
                            SettingsRow(icon: "puzzlepiece.extension.fill", title: "Dylib project",
                                        subtitle: "Theos · runtime swizzle · Actions build") { screen = .dylibTemplate }
                            SettingsRow(icon: "app.badge.fill", title: "IPA app project",
                                        subtitle: "SwiftUI · XcodeGen · unsigned Actions build") { screen = .ipaTemplate }
                        }

                        SettingsSection("Tutorials") {
                            ForEach(TutorialLibrary.all) { t in
                                SettingsRow(icon: t.icon, title: t.title, subtitle: t.subtitle) { screen = .tutorial(t.id) }
                            }
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
                case .dylibTemplate: DylibTemplateScreen()
                case .ipaTemplate:   IPATemplateScreen()
                case .tutorial(let id):
                    TutorialScreen(tutorial: TutorialLibrary.all.first { $0.id == id } ?? TutorialLibrary.flex)
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


// MARK: - OTA domain (zefv.dev)

private struct OTADomainScreen: View {
    @State private var host = ServerConfig.installHost
    @State private var saved = false
    @State private var refreshing = false
    @State private var expires = ZefvCert.effectiveNotAfter
    @State private var cached = ZefvCert.hasCached
    @State private var fetchedAt = ZefvCert.meta?.fetchedAt
    @State private var error: String?

    private var clean: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private var hostOK: Bool { clean.lowercased().hasSuffix(".zefv.dev") || clean.lowercased() == "zefv.dev" }

    var body: some View {
        DetailScreen(title: "On-Device OTA Domain") {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Install host", systemImage: "network").font(.headline).foregroundStyle(Theme.text)
                    Text("Installs run over an on-device Vapor HTTPS server, same as mSign. *.zefv.dev resolves to 127.0.0.1 and is covered by the bundled Let's Encrypt wildcard cert. iOS trusts it, connects to loopback, installs.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    Field(label: "Host", text: $host, placeholder: "mr.zefv.dev", keyboard: .URL)
                    if !hostOK {
                        Text("Host must be under zefv.dev to match the cert.").font(.caption).foregroundStyle(.orange)
                    }
                    Button {
                        ServerConfig.setInstallHost(clean.isEmpty ? "mr.zefv.dev" : clean)
                        host = ServerConfig.installHost; saved = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        HStack { Image(systemName: saved ? "checkmark.circle.fill" : "network"); Text(saved ? "Saved" : "Save host").fontWeight(.semibold); Spacer() }
                            .padding(.vertical, 12).padding(.horizontal, 14)
                            .background(hostOK ? Theme.accent : Theme.subtle).foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!hostOK)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Certificate", systemImage: "lock.shield.fill").font(.headline).foregroundStyle(Theme.text)
                        Spacer()
                        statusPill
                    }
                    kv("In use", cached ? "Refreshed copy" : "Bundled (mSign server.crt)")
                    kv("Covers", "*.zefv.dev, zefv.dev")
                    kv("Expires", expires.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    kv("Refreshed", fetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never")
                    kv("Source", ServerConfig.refreshURL.absoluteString)
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                    HStack(spacing: 10) {
                        Button { Task { await refresh() } } label: {
                            HStack {
                                if refreshing { ProgressView().tint(.black) } else { Image(systemName: "arrow.triangle.2.circlepath") }
                                Text(refreshing ? "Fetching…" : "Refresh certificate").fontWeight(.semibold)
                                Spacer()
                            }
                            .padding(.vertical, 12).padding(.horizontal, 14)
                            .background(Theme.accent).foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(refreshing)
                        if cached {
                            Button { ZefvCert.clearCache(); reload() } label: {
                                Image(systemName: "trash").frame(width: 46, height: 46)
                                    .background(Theme.card).foregroundStyle(.orange)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    Text("Auto-refreshes on install when within \(ServerConfig.refreshBufferDays) days of expiry. certbot on mrzefv.com republishes pack.json; the bundled pair keeps working offline until then.")
                        .font(.caption2).foregroundStyle(Theme.subtle)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Manifest URL shape").font(.headline).foregroundStyle(Theme.text)
                    Text("https://\(ServerConfig.installHost):<port>/<id>.plist")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent)
                }
            }
        }
        .onChange(of: host) { _ in saved = false }
        .onAppear(perform: reload)
    }

    private func reload() {
        expires = ZefvCert.effectiveNotAfter; cached = ZefvCert.hasCached; fetchedAt = ZefvCert.meta?.fetchedAt
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
        refreshing = true; error = nil
        do {
            _ = try await ZefvCert.fetch(); reload()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = error.localizedDescription }
        refreshing = false
    }
}
