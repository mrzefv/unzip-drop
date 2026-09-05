//
//  LocalOTAServer.swift
//  On-device OTA install the way full mSign does it: a Vapor HTTPS server on
//  the device (NIOSSL) serving an itms-services manifest + the signed IPA,
//  fronted by backloop.dev.
//
//  backloop.dev: every *.backloop.dev name resolves to 127.0.0.1 and the
//  operator publishes the matching wildcard cert + private key. We fetch that
//  pack, cache it in Documents, refresh it before expiry, and present it as
//  DELvEK.backloop.dev. iOS trusts the chain, connects to loopback, installs.
//  No backend of ours involved.
//

import Foundation
import Vapor
import NIOSSL

// MARK: - Config

nonisolated enum ServerConfig {
    /// SNI + manifest host. Must be a *.backloop.dev label (resolves to 127.0.0.1).
    static var installHost: String {
        UserDefaults.standard.string(forKey: "uzd_install_host") ?? "DELvEK.backloop.dev"
    }
    static func setInstallHost(_ h: String) { UserDefaults.standard.set(h, forKey: "uzd_install_host") }

    /// pack.json lists cert / ca / key filenames relative to this directory (Feather / mSign layout).
    static let packURL = URL(string: "https://backloop.dev/pack.json")!
    static let refreshBufferDays = 14
}

// MARK: - Cert pack (fetch + cache)

nonisolated enum BackloopCert {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var crtURL: URL { docs.appendingPathComponent("backloop-server.crt") }
    static var keyURL: URL { docs.appendingPathComponent("backloop-server.pem") }
    static var metaURL: URL { docs.appendingPathComponent("backloop-cert.json") }

    static var hasCached: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: crtURL.path) && fm.fileExists(atPath: keyURL.path)
    }

    /// Optional offline fallback: put backloop's files at Sources/Resources/server.crt + server.pem.
    static var bundledCrt: URL? { Bundle.main.url(forResource: "server", withExtension: "crt") }
    static var bundledKey: URL? { Bundle.main.url(forResource: "server", withExtension: "pem") }

    static var effectiveCrt: URL? { hasCached ? crtURL : bundledCrt }
    static var effectiveKey: URL? { hasCached ? keyURL : bundledKey }
    static var isAvailable: Bool { effectiveCrt != nil && effectiveKey != nil }

    struct Meta: Codable, Sendable {
        var commonName: String?
        var notAfter: Date?
        var fetchedAt: Date
    }

    static var meta: Meta? {
        guard let d = try? Data(contentsOf: metaURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Meta.self, from: d)
    }

    static var needsRefresh: Bool {
        guard hasCached, let m = meta else { return true }
        guard let exp = m.notAfter else { return Date().timeIntervalSince(m.fetchedAt) > 30 * 86400 }
        return exp.timeIntervalSinceNow < TimeInterval(ServerConfig.refreshBufferDays * 86400)
    }

    enum CertError: LocalizedError {
        case unavailable, badPack(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "No backloop.dev certificate yet. Go online once and tap Refresh in Settings › OTA Domain."
            case .badPack(let m): return "backloop.dev cert pack: \(m)"
            }
        }
    }

    /// Tolerant pack.json: Feather/mSign layout {cert, ca, key, info.domains.commonName}
    /// plus {bundle|fullchain, key|privkey} variants. Filenames resolve relative to the pack URL.
    private struct Pack: Decodable {
        var cert: String?; var bundle: String?; var fullchain: String?
        var ca: String?
        var key: String?; var privkey: String?
        var info: Info?
        struct Info: Decodable { var domains: Domains?; struct Domains: Decodable { var commonName: String? } }
        var certName: String? { cert ?? bundle ?? fullchain }
        var keyName: String? { key ?? privkey }
    }

    /// Download the pack and write crt (fullchain) + key into Documents.
    static func fetch() async throws -> Meta {
        let base = ServerConfig.packURL.deletingLastPathComponent()
        var req = URLRequest(url: ServerConfig.packURL); req.cachePolicy = .reloadIgnoringLocalCacheData
        let (packData, _) = try await URLSession.shared.data(for: req)
        let pack: Pack
        do { pack = try JSONDecoder().decode(Pack.self, from: packData) }
        catch { throw CertError.badPack("unreadable pack.json") }
        guard let certName = pack.certName, let keyName = pack.keyName else { throw CertError.badPack("missing cert/key entries") }

        func get(_ name: String) async throws -> Data {
            let u = name.hasPrefix("http") ? URL(string: name)! : base.appendingPathComponent(name)
            let (d, r) = try await URLSession.shared.data(from: u)
            guard (r as? HTTPURLResponse)?.statusCode ?? 0 < 400, !d.isEmpty else { throw CertError.badPack("couldn't download \(name)") }
            return d
        }

        var chain = try await get(certName)
        if let ca = pack.ca, !ca.isEmpty, let caData = try? await get(ca) {
            let chainText = String(decoding: chain, as: UTF8.self)
            let caText = String(decoding: caData, as: UTF8.self)
            if !chainText.contains(caText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if chain.last != 0x0A { chain.append(0x0A) }
                chain.append(caData)                      // leaf + intermediate → fullchain
            }
        }
        let key = try await get(keyName)

        // Must parse before we overwrite a working cached copy.
        _ = try NIOSSLCertificate.fromPEMBytes(Array(chain))
        _ = try NIOSSLPrivateKey(bytes: Array(key), format: .pem)

        try chain.write(to: crtURL, options: .atomic)
        try key.write(to: keyURL, options: .atomic)

        let m = Meta(commonName: pack.info?.domains?.commonName, notAfter: notAfter(fromPEM: chain), fetchedAt: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(m).write(to: metaURL)
        return m
    }

    /// Refresh only when missing or near expiry. Silent no-op offline.
    @discardableResult
    static func refreshIfNeeded() async -> Meta? {
        guard needsRefresh else { return meta }
        return try? await fetch()
    }

    static func clearCache() {
        for u in [crtURL, keyURL, metaURL] { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: notAfter from the leaf cert (minimal DER walk)

    private static func notAfter(fromPEM pem: Data) -> Date? {
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
        guard let crt = BackloopCert.effectiveCrt, let key = BackloopCert.effectiveKey else {
            throw BackloopCert.CertError.unavailable
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
