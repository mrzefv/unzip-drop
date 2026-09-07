//
//  OTAInstaller.swift
//  Serves a locally-signed IPA over the on-device Vapor HTTPS server and hands
//  iOS the itms-services URL. Keeps the server alive under a background task
//  for the ~90s installd needs.
//
//  Cert source follows ServerConfig.certMode:
//    "public" → the ACME (zefv.dev-style) cert, refreshed from the certs repo.
//    "local"  → our own root CA's leaf (LocalCAManager) — no network needed,
//               covers whatever host it was last issued for.
//  The "does this cert actually cover this host" check reads whichever cert
//  is active for the current mode, so a public-cert host mismatch never gets
//  reported while you're on Local, and vice versa.
//

import Foundation
import UIKit

@MainActor
final class OTAInstaller {
    static let shared = OTAInstaller()
    private init() {}

    private var current: LocalOTAServer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    enum InstallError: LocalizedError {
        case ipaMissing, openFailed
        case hostNotCovered(host: String, mode: String, sans: [String])
        case noLocalLeaf(host: String)

        var errorDescription: String? {
            switch self {
            case .hostNotCovered(let h, let mode, let sans):
                let covering = sans.isEmpty ? "nothing readable" : sans.joined(separator: ", ")
                if mode == "local" {
                    return "Your local leaf covers \(covering) — not \(h). Settings › Local CA: set host to \(h) and Re-issue leaf (instant, no profile needed again)."
                }
                return "The loaded ACME cert covers \(covering) — not \(h). Set the OTA domain to match, or renew a cert for it in Settings › OTA Domain. Or switch Cert mode to Fully local."
            case .noLocalLeaf(let h):
                return "Cert mode is Fully local but no leaf has been issued yet. Settings › Local CA: create the CA and issue a leaf for \(h)."
            case .ipaMissing: return "Signed IPA not found on disk."
            case .openFailed:
                return "iOS refused the itms-services URL. Check the OTA host resolves to 127.0.0.1 and matches the active cert (see Settings › OTA Domain — Active cert)."
            }
        }
    }

    func install(_ app: SignedEntry) async throws {
        let icon = app.iconURL.flatMap { try? Data(contentsOf: $0) }
        try await install(ipaURL: app.ipaURL, bundleID: app.bundleID, name: app.name, version: app.version, iconData: icon)
    }

    func install(ipaURL: URL, bundleID: String, name: String, version: String, iconData: Data?) async throws {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else { throw InstallError.ipaMissing }

        let host = ServerConfig.installHost
        let mode = ServerConfig.certMode

        if mode == "local" {
            guard LocalCAManager.hasLeaf else { throw InstallError.noLocalLeaf(host: host) }
            guard LocalCAManager.covers(host) else {
                throw InstallError.hostNotCovered(host: host, mode: mode, sans: LocalCAManager.leafSANs())
            }
        } else {
            // Near expiry: pull a fresh chain from the certs repo (no-op offline; bundled pair still works).
            if ZefvCert.needsRefresh { await ZefvCert.refreshIfNeeded(token: Keychain.get("gh_token")) }
            guard ZefvCert.isAvailable else { throw ZefvCert.CertError.unavailable }
            let sans = ZefvCert.effectiveSANs
            guard ZefvCert.covers(host, sans: sans) else {
                throw InstallError.hostNotCovered(host: host, mode: mode, sans: sans)
            }
        }

        let icon57  = Self.squarePNG(iconData, side: 57)
        let icon512 = Self.squarePNG(iconData, side: 512)

        tearDown()
        let server = try LocalOTAServer(package: ipaURL,
                                        metadata: InstallAppData(id: bundleID, version: version, name: name),
                                        imageSmall: icon57, imageLarge: icon512)
        current = server

        bgTask = UIApplication.shared.beginBackgroundTask(withName: "ota-install") { [weak self] in
            self?.tearDown()
        }

        let opened = await UIApplication.shared.open(server.itmsServicesURL)
        guard opened else { tearDown(); throw InstallError.openFailed }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            if let self, self.current === server { self.tearDown() }
        }
    }

    private func tearDown() {
        current?.shutdown(); current = nil
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    /// Square PNG for the manifest (installd wants valid PNGs); dark tile if no icon.
    private static func squarePNG(_ data: Data?, side: CGFloat) -> Data {
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if let data, let img = UIImage(data: data) { img.draw(in: CGRect(origin: .zero, size: size)) }
        }.pngData() ?? Data()
    }
}
