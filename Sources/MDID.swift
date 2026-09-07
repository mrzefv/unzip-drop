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

import Foundation
import Security
import UIKit

enum MDID {
    private static let service     = "zefv-mdid"
    private static let account     = "primary"
    private static let deviceHashSvc = "zefv-mdid-devicehash"

    /// The device's MDID, generating and persisting one on first call.
    /// Format: `MS-XXXX-XXXX-XX` using Crockford base32 alphabet
    /// (no I/L/O/U to avoid ambiguity with 1/0/etc).
    static var current: String {
        if let existing = load(), Self.isValidFormat(existing) { return existing }
        let fresh = generate()
        _ = save(fresh)
        return fresh
    }

    /// Regenerate and persist a new MDID.
    /// Wipes the current identifier — the server will treat future
    /// requests from this device as a new/unlinked device until a
    /// user authenticates from it.
    @discardableResult
    static func reset() -> String {
        let fresh = generate()
        _ = save(fresh)
        return fresh
    }

    /// Optional stable device-side hash of `identifierForVendor`, used
    /// as an additional signal by the server (not identity). Deterministic
    /// per install: reinstalling the app changes it. Storing here so we
    /// only compute it once.
    static var deviceHash: String {
        if let cached = readCache(service: deviceHashSvc) { return cached }
        let source = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let bytes  = Array(source.utf8)
        let hash   = sha256(bytes)
        let hex    = hash.map { String(format: "%02x", $0) }.joined()
        _ = writeCache(service: deviceHashSvc, value: hex)
        return hex
    }

    /// Best-effort device name for display in "linked devices" lists
    /// on other phones. Truncated server-side.
    static var deviceName: String { UIDevice.current.name }

    // MARK: - Formatting

    /// Matches `MS-XXXX-XXXX-XX` where X is Crockford base32 (uppercase).
    static func isValidFormat(_ s: String) -> Bool {
        s.range(of: #"^MS-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$"#,
                options: .regularExpression) != nil
    }

    // MARK: - Private

    private static func generate() -> String {
        // Crockford base32 minus I, L, O, U → 32 chars mapped to 5 bits each.
        let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        func chunk(_ n: Int) -> String {
            var s = ""
            s.reserveCapacity(n)
            for _ in 0..<n {
                // Uniform pick with random_uniform bounded to 32.
                var byte: UInt8 = 0
                _ = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
                s.append(alphabet[Int(byte) % alphabet.count])
            }
            return s
        }
        return "MS-\(chunk(4))-\(chunk(4))-\(chunk(2))"
    }

    // ─── iCloud-synced Keychain (the MDID must survive reinstall) ───

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
        // Delete any existing entry (synced OR local) then insert the
        // canonical synced version. iCloud Keychain treats synced/local
        // as separate namespaces — we always store synced.
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

    // ─── Simple non-synced cache for the device hash ───

    private static func readCache(service: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    private static func writeCache(service: String, value: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String]  = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - SHA-256 (avoids importing CryptoKit — this file stays self-contained)

    private static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        // Minimal SHA-256 for the device-hash cache. Fine for anti-abuse
        // fingerprint use — this is not a cryptographic primitive.
        var msg = bytes
        let bitLen = UInt64(bytes.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (8 * i)) & 0xFF)) }

        var h: [UInt32] = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
                            0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
        let k: [UInt32] = [
            0x428A2F98,0x71374491,0xB5C0FBCF,0xE9B5DBA5,0x3956C25B,0x59F111F1,0x923F82A4,0xAB1C5ED5,
            0xD807AA98,0x12835B01,0x243185BE,0x550C7DC3,0x72BE5D74,0x80DEB1FE,0x9BDC06A7,0xC19BF174,
            0xE49B69C1,0xEFBE4786,0x0FC19DC6,0x240CA1CC,0x2DE92C6F,0x4A7484AA,0x5CB0A9DC,0x76F988DA,
            0x983E5152,0xA831C66D,0xB00327C8,0xBF597FC7,0xC6E00BF3,0xD5A79147,0x06CA6351,0x14292967,
            0x27B70A85,0x2E1B2138,0x4D2C6DFC,0x53380D13,0x650A7354,0x766A0ABB,0x81C2C92E,0x92722C85,
            0xA2BFE8A1,0xA81A664B,0xC24B8B70,0xC76C51A3,0xD192E819,0xD6990624,0xF40E3585,0x106AA070,
            0x19A4C116,0x1E376C08,0x2748774C,0x34B0BCB5,0x391C0CB3,0x4ED8AA4A,0x5B9CCA4F,0x682E6FF3,
            0x748F82EE,0x78A5636F,0x84C87814,0x8CC70208,0x90BEFFFA,0xA4506CEB,0xBEF9A3F7,0xC67178F2
        ]

        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = chunkStart + i * 4
                w[i] = (UInt32(msg[o]) << 24) | (UInt32(msg[o+1]) << 16) | (UInt32(msg[o+2]) << 8) | UInt32(msg[o+3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var (a,b,c,d,e,f,g,hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let mj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ mj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in h {
            out.append(UInt8((word >> 24) & 0xFF))
            out.append(UInt8((word >> 16) & 0xFF))
            out.append(UInt8((word >> 8)  & 0xFF))
            out.append(UInt8( word        & 0xFF))
        }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
