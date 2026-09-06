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

nonisolated struct SignOptions: Sendable {
    // identity
    var name: String?
    var bundleID: String?
    var version: String?
    var iconPNG: Data?                 // replaces AppIcon (all sizes) if set

    // dylib injection: (localFileURL, weak)
    var injectDylibs: [(url: URL, weak: Bool)] = []
    var injectPath = "@executable_path"        // or @rpath
    var injectFolder = "/"                       // "/" (next to binary) or "Frameworks/"
    var removeDylibs: [String] = []              // load-command paths to strip

    // Info.plist tweaks
    var plistSet: [String: String] = [:]         // key → string value (bool as "true"/"false")
    var forceMinIOS: String?                     // e.g. "12.0"
    var disableFileSharing = false
    var forcePortrait = false
    var skipIPad = false
    var disableATS = false

    // strip content (bundle mutations before signing)
    var stripSCInfo = false
    var stripPrivacyManifests = false
    var stripWatchApps = false
    var stripExtensions = false
    var removeURLSchemes = false

    var skipEmbeddedProvision = false

    static let none = SignOptions()

    var isEmpty: Bool {
        name == nil && bundleID == nil && version == nil && iconPNG == nil
        && injectDylibs.isEmpty && removeDylibs.isEmpty && plistSet.isEmpty
        && forceMinIOS == nil && !disableFileSharing && !forcePortrait && !skipIPad && !disableATS
        && !stripSCInfo && !stripPrivacyManifests && !stripWatchApps && !stripExtensions && !removeURLSchemes
    }
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
        var o = SignOptions()
        o.name = nameOverride; o.bundleID = bundleIDOverride; o.version = versionOverride
        return try await signDetached(ipaURL: ipaURL, material: material, options: o, onLog: onLog)
    }

    nonisolated static func signDetached(
        ipaURL: URL,
        material: CertMaterial,
        options o: SignOptions,
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

        // 2b. Pre-sign mutations (strip content, plist tweaks, icon, dylibs).
        try applyPreSign(appURL: appURL, options: o, onLog: onLog)

        // 3. Sign in place — capture the engine's real stdout.
        let capture = onLog.map { ConsoleCapture($0) }
        capture?.start()
        do {
            try ZsignSigner.signAppBundle(
                appBundlePath: appURL.path,
                provisionPath: provURL.path,
                p12Path:       p12URL.path,
                p12Password:   material.password,
                bundleID:      o.bundleID,
                displayName:   o.name,
                version:       o.version,
                skipEmbeddedProvision: o.skipEmbeddedProvision
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
            ?? o.name ?? appURL.deletingPathExtension().lastPathComponent
        let bundleID = (info?["CFBundleIdentifier"] as? String) ?? o.bundleID ?? "unknown.bundle.id"
        let version  = (info?["CFBundleShortVersionString"] as? String) ?? o.version ?? "1.0"

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

    // MARK: - Pre-sign mutations

    private nonisolated static func applyPreSign(appURL: URL, options o: SignOptions, onLog: (@Sendable (String) -> Void)?) throws {
        let fm = FileManager.default
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let binName = (NSDictionary(contentsOf: infoURL)?["CFBundleExecutable"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let binURL = appURL.appendingPathComponent(binName)

        // Strip content
        if o.stripSCInfo {
            let sc = appURL.appendingPathComponent("SC_Info", isDirectory: true)
            if fm.fileExists(atPath: sc.path) { try? fm.removeItem(at: sc); onLog?(">>> stripped SC_Info") }
        }
        if o.stripPrivacyManifests, let e = fm.enumerator(at: appURL, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.lastPathComponent == "PrivacyInfo.xcprivacy" || u.pathExtension == "xcprivacy" { try? fm.removeItem(at: u) }
            onLog?(">>> stripped privacy manifests")
        }
        if o.stripWatchApps {
            let w = appURL.appendingPathComponent("Watch", isDirectory: true)
            if fm.fileExists(atPath: w.path) { try? fm.removeItem(at: w); onLog?(">>> removed Watch app") }
        }
        if o.stripExtensions {
            let px = appURL.appendingPathComponent("PlugIns", isDirectory: true)
            if fm.fileExists(atPath: px.path) { try? fm.removeItem(at: px); onLog?(">>> removed app extensions") }
        }

        // Info.plist tweaks
        if let dict = NSMutableDictionary(contentsOf: infoURL) {
            var changed = false
            for (k, v) in o.plistSet {
                if v == "true" || v == "false" { dict[k] = (v == "true") } else if let n = Int(v) { dict[k] = n } else { dict[k] = v }
                changed = true
            }
            if let m = o.forceMinIOS { dict["MinimumOSVersion"] = m; changed = true }
            if o.disableFileSharing { dict["UIFileSharingEnabled"] = false; changed = true }
            if o.forcePortrait { dict["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait"]; changed = true }
            if o.skipIPad { dict["UIDeviceFamily"] = [1]; changed = true }
            if o.removeURLSchemes { dict.removeObject(forKey: "CFBundleURLTypes"); changed = true }
            if o.disableATS {
                dict["NSAppTransportSecurity"] = ["NSAllowsArbitraryLoads": true]; changed = true
            }
            if changed { dict.write(to: infoURL, atomically: true); onLog?(">>> applied Info.plist tweaks") }
        }

        // Icon replacement (write one PNG at the standard names; zsign re-signs the bundle after).
        if let png = o.iconPNG {
            for name in ["AppIcon60x60@2x.png", "AppIcon60x60@3x.png", "AppIcon76x76@2x~ipad.png", "AppIcon.png"] {
                try? png.write(to: appURL.appendingPathComponent(name))
            }
            // point Info.plist at a flat icon file too
            if let dict = NSMutableDictionary(contentsOf: infoURL) {
                dict["CFBundleIconFile"] = "AppIcon"
                dict["CFBundleIcons"] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]]
                dict.write(to: infoURL, atomically: true)
            }
            onLog?(">>> replaced app icon")
        }

        // Dylibs: remove first, then inject.
        if !o.removeDylibs.isEmpty, fm.fileExists(atPath: binURL.path) {
            _ = ZsignSigner.removeDylibs(inMachO: binURL.path, o.removeDylibs)
            onLog?(">>> removed \(o.removeDylibs.count) dylib load command(s)")
        }
        for d in o.injectDylibs {
            let folder = o.injectFolder == "Frameworks/" ? appURL.appendingPathComponent("Frameworks", isDirectory: true) : appURL
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(d.url.lastPathComponent)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: d.url, to: dest)
            let loadPath = (o.injectFolder == "Frameworks/" ? "\(o.injectPath)/Frameworks/" : "\(o.injectPath)/") + d.url.lastPathComponent
            try ZsignSigner.injectDylib(intoMachO: binURL.path, dylibPath: loadPath, weak: d.weak, createIfMissing: true)
            onLog?(">>> injected \(d.url.lastPathComponent) (\(d.weak ? "weak" : "normal"))")
        }
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
