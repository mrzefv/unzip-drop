//
//  StaffGate.swift
//  Server-decided role gate. The list of staff device IDs lives on the VPS
//  (apii.zefv.dev/roles/check.php) — never in the IPA, so it can't be pulled out
//  of the binary. The app sends its stable device token; the server returns the
//  role. Result is cached in the Keychain with a short TTL so it works briefly
//  offline and re-verifies when back online.
//

import Foundation

nonisolated final class StaffGate: ObservableObject {
    static let shared = StaffGate()

    @Published private(set) var isStaff: Bool = StaffGate.cachedRole()

    private static let kRole = "uzd_role_staff"
    private static let kWhen = "uzd_role_ts"
    private static let ttl: TimeInterval = 24 * 3600      // trust cache for a day offline

    /// Cached decision (Keychain-backed, survives reinstall on same device via iCloud KC).
    private static func cachedRole() -> Bool {
        guard let v = Keychain.get(kRole) else { return false }
        if let ts = Keychain.get(kWhen).flatMap({ Double($0) }),
           Date().timeIntervalSince1970 - ts > ttl { return false }   // stale → treat as non-staff until re-check
        return v == "1"
    }

    private func cache(_ staff: Bool) {
        _ = Keychain.set(Self.kRole, staff ? "1" : "0")
        _ = Keychain.set(Self.kWhen, String(Date().timeIntervalSince1970))
    }

    /// VPS endpoint derived from the cert source (…/ota/cert.php → …/roles/check.php).
    private func endpoint() -> URL? {
        guard let base = URL(string: ServerConfig.certSourceURL) else { return nil }
        return base.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("roles").appendingPathComponent("check.php")
    }

    /// Re-check the role with the server. Silent on failure (keeps last cached value).
    func refresh() async {
        guard let u = endpoint() else { return }
        var comps = URLComponents(url: u, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "mdid", value: MDID.current)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              ((r as? HTTPURLResponse)?.statusCode ?? 0) < 400,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let roleStr = (o["role"] as? String)?.lowercased() ?? "member"
        let parsed: UserRole = roleStr == "admin" ? .admin : (roleStr == "developer" || roleStr == "staff" ? .developer : .member)
        let staff = (o["staff"] as? Bool) ?? parsed.isElevated
        await MainActor.run {
            self.isStaff = staff; self.role = staff ? (parsed == .member ? .developer : parsed) : .member
            self.cache(staff); _ = Keychain.set(Self.kRoleName, self.role.rawValue)
        }
    }

    /// The device id staff should send you to be allow-listed.
    var deviceID: String { MDID.current }
}
