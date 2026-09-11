//
//  McryptedRecoverView.swift
//  Standalone "Recover from any IPA" — the cross-device half of Inject Data.
//
//  Pick any signed .ipa that carries an Mcrypted-512 payload, enter the 24-word
//  recovery key, and decrypt. The IPA is the transport container; the recovery
//  words never live in it. Works independently of the signing sheet, so a payload
//  hidden on one device can be recovered from the IPA on another.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct McryptedRecoverView: View {
    var embeddedInSheet = false
    @Environment(\.dismiss) private var dismiss

    @State private var ipaURL: URL?
    @State private var ipaName = ""
    @State private var words = ""
    @State private var scanning = false
    @State private var hasPayload: Bool?
    @State private var recovered: (name: String, data: Data)?
    @State private var error: String?
    @State private var showPicker = false
    @State private var showShare = false

    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pick a signed IPA that carries a hidden Mcrypted-512 payload, then enter its 24-word recovery key to decrypt. The words are never stored in the IPA.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                }.listRowBackground(Color(white: 0.08))

                Section("Container") {
                    Button { error = nil; recovered = nil; showPicker = true } label: {
                        Label(ipaName.isEmpty ? "Choose .ipa" : ipaName, systemImage: "app.badge")
                    }
                    if scanning {
                        HStack { ProgressView().tint(blue); Text("Scanning binary…").font(.caption).foregroundStyle(Theme.subtle) }
                    } else if let hasPayload {
                        Label(hasPayload ? "Mcrypted payload found" : "No Mcrypted payload in this IPA",
                              systemImage: hasPayload ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(hasPayload ? .green : .orange)
                    }
                }.listRowBackground(Color(white: 0.08))

                Section("Recovery key") {
                    TextField("Enter your 24 words", text: $words, axis: .vertical)
                        .font(.system(size: 14, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { Task { await recover() } } label: { Label("Decrypt & recover", systemImage: "lock.open.fill") }
                        .disabled(ipaURL == nil || words.split(separator: " ").count < 24)
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                }.listRowBackground(Color(white: 0.08))

                if let recovered {
                    Section("Recovered") {
                        HStack {
                            Label("\(recovered.name) · \(ByteCountFormatter.string(fromByteCount: Int64(recovered.data.count), countStyle: .file))",
                                  systemImage: "doc.fill").font(.caption).foregroundStyle(Theme.text)
                            Spacer()
                            Button { showShare = true } label: { Image(systemName: "square.and.arrow.up").foregroundStyle(blue) }
                        }
                    }.listRowBackground(Color(white: 0.08))
                }
            }
            .scrollContentBackground(.hidden).background(Color.black)
            .navigationTitle("Recover Data").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPicker) {
            DocPicker(types: [UTType(filenameExtension: "ipa") ?? .item]) { urls in
                guard let u = urls.first else { return }
                ipaURL = u; ipaName = u.lastPathComponent; recovered = nil; error = nil
                Task { await probe() }
            }
        }
        .sheet(isPresented: $showShare) {
            if let r = recovered {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(r.name)
                let _ = try? r.data.write(to: tmp)
                ShareSheet(items: [tmp])
            }
        }
    }

    private func probe() async {
        guard let u = ipaURL else { return }
        scanning = true; hasPayload = nil
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        if let bin = await LocalBinaryScanner.mcryptedPayload(ipaURL: u) {
            hasPayload = Mcrypted512.hasPayload(inBinary: bin)
        } else { hasPayload = false; error = "Couldn't read the app binary in this IPA." }
        scanning = false
    }

    private func recover() async {
        guard let u = ipaURL else { return }
        error = nil; recovered = nil
        let ws = words.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard let entropy = Mcrypted512.entropy(fromWords: ws) else { error = "Invalid key — need 24 valid words."; return }
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        guard let bin = await LocalBinaryScanner.mcryptedPayload(ipaURL: u) else { error = "Couldn't read the binary."; return }
        do {
            let r = try Mcrypted512.extract(fromBinary: bin, entropy: entropy)
            recovered = (name: r.filename, data: r.payload)
        } catch { self.error = error.localizedDescription }
    }
}
