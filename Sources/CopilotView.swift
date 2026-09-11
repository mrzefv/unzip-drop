//
//  CopilotView.swift
//  mv1E Copilot — describe a tweak, get context-aware dylib source, then Download
//  the source, save it, or (via GitHub Actions) compile it to a .dylib and stage it
//  for injection into the IPA you're signing.
//
//  For apps you own or are authorized to modify.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CopilotView: View {
    let app: String
    let bundleID: String
    let cls: MV1E.DumpedClass
    let ipaURL: URL
    var stageDylib: (URL) -> Void

    @EnvironmentObject var config: Config
    @Environment(\.dismiss) private var dismiss
    @State private var request = ""
    @State private var generating = false
    @State private var source = ""
    @State private var note = ""
    @State private var error: String?
    @State private var showShare = false
    @State private var savedURL: URL?

    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)

    private var context: String { Copilot.contextJSON(app: app, bundleID: bundleID, cls: cls) }

    var body: some View {
        List {
            Section {
                Text("Copilot sees \(cls.name) — \(cls.methods.count) selectors, \(cls.ivars.count) ivars — and writes a tweak against it. Your API key, direct to \(Copilot.provider.label).")
                    .font(.caption).foregroundStyle(Theme.subtle)
            }.listRowBackground(Color(white: 0.08))

            if !Copilot.hasKey {
                Section { Label("No API key — add one in Settings › Copilot.", systemImage: "key.slash").foregroundStyle(.orange).font(.caption) }
                    .listRowBackground(Color(white: 0.08))
            }

            Section("Describe the tweak") {
                TextField("e.g. log every call to these methods with arguments", text: $request, axis: .vertical)
                    .lineLimit(2...5)
                Button { Task { await generate() } } label: {
                    HStack { if generating { ProgressView().tint(blue) } else { Image(systemName: "sparkles") }
                        Text(generating ? "Generating…" : "Generate dylib source").fontWeight(.semibold) }
                }.disabled(generating || request.trimmingCharacters(in: .whitespaces).isEmpty || !Copilot.hasKey)
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            }.listRowBackground(Color(white: 0.08))

            if !source.isEmpty {
                if !note.isEmpty {
                    Section("Notes") { Text(note).font(.caption).foregroundStyle(Theme.subtle) }
                        .listRowBackground(Color(white: 0.08))
                }
                Section("Source (.m)") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(source).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                            .textSelection(.enabled).padding(.vertical, 4)
                    }
                }.listRowBackground(Color(white: 0.08))

                Section("Use it") {
                    Button { UIPasteboard.general.string = source } label: { Label("Copy source", systemImage: "doc.on.doc") }
                    Button { saveSource() } label: { Label("Download source (.m)", systemImage: "square.and.arrow.down") }
                    Button { Task { await buildViaActions() } } label: { Label("Compile to .dylib on GitHub Actions", systemImage: "hammer") }
                    Text("Compiling needs clang + the iOS SDK, which runs on GitHub Actions — not on-device. The built .dylib returns as an artifact, then stages for injection.")
                        .font(.caption2).foregroundStyle(Theme.subtle)
                }.listRowBackground(Color(white: 0.08))
            }
        }
        .scrollContentBackground(.hidden).background(Color.black)
        .navigationTitle("Copilot").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) { if let u = savedURL { ShareSheet(items: [u]) } }
    }

    private func generate() async {
        generating = true; error = nil
        do {
            let r = try await Copilot.generate(context: context, request: request)
            source = r.source; note = r.note
            if source.isEmpty { error = "Model didn't return a code block." }
        } catch { self.error = error.localizedDescription }
        generating = false
    }

    private func saveSource() {
        let name = "\(cls.name)Tweak.m"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? source.data(using: .utf8)?.write(to: url)
        savedURL = url; showShare = true
    }

    private func buildViaActions() async {
        // Push the .m to the repo and dispatch the clang-swizzle build workflow.
        // compiles with Theos and uploads the .dylib artifact; the Build tab tracks it.
        error = nil
        do {
            try await CopilotBuild.dispatch(source: source, className: cls.name,
                owner: config.owner, repo: config.repo, branch: config.branch, token: config.token)
            note = "Pushed source + dispatched build. Watch the Build tab; the .dylib arrives as an artifact."
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Copilot settings (provider · model · API key)

struct CopilotSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = Copilot.provider
    @State private var model = Copilot.model
    @State private var key = Copilot.apiKey
    @State private var saved = false

    var body: some View {
        List {
            Section {
                Text("Copilot writes dylib source from the mv1E class dump using YOUR API key, sent directly to the provider. The key is stored in the Keychain and never leaves the device except to that provider.")
                    .font(.caption).foregroundStyle(Theme.subtle)
            }.listRowBackground(Color(white: 0.08))

            Section("Provider") {
                Picker("Provider", selection: $provider) {
                    ForEach(Copilot.Provider.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
            }.listRowBackground(Color(white: 0.08))

            Section("API key") {
                SecureField(provider == .openai ? "sk-…" : "sk-ant-…", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    Copilot.provider = provider
                    Copilot.model = model.trimmingCharacters(in: .whitespaces)
                    Copilot.apiKey = key.trimmingCharacters(in: .whitespaces)
                    saved = true
                } label: { Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down") }
                if Copilot.hasKey {
                    Button(role: .destructive) { Copilot.apiKey = ""; key = ""; saved = false } label: { Label("Clear key", systemImage: "trash") }
                }
            }.listRowBackground(Color(white: 0.08))
        }
        .scrollContentBackground(.hidden).background(Color.black)
        .navigationTitle("Copilot").navigationBarTitleDisplayMode(.inline)
        .onChange(of: provider) { model = $0.defaultModel }
    }
}
