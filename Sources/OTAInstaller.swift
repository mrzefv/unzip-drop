//
//  OTAInstaller.swift
//  Installs a locally-signed IPA over the air. Three cert/transport modes,
//  selected by ServerConfig.certMode:
//
//    "zefv"   → (DEFAULT) upload to the zefv.dev VPS via ZefvClient, then
//               open the itms-services URL it hands back. The VPS presents
//               its own *.zefv.dev Let's Encrypt cert; no cert material on
//               the phone, no loopback DNS, works on cellular. Requires a
//               zefv.dev account (Settings › zefv.dev Account).
//
//    "local"  → on-device Vapor HTTPS server using our own root CA's leaf
//               (LocalCAManager). No network needed but the install host
//               must resolve to 127.0.0.1 and the root profile must be
//               trusted. Legacy path.
//
//    "public" → on-device Vapor HTTPS server using the ACME cert bundled
//               from the certs branch. Also needs loopback DNS. Legacy —
//               *.zefv.dev now resolves to the VPS, so this mode only works
//               with a custom domain pointed at 127.0.0.1.
//
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

    /// Result of the last install attempt, filled ~25s after the sheet opens
    /// (local/public) or immediately after the upload completes (zefv).
    struct Report: Identifiable, Sendable {
        let id = UUID()
        let requests: [OTATrace.Entry]
        let diagnosis: String
        let profileNote: String?
        /// Local/public: did installd fetch the .ipa? zefv: did the upload succeed?
        let delivered: Bool
        /// zefv mode only — the public install URL the user can share.
        let installURL: String?

        init(requests: [OTATrace.Entry], diagnosis: String, profileNote: String?,
             delivered: Bool? = nil, installURL: String? = nil) {
            self.requests    = requests
            self.diagnosis   = diagnosis
            self.profileNote = profileNote
            self.delivered   = delivered ?? requests.contains { $0.path.hasSuffix(".ipa") }
            self.installURL  = installURL
        }
    }
    @Published var lastReport: Report?
    @Published var tracing = false
    /// 0…1 while a zefv upload is in flight; nil otherwise.
    @Published var uploadProgress: Double?

    enum InstallError: LocalizedError {
        case ipaMissing, openFailed
        case hostNotCovered(host: String, mode: String, sans: [String])
        case noLocalLeaf(host: String)
        case hostNotLoopback(host: String)
        case zefvNotSignedIn
        case zefvUploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .hostNotCovered(let h, let mode, let sans):
                let covering = sans.isEmpty ? "nothing readable" : sans.joined(separator: ", ")
                if mode == "local" {
                    return "Your local leaf covers \(covering) — not \(h). Settings › Local CA: set host to \(h) and Re-issue leaf (instant, no profile needed again)."
                }
                return "The loaded ACME cert covers \(covering) — not \(h). Set the OTA domain to match, or renew a cert for it in Settings › OTA Domain. Or switch Cert mode to zefv.dev."
            case .noLocalLeaf(let h):
                return "Cert mode is Fully local but no leaf has been issued yet. Settings › Local CA: create the CA and issue a leaf for \(h)."
            case .hostNotLoopback(let h):
                return "\(h) doesn't resolve to 127.0.0.1, so iOS silently drops the install prompt — there's no error dialog for this, it just never appears. Local/Public modes need loopback DNS. Switch Cert mode to zefv.dev (Settings › OTA Domain) to install through the VPS instead."
            case .ipaMissing: return "Signed IPA not found on disk."
            case .openFailed:
                return "iOS refused the itms-services URL. Check the OTA host resolves correctly and matches the active cert (see Settings › OTA Domain — Active cert)."
            case .zefvNotSignedIn:
                return "Cert mode is zefv.dev but you're not signed in. Settings › zefv.dev Account: sign in or register, then try again. Or switch Cert mode to Fully local."
            case .zefvUploadFailed(let msg):
                return "Upload to zefv.dev failed: \(msg)"
            }
        }
    }

    func install(_ app: SignedEntry) async throws {
        let icon = app.iconURL.flatMap { try? Data(contentsOf: $0) }
        try await install(ipaURL: app.ipaURL, bundleID: app.bundleID, name: app.name, version: app.version, iconData: icon)
    }

    func install(ipaURL: URL, bundleID: String, name: String, version: String, iconData: Data?) async throws {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else { throw InstallError.ipaMissing }

        let mode = ServerConfig.certMode
        if mode == "zefv" {
            try await installViaZefv(ipaURL: ipaURL, bundleID: bundleID, name: name, version: version)
        } else {
            try await installViaLocalServer(ipaURL: ipaURL, bundleID: bundleID, name: name, version: version,
                                            iconData: iconData, mode: mode)
        }
    }

    // MARK: - zefv.dev (VPS) path

    private func installViaZefv(ipaURL: URL, bundleID: String, name: String, version: String) async throws {
        let client = ZefvClient.shared
        guard client.isAuthenticated else { throw InstallError.zefvNotSignedIn }

        tearDown()                       // never leave a stale local server around
        lastReport = nil
        tracing = true
        uploadProgress = 0
        defer { uploadProgress = nil }

        let result: ZefvUploadResult
        do {
            result = try await client.upload(
                ipaURL: ipaURL, bundleID: bundleID, version: version, name: name,
                onProgress: { [weak self] p in self?.uploadProgress = p }
            )
        } catch let e as ZefvError {
            tracing = false
            throw InstallError.zefvUploadFailed(e.message)
        } catch {
            tracing = false
            throw InstallError.zefvUploadFailed(error.localizedDescription)
        }

        let activeCertName = CertificateStore.shared.active?.name
        let profileNote = Self.profileNote(ipaURL: ipaURL, certName: activeCertName)

        guard let url = URL(string: result.install_url) else {
            tracing = false
            throw InstallError.openFailed
        }
        let opened = await UIApplication.shared.open(url)
        tracing = false
        guard opened else { throw InstallError.openFailed }

        lastReport = Report(
            requests: [],
            diagnosis: "Uploaded \(Self.byteString(result.size_bytes)) to \(result.user.username).zefv.dev. iOS is fetching the manifest + IPA from the VPS — the install prompt should be on your home screen. If nothing appears, check the profile note below.",
            profileNote: profileNote,
            delivered: true,
            installURL: result.install_url
        )
    }

    // MARK: - On-device Vapor path (local / public, legacy)

    private func installViaLocalServer(ipaURL: URL, bundleID: String, name: String, version: String,
                                       iconData: Data?, mode: String) async throws {
        let host = ServerConfig.installHost

        // Loopback DNS is required in BOTH legacy modes — iOS shows no error, it
        // just silently drops the install prompt if the host can't be resolved
        // to 127.0.0.1. Check it up front so the failure is at least explainable.
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

    // MARK: - Helpers

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

    private static func byteString(_ n: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var v = Double(n); var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: v < 10 && i > 0 ? "%.1f %@" : "%.0f %@", v, units[i])
    }
}
