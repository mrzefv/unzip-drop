//
//  GitHubClient.swift
//  Pushes an extracted file tree into a repo as a single commit using the
//  Git Data API (blobs -> tree -> commit -> move ref).
//

import Foundation

enum GitHubError: LocalizedError {
    case badConfig(String)
    case http(Int, String)
    case decode(String)
    var errorDescription: String? {
        switch self {
        case .badConfig(let m): return m
        case .http(let c, let m): return "GitHub \(c): \(m)"
        case .decode(let m): return "Unexpected response (\(m))"
        }
    }
}

struct GitHubClient {
    let owner: String
    let repo: String
    let branch: String
    let token: String

    private let base = "https://api.github.com"

    private func call(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw GitHubError.badConfig("Bad URL") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(code) else {
            let msg = obj["message"] as? String ?? String(data: data, encoding: .utf8) ?? "error"
            throw GitHubError.http(code, msg)
        }
        return obj
    }

    /// Verify the token can see the repo + branch. Returns a short summary.
    /// Errors are diagnostic: bad token vs. token can't see repo vs. missing branch.
    func verify() async throws -> (fullName: String, branch: String, permission: String) {
        guard !owner.isEmpty, !repo.isEmpty else { throw GitHubError.badConfig("Set owner and repo first.") }
        guard !token.isEmpty else { throw GitHubError.badConfig("Add a GitHub token first.") }

        // 1. who is this token?
        let login: String
        do {
            let me = try await call("/user")
            login = me["login"] as? String ?? "?"
        } catch let GitHubError.http(code, _) where code == 401 {
            throw GitHubError.badConfig("Token rejected (401). It's invalid, expired, or has whitespace in it — paste it again.")
        }

        // 2. can it see the repo?
        let repoPath = "/repos/\(owner)/\(repo)"
        let r: [String: Any]
        do { r = try await call(repoPath) }
        catch let GitHubError.http(code, _) where code == 404 {
            throw GitHubError.badConfig(
                "Token belongs to @\(login) but can't see \(owner)/\(repo). " +
                "Fine-grained PAT: edit it → Repository access → add \(repo) → Contents: Read and write. " +
                "Classic PAT: needs the repo scope. Also check the owner/repo spelling.")
        }
        let fullName = r["full_name"] as? String ?? "\(owner)/\(repo)"
        let perms = r["permissions"] as? [String: Any] ?? [:]
        let canPush = (perms["push"] as? Bool) ?? false

        // 3. does the branch exist?
        do { _ = try await call("\(repoPath)/git/ref/heads/\(branch)") }
        catch let GitHubError.http(code, _) where code == 404 {
            let def = r["default_branch"] as? String ?? "main"
            throw GitHubError.badConfig("Repo reachable as @\(login), but branch '\(branch)' doesn't exist. Default branch is '\(def)'.")
        }
        return (fullName, branch, canPush ? "write access as @\(login)" : "read-only as @\(login) — pushes will fail")
    }

    /// Push files, returning the new commit's html URL.
    func push(files: [(path: String, data: Data)],
              subpath: String,
              message: String,
              progress: @escaping (Int, Int) -> Void) async throws -> String {

        guard !owner.isEmpty, !repo.isEmpty, !branch.isEmpty else {
            throw GitHubError.badConfig("Set owner, repo and branch in Settings.")
        }
        guard !token.isEmpty else { throw GitHubError.badConfig("Add a GitHub token in Settings.") }
        guard !files.isEmpty else { throw GitHubError.badConfig("Nothing to push.") }

        let repoPath = "/repos/\(owner)/\(repo)"

        // 1. tip of branch
        let ref: [String: Any]
        do { ref = try await call("\(repoPath)/git/ref/heads/\(branch)") }
        catch let GitHubError.http(code, _) where code == 404 {
            throw GitHubError.badConfig("Branch '\(branch)' not found. Create the repo with at least one commit (e.g. a README) first.")
        }
        guard let refObj = ref["object"] as? [String: Any],
              let baseCommit = refObj["sha"] as? String else { throw GitHubError.decode("ref") }

        // 2. base tree
        let commit = try await call("\(repoPath)/git/commits/\(baseCommit)")
        guard let treeObj = commit["tree"] as? [String: Any],
              let baseTree = treeObj["sha"] as? String else { throw GitHubError.decode("commit") }

        // 3. one blob per file
        let prefix = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var entries: [[String: Any]] = []
        let total = files.count
        var done = 0
        progress(0, total)
        for f in files {
            let blob = try await call("\(repoPath)/git/blobs", method: "POST",
                                      body: ["content": f.data.base64EncodedString(), "encoding": "base64"])
            guard let sha = blob["sha"] as? String else { throw GitHubError.decode("blob") }
            let full = prefix.isEmpty ? f.path : "\(prefix)/\(f.path)"
            entries.append(["path": full, "mode": "100644", "type": "blob", "sha": sha])
            done += 1
            progress(done, total)
        }

        // 4. new tree layered on the base
        let tree = try await call("\(repoPath)/git/trees", method: "POST",
                                  body: ["base_tree": baseTree, "tree": entries])
        guard let newTree = tree["sha"] as? String else { throw GitHubError.decode("tree") }

        // 5. commit
        let newCommit = try await call("\(repoPath)/git/commits", method: "POST",
                                       body: ["message": message, "tree": newTree, "parents": [baseCommit]])
        guard let newSha = newCommit["sha"] as? String else { throw GitHubError.decode("newcommit") }

        // 6. move branch to the new commit
        _ = try await call("\(repoPath)/git/refs/heads/\(branch)", method: "PATCH",
                           body: ["sha": newSha, "force": false])

        return "https://github.com/\(owner)/\(repo)/commit/\(newSha)"
    }
}
