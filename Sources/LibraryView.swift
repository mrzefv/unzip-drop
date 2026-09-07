//
//  LibraryView.swift
//  Library tab — downloaded (from Browse) and imported .ipa files sitting in
//  the inbox. Each row opens the same mSign-style bottom action sheet as the
//  Signed tab: Install / Sign. Import adds an .ipa from Files.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

struct LibraryView: View {
    @ObservedObject private var ota = OTAInstaller.shared
    @State private var items: [LibraryItem] = []
    @State private var loading = true
    @State private var search = ""
    @State private var importing = false
    @State private var installing: String?
    @State private var error: String?
    @State private var sheetItem: LibraryItem?
    @State private var showSearch = false
    @State private var selecting = false
    @State private var selected: Set<String> = []

    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)
    private var inbox: URL { AppPaths.dir("inbox") }

    private var filtered: [LibraryItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? items : items.filter { $0.name.lowercased().contains(q) || $0.bundle.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            VStack(spacing: 0) {
                header  // edge-to-edge, has its own accent bg + bottom border
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        if showSearch && !items.isEmpty {
                            TextField("Search", text: $search)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                                .padding(10).background(Theme.card).foregroundStyle(Theme.text)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        if let error { Card { Text(error).font(.caption).foregroundStyle(.orange) } }
                        if loading {
                            HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.padding(.top, 40)
                        } else if items.isEmpty {
                            Card { Text("No apps yet. Download one in Browse, or tap + to import an .ipa.").font(.caption).foregroundStyle(Theme.subtle) }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(filtered) { it in
                                    row(it)
                                    if it.id != filtered.last?.id {
                                        Divider().overlay(Theme.stroke).padding(.leading, 84)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
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
                    .init(title: "Sign", icon: "checkmark.seal", role: .normal) {
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
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { withAnimation { ThemePanelState.shared.open.toggle() } } label: {
                    Image(systemName: "paintpalette.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
                }
                Text("Library").font(.title2.bold()).foregroundStyle(Theme.text)
                Spacer()
                if selecting {
                    Text("\(selected.count) selected").font(.caption).foregroundStyle(Theme.subtle)
                } else {
                    Text("\(items.count) Apps").font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                }
                Button { withAnimation { showSearch.toggle(); if !showSearch { search = "" } } } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                Menu {
                    if selecting {
                        Button { selectAll() } label: { Label("Select all", systemImage: "checkmark.circle") }
                        Button(role: .destructive) { deleteSelected() } label: { Label("Delete selected", systemImage: "trash") }
                        Button { updateSelected() } label: { Label("Update selected", systemImage: "arrow.down.circle") }
                        Button { selecting = false; selected.removeAll() } label: { Label("Done", systemImage: "xmark") }
                    } else {
                        Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                        Button { importing = true } label: { Label("Import IPA", systemImage: "plus") }
                    }
                } label: {
                    Image(systemName: selecting ? "ellipsis.circle.fill" : "ellipsis.circle").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                if !selecting {
                    Button { importing = true } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.accent.opacity(0.06))
            Rectangle().fill(Theme.accent).frame(height: 2)
        }
    }

    private func row(_ it: LibraryItem) -> some View {
        HStack(spacing: 14) {
            icon(it.icon)
            VStack(alignment: .leading, spacing: 5) {
                Text(it.name).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(it.version) · \(it.bundle)").font(.system(size: 15)).foregroundStyle(Theme.subtle).lineLimit(1)
                Text("Downloaded").font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.card).foregroundStyle(Theme.subtle).clipShape(Capsule())
            }
            Spacer()
            if selecting {
                Image(systemName: selected.contains(it.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(selected.contains(it.id) ? blue : Theme.subtle)
            } else if installing == it.id { ProgressView().tint(Theme.accent) }
            else { Image(systemName: "arrow.up.forward").font(.system(size: 18, weight: .semibold)).foregroundStyle(blue) }
        }
        .padding(.vertical, 14).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { toggle(it.id) } else { sheetItem = it }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func selectAll() { selected = Set(filtered.map { $0.id }) }
    private func deleteSelected() {
        for it in items where selected.contains(it.id) { try? FileManager.default.removeItem(at: it.url) }
        items.removeAll { selected.contains($0.id) }
        selected.removeAll(); selecting = false
    }
    private func updateSelected() {
        // Re-download newer copies isn't tracked per-source here; hand each to the
        // signer so the user can re-sign the latest. (Library update = re-process.)
        for it in items where selected.contains(it.id) { SignQueue.shared.enqueue(it.url) }
        selected.removeAll(); selecting = false
    }

    private func icon(_ data: Data?) -> some View {
        Group {
            if let data, let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(Theme.accent)) }
        }
        .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
