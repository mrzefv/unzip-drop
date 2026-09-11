//
//  SigningSheet.swift
//  Full-screen signing sheet in the mSign layout: signing method (active cert),
//  app icon replace, name/bundle/version, build-option groups (General, Strip
//  Content, Entitlement/Info tweaks), dylib injection with @executable/@rpath +
//  folder pickers, a "Changes to be applied" summary, and a Sign IPA bar.
//  Everything is applied on-device by SignEngine.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

struct SigningSheet: View {
    let ipaURL: URL
    let meta: IPAMeta
    var onSigned: (SignedEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var certs = CertificateStore.shared
    @ObservedObject private var ota = OTAInstaller.shared

    // identity
    @State private var name: String
    @State private var bundle: String
    @State private var version: String
    @State private var iconPNG: Data?
    @State private var showIconPicker = false

    // dylibs
    @State private var injectPath = "@executable_path"
    @State private var injectFolder = "/"
    @State private var dylibs: [DylibItem] = []
    @State private var removeDylibs: Set<String> = []
    @State private var machoDylibs: [String] = []
    @State private var showDylibPicker = false

    // toggles
    @State private var o = ExtraToggles()
    @State private var expanded: Set<String> = ["general"]

    // mSign-style signing method selector (Saved / Enterprise / Apple ID).
    // "saved" is fully wired; the others are UI placeholders to plug in later.
    @AppStorage("uzd_signing_method") private var method = "saved"   // saved | enterprise | appleid
    @State private var enterpriseName = ""
    @State private var appleIDEmail = ""
    @State private var showBundleInfo = false
    @State private var bundleInfoMode: BundleInfoEditorSheet.Mode = .entitlements
    @State private var entitlementValues: [String: String] = [:]
    @State private var entitlementTypeHints: [String: String] = [:]
    @State private var plistSetValues: [String: String] = [:]

    // binary analysis
    @State private var macho: MachOReport?
    @State private var machoError: String?

    // signing
    @State private var signing = false
    @State private var showTerminal = false
    @State private var log: [String] = []
    @State private var lastEntitlements: [String: String] = [:]
    @State private var lastSizeBytes: Int64 = 0
    @State private var showInstallPrompt = false
    @State private var sentToHome = false
    @State private var error: String?
    @State private var result: SignedEntry?
    @State private var installing = false

    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)
    private let accent = Color(red: 0.74, green: 0.22, blue: 0.12)
    private let accentSoft = Color(red: 0.89, green: 0.44, blue: 0.27)
    private let accentTint = Color(red: 0.21, green: 0.08, blue: 0.07)
    private let surface = Color(red: 0.06, green: 0.06, blue: 0.07)
    private let surfaceRaised = Color(red: 0.09, green: 0.09, blue: 0.10)
    private let success = Color(red: 0.45, green: 0.79, blue: 0.34)

    struct DylibItem: Identifiable, Equatable { let id = UUID(); let url: URL; var weak = false }
    struct ExtraToggles {
        var removeExistingLibraries = false, thinToArm64Only = false, randomizeBundleID = false, disableATS = false
        var weakDylibReferences = false, sha256Only = false, forceResign = true, surgicalMode = true
        var forceMinIOS12 = false, disableFileSharing = false, forcePortrait = false, skipIPad = false
        var stripSCInfo = false, stripPrivacy = false, stripWatch = false, stripExtensions = false, removeURLSchemes = false
        var replaceIcon = true
    }

    init(ipaURL: URL, meta: IPAMeta, onSigned: @escaping (SignedEntry) -> Void) {
        self.ipaURL = ipaURL; self.meta = meta; self.onSigned = onSigned
        _name = State(initialValue: meta.name)
        _bundle = State(initialValue: meta.bundleID)
        _version = State(initialValue: meta.version)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16.5) {
                    signingMethodCard        // mSign: Saved / Enterprise / Apple ID
                    appIcon
                    identity                 // App metadata: name / bundle / version
                    buildOptions             // 4 collapsible categories
                    bundleInfoCard           // Entitlements · Info.plist (view)
                    binaryCard               // Mach-O / binary analysis
                    dylibInjection
                    changesSummary
                    if let error { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 3) }
                    if ota.tracing { tracingCard }
                    if let rep = ota.lastReport { reportCard(rep) }
                    Spacer(minLength: 15)
                }
                .padding(12)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { signBar.floatingGlassBar(edge: .bottom) }
        }
        .background(Color.black.ignoresSafeArea())
        .fullScreenCover(isPresented: $showTerminal) {
            SigningTerminalView(
                appName: name, bundle: bundle, icon: iconPNG ?? meta.iconPNG,
                lines: $log, done: Binding(get: { !signing && (result != nil || error != nil) }, set: { _ in }),
                result: result, error: error,
                onInstall: { _ in showInstallPrompt = true },
                onExit: { showTerminal = false }
            )
            .preferredColorScheme(.dark)
            .overlay {
                if sentToHome {
                    SentToHomeOverlay(name: name, icon: iconPNG ?? meta.iconPNG, host: ServerConfig.installHost)
                        .transition(.opacity)
                }
            }
            .overlay {
                if showInstallPrompt, let r = result {
                    InstallPromptOverlay(
                        name: r.name, bundle: r.bundleID, version: r.version,
                        sizeBytes: lastSizeBytes, icon: iconPNG ?? meta.iconPNG,
                        source: sourceLabel,
                        mdid: CertificateStore.knownUDID(certName: certs.active?.name) ?? "",
                        cert: certs.active?.name ?? "",
                        entitlements: lastEntitlements,
                        onInstall: { showInstallPrompt = false; Task { await install(r) } },
                        onCancel: { showInstallPrompt = false }
                    )
                }
            }
        }
        .task {
            machoDylibs = await currentDylibs()
            await analyzeBinary()
        }
        .sheet(isPresented: $showDylibPicker) {
            DocPicker(types: [UTType(filenameExtension: "dylib") ?? .item, UTType(filenameExtension: "framework") ?? .item, UTType(filenameExtension: "deb") ?? .item]) { urls in
                for u in urls { dylibs.append(DylibItem(url: u)) }
            }
        }
        .sheet(isPresented: $showBundleInfo) {
            BundleInfoEditorSheet(
                mode: bundleInfoMode,
                entitlements: $entitlementValues,
                infoPlistSet: $plistSetValues
            ) { removedKey in
                entitlementTypeHints.removeValue(forKey: removedKey)
            }
        }
        .sheet(isPresented: $showIconPicker) {
            DocPicker(types: [.png, .jpeg, .image]) { urls in
                if let u = urls.first, let d = try? Data(contentsOf: u), let img = UIImage(data: d) {
                    iconPNG = img.pngData()
                }
            }
        }
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(spacing: 12) {
            titleBarButton("chevron.left")
            HStack(spacing: 11) {
                iconThumb(iconPNG ?? meta.iconPNG, side: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Text(bundle).font(.system(size: 10.5, weight: .medium)).foregroundStyle(accent).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            titleBarButton("xmark")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    private func titleBarButton(_ icon: String) -> some View {
        Button { dismiss() } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(surfaceRaised)
                .clipShape(Circle())
        }
    }

    // MARK: Bundle info (mSign: Entitlements · Info.plist)

    private var bundleInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BUNDLE INFO")
            VStack(spacing: 0) {
                bundleRow("Entitlements", "key.fill", entitlementValues.isEmpty ? "View" : "\(entitlementValues.count)") {
                    if entitlementValues.isEmpty { loadEntitlementsFromActiveProfile() }
                    bundleInfoMode = .entitlements
                    showBundleInfo = true
                }
                Divider().overlay(Theme.stroke).padding(.leading, 39)
                bundleRow("Info.plist", "doc.text.fill", plistSetValues.isEmpty ? "View" : "\(plistSetValues.count)") {
                    bundleInfoMode = .infoPlist
                    showBundleInfo = true
                }
                Divider().overlay(Theme.stroke).padding(.leading, 39)
                bundleRow("Mach-O dependencies", "point.3.connected.trianglepath.dotted", macho.map { "\($0.arm64?.dylibs.count ?? 0)" } ?? "—") {}
            }
            .background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func bundleRow(_ title: String, _ icon: String, _ trailing: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack { RoundedRectangle(cornerRadius: 7).fill(blue.opacity(0.15)).frame(width: 19, height: 25.5); Image(systemName: icon).foregroundStyle(blue).font(.system(size: 10.5)) }
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Text(trailing).font(.caption.weight(.semibold)).foregroundStyle(Theme.subtle)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.subtle)
            }
            .padding(10.5)
        }
        .buttonStyle(.plain)
    }

    // MARK: Binary analysis (hand-rolled Mach-O reader)

    private var binaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BINARY")
            if let r = macho {
                VStack(alignment: .leading, spacing: 7.5) {
                    HStack(spacing: 6) {
                        Image(systemName: r.encrypted ? "lock.fill" : "lock.open.fill").foregroundStyle(r.encrypted ? .red : .green)
                        Text(r.encrypted ? "FairPlay ENCRYPTED — will not run after re-sign" : "Decrypted — safe to re-sign")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(r.encrypted ? .red : .green)
                        Spacer()
                        Text(r.isFat ? "FAT" : "THIN").font(.system(size: 7, weight: .heavy, design: .monospaced)).kerning(0.5)
                            .padding(.horizontal, 4.5).padding(.vertical, 2).background(Color(white: 0.16)).foregroundStyle(Theme.subtle).clipShape(Capsule())
                    }
                    ForEach(r.slices) { sl in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(sl.arch).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(blue)
                                Text(sl.fileType).font(.caption).foregroundStyle(Theme.subtle)
                                if sl.pie { tagSmall("PIE") }
                                if sl.hasCodeSignature { tagSmall("SIGNED \(ByteCountFormatter.string(fromByteCount: Int64(sl.codeSignatureSize), countStyle: .file))") }
                                Spacer()
                            }
                            kvSmall("Min OS", (sl.platform ?? "") + " " + (sl.minOS ?? "—") + (sl.sdk.map { " · SDK \($0)" } ?? ""))
                            kvSmall("Encryption", sl.encrypted ? "cryptid=\(sl.cryptID) (ENCRYPTED)" : "cryptid=0 (clear)")
                            kvSmall("Links", "\(sl.dylibs.count) dylibs · \(sl.weakDylibs.count) weak · \(sl.rpaths.count) rpaths")
                            if !sl.dylibs.isEmpty {
                                DisclosureGroup {
                                    ForEach(sl.dylibs + sl.weakDylibs.map { "(weak) " + $0 }, id: \.self) { d in
                                        Text(d).font(.system(size: 7.5, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1).truncationMode(.middle)
                                    }
                                } label: { Text("Show load commands").font(.caption).foregroundStyle(blue) }
                                .tint(blue)
                            }
                        }
                        .padding(7.5).background(Color(white: 0.06)).clipShape(RoundedRectangle(cornerRadius: 7.5))
                    }
                    ForEach(r.warnings, id: \.self) { w in
                        HStack(alignment: .top, spacing: 4.5) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                            Text(w).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(10.5).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(r.encrypted ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1))
            } else if let e = machoError {
                Text(e).font(.caption).foregroundStyle(.orange).padding(10.5).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(spacing: 7.5) { ProgressView().tint(blue); Text("Reading Mach-O headers…").font(.caption).foregroundStyle(Theme.subtle) }
                    .padding(10.5).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func tagSmall(_ s: String) -> some View {
        Text(s).font(.system(size: 7, weight: .heavy, design: .monospaced)).kerning(0.5)
            .padding(.horizontal, 4.5).padding(.vertical, 2).background(blue.opacity(0.15)).foregroundStyle(blue).clipShape(Capsule())
    }
    private func kvSmall(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 4.5) {
            Text(k).font(.caption2).foregroundStyle(Theme.subtle).frame(width: 39.5, alignment: .leading)
            Text(v).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white)
        }
    }

    private func analyzeBinary() async {
        let url = ipaURL
        // Return only Sendable values across the detached boundary (Result<_, Error>
        // is not Sendable under strict concurrency).
        let outcome: (report: MachOReport?, error: String?) = await Task.detached {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("macho-" + UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: work) }
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: work)
                let payload = work.appendingPathComponent("Payload", isDirectory: true)
                guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
                    return (nil, "No .app inside the IPA.")
                }
                return (try MachOInspector.inspect(appBundle: app), nil)
            } catch {
                return (nil, "Couldn't analyze binary: \(error.localizedDescription)")
            }
        }.value
        if let r = outcome.report { macho = r } else { machoError = outcome.error }
    }

    // MARK: Signing method

    // mSign-style signing method: a selector (Saved / Enterprise / Apple ID)
    // over a body whose accent + content changes with the choice.
    private var signingMethodCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("SIGNING METHOD")
            savedBody
        }
    }

    private var sourceLabel: String { ServerConfig.installHost }

    @ViewBuilder private var savedBody: some View {
        if let c = certs.active {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(accentTint)
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(accentSoft).font(.system(size: 18, weight: .bold))
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("USING YOUR SAVED CERTIFICATE").font(.system(size: 8.5, weight: .heavy)).kerning(1.1).foregroundStyle(accentSoft)
                        Text(c.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(certSubtitle(c)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.subtle).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal, 6)
                HStack(alignment: .top, spacing: 0) {
                    detailTile(
                        icon: "globe",
                        iconColor: blue,
                        iconBackground: blue.opacity(0.16),
                        title: "DISTRIBUTED IDENTITY",
                        titleColor: blue,
                        primary: ServerConfig.installHost,
                        secondary: "https://\(ServerConfig.installHost)",
                        tertiary: "This is the public URL where your app will be available."
                    )
                    Rectangle().fill(Theme.stroke).frame(width: 1).padding(.vertical, 18)
                    detailTile(
                        icon: "lock.fill",
                        iconColor: success,
                        iconBackground: success.opacity(0.16),
                        title: "CERTIFICATE",
                        titleColor: success,
                        primary: ServerConfig.certMode == "local" ? "Local CA" : (ServerConfig.certMode == "custom" ? "Own cert" : "Let's Encrypt"),
                        secondary: certStatusTitle,
                        tertiary: certStatusSubtitle
                    )
                }
                .background(surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .padding(12)
            .background(surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(accent.opacity(0.45), lineWidth: 1.2))
        } else {
            HStack(spacing: 7.5) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("No certificate — import one in Settings › Certificates.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Icon

    private var certDaysLeft: Int? {
        if ServerConfig.certMode == "local" { return LocalCAManager.leafDaysLeft }
        return ZefvCert.effectiveNotAfter.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 }
    }

    private func certSubtitle(_ c: Certificate) -> String {
        let info = (try? Data(contentsOf: c.provisionURL)).map(CertificateStore.profileInfo) ?? ProfileInfo()
        var parts: [String] = []
        if let t = info.team { parts.append("Team \(t)") }
        if let e = info.expires { parts.append("Expires " + e.formatted(date: .abbreviated, time: .omitted)) }
        return parts.isEmpty ? "On-device certificate" : parts.joined(separator: " · ")
    }

    private var certStatusTitle: String {
        guard let d = certDaysLeft else { return "Unknown" }
        return d < 0 ? "Expired" : "Valid"
    }

    private var certStatusSubtitle: String {
        guard let d = certDaysLeft else { return "Expiry unavailable" }
        let label = d == 1 ? "day" : "days"
        if let date = ZefvCert.effectiveNotAfter {
            return d < 0 ? "Expired \(date.formatted(date: .abbreviated, time: .omitted))" : "Expires in \(d) \(label) (\(date.formatted(date: .abbreviated, time: .omitted)))"
        }
        return d < 0 ? "Expired" : "Expires in \(d) \(label)"
    }

    private func detailTile(icon: String, iconColor: Color, iconBackground: Color, title: String, titleColor: Color, primary: String, secondary: String, tertiary: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(iconBackground)
                    Image(systemName: icon).foregroundStyle(iconColor).font(.system(size: 18, weight: .semibold))
                }
                .frame(width: 44, height: 44)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 8.5, weight: .heavy)).kerning(1.1).foregroundStyle(titleColor)
                Text(primary).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                Text(secondary).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(titleColor)
                Divider().overlay(Theme.stroke)
                Text(tertiary).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.subtle)
            }
            HStack {
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.subtle)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appIcon: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("APP ICON")
            Button { showIconPicker = true } label: {
                HStack(spacing: 12) {
                    iconThumb(iconPNG ?? meta.iconPNG, side: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(iconPNG == nil ? "Replace app icon" : "Icon replaced").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        Text("PNG/JPEG — auto-resized to required sizes").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.subtle)
                    }
                    Spacer()
                    if iconPNG != nil {
                        Button { iconPNG = nil } label: {
                            Image(systemName: "arrow.uturn.backward").foregroundStyle(accentSoft).font(.system(size: 16, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.subtle)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [6])))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("APP NAME · BUNDLE ID · VERSION")
            VStack(spacing: 0) {
                identRow("Aa", "Name", $name)
                divider
                identRow("shippingbox.fill", "Bundle ID", $bundle, mono: true)
                divider
                identRow("number", "Version", $version, mono: true)
            }
            .background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func identRow(_ icon: String, _ label: String, _ text: Binding<String>, mono: Bool = false) -> some View {
        HStack(spacing: 10.5) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accentTint).frame(width: 32, height: 32)
                if icon == "Aa" { Text("Aa").font(.system(size: 13, weight: .bold)).foregroundStyle(accentSoft) }
                else { Image(systemName: icon).foregroundStyle(accentSoft) }
            }
            VStack(alignment: .leading, spacing: 1.5) {
                Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.88))
                TextField(label, text: text)
                    .font(.system(size: 12, weight: .medium, design: mono ? .monospaced : .default)).foregroundStyle(.white)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }
        }
        .padding(12)
    }

    // MARK: Build options (collapsible groups)

    private var buildOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BUILD OPTIONS")
            group("general", "slider.horizontal.3", "General", badge: generalCount > 0 ? "\(generalCount) active" : nil) {
                toggle("Remove existing libraries", $o.removeExistingLibraries, note: "Strip pre-existing dylibs and frameworks before injection")
                toggle("Thin to arm64 only", Binding(get: { false }, set: { _ in }), disabled: true, note: "coming soon")
                toggle("Randomize bundle ID", $o.randomizeBundleID, note: "append a random suffix so it can coexist with the original app")
                toggle("Disable ATS (allow HTTP)", $o.disableATS)
                toggle("Weak dylib references", $o.weakDylibReferences, note: "use LC_LOAD_WEAK_DYLIB for injected libraries")
                toggle("Remove Watch apps", $o.stripWatch)
                toggle("SHA256 only", Binding(get: { false }, set: { _ in }), disabled: true, note: "coming soon")
                toggle("Force re-sign", Binding(get: { true }, set: { _ in }), disabled: true, note: "always on in current signer")
                toggle("Surgical mode", $o.surgicalMode, note: "70–85% faster; auto-disabled when injecting dylibs")
            }
            group("strip", "scissors", "Strip Content", badge: "\(stripCount)") {
                toggle("Strip SC_Info", $o.stripSCInfo)
                toggle("Strip privacy manifests", $o.stripPrivacy)
                toggle("Remove app extensions (PlugIns)", $o.stripExtensions)
                toggle("Remove URL schemes", $o.removeURLSchemes)
            }
            group("plist", "key.fill", "Entitlement Scrubbers", badge: "\(plistCount)") {
                toggle("Force MinimumOSVersion 12.0", $o.forceMinIOS12)
                toggle("Disable file sharing", $o.disableFileSharing)
                toggle("Force portrait only", $o.forcePortrait)
                toggle("iPhone only (skip iPad)", $o.skipIPad)
            }
        }
    }

    private var generalCount: Int {
        [o.removeExistingLibraries, o.randomizeBundleID, o.disableATS, o.weakDylibReferences, o.stripWatch, o.surgicalMode].filter { $0 }.count
    }
    private var stripCount: Int { [o.stripSCInfo, o.stripPrivacy, o.stripExtensions, o.removeURLSchemes].filter { $0 }.count }
    private var plistCount: Int { [o.forceMinIOS12, o.disableFileSharing, o.forcePortrait, o.skipIPad].filter { $0 }.count }

    @ViewBuilder
    private func group<C: View>(_ key: String, _ icon: String, _ title: String, badge: String?, @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) {
            Button { withAnimation { if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) } } } label: {
                HStack(spacing: 10.5) {
                    ZStack { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accentTint).frame(width: 32, height: 32); Image(systemName: icon).foregroundStyle(accentSoft) }
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    if let b = badge {
                        Text(b).font(.system(size: 10, weight: .bold)).foregroundStyle(b.contains("active") ? accentSoft : Theme.subtle)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.white.opacity(0.06)).clipShape(Capsule())
                    }
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.subtle)
                        .rotationEffect(.degrees(expanded.contains(key) ? 180 : 0))
                }
                .padding(10.5)
            }
            .buttonStyle(.plain)
            if expanded.contains(key) {
                VStack(spacing: 0) { content() }.padding(.bottom, 4.5)
            }
        }
        .background(surfaceRaised).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func toggle(_ label: String, _ b: Binding<Bool>, disabled: Bool = false, note: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(label).font(.system(size: 11)).foregroundStyle(disabled ? Theme.subtle : .white)
                if let n = note { Text(n).font(.caption2).foregroundStyle(Theme.subtle) }
            }
            Spacer()
            Toggle("", isOn: b).labelsHidden().tint(accent).disabled(disabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: Dylib injection

    private var dylibInjection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("DYLIB INJECTION")
            VStack(alignment: .leading, spacing: 10.5) {
                segRow("Inject Path", ["@executable_path": "@executable", "@rpath": "@rpath"], $injectPath)
                segRow("Inject Folder", ["/": "/", "Frameworks/": "Frameworks/"], $injectFolder)

                Text("\(injectPath)/\(injectFolder == "/" ? "" : "Frameworks/")xxx.dylib")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.subtle)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.06)).clipShape(RoundedRectangle(cornerRadius: 7.5))

                ForEach($dylibs) { $d in
                    HStack(spacing: 9) {
                        Button { dylibs.removeAll { $0.id == d.id } } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 19.5)).foregroundStyle(.red)
                        }
                        Text(d.url.lastPathComponent).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white).lineLimit(1)
                        Spacer()
                        Toggle("weak", isOn: $d.weak).labelsHidden().tint(blue)
                    }
                    .padding(9).background(Color(white: 0.10)).clipShape(RoundedRectangle(cornerRadius: 9))
                }

                if !machoDylibs.isEmpty {
                    DisclosureGroup {
                        ForEach(machoDylibs, id: \.self) { d in
                            HStack {
                                Image(systemName: removeDylibs.contains(d) ? "checkmark.square.fill" : "square").foregroundStyle(removeDylibs.contains(d) ? .red : Theme.subtle)
                                Text(d).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1).truncationMode(.middle)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if removeDylibs.contains(d) { removeDylibs.remove(d) } else { removeDylibs.insert(d) } }
                            .padding(.vertical, 3)
                        }
                    } label: {
                        Text("Existing load commands (\(machoDylibs.count)) — tap to strip").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.subtle)
                    }
                    .tint(blue)
                    .padding(9).background(Color(white: 0.06)).clipShape(RoundedRectangle(cornerRadius: 9))
                }

                Button { showDylibPicker = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 19.5, weight: .bold)).foregroundStyle(Theme.subtle)
                        Text("Add library (.dylib, .framework)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Text("Tap to browse").font(.system(size: 9)).foregroundStyle(Theme.subtle)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 19.5)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [6])))
                }
                .buttonStyle(.plain)
            }
            .padding(12).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 13.5))
        }
    }

    private func segRow(_ label: String, _ opts: [String: String], _ sel: Binding<String>) -> some View {
        HStack(spacing: 7.5) {
            Text(label).font(.system(size: 12)).foregroundStyle(.white).frame(width: 61, alignment: .leading)
            ForEach(opts.sorted(by: { $0.key < $1.key }), id: \.key) { k, title in
                Button { sel.wrappedValue = k } label: {
                    Text(title).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .padding(.vertical, 7.5).frame(maxWidth: .infinity)
                        .background(sel.wrappedValue == k ? blue.opacity(0.18) : Color(white: 0.1))
                        .foregroundStyle(sel.wrappedValue == k ? blue : Theme.subtle)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(sel.wrappedValue == k ? blue : Theme.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Changes summary

    private var changesSummary: some View {
        let ident = [name != meta.name ? "Name → \(name)" : nil,
                     bundle != meta.bundleID ? "Bundle → \(bundle)" : nil,
                     version != meta.version ? "Version → \(version)" : nil,
                     iconPNG != nil ? "Replace icon" : nil].compactMap { $0 }
        let dy = dylibs.map { "Inject \($0.url.lastPathComponent)" } + removeDylibs.map { "Remove \(($0 as NSString).lastPathComponent)" }
        let build = strip + plistList + generalSummary
        return Group {
            if ident.isEmpty && dy.isEmpty && build.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("CHANGES TO BE APPLIED")
                    VStack(alignment: .leading, spacing: 9) {
                        if !ident.isEmpty { summaryBlock("square.on.square", "Identity", ident) }
                        if !dy.isEmpty { summaryBlock("syringe", "Dylibs", dy) }
                        if !build.isEmpty { summaryBlock("slider.horizontal.3", "Build options", build) }
                    }
                    .padding(12).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 13.5))
                }
            }
        }
    }

    private var strip: [String] {
        [o.stripSCInfo ? "Strip SC_Info" : nil, o.stripPrivacy ? "Strip privacy manifests" : nil,
         o.stripExtensions ? "Remove extensions" : nil,
         o.removeURLSchemes ? "Remove URL schemes" : nil].compactMap { $0 }
    }
    private var generalSummary: [String] {
        [o.removeExistingLibraries ? "Remove existing libraries" : nil,
         o.randomizeBundleID ? "Randomize bundle ID" : nil,
         o.disableATS ? "Disable ATS" : nil,
         o.weakDylibReferences ? "Weak dylib references" : nil,
         o.stripWatch ? "Remove Watch apps" : nil,
         o.surgicalMode ? (dylibs.isEmpty ? "Surgical mode" : "Surgical mode (auto-disabled: dylibs)") : nil].compactMap { $0 }
    }
    private var plistList: [String] {
        [o.forceMinIOS12 ? "MinimumOSVersion 12.0" : nil, o.disableFileSharing ? "Disable file sharing" : nil,
         o.forcePortrait ? "Force portrait" : nil, o.skipIPad ? "iPhone only" : nil].compactMap { $0 }
        + plistSetValues.sorted(by: { $0.key < $1.key }).map { "Info.plist: \($0.key)=\($0.value)" }
    }

    private func summaryBlock(_ icon: String, _ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Image(systemName: icon).foregroundStyle(blue); Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.white); Spacer(); Text("\(items.count)").foregroundStyle(Theme.subtle) }
            ForEach(items, id: \.self) { Text("· \($0)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.subtle) }
        }
    }

    // MARK: Log + signed

    private var tracingCard: some View {
        HStack(spacing: 7.5) {
            ProgressView().tint(blue)
            Text("Watching installd… tap Install in the iOS sheet. Report in ~25s.").font(.caption).foregroundStyle(Theme.subtle)
        }
        .padding(10.5).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 10.5))
    }

    private func reportCard(_ r: OTAInstaller.Report) -> some View {
        VStack(alignment: .leading, spacing: 7.5) {
            HStack {
                Label("Install trace", systemImage: "waveform.path.ecg").font(.headline).foregroundStyle(.white)
                Spacer()
                Text(r.delivered ? "IPA DELIVERED" : "NOT DELIVERED")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced)).kerning(0.5)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background((r.delivered ? Color.green : Color.orange).opacity(0.18))
                    .foregroundStyle(r.delivered ? .green : .orange).clipShape(Capsule())
            }
            if r.requests.isEmpty {
                Text("installd made no requests.").font(.caption).foregroundStyle(.orange)
            } else {
                ForEach(r.requests) { e in
                    HStack(spacing: 6) {
                        Image(systemName: e.status == 200 ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(e.status == 200 ? .green : .orange).font(.caption)
                        Text(e.path).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file)).font(.caption2.monospaced()).foregroundStyle(Theme.subtle)
                    }
                }
            }
            Text(r.diagnosis).font(.system(size: 10)).foregroundStyle(.white)
            if let p = r.profileNote {
                Text(p).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.subtle)
            }
        }
        .padding(10.5).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 10.5))
    }

    // MARK: Sign bar

    private var signBar: some View {
        Button { Task { await sign() } } label: {
            HStack(spacing: 7.5) {
                if signing { ProgressView().tint(.white) } else { Image(systemName: "signature").font(.system(size: 13.5, weight: .bold)) }
                Text(signing ? "Signing…" : "Sign IPA").font(.system(size: 13.5, weight: .bold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(certs.active == nil || macho?.encrypted == true ? Theme.subtle : accent).foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .disabled(signing || certs.active == nil || macho?.encrypted == true)
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4.5)
    }

    // MARK: Helpers

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .bold)).kerning(2).foregroundStyle(.white.opacity(0.72))
    }
    private var divider: some View { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 51) }

    private func iconThumb(_ data: Data?, side: CGFloat) -> some View {
        Group {
            if let data, let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: side * 0.22).fill(blue.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(blue)) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }

    private func currentDylibs() async -> [String] {
        let url = ipaURL
        return await Task.detached { () -> [String] in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("peek-" + UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: work) }
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: work)
                let payload = work.appendingPathComponent("Payload", isDirectory: true)
                guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else { return [] }
                let bin = (NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))?["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
                return ZsignSigner.listDylibs(inMachO: app.appendingPathComponent(bin).path)
                    .filter { !$0.hasPrefix("/System") && !$0.hasPrefix("/usr/lib") }
            } catch { return [] }
        }.value
    }

    private func buildOptionsValue() -> SignOptions {
        var s = SignOptions()
        s.name = name.isEmpty ? nil : name
        // Override only when the user changed it (mSign passes the field through as-is
        // once it differs from the read value; unchanged → let the signer keep the app's own).
        let b = bundle.trimmingCharacters(in: .whitespaces)
        var bundleOut = (b.isEmpty || b == meta.bundleID) ? nil : b
        if o.randomizeBundleID {
            let base = (bundleOut ?? (b.isEmpty ? meta.bundleID : b)).trimmingCharacters(in: .whitespaces)
            if !base.isEmpty { bundleOut = base + "." + randomSuffix(6) }
        }
        s.bundleID = bundleOut
        s.version = version.isEmpty ? nil : version
        s.iconPNG = iconPNG
        s.injectDylibs = dylibs.map { ($0.url, o.weakDylibReferences ? true : $0.weak) }
        s.injectPath = injectPath; s.injectFolder = injectFolder
        s.removeDylibs = Array(Set((o.removeExistingLibraries ? machoDylibs : []) + Array(removeDylibs)))
        s.plistSet = plistSetValues
        s.forceMinIOS = o.forceMinIOS12 ? "12.0" : nil
        s.disableFileSharing = o.disableFileSharing
        s.forcePortrait = o.forcePortrait
        s.skipIPad = o.skipIPad
        s.disableATS = o.disableATS
        s.surgicalMode = o.surgicalMode
        s.stripSCInfo = o.stripSCInfo
        s.stripPrivacyManifests = o.stripPrivacy
        s.stripWatchApps = o.stripWatch
        s.stripExtensions = o.stripExtensions
        s.removeURLSchemes = o.removeURLSchemes
        s.entitlementsPlistData = encodedEntitlementsPlistData()
        return s
    }

    private func loadEntitlementsFromActiveProfile() {
        guard let material = try? certs.activeMaterial() else { return }
        let parsed = parseProvisionEntitlements(provision: material.provision)
        entitlementValues = parsed.values
        entitlementTypeHints = parsed.typeHints
    }

    private func parseProvisionEntitlements(provision: Data) -> (values: [String: String], typeHints: [String: String]) {
        guard let xml = xmlPlistData(fromMobileProvision: provision),
              let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any] else {
            return ([:], [:])
        }
        var values: [String: String] = [:]
        var hints: [String: String] = [:]
        for (k, v) in ent {
            values[k] = stringifyEntitlementValue(v)
            if v is Bool { hints[k] = "bool" }
            else if v is NSNumber { hints[k] = "number" }
            else if v is [Any] { hints[k] = "array" }
            else { hints[k] = "string" }
        }
        return (values, hints)
    }

    private func encodedEntitlementsPlistData() -> Data? {
        guard !entitlementValues.isEmpty else { return nil }
        var dict: [String: Any] = [:]
        for (k, raw) in entitlementValues {
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch entitlementTypeHints[k] {
            case "bool":
                dict[k] = (v.lowercased() == "true")
            case "number":
                if let i = Int(v) { dict[k] = i }
                else if let d = Double(v) { dict[k] = d }
                else { dict[k] = v }
            case "array":
                dict[k] = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            default:
                if v.lowercased() == "true" { dict[k] = true }
                else if v.lowercased() == "false" { dict[k] = false }
                else { dict[k] = v }
            }
        }
        return try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private func stringifyEntitlementValue(_ value: Any) -> String {
        if let b = value as? Bool { return b ? "true" : "false" }
        if let s = value as? String { return s }
        if let arr = value as? [String] { return arr.joined(separator: ", ") }
        if let arr = value as? [Any] { return arr.map { "\($0)" }.joined(separator: ", ") }
        return "\(value)"
    }

    private func xmlPlistData(fromMobileProvision data: Data) -> Data? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }

    private func randomSuffix(_ count: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<count).compactMap { _ in chars.randomElement() })
    }

    private func sign() async {
        showTerminal = true
        // Let the terminal cover paint before the blocking zsign work begins — no lag.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 60_000_000)   // ~1 frame
        if let r = macho, r.encrypted {
            error = "This IPA is still FairPlay-encrypted (cryptid ≠ 0). Signing it will produce an app that crashes at launch. Get a decrypted IPA first."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        guard let material = try? certs.activeMaterial() else { error = "No active certificate."; return }
        signing = true; error = nil; result = nil
        log = [">>> Signing \(name) with \(material.name)"]
        do {
            let outcome = try await Signer.signDetached(ipaURL: ipaURL, material: material, options: buildOptionsValue(),
                                                        onLog: { line in Task { @MainActor in log.append(line) } })
            lastEntitlements = outcome.entitlements
            lastSizeBytes = outcome.sizeBytes
            let entry = try SignedStore.shared.add(outcome: outcome, icon: iconPNG ?? meta.iconPNG, certName: material.name)
            result = entry
            onSigned(entry)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = error.localizedDescription
            log.append("error: \(error.localizedDescription)")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        signing = false
    }

    private func install(_ r: SignedEntry) async {
        error = nil
        do {
            try await OTAInstaller.shared.install(r)
            log.append("✓ Install triggered — confirm on your home screen")
            withAnimation { sentToHome = true }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation { sentToHome = false }
        } catch {
            self.error = error.localizedDescription
            log.append("error: install failed — \(error.localizedDescription)")
        }
    }
}

// MARK: - Document picker

struct BundleInfoEditorSheet: View {
    enum Mode { case entitlements, infoPlist }

    let mode: Mode
    @Binding var entitlements: [String: String]
    @Binding var infoPlistSet: [String: String]
    var onRemoveEntitlement: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if mode == .entitlements {
                    KeyValueEditorList(
                        title: "Entitlements",
                        values: $entitlements,
                        addLabel: "Add entitlement key",
                        onRemoveKey: onRemoveEntitlement
                    )
                } else {
                    KeyValueEditorList(
                        title: "Info.plist",
                        values: $infoPlistSet,
                        addLabel: "Add Info.plist key"
                    )
                }
            }
            .navigationTitle(mode == .entitlements ? "Entitlements (\(entitlements.count))" : "Info.plist (\(infoPlistSet.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct KeyValueEditorList: View {
    let title: String
    @Binding var values: [String: String]
    let addLabel: String
    var onRemoveKey: ((String) -> Void)? = nil

    @State private var newKey = ""
    @State private var newValue = "true"

    private var sortedKeys: [String] { values.keys.sorted() }

    var body: some View {
        List {
            ForEach(sortedKeys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 6) {
                    Text(key).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    TextField("Value", text: Binding(
                        get: { values[key] ?? "" },
                        set: { values[key] = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15))
                }
                .padding(.vertical, 6)
                .listRowBackground(Color(white: 0.08))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        values.removeValue(forKey: key)
                        onRemoveKey?(key)
                    } label: { Label("Remove", systemImage: "minus.circle.fill") }
                }
            }

            Section {
                VStack(spacing: 8) {
                    TextField("Key", text: $newKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Value", text: $newValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let k = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty else { return }
                        values[k] = newValue
                        newKey = ""
                        newValue = "true"
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                            Text(addLabel)
                            Spacer()
                        }
                    }
                }
                .font(.system(size: 15))
                .padding(.vertical, 8)
            }
            .listRowBackground(Color(white: 0.08))
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
    }
}

struct DocPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        p.allowsMultipleSelection = true
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(onPick: onPick) }

    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

// MARK: - Signing terminal (mSign-style full-screen zsign log)

struct SigningTerminalView: View {
    let appName: String
    let bundle: String
    let icon: Data?
    @Binding var lines: [String]
    @Binding var done: Bool
    let result: SignedEntry?
    let error: String?
    var onInstall: (SignedEntry) -> Void
    var onExit: () -> Void

    private let accent = Color(red: 1.0, green: 0.60, blue: 0.10)   // MRZefv orange
    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.08))
                logScroll
                if done { bottomBar }
            }
        }
    }

    // Icon left · name+bundle centre · X right
    private var header: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                iconThumb(44)
                ZStack {
                    Circle().fill(Color.black).frame(width: 20, height: 20)
                    if done {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.45))
                    } else {
                        ProgressView().tint(accent).scaleEffect(0.65)
                    }
                }
                .offset(x: 5, y: 5)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(appName).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(bundle).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.40)).lineLimit(1)
            }
            Spacer()
            Button(action: onExit) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        .background(Color(white: 0.06))
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                        Text(raw)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(color(for: raw))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 1)
                    }
                    if !done { TerminalCursor(color: accent) }
                    Color.clear.frame(height: done ? 100 : 20).id("BOTTOM")
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            .onChange(of: done) { _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
        .background(Color.black)
    }

    // Download · branding · Install
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.10))
            HStack(spacing: 0) {
                Button {
                    if let r = result { UIActivityViewController.share(r.ipaURL) }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 26))
                        Text("Download").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(blue).frame(maxWidth: .infinity)
                }
                .disabled(result == nil)

                VStack(spacing: 2) {
                    Text("ᴍʀZefv").font(.system(size: 14, weight: .bold)).foregroundStyle(accent)
                    Text("Powered by DELvEK.NET").font(.system(size: 9, weight: .semibold)).foregroundStyle(blue)
                }
                .frame(maxWidth: .infinity)

                Button {
                    guard let r = result else { return }
                    onInstall(r)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "signature").font(.system(size: 26))
                        Text(result == nil ? "Sign IPA" : "Install").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(result == nil ? Color.white.opacity(0.35) : blue).frame(maxWidth: .infinity)
                }
                .disabled(result == nil)
            }
            .padding(.top, 12).padding(.bottom, 6)
            .background(Color(white: 0.06))
        }
    }

    private func iconThumb(_ side: CGFloat) -> some View {
        Group {
            if let icon, let img = UIImage(data: icon) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(accent)) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }

    // mSign's log coloring
    private func color(for raw: String) -> Color {
        let l = raw.lowercased()
        if raw.contains("Signed OK") || raw.contains("Done.") || raw.contains("ready to install") { return Color(red: 0.2, green: 1.0, blue: 0.45) }
        if raw.contains("Success!") { return Color(red: 0.35, green: 0.95, blue: 0.45) }
        if l.contains("error") || l.contains("failed") || raw.contains("❌") { return .red.opacity(0.9) }
        if raw.contains("No Enough CodeSignature") || raw.contains("Realloc") { return accent }
        if raw.contains("SignFolder:") { return Color(red: 0.45, green: 0.85, blue: 1.0) }
        if raw.contains("SignFile:") { return .white.opacity(0.6) }
        if raw.contains("Packaging") || raw.contains("Packaged") { return Color(red: 0.55, green: 0.75, blue: 1.0) }
        if raw.hasPrefix(">>>") { return .white.opacity(0.85) }
        return .white.opacity(0.75)
    }
}

struct TerminalCursor: View {
    let color: Color
    @State private var on = true
    var body: some View {
        Rectangle().fill(color).frame(width: 9, height: 15)
            .opacity(on ? 1 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { on = false } }
    }
}

extension UIActivityViewController {
    static func share(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first?.present(vc, animated: true)
    }
}

// MARK: - Install prompt (mSign-style pre-install detail card)

struct InstallPromptOverlay: View {
    let name: String
    let bundle: String
    let version: String
    let sizeBytes: Int64
    let icon: Data?
    let source: String
    var mdid: String = ""
    var cert: String = ""
    let entitlements: [String: String]
    var onInstall: () -> Void
    var onCancel: () -> Void

    @State private var showSandboxing = false
    @State private var showCapabilities = false
    @State private var showContainers = false
    @State private var copied = false

    private let accent = Color(red: 1.0, green: 0.60, blue: 0.10)
    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)

    private var sizeText: String { sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : "—" }
    private var isUnsandboxed: Bool { entitlements["platform-application"] == "true" || entitlements["com.apple.security.app-sandbox"] == "false" }
    private var sandboxLabel: String { isUnsandboxed ? "Unsandboxed (platform-application active)" : "Standard iOS sandbox — app restricted to its container" }
    private var capabilityKeys: [String] {
        let skip: Set<String> = ["application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups", "com.apple.security.application-groups", "platform-application", "get-task-allow"]
        return entitlements.keys.filter { !skip.contains($0) }.sorted().map {
            $0.replacingOccurrences(of: "com.apple.developer.", with: "")
              .replacingOccurrences(of: "com.apple.security.", with: "")
              .replacingOccurrences(of: "com.apple.", with: "")
        }
    }
    private var appGroups: [String] { (entitlements["com.apple.security.application-groups"] ?? "").components(separatedBy: ", ").filter { !$0.isEmpty } }
    private var keychainGroups: [String] { (entitlements["keychain-access-groups"] ?? "").components(separatedBy: ", ").filter { !$0.isEmpty } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { onCancel() }
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        header
                        Divider().overlay(Color.white.opacity(0.10))
                        info
                        section("Sandboxing", $showSandboxing) {
                            Text(sandboxLabel).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                        }
                        section("Capabilities", $showCapabilities) {
                            if capabilityKeys.isEmpty { Text("None").font(.caption).foregroundStyle(Theme.subtle) }
                            else { ForEach(capabilityKeys.prefix(40), id: \.self) { bullet($0) } }
                        }
                        section("Accessible Containers", $showContainers) {
                            if !appGroups.isEmpty {
                                Text("App Groups").font(.system(size: 12, weight: .bold)).foregroundStyle(blue)
                                ForEach(appGroups, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.7)) }
                            }
                            if !keychainGroups.isEmpty {
                                Text("Keychain Groups").font(.system(size: 12, weight: .bold)).foregroundStyle(blue).padding(.top, 6)
                                ForEach(keychainGroups, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.7)) }
                            }
                            if appGroups.isEmpty && keychainGroups.isEmpty { Text("None").font(.caption).foregroundStyle(Theme.subtle) }
                        }
                        Text("\(source) | ᴍʀZefv").font(.system(size: 12, weight: .semibold)).foregroundStyle(blue).padding(.vertical, 12)
                    }
                }
                .frame(maxHeight: 520)
                Divider().overlay(Color.white.opacity(0.10))
                HStack(spacing: 0) {
                    Button(action: onCancel) { Text("Cancel").font(.system(size: 16)).foregroundStyle(blue).frame(maxWidth: .infinity).padding(.vertical, 14) }
                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1)
                    Button(action: onInstall) { Text("Install").font(.system(size: 16, weight: .bold)).foregroundStyle(blue).frame(maxWidth: .infinity).padding(.vertical, 14) }
                }
            }
            .background(Color(white: 0.11)).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: 360)
            .padding(24)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            iconThumb(64)
            Text(name).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2)
        }
        .padding(.top, 20).padding(.bottom, 12)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Bundle ID", bundle)
            row("Version", version)
            row("Size", sizeText)
            HStack(alignment: .top, spacing: 4) {
                Text("Partner:").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).frame(width: 72, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reputable Repository").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                    Text(source).font(.system(size: 10, design: .monospaced)).foregroundStyle(accent.opacity(0.75))
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = source
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copied = false } }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                        .foregroundStyle(copied ? Color(red: 0.2, green: 1, blue: 0.45) : accent.opacity(0.65)).frame(width: 28, height: 28)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            if !mdid.isEmpty { row("MDID", mdid) }
            if !cert.isEmpty { row("Cert", cert) }
        }
        .padding(.vertical, 6)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(k + ":").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).frame(width: 72, alignment: .leading)
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    @ViewBuilder private func section<C: View>(_ title: String, _ open: Binding<Bool>, @ViewBuilder content: () -> C) -> some View {
        Divider().overlay(Color.white.opacity(0.08))
        Button { withAnimation { open.wrappedValue.toggle() } } label: {
            HStack {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.5)).rotationEffect(.degrees(open.wrappedValue ? 180 : 0))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }.buttonStyle(.plain)
        if open.wrappedValue {
            VStack(alignment: .leading, spacing: 5) { content() }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(blue).frame(width: 6, height: 6).padding(.top, 6)
            Text(s).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).truncationMode(.tail)
            Spacer()
        }
    }

    private func iconThumb(_ side: CGFloat) -> some View {
        Group {
            if let icon, let img = UIImage(data: icon) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 15).fill(accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(accent)) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.08)))
    }
}

// MARK: - "Sent to Home Screen" success overlay (mSign-style)

struct SentToHomeOverlay: View {
    let name: String
    let icon: Data?
    let host: String
    @State private var progress: CGFloat = 0

    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    iconThumb(78)
                    ZStack {
                        Circle().fill(Color.black).frame(width: 28, height: 28)
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 26))
                            .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.45))
                    }
                    .offset(x: 6, y: 6)
                }
                Text(name).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Text("Sent to Home Screen").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(host).font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color(white: 0.18)).clipShape(Capsule())
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12)).frame(height: 6)
                        Capsule().fill(blue).frame(width: g.size.width * progress, height: 6)
                    }
                }
                .frame(height: 6).padding(.horizontal, 24).padding(.top, 4)
            }
            .padding(.vertical, 28).padding(.horizontal, 28)
            .frame(maxWidth: 320)
            .background(Color(white: 0.11)).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onAppear { withAnimation(.easeInOut(duration: 2.4)) { progress = 1 } }
        }
    }

    private func iconThumb(_ side: CGFloat) -> some View {
        Group {
            if let icon, let img = UIImage(data: icon) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: side * 0.22).fill(blue.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(blue)) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }
}
