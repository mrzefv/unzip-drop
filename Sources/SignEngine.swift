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

func xmlPlistData(fromMobileProvision data: Data) -> Data? {
    guard let start = data.range(of: Data("<?xml".utf8)),
          let end = data.range(of: Data("</plist>".utf8)) else { return nil }
    return data.subdata(in: start.lowerBound..<end.upperBound)
}

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
    ///   - skipEmbeddedProvision: kept for API compat. This zsign fork only WRITES
    ///     embedded.mobileprovision inside `if(dontGenerateEmbeddedMobileProvision)`,
    ///     so we always pass true; a post-sign guard below also verifies the file exists.
    nonisolated static func signAppBundle(
        appBundlePath: String,
        provisionPath: String,
        p12Path: String,
        p12Password: String,
        bundleID: String? = nil,
        displayName: String? = nil,
        version: String? = nil,
        entitlementsPath: String? = nil,
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
            entitlementsPath ?? "",
            true   // fork writes embedded.mobileprovision only inside `if(dontGenerate…)`; always embed
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
    var entitlements: [String: String] = [:]
    var sizeBytes: Int64 = 0
}

/// A raw byte edit to the app's main Mach-O, resolved from a virtual address.
/// `fileOffset` is into the THIN arm64 slice; the engine maps it back into the
/// fat binary on disk if needed. `original` lets us verify before writing.
nonisolated struct BinaryPatch: Sendable, Identifiable, Equatable {
    let id: UUID
    let label: String          // human description for the log
    let fileOffset: Int        // offset into the thin arm64 slice
    let bytes: [UInt8]         // replacement bytes
    let original: [UInt8]      // expected current bytes (verify guard); empty = skip check
    init(id: UUID = UUID(), label: String, fileOffset: Int, bytes: [UInt8], original: [UInt8] = []) {
        self.id = id; self.label = label; self.fileOffset = fileOffset; self.bytes = bytes; self.original = original
    }
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
    var binaryPatches: [BinaryPatch] = []        // raw byte edits (string rewrites / insn patches) applied to the thin binary
    var injectDataBlob: Data? = nil              // Mcrypted-512 payload appended to the main binary before signing

    // Info.plist tweaks
    var plistSet: [String: String] = [:]         // key → string value (bool as "true"/"false")
    var entitlementsPlistData: Data? = nil
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
    var stripBitcode = false
    var stripDebugSymbols = false

    // Entitlement scrubbers (mutate the entitlements plist before it reaches zsign)
    var autoFixEntitlements = false     // drop ents not granted by the signing profile
    var disablePush = false             // strip aps-environment
    var disableAppGroups = false        // strip application-groups
    var disableiCloud = false           // strip iCloud container + ubiquity
    var disableSiri = false             // strip developer.siri
    var disableBackgroundModes = false  // strip UIBackgroundModes (Info.plist)

    var skipEmbeddedProvision = false
    var surgicalMode = true             // engine default; SigningSheet overrides to opt-in
    var parallelSigning = true          // engine default; SigningSheet overrides to opt-in and zsign still disables it for guarded cases

    static let none = SignOptions()

    var isEmpty: Bool {
        name == nil && bundleID == nil && version == nil && iconPNG == nil
        && injectDylibs.isEmpty && removeDylibs.isEmpty && binaryPatches.isEmpty && injectDataBlob == nil && plistSet.isEmpty && entitlementsPlistData == nil
        && forceMinIOS == nil && !disableFileSharing && !forcePortrait && !skipIPad && !disableATS
        && !stripSCInfo && !stripPrivacyManifests && !stripWatchApps && !stripExtensions && !removeURLSchemes
        && !stripBitcode && !stripDebugSymbols
        && !autoFixEntitlements && !disablePush && !disableAppGroups && !disableiCloud && !disableSiri && !disableBackgroundModes
    }
}

nonisolated enum Signer {
    static let parallelSigningMaxIPABytes: Int64 = 500 * 1_024 * 1_024

    enum ParallelSigningDecision: Equatable {
        case enabled
        case disabledByUser
        case disabledByDylibInjection
        case disabledByUnknownIPASize
        case disabledByIPASize(actual: Int64)

        var isEnabled: Bool {
            if case .enabled = self { return true }
            return false
        }

        var logMessage: String? {
            switch self {
            case .enabled, .disabledByUser:
                return nil
            case .disabledByDylibInjection:
                return ">>> Parallel signing disabled: dylib injection selected."
            case .disabledByUnknownIPASize:
                return ">>> Parallel signing disabled: couldn't determine IPA size safely."
            case .disabledByIPASize(let actual):
                let actualText = ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)
                let limitText = ByteCountFormatter.string(fromByteCount: Signer.parallelSigningMaxIPABytes, countStyle: .file)
                return ">>> Parallel signing disabled: \(actualText) IPA exceeds the \(limitText) safety cap."
            }
        }

        var statusText: String {
            switch self {
            case .enabled:
                return "Parallel signing"
            case .disabledByUser:
                return "Parallel signing"
            case .disabledByDylibInjection:
                return "Parallel signing (auto-disabled: dylibs)"
            case .disabledByUnknownIPASize:
                return "Parallel signing (auto-disabled: unknown size)"
            case .disabledByIPASize:
                return "Parallel signing (auto-disabled: large IPA)"
            }
        }

        var noteText: String {
            switch self {
            case .enabled, .disabledByUser:
                return "Signs sibling frameworks and binaries concurrently inside zsign"
            case .disabledByDylibInjection:
                return "Signs sibling frameworks and binaries concurrently inside zsign — currently auto-disabled because dylib injection is selected"
            case .disabledByUnknownIPASize:
                return "Signs sibling frameworks and binaries concurrently inside zsign — currently auto-disabled because the IPA size could not be determined safely"
            case .disabledByIPASize:
                let limitText = ByteCountFormatter.string(fromByteCount: Signer.parallelSigningMaxIPABytes, countStyle: .file)
                return "Signs sibling frameworks and binaries concurrently inside zsign — currently auto-disabled because this IPA exceeds the \(limitText) safety cap"
            }
        }
    }

    nonisolated static func parallelSigningDecision(
        ipaURL: URL,
        options o: SignOptions
    ) -> ParallelSigningDecision {
        guard o.parallelSigning else { return .disabledByUser }
        guard o.injectDylibs.isEmpty else { return .disabledByDylibInjection }
        guard let ipaSize = (try? FileManager.default.attributesOfItem(atPath: ipaURL.path)[.size] as? Int64) else {
            return .disabledByUnknownIPASize
        }
        guard ipaSize <= parallelSigningMaxIPABytes else {
            return .disabledByIPASize(actual: ipaSize)
        }
        return .enabled
    }

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
        o.surgicalMode = false
        o.parallelSigning = false
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

        // 3. Sign in place — capture the engine's real stdout, mSign-style.
        let capture = onLog.map { ConsoleCapture($0) }
        capture?.start()
        do {
            let parallelDecision = parallelSigningDecision(ipaURL: ipaURL, options: o)
            if let msg = parallelDecision.logMessage { onLog?(msg) }
            ZSignSetParallel(parallelDecision.isEnabled)
            let entitlementsURL: URL?
            if let scrubbed = Self.scrubbedEntitlements(o.entitlementsPlistData, options: o, profile: material.provision, onLog: onLog) {
                let u = work.appendingPathComponent("entitlements.plist")
                try scrubbed.write(to: u)
                entitlementsURL = u
            } else {
                entitlementsURL = nil
            }

            try ZsignSigner.signAppBundle(
                appBundlePath: appURL.path,
                provisionPath: provURL.path,
                p12Path: p12URL.path,
                p12Password: material.password,
                bundleID: o.bundleID,
                displayName: o.name,
                version: o.version,
                entitlementsPath: entitlementsURL?.path,
                skipEmbeddedProvision: o.skipEmbeddedProvision
            )
            capture?.stop()
        } catch {
            capture?.stop()
            throw error
        }

        // Deterministic safety net: installd refuses an app with no profile. If for
        // any reason zsign didn't write embedded.mobileprovision, write it ourselves
        // from the same provisioning file we signed with, then re-seal is unneeded
        // (the profile isn't part of the code signature).
        let embeddedProv = appURL.appendingPathComponent("embedded.mobileprovision")
        if !fm.fileExists(atPath: embeddedProv.path) {
            try? material.provision.write(to: embeddedProv)
            onLog?(">>> embedded.mobileprovision was missing — wrote it from the signing profile")
        }

        // 4. Read identifiers back from the SIGNED app's own Info.plist — this is
        //    what installd will check the manifest against, so it must be exact.
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let info = NSDictionary(contentsOf: infoURL)
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? o.name ?? appURL.deletingPathExtension().lastPathComponent
        // Bundle id straight from the signed app's Info.plist (mSign does exactly
        // this). Never the filename; com.unknown.app only if the plist is unreadable.
        let bundleID = (info?["CFBundleIdentifier"] as? String) ?? o.bundleID ?? "com.unknown.app"
        let version  = (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String) ?? o.version ?? "1.0"

        // 5. Repack (stored) → signed .ipa in temp.
        let signed = fm.temporaryDirectory
            .appendingPathComponent("\(name)-signed-\(UUID().uuidString)")
            .appendingPathExtension("ipa")
        try? fm.removeItem(at: signed)
        onLog?(">>> Packaging signed IPA…")
        try fm.zipItem(at: payload, to: signed, shouldKeepParent: true, compressionMethod: .none)
        onLog?(">>> Done.")

        let ents = Signer.readEntitlements(appURL: appURL)
        let sz = (try? fm.attributesOfItem(atPath: signed.path)[.size] as? Int64) ?? 0
        return SignOutcome(ipaURL: signed, name: name, bundleID: bundleID, version: version, entitlements: ents, sizeBytes: sz)
    }

    /// Best-effort entitlements read from the signed app's embedded profile.
    /// The .mobileprovision is a CMS blob; its plist payload has an "Entitlements"
    /// dict. We extract the plist span and read that key. Values are flattened to
    /// strings/lists for display in the install prompt.
    nonisolated static func readEntitlements(appURL: URL) -> [String: String] {
        let prov = appURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: prov),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else { return [:] }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let obj = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let ent = obj["Entitlements"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in ent {
            if let b = v as? Bool { out[k] = b ? "true" : "false" }
            else if let s = v as? String { out[k] = s }
            else if let arr = v as? [String] { out[k] = arr.joined(separator: ", ") }
            else if let arr = v as? [Any] { out[k] = arr.map { "\($0)" }.joined(separator: ", ") }
            else { out[k] = "\(v)" }
        }
        return out
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
            if o.disableBackgroundModes { dict.removeObject(forKey: "UIBackgroundModes"); changed = true }
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
        if !o.binaryPatches.isEmpty, fm.fileExists(atPath: binURL.path) {
            let applied = LocalBinaryScanner.applyPatches(o.binaryPatches, toBinaryAt: binURL.path)
            onLog?(">>> applied \(applied)/\(o.binaryPatches.count) binary patch(es)")
        }
        if let blob = o.injectDataBlob {
            // Primary: sealed resource inside the .app. zsign seals it into
            // _CodeSignature/CodeResources, so it survives resign intact and
            // recovery can read it straight out of the IPA.
            let dat = appURL.appendingPathComponent("mcrypted.dat")
            try? blob.write(to: dat, options: .atomic)
            onLog?(">>> injected Mcrypted-512 payload (\(blob.count) bytes) → mcrypted.dat")
            // Secondary (belt-and-suspenders): append to the binary too. zsign may
            // rewrite __LINKEDIT, so this copy isn't guaranteed, but costs nothing.
            if fm.fileExists(atPath: binURL.path), var bin = fm.contents(atPath: binURL.path) {
                bin.append(blob)
                try? bin.write(to: binURL)
            }
        }
        if !o.injectDylibs.isEmpty, fm.fileExists(atPath: binURL.path) {
            // Substrate-linked tweaks (built against CydiaSubstrate / MSHookFunction /
            // %hook) need ElleKit's shim present in Frameworks/ or they silently fail to
            // load at launch. Stage it once before injecting the user's dylibs.
            Signer.installSubstrate(into: appURL, mainExe: binURL, onLog: onLog)
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


    // MARK: - ElleKit (CydiaSubstrate shim)

    /// Unzips the bundled `CydiaSubstrate.framework.zip` into `App.app/Frameworks/`
    /// and weak-links it into the main executable, so tweaks that depend on
    /// `@rpath/CydiaSubstrate.framework/CydiaSubstrate` (ElleKit / substrate hooks)
    /// resolve at launch. No-op if the framework is already present or the zip
    /// isn't bundled in the app.
    nonisolated static func installSubstrate(into appURL: URL, mainExe exeURL: URL, onLog: ((String) -> Void)?) {
        let fm = FileManager.default
        let frameworks = appURL.appendingPathComponent("Frameworks", isDirectory: true)
        let dest = frameworks.appendingPathComponent("CydiaSubstrate.framework", isDirectory: true)

        if !fm.fileExists(atPath: dest.path) {
            guard let zip = Bundle.main.url(forResource: "CydiaSubstrate.framework", withExtension: "zip") else {
                onLog?(">>> note: CydiaSubstrate.framework.zip not bundled — substrate tweaks may not load")
                return
            }
            try? fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
            do { try fm.unzipItem(at: zip, to: frameworks) }
            catch { onLog?(">>> failed to stage ElleKit: \(error.localizedDescription)"); return }
            onLog?(">>> staged ElleKit CydiaSubstrate.framework → Frameworks/")
        }

        let fwExe = dest.appendingPathComponent("CydiaSubstrate")
        guard fm.fileExists(atPath: fwExe.path) else { return }
        try? ZsignSigner.injectDylib(
            intoMachO: exeURL.path,
            dylibPath: "@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            weak: true, createIfMissing: true
        )
        onLog?(">>> linked @executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate")
    }

    // MARK: - Entitlement scrubbers

    /// Applies the Entitlement Scrubbers toggles to the entitlements plist handed to zsign.
    /// Returns nil when there is nothing to sign with (no base ents, no scrub requested),
    /// otherwise the mutated plist Data.
    nonisolated static func scrubbedEntitlements(_ base: Data?, options o: SignOptions, profile: Data, onLog: ((String) -> Void)?) -> Data? {
        let wantsScrub = o.autoFixEntitlements || o.disablePush || o.disableAppGroups || o.disableiCloud || o.disableSiri
        guard base != nil || wantsScrub else { return base }

        var ent: [String: Any] = [:]
        if let base, let obj = try? PropertyListSerialization.propertyList(from: base, format: nil) as? [String: Any] {
            ent = obj
        }
        guard !ent.isEmpty || wantsScrub else { return base }

        var removed: [String] = []
        func drop(_ key: String) { if ent.removeValue(forKey: key) != nil { removed.append(key) } }

        if o.disablePush { drop("aps-environment") }
        if o.disableAppGroups { drop("com.apple.security.application-groups") }
        if o.disableiCloud {
            for k in ["com.apple.developer.icloud-container-identifiers",
                      "com.apple.developer.icloud-container-environment",
                      "com.apple.developer.icloud-services",
                      "com.apple.developer.ubiquity-container-identifiers",
                      "com.apple.developer.ubiquity-kvstore-identifier"] { drop(k) }
        }
        if o.disableSiri { drop("com.apple.developer.siri") }

        if o.autoFixEntitlements,
           let xml = xmlPlistData(fromMobileProvision: profile),
           let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
           let granted = plist["Entitlements"] as? [String: Any] {
            for key in ent.keys where granted[key] == nil {
                if key == "application-identifier" || key == "com.apple.developer.team-identifier" { continue }
                ent.removeValue(forKey: key); removed.append(key)
            }
        }

        if !removed.isEmpty { onLog?(">>> scrubbed entitlements: \(Set(removed).sorted().joined(separator: ", "))") }
        if ent.isEmpty { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: ent, format: .xml, options: 0)
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

        // Prefer Payload/*.app; if the layout is odd, search recursively for any
        // .app with an Info.plist rather than falling back to the filename (which
        // would poison the bundle id and make installd reject the manifest).
        var app: URL? = (try? fm.contentsOfDirectory(at: work.appendingPathComponent("Payload"), includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" })
        if app == nil, let e = fm.enumerator(at: work, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension == "app"
                && fm.fileExists(atPath: u.appendingPathComponent("Info.plist").path) { app = u; break }
        }
        guard let app else {
            // mSign convention: never let the filename become a bundle id.
            let base = ipa.deletingPathExtension().lastPathComponent
            return IPAMeta(name: base, bundleID: "com.unknown.app", version: "1.0", iconPNG: nil)
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
