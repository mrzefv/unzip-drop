//
//  SignView.swift
//  Sign tab — take an unsigned .ipa (from Files, or handed over by the Build
//  tab), sign it on-device with zsign using the active certificate, then
//  install it over the loopback HTTPS OTA server (itms-services).
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SignView: View {
    @ObservedObject private var certs  = CertificateStore.shared
    @ObservedObject private var signed = SignedStore.shared
    @ObservedObject private var queue  = SignQueue.shared

    @State private var ipaURL: URL?
    @State private var meta: IPAMeta?
    @State private var reading = false

    @State private var nameOverride = ""
    @State private var bundleOverride = ""
    @State private var versionOverride = ""

    @State private var signing = false
    @State private var log: [String] = []
    @State private var error: String?
    @State private var lastSigned: SignedEntry?
    @State private var installing: String?
    @State private var share: URLItem?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Sign").font(.title2.bold()).foregroundStyle(Theme.text)
                        Spacer()
                        certPill
                    }
                    sourceCard
                    if meta != nil { overridesCard; actionCard }
                    if !log.isEmpty { logCard }
                    if let error { Card { Text(error).font(.caption).foregroundStyle(.orange) } }
                    historySection
                }
                .padding(16)
            }
        }
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
        .onAppear { consumeQueue() }
        .onChange(of: queue.pending) { _ in consumeQueue() }
    }

    // MARK: Header pill

    private var certPill: some View {
        HStack(spacing: 6) {
            Circle().fill(certs.active == nil ? Color.orange : Theme.accent).frame(width: 8, height: 8)
            Text(certs.active?.name ?? "No cert").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.subtle).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card).clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }

    // MARK: Source

    private var sourceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Unsigned IPA", systemImage: "app.dashed").font(.headline).foregroundStyle(Theme.text)
                if let meta, let ipaURL {
                    HStack(spacing: 12) {
                        iconView(meta.iconPNG, side: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meta.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(meta.bundleID).font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                            Text("v\(meta.version) · \(sizeString(ipaURL))").font(.caption).foregroundStyle(Theme.subtle)
                        }
                        Spacer()
                        Button { clear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.subtle) }
                    }
                } else {
                    Text("Pick an .ipa from Files, or download a build artifact in the Build tab and it lands here. Installs go over the on-device Vapor server on \(ServerConfig.installHost).")
                        .font(.caption).foregroundStyle(Theme.subtle)
                }
                Button { pick() } label: {
                    HStack {
                        if reading { ProgressView().tint(.black) } else { Image(systemName: "folder.fill") }
                        Text(meta == nil ? "Choose IPA" : "Choose another").fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(meta == nil ? Theme.accent : Theme.card)
                    .foregroundStyle(meta == nil ? .black : Theme.accent)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: meta == nil ? 0 : 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(reading || signing)
            }
        }
    }

    // MARK: Overrides

    private var overridesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Overrides (optional)", systemImage: "slider.horizontal.3").font(.headline).foregroundStyle(Theme.text)
                field("Display name", $nameOverride, meta?.name ?? "")
                field("Bundle id", $bundleOverride, meta?.bundleID ?? "")
                field("Version", $versionOverride, meta?.version ?? "")
                Text("Change the bundle id to install alongside the App Store copy. Leave blank to keep the IPA's values.")
                    .font(.caption2).foregroundStyle(Theme.subtle)
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Theme.subtle)
            TextField(placeholder, text: text)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .padding(10).background(Theme.bg).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
        }
    }

    // MARK: Sign / install

    private var actionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Certificate", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    if certs.certificates.count > 1 {
                        Menu {
                            ForEach(certs.certificates) { c in
                                Button(c.name) { certs.activeID = c.id }
                            }
                        } label: {
                            HStack(spacing: 4) { Text(certs.active?.name ?? "Pick"); Image(systemName: "chevron.down") }
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    } else {
                        Text(certs.active?.name ?? "None").font(.caption).foregroundStyle(certs.active == nil ? .orange : Theme.subtle)
                    }
                }
                if certs.active == nil {
                    Text("Import a .p12 + .mobileprovision in Settings › Certificates first.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button { Task { await sign() } } label: {
                    HStack {
                        if signing { ProgressView().tint(.black) } else { Image(systemName: "signature") }
                        Text(signing ? "Signing…" : "Sign").fontWeight(.bold)
                        Spacer()
                    }
                    .padding(.vertical, 14).padding(.horizontal, 14)
                    .background(certs.active == nil ? Theme.subtle : Theme.accent)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(signing || certs.active == nil)

                if let e = lastSigned {
                    Divider().overlay(Theme.stroke)
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Signed \(e.name) v\(e.version)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            Text("with \(e.certName)").font(.caption).foregroundStyle(Theme.subtle)
                        }
                        Spacer()
                    }
                    installButton(e)
                }
            }
        }
    }

    private func installButton(_ e: SignedEntry) -> some View {
        HStack(spacing: 10) {
            Button { Task { await install(e) } } label: {
                HStack {
                    if installing == e.id { ProgressView().tint(.black) } else { Image(systemName: "arrow.down.app.fill") }
                    Text("Install").fontWeight(.bold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Color.green).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(installing != nil)
            Button { share = URLItem(url: e.ipaURL) } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(Theme.card).foregroundStyle(Theme.accent)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: Log

    private var logCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("zsign", systemImage: "terminal.fill").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    Button { log.removeAll() } label: { Image(systemName: "trash").font(.caption).foregroundStyle(Theme.subtle) }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(log.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(line.hasPrefix(">>>") ? Theme.accent : (line.lowercased().contains("error") ? .orange : Theme.subtle))
                                    .id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(height: 180)
                    .background(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: log.count) { _ in if let l = log.indices.last { proxy.scrollTo(l, anchor: .bottom) } }
                }
            }
        }
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        if !signed.entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("SIGNED").font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
                ForEach(signed.entries) { e in
                    HStack(spacing: 12) {
                        iconView(e.iconURL.flatMap { try? Data(contentsOf: $0) }, side: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("\(e.bundleID) · v\(e.version)").font(.caption.monospaced()).foregroundStyle(Theme.subtle).lineLimit(1)
                            Text("\(e.certName) · \(e.signedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(Theme.subtle)
                        }
                        Spacer()
                        Button { Task { await install(e) } } label: {
                            if installing == e.id { ProgressView().tint(Theme.accent) }
                            else { Image(systemName: "arrow.down.app.fill").font(.system(size: 20)).foregroundStyle(.green) }
                        }
                        .disabled(installing != nil)
                        Menu {
                            Button { share = URLItem(url: e.ipaURL) } label: { Label("Share IPA", systemImage: "square.and.arrow.up") }
                            Button(role: .destructive) { signed.delete(e) } label: { Label("Delete", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(Theme.subtle)
                        }
                    }
                    .padding(12).background(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: Helpers

    private func iconView(_ data: Data?, side: CGFloat) -> some View {
        Group {
            if let data, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: side * 0.22).fill(Theme.accent.opacity(0.15))
                    .overlay(Image(systemName: "app.dashed").foregroundStyle(Theme.accent))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22))
    }

    private func sizeString(_ u: URL) -> String {
        let n = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func clear() {
        ipaURL = nil; meta = nil; lastSigned = nil; error = nil
        nameOverride = ""; bundleOverride = ""; versionOverride = ""
    }

    private func consumeQueue() {
        guard let u = queue.pending else { return }
        queue.pending = nil
        load(u)
    }

    private func pick() {
        DocumentPickerPresenter.pickFiles { urls in
            guard let u = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) ?? urls.first else { return }
            load(u)
        }
    }

    private func load(_ src: URL) {
        reading = true; error = nil; lastSigned = nil
        // Keep our own copy — picker temp files vanish.
        let dir = AppPaths.dir("inbox")
        let dest = dir.appendingPathComponent(src.lastPathComponent.isEmpty ? "app.ipa" : src.lastPathComponent)
        Task.detached {
            do {
                if src.standardizedFileURL != dest.standardizedFileURL {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: src, to: dest)
                }
                let m = try IPAMeta.read(dest)
                await MainActor.run { ipaURL = dest; meta = m; reading = false }
            } catch {
                await MainActor.run { self.error = "Couldn't read IPA: \(error.localizedDescription)"; reading = false }
            }
        }
    }

    private func sign() async {
        guard let ipaURL, let meta else { return }
        let material: CertMaterial
        do { material = try certs.activeMaterial() } catch { self.error = error.localizedDescription; return }
        signing = true; error = nil; lastSigned = nil
        log = [">>> Signing \(meta.name) with \(material.name)"]
        let n = nameOverride.trimmingCharacters(in: .whitespaces)
        let b = bundleOverride.trimmingCharacters(in: .whitespaces)
        let v = versionOverride.trimmingCharacters(in: .whitespaces)
        do {
            let outcome = try await Signer.signDetached(
                ipaURL: ipaURL, material: material,
                nameOverride: n.isEmpty ? nil : n,
                bundleIDOverride: b.isEmpty ? nil : b,
                versionOverride: v.isEmpty ? nil : v,
                onLog: { line in Task { @MainActor in log.append(line) } })
            let entry = try signed.add(outcome: outcome, icon: meta.iconPNG, certName: material.name)
            lastSigned = entry
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = error.localizedDescription
            log.append("error: \(error.localizedDescription)")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        signing = false
    }

    private func install(_ e: SignedEntry) async {
        installing = e.id; error = nil
        do { try await OTAInstaller.shared.install(e) }
        catch { self.error = error.localizedDescription }
        installing = nil
    }
}
