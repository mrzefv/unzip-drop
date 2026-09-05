//
//  LocalOTAServer.swift
//  On-device OTA install the way full mSign does it: a Vapor HTTPS server on
//  the device (NIOSSL) serving an itms-services manifest + the signed IPA.
//
//  *.zefv.dev resolves to 127.0.0.1 and is covered by a Let's Encrypt wildcard
//  cert. The cert + key ship in the bundle (Sources/Resources/server.crt +
//  server.pem, straight from mSign) and are refreshed from
//  mrzefv.com/certs/pack.json before expiry. iOS trusts the chain, connects to
//  loopback as mr.zefv.dev, installs — no network needed for the install itself.
//

import Foundation
import Vapor
import NIOSSL

// MARK: - Config

nonisolated enum ServerConfig {
    /// SNI + manifest host. Must resolve to 127.0.0.1 and be covered by the cert (*.zefv.dev).
    static var installHost: String {
        UserDefaults.standard.string(forKey: "uzd_install_host") ?? "mr.zefv.dev"
    }
    static func setInstallHost(_ h: String) { UserDefaults.standard.set(h, forKey: "uzd_install_host") }

    /// Bundled Let's Encrypt pair from mSign (Sources/Resources):
    ///   server.crt ← fullchain.pem   server.pem ← privkey.pem
    static let certResource = "server"

    /// mSign's refresh endpoint. Real host (not a 127.0.0.1 domain). Serves
    ///   { "bundle": "<chain file>", "key": "<privkey file>", "expires": "<ISO8601>" }
    /// with filenames relative to the manifest's directory; certbot republishes them.
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

    /// Pull a fresh chain + key from mSign's pack.json and cache them.
    static func fetch() async throws -> Meta {
        var req = URLRequest(url: ServerConfig.refreshURL); req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw CertError.badPack("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        let m: Manifest
        do { m = try JSONDecoder().decode(Manifest.self, from: data) } catch { throw CertError.badPack("unreadable pack.json") }
        guard let keyFile = m.key, !keyFile.isEmpty else { throw CertError.badPack("pack.json has no \"key\" — the private key must be published for the on-device server.") }

        let base = ServerConfig.refreshURL.deletingLastPathComponent()
        func get(_ name: String) async throws -> Data {
            let u = name.hasPrefix("http") ? URL(string: name)! : base.appendingPathComponent(name)
            let (d, r) = try await URLSession.shared.data(from: u)
            guard (r as? HTTPURLResponse)?.statusCode ?? 0 < 400, !d.isEmpty else { throw CertError.badPack("couldn't download \(name)") }
            return d
        }
        let chain = try await get(m.bundle)
        let key = try await get(keyFile)

        // Validate before overwriting a working copy.
        _ = try NIOSSLCertificate.fromPEMBytes(Array(chain))
        _ = try NIOSSLPrivateKey(bytes: Array(key), format: .pem)

        try chain.write(to: cachedCrt, options: .atomic)
        try key.write(to: cachedKey, options: .atomic)

        let exp = m.expires.flatMap { ISO8601DateFormatter().date(from: $0) } ?? notAfter(fromPEM: chain)
        let meta = Meta(notAfter: exp, fetchedAt: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(meta).write(to: metaURL)
        return meta
    }

    @discardableResult
    static func refreshIfNeeded() async -> Meta? {
        guard needsRefresh else { return meta }
        return try? await fetch()
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

        app.get("*") { req -> Response in
            switch req.url.path {
            case "/ping":
                return Response(status: .ok, body: .init(string: "pong"))
            case "/\(ident).plist":
                return Response(status: .ok, version: req.version, headers: ["Content-Type": "text/xml"], body: .init(data: manifestData))
            case "/app57x57.png":
                return Response(status: .ok, version: req.version, headers: ["Content-Type": "image/png"], body: .init(data: imgS))
            case "/app512x512.png":
                return Response(status: .ok, version: req.version, headers: ["Content-Type": "image/png"], body: .init(data: imgL))
            case "/\(ident).ipa":
                return req.fileio.streamFile(at: pkg.path)
            default:
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
        guard let crt = ZefvCert.crtURL, let key = ZefvCert.keyURL else {
            throw ZefvCert.CertError.unavailable
        }
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
