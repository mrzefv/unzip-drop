//
//  ActionsClient.swift
//  GitHub Actions API: list workflow runs, read a run's jobs + steps, trigger a
//  workflow_dispatch, list + download artifacts. Read-only calls need the token
//  to have Actions: Read; dispatch needs Actions: Read and write.
//

import Foundation

// MARK: - Models

struct WorkflowRun: Identifiable, Equatable {
    let id: Int
    let name: String
    let runNumber: Int
    let status: String          // queued | in_progress | completed
    let conclusion: String?     // success | failure | cancelled | …
    let headBranch: String
    let headSha: String
    let commitMessage: String
    let event: String
    let createdAt: Date
    let updatedAt: Date
    let htmlURL: String
    let workflowID: Int

    var isActive: Bool { status != "completed" }
    var shortSha: String { String(headSha.prefix(7)) }
    var title: String { commitMessage.components(separatedBy: "\n").first ?? commitMessage }
}

struct WorkflowJob: Identifiable, Equatable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?
    let steps: [WorkflowStep]
}

struct WorkflowStep: Identifiable, Equatable {
    let number: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?
    var id: Int { number }
}

struct Workflow: Identifiable, Equatable {
    let id: Int
    let name: String
    let path: String
    let state: String
}

struct RunArtifact: Identifiable, Equatable {
    let id: Int
    let name: String
    let sizeBytes: Int64
    let expired: Bool
}

// MARK: - Client

struct ActionsClient {
    let owner: String
    let repo: String
    let token: String

    private let base = "https://api.github.com"
    private var repoPath: String { "/repos/\(owner)/\(repo)" }

    // MARK: Requests

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: base + path)!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func json(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        let (data, resp) = try await URLSession.shared.data(for: request(path, method: method, body: body))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = try? JSONSerialization.jsonObject(with: data)
        guard (200...299).contains(code) else {
            let msg = (obj as? [String: Any])?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "error"
            throw Self.explain(code, msg)
        }
        return obj ?? [:]
    }

    private static func explain(_ code: Int, _ msg: String) -> GitHubError {
        switch code {
        case 401: return .badConfig("Token rejected (401). Paste it again in Settings.")
        case 403: return .badConfig("GitHub 403: token can't access Actions. Fine-grained PAT: Repository permissions → Actions: Read and write. Classic: 'repo' + 'workflow' scopes.")
        case 404: return .badConfig("Not found (404). Check owner/repo, and that the token can see the repo and has Actions: Read.")
        default:  return .http(code, msg)
        }
    }

    // MARK: Workflows / runs

    func workflows() async throws -> [Workflow] {
        let o = try await json("\(repoPath)/actions/workflows?per_page=50") as? [String: Any] ?? [:]
        let arr = o["workflows"] as? [[String: Any]] ?? []
        return arr.compactMap {
            guard let id = $0["id"] as? Int else { return nil }
            return Workflow(id: id, name: $0["name"] as? String ?? "workflow",
                            path: $0["path"] as? String ?? "", state: $0["state"] as? String ?? "")
        }
    }

    func runs(perPage: Int = 20) async throws -> [WorkflowRun] {
        let o = try await json("\(repoPath)/actions/runs?per_page=\(perPage)") as? [String: Any] ?? [:]
        let arr = o["workflow_runs"] as? [[String: Any]] ?? []
        return arr.compactMap(Self.run)
    }

    func run(id: Int) async throws -> WorkflowRun {
        let o = try await json("\(repoPath)/actions/runs/\(id)") as? [String: Any] ?? [:]
        guard let r = Self.run(o) else { throw GitHubError.decode("run") }
        return r
    }

    func jobs(runID: Int) async throws -> [WorkflowJob] {
        let o = try await json("\(repoPath)/actions/runs/\(runID)/jobs?per_page=50") as? [String: Any] ?? [:]
        let arr = o["jobs"] as? [[String: Any]] ?? []
        return arr.compactMap { j in
            guard let id = j["id"] as? Int else { return nil }
            let steps = (j["steps"] as? [[String: Any]] ?? []).map { s in
                WorkflowStep(number: s["number"] as? Int ?? 0,
                             name: s["name"] as? String ?? "",
                             status: s["status"] as? String ?? "queued",
                             conclusion: s["conclusion"] as? String,
                             startedAt: Self.date(s["started_at"]),
                             completedAt: Self.date(s["completed_at"]))
            }
            return WorkflowJob(id: id, name: j["name"] as? String ?? "job",
                               status: j["status"] as? String ?? "queued",
                               conclusion: j["conclusion"] as? String,
                               startedAt: Self.date(j["started_at"]),
                               completedAt: Self.date(j["completed_at"]),
                               steps: steps)
        }
    }

    /// Trigger `workflow_dispatch` on a workflow. GitHub returns 204 with no body.
    func dispatch(workflowID: Int, ref: String, inputs: [String: String] = [:]) async throws {
        var body: [String: Any] = ["ref": ref]
        if !inputs.isEmpty { body["inputs"] = inputs }
        _ = try await json("\(repoPath)/actions/workflows/\(workflowID)/dispatches", method: "POST", body: body)
    }

    func cancel(runID: Int) async throws {
        _ = try await json("\(repoPath)/actions/runs/\(runID)/cancel", method: "POST")
    }

    func rerun(runID: Int) async throws {
        _ = try await json("\(repoPath)/actions/runs/\(runID)/rerun", method: "POST")
    }

    // MARK: Artifacts

    func artifacts(runID: Int) async throws -> [RunArtifact] {
        let o = try await json("\(repoPath)/actions/runs/\(runID)/artifacts") as? [String: Any] ?? [:]
        let arr = o["artifacts"] as? [[String: Any]] ?? []
        return arr.compactMap {
            guard let id = $0["id"] as? Int else { return nil }
            return RunArtifact(id: id, name: $0["name"] as? String ?? "artifact",
                               sizeBytes: Int64($0["size_in_bytes"] as? Int ?? 0),
                               expired: $0["expired"] as? Bool ?? false)
        }
    }

    /// Download an artifact (always a zip from GitHub). Follows the 302 to blob storage.
    func downloadArtifact(id: Int, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        let req = request("\(repoPath)/actions/artifacts/\(id)/zip")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            let msg = (try? String(contentsOf: tmp)) ?? "download failed"
            throw Self.explain(code, msg)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        progress(1)
    }

    // MARK: Parsing

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); return f }()

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return iso.date(from: s)
    }

    private static func run(_ r: [String: Any]) -> WorkflowRun? {
        guard let id = r["id"] as? Int else { return nil }
        let head = r["head_commit"] as? [String: Any]
        return WorkflowRun(
            id: id,
            name: r["name"] as? String ?? "build",
            runNumber: r["run_number"] as? Int ?? 0,
            status: r["status"] as? String ?? "queued",
            conclusion: r["conclusion"] as? String,
            headBranch: r["head_branch"] as? String ?? "",
            headSha: r["head_sha"] as? String ?? "",
            commitMessage: head?["message"] as? String ?? (r["display_title"] as? String ?? ""),
            event: r["event"] as? String ?? "",
            createdAt: date(r["created_at"]) ?? Date(),
            updatedAt: date(r["updated_at"]) ?? Date(),
            htmlURL: r["html_url"] as? String ?? "",
            workflowID: r["workflow_id"] as? Int ?? 0)
    }
}
