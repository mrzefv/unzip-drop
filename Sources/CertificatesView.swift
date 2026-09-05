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

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
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
                        if certName.isEmpty, let n = info.0 { certName = n }
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
        let info = (try? Data(contentsOf: c.provisionURL)).map(CertificateStore.profileInfo) ?? (nil, nil, nil)
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? Theme.accent.opacity(0.18) : Theme.bg)
                Image(systemName: active ? "checkmark.seal.fill" : "seal").foregroundStyle(active ? Theme.accent : Theme.subtle)
            }.frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                if let t = info.1 { Text(t).font(.caption).foregroundStyle(Theme.subtle).lineLimit(1) }
                if let e = info.2 {
                    let expired = e < Date()
                    Text((expired ? "Expired " : "Expires ") + e.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(expired ? .orange : Theme.subtle)
                }
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
