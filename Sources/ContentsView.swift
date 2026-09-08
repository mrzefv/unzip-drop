//
//  ContentsView.swift
//  Browse + edit the extracted tree. Tap a file to view/edit its raw source,
//  add new files, import (upload) files into the current folder, or repackage
//  the whole edited tree as a zip.
//

import SwiftUI

private nonisolated struct Entry: Identifiable {
    let url: URL
    let isDir: Bool
    let size: Int64
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct ContentsView: View {
    @EnvironmentObject var session: Session
    @State private var dir: URL?
    @State private var items: [Entry] = []
    @State private var editing: URLItem?
    @State private var sharing: URLItem?
    @State private var showNewFile = false
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let root = session.root {
                VStack(spacing: 0) {
                    header(root)
                    listView(root)
                }
                .onAppear { if dir == nil { dir = root }; reload(root) }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 34)).foregroundStyle(Theme.subtle)
                    Text("Nothing extracted yet").font(.subheadline).foregroundStyle(Theme.subtle)
                    Text("Import a zip first.").font(.caption).foregroundStyle(Theme.subtle)
                }
            }
        }
        .sheet(item: $editing, onDismiss: { if let root = session.root { reload(dir ?? root) } }) { it in
            FileEditorView(url: it.url)
        }
        .sheet(item: $sharing) { it in ShareSheet(items: [it.url]) }
        .alert("New file", isPresented: $showNewFile) {
            TextField("name.swift", text: $newName)
            Button("Create") { createFile() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Contents", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func header(_ root: URL) -> some View {
        let atRoot = (dir?.standardizedFileURL == root.standardizedFileURL)
        return VStack(spacing: 10) {
            HStack {
                Text("Contents").font(.title2.bold()).foregroundStyle(Theme.text)
                Spacer()
                Button { showNewFile = true } label: { Image(systemName: "doc.badge.plus").foregroundStyle(Theme.accent) }
                Button { importFiles() } label: { Image(systemName: "square.and.arrow.down").foregroundStyle(Theme.accent) }
                Button { exportZip(root) } label: { Image(systemName: "archivebox").foregroundStyle(Theme.accent) }
            }
            HStack(spacing: 8) {
                Button {
                    if let d = dir, !atRoot { dir = d.deletingLastPathComponent(); reload(root) }
                } label: {
                    Image(systemName: "chevron.left").foregroundStyle(atRoot ? Theme.subtle.opacity(0.4) : Theme.accent)
                }
                .disabled(atRoot)
                Text(rel(root)).font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.subtle).lineLimit(1).truncationMode(.head)
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
    }

    @ViewBuilder
    private func listView(_ root: URL) -> some View {
        if items.isEmpty {
            VStack { Spacer(); Text("Empty folder").font(.subheadline).foregroundStyle(Theme.subtle); Spacer() }
        } else {
            List {
                ForEach(items) { e in row(e, root: root) }
                    .listRowBackground(Theme.card)
                    .listRowSeparatorTint(Theme.stroke)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ e: Entry, root: URL) -> some View {
        Button {
            if e.isDir { dir = e.url; reload(root) } else { editing = URLItem(url: e.url) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(e)).foregroundStyle(e.isDir ? Theme.accent : Theme.text).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.name).foregroundStyle(Theme.text).lineLimit(1)
                    if !e.isDir {
                        Text(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                            .font(.caption2).foregroundStyle(Theme.subtle)
                    }
                }
                Spacer()
                Image(systemName: e.isDir ? "chevron.right" : "pencil").font(.caption).foregroundStyle(Theme.subtle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { remove(e, root: root) } label: { Label("Delete", systemImage: "trash") }
            if !e.isDir {
                Button { sharing = URLItem(url: e.url) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    .tint(Theme.accent)
            }
        }
    }

    private func icon(_ e: Entry) -> String {
        if e.isDir { return "folder.fill" }
        switch e.url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "png", "jpg", "jpeg", "gif": return "photo"
        case "json", "plist": return "curlybraces"
        case "md", "txt": return "doc.text"
        case "yml", "yaml", "sh": return "terminal"
        default: return "doc"
        }
    }

    private func rel(_ root: URL) -> String {
        let base = root.standardizedFileURL.path
        let here = (dir ?? root).standardizedFileURL.path
        let r = here.hasPrefix(base) ? String(here.dropFirst(base.count)) : here
        return r.isEmpty ? "/" : r
    }

    private func reload(_ root: URL) {
        let d = dir ?? root
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let urls = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: keys)) ?? []
        items = urls
            .filter { $0.lastPathComponent != ".DS_Store" }
            .map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return Entry(url: u, isDir: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0))
            }
            .sorted {
                if $0.isDir != $1.isDir { return $0.isDir && !$1.isDir }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    // MARK: actions

    private func createFile() {
        let name = newName.trimmingCharacters(in: .whitespaces); newName = ""
        guard !name.isEmpty, let d = dir else { return }
        let dest = d.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { error = "\(name) already exists."; return }
        do {
            try Data().write(to: dest)
            if let root = session.root { reload(root) }
            editing = URLItem(url: dest)
        } catch { self.error = error.localizedDescription }
    }

    private func importFiles() {
        guard let d = dir else { return }
        DocumentPickerPresenter.pickFiles { urls in
            let fm = FileManager.default
            for src in urls {
                var dest = d.appendingPathComponent(src.lastPathComponent)
                var n = 1
                while fm.fileExists(atPath: dest.path) {
                    let base = src.deletingPathExtension().lastPathComponent
                    let ext = src.pathExtension
                    dest = d.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                    n += 1
                }
                try? fm.copyItem(at: src, to: dest)   // asCopy â local & readable
            }
            if let root = session.root { reload(root) }
        }
    }

    private func exportZip(_ root: URL) {
        do {
            let z = try Unzipper.makeZip(from: root, name: session.archiveName ?? "archive")
            sharing = URLItem(url: z)
        } catch { self.error = "Couldn't make zip: \(error.localizedDescription)" }
    }

    private func remove(_ e: Entry, root: URL) {
        do { try FileManager.default.removeItem(at: e.url); reload(root) }
        catch { self.error = error.localizedDescription }
    }
}
