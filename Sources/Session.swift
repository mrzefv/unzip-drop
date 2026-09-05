//
//  Session.swift
//  Holds the currently extracted archive shared across tabs. All file I/O runs
//  off the main thread; failures surface via `errorMessage`.
//

import SwiftUI

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
        case .failure(let msg):
            busy = false; status = nil; errorMessage = msg; return
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
        case .failure(let msg):
            root = nil; archiveName = nil; fileCount = 0; totalBytes = 0
            busy = false; status = nil; errorMessage = msg
        case .success(let out):
            root = out.root; archiveName = out.name
            fileCount = out.count; totalBytes = out.bytes
            busy = false
            status = "Extracted \(out.count) file\(out.count == 1 ? "" : "s")"
        }
    }

    /// Copy the picked/opened file into our sandbox using NSFileCoordinator so
    /// security-scoped and iCloud files read reliably. Keeps the original name.
    private static func copyIntoSandbox(_ src: URL) async -> Result<URL, String> {
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
                if let coordErr { cont.resume(returning: .failure("Couldn't access the file: \(coordErr.localizedDescription)")); return }
                if let innerErr { cont.resume(returning: .failure(innerErr)); return }
                guard FileManager.default.fileExists(atPath: dest.path) else {
                    cont.resume(returning: .failure("The file couldn't be copied in.")); return
                }
                cont.resume(returning: .success(dest))
            }
        }
    }

    private static func extract(_ zipURL: URL) async -> Result<(root: URL, name: String, count: Int, bytes: Int64), String> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let (r, name) = try Unzipper.extract(zipURL)
                    let s = Unzipper.stats(under: r)
                    guard s.count > 0 else {
                        cont.resume(returning: .failure("Extracted, but the archive has no files inside.")); return
                    }
                    cont.resume(returning: .success((r, name, s.count, s.bytes)))
                } catch {
                    cont.resume(returning: .failure("Extract failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    func reset() {
        if let r = root { try? FileManager.default.removeItem(at: r.deletingLastPathComponent()) }
        root = nil; archiveName = nil; fileCount = 0; totalBytes = 0; status = nil; errorMessage = nil
    }
}
