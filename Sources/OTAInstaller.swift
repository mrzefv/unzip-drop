//
//  OTAInstaller.swift
//  Serves a locally-signed IPA over the on-device Vapor HTTPS server
//  (zefv.dev cert) and hands iOS the itms-services URL. Keeps the server
//  alive under a background task for the ~90s installd needs.
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
        case ipaMissing, openFailed, hostNotCovered(String, [String])
        var errorDescription: String? {
            switch self {
            case .hostNotCovered(let h, let sans):
                return "The loaded cert doesn't cover \(h) (it covers \(sans.isEmpty ? "nothing readable" : sans.joined(separator: ", "))). Set the OTA domain to match, or renew a cert for it in Settings › OTA Domain."
            case .ipaMissing: return "Signed IPA not found on disk."
            case .openFailed: return "iOS refused the itms-services URL. Check the OTA host resolves to 127.0.0.1 and is covered by the zefv.dev cert."
            }
        }
    }

    func install(_ app: SignedEntry) async throws {
        let icon = app.iconURL.flatMap { try? Data(contentsOf: $0) }
        try await install(ipaURL: app.ipaURL, bundleID: app.bundleID, name: app.name, version: app.version, iconData: icon)
    }

    func install(ipaURL: URL, bundleID: String, name: String, version: String, iconData: Data?) async throws {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else { throw InstallError.ipaMissing }

        // Near expiry: pull a fresh chain from mrzefv.com (no-op offline; bundled pair still works).
        if ZefvCert.needsRefresh { await ZefvCert.refreshIfNeeded(token: Keychain.get("gh_token")) }
        guard ZefvCert.isAvailable else { throw ZefvCert.CertError.unavailable }
        let sans = ZefvCert.effectiveSANs
        guard ZefvCert.covers(ServerConfig.installHost, sans: sans) else {
            throw InstallError.hostNotCovered(ServerConfig.installHost, sans)
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
