//
//  LibraryView.swift
//  Library tab — imported/downloaded IPAs, mSign-style rows in floating glass chrome.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var ota = OTAInstaller.shared
    @State private var items: [LibraryItem] = []
    @State private var loading = true
    @State private var search = ""
    @State private var importing = false
    @State private var installing: String?
    @State private var error: String?
    @State private var sheetItem: LibraryItem?

    private var inbox: URL { AppPaths.dir("inbox") }

    private var filtered: [LibraryItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? items : items.filter { $0.name.lowercased().contains(q) || $0.bundle.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if !items.isEmpty {
                        MSignSearchField(placeholder: "Search", text: $search).padding(.bottom, 8)
                    }
                    if let error { Card { Text(error).font(.caption).foregroundStyle(.orange) }.padding(.bottom, 8) }
                    if loading {
                        HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.padding(.top, 60)
                    } else if items.isEmpty {
                        Card { Text("No apps yet. Download one in Browse, or tap + to import an .ipa.").font(.caption).foregroundStyle(Theme.subtle) }
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, it in
                            MSignRow(
                                icon: it.icon,
                                title: it.name,
                                subtitle: "\(it.version) • \(it.bundle)",
                                badge: "Downloaded",
                                busy: installing == it.id,
                                accent: SSTheme.tintColor,
                                onAction: { sheetItem = it },
                                onTap: { sheetItem = it }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { delete(it) } label: { Label("Delete", systemImage: "trash") }
                            }
                            if idx < filtered.count - 1 {
                                Divider().overlay(Theme.stroke).padding(.leading, 78)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 20)
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
        }
        .task { await reload() }
        .sheet(isPresented: $importing) {
            DocPicker(types: [UTType(filenameExtension: "ipa") ?? .item]) { urls in
                Task { await importIPAs(urls) }
            }
        }
        .sheet(item: $sheetItem) { it in
            AppActionSheet(
                name: it.name, bundle: it.bundle, icon: it.icon,
                actions: [
                    .init(title: "Install", icon: "square.and.arrow.down", role: .normal) {
                        sheetItem = nil; Task { await install(it) }
                    },
                    .init(title: "Sign", icon: "signature", role: .normal) {
                        sheetItem = nil; SignQueue.shared.enqueue(it.url)
                    },
                    .init(title: "Delete", icon: "trash", role: .destructive) {
                        sheetItem = nil; delete(it)
                    },
                ]
            )
            .presentationDetents([.height(340)])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        TabTitleBar(title: "Library", center: "\(items.count) Apps") {
            Button { importing = true } label: {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: - Data

    private func reload() async {
        loading = true
        let dir = inbox
        let list: [LibraryItem] = await Task.detached { () -> [LibraryItem] in
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter({ $0.pathExtension.lowercased() == "ipa" }) else { return [] }
            let sorted = files.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            return sorted.compactMap { u in
                let size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
                if let m = try? IPAMeta.read(u) {
                    return LibraryItem(id: u.path, url: u, name: m.name, bundle: m.bundleID, version: m.version, sizeBytes: size, icon: m.iconPNG)
                }
                let base = u.deletingPathExtension().lastPathComponent
                return LibraryItem(id: u.path, url: u, name: base, bundle: "—", version: "—", sizeBytes: size, icon: nil)
            }
        }.value
        items = list
        loading = false
    }

    private func importIPAs(_ urls: [URL]) async {
        let fm = FileManager.default
        for u in urls {
            let dest = inbox.appendingPathComponent(u.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: u, to: dest)
        }
        await reload()
    }

    private func delete(_ it: LibraryItem) {
        try? FileManager.default.removeItem(at: it.url)
        items.removeAll { $0.id == it.id }
    }

    private func install(_ it: LibraryItem) async {
        installing = it.id; error = nil
        do {
            try await OTAInstaller.shared.install(ipaURL: it.url, bundleID: it.bundle, name: it.name, version: it.version,
                                                 iconData: it.icon)
        } catch { self.error = error.localizedDescription }
        installing = nil
    }
}

// MARK: - Library item (on-disk IPA in the inbox)

struct LibraryItem: Identifiable, Equatable {
    let id: String            // file path
    let url: URL
    let name: String
    let bundle: String
    let version: String
    let sizeBytes: Int64
    let icon: Data?
    var sizeString: String { sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : "" }
}
