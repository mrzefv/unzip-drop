//
//  SignEngine.swift
//  On-device signing: zsign wrapper, IPA sign pipeline, IPA metadata reader,
//  stdout capture. Ported from mSignLite. Everything here is `nonisolated`
//  because this project defaults to MainActor isolation and the C work must
//  run off the UI thread.
//

import Foundation
import Darwin
import ZIPFoundation

enum ZsignError: Error, LocalizedError {
    case fileNotFound(String)
    case signingFailed(code: Int32)
    case dylibInjectionFailed(macho: String, dylib: String)
    case appBundleNotFound(inIPA: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let p):           return "zsign: file not found at \(p)"
        case .signingFailed(let c):          return "zsign: signing failed (code \(c))"
        case .dylibInjectionFailed(let m, let d):
                                             return "zsign: failed to inject \(d) into \(m)"
        case .appBundleNotFound(let ipa):    return "zsign: no Payload/*.app inside \(ipa)"
        }
    }
}

nonisolated struct ZsignSigner {

    // MARK: - Core: sign an unpacked .app bundle in place

    /// Signs an extracted `.app` directory in place.
    /// - Parameters:
    ///   - appBundlePath: absolute path to `…/Payload/Foo.app` (or any `.app` dir).
    ///   - provisionPath: absolute path to the `.mobileprovision`.
    ///   - p12Path:       absolute path to the signing `.p12`.
    ///   - p12Password:   password for the `.p12` (pass `""` if none).
    ///   - bundleID/displayName/version: pass non-nil to override Info.plist values.
    ///   - skipEmbeddedProvision: when true, does NOT write embedded.mobileprovision.
    nonisolated static func signAppBundle(
        appBundlePath: String,
        provisionPath: String,
        p12Path: String,
        p12Password: String,
        bundleID: String? = nil,
        displayName: String? = nil,
        version: String? = nil,
        skipEmbeddedProvision: Bool = false
    ) throws {
        let fm = FileManager.default
        for p in [appBundlePath, provisionPath, p12Path] where !fm.fileExists(atPath: p) {
            throw ZsignError.fileNotFound(p)
        }

        let code = zsign(
            appBundlePath,
            provisionPath,
            p12Path,
            p12Password,
            bundleID ?? "",
            displayName ?? "",
            version ?? "",
            skipEmbeddedProvision
        )
        if code != 0 { throw ZsignError.signingFailed(code: code) }
    }

    // MARK: - Convenience: sign a full .ipa

    /// Unpacks an `.ipa`, signs the contained `.app`, repacks to a new `.ipa`.
    /// Bring your own zip handling by passing an `IPAArchiver` — mSign already
    /// has IPA pack/unpack code; conform it to `IPAArchiver` in a few lines
    /// (see INTEGRATION.md). Returns the URL of the signed `.ipa`.
    nonisolated static func signIPA(
        at ipaURL: URL,
        provisionPath: String,
        p12Path: String,
        p12Password: String,
        bundleID: String? = nil,
        displayName: String? = nil,
        version: String? = nil,
        using archiver: IPAArchiver
    ) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let appURL = try archiver.unpack(ipa: ipaURL, into: work)
        guard fm.fileExists(atPath: appURL.path) else {
            throw ZsignError.appBundleNotFound(inIPA: ipaURL.lastPathComponent)
        }

        try signAppBundle(
            appBundlePath: appURL.path,
            provisionPath: provisionPath,
            p12Path: p12Path,
            p12Password: p12Password,
            bundleID: bundleID,
            displayName: displayName,
            version: version
        )

        let signed = fm.temporaryDirectory
            .appendingPathComponent(ipaURL.deletingPathExtension().lastPathComponent + "-signed")
            .appendingPathExtension("ipa")
        try? fm.removeItem(at: signed)
        try archiver.pack(payloadRoot: work, to: signed)
        return signed
    }

    // MARK: - Dylib tools (tweak injection)

    nonisolated static func injectDylib(
        intoMachO machoPath: String,
        dylibPath: String,
        weak: Bool = false,
        createIfMissing: Bool = true
    ) throws {
        if !InjectDyLib(machoPath, dylibPath, weak, createIfMissing) {
            throw ZsignError.dylibInjectionFailed(macho: machoPath, dylib: dylibPath)
        }
    }

    nonisolated static func listDylibs(inMachO machoPath: String) -> [String] {
        let out = NSMutableArray()
        _ = ListDylibs(machoPath, out)
        return out.compactMap { $0 as? String }
    }

    @discardableResult
    nonisolated static func removeDylibs(inMachO machoPath: String, _ dylibs: [String]) -> Bool {
        UninstallDylibs(machoPath, dylibs)
    }

    @discardableResult
    nonisolated static func changeDylibPath(inMachO machoPath: String, from old: String, to new: String) -> Bool {
        ChangeDylibPath(machoPath, old, new)
    }
}

protocol IPAArchiver {
    /// Extract `ipa` under `dir` and return the URL of `dir/Payload/<App>.app`.
    func unpack(ipa: URL, into dir: URL) throws -> URL
    /// Zip everything under `payloadRoot` (which contains `Payload/`) into `ipa`.
    func pack(payloadRoot: URL, to ipa: URL) throws
}

nonisolated struct SignOutcome: Sendable {
    let ipaURL: URL          // file:// temp path of the signed IPA
    let name: String
    let bundleID: String
    let version: String
}

nonisolated enum Signer {

    nonisolated static func signDetached(
        ipaURL: URL,
        material: CertMaterial,
        nameOverride: String?,
        bundleIDOverride: String?,
        versionOverride: String?,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> SignOutcome {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sign-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Stage cert + profile — zsign takes file paths.
        let p12URL  = work.appendingPathComponent("cert.p12")
        let provURL = work.appendingPathComponent("profile.mobileprovision")
        try material.p12.write(to: p12URL)
        try material.provision.write(to: provURL)

        // 2. Unzip → locate Payload/*.app
        let extractDir = work.appendingPathComponent("x", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        onLog?(">>> Extracting IPA…")
        try fm.unzipItem(at: ipaURL, to: extractDir)
        let payload = extractDir.appendingPathComponent("Payload", isDirectory: true)
        guard let appURL = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw ZsignError.appBundleNotFound(inIPA: ipaURL.lastPathComponent)
        }

        // 3. Sign in place — capture the engine's real stdout.
        let capture = onLog.map { ConsoleCapture($0) }
        capture?.start()
        do {
            try ZsignSigner.signAppBundle(
                appBundlePath: appURL.path,
                provisionPath: provURL.path,
                p12Path:       p12URL.path,
                p12Password:   material.password,
                bundleID:      bundleIDOverride,
                displayName:   nameOverride,
                version:       versionOverride
            )
            capture?.stop()
        } catch {
            capture?.stop()
            throw error
        }

        // 4. Read identifiers back from the (possibly overridden) Info.plist.
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist"))
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? nameOverride ?? appURL.deletingPathExtension().lastPathComponent
        let bundleID = (info?["CFBundleIdentifier"] as? String) ?? bundleIDOverride ?? "unknown.bundle.id"
        let version  = (info?["CFBundleShortVersionString"] as? String) ?? versionOverride ?? "1.0"

        // 5. Repack (stored) → signed .ipa in temp.
        let signed = fm.temporaryDirectory
            .appendingPathComponent("\(name)-signed-\(UUID().uuidString)")
            .appendingPathExtension("ipa")
        try? fm.removeItem(at: signed)
        onLog?(">>> Packaging signed IPA…")
        try fm.zipItem(at: payload, to: signed, shouldKeepParent: true, compressionMethod: .none)
        onLog?(">>> Done.")

        return SignOutcome(ipaURL: signed, name: name, bundleID: bundleID, version: version)
    }
}

nonisolated struct IPAMeta: Sendable {
    var name: String
    var bundleID: String
    var version: String
    var iconPNG: Data?

    static func read(_ ipa: URL) throws -> IPAMeta {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("meta-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        try fm.unzipItem(at: ipa, to: work)

        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        guard let app = try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            // Not a normal IPA layout — fall back to the filename.
            let base = ipa.deletingPathExtension().lastPathComponent
            return IPAMeta(name: base, bundleID: "unknown.bundle.id", version: "1.0", iconPNG: nil)
        }

        let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        let bundleID = (info?["CFBundleIdentifier"] as? String) ?? "unknown.bundle.id"
        let version  = (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String) ?? "1.0"

        let icon = primaryIcon(in: app, info: info)
        return IPAMeta(name: name, bundleID: bundleID, version: version, iconPNG: icon)
    }

    /// Best effort: resolve the primary icon file name from Info.plist, else
    /// grab the largest AppIcon*.png at the app root.
    private static func primaryIcon(in app: URL, info: NSDictionary?) -> Data? {
        let fm = FileManager.default
        var candidateNames: [String] = []

        if let icons = info?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            candidateNames = files.reversed()   // last is usually the largest
        }

        let all = (try? fm.contentsOfDirectory(at: app, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension.lowercased() == "png" } ?? []

        // Prefer a file matching a declared icon base name.
        for base in candidateNames {
            if let hit = all.first(where: { $0.lastPathComponent.hasPrefix(base) }),
               let d = try? Data(contentsOf: hit) { return d }
        }
        // Otherwise the biggest PNG that looks like an app icon.
        let iconish = all.filter { $0.lastPathComponent.localizedCaseInsensitiveContains("AppIcon")
            || $0.lastPathComponent.localizedCaseInsensitiveContains("Icon") }
        let pool = iconish.isEmpty ? all : iconish
        let largest = pool.max { (a, b) in
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        }
        return largest.flatMap { try? Data(contentsOf: $0) }
    }
}

nonisolated final class ConsoleCapture: @unchecked Sendable {
    private let onLine: @Sendable (String) -> Void
    private let pipe = Pipe()
    private var savedOut: Int32 = -1
    private var savedErr: Int32 = -1
    private var buffer = Data()
    private let lock = NSLock()

    init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func start() {
        savedOut = dup(fileno(stdout))
        savedErr = dup(fileno(stderr))
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stdout))
        dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stderr))

        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            self.lock.lock(); self.buffer.append(d); self.drain(); self.lock.unlock()
        }
    }

    func stop() {
        fflush(stdout); fflush(stderr)
        if savedOut >= 0 { dup2(savedOut, fileno(stdout)); close(savedOut); savedOut = -1 }
        if savedErr >= 0 { dup2(savedErr, fileno(stderr)); close(savedErr); savedErr = -1 }
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        if !buffer.isEmpty { emit(String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
        lock.unlock()
    }

    private func drain() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            emit(String(decoding: line, as: UTF8.self))
        }
    }

    private func emit(_ text: String) {
        let t = text.trimmingCharacters(in: .newlines)
        guard !t.isEmpty else { return }
        onLine(t)
    }
}
