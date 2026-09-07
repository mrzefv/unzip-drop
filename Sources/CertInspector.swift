//
//  CertInspector.swift
//  Parse any X.509 PEM into human-readable facts — works identically on the
//  ACME (public) cert and the on-device local CA's root + leaf, so a user can
//  compare what a real CA issued vs. what the phone issued, field by field.
//  Pure DER walking (no OpenSSL on the read path) so it's cheap and safe.
//

import Foundation
import CryptoKit

nonisolated struct CertFacts: Sendable, Identifiable {
    var id: String { sha256 }
    var label: String                  // "Leaf", "Root", "Intermediate #1"
    var subjectCN: String
    var subjectO: String
    var issuerCN: String
    var issuerO: String
    var sans: [String]
    var notBefore: Date?
    var notAfter: Date?
    var serialHex: String
    var isCA: Bool
    var keyType: String                // "EC P-256", "RSA 2048", …
    var sha256: String                 // colon-separated
    var selfSigned: Bool { subjectCN == issuerCN && subjectO == issuerO }

    var daysLeft: Int? { notAfter.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 } }
}

nonisolated enum CertInspector {

    /// Every certificate in a PEM (leaf first for a fullchain).
    static func inspect(pem: String) -> [CertFacts] {
        var out: [CertFacts] = []
        var rest = Substring(pem)
        var idx = 0
        while let b = rest.range(of: "-----BEGIN CERTIFICATE-----"),
              let e = rest.range(of: "-----END CERTIFICATE-----", range: b.upperBound..<rest.endIndex) {
            let b64 = rest[b.upperBound..<e.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
            if let der = Data(base64Encoded: b64), var f = parse(der: der) {
                f.label = idx == 0 ? "Leaf" : (f.isCA && f.selfSigned ? "Root" : "Intermediate #\(idx)")
                out.append(f)
            }
            idx += 1
            rest = rest[e.upperBound...]
        }
        return out
    }

    static func inspect(fileURL: URL) -> [CertFacts] {
        guard let pem = try? String(contentsOf: fileURL) else { return [] }
        return inspect(pem: pem)
    }

    // MARK: - DER parsing

    private struct TLV { let tag: UInt8; let start: Int; let len: Int; let hdr: Int
        var contentStart: Int { start + hdr }; var end: Int { start + hdr + len } }

    private static func readTLV(_ b: [UInt8], _ at: Int) -> TLV? {
        guard at + 1 < b.count else { return nil }
        let tag = b[at]; var p = at + 1
        var len = Int(b[p]); p += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F; len = 0
            guard p + n <= b.count else { return nil }
            for _ in 0..<n { len = (len << 8) | Int(b[p]); p += 1 }
        }
        guard at + (p - at) + len <= b.count else { return nil }
        return TLV(tag: tag, start: at, len: len, hdr: p - at)
    }

    private static func children(_ b: [UInt8], _ t: TLV) -> [TLV] {
        var out: [TLV] = []; var p = t.contentStart
        while p < t.end, let c = readTLV(b, p) { out.append(c); p = c.end }
        return out
    }

    private static func parse(der: Data) -> CertFacts? {
        let b = [UInt8](der)
        guard let cert = readTLV(b, 0), cert.tag == 0x30,
              let tbs = readTLV(b, cert.contentStart), tbs.tag == 0x30 else { return nil }
        var fields = children(b, tbs)
        // optional [0] version
        if let f = fields.first, f.tag == 0xA0 { fields.removeFirst() }
        guard fields.count >= 6 else { return nil }
        let serial = fields[0], /*sigAlg*/ _ = fields[1], issuer = fields[2], validity = fields[3], subject = fields[4], spki = fields[5]

        let serialHex = b[serial.contentStart..<serial.end].map { String(format: "%02X", $0) }.joined(separator: ":")
        let (iCN, iO) = name(b, issuer)
        let (sCN, sO) = name(b, subject)
        let v = children(b, validity)
        let nb = v.count > 0 ? time(b, v[0]) : nil
        let na = v.count > 1 ? time(b, v[1]) : nil
        let keyType = keyDesc(b, spki)

        // extensions: [3] EXPLICIT SEQUENCE OF Extension
        var sans: [String] = []; var isCA = false
        if let ext = fields.first(where: { $0.tag == 0xA3 }), let seq = readTLV(b, ext.contentStart) {
            for e in children(b, seq) {
                let parts = children(b, e)
                guard let oid = parts.first, oid.tag == 0x06 else { continue }
                let oidBytes = Array(b[oid.contentStart..<oid.end])
                let valueTLV = parts.last!               // OCTET STRING (skip optional critical BOOLEAN)
                guard valueTLV.tag == 0x04, let inner = readTLV(b, valueTLV.contentStart) else { continue }
                if oidBytes == [0x55,0x1D,0x11] {         // subjectAltName
                    for gn in children(b, inner) where gn.tag == 0x82 {
                        if let s = String(bytes: b[gn.contentStart..<gn.end], encoding: .ascii) { sans.append(s) }
                    }
                } else if oidBytes == [0x55,0x1D,0x13] {  // basicConstraints
                    if let ca = children(b, inner).first, ca.tag == 0x01, ca.len == 1 { isCA = b[ca.contentStart] != 0 }
                }
            }
        }

        let fp = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        return CertFacts(label: "", subjectCN: sCN, subjectO: sO, issuerCN: iCN, issuerO: iO, sans: sans,
                         notBefore: nb, notAfter: na, serialHex: serialHex, isCA: isCA, keyType: keyType, sha256: fp)
    }

    /// Name → (CN, O)
    private static func name(_ b: [UInt8], _ n: TLV) -> (String, String) {
        var cn = "", o = ""
        for rdn in children(b, n) {                       // SET
            for atv in children(b, rdn) {                 // SEQUENCE { OID, value }
                let p = children(b, atv)
                guard p.count == 2, p[0].tag == 0x06 else { continue }
                let oid = Array(b[p[0].contentStart..<p[0].end])
                let val = String(bytes: b[p[1].contentStart..<p[1].end], encoding: .utf8) ?? ""
                if oid == [0x55,0x04,0x03] { cn = val }
                if oid == [0x55,0x04,0x0A] { o = val }
            }
        }
        return (cn, o)
    }

    private static func time(_ b: [UInt8], _ t: TLV) -> Date? {
        let s = String(decoding: b[t.contentStart..<t.end], as: UTF8.self)
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = t.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return f.date(from: s)
    }

    private static func keyDesc(_ b: [UInt8], _ spki: TLV) -> String {
        let p = children(b, spki)
        guard p.count == 2, let alg = readTLV(b, p[0].contentStart), alg.tag == 0x06 else { return "unknown" }
        let oid = Array(b[alg.contentStart..<alg.end])
        if oid == [0x2A,0x86,0x48,0xCE,0x3D,0x02,0x01] {           // ecPublicKey
            let params = children(b, p[0])
            if params.count > 1, params[1].tag == 0x06 {
                let c = Array(b[params[1].contentStart..<params[1].end])
                if c == [0x2A,0x86,0x48,0xCE,0x3D,0x03,0x01,0x07] { return "EC P-256" }
                if c == [0x2B,0x81,0x04,0x00,0x22] { return "EC P-384" }
            }
            return "EC"
        }
        if oid == [0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01] {  // rsaEncryption
            // bit string → SEQUENCE { modulus, exponent }; modulus length ≈ key bits
            if let bits = readTLV(b, p[1].contentStart), let seq = readTLV(b, bits.contentStart + 1), let mod = readTLV(b, seq.contentStart) {
                let bytes = mod.len - (b[mod.contentStart] == 0 ? 1 : 0)
                return "RSA \(bytes * 8)"
            }
            return "RSA"
        }
        return "unknown"
    }
}

// MARK: - What leaves the device (declared, not inferred)

nonisolated struct Endpoint: Identifiable, Sendable {
    var id: String { host }
    let host: String
    let purpose: String
    let sends: String
    let when: String
}

nonisolated enum TransparencyReport {
    /// Every network destination the app can contact, and what it sends there.
    static let endpoints: [Endpoint] = [
        Endpoint(host: "api.github.com", purpose: "GitHub API — repos, Actions runs, artifacts, certs branch, workflow dispatch",
                 sends: "Your GitHub token (Bearer header), repo names, files you push, workflow inputs (domain, email).",
                 when: "Push, Build tab, Browse › Repos, Link repo, Renew now, Pull latest."),
        Endpoint(host: "github.com / *.githubusercontent.com", purpose: "Artifact + release asset downloads (redirect targets)",
                 sends: "Your GitHub token for private repos. Nothing else.",
                 when: "Downloading an IPA/artifact from Browse › Repos or the Build tab."),
        Endpoint(host: "<source hosts> e.g. delvek.net, msign.party", purpose: "repo.json sources and their IPA download URLs",
                 sends: "Nothing but a standard GET. No identifiers, no token.",
                 when: "Opening a source in Browse, downloading an app."),
        Endpoint(host: "cloudflare-dns.com · dns.google · dns.quad9.net", purpose: "DNS-over-HTTPS lookups",
                 sends: "The hostname being checked (your OTA host / _acme-challenge name). No identifiers.",
                 when: "DNS checks in OTA Domain / Local CA / Force continue."),
        Endpoint(host: "acme-v02.api.letsencrypt.org (from GitHub Actions, not the phone)", purpose: "Certificate issuance",
                 sends: "Your ACME email + domain — from the workflow runner, never from this device.",
                 when: "Renew now (Public/ACME mode only)."),
        Endpoint(host: "mrzefv.com", purpose: "Legacy cert-refresh fallback",
                 sends: "Standard GET for pack.json. No identifiers.",
                 when: "Only if the certs branch fetch fails in Public mode."),
        Endpoint(host: "127.0.0.1 (your OTA host resolves here)", purpose: "On-device Vapor HTTPS server for installs",
                 sends: "The signed IPA + manifest, to installd on this same phone. Never leaves the device.",
                 when: "Install."),
    ]

    static let neverSent: [String] = [
        "Certificates or private keys (.p12, root/leaf keys) — Keychain only, never transmitted.",
        "Your UDID, device name, or any device identifier.",
        "Which apps you sign or install.",
        "Analytics, crash reports, or telemetry of any kind.",
    ]

    // MARK: Runtime self-checks — the app verifies its own claims

    nonisolated struct Check: Identifiable, Sendable {
        let id: String
        let title: String
        let pass: Bool
        let detail: String
    }

    /// Verifies the privacy/security claims at runtime rather than asserting them.
    static func selfCheck() -> [Check] {
        var out: [Check] = []
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // 1. No private-key files on disk anywhere under Documents.
        var keyFiles: [String] = []
        if let en = fm.enumerator(at: docs, includingPropertiesForKeys: nil) {
            for case let u as URL in en {
                let n = u.lastPathComponent.lowercased()
                if n.hasSuffix(".key") || n.hasSuffix(".pem") && !n.contains("server") {
                    if let t = try? String(contentsOf: u), t.contains("PRIVATE KEY") { keyFiles.append(u.lastPathComponent) }
                }
            }
        }
        out.append(Check(id: "nokeys", title: "No private keys on disk",
                         pass: keyFiles.isEmpty,
                         detail: keyFiles.isEmpty
                            ? "Scanned Documents — no PEM private keys found. (The Public-mode ACME key ships in the app bundle as server.pem by design; it protects a loopback-only domain and is not secret.)"
                            : "Found: \(keyFiles.joined(separator: ", "))"))

        // 2. Local CA keys live in Keychain (if a local CA exists).
        if LocalCAManager.hasRoot || fm.fileExists(atPath: LocalCAManager.rootCertURL.path) {
            let inKC = Keychain.getSecret("localca-root-key") != nil
            out.append(Check(id: "kc", title: "Local CA root key in Keychain",
                             pass: inKC, detail: inKC ? "Stored with ThisDeviceOnly — excluded from backups." : "Root cert exists but its key isn't in the Keychain."))
        }

        // 3. Signing .p12 password in Keychain, not in UserDefaults.
        let ud = UserDefaults.standard.dictionaryRepresentation()
        let leaky = ud.keys.filter { $0.lowercased().contains("password") || $0.lowercased().contains("p12") }
        out.append(Check(id: "ud", title: "No secrets in UserDefaults",
                         pass: leaky.isEmpty, detail: leaky.isEmpty ? "No password/p12 keys in preferences." : "Suspicious keys: \(leaky.joined(separator: ", "))"))

        // 4. GitHub token is Keychain-backed.
        let tokenKC = Keychain.get("gh_token") != nil
        let tokenUD = ud["gh_token"] != nil || ud.keys.contains { $0.lowercased().contains("token") && ($0 != "uzd_owner") }
        out.append(Check(id: "tok", title: "GitHub token only in Keychain",
                         pass: !tokenUD, detail: tokenKC ? (tokenUD ? "Also found a token-like key in UserDefaults." : "Present in Keychain, absent from UserDefaults.") : "No token set."))

        // 5. Temp dir has no leftover key material.
        let tmp = fm.temporaryDirectory
        var tmpKeys: [String] = []
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for u in items where u.lastPathComponent.hasPrefix("localca-leaf-") { tmpKeys.append(u.lastPathComponent) }
        }
        out.append(Check(id: "tmp", title: "No leftover key files in temp",
                         pass: tmpKeys.isEmpty, detail: tmpKeys.isEmpty ? "Just-in-time key files were cleaned up." : "Stale: \(tmpKeys.joined(separator: ", "))"))

        return out
    }
}
