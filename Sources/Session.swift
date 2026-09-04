//
//  Session.swift
//  Holds the currently extracted archive shared across tabs.
//

import SwiftUI

@MainActor
final class Session: ObservableObject {
    @Published var archiveName: String?
    @Published var root: URL?
    @Published var fileCount = 0
    @Published var totalBytes: Int64 = 0
    @Published var status: String?
    @Published var busy = false

    func importPicked(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.copyItem(at: url, to: tmp)
            unzip(tmp)
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    func receiveIncoming(_ url: URL) {
        guard url.pathExtension.lowercased() == "zip" else { return }
        importPicked(url)
    }

    func unzip(_ zipURL: URL) {
        busy = true
        status = "Extracting…"
        reset(keepStatus: true)
        do {
            let (r, name) = try Unzipper.extract(zipURL)
            let s = Unzipper.stats(under: r)
            root = r; archiveName = name
            fileCount = s.count; totalBytes = s.bytes
            status = "Extracted \(s.count) file\(s.count == 1 ? "" : "s")"
        } catch {
            root = nil; archiveName = nil
            status = "Extract failed: \(error.localizedDescription)"
        }
        busy = false
    }

    func reset(keepStatus: Bool = false) {
        if let r = root { try? FileManager.default.removeItem(at: r.deletingLastPathComponent()) }
        root = nil; archiveName = nil; fileCount = 0; totalBytes = 0
        if !keepStatus { status = nil }
    }
}
