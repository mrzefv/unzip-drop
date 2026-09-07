//
//  CertificateStore.swift
//  Signing certificates (.p12 + .mobileprovision) and the signed-IPA history.
//  Files live under Documents; the .p12 password lives in the Keychain.
//

import Foundation
import Security

// MARK: - Models

struct Certificate: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var p12RelPath: String
    var provisionRelPath: String
    var addedAt: Date

    var p12URL: URL { AppPaths.documents.appendingPathComponent(p12RelPath) }
    var provisionURL: URL { AppPaths.documents.appendingPathComponent(provisionRelPath) }
}

/// In-memory cert material handed to the signer.
nonisolated struct CertMaterial: Sendable {
    let p12: Data
    let provision: Data
    let password: String
    let name: String
}

/// A signed .ipa produced on-device, ready to install over the air.
struct SignedEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var bundleID: String
    var version: String
    var ipaRelPath: String
    var iconRelPath: String?
    var signedAt: Date
    var certName: String

    var ipaURL: URL { AppPaths.documents.appendingPathComponent(ipaRelPath) }
    var iconURL: URL? { iconRelPath.map { AppPaths.documents.appendingPathComponent($0) } }
}

nonisolated enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static func dir(_ name: String) -> URL {
        let u = documents.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// Parsed provisioning-profile facts. `expires` is the canonical field;
/// `expirationDate` and the status helpers exist for the analytics / widget / search code.
nonisolated struct ProfileInfo: Sendable {
    var name: String? = nil
    var team: String? = nil
    var expires: Date? = nil
    var udids: [String] = []

    var expirationDate: Date? { expires }
    var daysUntilExpiry: Int? {
        guard let e = expires else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: e).day
    }
    var isExpired: Bool { (expires ?? .distantFuture) < Date() }
    var isExpiringSoon: Bool {
        guard let d = daysUntilExpiry else { return false }
        return d >= 0 && d <= 14
    }
}

// MARK: - Certificate store

@MainActor
final class CertificateStore: ObservableObject {
    static let shared = CertificateStore()

    @Published private(set) var certificates: [Certificate] = []
    @Published var activeID: String? {
        didSet { UserDefaults.standard.set(activeID, forKey: Self.activeKey) }
    }

    private static let activeKey = "uzd_active_cert"
    private let indexURL = AppPaths.dir("certs").appendingPathComponent("index.json")

    private init() {
        load()
        activeID = UserDefaults.standard.string(forKey: Self.activeKey)
        if activeID == nil { activeID = certificates.first?.id }
    }

    enum CertError: LocalizedError {
        case badPassword, importFailed, noActive
        var errorDescription: String? {
            switch self {
            case .badPassword:  return "Wrong .p12 password (or the file isn't a valid PKCS#12)."
            case .importFailed: return "Could not read the certificate files."
            case .noActive:     return "No active certificate. Import one in Settings › Certificates."
            }
        }
    }

    @discardableResult
    func importPair(name: String, p12: Data, password: String, provision: Data, makeActive: Bool = true) throws -> Certificate {
        guard Self.p12IsValid(p12, password: password) else { throw CertError.badPassword }
        let id = UUID().uuidString
        let p12Rel  = "certs/\(id).p12"
        let provRel = "certs/\(id).mobileprovision"
        do {
            try p12.write(to: AppPaths.documents.appendingPathComponent(p12Rel))
            try provision.write(to: AppPaths.documents.appendingPathComponent(provRel))
        } catch { throw CertError.importFailed }
        Keychain.set("cert-" + id, password)
        let cert = Certificate(id: id, name: name.isEmpty ? "Certificate" : name,
                               p12RelPath: p12Rel, provisionRelPath: provRel, addedAt: Date())
        certificates.append(cert)
        save()
        if makeActive || activeID == nil { activeID = id }
        return cert
    }

    func delete(_ cert: Certificate) {
        try? FileManager.default.removeItem(at: cert.p12URL)
        try? FileManager.default.removeItem(at: cert.provisionURL)
        Keychain.set("cert-" + cert.id, "")
        certificates.removeAll { $0.id == cert.id }
        if activeID == cert.id { activeID = certificates.first?.id }
        save()
    }

    var active: Certificate? { certificates.first { $0.id == activeID } }

    func activeMaterial() throws -> CertMaterial {
        guard let c = active else { throw CertError.noActive }
        guard let p12 = try? Data(contentsOf: c.p12URL),
              let mp  = try? Data(contentsOf: c.provisionURL) else { throw CertError.importFailed }
        return CertMaterial(p12: p12, provision: mp, password: Keychain.get("cert-" + c.id) ?? "", name: c.name)
    }

    /// Read name / team / expiry from the provisioning profile (best effort).
    /// The .mobileprovision is a CMS envelope around a plist; the plist is readable in the clear.
    nonisolated static func profileInfo(_ provision: Data) -> ProfileInfo {
        guard let s = String(data: provision, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"), let b = s.range(of: "</plist>") else { return ProfileInfo() }
        let xml = String(s[a.lowerBound..<b.upperBound])
        guard let d = xml.data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return ProfileInfo() }
        let team = (plist["TeamName"] as? String) ?? (plist["TeamIdentifier"] as? [String])?.first
        return ProfileInfo(name: plist["Name"] as? String, team: team, expires: plist["ExpirationDate"] as? Date,
                           udids: plist["ProvisionedDevices"] as? [String] ?? [])
    }

    // MARK: Device ↔ profile check

    /// The device UDID we know about: a saved value, else a cert name that looks like one
    /// (registration-service certs are named after the UDID, e.g. 00008110-000209003C60E01E).
    nonisolated static func knownUDID(certName: String? = nil) -> String? {
        if let saved = UserDefaults.standard.string(forKey: "uzd_device_udid"), !saved.isEmpty { return saved }
        if let n = certName, n.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$"#, options: .regularExpression) != nil { return n.uppercased() }
        return nil
    }
    nonisolated static func setKnownUDID(_ u: String) {
        UserDefaults.standard.set(u.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), forKey: "uzd_device_udid")
    }

    /// nil = unknown UDID; true/false = definitive.
    nonisolated static func profileIncludesDevice(_ info: ProfileInfo, udid: String?) -> Bool? {
        guard let u = udid?.uppercased(), !u.isEmpty else { return nil }
        return info.udids.contains { $0.uppercased() == u }
    }

    nonisolated static func p12IsValid(_ data: Data, password: String) -> Bool {
        let opts = [kSecImportExportPassphrase as String: password] as CFDictionary
        var items: CFArray?
        return SecPKCS12Import(data as CFData, opts, &items) == errSecSuccess
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Certificate].self, from: data) else { return }
        certificates = list
    }
    private func save() { try? JSONEncoder().encode(certificates).write(to: indexURL) }
}

// MARK: - Signed history

@MainActor
final class SignedStore: ObservableObject {
    static let shared = SignedStore()
    @Published private(set) var entries: [SignedEntry] = []
    private let indexURL = AppPaths.dir("signed").appendingPathComponent("index.json")

    private init() { load() }

    /// Move a freshly signed temp IPA into Documents/signed and record it.
    func add(outcome: SignOutcome, icon: Data?, certName: String) throws -> SignedEntry {
        let id = UUID().uuidString
        let ipaRel = "signed/\(id).ipa"
        let dest = AppPaths.documents.appendingPathComponent(ipaRel)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: outcome.ipaURL, to: dest)
        var iconRel: String?
        if let icon {
            iconRel = "signed/\(id).png"
            try? icon.write(to: AppPaths.documents.appendingPathComponent(iconRel!))
        }
        let e = SignedEntry(id: id, name: outcome.name, bundleID: outcome.bundleID, version: outcome.version,
                            ipaRelPath: ipaRel, iconRelPath: iconRel, signedAt: Date(), certName: certName)
        entries.insert(e, at: 0)
        save()
        return e
    }

    func delete(_ e: SignedEntry) {
        try? FileManager.default.removeItem(at: e.ipaURL)
        if let u = e.iconURL { try? FileManager.default.removeItem(at: u) }
        entries.removeAll { $0.id == e.id }
        save()
    }

    private func load() {
        guard let d = try? Data(contentsOf: indexURL),
              let l = try? JSONDecoder().decode([SignedEntry].self, from: d) else { return }
        entries = l.filter { FileManager.default.fileExists(atPath: $0.ipaURL.path) }
    }
    private func save() { try? JSONEncoder().encode(entries).write(to: indexURL) }
}

// MARK: - Hand-off queue (Build tab / Files → Sign tab)

@MainActor
final class SignQueue: ObservableObject {
    static let shared = SignQueue()
    /// An unsigned IPA waiting in the Sign tab.
    @Published var pending: URL?
    /// Set to ask the shell to switch tabs (RootView observes).
    @Published var requestedTab: Int?
    private init() {}

    func enqueue(_ url: URL, switchToSign: Bool = true) {
        pending = url
        if switchToSign { requestedTab = 0 }
    }
}
