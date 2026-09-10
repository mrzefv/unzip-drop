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

    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)
    private var inbox: URL { AppPaths.dir("inbox") }

    private var filtered: [LibraryItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? items : items.filter { $0.name.lowercased().contains(q) || $0.bundle.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if !items.isEmpty {
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
                        ForEach(filtered) { row($0) }
                    }
                }
                .padding(16)
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
        HStack {
            Text("Library").font(.title2.bold()).foregroundStyle(Theme.text)
            Spacer()
            Text("\(items.count) Apps").font(.caption.monospaced()).foregroundStyle(Theme.subtle)
            Button { importing = true } label: {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(blue).padding(.leading, 12)
            }
        }
    }

    private func row(_ it: LibraryItem) -> some View {
        HStack(spacing: 12) {
            icon(it.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(it.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(it.version) · \(it.bundle)\(it.sizeString.isEmpty ? "" : " · \(it.sizeString)")")
                    .font(.caption.monospaced()).foregroundStyle(Theme.subtle).lineLimit(1)
                Text("Downloaded").font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.card).foregroundStyle(Theme.subtle).clipShape(Capsule())
            }
            Spacer()
            if installing == it.id { ProgressView().tint(Theme.accent) }
            else { Image(systemName: "arrow.up.forward").font(.system(size: 18, weight: .semibold)).foregroundStyle(blue) }
        }
        .padding(12).background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { sheetItem = it }
    }

    private func icon(_ data: Data?) -> some View {
        Group {
            if let data, let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(Theme.accent)) }
        }
        .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
