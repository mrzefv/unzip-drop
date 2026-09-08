//
//  MDID.swift
//  Persistent device identifier for zefv.dev — format MS-XXXX-XXXX-XX.
//
//  Generated once on first launch. Stored in the iCloud Keychain
//  (kSecAttrSynchronizable) so it survives app deletion, device restore,
//  and even migration to a new device — as long as the same Apple ID /
//  iCloud Keychain is signed in. The zefv.dev server uses it as an
//  anti-abuse device fingerprint that a user can bind to their account.
//
//  Sent on /register and /login as the `X-MDID` header, along with
//  `X-Device-Name` for the user's "linked devices" list.
//

import Foundation
import Security
import UIKit

enum MDID {
    private static let service = "zefv-mdid"
    private static let account = "primary"

    /// The device's MDID, generating and persisting one on first call.
    /// Format: `MS-XXXX-XXXX-XX` using the Crockford base32 alphabet
    /// (no I/L/O/U so it can be read aloud or typed unambiguously).
    static var current: String {
        if let existing = load(), isValidFormat(existing) { return existing }
        let fresh = generate()
        _ = save(fresh)
        return fresh
    }

    /// Regenerate and persist a new MDID. Wipes the current identifier —
    /// the server will treat this device as new/unlinked until a user
    /// authenticates from it again.
    @discardableResult
    static func reset() -> String {
        let fresh = generate()
        _ = save(fresh)
        return fresh
    }

    /// Best-effort device name for the server's "linked devices" list.
    /// Truncated to 40 chars server-side.
    static var deviceName: String { UIDevice.current.name }

    /// Matches `MS-XXXX-XXXX-XX` where X is Crockford base32 (uppercase).
    static func isValidFormat(_ s: String) -> Bool {
        s.range(of: #"^MS-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$"#,
                options: .regularExpression) != nil
    }

    // MARK: - Private

    private static func generate() -> String {
        // Crockford base32 minus I, L, O, U → 32 symbols.
        let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        func chunk(_ n: Int) -> String {
            var s = ""
            s.reserveCapacity(n)
            for _ in 0..<n {
                var byte: UInt8 = 0
                _ = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
                s.append(alphabet[Int(byte) % alphabet.count])
            }
            return s
        }
        return "MS-\(chunk(4))-\(chunk(4))-\(chunk(2))"
    }

    // ─── iCloud-synced Keychain (must survive app reinstall + device restore) ───

    private static func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    private static func save(_ value: String) -> Bool {
        // iCloud Keychain treats synced and local as separate namespaces.
        // Clear both so a stale local copy can't shadow the synced one,
        // then write the canonical synced entry.
        for sync in [kCFBooleanTrue!, kCFBooleanFalse!] {
            let q: [String: Any] = [
                kSecClass as String:              kSecClassGenericPassword,
                kSecAttrService as String:        service,
                kSecAttrAccount as String:        account,
                kSecAttrSynchronizable as String: sync,
            ]
            SecItemDelete(q as CFDictionary)
        }
        let add: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecAttrAccessible as String:     kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String:          Data(value.utf8),
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
