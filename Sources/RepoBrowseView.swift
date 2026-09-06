//
//  RepoBrowseView.swift
//  Browse tab. Your GitHub repos (or any public one by name) → releases with
//  .ipa assets, latest Actions artifacts, and the file tree. Any IPA goes
//  straight to the Library tab for signing.
//

import SwiftUI
import UIKit
import ZIPFoundation

// MARK: - Models

struct GHRepo: Identifiable, Equatable {
    let id: Int
    let owner: String
    let name: String
    let fullName: String
    let description: String?
    let isPrivate: Bool
    let defaultBranch: String
    let updatedAt: Date?
    let stars: Int
}

struct GHRelease: Identifiable, Equatable {
    let id: Int
    let tag: String
    let name: String?
    let publishedAt: Date?
    let prerelease: Bool
    let assets: [GHAsset]
}

struct GHAsset: Identifiable, Equatable {
    let id: Int
    let name: String
    let size: Int64
    let apiURL: String          // needs Accept: application/octet-stream
    var isIPA: Bool { name.lowercased().hasSuffix(".ipa") }
}

struct GHEntry: Identifiable, Equatable {
    let path: String
    let name: String
    let type: String            // file | dir
    let size: Int64
    let downloadURL: String?
    var id: String { path }
    var isIPA: Bool { type == "file" && name.lowercased().hasSuffix(".ipa") }
}

// MARK: - Client

nonisolated struct RepoBrowseClient {
    let token: String
    private let base = "https://api.github.com"

    private func request(_ url: URL, accept: String = "application/vnd.github+json") -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private func json(_ path: String) async throws -> Any {
        let (d, resp) = try await URLSession.shared.data(for: request(URL(string: base + path)!))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = try? JSONSerialization.jsonObject(with: d)
        guard (200...299).contains(code) else {
            let msg = (obj as? [String: Any])?["message"] as? String ?? "HTTP \(code)"
            switch code {
            case 401: throw GitHubError.badConfig("Token rejected. Paste it again in Settings › Access token.")
            case 404: throw GitHubError.badConfig("Not found — repo name wrong, or the token can't see it.")
            default:  throw GitHubError.http(code, msg)
            }
        }
        return obj ?? [:]
    }

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func repo(_ r: [String: Any]) -> GHRepo? {
        guard let id = r["id"] as? Int, let name = r["name"] as? String,
              let owner = (r["owner"] as? [String: Any])?["login"] as? String else { return nil }
        return GHRepo(id: id, owner: owner, name: name, fullName: r["full_name"] as? String ?? "\(owner)/\(name)",
                      description: r["description"] as? String, isPrivate: r["private"] as? Bool ?? false,
                      defaultBranch: r["default_branch"] as? String ?? "main",
                      updatedAt: (r["pushed_at"] as? String).flatMap(iso.date(from:)),
                      stars: r["stargazers_count"] as? Int ?? 0)
    }

    func myRepos() async throws -> [GHRepo] {
        guard !token.isEmpty else { return [] }
        let arr = try await json("/user/repos?sort=pushed&per_page=100&affiliation=owner,collaborator") as? [[String: Any]] ?? []
        return arr.compactMap(Self.repo)
    }

    func repo(owner: String, name: String) async throws -> GHRepo {
        guard let r = Self.repo(try await json("/repos/\(owner)/\(name)") as? [String: Any] ?? [:]) else { throw GitHubError.decode("repo") }
        return r
    }

    func releases(_ repo: GHRepo) async throws -> [GHRelease] {
        let arr = try await json("/repos/\(repo.owner)/\(repo.name)/releases?per_page=30") as? [[String: Any]] ?? []
        return arr.compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            let assets = (r["assets"] as? [[String: Any]] ?? []).compactMap { a -> GHAsset? in
                guard let aid = a["id"] as? Int, let n = a["name"] as? String, let u = a["url"] as? String else { return nil }
                return GHAsset(id: aid, name: n, size: Int64(a["size"] as? Int ?? 0), apiURL: u)
            }
            return GHRelease(id: id, tag: r["tag_name"] as? String ?? "", name: r["name"] as? String,
                             publishedAt: (r["published_at"] as? String).flatMap(Self.iso.date(from:)),
                             prerelease: r["prerelease"] as? Bool ?? false, assets: assets)
        }
    }

    func contents(_ repo: GHRepo, path: String) async throws -> [GHEntry] {
        let p = path.isEmpty ? "" : "/" + path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let obj = try await json("/repos/\(repo.owner)/\(repo.name)/contents\(p)?ref=\(repo.defaultBranch)")
        let arr = (obj as? [[String: Any]]) ?? [(obj as? [String: Any]) ?? [:]]
        return arr.compactMap { e in
            guard let name = e["name"] as? String, let path = e["path"] as? String, let type = e["type"] as? String else { return nil }
            return GHEntry(path: path, name: name, type: type, size: Int64(e["size"] as? Int ?? 0), downloadURL: e["download_url"] as? String)
        }
        .sorted { ($0.type == "dir" ? 0 : 1, $0.name.lowercased()) < ($1.type == "dir" ? 0 : 1, $1.name.lowercased()) }
    }

    /// Release asset: API URL + octet-stream accept follows the redirect to the blob.
    func downloadAsset(_ asset: GHAsset, to dest: URL) async throws {
        let (tmp, resp) = try await URLSession.shared.download(for: request(URL(string: asset.apiURL)!, accept: "application/octet-stream"))
        guard (200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { throw GitHubError.badConfig("Asset download failed") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Repo file: Contents API with raw accept (works on private repos, unlike download_url).
    func downloadFile(_ repo: GHRepo, entry: GHEntry, to dest: URL) async throws {
        let p = entry.path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let url = URL(string: "\(base)/repos/\(repo.owner)/\(repo.name)/contents/\(p)?ref=\(repo.defaultBranch)")!
        let (tmp, resp) = try await URLSession.shared.download(for: request(url, accept: "application/vnd.github.raw+json"))
        guard (200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { throw GitHubError.badConfig("File download failed") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

// MARK: - Browse tab

struct RepoBrowseView: View {
    @EnvironmentObject var config: Config
    @State private var repos: [GHRepo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var manual = ""
    @State private var selected: GHRepo?

    private var client: RepoBrowseClient { RepoBrowseClient(token: config.token) }
    private var filtered: [GHRepo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? repos : repos.filter { $0.fullName.lowercased().contains(q) || ($0.description?.lowercased().contains(q) ?? false) }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Browse").font(.title2.bold()).foregroundStyle(Theme.text)
                        Spacer()
                        if loading { ProgressView().tint(Theme.accent) }
                        Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").foregroundStyle(Theme.accent) }
                    }
                    openAnyCard
                    if !config.hasToken {
                        Card {
                            Text("Add a GitHub token in Settings › Access token to list your repos. Public repos work without one.")
                                .font(.caption).foregroundStyle(Theme.subtle)
                        }
                    }
                    if let error { Card { Text(error).font(.caption).foregroundStyle(.orange) } }
                    if !repos.isEmpty {
                        TextField("Search repos", text: $search)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .padding(10).background(Theme.card).foregroundStyle(Theme.text)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("YOUR REPOS").font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
                        ForEach(filtered) { r in repoRow(r) }
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
        .fullScreenCover(item: $selected) { r in
            RepoDetailScreen(repo: r, client: client).environmentObject(config).preferredColorScheme(.dark)
        }
        .onAppear { if repos.isEmpty { Task { await load() } } }
    }

    private var openAnyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Open a repo", systemImage: "link").font(.headline).foregroundStyle(Theme.text)
                HStack(spacing: 8) {
                    TextField("owner/repo", text: $manual)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .padding(10).background(Theme.bg).foregroundStyle(Theme.text)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Button { Task { await openManual() } } label: {
                        Image(systemName: "arrow.right").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 42, height: 42).background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(!manual.contains("/"))
                }
                Text("Any public repo, or a private one your token can read. Releases with .ipa assets, Actions artifacts and files are all one tap from the signer.")
                    .font(.caption2).foregroundStyle(Theme.subtle)
            }
        }
    }

    private func repoRow(_ r: GHRepo) -> some View {
        Button { selected = r } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.14))
                    Image(systemName: r.isPrivate ? "lock.fill" : "book.closed.fill").foregroundStyle(Theme.accent)
                }.frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.fullName).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if let d = r.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(Theme.subtle).lineLimit(1) }
                    HStack(spacing: 8) {
                        if let u = r.updatedAt { Text("pushed \(relativeDate(u))") }
                        if r.stars > 0 { Text("★ \(r.stars)") }
                        Text(r.defaultBranch)
                    }
                    .font(.caption2.monospaced()).foregroundStyle(Theme.subtle)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.subtle)
            }
            .padding(12).background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        loading = true; error = nil
        do { repos = try await client.myRepos() } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func openManual() async {
        let parts = manual.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "https://github.com/", with: "").split(separator: "/")
        guard parts.count >= 2 else { return }
        error = nil
        do { selected = try await client.repo(owner: String(parts[0]), name: String(parts[1])) }
        catch { self.error = error.localizedDescription }
    }
}

private func relativeDate(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
    return f.localizedString(for: d, relativeTo: Date())
}

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

// MARK: - Repo detail (Releases · Artifacts · Files)

private struct RepoDetailScreen: View {
    let repo: GHRepo
    let client: RepoBrowseClient
    @EnvironmentObject var config: Config
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var releases: [GHRelease] = []
    @State private var runs: [WorkflowRun] = []
    @State private var runArtifacts: [Int: [RunArtifact]] = [:]
    @State private var path = ""
    @State private var entries: [GHEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var downloading: String?
    @State private var share: URLItem?

    private var actions: ActionsClient { ActionsClient(owner: repo.owner, repo: repo.name, token: config.token) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            segmented
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if let error { Card { Text(error).font(.caption).foregroundStyle(.orange) } }
                    switch page {
                    case 0: releasesSection
                    case 1: artifactsSection
                    default: filesSection
                    }
                    if loading { HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.padding() }
                }
                .padding(16)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
        .onAppear { Task { await load() } }
        .onChange(of: page) { _ in Task { await load() } }
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                Text("UNZIP DROP").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
                Spacer()
            }
            Text(repo.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
                .frame(maxWidth: .infinity).padding(.horizontal, 140).lineLimit(1)
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34).background(Theme.accent.opacity(0.14)).clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.bg)
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)
    }

    private var segmented: some View {
        HStack(spacing: 6) {
            ForEach(Array(["Releases", "Artifacts", "Files"].enumerated()), id: \.offset) { i, t in
                Button { page = i } label: {
                    Text(t).font(.system(size: 12, weight: .semibold))
                        .padding(.vertical, 8).frame(maxWidth: .infinity)
                        .background(page == i ? Theme.accent.opacity(0.16) : Theme.card)
                        .foregroundStyle(page == i ? Theme.accent : Theme.subtle)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(page == i ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Releases

    @ViewBuilder private var releasesSection: some View {
        if releases.isEmpty && !loading { Card { Text("No releases.").font(.caption).foregroundStyle(Theme.subtle) } }
        ForEach(releases) { rel in
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(rel.name?.isEmpty == false ? rel.name! : rel.tag).font(.headline).foregroundStyle(Theme.text)
                        if rel.prerelease { tag("PRE", .orange) }
                        Spacer()
                        Text(rel.tag).font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                    }
                    if let d = rel.publishedAt { Text(relativeDate(d)).font(.caption2).foregroundStyle(Theme.subtle) }
                    ForEach(rel.assets) { a in
                        assetRow(name: a.name, size: a.size, isIPA: a.isIPA, key: "asset-\(a.id)") {
                            await download({ dest in try await client.downloadAsset(a, to: dest) }, name: a.name, isIPA: a.isIPA)
                        }
                    }
                    if rel.assets.isEmpty { Text("No assets on this release.").font(.caption2).foregroundStyle(Theme.subtle) }
                }
            }
        }
    }

    // MARK: Artifacts

    @ViewBuilder private var artifactsSection: some View {
        if runs.isEmpty && !loading { Card { Text("No completed workflow runs with artifacts.").font(.caption).foregroundStyle(Theme.subtle) } }
        ForEach(runs) { run in
            if let arts = runArtifacts[run.id], !arts.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(run.title.isEmpty ? run.name : run.title).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text("#\(run.runNumber)").font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                        }
                        Text("\(run.headBranch) · \(run.shortSha) · \(relativeDate(run.updatedAt))").font(.caption2.monospaced()).foregroundStyle(Theme.subtle)
                        ForEach(arts) { a in
                            assetRow(name: a.name, size: a.sizeBytes, isIPA: a.name.lowercased().contains("ipa"), key: "art-\(a.id)") {
                                await download({ dest in try await actions.downloadArtifact(id: a.id, to: dest) { _ in } }, name: a.name + ".zip", isIPA: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Files

    @ViewBuilder private var filesSection: some View {
        HStack(spacing: 6) {
            Button { path = ""; Task { await load() } } label: { Image(systemName: "house.fill").foregroundStyle(Theme.accent) }
            Text("/" + path).font(.caption.monospaced()).foregroundStyle(Theme.subtle).lineLimit(1).truncationMode(.head)
            Spacer()
            if !path.isEmpty {
                Button {
                    path = path.split(separator: "/").dropLast().joined(separator: "/"); Task { await load() }
                } label: { Label("Up", systemImage: "arrow.up").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent) }
            }
        }
        ForEach(entries) { e in
            if e.type == "dir" {
                Button { path = e.path; Task { await load() } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                        Text(e.name).font(.system(size: 15)).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.subtle)
                    }
                    .padding(12).background(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else {
                assetRow(name: e.name, size: e.size, isIPA: e.isIPA, key: "file-\(e.path)") {
                    await download({ dest in try await client.downloadFile(repo, entry: e, to: dest) }, name: e.name, isIPA: e.isIPA)
                }
            }
        }
    }

    // MARK: Rows + actions

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1)
            .padding(.horizontal, 6).padding(.vertical, 3).background(c.opacity(0.18)).foregroundStyle(c).clipShape(Capsule())
    }

    private func assetRow(name: String, size: Int64, isIPA: Bool, key: String, action: @escaping () async -> Void) -> some View {
        Button { Task { downloading = key; await action(); downloading = nil } } label: {
            HStack(spacing: 12) {
                Image(systemName: isIPA ? "app.badge.checkmark" : "doc.fill").foregroundStyle(isIPA ? Theme.accent : Theme.subtle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(bytes(size)).font(.caption2).foregroundStyle(Theme.subtle)
                }
                Spacer()
                if downloading == key { ProgressView().tint(Theme.accent) }
                else if isIPA { tag("SIGN", Theme.accent) }
                else { Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.subtle) }
            }
            .padding(10).background(Theme.bg)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isIPA ? Theme.accent.opacity(0.35) : Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(downloading != nil)
    }

    /// Download to the inbox; IPAs (or zips that contain one) go to the Library tab.
    private func download(_ op: (URL) async throws -> Void, name: String, isIPA: Bool) async {
        error = nil
        let dest = AppPaths.dir("inbox").appendingPathComponent(name)
        do {
            try await op(dest)
            if name.lowercased().hasSuffix(".ipa") {
                dismiss(); SignQueue.shared.enqueue(dest)
            } else if name.lowercased().hasSuffix(".zip"), let ipa = try? Self.extractIPA(from: dest) {
                dismiss(); SignQueue.shared.enqueue(ipa)
            } else {
                share = URLItem(url: dest)
            }
        } catch { self.error = error.localizedDescription }
    }

    nonisolated private static func extractIPA(from zip: URL) throws -> URL? {
        let fm = FileManager.default
        let out = AppPaths.dir("inbox").appendingPathComponent("x-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try fm.unzipItem(at: zip, to: out)
        guard let en = fm.enumerator(at: out, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in en where u.pathExtension.lowercased() == "ipa" { return u }
        return nil
    }

    private func load() async {
        loading = true; error = nil
        do {
            switch page {
            case 0: releases = try await client.releases(repo)
            case 1:
                let all = try await actions.runs(perPage: 15).filter { !$0.isActive }
                runs = all
                for r in all where runArtifacts[r.id] == nil {
                    runArtifacts[r.id] = (try? await actions.artifacts(runID: r.id))?.filter { !$0.expired } ?? []
                }
            default: entries = try await client.contents(repo, path: path)
            }
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}
