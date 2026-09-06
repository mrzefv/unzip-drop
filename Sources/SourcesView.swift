//
//  SourcesView.swift
//  Browse tab — AltStore / Feather / DELvEK style sources (repo.json).
//  Sources list → source detail (icon header, "N Apps" bar, rows with icon ·
//  size | version | subtitle · screenshot carousel · download). Downloading an
//  app pulls the IPA into the inbox and hands it to the Library tab to sign.
//

import SwiftUI
import UIKit

// MARK: - Models

struct RepoSource: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: URL
    var iconURL: URL?
    var description: String
    var author: String?
    var appCount: Int?
    var lastFetched: Date?
}

struct SourceApp: Identifiable, Equatable {
    let id: String
    let name: String
    let bundle: String
    let subtitle: String
    let version: String
    let sizeMB: String
    let updated: String
    let downloads: String
    let description: String
    let iconURL: URL?
    let downloadURL: URL?
    let screenshots: [URL]
}

// MARK: - Parser (ported from mSign's RepoParser; accepts many repo.json dialects)

nonisolated enum RepoParser {
    struct ParsedRepo: Sendable {
        let name: String
        let iconURL: URL?
        let description: String?
        let author: String?
        let apps: [SourceApp]
    }

    static func parse(data: Data, fallbackName: String) throws -> ParsedRepo {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            // Bare array of apps
            let apps = ((obj as? [[String: Any]]) ?? []).compactMap(mapApp)
            return ParsedRepo(name: fallbackName, iconURL: nil, description: nil, author: nil, apps: apps)
        }
        var name = (root["name"] as? String) ?? (root["repoName"] as? String) ?? (root["title"] as? String)
            ?? (root["sourceName"] as? String) ?? fallbackName
        if name.lowercased().hasSuffix(" repo") { name = String(name.dropLast(5)) }
        let icon = firstURL(root, ["iconURL", "iconUrl", "icon", "repoIcon", "sourceIcon"])
        let desc = (root["description"] as? String) ?? (root["subtitle"] as? String) ?? (root["caption"] as? String)
        let author = (root["author"] as? String) ?? (root["developer"] as? String) ?? (root["identifier"] as? String)
        let arr = (root["apps"] as? [[String: Any]]) ?? (root["Applications"] as? [[String: Any]])
            ?? (root["items"] as? [[String: Any]]) ?? (root["packages"] as? [[String: Any]])
            ?? ((root["repo"] as? [String: Any])?["apps"] as? [[String: Any]]) ?? []
        return ParsedRepo(name: name, iconURL: icon, description: desc, author: author, apps: arr.compactMap(mapApp))
    }

    private static func firstURL(_ d: [String: Any], _ keys: [String]) -> URL? {
        for k in keys { if let s = d[k] as? String, let u = URL(string: s) { return u } }
        return nil
    }

    private static func mapApp(_ a: [String: Any]) -> SourceApp? {
        guard let name = (a["name"] as? String) ?? (a["displayName"] as? String) ?? (a["title"] as? String) else { return nil }
        let bundle = (a["bundleIdentifier"] as? String) ?? (a["bundleID"] as? String) ?? (a["bundle"] as? String) ?? (a["identifier"] as? String) ?? "unknown.bundle"
        let subtitle = (a["subtitle"] as? String) ?? (a["developer"] as? String) ?? (a["developerName"] as? String) ?? (a["author"] as? String) ?? (a["category"] as? String) ?? ""
        let desc = (a["description"] as? String) ?? (a["localizedDescription"] as? String) ?? (a["summary"] as? String) ?? ""

        // AltStore v2: versions[0] holds version/date/size/downloadURL
        let v0 = (a["versions"] as? [[String: Any]])?.first ?? [:]
        let version = (a["version"] as? String) ?? (v0["version"] as? String) ?? (a["versionString"] as? String) ?? (a["latestVersion"] as? String) ?? "—"
        let sizeMB: String = {
            for src in [a, v0] {
                if let s = src["size"] as? String { return s }
                if let b = src["size"] as? Double { return String(format: "%.1f MB", b / 1_048_576) }
                if let b = src["size"] as? Int { return String(format: "%.1f MB", Double(b) / 1_048_576) }
            }
            return (a["sizeMB"] as? String) ?? "—"
        }()
        let updated = (a["versionDate"] as? String) ?? (v0["date"] as? String) ?? (a["updated"] as? String) ?? (a["lastUpdated"] as? String) ?? "—"
        let downloads: String = {
            if let n = a["downloads"] as? Int { return "\(n)" }
            if let n = a["downloadCount"] as? Int { return "\(n)" }
            if let s = a["downloads"] as? String { return s }
            return "0"
        }()
        let icon = firstURL(a, ["iconURL", "iconUrl", "icon"])
        let dl = firstURL(a, ["downloadURL", "downloadUrl", "url", "ipa", "ipaURL", "ipa_url"]) ?? firstURL(v0, ["downloadURL", "url"])
        let shots: [URL] = {
            if let arr = a["screenshots"] as? [String] { return arr.compactMap(URL.init(string:)) }
            if let arr = a["screenshotURLs"] as? [String] { return arr.compactMap(URL.init(string:)) }
            if let arr = a["screenshots"] as? [[String: Any]] { return arr.compactMap { ($0["imageURL"] as? String).flatMap(URL.init(string:)) } }
            if let d = a["screenshots"] as? [String: Any] { // AltStore v2: {"iphone": [...]}
                for (_, v) in d { if let arr = v as? [String] { return arr.compactMap(URL.init(string:)) } }
            }
            return []
        }()
        return SourceApp(id: bundle + "@" + version, name: name, bundle: bundle, subtitle: subtitle, version: version,
                         sizeMB: sizeMB, updated: updated, downloads: downloads, description: desc,
                         iconURL: icon, downloadURL: dl, screenshots: shots)
    }
}

// MARK: - Store

@MainActor
final class SourceStore: ObservableObject {
    static let shared = SourceStore()
    @Published private(set) var sources: [RepoSource] = []
    private let fileURL = AppPaths.dir("sources").appendingPathComponent("sources.json")

    static let defaults: [RepoSource] = [
        RepoSource(id: "delvek", name: "DELvEK", url: URL(string: "https://delvek.net/repo.json")!,
                   iconURL: nil, description: "Trusted IPA Daily Uploads!", author: "MRzefv"),
        RepoSource(id: "msign", name: "mSign", url: URL(string: "https://msign.party/repo.json")!,
                   iconURL: nil, description: "mSign party repo", author: "MRzefv"),
    ]

    private init() {
        if let d = try? Data(contentsOf: fileURL), let l = try? JSONDecoder().decode([RepoSource].self, from: d), !l.isEmpty {
            sources = l
        } else {
            sources = Self.defaults; save()
        }
    }

    func add(_ s: RepoSource) { sources.removeAll { $0.url == s.url }; sources.append(s); save() }
    func update(_ s: RepoSource) { if let i = sources.firstIndex(where: { $0.id == s.id }) { sources[i] = s; save() } }
    func remove(_ s: RepoSource) { sources.removeAll { $0.id == s.id }; save() }
    func move(from: IndexSet, to: Int) { sources.move(fromOffsets: from, toOffset: to); save() }
    private func save() { try? JSONEncoder().encode(sources).write(to: fileURL) }

    /// Fetch + parse a repo.json; caches nothing but updates the source's metadata.
    func fetch(_ s: RepoSource) async throws -> RepoParser.ParsedRepo {
        var req = URLRequest(url: s.url); req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw GitHubError.badConfig("Source returned HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        let parsed = try RepoParser.parse(data: d, fallbackName: s.name)
        var u = s
        if u.name.isEmpty || u.id.hasPrefix("custom-") { u.name = parsed.name }
        if u.iconURL == nil { u.iconURL = parsed.iconURL }
        if let desc = parsed.description, !desc.isEmpty, u.description.isEmpty || u.id.hasPrefix("custom-") { u.description = desc }
        if let a = parsed.author { u.author = a }
        u.appCount = parsed.apps.count; u.lastFetched = Date()
        update(u)
        return parsed
    }
}

// MARK: - Sources list (Browse tab)

struct SourcesView: View {
    @ObservedObject private var store = SourceStore.shared
    @State private var editing = false
    @State private var adding = false
    @State private var newURL = ""
    @State private var addError: String?
    @State private var selected: RepoSource?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Sources").font(.title2.bold()).foregroundStyle(Theme.text)
                    Spacer()
                    Button(editing ? "Done" : "Edit") { withAnimation { editing.toggle() } }
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                    Button { adding = true } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    .padding(.leading, 14)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

                List {
                    ForEach(store.sources) { s in
                        Button { if !editing { selected = s } } label: { sourceRow(s) }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.bg)
                            .listRowSeparatorTint(Theme.stroke)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .swipeActions { Button(role: .destructive) { store.remove(s) } label: { Label("Remove", systemImage: "trash") } }
                    }
                    .onDelete { idx in idx.map { store.sources[$0] }.forEach(store.remove) }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(editing ? .active : .inactive))
            }
        }
        .fullScreenCover(item: $selected) { s in SourceDetailScreen(source: s).preferredColorScheme(.dark) }
        .alert("Add source", isPresented: $adding) {
            TextField("https://example.com/repo.json", text: $newURL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add") { add() }
            Button("Cancel", role: .cancel) { newURL = "" }
        } message: { Text(addError ?? "Paste a repo.json URL (AltStore, Feather, DELvEK, mSign formats).") }
    }

    private func sourceRow(_ s: RepoSource) -> some View {
        HStack(spacing: 14) {
            SourceIcon(url: s.iconURL, side: 64, fallback: s.name)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.name).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(s.description.isEmpty ? s.url.host ?? s.url.absoluteString : s.description)
                    .font(.system(size: 15)).foregroundStyle(Theme.subtle).lineLimit(1)
                if let n = s.appCount { Text("\(n) apps").font(.caption2.monospaced()).foregroundStyle(Theme.accent) }
            }
            Spacer()
            if !editing {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 26, weight: .medium)).foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func add() {
        let s = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), u.scheme?.hasPrefix("http") == true else { addError = "That isn't a valid URL."; adding = true; return }
        let src = RepoSource(id: "custom-" + UUID().uuidString, name: u.host ?? "Source", url: u, iconURL: nil, description: "", author: nil)
        store.add(src); newURL = ""; addError = nil
        Task { _ = try? await store.fetch(src) }
    }
}

// MARK: - Source detail (the app list)

private struct SourceDetailScreen: View {
    let source: RepoSource
    @ObservedObject private var store = SourceStore.shared
    @ObservedObject private var signed = SignedStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var parsed: RepoParser.ParsedRepo?
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @State private var showSearch = false
    @State private var downloading: String?
    @State private var progress: Double = 0
    @State private var sort: Sort = .updated

    private enum Sort: String, CaseIterable { case updated = "Recently updated", name = "Name", size = "Size" }

    private var current: RepoSource { store.sources.first { $0.id == source.id } ?? source }
    private var apps: [SourceApp] {
        var list = parsed?.apps ?? []
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) || $0.bundle.lowercased().contains(q) } }
        switch sort {
        case .updated: list.sort { $0.updated > $1.updated }
        case .name: list.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .size: list.sort { (Double($0.sizeMB.split(separator: " ").first ?? "") ?? 0) > (Double($1.sizeMB.split(separator: " ").first ?? "") ?? 0) }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            countBar
            if showSearch {
                TextField("Search \(current.name)", text: $search)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .padding(10).background(Theme.card).foregroundStyle(Theme.text)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if let error {
                Card { Text(error).font(.caption).foregroundStyle(.orange) }.padding(16)
            }
            List {
                if loading {
                    HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.listRowBackground(Theme.bg).listRowSeparator(.hidden)
                }
                ForEach(apps) { app in
                    appRow(app)
                        .listRowBackground(Theme.bg)
                        .listRowSeparatorTint(Theme.stroke)
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await load() }
    }

    // Header: back · icon + NAME · search · sort
    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 34, height: 34)
            }
            Spacer()
            HStack(spacing: 10) {
                SourceIcon(url: current.iconURL, side: 34, fallback: current.name)
                Text(current.name.uppercased()).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            Spacer()
            Button { withAnimation { showSearch.toggle() } } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 34, height: 34)
            }
            Menu {
                ForEach(Sort.allCases, id: \.self) { s in Button(s.rawValue) { sort = s } }
                Divider()
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Link(destination: current.url) { Label("Open repo.json", systemImage: "safari") }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.card.opacity(0.6))
    }

    private var countBar: some View {
        HStack {
            Text("\(apps.count.formatted()) Apps").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            if let a = current.author ?? parsed?.author {
                Text(a).font(.system(size: 18, weight: .bold)).foregroundStyle(.red).kerning(0.5)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.card.opacity(0.35))
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)
    }

    private func appRow(_ app: SourceApp) -> some View {
        let have = signed.entries.contains { $0.bundleID == app.bundle }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                SourceIcon(url: app.iconURL, side: 84, fallback: app.name)
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.name).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text("\(app.sizeMB) | \(app.version) | \(app.subtitle)")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.subtle).lineLimit(1)
                    if !app.description.isEmpty {
                        Text(app.description).font(.system(size: 15)).foregroundStyle(Theme.subtle).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    Button { Task { await download(app) } } label: {
                        Group {
                            if downloading == app.id {
                                ZStack {
                                    Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 3)
                                    Circle().trim(from: 0, to: max(0.05, progress)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                                }
                            } else if have {
                                Image(systemName: "checkmark").font(.system(size: 28, weight: .bold))
                            } else {
                                Image(systemName: "arrow.down").font(.system(size: 28, weight: .bold))
                            }
                        }
                        .frame(width: 44, height: 44).foregroundStyle(Theme.accent)
                    }
                    .disabled(downloading != nil || app.downloadURL == nil)
                    Text("Views: \(app.downloads)").font(.system(size: 13)).foregroundStyle(Theme.subtle)
                }
            }
            if !app.screenshots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(app.screenshots.prefix(8).enumerated()), id: \.offset) { _, u in
                            AsyncImage(url: u) { phase in
                                if let img = phase.image { img.resizable().scaledToFill() }
                                else { Theme.card.overlay(ProgressView().tint(Theme.accent)) }
                            }
                            .frame(width: 176, height: 380)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true; error = nil
        do { parsed = try await store.fetch(current) } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func download(_ app: SourceApp) async {
        guard let u = app.downloadURL else { return }
        downloading = app.id; progress = 0; error = nil
        let name = (app.name.replacingOccurrences(of: "/", with: "-")) + "-" + app.version + ".ipa"
        let dest = AppPaths.dir("inbox").appendingPathComponent(name)
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: u, delegate: nil)
            guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw GitHubError.badConfig("Download failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))") }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            progress = 1
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            SignQueue.shared.enqueue(dest)
        } catch { self.error = error.localizedDescription }
        downloading = nil
    }
}

// MARK: - Icon

struct SourceIcon: View {
    let url: URL?
    let side: CGFloat
    var fallback: String = ""
    var body: some View {
        AsyncImage(url: url) { phase in
            if let img = phase.image { img.resizable().scaledToFill() }
            else {
                ZStack {
                    RoundedRectangle(cornerRadius: side * 0.22, style: .continuous).fill(Theme.accent.opacity(0.15))
                    Text(String(fallback.prefix(1)).uppercased()).font(.system(size: side * 0.42, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }
}
