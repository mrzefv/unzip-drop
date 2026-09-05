//
//  Unzipper.swift
//

import Foundation
import ZIPFoundation

enum Unzipper {

    enum Failure: LocalizedError {
        case notAZip
        var errorDescription: String? {
            switch self {
            case .notAZip: return "That file isn't a zip archive."
            }
        }
    }

    static func extract(_ zipURL: URL) throws -> (root: URL, name: String) {
        let fm = FileManager.default
        if let fh = try? FileHandle(forReadingFrom: zipURL) {
            let magic = try? fh.read(upToCount: 2)
            try? fh.close()
            if magic != Data([0x50, 0x4B]) { throw Failure.notAZip }
        }
        let work = fm.temporaryDirectory
            .appendingPathComponent("uzd-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.unzipItem(at: zipURL, to: work)

        var root = work
        let top = (try? fm.contentsOfDirectory(at: work,
                                               includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])) ?? []
        if top.count == 1,
           (try? top[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            root = top[0]
        }
        return (root, zipURL.deletingPathExtension().lastPathComponent)
    }

    /// Repackage a folder tree into a fresh .zip in temp; returns its URL.
    static func makeZip(from root: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let outDir = fm.temporaryDirectory.appendingPathComponent("zip-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let safe = name.isEmpty ? "archive" : name
        let dest = outDir.appendingPathComponent(safe + ".zip")
        try? fm.removeItem(at: dest)
        try fm.zipItem(at: root, to: dest, shouldKeepParent: false, compressionMethod: .deflate)
        return dest
    }

    private static func skip(_ url: URL) -> Bool {
        url.lastPathComponent == ".DS_Store" || url.path.contains("__MACOSX")
    }

    static func stats(under root: URL) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        var c = 0; var b: Int64 = 0
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let u as URL in en where !skip(u) {
                let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if v?.isRegularFile == true { c += 1; b += Int64(v?.fileSize ?? 0) }
            }
        }
        return (c, b)
    }

    static func files(under root: URL) throws -> [(path: String, data: Data)] {
        let fm = FileManager.default
        var out: [(String, Data)] = []
        let base = root.standardizedFileURL.path
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let u as URL in en where !skip(u) {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            var rel = u.standardizedFileURL.path
            if rel.hasPrefix(base) { rel.removeFirst(base.count) }
            while rel.hasPrefix("/") { rel.removeFirst() }
            out.append((rel, try Data(contentsOf: u)))
        }
        return out
    }
}
