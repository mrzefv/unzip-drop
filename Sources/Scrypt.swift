//
//  Scrypt.swift
//  Pure-Swift scrypt (RFC 7914) for Mcrypted-512's memory-hard KDF.
//  PBKDF2-HMAC-SHA256 → ROMix(BlockMix(Salsa20/8)) → PBKDF2 finalize.
//  CryptoKit only; no SPM/C dependency, phone-only buildable.
//
//  Cost is set by Mcrypted512 (Paranoid: N=2^19, r=4, p=1 ≈ 256 MB, ~2s).
//

import Foundation
import CryptoKit

nonisolated enum Scrypt {

    static func derive(password: Data, salt: Data, n: Int, r: Int, p: Int, dkLen: Int) -> Data {
        let mfLen = 128 * r
        // B = PBKDF2(password, salt, 1, p * 128 * r)
        var b = pbkdf2(password: password, salt: salt, rounds: 1, dkLen: p * mfLen)
        b.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<p {
                romix(base + i * mfLen, n: n, r: r)
            }
        }
        // DK = PBKDF2(password, B, 1, dkLen)
        return pbkdf2(password: password, salt: b, rounds: 1, dkLen: dkLen)
    }

    // MARK: ROMix (RFC 7914 §5)

    private static func romix(_ block: UnsafeMutablePointer<UInt8>, n: Int, r: Int) {
        let blockLen = 128 * r
        var x = [UInt8](repeating: 0, count: blockLen)
        for i in 0..<blockLen { x[i] = block[i] }

        // V = array of N blocks, each blockLen bytes. This is the memory-hard part.
        var v = [UInt8](repeating: 0, count: n * blockLen)
        for i in 0..<n {
            let off = i * blockLen
            for j in 0..<blockLen { v[off + j] = x[j] }
            blockMix(&x, r: r)
        }
        for _ in 0..<n {
            let j = integerify(x, r: r) & (n - 1)
            let off = j * blockLen
            for k in 0..<blockLen { x[k] ^= v[off + k] }
            blockMix(&x, r: r)
        }
        for i in 0..<blockLen { block[i] = x[i] }
    }

    private static func integerify(_ x: [UInt8], r: Int) -> Int {
        let off = (2 * r - 1) * 64
        var v = 0
        for i in 0..<4 { v |= Int(x[off + i]) << (8 * i) }
        return v
    }

    // MARK: BlockMix (RFC 7914 §4)

    private static func blockMix(_ b: inout [UInt8], r: Int) {
        var x = [UInt8](repeating: 0, count: 64)
        for i in 0..<64 { x[i] = b[(2 * r - 1) * 64 + i] }
        var out = [UInt8](repeating: 0, count: 128 * r)
        for i in 0..<(2 * r) {
            for k in 0..<64 { x[k] ^= b[i * 64 + k] }
            salsa20_8(&x)
            let dst = (i / 2 + (i % 2) * r) * 64
            for k in 0..<64 { out[dst + k] = x[k] }
        }
        b = out
    }

    // MARK: Salsa20/8 core (RFC 7914 §3)

    private static func salsa20_8(_ block: inout [UInt8]) {
        var x = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            x[i] = UInt32(block[4*i]) | (UInt32(block[4*i+1]) << 8) | (UInt32(block[4*i+2]) << 16) | (UInt32(block[4*i+3]) << 24)
        }
        let orig = x
        func R(_ a: UInt32, _ b: UInt32) -> UInt32 { (a << b) | (a >> (32 - b)) }
        var i = 0
        while i < 8 {
            x[ 4] ^= R(x[ 0] &+ x[12], 7);  x[ 8] ^= R(x[ 4] &+ x[ 0], 9)
            x[12] ^= R(x[ 8] &+ x[ 4],13);  x[ 0] ^= R(x[12] &+ x[ 8],18)
            x[ 9] ^= R(x[ 5] &+ x[ 1], 7);  x[13] ^= R(x[ 9] &+ x[ 5], 9)
            x[ 1] ^= R(x[13] &+ x[ 9],13);  x[ 5] ^= R(x[ 1] &+ x[13],18)
            x[14] ^= R(x[10] &+ x[ 6], 7);  x[ 2] ^= R(x[14] &+ x[10], 9)
            x[ 6] ^= R(x[ 2] &+ x[14],13);  x[10] ^= R(x[ 6] &+ x[ 2],18)
            x[ 3] ^= R(x[15] &+ x[11], 7);  x[ 7] ^= R(x[ 3] &+ x[15], 9)
            x[11] ^= R(x[ 7] &+ x[ 3],13);  x[15] ^= R(x[11] &+ x[ 7],18)
            x[ 1] ^= R(x[ 0] &+ x[ 3], 7);  x[ 2] ^= R(x[ 1] &+ x[ 0], 9)
            x[ 3] ^= R(x[ 2] &+ x[ 1],13);  x[ 0] ^= R(x[ 3] &+ x[ 2],18)
            x[ 6] ^= R(x[ 5] &+ x[ 4], 7);  x[ 7] ^= R(x[ 6] &+ x[ 5], 9)
            x[ 4] ^= R(x[ 7] &+ x[ 6],13);  x[ 5] ^= R(x[ 4] &+ x[ 7],18)
            x[11] ^= R(x[10] &+ x[ 9], 7);  x[ 8] ^= R(x[11] &+ x[10], 9)
            x[ 9] ^= R(x[ 8] &+ x[11],13);  x[10] ^= R(x[ 9] &+ x[ 8],18)
            x[12] ^= R(x[15] &+ x[14], 7);  x[13] ^= R(x[12] &+ x[15], 9)
            x[14] ^= R(x[13] &+ x[12],13);  x[15] ^= R(x[14] &+ x[13],18)
            i += 2
        }
        for k in 0..<16 {
            let v = x[k] &+ orig[k]
            block[4*k]   = UInt8(v & 0xff)
            block[4*k+1] = UInt8((v >> 8) & 0xff)
            block[4*k+2] = UInt8((v >> 16) & 0xff)
            block[4*k+3] = UInt8((v >> 24) & 0xff)
        }
    }

    // MARK: PBKDF2-HMAC-SHA256

    private static func pbkdf2(password: Data, salt: Data, rounds: Int, dkLen: Int) -> Data {
        let key = SymmetricKey(data: password)
        let hLen = 32
        let blocks = (dkLen + hLen - 1) / hLen
        var dk = Data()
        for i in 1...blocks {
            var msg = salt
            withUnsafeBytes(of: UInt32(i).bigEndian) { msg.append(contentsOf: $0) }
            var u = Data(HMAC<SHA256>.authenticationCode(for: msg, using: key))
            var t = u
            if rounds > 1 {
                for _ in 1..<rounds {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for k in 0..<t.count { t[k] ^= u[k] }
                }
            }
            dk.append(t)
        }
        return dk.prefix(dkLen)
    }
}
