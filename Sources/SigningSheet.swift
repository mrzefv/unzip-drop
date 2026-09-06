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

struct SigningSheet: View {
    let ipaURL: URL
    let meta: IPAMeta
    var onSigned: (SignedEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var certs = CertificateStore.shared

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

    // signing
    @State private var signing = false
    @State private var log: [String] = []
    @State private var error: String?
    @State private var result: SignedEntry?
    @State private var installing = false

    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)

    struct DylibItem: Identifiable, Equatable { let id = UUID(); let url: URL; var weak = false }
    struct ExtraToggles {
        var disableATS = false, forceMinIOS12 = false, disableFileSharing = false, forcePortrait = false, skipIPad = false
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
                VStack(alignment: .leading, spacing: 22) {
                    signingMethod
                    appIcon
                    identity
                    buildOptions
                    dylibInjection
                    changesSummary
                    if !log.isEmpty { logCard }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 4) }
                    if let r = result { signedCard(r) }
                    Spacer(minLength: 20)
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { signBar.background(BarBlur()) }
        }
        .background(Color.black.ignoresSafeArea())
        .task { machoDylibs = await currentDylibs() }
        .sheet(isPresented: $showDylibPicker) {
            DocPicker(types: [UTType(filenameExtension: "dylib") ?? .item, UTType(filenameExtension: "framework") ?? .item, UTType(filenameExtension: "deb") ?? .item]) { urls in
                for u in urls { dylibs.append(DylibItem(url: u)) }
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
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Color(white: 0.16)).clipShape(Circle())
            }
            Spacer()
            HStack(spacing: 10) {
                iconThumb(iconPNG ?? meta.iconPNG, side: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Text(bundle).font(.system(size: 12)).foregroundStyle(blue).lineLimit(1)
                }
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Color(white: 0.16)).clipShape(Circle())
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .background(BarBlur())
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)
    }

    // MARK: Signing method

    private var signingMethod: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("SIGNING METHOD")
            if let c = certs.active {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("USING YOUR SAVED CERTIFICATE").font(.system(size: 12, weight: .bold)).foregroundStyle(blue)
                        Text(c.name).font(.system(size: 18, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        Text(certSubtitle(c)).font(.system(size: 13)).foregroundStyle(Theme.subtle)
                    }
                    Spacer()
                }
                .padding(16)
                .background(Color(red: 0.03, green: 0.06, blue: 0.12))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(blue.opacity(0.6), lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Text("No active certificate. Settings › Certificates to import a .p12 + .mobileprovision.")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func certSubtitle(_ c: Certificate) -> String {
        let info = (try? Data(contentsOf: c.provisionURL)).map(CertificateStore.profileInfo)
        var parts: [String] = []
        if let t = info??.team { parts.append("Team \(t)") }
        if let e = info??.expires { parts.append("Expires " + e.formatted(date: .abbreviated, time: .omitted)) }
        return parts.isEmpty ? "On-device certificate" : parts.joined(separator: " · ")
    }

    // MARK: Icon

    private var appIcon: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("APP ICON")
            Button { showIconPicker = true } label: {
                HStack(spacing: 16) {
                    iconThumb(iconPNG ?? meta.iconPNG, side: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(iconPNG == nil ? "Replace app icon" : "Icon replaced").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        Text("PNG/JPEG — auto-resized to required sizes").font(.system(size: 13)).foregroundStyle(Theme.subtle)
                    }
                    Spacer()
                    if iconPNG != nil { Button { iconPNG = nil } label: { Image(systemName: "arrow.uturn.backward").foregroundStyle(blue) } }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke, style: StrokeStyle(lineWidth: 1.5, dash: [6])))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("APP NAME · BUNDLE ID · VERSION")
            VStack(spacing: 0) {
                identRow("Aa", "Name", $name)
                divider
                identRow("shippingbox.fill", "Bundle ID", $bundle, mono: true)
                divider
                identRow("number", "Version", $version, mono: true)
            }
            .background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func identRow(_ icon: String, _ label: String, _ text: Binding<String>, mono: Bool = false) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(blue.opacity(0.15)).frame(width: 40, height: 40)
                if icon == "Aa" { Text("Aa").font(.system(size: 15, weight: .bold)).foregroundStyle(blue) }
                else { Image(systemName: icon).foregroundStyle(blue) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.subtle)
                TextField(label, text: text)
                    .font(.system(size: 17, design: mono ? .monospaced : .default)).foregroundStyle(.white)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }
        }
        .padding(14)
    }

    // MARK: Build options (collapsible groups)

    private var buildOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("BUILD OPTIONS")
            group("general", "slider.horizontal.3", "General", badge: generalCount > 0 ? "\(generalCount) active" : nil) {
                toggle("Disable ATS (allow HTTP)", $o.disableATS)
                toggle("Skip embedded provision", Binding(get: { false }, set: { _ in }), disabled: true, note: "on-device signer always embeds")
            }
            group("strip", "scissors", "Strip Content", badge: "\(stripCount)") {
                toggle("Strip SC_Info", $o.stripSCInfo)
                toggle("Strip privacy manifests", $o.stripPrivacy)
                toggle("Remove Watch app", $o.stripWatch)
                toggle("Remove app extensions (PlugIns)", $o.stripExtensions)
                toggle("Remove URL schemes", $o.removeURLSchemes)
            }
            group("plist", "doc.fill", "Info.plist Tweaks", badge: "\(plistCount)") {
                toggle("Force MinimumOSVersion 12.0", $o.forceMinIOS12)
                toggle("Disable file sharing", $o.disableFileSharing)
                toggle("Force portrait only", $o.forcePortrait)
                toggle("iPhone only (skip iPad)", $o.skipIPad)
            }
        }
    }

    private var generalCount: Int { o.disableATS ? 1 : 0 }
    private var stripCount: Int { [o.stripSCInfo, o.stripPrivacy, o.stripWatch, o.stripExtensions, o.removeURLSchemes].filter { $0 }.count }
    private var plistCount: Int { [o.forceMinIOS12, o.disableFileSharing, o.forcePortrait, o.skipIPad].filter { $0 }.count }

    @ViewBuilder
    private func group<C: View>(_ key: String, _ icon: String, _ title: String, badge: String?, @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) {
            Button { withAnimation { if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) } } } label: {
                HStack(spacing: 14) {
                    ZStack { RoundedRectangle(cornerRadius: 9).fill(blue.opacity(0.15)).frame(width: 40, height: 40); Image(systemName: icon).foregroundStyle(blue) }
                    Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    if let b = badge {
                        Text(b).font(.system(size: 13, weight: .bold)).foregroundStyle(b.contains("active") ? blue : Theme.subtle)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color(white: 0.14)).clipShape(Capsule())
                    }
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.subtle)
                        .rotationEffect(.degrees(expanded.contains(key) ? 180 : 0))
                }
                .padding(14)
            }
            .buttonStyle(.plain)
            if expanded.contains(key) {
                VStack(spacing: 0) { content() }.padding(.bottom, 6)
            }
        }
        .background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func toggle(_ label: String, _ b: Binding<Bool>, disabled: Bool = false, note: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 15)).foregroundStyle(disabled ? Theme.subtle : .white)
                if let n = note { Text(n).font(.caption2).foregroundStyle(Theme.subtle) }
            }
            Spacer()
            Toggle("", isOn: b).labelsHidden().tint(blue).disabled(disabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: Dylib injection

    private var dylibInjection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("DYLIB INJECTION")
            VStack(alignment: .leading, spacing: 14) {
                segRow("Inject Path", ["@executable_path": "@executable", "@rpath": "@rpath"], $injectPath)
                segRow("Inject Folder", ["/": "/", "Frameworks/": "Frameworks/"], $injectFolder)

                Text("\(injectPath)/\(injectFolder == "/" ? "" : "Frameworks/")xxx.dylib")
                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.subtle)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.06)).clipShape(RoundedRectangle(cornerRadius: 10))

                ForEach($dylibs) { $d in
                    HStack(spacing: 12) {
                        Button { dylibs.removeAll { $0.id == d.id } } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 26)).foregroundStyle(.red)
                        }
                        Text(d.url.lastPathComponent).font(.system(size: 16, design: .monospaced)).foregroundStyle(.white).lineLimit(1)
                        Spacer()
                        Toggle("weak", isOn: $d.weak).labelsHidden().tint(blue)
                    }
                    .padding(12).background(Color(white: 0.10)).clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if !machoDylibs.isEmpty {
                    DisclosureGroup {
                        ForEach(machoDylibs, id: \.self) { d in
                            HStack {
                                Image(systemName: removeDylibs.contains(d) ? "checkmark.square.fill" : "square").foregroundStyle(removeDylibs.contains(d) ? .red : Theme.subtle)
                                Text(d).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1).truncationMode(.middle)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if removeDylibs.contains(d) { removeDylibs.remove(d) } else { removeDylibs.insert(d) } }
                            .padding(.vertical, 4)
                        }
                    } label: {
                        Text("Existing load commands (\(machoDylibs.count)) — tap to strip").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.subtle)
                    }
                    .tint(blue)
                    .padding(12).background(Color(white: 0.06)).clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button { showDylibPicker = true } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.subtle)
                        Text("Add library (.dylib, .framework)").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        Text("Tap to browse").font(.system(size: 12)).foregroundStyle(Theme.subtle)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 26)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke, style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                }
                .buttonStyle(.plain)
            }
            .padding(16).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    private func segRow(_ label: String, _ opts: [String: String], _ sel: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 16)).foregroundStyle(.white).frame(width: 108, alignment: .leading)
            ForEach(opts.sorted(by: { $0.key < $1.key }), id: \.key) { k, title in
                Button { sel.wrappedValue = k } label: {
                    Text(title).font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .padding(.vertical, 10).frame(maxWidth: .infinity)
                        .background(sel.wrappedValue == k ? blue.opacity(0.18) : Color(white: 0.1))
                        .foregroundStyle(sel.wrappedValue == k ? blue : Theme.subtle)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(sel.wrappedValue == k ? blue : Theme.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        let build = strip + plistList + (o.disableATS ? ["Disable ATS"] : [])
        return Group {
            if ident.isEmpty && dy.isEmpty && build.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("CHANGES TO BE APPLIED")
                    VStack(alignment: .leading, spacing: 12) {
                        if !ident.isEmpty { summaryBlock("square.on.square", "Identity", ident) }
                        if !dy.isEmpty { summaryBlock("syringe", "Dylibs", dy) }
                        if !build.isEmpty { summaryBlock("slider.horizontal.3", "Build options", build) }
                    }
                    .padding(16).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 18))
                }
            }
        }
    }

    private var strip: [String] {
        [o.stripSCInfo ? "Strip SC_Info" : nil, o.stripPrivacy ? "Strip privacy manifests" : nil,
         o.stripWatch ? "Remove Watch app" : nil, o.stripExtensions ? "Remove extensions" : nil,
         o.removeURLSchemes ? "Remove URL schemes" : nil].compactMap { $0 }
    }
    private var plistList: [String] {
        [o.forceMinIOS12 ? "MinimumOSVersion 12.0" : nil, o.disableFileSharing ? "Disable file sharing" : nil,
         o.forcePortrait ? "Force portrait" : nil, o.skipIPad ? "iPhone only" : nil].compactMap { $0 }
    }

    private func summaryBlock(_ icon: String, _ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Image(systemName: icon).foregroundStyle(blue); Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(.white); Spacer(); Text("\(items.count)").foregroundStyle(Theme.subtle) }
            ForEach(items, id: \.self) { Text("· \($0)").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.subtle) }
        }
    }

    // MARK: Log + signed

    private var logCard: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(l.hasPrefix(">>>") ? blue : (l.lowercased().contains("error") ? .orange : Theme.subtle)).id(i)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 160).background(Color(white: 0.05)).clipShape(RoundedRectangle(cornerRadius: 12))
            .onChange(of: log.count) { _ in if let l = log.indices.last { proxy.scrollTo(l, anchor: .bottom) } }
        }
    }

    private func signedCard(_ r: SignedEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Signed \(r.name) v\(r.version)").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(r.certName).font(.caption).foregroundStyle(Theme.subtle)
            }
            Spacer()
            Button { Task { await install(r) } } label: {
                HStack { if installing { ProgressView().tint(.black) } else { Image(systemName: "arrow.down.app.fill") }; Text("Install").fontWeight(.bold) }
                    .padding(.horizontal, 16).padding(.vertical, 10).background(Color.green).foregroundStyle(.black).clipShape(Capsule())
            }.disabled(installing)
        }
        .padding(14).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Sign bar

    private var signBar: some View {
        Button { Task { await sign() } } label: {
            HStack(spacing: 10) {
                if signing { ProgressView().tint(.white) } else { Image(systemName: "signature").font(.system(size: 18, weight: .bold)) }
                Text(signing ? "Signing…" : "Sign IPA").font(.system(size: 18, weight: .bold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(certs.active == nil ? Theme.subtle : blue).foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .disabled(signing || certs.active == nil)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
    }

    // MARK: Helpers

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .bold)).kerning(1).foregroundStyle(Theme.subtle)
    }
    private var divider: some View { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 68) }

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
        s.bundleID = bundle.isEmpty ? nil : bundle
        s.version = version.isEmpty ? nil : version
        s.iconPNG = iconPNG
        s.injectDylibs = dylibs.map { ($0.url, $0.weak) }
        s.injectPath = injectPath; s.injectFolder = injectFolder
        s.removeDylibs = Array(removeDylibs)
        s.forceMinIOS = o.forceMinIOS12 ? "12.0" : nil
        s.disableFileSharing = o.disableFileSharing
        s.forcePortrait = o.forcePortrait
        s.skipIPad = o.skipIPad
        s.disableATS = o.disableATS
        s.stripSCInfo = o.stripSCInfo
        s.stripPrivacyManifests = o.stripPrivacy
        s.stripWatchApps = o.stripWatch
        s.stripExtensions = o.stripExtensions
        s.removeURLSchemes = o.removeURLSchemes
        return s
    }

    private func sign() async {
        guard let material = try? certs.activeMaterial() else { error = "No active certificate."; return }
        signing = true; error = nil; result = nil
        log = [">>> Signing \(name) with \(material.name)"]
        do {
            let outcome = try await Signer.signDetached(ipaURL: ipaURL, material: material, options: buildOptionsValue(),
                                                        onLog: { line in Task { @MainActor in log.append(line) } })
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
        installing = true; error = nil
        do { try await OTAInstaller.shared.install(r) } catch { self.error = error.localizedDescription }
        installing = false
    }
}

// MARK: - Document picker

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
