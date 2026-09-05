//
//  FileEditorView.swift
//  Raw source viewer/editor for a file in the extracted tree. Text files are
//  editable and save back to disk (so Push / Export Zip pick up the changes);
//  binary files are shown read-only.
//

import SwiftUI

struct FileEditorView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isText = true
    @State private var loaded = false
    @State private var dirty = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if !loaded {
                    ProgressView().tint(Theme.accent)
                } else if isText {
                    TextEditor(text: $text)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden)
                        .background(Theme.bg)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: text) { _ in dirty = true }
                        .padding(8)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.viewfinder").font(.system(size: 34)).foregroundStyle(Theme.subtle)
                        Text("Binary file â can't edit as text").font(.subheadline).foregroundStyle(Theme.subtle)
                        Text(url.lastPathComponent).font(.caption).foregroundStyle(Theme.subtle)
                    }
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if isText {
                        Button { save() } label: { Text(dirty ? "Save" : "Saved").bold() }
                            .disabled(!dirty)
                    }
                }
            }
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(Theme.accent)
            .alert("Editor", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
        }
        .onAppear(perform: load)
    }

    private func load() {
        do {
            let data = try Data(contentsOf: url)
            if let s = String(data: data, encoding: .utf8) { text = s; isText = true }
            else { isText = false }
        } catch {
            message = error.localizedDescription
            isText = false
        }
        loaded = true
    }

    private func save() {
        do {
            try (text.data(using: .utf8) ?? Data()).write(to: url)
            dirty = false
        } catch {
            message = "Save failed: \(error.localizedDescription)"
        }
    }
}
