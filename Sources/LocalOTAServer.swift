//
//  LocalOTAServer.swift
//  On-device OTA install the way full mSign does it: a Vapor HTTPS server on
//  the device (NIOSSL) serving an itms-services manifest + the signed IPA.
//
//  Any domain works: point `*.<domain>` at 127.0.0.1 and let certs.yml issue
//  a Let's Encrypt wildcard for it. zefv.dev is just the default whose cert
//  ships in the bundle. The cert is one WE issue: .github/workflows/certs.yml runs certbot (DNS-01) and
//  publishes server.crt / server.pem / pack.json on the `certs` branch. A copy
//  ships in the bundle (Build.yml bakes the latest one in) and the app refreshes
//  from the branch before expiry. iOS trusts the chain, connects to
//  loopback as mr.zefv.dev, installs — no network needed for the install itself.
//

import Foundation
import Vapor
import NIOSSL

// MARK: - Config

nonisolated enum ServerConfig {
    /// Bring-your-own domain. Requirements: `*.<domain>` (and ideally `<domain>`) have an
    /// A record → 127.0.0.1, and certs.yml has issued a wildcard cert for it.
    /// Default is zefv.dev, whose cert ships in the bundle.
    static let defaultDomain = "zefv.dev"
    static var certDomain: String {
        UserDefaults.standard.string(forKey: "uzd_cert_domain") ?? defaultDomain
    }
    static func setCertDomain(_ d: String) { UserDefaults.standard.set(d, forKey: "uzd_cert_domain") }

    /// SNI + manifest host. Must be under `certDomain` and covered by the cert's SANs.
    static var installHost: String {
        UserDefaults.standard.string(forKey: "uzd_install_host") ?? "mr.\(certDomain)"
    }
    static func setInstallHost(_ h: String) { UserDefaults.standard.set(h, forKey: "uzd_install_host") }

    /// Bundled Let's Encrypt pair from mSign (Sources/Resources):
    ///   server.crt ← fullchain.pem   server.pem ← privkey.pem
    static let certResource = "server"

    /// OTA TLS source: "public" (ACME/DNS cert, iOS-trusted, no profile) or
    /// "local" (our own root CA — no DNS, but needs the root profile installed).
    static var certMode: String { UserDefaults.standard.string(forKey: "uzd_cert_mode") ?? "public" }
    static func setCertMode(_ m: String) { UserDefaults.standard.set(m, forKey: "uzd_cert_mode") }

    /// Hand-rolled cert pipeline: .github/workflows/certs.yml runs certbot
    /// (DNS-01) for *.zefv.dev and commits server.crt / server.pem / pack.json
    /// to the `certs` branch. The app reads them through the GitHub Contents
    /// API with its own token, so private repos work too.
    static var certRepoOwner: String { UserDefaults.standard.string(forKey: "uzd_cert_owner") ?? "mrzefv" }
    static var certRepoName:  String { UserDefaults.standard.string(forKey: "uzd_cert_repo")  ?? "unzip-drop" }
    static var certBranch:    String { UserDefaults.standard.string(forKey: "uzd_cert_branch") ?? "certs" }
    static func setCertSource(owner: String, repo: String, branch: String) {
        UserDefaults.standard.set(owner, forKey: "uzd_cert_owner")
        UserDefaults.standard.set(repo,  forKey: "uzd_cert_repo")
        UserDefaults.standard.set(branch, forKey: "uzd_cert_branch")
    }
    static let certWorkflowPath = ".github/workflows/certs.yml"

    // ACME certificate authority + optional ZeroSSL EAB credentials.
    static var certCA: String { UserDefaults.standard.string(forKey: "uzd_cert_ca") ?? "letsencrypt" }
    static func setCertCA(_ v: String) { UserDefaults.standard.set(v, forKey: "uzd_cert_ca") }
    static var eabKID: String { UserDefaults.standard.string(forKey: "uzd_eab_kid") ?? "" }
    static var eabHMAC: String { UserDefaults.standard.string(forKey: "uzd_eab_hmac") ?? "" }
    static func setEAB(kid: String, hmac: String) {
        UserDefaults.standard.set(kid, forKey: "uzd_eab_kid")
        UserDefaults.standard.set(hmac, forKey: "uzd_eab_hmac")
    }

    /// Legacy fallback (mSign's endpoint), tried only if the GitHub source fails.
    static let refreshURL = URL(string: "https://mrzefv.com/certs/pack.json")!
    static let refreshBufferDays = 21
}

// MARK: - Cert (bundled + refreshed)

nonisolated enum ZefvCert {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var cachedCrt: URL { docs.appendingPathComponent("refreshed-server.crt") }
    static var cachedKey: URL { docs.appendingPathComponent("refreshed-server.pem") }
    static var metaURL: URL { docs.appendingPathComponent("refreshed-cert.json") }

    static var bundledCrt: URL? { Bundle.main.url(forResource: ServerConfig.certResource, withExtension: "crt") }
    static var bundledKey: URL? { Bundle.main.url(forResource: ServerConfig.certResource, withExtension: "pem") }

    static var hasCached: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: cachedCrt.path) && fm.fileExists(atPath: cachedKey.path)
    }
    /// Refreshed copy wins over the bundle.
    static var crtURL: URL? { hasCached ? cachedCrt : bundledCrt }
    static var keyURL: URL? { hasCached ? cachedKey : bundledKey }
    static var isAvailable: Bool { crtURL != nil && keyURL != nil }

    /// SANs of the cert in effect (bundled or refreshed).
    static var effectiveSANs: [String] {
        guard let u = crtURL, let d = try? Data(contentsOf: u) else { return [] }
        return sans(fromPEM: d)
    }

    /// Does the current cert cover `host`? Exact match or one-label wildcard.
    static func covers(_ host: String, sans: [String]? = nil) -> Bool {
        let h = host.lowercased()
        for san in (sans ?? effectiveSANs).map({ $0.lowercased() }) {
            if san == h { return true }
            if san.hasPrefix("*."), h.hasSuffix(String(san.dropFirst(1))),
               !h.dropLast(san.count - 1).contains(".") { return true }
        }
        return false
    }

    /// Does `host` resolve to loopback? (A record via DNS-over-HTTPS.)
    static func resolvesToLoopback(_ host: String) async -> Bool? {
        for q in ["https://cloudflare-dns.com/dns-query?name=\(host)&type=A",
                  "https://dns.google/resolve?name=\(host)&type=A"] {
            guard let u = URL(string: q) else { continue }
            var req = URLRequest(url: u); req.setValue("application/dns-json", forHTTPHeaderField: "accept")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (d, _) = try? await URLSession.shared.data(for: req),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let ips = ((j["Answer"] as? [[String: Any]]) ?? []).compactMap { $0["data"] as? String }
            if ips.isEmpty { continue }
            return ips.contains { $0.hasPrefix("127.") }
        }
        return nil
    }

    struct Meta: Codable, Sendable { var notAfter: Date?; var fetchedAt: Date }

    static var meta: Meta? {
        guard let d = try? Data(contentsOf: metaURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Meta.self, from: d)
    }

    /// Expiry of whichever cert is in effect (bundled or refreshed).
    static var effectiveNotAfter: Date? {
        if hasCached, let m = meta?.notAfter { return m }
        if let u = crtURL, let d = try? Data(contentsOf: u) { return notAfter(fromPEM: d) }
        return nil
    }

    static var needsRefresh: Bool {
        guard let exp = effectiveNotAfter else { return true }
        return exp.timeIntervalSinceNow < TimeInterval(ServerConfig.refreshBufferDays * 86400)
    }

    enum CertError: LocalizedError {
        case unavailable, badPack(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "server.crt / server.pem aren't in the bundle and no refreshed copy exists."
            case .badPack(let m): return "Cert refresh (mrzefv.com/certs/pack.json): \(m)"
            }
        }
    }

    private struct Manifest: Decodable {
        let bundle: String
        let key: String?
        let expires: String?
    }

    /// Pull a fresh chain + key. Primary: `certs` branch of the configured repo via the
    /// GitHub Contents API (token optional for public repos). Fallback: mSign's pack.json.
    static func fetch(token: String? = nil) async throws -> Meta {
        do { return try await fetchFromGitHub(token: token) }
        catch let primary {
            do { return try await fetchFromURL(ServerConfig.refreshURL) }
            catch { throw primary }
        }
    }

    static func fetchFromGitHub(token: String?) async throws -> Meta {
        let o = ServerConfig.certRepoOwner, r = ServerConfig.certRepoName, b = ServerConfig.certBranch
        func raw(_ path: String) async throws -> Data {
            var c = URLComponents(string: "https://api.github.com/repos/\(o)/\(r)/contents/\(path)")!
            c.queryItems = [URLQueryItem(name: "ref", value: b)]
            var req = URLRequest(url: c.url!)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
            if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 400, !d.isEmpty else {
                throw CertError.badPack("\(o)/\(r)@\(b)/\(path) → HTTP \(code). The cert files aren't on the certs branch yet. If the last run showed VALIDATED, its publish step failed — open the run's 'Write pack.json & publish' step, or tap Renew now to re-issue. Also confirm the token can read this repo.")
            }
            return d
        }
        let packData = try await raw("pack.json")
        let m: Manifest
        do { m = try JSONDecoder().decode(Manifest.self, from: packData) } catch { throw CertError.badPack("unreadable pack.json") }
        guard let keyFile = m.key, !keyFile.isEmpty else { throw CertError.badPack("pack.json has no key entry") }
        let chain = try await raw(m.bundle)
        let key   = try await raw(keyFile)
        return try store(chain: chain, key: key, expires: m.expires)
    }

    static func fetchFromURL(_ url: URL) async throws -> Meta {
        var req = URLRequest(url: url); req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw CertError.badPack("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        let m: Manifest
        do { m = try JSONDecoder().decode(Manifest.self, from: data) } catch { throw CertError.badPack("unreadable pack.json") }
        guard let keyFile = m.key, !keyFile.isEmpty else { throw CertError.badPack("pack.json has no key entry") }
        let base = url.deletingLastPathComponent()
        func get(_ name: String) async throws -> Data {
            let u = name.hasPrefix("http") ? URL(string: name)! : base.appendingPathComponent(name)
            let (d, r) = try await URLSession.shared.data(from: u)
            guard (r as? HTTPURLResponse)?.statusCode ?? 0 < 400, !d.isEmpty else { throw CertError.badPack("couldn't download \(name)") }
            return d
        }
        return try store(chain: try await get(m.bundle), key: try await get(keyFile), expires: m.expires)
    }

    /// Validate (NIOSSL must parse both, key must match the leaf's SAN set) then cache.
    private static func store(chain: Data, key: Data, expires: String?) throws -> Meta {
        _ = try NIOSSLCertificate.fromPEMBytes(Array(chain))
        _ = try NIOSSLPrivateKey(bytes: Array(key), format: .pem)
        try chain.write(to: cachedCrt, options: .atomic)
        try key.write(to: cachedKey, options: .atomic)
        let exp = expires.flatMap { ISO8601DateFormatter().date(from: $0) } ?? notAfter(fromPEM: chain)
        let meta = Meta(notAfter: exp, fetchedAt: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(meta).write(to: metaURL)
        return meta
    }

    @discardableResult
    static func refreshIfNeeded(token: String? = nil) async -> Meta? {
        guard needsRefresh else { return meta }
        return try? await fetch(token: token)
    }

    static func clearCache() {
        for u in [cachedCrt, cachedKey, metaURL] { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: notAfter from the leaf cert (minimal DER walk)

    static func notAfter(fromPEM pem: Data) -> Date? {
        guard let s = String(data: pem, encoding: .utf8),
              let a = s.range(of: "-----BEGIN CERTIFICATE-----"),
              let b = s.range(of: "-----END CERTIFICATE-----") else { return nil }
        let b64 = s[a.upperBound..<b.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: b64) else { return nil }
        return parseNotAfter([UInt8](der))
    }
    private static func parseNotAfter(_ b: [UInt8]) -> Date? {
        var i = 0
        func readTL() -> (tag: UInt8, len: Int, hdr: Int)? {
            guard i + 1 < b.count else { return nil }
            let tag = b[i]; var p = i + 1
            var len = Int(b[p]); p += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F; len = 0
                guard p + n <= b.count else { return nil }
                for _ in 0..<n { len = (len << 8) | Int(b[p]); p += 1 }
            }
            return (tag, len, p - i)
        }
        guard let outer = readTL(), outer.tag == 0x30 else { return nil }; i += outer.hdr
        guard let tbs = readTL(), tbs.tag == 0x30 else { return nil }; i += tbs.hdr
        if let v = readTL(), v.tag == 0xA0 { i += v.hdr + v.len }             // version
        guard let serial = readTL() else { return nil }; i += serial.hdr + serial.len
        guard let sigAlg = readTL() else { return nil }; i += sigAlg.hdr + sigAlg.len
        guard let issuer = readTL() else { return nil }; i += issuer.hdr + issuer.len
        guard let validity = readTL(), validity.tag == 0x30 else { return nil }; i += validity.hdr
        guard let nb = readTL() else { return nil }; i += nb.hdr + nb.len          // notBefore
        guard let na = readTL(), i + na.hdr + na.len <= b.count else { return nil }
        let s = String(decoding: b[(i + na.hdr)..<(i + na.hdr + na.len)], as: UTF8.self)
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = na.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return f.date(from: s)
    }
}

extension ZefvCert {
    /// dNSName SANs from the leaf cert: find the SAN extension OID (2.5.29.17) in DER,
    /// then read the [2] IA5String entries of the inner SEQUENCE.
    static func sans(fromPEM pem: Data) -> [String] {
        guard let s = String(data: pem, encoding: .utf8),
              let a = s.range(of: "-----BEGIN CERTIFICATE-----"),
              let b = s.range(of: "-----END CERTIFICATE-----") else { return [] }
        let b64 = s[a.upperBound..<b.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: b64) else { return [] }
        let x = [UInt8](der)
        let oid: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x11]
        guard x.count > oid.count + 4 else { return [] }
        var i = 0
        while i + oid.count < x.count {
            if Array(x[i..<i+oid.count]) == oid { break }
            i += 1
        }
        guard i + oid.count < x.count else { return [] }
        var p = i + oid.count
        func len(_ at: inout Int) -> Int? {
            guard at < x.count else { return nil }
            var l = Int(x[at]); at += 1
            if l & 0x80 != 0 { let n = l & 0x7F; l = 0; guard at + n <= x.count else { return nil }; for _ in 0..<n { l = (l << 8) | Int(x[at]); at += 1 } }
            return l
        }
        if p < x.count, x[p] == 0x01 { p += 3 }                  // optional critical BOOLEAN
        guard p < x.count, x[p] == 0x04 else { return [] }        // OCTET STRING
        p += 1; guard let _ = len(&p) else { return [] }
        guard p < x.count, x[p] == 0x30 else { return [] }        // SEQUENCE
        p += 1; guard let seqLen = len(&p) else { return [] }
        let end = min(x.count, p + seqLen)
        var out: [String] = []
        while p < end {
            let tag = x[p]; p += 1
            guard let l = len(&p), p + l <= end else { break }
            if tag == 0x82, let str = String(bytes: x[p..<p+l], encoding: .ascii) { out.append(str) }
            p += l
        }
        return out
    }
}

// MARK: - One-tap link-up (phone only: sign in to GitHub, link a repo, done)

nonisolated enum CertSourceLinker {
    struct Report: Sendable {
        var repoOK = false
        var installedFiles: [String] = []
        var branchCreated = false
        var notes: [String] = []
    }

    private static func gh(_ path: String, token: String, method: String = "GET", body: [String: Any]? = nil,
                           accept: String = "application/vnd.github+json") async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (d, r) = try await URLSession.shared.data(for: req)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        return (code, obj)
    }

    /// 1) verify the token sees the repo, 2) install certs.yml + hooks on the default branch
    ///    if they're missing, 3) create the orphan `certs` branch (README + empty challenge board).
    static func link(owner: String, repo: String, token: String, forceUpdate: Bool = false) async throws -> Report {
        guard !token.isEmpty else { throw GitHubError.badConfig("Add a GitHub token in Settings › Access token first.") }
        var rep = Report()
        let base = "/repos/\(owner)/\(repo)"

        let (rc, rj) = try await gh(base, token: token)
        guard rc == 200 else { throw GitHubError.badConfig("Can't see \(owner)/\(repo) (HTTP \(rc)). Check the repo name and that the token has Contents + Actions + Workflows: Read and write on it.") }
        rep.repoOK = true
        let defaultBranch = rj["default_branch"] as? String ?? "main"

        // 2) pipeline files — push only what's missing (the app's own push engine).
        // forceUpdate: push every pipeline file regardless — replaces a stale
        // certs.yml/hook on main with the app's embedded copy.
        var missing: [(path: String, data: Data)] = []
        for f in CertPipeline.files {
            if forceUpdate { missing.append(f); continue }
            let (c, _) = try await gh("\(base)/contents/\(f.path)?ref=\(defaultBranch)", token: token)
            if c == 404 { missing.append(f) }
        }
        if !missing.isEmpty {
            let client = GitHubClient(owner: owner, repo: repo, branch: defaultBranch, token: token)
            do {
                _ = try await client.push(files: missing, subpath: "", message: forceUpdate ? "Update OTA cert pipeline (certbot via Actions)" : "Add OTA cert pipeline (certbot via Actions)", progress: { _, _ in })
                rep.installedFiles = missing.map(\.path)
            } catch {
                throw GitHubError.badConfig("Installing the workflow failed: \(error.localizedDescription) — the token needs Workflows: Read and write to add .github/workflows files.")
            }
        } else {
            rep.notes.append("Pipeline already installed on \(defaultBranch).")
        }

        // 3) certs branch (orphan commit via the Git Data API).
        let (bc, _) = try await gh("\(base)/branches/\(CertPipeline.branch)", token: token)
        if bc == 404 {
            func blob(_ text: String) async throws -> String {
                let (c, j) = try await gh("\(base)/git/blobs", token: token, method: "POST", body: ["content": text, "encoding": "utf-8"])
                guard c == 201, let sha = j["sha"] as? String else { throw GitHubError.badConfig("blob failed (\(c))") }
                return sha
            }
            let readme = try await blob("# OTA certs\n\nPublished by `.github/workflows/certs.yml`: server.crt (fullchain), server.pem (key), pack.json, challenge.json.\n")
            let board  = try await blob("{\"records\":[],\"updatedAt\":\"\",\"instructions\":\"Linked. Tap Renew now in the app to issue your first cert.\"}\n")
            let (tc, tj) = try await gh("\(base)/git/trees", token: token, method: "POST", body: ["tree": [
                ["path": "README.md",      "mode": "100644", "type": "blob", "sha": readme],
                ["path": "challenge.json", "mode": "100644", "type": "blob", "sha": board],
            ]])
            guard tc == 201, let tree = tj["sha"] as? String else { throw GitHubError.badConfig("tree failed (\(tc))") }
            let (cc, cj) = try await gh("\(base)/git/commits", token: token, method: "POST", body: ["message": "init certs branch", "tree": tree, "parents": []])
            guard cc == 201, let commit = cj["sha"] as? String else { throw GitHubError.badConfig("commit failed (\(cc))") }
            let (refc, _) = try await gh("\(base)/git/refs", token: token, method: "POST", body: ["ref": "refs/heads/\(CertPipeline.branch)", "sha": commit])
            guard refc == 201 else { throw GitHubError.badConfig("creating branch failed (\(refc))") }
            rep.branchCreated = true
        } else {
            rep.notes.append("certs branch already exists.")
        }
        return rep
    }
}

// MARK: - ACME challenge board (manual DNS-01 progress from certs.yml)

nonisolated struct AcmeCheck: Decodable, Sendable {
    struct NS: Decodable, Sendable { let seen: Bool; let txt: String? }
    let at: String?
    let authoritative: [String: NS]?
    let authoritativeSeen: Bool?
    let resolvers: [String: Bool]?
}

nonisolated struct AcmeChallenge: Decodable, Identifiable, Sendable {
    let domain: String
    let name: String
    let value: String
    let step: Int
    let of: Int
    let status: String          // pending | seen | forced | validated | timeout
    let force: Bool?
    let lastCheck: AcmeCheck?
    var id: String { value }
}

nonisolated struct AcmeBoard: Decodable, Sendable {
    let records: [AcmeChallenge]
    let updatedAt: String?
    let instructions: String?
    var pending: [AcmeChallenge] { records.filter { $0.status == "pending" } }
}

extension ZefvCert {
    /// challenge.json from the certs branch (nil if the branch/file doesn't exist yet).
    static func challengeBoard(token: String?) async -> AcmeBoard? {
        let o = ServerConfig.certRepoOwner, r = ServerConfig.certRepoName, b = ServerConfig.certBranch
        var c = URLComponents(string: "https://api.github.com/repos/\(o)/\(r)/contents/challenge.json")!
        c.queryItems = [URLQueryItem(name: "ref", value: b)]
        var req = URLRequest(url: c.url!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { return nil }
        return try? JSONDecoder().decode(AcmeBoard.self, from: d)
    }

    /// Flip "force": true on a pending record in challenge.json (certs branch). The hook
    /// pulls the file every poll and proceeds to validation as soon as it sees it.
    static func forceChallenge(value: String, token: String) async throws {
        guard !token.isEmpty else { throw GitHubError.badConfig("GitHub token required.") }
        let o = ServerConfig.certRepoOwner, r = ServerConfig.certRepoName, b = ServerConfig.certBranch
        let url = URL(string: "https://api.github.com/repos/\(o)/\(r)/contents/challenge.json?ref=\(b)")!
        var req = URLRequest(url: url); req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let meta = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sha = meta["sha"] as? String,
              let b64 = (meta["content"] as? String)?.replacingOccurrences(of: "\n", with: ""),
              let raw = Data(base64Encoded: b64),
              var doc = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw GitHubError.badConfig("Couldn't read challenge.json on \(b).")
        }
        var recs = doc["records"] as? [[String: Any]] ?? []
        var hit = false
        for i in recs.indices where (recs[i]["value"] as? String) == value { recs[i]["force"] = true; hit = true }
        guard hit else { throw GitHubError.badConfig("That challenge is no longer on the board.") }
        doc["records"] = recs
        doc["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        let newData = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        var put = URLRequest(url: URL(string: "https://api.github.com/repos/\(o)/\(r)/contents/challenge.json")!)
        put.httpMethod = "PUT"
        put.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        put.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        put.httpBody = try JSONSerialization.data(withJSONObject: [
            "message": "acme: force continue (from app)",
            "content": newData.base64EncodedString(),
            "sha": sha, "branch": b,
        ])
        let (_, pr) = try await URLSession.shared.data(for: put)
        guard (200...299).contains((pr as? HTTPURLResponse)?.statusCode ?? 0) else {
            throw GitHubError.badConfig("Couldn't update challenge.json (HTTP \((pr as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
    }

    /// What's actually on the certs branch — reports per-file presence so the
    /// UI can distinguish "publish step failed" from "wrong repo/branch/token".
    struct BranchProbe: Sendable {
        var reachable = false
        var httpCode = 0
        var hasPackJson = false, hasServerCrt = false, hasServerPem = false
        var files: [String] = []
        var summary: String {
            if httpCode == 404 && files.isEmpty { return "Branch/repo not found, or token can't read it (HTTP 404)." }
            if !reachable { return "Couldn't reach the branch (HTTP \(httpCode))." }
            if hasPackJson && hasServerCrt && hasServerPem { return "All cert files present — tap Pull latest." }
            var missing: [String] = []
            if !hasPackJson { missing.append("pack.json") }
            if !hasServerCrt { missing.append("server.crt") }
            if !hasServerPem { missing.append("server.pem") }
            return "Branch exists but missing: \(missing.joined(separator: ", ")). The workflow's publish step didn't finish — re-run it (Renew now)."
        }
    }

    static func probeCertBranch(token: String?) async -> BranchProbe {
        var p = BranchProbe()
        let o = ServerConfig.certRepoOwner, r = ServerConfig.certRepoName, b = ServerConfig.certBranch
        var c = URLComponents(string: "https://api.github.com/repos/\(o)/\(r)/git/trees/\(b)")!
        c.queryItems = [URLQueryItem(name: "recursive", value: "0")]
        var req = URLRequest(url: c.url!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (d, resp) = try? await URLSession.shared.data(for: req) else { return p }
        p.httpCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard p.httpCode < 400, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tree = j["tree"] as? [[String: Any]] else { return p }
        p.reachable = true
        p.files = tree.compactMap { $0["path"] as? String }
        p.hasPackJson = p.files.contains("pack.json")
        p.hasServerCrt = p.files.contains("server.crt")
        p.hasServerPem = p.files.contains("server.pem")
        return p
    }

    /// Live TXT lookup over DNS-over-HTTPS (same resolvers the hook polls).
    static func txtRecords(_ name: String) async -> [String] {
        var out = Set<String>()
        for q in ["https://cloudflare-dns.com/dns-query?name=\(name)&type=TXT",
                  "https://dns.google/resolve?name=\(name)&type=TXT"] {
            guard let u = URL(string: q) else { continue }
            var req = URLRequest(url: u); req.setValue("application/dns-json", forHTTPHeaderField: "accept")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (d, _) = try? await URLSession.shared.data(for: req),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ans = j["Answer"] as? [[String: Any]] else { continue }
            for a in ans {
                if let s = a["data"] as? String { out.insert(s.replacingOccurrences(of: "\"", with: "")) }
            }
        }
        return Array(out)
    }
}

// MARK: - Install trace (what installd actually fetched)

/// Every request the OTA server answered during an install, so a failure can be
/// diagnosed: no requests = TLS/DNS; manifest only = IPA fetch failed; both =
/// installd rejected the package (signing/provisioning/bundle-id).
nonisolated final class OTATrace: @unchecked Sendable {
    static let shared = OTATrace()
    struct Entry: Sendable, Identifiable { let id = UUID(); let at: Date; let path: String; let status: Int; let bytes: Int64 }
    private var entries: [Entry] = []
    private let lock = NSLock()

    func reset() { lock.lock(); entries.removeAll(); lock.unlock() }
    func add(_ path: String, status: Int, bytes: Int64) {
        lock.lock(); entries.append(Entry(at: Date(), path: path, status: status, bytes: bytes)); lock.unlock()
    }
    var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }

    var manifestFetched: Bool { all.contains { $0.path.hasSuffix(".plist") && $0.status == 200 } }
    var ipaFetched: Bool { all.contains { $0.path.hasSuffix(".ipa") && $0.status == 200 } }
    var ipaBytes: Int64 { all.filter { $0.path.hasSuffix(".ipa") }.map(\.bytes).max() ?? 0 }

    /// Plain-English diagnosis of the last install attempt.
    func diagnosis(ipaSize: Int64) -> String {
        if all.isEmpty {
            return "installd never connected. iOS showed the sheet but couldn't reach https://\(ServerConfig.installHost) — usually TLS: the cert isn't trusted by installd (Certificate Trust Settings toggle off), or the host isn't resolving to 127.0.0.1 from installd's resolver."
        }
        if !manifestFetched {
            return "installd connected but never got the manifest. Check the OTA host matches the cert SANs exactly (see Certificate inspector)."
        }
        if !ipaFetched {
            return "Manifest delivered but the IPA was never downloaded. installd rejected the manifest — bundle-identifier / bundle-version mismatch with the IPA, or the display-image PNG failed."
        }
        if ipaBytes < ipaSize {
            return "IPA download was cut short (\(ByteCountFormatter.string(fromByteCount: ipaBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: ipaSize, countStyle: .file))). The server was torn down too early or the app was backgrounded mid-download."
        }
        return "installd downloaded the full IPA and then refused to install it. That is a signing/provisioning problem, not a delivery problem: (1) this device's UDID isn't in the .mobileprovision, (2) the profile or cert is expired/revoked, (3) an app with the same bundle ID is already installed from a different team — delete it first, or change the bundle ID in the sign sheet, or (4) the entitlements don't match the profile (try Strip content › remove extensions, or disable App Groups/iCloud in the profile)."
    }
}

// MARK: - Vapor HTTPS server

nonisolated struct InstallAppData: Sendable {
    var id: String
    var version: String
    var name: String
}

nonisolated final class LocalOTAServer: Identifiable, @unchecked Sendable {
    let id = UUID()
    let app: Application
    let package: URL
    let port = Int.random(in: 4000 ... 8000)
    let metadata: InstallAppData
    private var needsShutdown = false

    private static let env: Environment = {
        var env = Environment(name: "production", arguments: ["vapor"])
        try? LoggingSystem.bootstrap(from: &env)
        return env
    }()

    static func host() -> String { ServerConfig.installHost }

    /// `imageSmall` / `imageLarge` are precomputed PNGs (rendered by the caller on the main actor).
    init(package: URL, metadata: InstallAppData, imageSmall: Data, imageLarge: Data) throws {
        self.package  = package
        self.metadata = metadata

        let app = Application(Self.env)
        self.app = app
        app.threadPool = .init(numberOfThreads: 1)
        app.http.server.configuration.tlsConfiguration = try Self.tls()
        app.http.server.configuration.hostname   = Self.host()
        app.http.server.configuration.tcpNoDelay = true
        app.http.server.configuration.address    = .hostname("0.0.0.0", port: port)
        app.http.server.configuration.port       = port
        app.routes.defaultMaxBodySize = "512mb"

        let host = Self.host(), serverPort = port, ident = id.uuidString
        let pkg = package, meta = metadata
        let imgS = imageSmall, imgL = imageLarge

        func url(_ path: String) -> String { "https://\(host):\(serverPort)/\(path)" }
        let manifest: [String: Any] = [
            "items": [[
                "assets": [
                    ["kind": "software-package", "url": url("\(ident).ipa")],
                    ["kind": "display-image",    "url": url("app57x57.png")],
                    ["kind": "full-size-image",  "url": url("app512x512.png")],
                ],
                "metadata": [
                    "bundle-identifier": meta.id,
                    "bundle-version":    meta.version,
                    "kind":  "software",
                    "title": meta.name,
                ],
            ]],
        ]
        let manifestData = (try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: .zero)) ?? Data()

        let ipaSize = (try? FileManager.default.attributesOfItem(atPath: package.path)[.size] as? Int64) ?? 0
        OTATrace.shared.reset()
        app.get("*") { req -> Response in
            let path = req.url.path
            switch path {
            case "/ping":
                OTATrace.shared.add(path, status: 200, bytes: 4)
                return Response(status: .ok, body: .init(string: "pong"))
            case "/\(ident).plist":
                OTATrace.shared.add(path, status: 200, bytes: Int64(manifestData.count))
                return Response(status: .ok, version: req.version, headers: ["Content-Type": "text/xml"], body: .init(data: manifestData))
            case "/app57x57.png":
                OTATrace.shared.add(path, status: 200, bytes: Int64(imgS.count))
                return Response(status: .ok, version: req.version, headers: ["Content-Type": "image/png"], body: .init(data: imgS))
            case "/app512x512.png":
                OTATrace.shared.add(path, status: 200, bytes: Int64(imgL.count))
                return Response(status: .ok, version: req.version, headers: ["Content-Type": "image/png"], body: .init(data: imgL))
            case "/\(ident).ipa":
                // Range requests are how installd resumes; record whatever it asked for.
                OTATrace.shared.add(path, status: 200, bytes: ipaSize)
                return req.fileio.streamFile(at: pkg.path)
            default:
                OTATrace.shared.add(path, status: 404, bytes: 0)
                return Response(status: .notFound)
            }
        }

        try app.server.start()
        needsShutdown = true
    }

    var itmsServicesURL: URL {
        var c = URLComponents()
        c.scheme = "itms-services"
        c.path = "/"
        c.queryItems = [
            .init(name: "action", value: "download-manifest"),
            .init(name: "url", value: "https://\(Self.host()):\(port)/\(id.uuidString).plist"),
        ]
        return c.url!
    }

    private static func tls() throws -> TLSConfiguration {
        if ServerConfig.certMode == "local" {
            guard LocalCAManager.hasLeaf else { throw ZefvCert.CertError.unavailable }
            // The leaf private key lives only in the Keychain (ThisDeviceOnly,
            // never backed up). Materialize it to a private temp file just long
            // enough for NIOSSL to read it, then it's deleted.
            return try LocalCAManager.withLeafKeyFile { keyFile in
                try .makeServerConfiguration(
                    certificateChain: NIOSSLCertificate.fromPEMFile(LocalCAManager.leafCertURL.path).map { NIOSSLCertificateSource.certificate($0) },
                    privateKey: .privateKey(try NIOSSLPrivateKey(file: keyFile.path, format: .pem))
                )
            }
        }
        guard let crt = ZefvCert.crtURL, let key = ZefvCert.keyURL else { throw ZefvCert.CertError.unavailable }
        return try .makeServerConfiguration(
            certificateChain: NIOSSLCertificate.fromPEMFile(crt.path).map { NIOSSLCertificateSource.certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(file: key.path, format: .pem))
        )
    }

    func shutdown() {
        guard needsShutdown else { return }
        needsShutdown = false
        app.server.shutdown()
        app.shutdown()
    }
}
