//
//  Mcrypted512.swift
//  "Inject Data" tool crypto — Mcrypted-512.
//
//  Hides a picture/document inside the app's main Mach-O by APPENDING an
//  encrypted, authenticated blob after the binary's data. The append happens
//  BEFORE zsign runs, so the hidden payload is inside the code signature's
//  sealed region and survives signing/installation intact.
//
//  Mcrypted-512 scheme (self-contained, CryptoKit only):
//    passphrase + random 16B salt
//      → KDF: 200k rounds of SHA-512 (salt‖pass‖counter), 64 bytes out
//      → split: bytes[0..<32] = AES-256-GCM key, bytes[32..<64] = HMAC-SHA-512 key
//    ciphertext = AES-256-GCM(payload, key, random 12B nonce)   (authenticated)
//    tag        = HMAC-SHA-512 over (header ‖ ciphertext)       (encrypt-then-MAC)
//  Wrong passphrase or any tampering → decryption/verify fails, never returns garbage.
//

import Foundation
import CryptoKit

nonisolated enum Mcrypted512 {

    static let magic = Data("MC512\u{01}".utf8)   // 6 bytes: "MC512" + version 1
    enum McError: LocalizedError {
        case notFound, badMagic, badTag, badGCM, tooLarge, empty
        var errorDescription: String? {
            switch self {
            case .notFound: return "No Mcrypted-512 payload found in this binary."
            case .badMagic: return "Payload header is corrupt."
            case .badTag:   return "Integrity check failed — wrong passphrase or the binary was modified."
            case .badGCM:   return "Decryption failed — wrong passphrase."
            case .tooLarge: return "Payload is too large."
            case .empty:    return "Nothing to embed."
            }
        }
    }

    // MARK: - Recovery key (12 words = the encryption secret, Model A)
    //
    //  256 bits of CSPRNG entropy -> 24 words from the Mcrypted wordlist (11 bits each,
    //  264 bits capacity; the low 8 bits of the last word are random padding). The words
    //  ARE the secret; the KDF runs on the recovered 32-byte entropy, so any device that
    //  enters the same 24 words derives the same keys. Not a BIP-39 seed.

    static let wordCount = 24
    static let entropyBytes = 32   // 256-bit recovery secret

    static func newRecoveryKey() -> (words: [String], entropy: Data) {
        var entropy = Data(count: entropyBytes)
        _ = entropy.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, entropyBytes, $0.baseAddress!) }
        return (words(fromEntropy: entropy), entropy)
    }

    static func words(fromEntropy entropy: Data) -> [String] {
        var bits: [Bool] = []
        for byte in entropy { for i in (0..<8).reversed() { bits.append((byte >> i) & 1 == 1) } }
        while bits.count < wordCount * 11 { bits.append(Bool.random()) }
        var out: [String] = []
        for w in 0..<wordCount {
            var idx = 0
            for b in 0..<11 { idx = (idx << 1) | (bits[w*11 + b] ? 1 : 0) }
            out.append(McryptedWordlist.words[idx])
        }
        return out
    }

    static func entropy(fromWords raw: [String]) -> Data? {
        let ws = raw.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard ws.count == wordCount else { return nil }
        var bits: [Bool] = []
        for w in ws {
            guard let idx = McryptedWordlist.index[w] else { return nil }
            for b in (0..<11).reversed() { bits.append((idx >> b) & 1 == 1) }
        }
        var bytes = [UInt8](repeating: 0, count: entropyBytes)
        for i in 0..<(entropyBytes * 8) { if bits[i] { bytes[i/8] |= (1 << (7 - (i%8))) } }
        return Data(bytes)
    }

    static func isValidWord(_ w: String) -> Bool { McryptedWordlist.index[w.lowercased()] != nil }

    // MARK: KDF

    /// Stretch a passphrase into 64 bytes (AES key ‖ HMAC key) with a salted SHA-512 chain.
    private static func derive(_ pass: String, salt: Data, rounds: Int = 200_000) -> (aes: SymmetricKey, mac: SymmetricKey) {
        deriveKM(Data(pass.utf8), salt: salt, rounds: rounds)
    }

    /// Same KDF over raw key material (the 16-byte recovery entropy).
    private static func deriveKM(_ material: Data, salt: Data, rounds: Int = 200_000) -> (aes: SymmetricKey, mac: SymmetricKey) {
        var acc = Data()
        acc.append(salt)
        acc.append(material)
        var digest = Data(SHA512.hash(data: acc))
        for i in 1..<rounds {
            var block = digest
            block.append(salt)
            withUnsafeBytes(of: UInt32(i).littleEndian) { block.append(contentsOf: $0) }
            digest = Data(SHA512.hash(data: block))
        }
        return (SymmetricKey(data: digest.prefix(32)), SymmetricKey(data: digest.suffix(32)))
    }

    // MARK: Blob format
    //  magic(6) | saltLen(1)=16 | salt(16) | nonce(12) |
    //  nameLen(2 LE) | name(utf8) | ctLen(8 LE) | ciphertext | hmac(64)

    static func makeBlob(payload: Data, filename: String, entropy: Data) throws -> Data {
        try makeBlobCore(payload: payload, filename: filename, keyMaterial: entropy)
    }

    static func makeBlob(payload: Data, filename: String, passphrase: String) throws -> Data {
        try makeBlobCore(payload: payload, filename: filename, keyMaterial: Data(passphrase.utf8))
    }

    private static func makeBlobCore(payload: Data, filename: String, keyMaterial: Data) throws -> Data {
        guard !payload.isEmpty else { throw McError.empty }
        guard payload.count < 200 * 1024 * 1024 else { throw McError.tooLarge }

        let salt = randomData(16)
        let (aesKey, macKey) = deriveKM(keyMaterial, salt: salt)

        let sealed = try AES.GCM.seal(payload, using: aesKey)
        guard let combined = sealed.combined else { throw McError.badGCM }   // nonce(12)+ct+tag(16)

        let name = Data(filename.utf8)
        var header = Data()
        header.append(magic)
        header.append(UInt8(16))
        header.append(salt)
        appendLE(&header, UInt16(name.count))
        header.append(name)
        appendLE(&header, UInt64(combined.count))

        var blob = header
        blob.append(combined)

        let mac = HMAC<SHA512>.authenticationCode(for: blob, using: macKey)
        blob.append(contentsOf: mac)   // 64 bytes
        return blob
    }

    /// Locate + decrypt a payload from a full binary's bytes.
    static func extract(fromBinary data: Data, entropy: Data) throws -> (filename: String, payload: Data) {
        try extractCore(fromBinary: data, keyMaterial: entropy)
    }

    static func extract(fromBinary data: Data, passphrase: String) throws -> (filename: String, payload: Data) {
        try extractCore(fromBinary: data, keyMaterial: Data(passphrase.utf8))
    }

    private static func extractCore(fromBinary data: Data, keyMaterial: Data) throws -> (filename: String, payload: Data) {
        guard let start = lastRange(of: magic, in: data)?.lowerBound else { throw McError.notFound }
        var p = start
        func need(_ n: Int) throws { guard p + n <= data.count else { throw McError.badMagic } }

        try need(magic.count); p += magic.count
        try need(1); let saltLen = Int(data[p]); p += 1
        guard saltLen == 16 else { throw McError.badMagic }
        try need(16); let salt = data.subdata(in: p ..< p+16); p += 16
        try need(2); let nameLen = Int(readLE16(data, p)); p += 2
        try need(nameLen); let name = String(decoding: data.subdata(in: p ..< p+nameLen), as: UTF8.self); p += nameLen
        try need(8); let ctLen = Int(readLE64(data, p)); p += 8
        try need(ctLen); let combined = data.subdata(in: p ..< p+ctLen); p += ctLen
        try need(64); let tag = data.subdata(in: p ..< p+64)

        let (aesKey, macKey) = deriveKM(keyMaterial, salt: salt)

        // Verify HMAC over everything before the tag (encrypt-then-MAC).
        let signedRegion = data.subdata(in: start ..< (p))   // header+ct, excludes tag
        guard HMAC<SHA512>.isValidAuthenticationCode(tag, authenticating: signedRegion, using: macKey) else { throw McError.badTag }

        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let clear = try AES.GCM.open(box, using: aesKey)
            return (name, clear)
        } catch { throw McError.badGCM }
    }

    static func hasPayload(inBinary data: Data) -> Bool { lastRange(of: magic, in: data) != nil }

    // MARK: helpers

    private static func randomData(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }
    private static func appendLE<T: FixedWidthInteger>(_ d: inout Data, _ v: T) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    private static func readLE16(_ d: Data, _ at: Int) -> UInt16 {
        UInt16(d[at]) | (UInt16(d[at+1]) << 8)
    }
    private static func readLE64(_ d: Data, _ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[at+i]) << (8*i) }
        return v
    }
    private static func lastRange(of needle: Data, in hay: Data) -> Range<Int>? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            if hay.subdata(in: i ..< i+needle.count) == needle { return i ..< i+needle.count }
            i -= 1
        }
        return nil
    }
}
