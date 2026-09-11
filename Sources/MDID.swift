//
//  MDID.swift
//  Ported from the full mSign (AVXIDManager + UserRole), trimmed for mSign/unzip:
//  a stable per-install device id (MS-XXXXXX-XX) derived from a basic device
//  fingerprint and persisted in the Keychain (survives update + reinstall).
//
//  Roles are NO LONGER granted by on-device unlock codes — that shipped the code
//  hashes in the binary. Role is decided server-side by StaffGate (VPS allowlist
//  keyed on this MDID). UserRole is kept for the UI gates.
//

import Foundation
import Security
import UIKit
import CommonCrypto
import Darwin

// MARK: - UserRole

nonisolated enum UserRole: String, Codable, CaseIterable, Comparable {
    case member, developer, admin
    var rank: Int { self == .member ? 0 : (self == .developer ? 1 : 2) }
    static func < (l: UserRole, r: UserRole) -> Bool { l.rank < r.rank }
    var title: String { self == .member ? "Member" : (self == .developer ? "Developer" : "Admin") }
    var isElevated: Bool { self >= .developer }   // devs + admins see dev/inspection tools
    var isAdmin: Bool { self == .admin }
}

// MARK: - Device fingerprint → MDID

nonisolated struct DeviceFingerprint {
    let machine: String, model: String, screenW: String, screenH: String, screenScale: String

    static func current() -> DeviceFingerprint {
        let bounds = UIScreen.main.nativeBounds
        return DeviceFingerprint(
            machine: sysctlStr("hw.machine"),
            model: UIDevice.current.model,
            screenW: "\(Int(bounds.width))", screenH: "\(Int(bounds.height))",
            screenScale: String(format: "%.1f", UIScreen.main.scale)
        )
    }
    var stableHash: String { sha256([machine, model, screenW, screenH, screenScale].joined(separator: "|")) }

    private static func sysctlStr(_ name: String) -> String {
        var size = 0; sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
    private func sha256(_ input: String) -> String {
        guard let d = input.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        d.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(d.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - MDID manager (Keychain-backed, restores across reinstall)

nonisolated final class MDIDManager {
    static let shared = MDIDManager()
    private let acct = "party.msign.mdid"
    private init() {}

    /// The device's MDID (MS-XXXXXX-XX). Mints + stores one on first call.
    func mdid() -> String {
        if let c = read(acct), isValid(c) { return c }
        let derived = derive(from: DeviceFingerprint.current().stableHash)
        save(derived, acct); return derived
    }
    func isValid(_ s: String) -> Bool {
        s.range(of: #"^MS-[A-Z0-9]{6}-[A-Z0-9]{2}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    func derive(from hash: String) -> String {
        let charset = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let bytes = Array(hash.utf8)
        func block(_ off: Int, _ len: Int) -> String {
            String(bytes.dropFirst(off).prefix(len).map { charset[Int($0) % charset.count] })
        }
        return "MS-\(block(0,6))-\(block(6,2))"
    }

    // Keychain
    private func save(_ v: String, _ account: String) {
        guard let data = v.data(using: .utf8) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account, kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemDelete(q as CFDictionary); SecItemAdd(q as CFDictionary, nil)
    }
    private func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
