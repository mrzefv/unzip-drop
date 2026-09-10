//
//  Keychain.swift
//

import Foundation
import Security

nonisolated enum Keychain {
    private static let service = "unzip-drop"

    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
        if value.isEmpty { return true }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // MARK: - Non-exportable secrets (private keys)
    //
    // Used for the local CA's root/leaf private keys: ThisDeviceOnly means the
    // item is excluded from iTunes/Finder and iCloud backups and can never
    // migrate to another device — if the CA key ever leaves this Keychain, it's
    // because the device itself was restored, not because a backup carried it.

    @discardableResult
    static func setSecret(_ key: String, _ value: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
        if value.isEmpty { return true }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func getSecret(_ key: String) -> String? { get(key) }   // read path is accessibility-agnostic

    static func deleteSecret(_ key: String) { _ = set(key, "") }
}
