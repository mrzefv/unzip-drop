//
//  LocalCAManager.swift
//  Hand-rolled OTA TLS. Generates a root CA once (LocalCA.mm / OpenSSL), keeps
//  it in the Keychain-backed Documents dir, issues a leaf for the chosen host,
//  and packages the root as a .mobileconfig the user installs + trusts once.
//  After that, every OTA install uses our own cert with zero external CA.
//

import Foundation

nonisolated enum LocalCAManager {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var rootCertURL: URL { docs.appendingPathComponent("localca-root.crt") }   // PEM
    static var rootKeyURL:  URL { docs.appendingPathComponent("localca-root.key") }   // PEM
    static var leafCertURL: URL { docs.appendingPathComponent("localca-leaf.crt") }   // PEM fullchain
    static var leafKeyURL:  URL { docs.appendingPathComponent("localca-leaf.key") }   // PEM
    static var metaURL:     URL { docs.appendingPathComponent("localca.json") }

    struct Meta: Codable, Sendable { var host: String; var rootCreated: Date; var leafIssued: Date; var validYears: Int }

    static var meta: Meta? {
        guard let d = try? Data(contentsOf: metaURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Meta.self, from: d)
    }

    static var hasRoot: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: rootCertURL.path) && fm.fileExists(atPath: rootKeyURL.path)
    }
    static var hasLeaf: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: leafCertURL.path) && fm.fileExists(atPath: leafKeyURL.path)
    }

    enum CAError: LocalizedError {
        case generateFailed, issueFailed, noRoot
        var errorDescription: String? {
            switch self {
            case .generateFailed: return "Couldn't generate the root CA."
            case .issueFailed:    return "Couldn't issue the leaf certificate."
            case .noRoot:         return "No local root CA yet — create one first."
            }
        }
    }

    /// Create the root once (idempotent unless force).
    @discardableResult
    static func ensureRoot(commonName: String = "MRvEK Local Root CA", years: Int = 10, force: Bool = false) throws -> Bool {
        if hasRoot && !force { return false }
        guard let pair = LocalCA.generateRootCA(withCommonName: commonName, validYears: Int32(years)),
              let cert = pair["cert"], let key = pair["key"] else { throw CAError.generateFailed }
        try cert.data(using: .utf8)!.write(to: rootCertURL, options: .atomic)
        try key.data(using: .utf8)!.write(to: rootKeyURL, options: [.atomic, .completeFileProtection])
        return true
    }

    /// Issue (or re-issue) a leaf for `host`, writing the fullchain + key.
    static func issueLeaf(host: String, years: Int = 5) throws {
        try ensureRoot()
        guard let rootCert = try? String(contentsOf: rootCertURL),
              let rootKey  = try? String(contentsOf: rootKeyURL) else { throw CAError.noRoot }
        guard let pair = LocalCA.issueLeaf(forHost: host, rootCertPEM: rootCert, rootKeyPEM: rootKey, validYears: Int32(years)),
              let cert = pair["cert"], let key = pair["key"] else { throw CAError.issueFailed }
        try cert.data(using: .utf8)!.write(to: leafCertURL, options: .atomic)
        try key.data(using: .utf8)!.write(to: leafKeyURL, options: [.atomic, .completeFileProtection])
        let m = Meta(host: host, rootCreated: rootCreatedDate(), leafIssued: Date(), validYears: years)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(m).write(to: metaURL)
    }

    static func reset() {
        for u in [rootCertURL, rootKeyURL, leafCertURL, leafKeyURL, metaURL] { try? FileManager.default.removeItem(at: u) }
    }

    private static func rootCreatedDate() -> Date {
        (try? FileManager.default.attributesOfItem(atPath: rootCertURL.path)[.creationDate] as? Date) ?? Date()
    }

    // MARK: Root DER (for the profile payload)

    /// Convert the root PEM to DER bytes for embedding in the .mobileconfig.
    static func rootDER() -> Data? {
        guard let pem = try? String(contentsOf: rootCertURL),
              let b = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let e = pem.range(of: "-----END CERTIFICATE-----") else { return nil }
        let body = pem[b.upperBound..<e.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
        return Data(base64Encoded: body)
    }

    // MARK: .mobileconfig (install the root as a trusted cert)

    /// Build an unsigned configuration profile that installs the root CA.
    /// The user still enables full trust in Settings afterwards.
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

    /// Write the profile to a temp file for sharing/opening.
    static func writeMobileConfig() -> URL? {
        guard let data = mobileConfig() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MRvEK-OTA-Trust.mobileconfig")
        try? data.write(to: url)
        return url
    }
}
