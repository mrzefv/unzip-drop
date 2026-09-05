//
//  SecurityEnhanced.swift
//  Enhanced security features for certificates.
//

import Foundation
import LocalAuthentication
import CryptoKit

@MainActor
final class SecurityManager: ObservableObject {
    static let shared = SecurityManager()
    
    @Published var isBiometricAvailable = false
    @Published var isAuthorized = false
    @Published private(set) var accessLog: [AccessLogEntry] = []
    
    struct AccessLogEntry: Codable, Identifiable {
        let id: String
        let certificateID: String
        let action: String // "view", "export", "delete", "use"
        let timestamp: Date
        let success: Bool
        let details: String?
    }
    
    private let context = LAContext()
    private let accessLogURL = AppPaths.dir("security").appendingPathComponent("access.log")
    
    private init() {
        checkBiometricAvailability()
        loadAccessLog()
    }
    
    // MARK: - Biometric Authentication
    
    func authenticateWithBiometric(reason: String) async -> Bool {
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        
        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return authenticated
        } catch {
            print("Biometric authentication failed: \(error.localizedDescription)")
            return false
        }
    }
    
    func checkBiometricAvailability() {
        var error: NSError?
        isBiometricAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
    
    // MARK: - Certificate Encryption
    
    func encryptCertificatePassword(_ password: String, for certID: String) throws -> String {
        let data = password.data(using: .utf8)!
        let key = try retrieveEncryptionKey(for: certID)
        let box = try AES.GCM.seal(data, using: key)
        return box.combined?.base64EncodedString() ?? password
    }
    
    func decryptCertificatePassword(_ encryptedPassword: String, for certID: String) throws -> String {
        guard let data = Data(base64Encoded: encryptedPassword) else { return encryptedPassword }
        let key = try retrieveEncryptionKey(for: certID)
        let box = try AES.GCM.SealedBox(combined: data)
        let decrypted = try AES.GCM.open(box, using: key)
        return String(data: decrypted, encoding: .utf8) ?? encryptedPassword
    }
    
    // MARK: - Access Logging
    
    func logAccess(_ action: String, to certID: String, success: Bool, details: String? = nil) {
        let entry = AccessLogEntry(
            id: UUID().uuidString,
            certificateID: certID,
            action: action,
            timestamp: Date(),
            success: success,
            details: details
        )
        
        accessLog.insert(entry, at: 0)
        saveAccessLog()
    }
    
    func getAccessLog(for certID: String) -> [AccessLogEntry] {
        accessLog.filter { $0.certificateID == certID }.sorted { $0.timestamp > $1.timestamp }
    }
    
    func exportAccessLog(for certID: String) -> String {
        var csv = "Timestamp,Action,Success,Details\n"
        for entry in getAccessLog(for: certID) {
            let timestamp = entry.timestamp.formatted(date: .abbreviated, time: .standard)
            let success = entry.success ? "Yes" : "No"
            let details = entry.details ?? ""
            csv += "\(timestamp),\(entry.action),\(success),\(details)\n"
        }
        return csv
    }
    
    func clearOldAccessLogs(olderThan days: Int) {
        let threshold = Date().addingTimeInterval(-Double(days * 24 * 3600))
        accessLog.removeAll { $0.timestamp < threshold }
        saveAccessLog()
    }
    
    // MARK: - Private Helpers
    
    private func retrieveEncryptionKey(for certID: String) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "enc-key-\(certID)",
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess, let keyData = result as? Data {
            return SymmetricKey(data: keyData)
        } else {
            let newKey = SymmetricKey(size: .bits256)
            let keyData = newKey.withUnsafeBytes { Data($0) }
            
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: "enc-key-\(certID)",
                kSecValueData as String: keyData
            ]
            
            SecItemAdd(addQuery as CFDictionary, nil)
            return newKey
        }
    }
    
    private func loadAccessLog() {
        guard let data = try? Data(contentsOf: accessLogURL),
              let log = try? JSONDecoder().decode([AccessLogEntry].self, from: data) else {
            accessLog = []
            return
        }
        accessLog = log.sorted { $0.timestamp > $1.timestamp }
    }
    
    private func saveAccessLog() {
        if let encoded = try? JSONEncoder().encode(accessLog) {
            try? encoded.write(to: accessLogURL)
        }
    }
}
