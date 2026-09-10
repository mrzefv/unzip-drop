//
//  LocalCAManager.swift
//  Hand-rolled OTA TLS. Generates a root CA once (LocalCA.mm / OpenSSL). The
//  private keys (root + leaf) live ONLY in the Keychain, marked
//  kSecAttrAccessibleWhenUnlockedThisDeviceOnly — never included in an
//  iTunes/Finder or iCloud backup and never portable to another device.
//  Certs (public, harmless) are plain files in Documents so Vapor's TLS
//  config and the .mobileconfig builder can read them directly. Keys are
//  materialized to a private temp file only for the instant Vapor needs to
//  load them, then deleted immediately.
//

import Foundation
import Security

nonisolated enum LocalCAManager {
    private static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var rootCertURL: URL { docs.appendingPathComponent("localca-root.crt") }   // PEM, public
    static var leafCertURL: URL { docs.appendingPathComponent("localca-leaf.crt") }   // PEM fullchain, public
    static var metaURL:     URL { docs.appendingPathComponent("localca.json") }

    private static let kRootKey = "localca-root-key"
    private static let kLeafKey = "localca-leaf-key"

    // Persistent iCloud-Keychain mirrors. These survive app deletion so the
    // user's root CA (and any trust they've installed on-device) is
    // recoverable on reinstall without regenerating.
    private static let kRootKeyPersistent  = "uzd-localca-root-key"
    private static let kRootCertPersistent = "uzd-localca-root-cert"
    private static let kLeafKeyPersistent  = "uzd-localca-leaf-key"
    private static let kLeafCertPersistent = "uzd-localca-leaf-cert"
    private static let kMetaPersistent     = "uzd-localca-meta"

    static let leafValidDays = 397   // iOS rejects TLS leaves valid > 398 days

    struct Meta: Codable, Sendable { var host: String; var rootCreated: Date; var leafIssued: Date; var validYears: Int; var validDays: Int? }

    static var meta: Meta? {
        rehydrateIfNeeded()
        guard let d = try? Data(contentsOf: metaURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Meta.self, from: d)
    }

    static var hasRoot: Bool {
        rehydrateIfNeeded()
        return FileManager.default.fileExists(atPath: rootCertURL.path) && Keychain.getSecret(kRootKey) != nil
    }
    static var hasLeaf: Bool {
        rehydrateIfNeeded()
        return FileManager.default.fileExists(atPath: leafCertURL.path) && Keychain.getSecret(kLeafKey) != nil
    }

    /// Reconstitutes root/leaf cert files and Keychain private-key entries
    /// from iCloud Keychain backup if the on-disk versions are missing (e.g.
    /// fresh reinstall). Idempotent — checks each item independently.
    static func rehydrateIfNeeded() {
        if !FileManager.default.fileExists(atPath: rootCertURL.path),
           let cert = Keychain.getPersistent(kRootCertPersistent), !cert.isEmpty {
            try? cert.write(to: rootCertURL, options: .atomic)
        }
        if Keychain.getSecret(kRootKey) == nil,
           let key = Keychain.getPersistentString(kRootKeyPersistent), !key.isEmpty {
            _ = Keychain.setSecret(kRootKey, key)
        }
        if !FileManager.default.fileExists(atPath: leafCertURL.path),
           let cert = Keychain.getPersistent(kLeafCertPersistent), !cert.isEmpty {
            try? cert.write(to: leafCertURL, options: .atomic)
        }
        if Keychain.getSecret(kLeafKey) == nil,
           let key = Keychain.getPersistentString(kLeafKeyPersistent), !key.isEmpty {
            _ = Keychain.setSecret(kLeafKey, key)
        }
        if !FileManager.default.fileExists(atPath: metaURL.path),
           let m = Keychain.getPersistent(kMetaPersistent), !m.isEmpty {
            try? m.write(to: metaURL, options: .atomic)
        }
    }

    enum CAError: LocalizedError {
        case generateFailed, issueFailed, noRoot, keychainWriteFailed
        var errorDescription: String? {
            switch self {
            case .generateFailed:     return "Couldn't generate the root CA."
            case .issueFailed:        return "Couldn't issue the leaf certificate."
            case .noRoot:             return "No local root CA yet — create one first."
            case .keychainWriteFailed: return "Couldn't save the private key to the Keychain."
            }
        }
    }

    /// Create the root once (idempotent unless force). Key → Keychain only; cert → file.
    @discardableResult
    static func ensureRoot(commonName: String = "MRvEK Local Root CA", years: Int = 10, force: Bool = false) throws -> Bool {
        rehydrateIfNeeded()
        if hasRoot && !force { return false }
        guard let pair = LocalCA.generateRootCA(withCommonName: commonName, validYears: Int32(years)),
              let cert = pair["cert"], let key = pair["key"] else { throw CAError.generateFailed }
        let certData = cert.data(using: .utf8)!
        try certData.write(to: rootCertURL, options: .atomic)
        guard Keychain.setSecret(kRootKey, key) else { throw CAError.keychainWriteFailed }
        // Mirror to iCloud Keychain so a reinstall keeps the same root CA.
        Keychain.setPersistent(kRootCertPersistent, certData)
        Keychain.setPersistentString(kRootKeyPersistent, key)
        return true
    }

    /// Issue (or re-issue) a leaf for `host`. Key → Keychain only; fullchain cert → file.
    static func issueLeaf(host: String, days: Int = leafValidDays) throws {
        try ensureRoot()
        guard let rootCert = try? String(contentsOf: rootCertURL),
              let rootKey  = Keychain.getSecret(kRootKey) else { throw CAError.noRoot }
        let capped = min(max(days, 1), 397)
        guard let pair = LocalCA.issueLeaf(forHost: host, rootCertPEM: rootCert, rootKeyPEM: rootKey, validDays: Int32(capped)),
              let cert = pair["cert"], let key = pair["key"] else { throw CAError.issueFailed }
        let certData = cert.data(using: .utf8)!
        try certData.write(to: leafCertURL, options: .atomic)
        guard Keychain.setSecret(kLeafKey, key) else { throw CAError.keychainWriteFailed }
        // Mirror to iCloud Keychain.
        Keychain.setPersistent(kLeafCertPersistent, certData)
        Keychain.setPersistentString(kLeafKeyPersistent, key)
        let m = Meta(host: host, rootCreated: rootCreatedDate(), leafIssued: Date(), validYears: 0, validDays: capped)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let mData = try? enc.encode(m) {
            try? mData.write(to: metaURL)
            Keychain.setPersistent(kMetaPersistent, mData)
        }
    }

    /// When the current leaf expires (nil if none).
    static var leafExpiry: Date? {
        guard let m = meta, let d = m.validDays else {
            // legacy leaf issued in years
            return meta.map { $0.leafIssued.addingTimeInterval(Double($0.validYears) * 365 * 86400) }
        }
        return m.leafIssued.addingTimeInterval(Double(d) * 86400)
    }
    static var leafDaysLeft: Int? { leafExpiry.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 } }
    static var leafNeedsReissue: Bool { (leafDaysLeft ?? -1) < 30 }

    /// Re-issue the current host's leaf if it's within 30 days of expiry.
    @discardableResult
    static func reissueIfNeeded() -> Bool {
        guard hasLeaf, leafNeedsReissue, let host = meta?.host else { return false }
        try? issueLeaf(host: host)
        return true
    }

    static func reset() {
        for u in [rootCertURL, leafCertURL, metaURL] { try? FileManager.default.removeItem(at: u) }
        Keychain.deleteSecret(kRootKey)
        Keychain.deleteSecret(kLeafKey)
        // Also wipe iCloud Keychain mirrors — explicit user reset should not
        // resurrect the CA on the next launch or on another device.
        Keychain.setPersistent(kRootCertPersistent, Data())
        Keychain.setPersistentString(kRootKeyPersistent, "")
        Keychain.setPersistent(kLeafCertPersistent, Data())
        Keychain.setPersistentString(kLeafKeyPersistent, "")
        Keychain.setPersistent(kMetaPersistent, Data())
    }

    private static func rootCreatedDate() -> Date {
        (try? FileManager.default.attributesOfItem(atPath: rootCertURL.path)[.creationDate] as? Date) ?? Date()
    }

    // MARK: Leaf key — materialized just-in-time for Vapor's TLS config

    /// Writes the leaf private key to a private, excluded-from-backup temp file
    /// so `NIOSSLPrivateKey(file:)` can load it, then deletes it. Callers must
    /// use the URL immediately and not retain it.
    static func withLeafKeyFile<T>(_ body: (URL) throws -> T) throws -> T {
        guard let key = Keychain.getSecret(kLeafKey) else { throw CAError.noRoot }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("localca-leaf-\(UUID().uuidString).key")
        try key.data(using: .utf8)!.write(to: tmp, options: [.atomic, .completeFileProtection])
        var noBackup = URL(fileURLWithPath: tmp.path)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? noBackup.setResourceValues(rv)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try body(tmp)
    }

    // MARK: Leaf SANs (for the "does this cert cover this host" check)

    static func leafSANs() -> [String] {
        guard let pem = try? String(contentsOf: leafCertURL) else { return [] }
        // Reuse the same SAN parser style as ZefvCert: read from the leaf's own
        // Common Name, plus the wildcard we always issue (host + *.host).
        guard let m = meta else { return [] }
        return [m.host, "*.\(m.host)"]
    }

    /// Does the current local leaf cover `host`? Exact match or our issued wildcard.
    static func covers(_ host: String) -> Bool {
        let h = host.lowercased()
        for san in leafSANs().map({ $0.lowercased() }) {
            if san == h { return true }
            if san.hasPrefix("*."), h.hasSuffix(String(san.dropFirst(1))), !h.dropLast(san.count - 1).contains(".") { return true }
        }
        return false
    }

    // MARK: Root DER (for the profile payload)

    static func rootDER() -> Data? {
        guard let pem = try? String(contentsOf: rootCertURL),
              let b = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let e = pem.range(of: "-----END CERTIFICATE-----") else { return nil }
        let body = pem[b.upperBound..<e.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
        return Data(base64Encoded: body)
    }

    // MARK: Is the root actually trusted on this device?

    /// True only when the root profile is installed AND enabled under
    /// Settings › General › About › Certificate Trust Settings. Evaluates the
    /// root itself against the system trust store, so it reflects exactly what
    /// iOS will do when Safari hits the on-device HTTPS server.
    static func isRootTrusted() -> Bool {
        rehydrateIfNeeded()
        guard let der = rootDER(), let cert = SecCertificateCreateWithData(nil, der as CFData) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else { return false }
        var err: CFError?
        return SecTrustEvaluateWithError(trust, &err)
    }

    /// Same check for the issued leaf + host, i.e. "will https://<host> pass?"
    static func leafTrusted(for host: String) -> Bool {
        rehydrateIfNeeded()
        guard let pem = try? String(contentsOf: leafCertURL) else { return false }
        var certs: [SecCertificate] = []
        var s = pem[...]
        while let b = s.range(of: "-----BEGIN CERTIFICATE-----"), let e = s.range(of: "-----END CERTIFICATE-----") {
            let body = s[b.upperBound..<e.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
            if let d = Data(base64Encoded: body), let c = SecCertificateCreateWithData(nil, d as CFData) { certs.append(c) }
            s = s[e.upperBound...]
        }
        guard !certs.isEmpty else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess, let trust else { return false }
        var err: CFError?
        return SecTrustEvaluateWithError(trust, &err)
    }

    // MARK: .mobileconfig (install the root as a trusted cert)

    static func mobileConfig() -> Data? {
        guard let der = rootDER() else { return nil }
        let payloadUUID = UUID().uuidString
        let profileUUID = UUID().uuidString
        let certB64 = der.base64EncodedString()
        let host = meta?.host ?? "OTA"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>PayloadContent</key>
          <array>
            <dict>
              <key>PayloadType</key><string>com.apple.security.root</string>
              <key>PayloadVersion</key><integer>1</integer>
              <key>PayloadIdentifier</key><string>ms.mrvek.localca.\(payloadUUID)</string>
              <key>PayloadUUID</key><string>\(payloadUUID)</string>
              <key>PayloadDisplayName</key><string>MRvEK Local Root CA</string>
              <key>PayloadContent</key>
              <data>\(certB64)</data>
            </dict>
          </array>
          <key>PayloadType</key><string>Configuration</string>
          <key>PayloadVersion</key><integer>1</integer>
          <key>PayloadIdentifier</key><string>ms.mrvek.localca.profile.\(profileUUID)</string>
          <key>PayloadUUID</key><string>\(profileUUID)</string>
          <key>PayloadDisplayName</key><string>MRvEK OTA Trust (\(host))</string>
          <key>PayloadDescription</key><string>Installs the MRvEK local root so on-device OTA installs are trusted. After installing, enable it in Settings › General › About › Certificate Trust Settings.</string>
          <key>PayloadRemovalDisallowed</key><false/>
        </dict>
        </plist>
        """
        return xml.data(using: .utf8)
    }

    static func writeMobileConfig() -> URL? {
        guard let data = mobileConfig() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MRvEK-OTA-Trust.mobileconfig")
        try? data.write(to: url)
        return url
    }
}


// MARK: - Files the iPhone can see (Files app › On My iPhone › unzip-drop › OTA Certs)

/// Everything the user might want to inspect or move elsewhere lands here —
/// public material only (certs, chains, the trust profile). Private keys never
/// leave the Keychain.
nonisolated enum OTAFiles {
    static var folder: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OTA Certs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// `shareddocuments://` opens the Files app straight at our folder.
    static var filesAppURL: URL? { URL(string: "shareddocuments://" + folder.path) }

    static func list() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Root cert (PEM + DER), leaf chain, trust profile, README.
    @discardableResult
    static func exportLocalCA() -> [URL] {
        var out: [URL] = []
        func put(_ name: String, _ data: Data?) { guard let data else { return }; let u = folder.appendingPathComponent(name); if (try? data.write(to: u, options: .atomic)) != nil { out.append(u) } }
        put("MRvEK-Root-CA.crt", try? Data(contentsOf: LocalCAManager.rootCertURL))
        put("MRvEK-Root-CA.cer", LocalCAManager.rootDER())
        if let host = LocalCAManager.meta?.host { put("leaf-\(host).crt", try? Data(contentsOf: LocalCAManager.leafCertURL)) }
        put("MRvEK-OTA-Trust.mobileconfig", LocalCAManager.mobileConfig())
        put("README.txt", Data("""
        OTA Certs — exported by unzip-drop

        MRvEK-Root-CA.crt / .cer     your on-device root CA (PEM / DER). Public — safe to share.
        leaf-<host>.crt              the leaf + chain the on-device HTTPS server presents.
        MRvEK-OTA-Trust.mobileconfig the trust profile. Open it to install the root, then enable it in
                                     Settings › General › About › Certificate Trust Settings.

        Private keys are NOT here — they live in the Keychain (ThisDeviceOnly) and never touch disk.
        """.utf8))
        return out
    }

    /// The public chain currently used in zefv.dev / own-cert mode (no key).
    @discardableResult
    static func exportPublicChain() -> [URL] {
        guard let crt = ZefvCert.crtURL, let data = try? Data(contentsOf: crt) else { return [] }
        let name = ServerConfig.certMode == "custom" ? "own-cert-fullchain.pem" : "zefv.dev-fullchain.pem"
        let u = folder.appendingPathComponent(name)
        return (try? data.write(to: u, options: .atomic)) != nil ? [u] : []
    }

    static func clear() {
        for u in list() { try? FileManager.default.removeItem(at: u) }
    }
}
