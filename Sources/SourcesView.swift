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

nonisolated struct RepoSource: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var url: URL
    var iconURL: URL?
    var description: String
    var author: String?
    var appCount: Int?
    var lastFetched: Date?
}

nonisolated struct SourceApp: Identifiable, Equatable, Sendable, Codable {
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
    var featured: Bool = false
    var tintHex: String? = nil

    // Precomputed once at parse time — never touch formatters or lowercase() in a View body.
    var updatedDate: Date? = nil
    var searchKey: String = ""
    var sizeValue: Double = 0
    var categoryRaw: String? = nil          // repo-provided "category" if any
    var category: AppCategory = .tools

    nonisolated(unsafe) private static let isoFull: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    nonisolated(unsafe) private static let isoDate: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f }()

    func precomputed() -> SourceApp {
        var a = self
        a.updatedDate = Self.isoFull.date(from: updated) ?? Self.isoDate.date(from: updated)
        a.searchKey = (name + " " + subtitle + " " + bundle).lowercased()
        a.sizeValue = Double(sizeMB.split(separator: " ").first ?? "") ?? 0
        a.category = AppCategory.infer(explicit: categoryRaw, text: name + " " + subtitle + " " + description)
        return a
    }
}

/// Browse categories (chip row under News). Repo "category" wins; otherwise inferred from text.
nonisolated enum AppCategory: String, CaseIterable, Sendable, Codable {
    case all, tools, paid, jailbreak, media, social, car, emu
    var title: String { rawValue.uppercased() }
    var icon: String {
        switch self {
        case .all: return "app.badge"; case .tools: return "wrench.and.screwdriver.fill"; case .paid: return "dollarsign"
        case .jailbreak: return "lock.open.fill"; case .media: return "film.stack.fill"; case .social: return "person.3.fill"
        case .car: return "car.fill"; case .emu: return "gamecontroller.fill"
        }
    }
    private static let rules: [(AppCategory, [String])] = [
        (.jailbreak, ["jailbreak", "dopamine", "trollstore", "palera", "unc0ver", "checkra", "sileo", "cydia", "rootless", "tweak", "ellekit", "substrate"]),
        (.emu,       ["emulator", "emu ", "delta", "ppsspp", "dolphin", "retroarch", "provenance", "gba", "nds", "nintendo", "playstation", "ps1", "n64", "snes", "gamecube", "citra", "melon"]),
        (.car,       ["carplay", "car play", "car ", "vehicle", "obd", "tesla", "dash cam", "waze", "gps", "navigation", "driving", "auto "]),
        (.social,    ["social", "instagram", "snapchat", "tiktok", "twitter", "reddit", "discord", "telegram", "whatsapp", "messenger", "facebook", "threads", "bereal", "chat"]),
        (.media,     ["music", "video", "stream", "movie", "netflix", "spotify", "youtube", "audiomack", "soundcloud", "player", "podcast", "tv", "anime", "manga", "photo", "camera", "editor", "vlc"]),
        (.tools,     ["tool", "utility", "manager", "file", "vpn", "proxy", "terminal", "ssh", "signer", "sign ", "certificate", "inspector", "ipa", "installer", "downloader", "browser", "keyboard", "clean", "backup"]),
    ]
    static func infer(explicit: String?, text: String) -> AppCategory {
        if let e = explicit?.lowercased() {
            if e.contains("jail") { return .jailbreak }
            if e.contains("emu") || e.contains("game") { return .emu }
            if e.contains("car") || e.contains("auto") { return .car }
            if e.contains("social") || e.contains("messag") { return .social }
            if e.contains("media") || e.contains("music") || e.contains("video") || e.contains("photo") || e.contains("entertain") { return .media }
            if e.contains("tool") || e.contains("util") || e.contains("dev") || e.contains("product") { return .tools }
            if e.contains("paid") { return .paid }
        }
        let t = text.lowercased()
        // Normalise so "「✓PAID APP」", "PAID  APP", "Paid-App", fullwidth spaces etc. all collapse to "paidapp".
        let squashed = t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { Character($0) }
        let flat = String(squashed)
        if flat.contains("paidapp") || flat.contains("paidversion") || flat.contains("paidunlock") || flat.contains("paidfree")
            || t.contains("✓paid") || t.contains("✓ paid") || t.contains("$ paid") || t.contains("paid ipa") { return .paid }
        for (cat, keys) in rules where keys.contains(where: { t.contains($0) }) { return cat }
        return .tools
    }
}

/// One app = one bundle id; a source can list many versions of it.
nonisolated struct AppGroup: Identifiable, Equatable, Sendable {
    let bundle: String
    let versions: [SourceApp]          // newest first
    var id: String { bundle }
    var latest: SourceApp { versions[0] }

    static func group(_ apps: [SourceApp]) -> [AppGroup] {
        var order: [String] = []
        var dict: [String: [SourceApp]] = [:]
        for a in apps {
            if dict[a.bundle] == nil { order.append(a.bundle) }
            if !(dict[a.bundle]?.contains { $0.version == a.version } ?? false) { dict[a.bundle, default: []].append(a) }
        }
        return order.map { b in
            AppGroup(bundle: b, versions: dict[b]!.sorted {
                let d0 = $0.updatedDate ?? .distantPast, d1 = $1.updatedDate ?? .distantPast
                if d0 != d1 { return d0 > d1 }
                return $0.version.compare($1.version, options: .numeric) == .orderedDescending
            })
        }
    }
}

nonisolated struct SourceNews: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let title: String
    let caption: String
    let imageURL: URL?
    let url: URL?
    let appID: String?
    let date: String
    let tintHex: String?
}

// MARK: - Parser (ported from mSign's RepoParser; accepts many repo.json dialects)

nonisolated enum RepoParser {
    struct ParsedRepo: Sendable {
        let name: String
        let iconURL: URL?
        let description: String?
        let author: String?
        let apps: [SourceApp]
        let news: [SourceNews]
        // Built once (off the main thread) so the list, sort and search are free at render time.
        let groups: [AppGroup]
        let byUpdated: [AppGroup]
        let byName: [AppGroup]
        let bySize: [AppGroup]
        let featuredNews: [SourceNews]
        let groupIndex: [String: Int]

        init(name: String, iconURL: URL?, description: String?, author: String?, apps rawApps: [SourceApp], news: [SourceNews], alreadyPrecomputed: Bool = false) {
            self.name = name; self.iconURL = iconURL; self.description = description; self.author = author
            let apps = alreadyPrecomputed ? rawApps : rawApps.map { $0.precomputed() }
            self.apps = apps
            self.news = news
            let g = AppGroup.group(apps)
            groups = g
            byUpdated = g.sorted { ($0.latest.updatedDate ?? .distantPast) > ($1.latest.updatedDate ?? .distantPast) }
            byName    = g.sorted { $0.latest.name.localizedCaseInsensitiveCompare($1.latest.name) == .orderedAscending }
            bySize    = g.sorted { $0.latest.sizeValue > $1.latest.sizeValue }
            var idx: [String: Int] = [:]; for (i, x) in g.enumerated() { idx[x.bundle] = i }
            groupIndex = idx
            featuredNews = news.isEmpty ? g.filter { $0.latest.featured }.prefix(12).map { grp in
                let a = grp.latest
                return SourceNews(id: "feat-" + a.bundle, title: a.name, caption: a.description, imageURL: a.screenshots.first ?? a.iconURL,
                                  url: nil, appID: a.bundle, date: a.updated, tintHex: a.tintHex)
            } : news
        }

        // MARK: persisted index (apps carry their precomputed fields, so decode = no parsing, no formatters)
        private struct Index: Codable { let v: Int; let name: String; let iconURL: URL?; let description: String?; let author: String?; let apps: [SourceApp]; let news: [SourceNews] }
        static let indexVersion = 4
        func indexData() -> Data? {
            try? JSONEncoder().encode(Index(v: Self.indexVersion, name: name, iconURL: iconURL, description: description, author: author, apps: apps, news: news))
        }
        static func fromIndex(_ data: Data) -> ParsedRepo? {
            guard let i = try? JSONDecoder().decode(Index.self, from: data), i.v == indexVersion else { return nil }
            return ParsedRepo(name: i.name, iconURL: i.iconURL, description: i.description, author: i.author, apps: i.apps, news: i.news, alreadyPrecomputed: true)
        }

        func sorted(_ key: String) -> [AppGroup] {
            switch key { case "Name": return byName; case "Size": return bySize; default: return byUpdated }
        }
        func group(bundle: String) -> AppGroup? { groupIndex[bundle].map { groups[$0] } }
    }

    static func parse(data: Data, fallbackName: String) throws -> ParsedRepo {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            // Bare array of apps
            let apps = ((obj as? [[String: Any]]) ?? []).compactMap(mapApp)
            return ParsedRepo(name: fallbackName, iconURL: nil, description: nil, author: nil, apps: apps, news: [])
        }
        var name = (root["name"] as? String) ?? (root["repoName"] as? String) ?? (root["title"] as? String)
            ?? (root["sourceName"] as? String) ?? fallbackName
        if name.lowercased().hasSuffix(" repo") { name = String(name.dropLast(5)) }
        let meta = root["META"] as? [String: Any] ?? [:]
        let icon = firstURL(root, ["iconURL", "iconUrl", "icon", "repoIcon", "sourceIcon", "sourceicon"]) ?? firstURL(meta, ["repoIcon", "iconURL"])
        let desc = (root["description"] as? String) ?? (root["subtitle"] as? String) ?? (root["caption"] as? String)
        let author = (root["author"] as? String) ?? (root["developer"] as? String) ?? (root["identifier"] as? String)
        let arr = (root["apps"] as? [[String: Any]]) ?? (root["Applications"] as? [[String: Any]])
            ?? (root["items"] as? [[String: Any]]) ?? (root["packages"] as? [[String: Any]])
            ?? ((root["repo"] as? [String: Any])?["apps"] as? [[String: Any]]) ?? []
        let newsArr = (root["news"] as? [[String: Any]]) ?? []
        let news: [SourceNews] = newsArr.enumerated().compactMap { i, n in
            guard let title = n["title"] as? String else { return nil }
            return SourceNews(id: (n["identifier"] as? String) ?? "news-\(i)", title: title,
                              caption: (n["caption"] as? String) ?? "", imageURL: firstURL(n, ["imageURL", "image"]),
                              url: firstURL(n, ["url"]), appID: n["appID"] as? String,
                              date: (n["date"] as? String) ?? "", tintHex: n["tintColor"] as? String)
        }
        return ParsedRepo(name: name, iconURL: icon, description: desc, author: author, apps: arr.compactMap(mapApp), news: news)
    }

    private static func firstURL(_ d: [String: Any], _ keys: [String]) -> URL? {
        for k in keys { if let s = d[k] as? String, let u = URL(string: s) { return u } }
        return nil
    }

    private static func mapApp(_ a: [String: Any]) -> SourceApp? {
        guard let name = (a["name"] as? String) ?? (a["displayName"] as? String) ?? (a["title"] as? String) else { return nil }
        let bundle = (a["bundleIdentifier"] as? String) ?? (a["bundleID"] as? String) ?? (a["bundle"] as? String) ?? (a["identifier"] as? String) ?? "unknown.bundle"
        let subtitle = (a["subtitle"] as? String) ?? (a["developer"] as? String) ?? (a["developerName"] as? String) ?? (a["author"] as? String) ?? (a["category"] as? String) ?? ""
        let desc = (a["localizedDescription"] as? String) ?? (a["description"] as? String) ?? (a["versionDescription"] as? String) ?? (a["summary"] as? String) ?? ""

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
                         iconURL: icon, downloadURL: dl, screenshots: shots,
                         featured: (a["featured"] as? Bool) ?? false, tintHex: a["tintColor"] as? String,
                         categoryRaw: (a["category"] as? String) ?? (a["genre"] as? String) ?? (a["type"] as? String))
    }
}

// MARK: - Store

@MainActor
final class SourceStore: ObservableObject {
    static let shared = SourceStore()
    @Published private(set) var sources: [RepoSource] = []
    private let fileURL = AppPaths.dir("sources").appendingPathComponent("sources.json")
    private var parsedCache: [String: RepoParser.ParsedRepo] = [:]
    private var prefetchingIDs: Set<String> = []

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

    // Raw repo.json bytes cached on disk so a cold launch shows the list instantly, then refreshes.
    private nonisolated static let rawCacheDir: URL = {
        let d = AppPaths.dir("sources").appendingPathComponent("raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private nonisolated static func rawCacheURL(_ id: String) -> URL {
        rawCacheDir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
    }
    private nonisolated static func indexCacheURL(_ id: String) -> URL {
        rawCacheDir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".index.json")
    }
    private nonisolated static func persistIndex(_ parsed: RepoParser.ParsedRepo, for source: RepoSource) {
        Task.detached(priority: .utility) {
            if let d = parsed.indexData() { try? d.write(to: indexCacheURL(source.id), options: .atomic) }
        }
    }
    /// Warm the first 40 icons (by "recently updated") so the list paints with no placeholders.
    private nonisolated static func prefetchIcons(_ parsed: RepoParser.ParsedRepo) {
        let urls = parsed.byUpdated.prefix(40).compactMap { $0.latest.iconURL }
        Task.detached(priority: .utility) { await IconCache.shared.prefetch(Array(urls)) }
    }

    private nonisolated static func requestParsedRepo(for source: RepoSource) async throws -> RepoParser.ParsedRepo {
        var req = URLRequest(url: source.url); req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else {
            throw GitHubError.badConfig("Source returned HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let parsed = try await Task.detached(priority: .userInitiated) { try RepoParser.parse(data: data, fallbackName: source.name) }.value
        try? data.write(to: rawCacheURL(source.id), options: .atomic)
        persistIndex(parsed, for: source)
        prefetchIcons(parsed)
        return parsed
    }

    /// Parse the on-disk copy (if any) off the main thread.
    private nonisolated static func cachedParsedRepoFromDisk(for source: RepoSource) async -> RepoParser.ParsedRepo? {
        // 1. Persisted index: plain Codable decode, no dialect parsing, no date formatters. ~tens of ms for 10k apps.
        if let d = try? Data(contentsOf: indexCacheURL(source.id)),
           let p = await Task.detached(priority: .userInitiated, operation: { RepoParser.ParsedRepo.fromIndex(d) }).value {
            prefetchIcons(p)
            return p
        }
        // 2. Raw repo.json fallback (older cache or index version bump) — parse, then write the index for next time.
        guard let data = try? Data(contentsOf: rawCacheURL(source.id)) else { return nil }
        let p = await Task.detached(priority: .userInitiated) { try? RepoParser.parse(data: data, fallbackName: source.name) }.value
        if let p { persistIndex(p, for: source); prefetchIcons(p) }
        return p
    }

    /// Call once at launch: hydrate every source from disk (instant), then refresh from the network in the background.
    func warmUpAtLaunch() async {
        let snapshot = sources
        await withTaskGroup(of: (RepoSource, RepoParser.ParsedRepo?).self) { group in
            for src in snapshot where parsedCache[src.id] == nil {
                group.addTask { (src, await Self.cachedParsedRepoFromDisk(for: src)) }
            }
            for await (src, parsed) in group {
                if let parsed, parsedCache[src.id] == nil { applyParsedRepo(parsed, to: src) }
            }
        }
        await refreshAllInBackground()
    }

    /// Refresh every source from the network without evicting what's already cached.
    func refreshAllInBackground() async {
        let snapshot = sources.filter { !prefetchingIDs.contains($0.id) }
        snapshot.forEach { prefetchingIDs.insert($0.id) }
        await withTaskGroup(of: (RepoSource, RepoParser.ParsedRepo?).self) { group in
            for source in snapshot {
                group.addTask(priority: .utility) { (source, try? await Self.requestParsedRepo(for: source)) }
            }
            for await (source, parsed) in group {
                prefetchingIDs.remove(source.id)
                if let parsed { applyParsedRepo(parsed, to: source) }
            }
        }
    }

    private func applyParsedRepo(_ parsed: RepoParser.ParsedRepo, to source: RepoSource) {
        var updated = source
        if updated.name.isEmpty || updated.id.hasPrefix("custom-") { updated.name = parsed.name }
        if updated.iconURL == nil { updated.iconURL = parsed.iconURL }
        if let desc = parsed.description, !desc.isEmpty, updated.description.isEmpty || updated.id.hasPrefix("custom-") { updated.description = desc }
        if let author = parsed.author { updated.author = author }
        updated.appCount = parsed.groups.count
        updated.lastFetched = Date()
        parsedCache[source.id] = parsed
        update(updated)
    }

    func add(_ s: RepoSource) {
        let replacedIDs = sources.filter { $0.url == s.url }.map(\.id)
        replacedIDs.forEach { parsedCache.removeValue(forKey: $0) }
        sources.removeAll { $0.url == s.url }
        sources.append(s)
        save()
    }
    func update(_ s: RepoSource) {
        if let i = sources.firstIndex(where: { $0.id == s.id }) {
            let oldURL = sources[i].url
            sources[i] = s
            if oldURL != s.url { parsedCache.removeValue(forKey: s.id) }
            save()
        }
    }
    func remove(_ s: RepoSource) {
        sources.removeAll { $0.id == s.id }; parsedCache.removeValue(forKey: s.id); save()
        try? FileManager.default.removeItem(at: Self.rawCacheURL(s.id))
        try? FileManager.default.removeItem(at: Self.indexCacheURL(s.id))
    }
    func move(from: IndexSet, to: Int) { sources.move(fromOffsets: from, toOffset: to); save() }
    private func save() { try? JSONEncoder().encode(sources).write(to: fileURL) }
    func cachedParsedRepo(for source: RepoSource) -> RepoParser.ParsedRepo? { parsedCache[source.id] }

    /// Fetch + parse a repo.json, cache the parsed result, and update the source metadata.
    func fetch(_ s: RepoSource) async throws -> RepoParser.ParsedRepo {
        let parsed = try await Self.requestParsedRepo(for: s)
        applyParsedRepo(parsed, to: s)
        return parsed
    }

    func prefetchSources() async {
        // Fill any hole left by warmUpAtLaunch (e.g. a source added since).
        for src in sources where parsedCache[src.id] == nil {
            if let p = await Self.cachedParsedRepoFromDisk(for: src), parsedCache[src.id] == nil { applyParsedRepo(p, to: src) }
        }
        let snapshot = sources.filter { parsedCache[$0.id] == nil && !prefetchingIDs.contains($0.id) }
        snapshot.forEach { prefetchingIDs.insert($0.id) }
        await withTaskGroup(of: (RepoSource, RepoParser.ParsedRepo?).self) { group in
            for source in snapshot {
                group.addTask { (source, try? await Self.requestParsedRepo(for: source)) }
            }
            for await (source, parsed) in group {
                prefetchingIDs.remove(source.id)
                guard let parsed else { continue }
                applyParsedRepo(parsed, to: source)
            }
        }
    }
}

// MARK: - Sources list (Browse tab)

struct SourcesView: View {
    @ObservedObject private var store = SourceStore.shared
    @State private var editing = false
    @State private var adding = false
    @State private var newURL = ""
    @State private var addError: String?

    var body: some View {
        NavigationStack {
            sourcesBody
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: RepoSource.self) { s in
                    SourceDetailScreen(source: s).toolbar(.hidden, for: .navigationBar)
                }
        }
        .tint(Theme.accent)
    }

    private var sourcesBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                List {
                    ForEach(store.sources) { s in
                        NavigationLink(value: s) { sourceRow(s) }
                            .disabled(editing)
                            .opacity(1)
                            .listRowBackground(Color.black)
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
                .safeAreaInset(edge: .top, spacing: 0) {
                    TabTitleBar(title: "Sources") {
                        Button(editing ? "Done" : "Edit") { withAnimation { editing.toggle() } }
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                        Button { adding = true } label: {
                            Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                        .padding(.leading, 6)
                    }
                }
            }
        }
        .alert("Add source", isPresented: $adding) {
            TextField("https://example.com/repo.json", text: $newURL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add") { add() }
            Button("Cancel", role: .cancel) { newURL = "" }
        } message: { Text(addError ?? "Paste a repo.json URL (AltStore, Feather, DELvEK, mSign formats).") }
        .task { await store.prefetchSources() }
    }

    private func sourceRow(_ s: RepoSource) -> some View {
        HStack(spacing: 14) {
            SourceIcon(url: s.iconURL, side: 54, fallback: s.name)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.name).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(s.description.isEmpty ? s.url.host ?? s.url.absoluteString : s.description)
                    .font(.system(size: 13)).foregroundStyle(Theme.subtle).lineLimit(1)
                if let n = s.appCount { Text("\(n) apps").font(.caption2.monospaced()).foregroundStyle(Theme.accent) }
            }
            Spacer()
            Image(systemName: "arrow.up.forward.square").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.accent)
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
    @State private var openGroup: AppGroup?
    @State private var visibleGroupCount = 6

    private enum Sort: String, CaseIterable { case updated = "Recently updated", name = "Name", size = "Size" }

    private var current: RepoSource { store.sources.first { $0.id == source.id } ?? source }

    /// The list actually rendered. Recomputed off-main (debounced) when search/sort/parsed change — never in `body`.
    @State private var groups: [AppGroup] = []
    @State private var filterTask: Task<Void, Never>?
    @State private var category: AppCategory = .all
    private var visibleGroups: [AppGroup] { Array(groups.prefix(visibleGroupCount)) }
    private var news: [SourceNews] { parsed?.featuredNews ?? [] }

    private func recompute(debounce: Bool) {
        filterTask?.cancel()
        guard let p = parsed else { groups = []; return }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let base = p.sorted(sort.rawValue == "Name" ? "Name" : (sort.rawValue == "Size" ? "Size" : "Updated"))
        let cat = category
        if q.isEmpty && cat == .all { groups = base; return }
        filterTask = Task {
            if debounce { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled else { return }
            let out = await Task.detached(priority: .userInitiated) {
                base.filter { g in
                    (cat == .all || g.latest.category == cat) &&
                    (q.isEmpty || g.versions.contains { $0.searchKey.contains(q) })
                }
            }.value
            guard !Task.isCancelled else { return }
            groups = out
        }
    }

    var body: some View {
        List {
            if let error {
                Card { Text(error).font(.caption).foregroundStyle(.orange) }
                    .listRowBackground(Color.black).listRowSeparator(.hidden)
            }
            if loading {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                    .listRowBackground(Color.black).listRowSeparator(.hidden)
            }
            if !news.isEmpty {
                newsSection
                    .listRowBackground(Color.black).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 4, trailing: 0))
            }
            if parsed != nil {
                categoryRow
                    .listRowBackground(Color.black).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 14, trailing: 0))
            }
            ForEach(visibleGroups) { g in
                appRow(g)
                    .listRowBackground(Color.black)
                    .listRowSeparatorTint(Theme.stroke)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .onAppear { loadMoreIfNeeded(current: g) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                countBar
                if showSearch {
                    TextField("Search \(current.name)", text: $search)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .padding(10).background(Theme.card.opacity(0.8)).foregroundStyle(Theme.text)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            .floatingGlassBar(edge: .top)
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            if let cached = store.cachedParsedRepo(for: current) {
                parsed = cached
                loading = false
                recompute(debounce: false)
                // Already warm: refresh quietly only if the copy is older than 10 minutes.
                if let t = current.lastFetched, Date().timeIntervalSince(t) < 600 { return }
            }
            await load(showSpinner: parsed == nil)
        }
        .onChange(of: search) { _ in visibleGroupCount = 6; recompute(debounce: true) }
        .onChange(of: sort) { _ in visibleGroupCount = 6; recompute(debounce: false) }
        .onChange(of: category) { _ in visibleGroupCount = 6; recompute(debounce: false) }
        .onChange(of: parsed?.apps.count) { _ in recompute(debounce: false) }
        .sheet(item: $openGroup) { g in
            AppDetailSheet(source: current, group: g)
                .then { view in
                    if #available(iOS 16.0, *) {
                        view.presentationDragIndicator(.visible)
                    } else {
                        view
                    }
                }
                .preferredColorScheme(.dark)
        }
    }

    // Header: back · icon + NAME · search · sort
    private var header: some View {
        ZStack {
            // centered: repo icon + name
            HStack(spacing: 8) {
                SourceIcon(url: current.iconURL, side: 24, fallback: current.name)
                Text(current.name.uppercased()).font(.system(size: 17, weight: .bold)).kerning(0.6).foregroundStyle(Theme.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.horizontal, 100)
            // edges: ‹ Browse … search · sort
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text("Browse").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    }
                    .frame(height: 30)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { withAnimation { showSearch.toggle() } } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 30, height: 30)
                }
                Menu {
                    ForEach(Sort.allCases, id: \.self) { s in Button(s.rawValue) { sort = s } }
                    Divider()
                    Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Link(destination: current.url) { Label("Open repo.json", systemImage: "safari") }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 30, height: 30)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var countBar: some View {
        HStack(spacing: 8) {
            Text("\(groups.count.formatted()) Apps").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 6)
            AccountChip()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
    }

    // Category chips (ALL · TOOLS · PAID · JAILBREAK / MEDIA · SOCIAL · CAR · EMU) — compact, single-line, two rows
    private var categoryRow: some View {
        let cats = AppCategory.allCases
        let rows = [Array(cats.prefix(4)), Array(cats.dropFirst(4))]
        return VStack(spacing: 6) {
            ForEach(0..<rows.count, id: \.self) { r in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(rows[r], id: \.self) { c in categoryChip(c) }
                    }
                    .padding(.horizontal, 16)
                    .frame(minWidth: UIScreen.main.bounds.width, alignment: .center)
                }
            }
        }
    }

    private func categoryChip(_ c: AppCategory) -> some View {
        let on = c == category
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeInOut(duration: 0.15)) { category = c }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: c.icon).font(.system(size: 11, weight: .bold))
                Text(c.title).font(.system(size: 12, weight: .heavy, design: .monospaced)).kerning(0.4)
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(on ? Theme.accent : Theme.text)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(on ? Theme.accent.opacity(0.18) : Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Theme.accent.opacity(0.7) : Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(parsed?.news.isEmpty == false ? "NEWS" : "FEATURED")
                .font(.system(size: 12, weight: .bold)).kerning(1.5).foregroundStyle(Theme.subtle).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(news) { n in newsCard(n) }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func newsCard(_ n: SourceNews) -> some View {
        let tint = Color.fromTint(n.tintHex) ?? Theme.accent
        return Button { openNews(n) } label: {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: n.imageURL) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { tint.opacity(0.25) }
                }
                .frame(width: 250, height: 118).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text(n.title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    if !n.caption.isEmpty { Text(n.caption).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(2) }
                }
                .padding(12)
            }
            .frame(width: 250, height: 118)
            .background(tint.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(tint.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func openNews(_ n: SourceNews) {
        if let id = n.appID, let g = parsed?.group(bundle: id) { openGroup = g; return }
        if let u = n.url { UIApplication.shared.open(u) }
    }

    private func appRow(_ g: AppGroup) -> some View {
        let app = g.latest
        let have = signed.entries.contains { $0.bundleID == app.bundle } || IPAInbox.has(app)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                SourceIcon(url: app.iconURL, side: 56, fallback: app.name)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(app.name).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                        if g.versions.count > 1 {
                            Text("\(g.versions.count) versions").font(.system(size: 10, weight: .heavy, design: .monospaced)).kerning(0.5)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Theme.accent.opacity(0.16)).foregroundStyle(Theme.accent).clipShape(Capsule())
                        }
                    }
                    Text("\(app.sizeMB) | \(app.version) | \(app.subtitle)")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.subtle).lineLimit(1)
                    if !app.description.isEmpty {
                        Text(app.description).font(.system(size: 13)).foregroundStyle(Theme.subtle).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { openGroup = g }
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
                                Image(systemName: "sdcard.fill").font(.system(size: 20, weight: .bold))
                            } else {
                                Image(systemName: "arrow.down").font(.system(size: 20, weight: .bold))
                            }
                        }
                        .frame(width: 30, height: 30).foregroundStyle(Theme.accent)
                    }
                    .disabled(downloading != nil || app.downloadURL == nil)
                    Text("Views: \(app.downloads)").font(.system(size: 11)).foregroundStyle(Theme.subtle)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { openGroup = g }
            if !app.screenshots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(app.screenshots.prefix(8).enumerated()), id: \.offset) { _, u in
                            AsyncImage(url: u) { phase in
                                if let img = phase.image { img.resizable().scaledToFill() }
                                else { Theme.card.overlay(ProgressView().tint(Theme.accent)) }
                            }
                            .frame(width: 126, height: 270)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                            .onTapGesture { openGroup = g }
                        }
                    }
                }
            }
        }
    }

    private func load(showSpinner: Bool = true) async {
        if showSpinner { loading = true }
        error = nil
        do { parsed = try await store.fetch(current) } catch { self.error = error.localizedDescription }
        visibleGroupCount = 6
        loading = false
        recompute(debounce: false)
    }

    private func loadMoreIfNeeded(current group: AppGroup) {
        guard group.id == visibleGroups.last?.id, visibleGroupCount < groups.count else { return }
        visibleGroupCount = min(visibleGroupCount + 6, groups.count)
    }

    private func download(_ app: SourceApp) async {
        downloading = app.id; progress = 0; error = nil
        do {
            let dest = try await IPADownloader.shared.download(app) { p in Task { @MainActor in progress = p } }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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
    var body: some View { CachedIcon(url: url, side: side, fallback: fallback) }
}
}

// MARK: - Inbox + downloader (progress-reporting)

nonisolated enum IPAInbox {
    static func url(for app: SourceApp) -> URL {
        let safe = app.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return AppPaths.dir("inbox").appendingPathComponent("\(safe)-\(app.version).ipa")
    }
    static func has(_ app: SourceApp) -> Bool { FileManager.default.fileExists(atPath: url(for: app).path) }
    static func size(_ app: SourceApp) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url(for: app).path)[.size] as? Int64) ?? 0
    }
}

nonisolated final class IPADownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = IPADownloader()
    private var session: URLSession!
    private var handlers: [Int: (progress: @Sendable (Double) -> Void, done: @Sendable (Result<URL, Error>) -> Void, dest: URL)] = [:]
    private let lock = NSLock()

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    /// Downloads to the inbox; returns immediately if it's already on device.
    func download(_ app: SourceApp, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let src = app.downloadURL else { throw GitHubError.badConfig("This app has no download URL in the source.") }
        let dest = IPAInbox.url(for: app)
        if FileManager.default.fileExists(atPath: dest.path) { progress(1); return dest }
        return try await withCheckedThrowingContinuation { cont in
            var req = URLRequest(url: src)
            req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: req)
            lock.lock(); handlers[task.taskIdentifier] = (progress, { cont.resume(with: $0) }, dest); lock.unlock()
            task.resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let h = handlers[downloadTask.taskIdentifier]; lock.unlock()
        guard let h, totalBytesExpectedToWrite > 0 else { return }
        h.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let h = handlers.removeValue(forKey: downloadTask.taskIdentifier); lock.unlock()
        guard let h else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code < 400 else { h.done(.failure(GitHubError.badConfig("Download failed (HTTP \(code))"))); return }
        do {
            try? FileManager.default.removeItem(at: h.dest)
            try FileManager.default.moveItem(at: location, to: h.dest)
            h.done(.success(h.dest))
        } catch { h.done(.failure(error)) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock(); let h = handlers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        h?.done(.failure(error))
    }
}

// MARK: - App detail sheet (mSign layout)

struct AppDetailSheet: View {
    let source: RepoSource
    let group: AppGroup
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var signed = SignedStore.shared

    @State private var selectedID: String = ""
    private var app: SourceApp { group.versions.first { $0.id == selectedID } ?? group.latest }

    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var onDevice = false
    @State private var error: String?

    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)

    private var detailTitleBar: some View {
        ZStack {
            HStack(spacing: 8) {
                SourceIcon(url: source.iconURL, side: 22, fallback: source.name)
                Text(source.name.uppercased()).font(.system(size: 15, weight: .bold)).kerning(1).foregroundStyle(Theme.text)
            }
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                        .frame(width: 32, height: 32).background(Color.white.opacity(0.12)).clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .floatingGlassBar(edge: .top)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    infoCard
                    Text("SCREENSHOTS").font(.system(size: 13, weight: .bold)).kerning(1.5).foregroundStyle(Theme.subtle)
                    if app.screenshots.isEmpty {
                        Text("No screenshots.").font(.caption).foregroundStyle(Theme.subtle)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(Array(app.screenshots.enumerated()), id: \.offset) { _, u in
                                    AsyncImage(url: u) { phase in
                                        if let img = phase.image { img.resizable().scaledToFill() }
                                        else { Theme.card.overlay(ProgressView().tint(blue)) }
                                    }
                                    .frame(width: 150, height: 325)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                                }
                            }
                        }
                    }
                    Text("\(group.versions.count) Versions Available").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.subtle)
                    ForEach(group.versions) { v in versionRow(v) }
                    if downloading || onDevice { serverDownloadCard }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                    Spacer(minLength: 20)
                }
                .padding(16)
            }
            .safeAreaInset(edge: .top, spacing: 0) { detailTitleBar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar.floatingGlassBar(edge: .bottom)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { selectedID = group.latest.id; refreshDevice() }
        .onChange(of: selectedID) { _ in refreshDevice() }
    }

    private func refreshDevice() {
        onDevice = IPAInbox.has(app); progress = onDevice ? 1 : 0
    }

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    SourceIcon(url: app.iconURL, side: 64, fallback: app.name)
                        .shadow(color: blue.opacity(0.55), radius: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.text).lineLimit(2).minimumScaleFactor(0.8)
                        Text(app.subtitle.isEmpty ? (source.url.host ?? "") : app.subtitle)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(blue).lineLimit(1)
                        Text(app.bundle).font(.system(size: 10, design: .monospaced)).foregroundStyle(blue.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text((source.author ?? "MRzefv").uppercased() + " EDITION").font(.system(size: 12, weight: .bold)).kerning(1).foregroundStyle(blue)
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.system(size: 13)).foregroundStyle(blue)
                        Text(app.description.isEmpty ? "No description." : app.description).font(.system(size: 13)).foregroundStyle(Theme.text)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            VStack(spacing: 6) {
                stat("v\(app.version)", "VERSION")
                stat(app.sizeMB, "SIZE")
                stat(updatedText, "UPDATED")
                stat(app.downloads, "DOWNLOADS")
                stat(signed.entries.filter { $0.bundleID == app.bundle }.count.description, "SIGNED")
            }
            .frame(width: 74)
        }
        .padding(10)
        .background(Color(white: 0.11)).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stat(_ v: String, _ k: String) -> some View {
        VStack(spacing: 4) {
            Text(v).font(.system(size: 13, weight: .bold)).foregroundStyle(blue).lineLimit(1).minimumScaleFactor(0.6)
            Text(k).font(.system(size: 8, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.subtle)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var updatedText: String { ageText(app.updated) }

    private func ageText(_ s: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withFullDate]
        if let d = f.date(from: s) ?? f2.date(from: s) {
            let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
            return days == 0 ? "today" : (days == 1 ? "1 day ago" : "\(days) days ago")
        }
        return s
    }

    private func versionRow(_ v: SourceApp) -> some View {
        let sel = v.id == selectedID
        return Button { selectedID = v.id } label: {
            HStack(spacing: 14) {
                Circle().fill(sel ? blue : Theme.subtle.opacity(0.4)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text("v\(v.version)").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                    Text("\(v.sizeMB)  \(ageText(v.updated))").font(.system(size: 13)).foregroundStyle(Theme.subtle)
                }
                Spacer()
                if IPAInbox.has(v) { Image(systemName: "internaldrive.fill").font(.system(size: 14)).foregroundStyle(.green) }
                if sel { Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(blue) }
            }
            .padding(12)
            .background(sel ? Color(red: 0.06, green: 0.09, blue: 0.16) : Color(white: 0.09))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(sel ? blue.opacity(0.35) : Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var serverDownloadCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Server Download").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.subtle)
                Spacer()
                if !onDevice { Text("\(Int(progress * 100))%").font(.system(size: 14, weight: .bold)).foregroundStyle(blue) }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 8)
                    Capsule().fill(onDevice ? Color.green : blue).frame(width: max(8, g.size.width * progress), height: 8)
                }
            }
            .frame(height: 8)
            VStack(alignment: .leading, spacing: 8) {
                Label("Downloading to device…", systemImage: "arrow.down.square.fill").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.subtle)
                Label(source.url.host ?? source.name, systemImage: "globe").font(.system(size: 13, design: .monospaced)).foregroundStyle(blue)
                if onDevice {
                    Label("\(ByteCountFormatter.string(fromByteCount: IPAInbox.size(app), countStyle: .file)) on device — no re-download at sign", systemImage: "sdcard.fill")
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(blue)
                }
            }
        }
        .padding(12).background(Color(white: 0.11)).clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var bottomBar: some View {
        HStack {
            Button { Task { await download() } } label: {
                VStack(spacing: 4) {
                    if downloading { ProgressView().tint(blue).frame(height: 26) }
                    else if onDevice { Image(systemName: "sdcard.fill").font(.system(size: 24)) }
                    else { Image(systemName: "arrow.down.circle").font(.system(size: 26)) }
                    Text(downloading ? "Downloading" : (onDevice ? "Downloaded" : "Download")).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(blue).frame(width: 100)
            }
            .disabled(downloading || app.downloadURL == nil)
            Spacer()
            VStack(spacing: 2) {
                Text("MRZefv").font(.system(size: 14, weight: .bold)).foregroundStyle(.orange).lineLimit(1)
                Text("Powered by \((source.url.host ?? source.name).uppercased())").font(.system(size: 9, weight: .semibold)).foregroundStyle(blue).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            Spacer()
            Button {
                dismiss(); SignQueue.shared.enqueue(IPAInbox.url(for: app))
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "signature").font(.system(size: 26))
                    Text("Sign IPA").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(onDevice ? blue : Theme.subtle).frame(width: 100)
            }
            .disabled(!onDevice)
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .top)
    }

    private func download() async {
        downloading = true; error = nil; progress = 0
        do {
            _ = try await IPADownloader.shared.download(app) { p in Task { @MainActor in progress = p } }
            onDevice = true; progress = 1
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = error.localizedDescription }
        downloading = false
    }
}


// MARK: - Liquid Glass bars
//
// Real `.glassEffect` on iOS 26; on 16–18 a material with a glass rim + drop
// shadow so it reads the same. Bars are meant to FLOAT: put them in
// `.safeAreaInset(edge:)` so the scroll content slides underneath them.

struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 26
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(Color(white: 0.08).opacity(0.35), in: shape)
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06), .white.opacity(0.14)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
    }
}

extension View {
    /// Glass pill/card surface.
    func liquidGlass(cornerRadius: CGFloat = 26) -> some View { modifier(GlassSurface(cornerRadius: cornerRadius)) }

    /// Floating glass bar inset from the screen edges. Use inside `.safeAreaInset(edge:)`
    /// so content scrolls beneath it; the bar itself sits in the safe area.
    func floatingGlassBar(edge: Edge = .bottom, cornerRadius: CGFloat = 26) -> some View {
        self.liquidGlass(cornerRadius: cornerRadius)
            .padding(.horizontal, 12)
            .padding(edge == .top ? .bottom : .top, 6)
            .padding(edge == .top ? .top : .bottom, 2)
    }
}

/// Edge-to-edge glass (kept for full-width bars that aren't meant to float).
struct BarBlur: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(white: 0.06).opacity(0.35)
        }
        .overlay(Rectangle().fill(.white.opacity(0.10)).frame(height: 0.5), alignment: .bottom)
        .ignoresSafeArea()
    }
}


extension Color {
    /// "0,255,0" · "#00FF00" · "00FF00"
    static func fromTint(_ s: String?) -> Color? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.contains(",") {
            let p = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count >= 3 else { return nil }
            return Color(red: p[0] / 255, green: p[1] / 255, blue: p[2] / 255)
        }
        let h = s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let v = Int(h, radix: 16), h.count == 6 else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
