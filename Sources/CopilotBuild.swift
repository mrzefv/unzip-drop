//
//  CopilotBuild.swift
//  Compile a Copilot-generated .xm into a .dylib on GitHub Actions (Theos), then
//  the artifact returns to the Build tab for download / injection. Compiling needs
//  clang + the iOS SDK, so it runs on the runner — not on-device.
//

import Foundation

nonisolated enum CopilotBuild {

    enum BuildError: LocalizedError {
        case noConfig, noWorkflow
        var errorDescription: String? {
            switch self {
            case .noConfig: return "Set GitHub owner/repo/token in Settings first."
            case .noWorkflow: return "No copilot-tweak workflow found (or it lacks a workflow_dispatch trigger). Push .github/workflows/copilot-tweak.yml — the on: block must include workflow_dispatch:."
            }
        }
    }

    /// Commit the source and trigger the tweak-build workflow.
    static func dispatch(source: String, className: String,
                         owner: String, repo: String, branch rawBranch: String, token: String) async throws {
        let branch = rawBranch.isEmpty ? "main" : rawBranch
        guard !owner.isEmpty, !repo.isEmpty, !token.isEmpty else { throw BuildError.noConfig }

        let gh = GitHubClient(owner: owner, repo: repo, branch: branch, token: token)
        let file = "\(className)Tweak.m"
        _ = try await gh.push(
            files: [(path: file, data: Data(source.utf8))],
            subpath: "copilot-tweaks",
            message: "Copilot: \(file)",
            progress: { _, _ in }
        )

        let actions = ActionsClient(owner: owner, repo: repo, token: token)
        let wfs = try await actions.workflows()
        guard let wf = wfs.first(where: { $0.path.hasSuffix("/copilot-tweak.yml") || $0.path.hasSuffix("copilot-tweak.yml") }) else {
            throw BuildError.noWorkflow
        }
        try await actions.dispatch(workflowID: wf.id, ref: branch, inputs: ["source": "copilot-tweaks/\(file)"])
    }
}
