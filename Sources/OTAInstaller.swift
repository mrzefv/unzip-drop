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
import ZIPFoundation

@MainActor
final class OTAInstaller: ObservableObject {
    static let shared = OTAInstaller()
    private init() {}

    private var current: LocalOTAServer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    /// Result of the last install attempt, filled ~25s after the sheet opens.
    struct Report: Identifiable, Sendable {
        let id = UUID()
        let requests: [OTATrace.Entry]
        let diagnosis: String
        let profileNote: String?
        var delivered: Bool { requests.contains { $0.path.hasSuffix(".ipa") } }
    }
    @Published var lastReport: Report?
    @Published var tracing = false

    enum InstallError: LocalizedError {
        case ipaMissing, openFailed
        case hostNotCovered(host: String, mode: String, sans: [String])
        case noLocalLeaf(host: String)
        case hostNotLoopback(host: String)

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
            case .hostNotLoopback(let h):
                return "\(h) doesn't resolve to 127.0.0.1, so iOS silently drops the install prompt — there's no error dialog for this, it just never appears. Point a DNS A record for \(h) at 127.0.0.1, or use a free loopback name (e.g. 127-0-0-1.nip.io). Check it in Settings › Local CA / OTA Domain."
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

        // Loopback DNS is required in BOTH modes — iOS shows no error, it just
        // silently drops the install prompt if the host can't be resolved to
        // 127.0.0.1. Check it up front so the failure is at least explainable.
        if let loop = await ZefvCert.resolvesToLoopback(host), loop == false {
            throw InstallError.hostNotLoopback(host: host)
        }

        if mode == "local" {
            guard LocalCAManager.hasLeaf else { throw InstallError.noLocalLeaf(host: host) }
            // Auto-reissue when within 30 days of the 397-day cap (iOS TLS limit).
            if LocalCAManager.reissueIfNeeded() { /* fresh leaf issued */ }
            guard LocalCAManager.covers(host) else {
                throw InstallError.hostNotCovered(host: host, mode: mode, sans: LocalCAManager.leafSANs())
            }
        } else if mode == "custom" {
            guard ZefvCert.hasCustom else { throw ZefvCert.CertError.badPack("No custom cert imported yet — Settings › On-Device OTA Domain › Own TLS cert.") }
            let sans = ZefvCert.customSANs
            guard ZefvCert.covers(host, sans: sans) else {
                throw InstallError.hostNotCovered(host: host, mode: mode, sans: sans)
            }
        } else {
            // Near expiry: pull the freshly renewed pair from the VPS (no-op offline; cached/bundled pair still works).
            if ZefvCert.needsRefresh { await ZefvCert.refreshIfNeeded() }
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

        lastReport = nil; tracing = true
        let opened = await UIApplication.shared.open(server.itmsServicesURL)
        guard opened else { tearDown(); tracing = false; throw InstallError.openFailed }

        let ipaSize = (try? FileManager.default.attributesOfItem(atPath: ipaURL.path)[.size] as? Int64) ?? 0
        let activeCertName = CertificateStore.shared.active?.name
        let profileNote = Self.profileNote(ipaURL: ipaURL, certName: activeCertName)

        // Give installd time to fetch manifest + IPA, then report what it did.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25 * 1_000_000_000)
            guard let self else { return }
            let t = OTATrace.shared
            self.lastReport = Report(requests: t.all, diagnosis: t.diagnosis(ipaSize: ipaSize), profileNote: profileNote)
            self.tracing = false
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            if let self, self.current === server { self.tearDown() }
        }
    }

    /// Reads embedded.mobileprovision out of the signed IPA and reports the facts
    /// that most often cause "Unable to Install": device count, expiry, team, entitlements.
    private static func profileNote(ipaURL: URL, certName: String?) -> String? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("prof-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.unzipItem(at: ipaURL, to: work)
            let payload = work.appendingPathComponent("Payload", isDirectory: true)
            guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else { return nil }
            let prov = app.appendingPathComponent("embedded.mobileprovision")
            guard let data = try? Data(contentsOf: prov) else { return "No embedded.mobileprovision in the signed app — installd will refuse it." }
            let info = CertificateStore.profileInfo(data)
            var parts: [String] = []
            if let n = info.name { parts.append("Profile: \(n)") }
            if let t = info.team { parts.append("Team: \(t)") }
            if let e = info.expires {
                let d = Calendar.current.dateComponents([.day], from: Date(), to: e).day ?? 0
                parts.append(d < 0 ? "⚠️ Profile EXPIRED \(-d)d ago" : "Profile expires in \(d)d")
            }
            if info.udids.isEmpty {
                parts.append("Profile has no device list → Enterprise/in-house (any device OK, needs 'trust developer' in Settings) — or a broken profile.")
            } else {
                let udid = CertificateStore.knownUDID(certName: certName)
                switch CertificateStore.profileIncludesDevice(info, udid: udid) {
                case .some(true):  parts.append("✅ This device (\(udid!)) IS in the profile's \(info.udids.count) device(s). UDID is not the problem.")
                case .some(false): parts.append("❌ This device (\(udid!)) is NOT in the profile's \(info.udids.count) device(s) — that's the install failure. Regenerate the profile with this UDID on the developer portal and re-import it.")
                case .none:        parts.append("Profile lists \(info.udids.count) device(s). Enter your UDID in Settings › Certificates to check it definitively.")
                }
            }
            let bundleID = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String ?? "?"
            parts.append("Signed bundle ID: \(bundleID). If any app with this ID is already installed from a different team, delete it first.")
            return parts.joined(separator: "\n")
        } catch { return nil }
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
