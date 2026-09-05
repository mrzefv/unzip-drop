//
//  CertificateBackup.swift
//  Encrypted backup and restore functionality.
//

import Foundation
import CryptoKit
import Compression

struct BackupEntry: Codable {
    let id: String
    let name: String
    let p12Data: Data
    let provisionData: Data
    let password: String
    let timestamp: Date
    let bundleVersion: String = "1.0"
}

struct BackupFile: Codable {
    let version: String = "1.0"
    let createdAt: Date
    let deviceName: String
    let entries: [BackupEntry]
    let checksumHash: String
}

@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()
    @Published var backups: [BackupMetadata] = []
    @Published var lastBackupDate: Date? = nil
    
    private let backupDir = AppPaths.dir("backups")
    
    struct BackupMetadata: Identifiable, Codable {
        let id: String
        let deviceName: String
        let createdAt: Date
        let certificateCount: Int
        let fileSize: Int
        
        var sizeFormatted: String {
            let bytes = Double(fileSize)
            if bytes < 1024 {
                return String(format: "%.0f B", bytes)
            } else if bytes < 1024 * 1024 {
                return String(format: "%.2f KB", bytes / 1024)
            } else {
                return String(format: "%.2f MB", bytes / (1024 * 1024))
            }
        }
    }
    
    private init() {
        loadBackups()
    }
    
    /// Create encrypted backup of all certificates
    func createBackup(certificates: [Certificate]) throws -> BackupMetadata {
        var entries: [BackupEntry] = []
        
        for cert in certificates {
            guard let p12Data = try? Data(contentsOf: cert.p12URL),
                  let provData = try? Data(contentsOf: cert.provisionURL),
                  let password = Keychain.get("cert-" + cert.id) else {
                continue
            }
            
            entries.append(BackupEntry(
                id: cert.id,
                name: cert.name,
                p12Data: p12Data,
                provisionData: provData,
                password: password,
                timestamp: cert.addedAt
            ))
        }
        
        let backup = BackupFile(
            createdAt: Date(),
            deviceName: UIDevice.current.name,
            entries: entries,
            checksumHash: entries.map { $0.id }.joined().sha256Hash()
        )
        
        // Encode and compress
        let encoded = try JSONEncoder().encode(backup)
        let compressed = try compressData(encoded)
        
        // Encrypt with device key
        let encrypted = try encryptData(compressed)
        
        // Save to file
        let backupID = UUID().uuidString
        let fileName = "backup-\(backupID).uzd"
        let fileURL = backupDir.appendingPathComponent(fileName)
        try encrypted.write(to: fileURL)
        
        let metadata = BackupMetadata(
            id: backupID,
            deviceName: backup.deviceName,
            createdAt: backup.createdAt,
            certificateCount: entries.count,
            fileSize: encrypted.count
        )
        
        backups.append(metadata)
        lastBackupDate = Date()
        saveMetadata()
        
        return metadata
    }
    
    /// Restore certificates from backup
    func restoreBackup(metadata: BackupMetadata, store: CertificateStore) throws {
        let fileName = "backup-\(metadata.id).uzd"
        let fileURL = backupDir.appendingPathComponent(fileName)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BackupError.backupNotFound
        }
        
        let encrypted = try Data(contentsOf: fileURL)
        let compressed = try decryptData(encrypted)
        let decompressed = try decompressData(compressed)
        let backup = try JSONDecoder().decode(BackupFile.self, from: decompressed)
        
        // Verify checksum
        let calculatedHash = backup.entries.map { $0.id }.joined().sha256Hash()
        guard calculatedHash == backup.checksumHash else {
            throw BackupError.corruptedBackup
        }
        
        // Restore entries
        var restoredCount = 0
        for entry in backup.entries {
            do {
                _ = try store.importPair(
                    name: entry.name,
                    p12: entry.p12Data,
                    password: entry.password,
                    provision: entry.provisionData,
                    makeActive: restoredCount == 0
                )
                restoredCount += 1
            } catch {
                print("Failed to restore certificate \(entry.name): \(error)")
            }
        }
    }
    
    /// Export backup to Files app
    func exportBackup(metadata: BackupMetadata, to destination: URL) throws {
        let fileName = "backup-\(metadata.id).uzd"
        let fileURL = backupDir.appendingPathComponent(fileName)
        let timestamp = metadata.createdAt.formatted(date: .abbreviated, time: .omitted).replacingOccurrences(of: "/", with: "-")
        let exportName = "unzip-drop-backup-\(timestamp).uzd"
        let exportURL = destination.appendingPathComponent(exportName)
        
        try FileManager.default.copyItem(at: fileURL, to: exportURL)
    }
    
    /// Delete backup
    func deleteBackup(metadata: BackupMetadata) throws {
        let fileName = "backup-\(metadata.id).uzd"
        let fileURL = backupDir.appendingPathComponent(fileName)
        try FileManager.default.removeItem(at: fileURL)
        backups.removeAll { $0.id == metadata.id }
        saveMetadata()
    }
    
    // MARK: - Private Helpers
    
    private func encryptData(_ data: Data) throws -> Data {
        let key = SymmetricKey(size: .bits256)
        let box = try AES.GCM.seal(data, using: key)
        return box.combined ?? data
    }
    
    private func decryptData(_ data: Data) throws -> Data {
        // In production, use Keychain to retrieve stored key
        let key = SymmetricKey(size: .bits256)
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }
    
    private func compressData(_ data: Data) throws -> Data {
        var compressed = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        defer { buffer.deallocate() }
        
        let compressedSize = compression_encode_buffer(
            buffer, data.count,
            (data as NSData).bytes.assumingMemoryBound(to: UInt8.self),
            data.count,
            nil,
            COMPRESSION_ZLIB
        )
        
        compressed = Data(bytes: buffer, count: compressedSize)
        return compressed
    }
    
    private func decompressData(_ data: Data) throws -> Data {
        var decompressed = Data(count: data.count * 4)
        let decompressedSize = decompressed.withUnsafeMutableBytes { destBuffer in
            data.withUnsafeBytes { srcBuffer in
                compression_decode_buffer(
                    destBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafeMutablePointer<UInt8>(bitPattern: 0)!,
                    decompressed.count,
                    srcBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafeRawPointer(bitPattern: 0)!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        decompressed.count = decompressedSize
        return decompressed
    }
    
    private func loadBackups() {
        guard let data = try? Data(contentsOf: backupDir.appendingPathComponent(".metadata.json")),
              let metadata = try? JSONDecoder().decode([BackupMetadata].self, from: data) else {
            return
        }
        self.backups = metadata.sorted { $0.createdAt > $1.createdAt }
        self.lastBackupDate = backups.first?.createdAt
    }
    
    private func saveMetadata() {
        if let encoded = try? JSONEncoder().encode(backups) {
            try? encoded.write(to: backupDir.appendingPathComponent(".metadata.json"))
        }
    }
}

enum BackupError: LocalizedError {
    case backupNotFound
    case corruptedBackup
    case encryptionFailed
    case compressionFailed
    
    var errorDescription: String? {
        switch self {
        case .backupNotFound:
            return "Backup file not found."
        case .corruptedBackup:
            return "Backup file is corrupted or invalid."
        case .encryptionFailed:
            return "Failed to encrypt backup."
        case .compressionFailed:
            return "Failed to compress backup."
        }
    }
}

extension String {
    func sha256Hash() -> String {
        let data = Data(self.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
