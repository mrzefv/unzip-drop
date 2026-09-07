//
//  Keychain.swift
//

import Foundation
import Security

enum Keychain {
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

    // MARK: - Persistent binary storage (survives app deletion)
    //
    // Items written with these methods have kSecAttrSynchronizable = true so
    // they sync into the user's iCloud Keychain. This is the only way a
    // Keychain item can outlive app deletion on iOS 10.3+ without an app
    // group entitlement — Apple wipes local-only Keychain items when an
    // app is uninstalled.
    //
    // Used for the leaf/root CA + user-imported .p12 / .mobileprovision so
    // deleting Unzip Drop doesn't force the user to re-import certs when
    // they reinstall.

    @discardableResult
    static func setPersistent(_ key: String, _ data: Data) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
        SecItemDelete(q as CFDictionary)
        if data.isEmpty { return true }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func getPersistent(_ key: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return d
    }

    /// String convenience over the persistent (iCloud-synced) storage.
    @discardableResult
    static func setPersistentString(_ key: String, _ value: String) -> Bool {
        setPersistent(key, Data(value.utf8))
    }
    static func getPersistentString(_ key: String) -> String? {
        guard let d = getPersistent(key) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Enumerate all persistent keys under our service — used at startup so
    /// CertificateStore can rehydrate the on-disk .p12 / .mobileprovision
    /// files after a fresh reinstall.
    static func allPersistentKeys() -> [String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return [] }
        if let arr = out as? [[String: Any]] {
            return arr.compactMap { $0[kSecAttrAccount as String] as? String }
        }
        return []
    }
}
