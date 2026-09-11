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
    case certificates, otaDomain, certInspector, transparency, recoverData, copilot, live3d
    case tutorials
    var id: String {
        switch self {
        case .about: return "about"; case .repo: return "repo"; case .token: return "token"
        case .dylibTemplate: return "tpl-dylib"; case .ipaTemplate: return "tpl-ipa"
        case .certificates: return "certs"; case .otaDomain: return "ota"; case .certInspector: return "inspect"; case .transparency: return "transparency"; case .recoverData: return "recover"; case .copilot: return "copilot"; case .live3d: return "live3d"
        case .tutorials: return "tutorials"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var config: Config
    @EnvironmentObject var session: Session
    @ObservedObject private var certs = CertificateStore.shared
    @ObservedObject private var staff = StaffGate.shared
    @State private var screen: Screen?

    var body: some View {
        ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {

                        SettingsSection("General") {
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
                            if staff.isStaff {
                                SettingsRow(icon: "lock.doc.fill",
                                            title: "Recover hidden data",
                                            subtitle: "Decrypt an Mcrypted payload from any signed IPA") { screen = .recoverData }
                                SettingsRow(icon: "sparkles",
                                            title: "Copilot",
                                            subtitle: Copilot.hasKey ? "\(Copilot.provider.label) key set" : "Add API key for AI dylib authoring") { screen = .copilot }
                                SettingsRow(icon: "cube.transparent",
                                            title: "mv1E Live (3D view debugger)",
                                            subtitle: "Render a live UIView hierarchy captured from an injected app") { screen = .live3d }
                            }
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
                            SettingsLink(icon: "globe", title: "delvek.net", subtitle: "Trusted IPA Repository",
                                         url: URL(string: "https://delvek.net")!)
                            SettingsLink(icon: "person.crop.circle.badge.checkmark", title: "MSign",
                                         subtitle: "msign.party | Founder MRZefv",
                                         url: URL(string: "https://msign.party")!)
                        }

                        SettingsSection(staff.isStaff ? "Staff (\(staff.role.title))" : "Access") {
                            SettingsRow(icon: staff.isStaff ? "checkmark.shield.fill" : "lock.fill",
                                        title: staff.isStaff ? "Staff tools unlocked" : "Standard access",
                                        subtitle: "Your MDID: \(staff.mdid)") {
                                UIPasteboard.general.string = staff.mdid
                            }
                        }

                        StatusFooter()
                            .padding(.top, 26)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 20)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                TabTitleBar(title: "Settings") {
                    Text("\(Theme.appName.uppercased()) \(Theme.appVersion)").font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                }
            }
            .task { await StaffGate.shared.refresh() }
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
                case .recoverData:   McryptedRecoverView()
                case .copilot:       CopilotSettingsView()
                case .live3d:        MV1ELiveView()
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
    @Environment(\.openURL) private var openURL
    @ObservedObject private var staff = StaffGate.shared
    @State private var checking = false

    private var role: UserRole { staff.isStaff ? staff.role : .member }
    private var roleLabel: String { staff.isStaff ? role.badgeText : "GUEST" }
    private var roleColor: Color { staff.isStaff ? role.color : Theme.accent }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    openURL(URL(string: "https://msign.party/account")!)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.plus")
                        Text("Create an MSign account")
                            .underline()
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    guard !checking else { return }
                    checking = true
                    Task {
                        await staff.refresh()
                        await MainActor.run { checking = false }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.subtle)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                        .rotationEffect(.degrees(checking ? 360 : 0))
                        .animation(checking ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: checking)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Text(roleLabel)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced)).kerning(1)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(roleColor.opacity(0.18))
                    .foregroundStyle(roleColor)
                    .overlay(Capsule().stroke(roleColor.opacity(0.5), lineWidth: 1))
                    .clipShape(Capsule())

                Button {
                    UIPasteboard.general.string = staff.mdid
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    (Text("MDID: ")
                        .font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundColor(Theme.subtle)
                    + Text(staff.mdid)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundColor(Theme.accent))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy MDID")
                .accessibilityValue(staff.mdid)
                .accessibilityHint("Copies your device identifier")

                Spacer(minLength: 0)
            }
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
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) { content }
                .padding(16)
        }
        // Floating glass header — content scrolls underneath it.
        .safeAreaInset(edge: .top, spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                    Text("MSIGN")
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
            .padding(.horizontal, 16).padding(.vertical, 10)
            .floatingGlassBar(edge: .top)
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


// MARK: - Table plumbing shared by the OTA screens

/// Inset-grouped table screen with the app's dark chrome. Root screens get a
/// chevron-down dismiss; pushed screens get the system back button.
private struct TableScreen<Content: View>: View {
    let title: String
    var root = false
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if root {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.accent).frame(width: 34, height: 34)
                                .background(Theme.accent.opacity(0.14)).clipShape(Circle())
                        }
                    }
                }
            }
    }
}

private struct TRow: View {          // label · value
    let k: String; let v: String
    var tint: Color = Theme.text
    var body: some View {
        HStack {
            Text(k).foregroundStyle(Theme.subtle)
            Spacer(minLength: 12)
            Text(v).font(.system(size: 15, design: .monospaced)).foregroundStyle(tint)
                .lineLimit(1).truncationMode(.middle).multilineTextAlignment(.trailing)
        }
        .listRowBackground(Theme.card)
    }
}

private struct TStatusRow: View {    // icon · text (green/orange)
    let ok: Bool; let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill").foregroundStyle(ok ? .green : .orange)
            Text(text).font(.subheadline).foregroundStyle(ok ? .green : .orange)
        }
        .listRowBackground(Theme.card)
    }
}

private struct TNav<Dest: View>: View {   // icon · title · subtitle › pushes Dest
    let icon: String; let title: String; var subtitle: String = ""
    @ViewBuilder var dest: Dest
    var body: some View {
        NavigationLink {
            dest
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.text)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(Theme.subtle).lineLimit(2) }
                }
            }
        }
        .listRowBackground(Theme.card)
    }
}

private struct TButton: View {       // full-width action row
    let title: String; let icon: String
    var role: ButtonRole? = nil
    var busy = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                if busy { ProgressView().tint(Theme.accent) } else { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
                Spacer()
            }
            .foregroundStyle(role == .destructive ? .red : (enabled ? Theme.accent : Theme.subtle))
        }
        .disabled(busy || !enabled)
        .listRowBackground(Theme.card)
    }
}

private struct TField: View {        // label · text field on one row
    let label: String
    @Binding var text: String
    var placeholder = ""
    var keyboard: UIKeyboardType = .default
    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.subtle)
            Spacer(minLength: 12)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard).textInputAutocapitalization(.never).autocorrectionDisabled()
                .multilineTextAlignment(.trailing).foregroundStyle(Theme.text)
                .font(.system(size: 15, design: .monospaced))
        }
        .listRowBackground(Theme.card)
    }
}

private struct TNote: View {         // footer-ish explanatory row
    let text: String
    var tint: Color = Theme.subtle
    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 6, trailing: 4))
    }
}

private func certPill(_ exp: Date?) -> some View {
    let days = exp.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 } ?? -1
    let color: Color = exp == nil ? .orange : (days < 0 ? .red : (days < ServerConfig.refreshBufferDays ? .orange : .green))
    let text = exp == nil ? "MISSING" : (days < 0 ? "EXPIRED" : (days < ServerConfig.refreshBufferDays ? "\(days)D LEFT" : "READY"))
    return Text(text).font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
}

/// Shared, observable snapshot of the OTA cert state so every pushed screen
/// re-renders the root when it changes something.
@MainActor
private final class OTAState: ObservableObject {
    @Published var mode = ServerConfig.certMode
    @Published var host = ServerConfig.installHost
    @Published var domain = ServerConfig.certDomain
    @Published var sans: [String] = []
    @Published var expires: Date?
    @Published var rootTrusted = false
    @Published var hasRoot = false
    @Published var hasLeaf = false
    @Published var hasCustom = false
    @Published var cached = false
    @Published var fetchedAt: Date?
    @Published var files: [URL] = []

    func reload() {
        LocalCAManager.rehydrateIfNeeded()
        mode = ServerConfig.certMode; host = ServerConfig.installHost; domain = ServerConfig.certDomain
        hasRoot = LocalCAManager.hasRoot; hasLeaf = LocalCAManager.hasLeaf; hasCustom = ZefvCert.hasCustom
        rootTrusted = LocalCAManager.isRootTrusted()
        cached = ZefvCert.hasCached; fetchedAt = ZefvCert.meta?.fetchedAt
        switch mode {
        case "local":  sans = LocalCAManager.leafSANs(); expires = LocalCAManager.leafExpiry
        case "custom": sans = ZefvCert.customSANs;       expires = ZefvCert.customNotAfter
        default:       sans = ZefvCert.effectiveSANs;    expires = ZefvCert.effectiveNotAfter
        }
        files = OTAFiles.list()
    }

    var have: Bool { mode == "local" ? hasLeaf : (mode == "custom" ? hasCustom : ZefvCert.isAvailable) }
    var coversHost: Bool { mode == "local" ? LocalCAManager.covers(host) : ZefvCert.covers(host, sans: sans) }
    var ready: Bool { have && coversHost && (mode != "local" || rootTrusted) }
    var modeName: String { mode == "local" ? "Local CA" : (mode == "custom" ? "Own cert" : "zefv.dev") }
    var statusText: String { ready ? "READY" : (have ? (coversHost ? "NOT TRUSTED" : "MISMATCH") : "MISSING") }
}

// MARK: - On-Device OTA (root table)

struct OTADomainScreen: View {
    @EnvironmentObject var config: Config
    @StateObject private var st = OTAState()

    var body: some View {
        NavigationStack {
            TableScreen(title: "On-Device OTA", root: true) {

                Section {
                    Picker(selection: Binding(get: { st.mode }, set: { m in
                        ServerConfig.setCertMode(m)
                        if m == "public" {
                            ServerConfig.setCertDomain(ServerConfig.defaultDomain)
                            if !ServerConfig.installHost.hasSuffix("." + ServerConfig.defaultDomain) { ServerConfig.setInstallHost(ServerConfig.defaultInstallHost) }
                        }
                        st.reload()
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    })) {
                        Label("zefv.dev · VPS auto-renew", systemImage: "globe").tag("public")
                        Label("Own TLS cert",             systemImage: "doc.badge.plus").tag("custom")
                        Label("Local root CA",            systemImage: "iphone").tag("local")
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.rotation").foregroundStyle(Theme.accent).frame(width: 26)
                            Text("Certificate mode").foregroundStyle(Theme.text)
                        }
                    }
                    .pickerStyle(.menu).tint(Theme.accent)
                    .listRowBackground(Theme.card)
                } footer: {
                    Text(st.mode == "public"
                         ? "Real Let's Encrypt wildcard for *.zefv.dev, renewed on the VPS (certbot + Cloudflare) and pulled here. Trusted by iOS out of the box."
                         : st.mode == "custom"
                         ? "Your own TLS cert for your own domain. Import fullchain + key; point the host at 127.0.0.1."
                         : "Your own root CA — offline, no DNS provider. iOS trusts it once the root profile is installed and enabled.")
                    .foregroundStyle(Theme.subtle)
                }

                Section {
                    HStack {
                        Label("Active cert", systemImage: "checkmark.seal").foregroundStyle(Theme.text)
                        Spacer()
                        Text(st.statusText).font(.system(size: 10, weight: .heavy, design: .monospaced)).kerning(0.5)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background((st.ready ? Color.green : Color.orange).opacity(0.18))
                            .foregroundStyle(st.ready ? .green : .orange).clipShape(Capsule())
                    }
                    .listRowBackground(Theme.card)
                    TRow(k: "Mode", v: st.modeName)
                    TRow(k: "Install host", v: st.host)
                    TRow(k: "Covers", v: st.sans.isEmpty ? "—" : st.sans.joined(separator: ", "))
                    TRow(k: "Expires", v: st.expires.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    if st.mode == "local" {
                        TStatusRow(ok: st.rootTrusted, text: st.rootTrusted ? "Root CA installed & trusted on this device" : "Root CA not trusted yet — install the profile, then enable it in Settings › General › About › Certificate Trust Settings")
                    }
                    if st.have && !st.coversHost {
                        TStatusRow(ok: false, text: "The cert doesn't cover \(st.host).")
                    }
                }

                Section {
                    if st.mode != "local" {
                        TNav(icon: "network", title: "Install host & DNS", subtitle: st.host) { OTAHostScreen(st: st) }
                    }
                    switch st.mode {
                    case "local":
                        TNav(icon: "iphone", title: "Local CA", subtitle: st.hasRoot ? "Root ready · leaf \(st.hasLeaf ? "issued for \(LocalCAManager.meta?.host ?? st.host)" : "not issued")" : "Create root + leaf, install the trust profile") { LocalCAScreen(st: st) }
                    case "custom":
                        TNav(icon: "doc.badge.plus", title: "Own certificate", subtitle: st.hasCustom ? "Imported · \(st.sans.joined(separator: ", "))" : "Import fullchain + key (PEM)") { OwnCertScreen(st: st) }
                    default:
                        TNav(icon: "arrow.triangle.2.circlepath.circle", title: "zefv.dev certificate", subtitle: st.cached ? "Pulled from VPS · \(st.fetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")" : "Bundled in IPA · pull from VPS to refresh") { VPSCertScreen(st: st) }
                    }
                } header: {
                    Text("Setup")
                }

                Section {
                    TNav(icon: "folder", title: "Exported files", subtitle: st.files.isEmpty ? "Nothing exported yet" : "\(st.files.count) file\(st.files.count == 1 ? "" : "s") · Files › On My iPhone › mSign › OTA Certs") { OTAFilesScreen(st: st) }
                } footer: {
                    Text("Certs, chains and the trust profile are copied into a folder the Files app can see whenever you issue or install. Private keys never leave the Keychain.").foregroundStyle(Theme.subtle)
                }
            }
        }
        .onAppear { st.reload() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in st.reload() }
    }
}

// MARK: - Install host & DNS

private struct OTAHostScreen: View {
    @ObservedObject var st: OTAState
    @State private var domain = ServerConfig.certDomain
    @State private var host = ServerConfig.installHost
    @State private var dnsLoopback: Bool?
    @State private var checking = false
    @State private var saved = false

    private var cleanDomain: String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "*.", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/."))
    }
    private var cleanHost: String {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return h.isEmpty ? (cleanDomain == ServerConfig.defaultDomain ? ServerConfig.defaultInstallHost : "mr.\(cleanDomain)") : h
    }
    private var domainOK: Bool { cleanDomain.contains(".") && !cleanDomain.contains(" ") }
    private var hostOK: Bool { domainOK && (cleanHost.hasSuffix("." + cleanDomain) || cleanHost == cleanDomain) }

    var body: some View {
        TableScreen(title: "Install host & DNS") {
            Section {
                if st.mode != "public" { TField(label: "Domain", text: $domain, placeholder: "example.com", keyboard: .URL) }
                TField(label: "Install host", text: $host, placeholder: ServerConfig.defaultInstallHost, keyboard: .URL)
            } footer: {
                Text(st.mode == "public"
                     ? "On Cloudflare, *.zefv.dev points at the VPS, so the OTA host is the dedicated mr.zefv.dev A record → 127.0.0.1 (DNS only). One label under the wildcard, so the *.zefv.dev cert covers it."
                     : "The install host must resolve to 127.0.0.1 via an A record — iOS silently drops the install prompt otherwise. The cert must cover it (wildcard *.<domain> covers any single label).")
                .foregroundStyle(Theme.subtle)
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: checking ? "hourglass" : (dnsLoopback == true ? "checkmark.circle.fill" : (dnsLoopback == false ? "xmark.octagon.fill" : "questionmark.circle")))
                        .foregroundStyle(dnsLoopback == true ? .green : (dnsLoopback == false ? .red : Theme.subtle))
                    Text(checking ? "Resolving \(cleanHost)…"
                         : dnsLoopback == true ? "\(cleanHost) → 127.0.0.1"
                         : dnsLoopback == false ? "\(cleanHost) does not resolve to 127.0.0.1"
                         : "Not checked").font(.subheadline).foregroundStyle(Theme.text)
                    Spacer()
                }
                .listRowBackground(Theme.card)
                TButton(title: "Check DNS", icon: "arrow.clockwise", busy: checking, enabled: domainOK) { Task { await check() } }
            } header: {
                Text("DNS")
            }

            Section {
                if !domainOK { TStatusRow(ok: false, text: "Enter a domain like example.com") }
                else if !hostOK { TStatusRow(ok: false, text: "Host must be under \(cleanDomain).") }
                else if !st.sans.isEmpty, !ZefvCert.covers(cleanHost, sans: st.sans) { TStatusRow(ok: false, text: "Cert covers \(st.sans.joined(separator: ", ")) — not \(cleanHost).") }
                TButton(title: saved ? "Saved" : "Save", icon: saved ? "checkmark.circle.fill" : "square.and.arrow.down", enabled: hostOK) {
                    ServerConfig.setCertDomain(cleanDomain); ServerConfig.setInstallHost(cleanHost)
                    domain = ServerConfig.certDomain; host = ServerConfig.installHost; saved = true
                    st.reload(); UINotificationFeedbackGenerator().notificationOccurred(.success)
                    Task { await check() }
                }
            }
        }
        .onChange(of: host) { _ in saved = false; dnsLoopback = nil }
        .onChange(of: domain) { _ in saved = false; dnsLoopback = nil }
        .task { await check() }
    }

    private func check() async {
        guard domainOK else { return }
        checking = true; dnsLoopback = await ZefvCert.resolvesToLoopback(cleanHost); checking = false
    }
}

// MARK: - zefv.dev certificate (VPS)

private struct VPSCertScreen: View {
    @ObservedObject var st: OTAState
    @State private var sourceURL = ServerConfig.certSourceURL
    @State private var sourceToken = ServerConfig.certSourceToken
    @State private var sourceSaved = false
    @State private var refreshing = false
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        TableScreen(title: "zefv.dev certificate") {
            Section {
                HStack { Text("Status").foregroundStyle(Theme.subtle); Spacer(); certPill(ZefvCert.effectiveNotAfter) }.listRowBackground(Theme.card)
                TRow(k: "In use", v: st.cached ? "Pulled from VPS" : "Bundled in IPA")
                TRow(k: "Covers", v: ZefvCert.effectiveSANs.isEmpty ? "—" : ZefvCert.effectiveSANs.joined(separator: ", "))
                TRow(k: "Expires", v: ZefvCert.effectiveNotAfter.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                TRow(k: "Last pull", v: st.fetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never")
            }

            Section {
                TButton(title: refreshing ? "Fetching…" : "Pull latest from VPS", icon: "arrow.down.circle", busy: refreshing) { Task { await refresh() } }
                if st.cached { TButton(title: "Forget pulled copy (use bundled)", icon: "trash", role: .destructive) { ZefvCert.clearCache(); st.reload() } }
                if let error { TStatusRow(ok: false, text: error) }
                if let note { TStatusRow(ok: true, text: note) }
            } footer: {
                Text("certbot on the VPS renews *.zefv.dev through the Cloudflare DNS API; the app auto-pulls on install when within \(ServerConfig.refreshBufferDays) days of expiry. Pull latest forces it now.").foregroundStyle(Theme.subtle)
            }

            Section {
                TField(label: "URL", text: $sourceURL, placeholder: ServerConfig.defaultCertSourceURL, keyboard: .URL)
                TField(label: "Token", text: $sourceToken, placeholder: ServerConfig.defaultCertSourceToken, keyboard: .asciiCapable)
                TButton(title: sourceSaved ? "Saved" : "Save source", icon: sourceSaved ? "checkmark.circle.fill" : "server.rack") {
                    ServerConfig.setCertSourceURL(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines))
                    ServerConfig.setCertSourceToken(sourceToken.trimmingCharacters(in: .whitespacesAndNewlines))
                    sourceURL = ServerConfig.certSourceURL; sourceToken = ServerConfig.certSourceToken; sourceSaved = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } header: {
                Text("Cert source")
            }
        }
        .onChange(of: sourceURL) { _ in sourceSaved = false }
        .onChange(of: sourceToken) { _ in sourceSaved = false }
    }

    private func refresh() async {
        refreshing = true; error = nil; note = nil
        do {
            _ = try await ZefvCert.fetch()
            OTAFiles.exportPublicChain(); st.reload()
            note = "Pulled from \(URL(string: ServerConfig.certSourceURL)?.host ?? "VPS")"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = error.localizedDescription }
        refreshing = false
    }
}

// MARK: - Own certificate

private struct OwnCertScreen: View {
    @ObservedObject var st: OTAState
    @State private var showPicker = false
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        TableScreen(title: "Own certificate") {
            Section {
                HStack { Text("Status").foregroundStyle(Theme.subtle); Spacer(); if st.hasCustom { certPill(ZefvCert.customNotAfter) } else { Text("MISSING").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(.orange) } }.listRowBackground(Theme.card)
                if st.hasCustom {
                    TRow(k: "Covers", v: ZefvCert.customSANs.joined(separator: ", "))
                    TRow(k: "Expires", v: ZefvCert.customNotAfter.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    if !ZefvCert.covers(st.host, sans: ZefvCert.customSANs) { TStatusRow(ok: false, text: "Doesn't cover \(st.host) — change the install host or import a cert for it.") }
                }
            } footer: {
                Text("Bring the cert you already have for your domain — Let's Encrypt, ZeroSSL, Cloudflare Origin, anything iOS trusts. Pick the fullchain (.pem/.crt) and the private key (.pem/.key), or one combined PEM. The key must be unencrypted PEM; it stays on this device.").foregroundStyle(Theme.subtle)
            }
            Section {
                TButton(title: st.hasCustom ? "Replace cert + key" : "Import cert + key", icon: "square.and.arrow.down") { error = nil; note = nil; showPicker = true }
                if st.hasCustom { TButton(title: "Remove imported cert", icon: "trash", role: .destructive) { ZefvCert.clearCustom(); st.reload() } }
                if let error { TStatusRow(ok: false, text: error) }
                if let note { TStatusRow(ok: true, text: note) }
            } footer: {
                Text("Nothing renews automatically in this mode — when the cert expires, import the renewed pair.").foregroundStyle(Theme.subtle)
            }
        }
        .sheet(isPresented: $showPicker) {
            DocPicker(types: [.item]) { urls in
                guard !urls.isEmpty else { return }
                do {
                    try ZefvCert.importCustom(files: urls)
                    OTAFiles.exportPublicChain()
                    note = "Imported \(urls.count) file\(urls.count == 1 ? "" : "s")."
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch { self.error = error.localizedDescription }
                st.reload()
            }
        }
    }
}

// MARK: - Exported files

private struct OTAFilesScreen: View {
    @ObservedObject var st: OTAState
    @Environment(\.openURL) private var openURL
    @State private var share: URLItem?

    var body: some View {
        TableScreen(title: "Exported files") {
            Section {
                TRow(k: "Folder", v: "Files › On My iPhone › mSign › OTA Certs")
                if let u = OTAFiles.filesAppURL {
                    TButton(title: "Open in Files", icon: "folder") { openURL(u) }
                }
                TButton(title: "Export again", icon: "arrow.triangle.2.circlepath") {
                    if st.mode == "local" { OTAFiles.exportLocalCA() } else { OTAFiles.exportPublicChain() }
                    st.reload(); UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
            Section {
                if st.files.isEmpty {
                    Text("Nothing exported yet.").foregroundStyle(Theme.subtle).listRowBackground(Theme.card)
                }
                ForEach(st.files, id: \.path) { u in
                    Button { share = URLItem(url: u) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: u.pathExtension == "mobileconfig" ? "doc.badge.gearshape" : (u.pathExtension == "txt" ? "doc.text" : "doc.badge.ellipsis"))
                                .foregroundStyle(Theme.accent).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(u.lastPathComponent).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                Text(sizeString(u)).font(.caption).foregroundStyle(Theme.subtle)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.subtle)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
            } header: {
                Text("Files")
            }
            if !st.files.isEmpty {
                Section { TButton(title: "Clear folder", icon: "trash", role: .destructive) { OTAFiles.clear(); st.reload() } }
            }
        }
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
    }

    private func sizeString(_ u: URL) -> String {
        let n = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - Local CA

private struct LocalCAScreen: View {
    @ObservedObject var st: OTAState
    @State private var host = ServerConfig.installHost
    @State private var working = false
    @State private var error: String?
    @State private var note: String?
    @State private var showProfileText = false
    @State private var share: URLItem?
    @State private var dnsLoopback: Bool?
    @State private var dnsChecking = false
    @State private var confirmDelete = false

    private var cleanHost: String {
        Config.clean(host).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "*.", with: "").lowercased()
    }

    var body: some View {
        TableScreen(title: "Local CA") {
            Section {
                TRow(k: "Root CA", v: st.hasRoot ? "ready" : "not created", tint: st.hasRoot ? .green : .orange)
                TRow(k: "Leaf", v: st.hasLeaf ? "issued for \(LocalCAManager.meta?.host ?? "—")" : "not issued", tint: st.hasLeaf ? .green : .orange)
                TStatusRow(ok: st.rootTrusted, text: st.rootTrusted ? "Root profile installed & trusted on this device" : "Root profile not trusted on this device yet")
                TButton(title: "Re-check trust", icon: "arrow.clockwise") { st.reload() }
            } footer: {
                Text("Generates a root CA on this device (OpenSSL), signs a leaf for your OTA host, and serves installs with it. Private keys stay in the Keychain (ThisDeviceOnly) — public certs are mirrored to iCloud Keychain so a reinstall keeps the same root.").foregroundStyle(Theme.subtle)
            }

            Section {
                TField(label: "OTA host", text: $host, placeholder: ServerConfig.defaultInstallHost, keyboard: .URL)
                HStack(spacing: 10) {
                    Image(systemName: dnsChecking ? "hourglass" : (dnsLoopback == true ? "checkmark.circle.fill" : (dnsLoopback == false ? "xmark.octagon.fill" : "questionmark.circle")))
                        .foregroundStyle(dnsLoopback == true ? .green : (dnsLoopback == false ? .red : Theme.subtle))
                    Text(dnsChecking ? "Resolving…" : dnsLoopback == true ? "\(cleanHost) → 127.0.0.1" : dnsLoopback == false ? "\(cleanHost) does not resolve to 127.0.0.1" : "DNS not checked")
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Spacer()
                    Button("Check") { Task { await checkDNS() } }.font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .listRowBackground(Theme.card)
                TButton(title: working ? "Working…" : (st.hasLeaf ? "Re-issue leaf for host" : "Create CA & issue leaf"), icon: "checkmark.seal.fill", busy: working) { Task { await issue() } }
            } header: {
                Text("1 · Host & leaf")
            } footer: {
                Text("The leaf covers this host and *.<host>. The host must ALSO resolve to 127.0.0.1 (A record, or a free name like 127-0-0-1.nip.io) or the install prompt never appears.").foregroundStyle(Theme.subtle)
            }

            if st.hasRoot {
                Section {
                    TButton(title: "Install trust profile", icon: "square.and.arrow.down") {
                        OTAFiles.exportLocalCA()
                        if let u = LocalCAManager.writeMobileConfig() { share = URLItem(url: u) } else { error = "Couldn't build the profile." }
                        st.reload()
                    }
                    TButton(title: "View profile contents", icon: "doc.text.magnifyingglass") { showProfileText = true }
                } header: {
                    Text("2 · Trust profile")
                } footer: {
                    Text("One payload: the root cert as a trusted-root payload. Unsigned, plain text. After installing, enable it in Settings › General › About › Certificate Trust Settings — the status above flips green on its own.").foregroundStyle(Theme.subtle)
                }

                Section {
                    TRow(k: "Subject", v: "MRvEK Local Root CA")
                    TRow(k: "Fingerprint", v: fingerprint)
                    if let m = LocalCAManager.meta {
                        TRow(k: "Created", v: m.rootCreated.formatted(date: .abbreviated, time: .shortened))
                        TRow(k: "Leaf issued", v: m.leafIssued.formatted(date: .abbreviated, time: .shortened))
                    }
                    TRow(k: "Leaf expires", v: LocalCAManager.leafExpiry.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    TRow(k: "Key storage", v: "Keychain · ThisDeviceOnly")
                } header: {
                    Text("Root details")
                }

                Section {
                    TButton(title: "Delete local CA", icon: "trash", role: .destructive) { confirmDelete = true }
                }
            }

            if let error { Section { TStatusRow(ok: false, text: error) } }
            if let note { Section { TStatusRow(ok: true, text: note) } }
        }
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
        .sheet(isPresented: $showProfileText) { ProfileInspector(text: profileXML) }
        .confirmationDialog("Delete the local CA?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete root + leaf", role: .destructive) { LocalCAManager.reset(); OTAFiles.clear(); st.reload(); note = "Local CA deleted." }
        } message: { Text("Installs signed by this root stop being trusted. Remove the profile from Settings afterwards.") }
        .task { await checkDNS() }
    }

    private var profileXML: String {
        LocalCAManager.mobileConfig().flatMap { String(data: $0, encoding: .utf8) } ?? "(no profile — create the CA first)"
    }
    private var fingerprint: String {
        guard let der = LocalCAManager.rootDER() else { return "—" }
        return SHA256.hash(data: der).prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":") + "…"
    }

    private func checkDNS() async {
        dnsChecking = true; dnsLoopback = await ZefvCert.resolvesToLoopback(cleanHost); dnsChecking = false
    }

    private func issue() async {
        working = true; error = nil; note = nil
        let h = cleanHost
        guard h.contains(".") else { error = "Enter a host like \(ServerConfig.defaultInstallHost)"; working = false; return }
        do {
            try LocalCAManager.issueLeaf(host: h)
            ServerConfig.setInstallHost(h)
            ServerConfig.setCertMode("local")
            OTAFiles.exportLocalCA()
            st.reload()
            await checkDNS()
            note = dnsLoopback == false
                ? "Root + leaf ready for \(h) and exported to Files — but \(h) does NOT resolve to 127.0.0.1, so the install sheet won't appear until it does."
                : "Root + leaf ready for \(h) and exported to Files. Install the trust profile next."
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
