//
//  StaffGate.swift
//  Server-decided role gate. The list of staff device IDs lives on the VPS
//  (apii.zefv.dev/roles_check.php) — never in the IPA, so it can't be pulled out
//  of the binary. The app sends its stable device token; the server returns the
//  role. Result is cached in the Keychain with a short TTL so it works briefly
//  offline and re-verifies when back online.
//

import Foundation

@MainActor
final class StaffGate: ObservableObject {
    static let shared = StaffGate()

    @Published private(set) var isStaff: Bool = StaffGate.cachedStaff()
    @Published private(set) var role: UserRole = StaffGate.cachedRole()

    nonisolated private static let kRole     = "uzd_role_staff"
    nonisolated private static let kRoleName = "uzd_role_name"
    nonisolated private static let kWhen     = "uzd_role_ts"
    nonisolated private static let ttl: TimeInterval = 24 * 3600      // trust cache for a day offline

    private init() {}

    /// The device id staff should send you to be allow-listed.
    nonisolated var deviceID: String { MDID.current }
    nonisolated var mdid: String { MDID.current }

    // MARK: - Keychain cache

    nonisolated private static func cacheFresh() -> Bool {
        guard let ts = Keychain.get(kWhen).flatMap({ Double($0) }) else { return true }
        return Date().timeIntervalSince1970 - ts <= ttl          // stale → treat as non-staff until re-check
    }

    /// Cached staff decision (Keychain-backed, survives reinstall on same device).
    nonisolated private static func cachedStaff() -> Bool {
        guard let v = Keychain.get(kRole), cacheFresh() else { return false }
        return v == "1"
    }

    /// Cached role name; falls back to `.member` when missing or stale.
    nonisolated private static func cachedRole() -> UserRole {
        guard cacheFresh(), let raw = Keychain.get(kRoleName), let r = UserRole(rawValue: raw) else { return .member }
        return r
    }

    private func cache(staff: Bool, role: UserRole) {
        _ = Keychain.set(Self.kRole, staff ? "1" : "0")
        _ = Keychain.set(Self.kRoleName, role.rawValue)
        _ = Keychain.set(Self.kWhen, String(Date().timeIntervalSince1970))
    }

    // MARK: - Server check

    /// Roles endpoint. Lives on apii (the PHP account API), not the api.zefv.dev
    /// router. Override with UserDefaults "uzd_roles_url" if it ever moves.
    nonisolated static let defaultRolesURL = "https://apii.zefv.dev/roles/check.php"
    nonisolated private func endpoint() -> URL? {
        let v = UserDefaults.standard.string(forKey: "uzd_roles_url") ?? ""
        return URL(string: v.isEmpty ? Self.defaultRolesURL : v)
    }

    /// Re-check the role with the server. Silent on failure (keeps last cached value).
    func refresh() async {
        guard let u = endpoint(),
              var comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return }
        comps.queryItems = [URLQueryItem(name: "mdid", value: MDID.current)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              ((r as? HTTPURLResponse)?.statusCode ?? 0) < 400,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let roleStr = (o["role"] as? String)?.lowercased() ?? "member"
        let parsed: UserRole = roleStr == "admin" ? .admin
            : (roleStr == "developer" || roleStr == "staff" ? .developer : .member)
        let staff = (o["staff"] as? Bool) ?? parsed.isElevated
        let resolved: UserRole = staff ? (parsed == .member ? .developer : parsed) : .member
        isStaff = staff
        role = resolved
        cache(staff: staff, role: resolved)
    }
}
