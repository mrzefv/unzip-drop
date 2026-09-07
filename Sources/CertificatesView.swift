//
//  CertificatesView.swift
//  Import a signing pair (.p12 + .mobileprovision), pick the active one.
//  Presented full-screen from Settings.
//

import SwiftUI
import UIKit

struct CertificatesScreen: View {
    @ObservedObject private var store = CertificateStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var p12Data: Data?
    @State private var p12Name = ""
    @State private var provData: Data?
    @State private var provName = ""
    @State private var certName = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var error: String?
    @State private var importing = false
    @State private var udidText = UserDefaults.standard.string(forKey: "uzd_device_udid") ?? ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    deviceCard
                    addCard
                    if store.certificates.isEmpty {
                        Card {
                            Text("No certificates yet. You need a developer .p12 (with its password) and a matching .mobileprovision that includes this device's UDID.")
                                .font(.caption).foregroundStyle(Theme.subtle)
                        }
                    }
                    ForEach(store.certificates) { certRow($0) }
                }
                .padding(16)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                Text("UNZIP DROP").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
                Spacer()
            }
            Text("Certificates").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
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
    }

    private var addCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Import certificate", systemImage: "plus.circle.fill").font(.headline).foregroundStyle(Theme.text)

                fileRow(icon: "key.fill", title: "Certificate (.p12)", picked: p12Name) {
                    DocumentPickerPresenter.pickFiles { urls in
                        guard let u = urls.first, let d = try? Data(contentsOf: u) else { return }
                        p12Data = d; p12Name = u.lastPathComponent
                        if certName.isEmpty { certName = u.deletingPathExtension().lastPathComponent }
                    }
                }
                fileRow(icon: "doc.badge.gearshape", title: "Profile (.mobileprovision)", picked: provName) {
                    DocumentPickerPresenter.pickFiles { urls in
                        guard let u = urls.first, let d = try? Data(contentsOf: u) else { return }
                        provData = d; provName = u.lastPathComponent
                        let info = CertificateStore.profileInfo(d)
                        if certName.isEmpty, let n = info.name { certName = n }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(Theme.subtle)
                    TextField("My Dev Cert", text: $certName)
                        .autocorrectionDisabled()
                        .padding(10).background(Theme.bg).foregroundStyle(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(".p12 password").font(.caption).foregroundStyle(Theme.subtle)
                    HStack {
                        Group {
                            if showPassword { TextField("blank if none", text: $password) }
                            else { SecureField("blank if none", text: $password) }
                        }
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(Theme.subtle)
                        }
                    }
                    .padding(10).background(Theme.bg).foregroundStyle(Theme.text)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                }

                if let error { Text(error).font(.caption).foregroundStyle(.orange) }

                Button { doImport() } label: {
                    HStack {
                        if importing { ProgressView().tint(.black) } else { Image(systemName: "checkmark.seal.fill") }
                        Text("Import & activate").fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(canImport ? Theme.accent : Theme.subtle).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canImport || importing)
            }
        }
    }

    /// Lets the user pin their UDID so every profile can be checked definitively.
    private var deviceCard: some View {
        let known = CertificateStore.knownUDID(certName: store.active?.name)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("This device", systemImage: "iphone.gen3").font(.headline).foregroundStyle(Theme.text)
                Text("Development/ad-hoc profiles only install on devices listed inside them. Enter your UDID once and every profile below shows whether it includes this device. (If your cert is named after your UDID, it's detected automatically.)")
                    .font(.caption).foregroundStyle(Theme.subtle)
                HStack(spacing: 8) {
                    TextField(known ?? "00008110-000209003C60E01E", text: $udidText)
                        .font(.system(size: 13, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.characters)
                        .padding(10).background(Theme.bg).foregroundStyle(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                    Button {
                        CertificateStore.setKnownUDID(udidText)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Text("Save").font(.caption.weight(.semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 14).padding(.vertical, 11).background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(udidText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let k = known {
                    Text("Using: \(k)").font(.caption2.monospaced()).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var canImport: Bool { p12Data != nil && provData != nil }

    private func fileRow(icon: String, title: String, picked: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                    Text(picked.isEmpty ? "Tap to choose" : picked).font(.caption).foregroundStyle(picked.isEmpty ? Theme.subtle : Theme.accent).lineLimit(1)
                }
                Spacer()
                Image(systemName: picked.isEmpty ? "folder" : "checkmark.circle.fill").foregroundStyle(picked.isEmpty ? Theme.subtle : .green)
            }
            .padding(10).background(Theme.bg)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func deviceLine(_ info: ProfileInfo, certName: String) -> some View {
        let udid = CertificateStore.knownUDID(certName: certName)
        let r = CertificateStore.profileIncludesDevice(info, udid: udid)
        let (icon, text, color): (String, String, Color) = {
            if info.udids.isEmpty { return ("building.2", "No device list (enterprise/in-house)", Theme.subtle) }
            switch r {
            case .some(true):  return ("checkmark.seal.fill", "This device is in the profile (\(info.udids.count) devices)", .green)
            case .some(false): return ("xmark.octagon.fill", "This device is NOT in the profile (\(info.udids.count) devices) — won't install", .orange)
            case .none:        return ("questionmark.circle", "\(info.udids.count) devices — enter your UDID above to check", Theme.subtle)
            }
        }()
        return HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text(text).font(.caption2).foregroundStyle(color).lineLimit(2)
        }
    }

    private func doImport() {
        guard let p12 = p12Data, let prov = provData else { return }
        importing = true; error = nil
        do {
            try store.importPair(name: certName, p12: p12, password: password, provision: prov)
            p12Data = nil; p12Name = ""; provData = nil; provName = ""; certName = ""; password = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = error.localizedDescription }
        importing = false
    }

    private func certRow(_ c: Certificate) -> some View {
        let active = store.activeID == c.id
        let info = (try? Data(contentsOf: c.provisionURL)).map(CertificateStore.profileInfo) ?? ProfileInfo()
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? Theme.accent.opacity(0.18) : Theme.bg)
                Image(systemName: active ? "checkmark.seal.fill" : "seal").foregroundStyle(active ? Theme.accent : Theme.subtle)
            }.frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                if let t = info.team { Text(t).font(.caption).foregroundStyle(Theme.subtle).lineLimit(1) }
                if let e = info.expires {
                    let expired = e < Date()
                    Text((expired ? "Expired " : "Expires ") + e.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(expired ? .orange : Theme.subtle)
                }
                deviceLine(info, certName: c.name)
            }
            Spacer()
            if active {
                Text("ACTIVE").font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.18)).foregroundStyle(Theme.accent).clipShape(Capsule())
            } else {
                Button("Use") { store.activeID = c.id }.font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            Menu {
                Button(role: .destructive) { store.delete(c) } label: { Label("Delete", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Theme.subtle) }
        }
        .padding(12).background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Theme.accent.opacity(0.4) : Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
