//
//  Session.swift
//  Holds the currently extracted archive shared across tabs. All file I/O runs
//  off the main thread; failures surface via `errorMessage`.
//

import SwiftUI

/// Lightweight error so we can carry a message through Result (String isn't Error).
private struct IngestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class Session: ObservableObject {
    @Published var archiveName: String?
    @Published var root: URL?
    @Published var fileCount = 0
    @Published var totalBytes: Int64 = 0
    @Published var status: String?
    @Published var errorMessage: String?
    @Published var busy = false
    /// Bumped whenever an import starts, so the shell can jump to the Import tab.
    @Published private(set) var lastEventID = UUID()

    func importPicked(_ url: URL) { lastEventID = UUID(); Task { await ingest(url) } }
    func receiveIncoming(_ url: URL) { lastEventID = UUID(); Task { await ingest(url) } }

    private func ingest(_ url: URL) async {
        busy = true
        status = "Reading…"
        errorMessage = nil

        // 1. Copy the source into our sandbox (handles iCloud / in-place / Inbox).
        let copied: URL
        switch await Self.copyIntoSandbox(url) {
        case .failure(let e):
            busy = false; status = nil; errorMessage = e.message; return
        case .success(let u):
            copied = u
        }

        // 2. Extract off the main thread.
        status = "Extracting…"
        let prev = root
        let result = await Self.extract(copied)

        if let prev { try? FileManager.default.removeItem(at: prev.deletingLastPathComponent()) }
        try? FileManager.default.removeItem(at: copied.deletingLastPathComponent())

        switch result {
        case .failure(let e):
            root = nil; archiveName = nil; fileCount = 0; totalBytes = 0
            busy = false; status = nil; errorMessage = e.message
        case .success(let out):
            root = out.root; archiveName = out.name
            fileCount = out.count; totalBytes = out.bytes
            busy = false
            status = "Extracted \(out.count) file\(out.count == 1 ? "" : "s")"
        }
    }

    /// Copy the picked/opened file into our sandbox using NSFileCoordinator so
    /// security-scoped and iCloud files read reliably. Keeps the original name.
    private static func copyIntoSandbox(_ src: URL) async -> Result<URL, IngestError> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = src.startAccessingSecurityScopedResource()
                defer { if scoped { src.stopAccessingSecurityScopedResource() } }

                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("in-" + UUID().uuidString, isDirectory: true)
                let name = src.lastPathComponent.isEmpty ? "archive.zip" : src.lastPathComponent
                let dest = dir.appendingPathComponent(name)

                var coordErr: NSError?
                var innerErr: String?
                NSFileCoordinator().coordinate(readingItemAt: src, options: [.withoutChanges], error: &coordErr) { readURL in
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.copyItem(at: readURL, to: dest)
                    } catch {
                        innerErr = "Couldn't read the file: \(error.localizedDescription)"
                    }
                }
                if let coordErr { cont.resume(returning: .failure(IngestError(message: "Couldn't access the file: \(coordErr.localizedDescription)"))); return }
                if let innerErr { cont.resume(returning: .failure(IngestError(message: innerErr))); return }
                guard FileManager.default.fileExists(atPath: dest.path) else {
                    cont.resume(returning: .failure(IngestError(message: "The file couldn't be copied in."))); return
                }
                cont.resume(returning: .success(dest))
            }
        }
    }

    private static func extract(_ zipURL: URL) async -> Result<(root: URL, name: String, count: Int, bytes: Int64), IngestError> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let (r, name) = try Unzipper.extract(zipURL)
                    let s = Unzipper.stats(under: r)
                    guard s.count > 0 else {
                        cont.resume(returning: .failure(IngestError(message: "Extracted, but the archive has no files inside."))); return
                    }
                    cont.resume(returning: .success((r, name, s.count, s.bytes)))
                } catch {
                    cont.resume(returning: .failure(IngestError(message: "Extract failed: \(error.localizedDescription)")))
                }
            }
        }
    }

    /// Load a generated project (template) as the current workspace so the
    /// Contents / Push / Build tabs treat it exactly like an extracted zip.
    func loadGenerated(name: String, files: [(path: String, content: String)]) {
        lastEventID = UUID()
        busy = true; status = "Generating…"; errorMessage = nil
        let prev = root
        let wrapper = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-" + UUID().uuidString, isDirectory: true)
        let dir = wrapper.appendingPathComponent(name, isDirectory: true)
        var count = 0; var bytes: Int64 = 0
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in files {
                let u = dir.appendingPathComponent(f.path)
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                let d = Data(f.content.utf8)
                try d.write(to: u)
                count += 1; bytes += Int64(d.count)
            }
        } catch {
            busy = false; status = nil; errorMessage = "Template failed: \(error.localizedDescription)"; return
        }
        if let prev { try? FileManager.default.removeItem(at: prev.deletingLastPathComponent()) }
        root = dir; archiveName = name; fileCount = count; totalBytes = bytes
        busy = false; status = "Generated \(count) files — review in Contents, then Push"
    }

    func reset() {
        if let r = root { try? FileManager.default.removeItem(at: r.deletingLastPathComponent()) }
        root = nil; archiveName = nil; fileCount = 0; totalBytes = 0; status = nil; errorMessage = nil
    }
}
