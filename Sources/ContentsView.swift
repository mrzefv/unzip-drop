//
//  ContentsView.swift
//

import SwiftUI

private struct Entry: Identifiable {
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
    @State private var share: URLItem?
    @State private var exporting = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let root = session.root {
                VStack(spacing: 0) {
                    header(root)
                    if items.isEmpty {
                        Spacer()
                        Text("Empty").font(.subheadline).foregroundStyle(Theme.subtle)
                        Spacer()
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
                .onAppear { if dir == nil { dir = root }; reload(root) }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 34)).foregroundStyle(Theme.subtle)
                    Text("Nothing extracted yet").font(.subheadline).foregroundStyle(Theme.subtle)
                    Text("Import a zip first.").font(.caption).foregroundStyle(Theme.subtle)
                }
            }
        }
        .sheet(item: $share) { s in ShareSheet(items: [s.url]) }
        .sheet(isPresented: $exporting) { if let r = session.root { DirExporter(url: r) } }
    }

    private func header(_ root: URL) -> some View {
        let atRoot = (dir?.standardizedFileURL == root.standardizedFileURL)
        return VStack(spacing: 10) {
            HStack {
                Text("Contents").font(.title2.bold()).foregroundStyle(Theme.text)
                Spacer()
                Button { exporting = true } label: {
                    Label("Save All", systemImage: "square.and.arrow.down").font(.caption).foregroundStyle(Theme.accent)
                }
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

    private func row(_ e: Entry, root: URL) -> some View {
        Button {
            if e.isDir { dir = e.url; reload(root) } else { share = URLItem(url: e.url) }
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
                Image(systemName: e.isDir ? "chevron.right" : "square.and.arrow.up")
                    .font(.caption).foregroundStyle(Theme.subtle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
}
