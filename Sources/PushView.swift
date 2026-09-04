//
//  PushView.swift
//

import SwiftUI

struct PushView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var config: Config

    @State private var message = ""
    @State private var pushing = false
    @State private var done = 0
    @State private var total = 0
    @State private var resultURL: String?
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    HStack { Text("Push to GitHub").font(.title2.bold()).foregroundStyle(Theme.text); Spacer() }

                    if session.root == nil {
                        Card { Text("Import a zip first.").font(.subheadline).foregroundStyle(Theme.subtle) }
                    } else {
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                kv("Repo",   (config.owner.isEmpty || config.repo.isEmpty) ? "— set in Settings" : "\(config.owner)/\(config.repo)")
                                kv("Branch", config.branch.isEmpty ? "main" : config.branch)
                                kv("Into",   config.subpath.isEmpty ? "repo root" : config.subpath)
                                kv("Files",  "\(session.fileCount)")
                                kv("Token",  config.hasToken ? "set" : "missing")
                            }
                        }

                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Commit message").font(.caption).foregroundStyle(Theme.subtle)
                                TextField(defaultMessage, text: $message)
                                    .padding(10).background(Theme.bg).foregroundStyle(Theme.text)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }

                        Button { push() } label: {
                            HStack {
                                Image(systemName: "arrow.up.circle.fill")
                                Text(pushing ? "Pushing…" : "Push").fontWeight(.semibold)
                                Spacer()
                                if pushing { Text("\(done)/\(total)").font(.caption) }
                            }
                            .padding(.vertical, 12).padding(.horizontal, 14)
                            .background(config.hasToken ? Theme.accent : Theme.subtle)
                            .foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(pushing || !config.hasToken)

                        if pushing, total > 0 {
                            ProgressView(value: Double(done), total: Double(total)).tint(Theme.accent)
                        }

                        if let u = resultURL, let link = URL(string: u) {
                            Card {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Pushed", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                                    Link(u, destination: link).font(.caption).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        if let e = error {
                            Card { Text(e).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var defaultMessage: String { "Unzip drop: \(session.archiveName ?? "archive")" }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(Theme.subtle)
            Spacer()
            Text(v).font(.caption).foregroundStyle(Theme.text)
        }
    }

    private func push() {
        guard let root = session.root else { return }
        error = nil; resultURL = nil; pushing = true; done = 0; total = session.fileCount
        let msg = message.isEmpty ? defaultMessage : message
        let client = GitHubClient(owner: config.owner, repo: config.repo,
                                  branch: config.branch.isEmpty ? "main" : config.branch,
                                  token: config.token)
        let sub = config.subpath
        Task {
            do {
                let files = try Unzipper.files(under: root)
                await MainActor.run { total = files.count }
                let url = try await client.push(files: files, subpath: sub, message: msg) { d, t in
                    Task { @MainActor in done = d; total = t }
                }
                await MainActor.run { resultURL = url; pushing = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; pushing = false }
            }
        }
    }
}
