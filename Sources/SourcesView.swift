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

nonisolated struct SourceApp: Identifiable, Equatable, Sendable {
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

    /// Parsed `updated` (ISO date / datetime) for sorting.
    var updatedDate: Date? {
        let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime]
        let b = ISO8601DateFormatter(); b.formatOptions = [.withFullDate]
        return a.date(from: updated) ?? b.date(from: updated)
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

nonisolated struct SourceNews: Identifiable, Equatable, Sendable {
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
        var groups: [AppGroup] { AppGroup.group(apps) }
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
                         featured: (a["featured"] as? Bool) ?? false, tintHex: a["tintColor"] as? String)
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
        u.appCount = parsed.groups.count; u.lastFetched = Date()
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

    private enum Sort: String, CaseIterable { case updated = "Recently updated", name = "Name", size = "Size" }

    private var current: RepoSource { store.sources.first { $0.id == source.id } ?? source }
    private var groups: [AppGroup] {
        var list = parsed?.groups ?? []
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { g in g.versions.contains { $0.name.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) || $0.bundle.lowercased().contains(q) } } }
        switch sort {
        case .updated: list.sort { ($0.latest.updatedDate ?? .distantPast) > ($1.latest.updatedDate ?? .distantPast) }
        case .name: list.sort { $0.latest.name.lowercased() < $1.latest.name.lowercased() }
        case .size: list.sort { (Double($0.latest.sizeMB.split(separator: " ").first ?? "") ?? 0) > (Double($1.latest.sizeMB.split(separator: " ").first ?? "") ?? 0) }
        }
        return list
    }

    /// News from the source, else featured apps as news cards.
    private var news: [SourceNews] {
        guard let p = parsed else { return [] }
        if !p.news.isEmpty { return p.news }
        return p.groups.filter { $0.latest.featured }.prefix(12).map { g in
            let a = g.latest
            return SourceNews(id: "feat-" + a.bundle, title: a.name, caption: a.description, imageURL: a.screenshots.first ?? a.iconURL,
                              url: nil, appID: a.bundle, date: a.updated, tintHex: a.tintHex)
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
            ForEach(groups) { g in
                appRow(g)
                    .listRowBackground(Color.black)
                    .listRowSeparatorTint(Theme.stroke)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
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
        .task { await load() }
        .sheet(item: $openGroup) { g in
            AppDetailSheet(source: current, group: g)
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
    }

    // Header: back · icon + NAME · search · sort
    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 30, height: 30)
            }
            Spacer()
            HStack(spacing: 10) {
                SourceIcon(url: current.iconURL, side: 24, fallback: current.name)
                Text(current.name.uppercased()).font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
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
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var countBar: some View {
        HStack {
            Text("\(groups.count.formatted()) Apps").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "signature.zh").font(.system(size: 15, weight: .bold))
                Text("by MrZEfv").font(.system(size: 14, weight: .bold)).kerning(0.3)
            }
            .foregroundStyle(Color(red: 0.95, green: 0.25, blue: 0.25)).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
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
        if let id = n.appID, let g = parsed?.groups.first(where: { $0.bundle == id }) { openGroup = g; return }
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

    private func load() async {
        loading = true; error = nil
        do { parsed = try await store.fetch(current) } catch { self.error = error.localizedDescription }
        loading = false
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
