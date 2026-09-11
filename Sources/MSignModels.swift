//
//  MSignModels.swift
//  Layer 2 — mSign data models ported into unzip-drop.
//
//  `LocalAppEntry` and `SignedApp` are mSign's canonical library/signed models.
//  They're bridged onto unzip-drop's existing on-disk types (LibraryItem / SignedEntry)
//  so mSign's row UI and, later, SigningSheet can consume real unzip-drop data without
//  pulling in mSign's server/account/downgrade stack. Trimmed to the fields the ported
//  UI uses; server-only fields (job IDs, manifest URLs) are kept optional for layer 4.
//

import Foundation

// MARK: - LocalAppEntry (library) — verbatim shape from mSign

struct LocalAppEntry: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let bundle: String
    let subtitle: String
    let version: String
    let sizeMB: String
    let iconURL: URL?
    let localFileURL: URL
    let downloadURL: URL?

    init(
        id: String = UUID().uuidString,
        name: String,
        bundle: String,
        subtitle: String = "",
        version: String = "—",
        sizeMB: String = "—",
        iconURL: URL? = nil,
        localFileURL: URL,
        downloadURL: URL? = nil
    ) {
        self.id = id; self.name = name; self.bundle = bundle; self.subtitle = subtitle
        self.version = version; self.sizeMB = sizeMB; self.iconURL = iconURL
        self.localFileURL = localFileURL; self.downloadURL = downloadURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bundle, subtitle, version, sizeMB, iconURL, localFileURL, downloadURL
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        bundle = try c.decode(String.self, forKey: .bundle)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "—"
        sizeMB = try c.decodeIfPresent(String.self, forKey: .sizeMB) ?? "—"
        iconURL = try c.decodeIfPresent(URL.self, forKey: .iconURL)
        localFileURL = try c.decode(URL.self, forKey: .localFileURL)
        downloadURL = try c.decodeIfPresent(URL.self, forKey: .downloadURL)
    }
}

// MARK: - SignedApp (signed) — trimmed from mSign (local-signing fields kept)

struct SignedApp: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bundleID: String
    let version: String
    let iconURL: String?
    let signedDate: Date
    let localIPAPath: String?
    let certName: String
    let isTrollsign: Bool

    // Server fields — reserved for layer 4 (upload / OTA share). Optional so
    // local-signed entries decode cleanly.
    let signedIPAURL: String?
    let manifestURL: String?
    let installURL: String?

    var localIPAURL: URL? {
        guard let p = localIPAPath, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p)
    }
    var displayName: String { name }
    var iconFileURL: URL? {
        guard let s = iconURL, !s.isEmpty else { return nil }
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        return URL(string: s)
    }
    var otaInstallURL: String? {
        if let u = installURL, !u.isEmpty { return u }
        guard let m = manifestURL, !m.isEmpty else { return nil }
        let e = m.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? m
        return "itms-services://?action=download-manifest&url=\(e)"
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        bundleID: String,
        version: String = "1.0.0",
        iconURL: String? = nil,
        signedDate: Date = Date(),
        localIPAPath: String? = nil,
        certName: String = "",
        isTrollsign: Bool = false,
        signedIPAURL: String? = nil,
        manifestURL: String? = nil,
        installURL: String? = nil
    ) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.version = version
        self.iconURL = iconURL; self.signedDate = signedDate; self.localIPAPath = localIPAPath
        self.certName = certName; self.isTrollsign = isTrollsign
        self.signedIPAURL = signedIPAURL; self.manifestURL = manifestURL; self.installURL = installURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bundleID, version, iconURL, signedDate
        case localIPAPath, certName, isTrollsign, signedIPAURL, manifestURL, installURL
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        iconURL = try c.decodeIfPresent(String.self, forKey: .iconURL)
        signedDate = try c.decodeIfPresent(Date.self, forKey: .signedDate) ?? Date()
        localIPAPath = try c.decodeIfPresent(String.self, forKey: .localIPAPath)
        certName = try c.decodeIfPresent(String.self, forKey: .certName) ?? ""
        isTrollsign = try c.decodeIfPresent(Bool.self, forKey: .isTrollsign) ?? false
        signedIPAURL = try c.decodeIfPresent(String.self, forKey: .signedIPAURL)
        manifestURL = try c.decodeIfPresent(String.self, forKey: .manifestURL)
        installURL = try c.decodeIfPresent(String.self, forKey: .installURL)
    }
}

// MARK: - Bridges from unzip-drop's on-disk types

extension LibraryItem {
    /// mSign's library model view of an inbox IPA.
    var asLocalAppEntry: LocalAppEntry {
        LocalAppEntry(
            id: id, name: name, bundle: bundle, subtitle: "Downloaded",
            version: version,
            sizeMB: sizeBytes > 0 ? String(format: "%.2f", Double(sizeBytes) / 1_048_576) : "—",
            iconURL: nil, localFileURL: url
        )
    }
}

extension SignedEntry {
    /// mSign's signed model view of a locally-signed IPA.
    var asSignedApp: SignedApp {
        SignedApp(
            id: id, name: name, bundleID: bundleID, version: version,
            iconURL: iconURL?.path, signedDate: signedAt,
            localIPAPath: ipaURL.path, certName: certName, isTrollsign: false
        )
    }
}
