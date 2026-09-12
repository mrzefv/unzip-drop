//
//  ZefvClient.swift
//  Account client for the VPS API (apii.zefv.dev). Registration/login are
//  OPTIONAL — the app works fully as a guest keyed on the device MDID. An
//  account links this MDID to a username + role so staff tools follow you
//  across reinstalls and devices.
//
//  All requests carry the shared X-OTA-Token (ServerConfig.certSourceToken).
//  The per-user session token is stored in the Keychain.
//

import Foundation

enum UsernameFontStyle: String, Codable, CaseIterable, Sendable {
    case `default`
    case rounded
    case monospaced
    case serif

    var title: String {
        switch self {
        case .default: return "Default"
        case .rounded: return "Rounded"
        case .monospaced: return "Monospaced"
        case .serif: return "Serif"
        }
    }
}

struct UsernameCustomization: Codable, Sendable {
    var colorHex: String
    var fontStyle: UsernameFontStyle
    var gifBackground: Bool

    static let `default` = UsernameCustomization(colorHex: "FFFFFF", fontStyle: .default, gifBackground: false)
}

@MainActor
final class ZefvAccount: ObservableObject {
    static let shared = ZefvAccount()

    @Published private(set) var username: String?
    @Published private(set) var email: String?
    @Published private(set) var role: UserRole = .member
    @Published private(set) var usernameCustomization: UsernameCustomization = .default
    @Published private(set) var busy = false
    @Published var lastError: String?
    @Published var panelShown = false

    private static let kSession  = "zefv_session_token"
    private static let kUsername = "zefv_username"
    private static let kCustomizationPrefix = "zefv_username_custom_"

    var isLoggedIn: Bool { username != nil }
    var sessionToken: String? { Keychain.get(Self.kSession) }

    private init() {
        username = Keychain.get(Self.kUsername)
        if let raw = Keychain.get("zefv_role"), let r = UserRole(rawValue: raw) { role = r }
        loadCustomization(for: username)
    }

    // MARK: - Endpoint base — the PHP account API lives on apii (api.zefv.dev is a router)

    nonisolated static let defaultBase = "https://apii.zefv.dev/"
    private func base() -> URL? {
        let v = UserDefaults.standard.string(forKey: "uzd_account_base") ?? ""
        return URL(string: v.isEmpty ? Self.defaultBase : v)
    }
    private func endpoint(_ path: String) -> URL? { base()?.appendingPathComponent(path) }

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        guard let url = endpoint(path), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw Err.badURL }
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let u = c.url else { throw Err.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        let (d, r) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 { throw Err.server((obj["error"] as? String) ?? "Server error (\(code))") }
        return obj
    }

    private func post(_ path: String, _ payload: [String: Any]) async throws -> [String: Any] {
        guard let url = endpoint(path) else { throw Err.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (d, r) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 { throw Err.server((obj["error"] as? String) ?? "Server error (\(code))") }
        return obj
    }

    // MARK: - Actions

    func register(username u: String, password p: String) async -> Bool {
        await run { try await self.post("register.php", ["username": u, "password": p, "mdid": MDID.current]) }
    }
    func login(username u: String, password p: String) async -> Bool {
        await run { try await self.post("login.php", ["username": u, "password": p, "mdid": MDID.current]) }
    }

    private func run(_ call: @escaping () async throws -> [String: Any]) async -> Bool {
        busy = true; lastError = nil; defer { busy = false }
        do {
            let o = try await call()
            guard let tok = o["token"] as? String, let name = o["username"] as? String else {
                lastError = "Malformed response"; return false
            }
            let r = UserRole(rawValue: (o["role"] as? String) ?? "member") ?? .member
            _ = Keychain.set(Self.kSession, tok)
            _ = Keychain.set(Self.kUsername, name)
            _ = Keychain.set("zefv_role", r.rawValue)
            username = name; role = r
            loadCustomization(for: name)
            await StaffGate.shared.refresh()
            return true
        } catch { lastError = (error as? Err)?.message ?? error.localizedDescription; return false }
    }

    /// Pull username/role/email for the stored session; clears the session if the server rejects it.
    func refreshProfile() async {
        guard let tok = sessionToken, !tok.isEmpty else { return }
        do {
            let o = try await get("account.php", ["token": tok])
            if let name = o["username"] as? String {
                username = name
                _ = Keychain.set(Self.kUsername, name)
                loadCustomization(for: name)
            }
            email = (o["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let r = UserRole(rawValue: (o["role"] as? String) ?? "member") ?? .member
            role = r; _ = Keychain.set("zefv_role", r.rawValue)
            await StaffGate.shared.refresh()
        } catch let e as Err {
            if case .server(let m) = e, m.lowercased().contains("session") { await clearLocal() }
            lastError = e.message
        } catch { lastError = error.localizedDescription }
    }

    func setEmail(_ e: String) async -> Bool {
        guard let tok = sessionToken else { return false }
        busy = true; lastError = nil; defer { busy = false }
        do { _ = try await post("account.php", ["action": "set_email", "token": tok, "email": e]); email = e.isEmpty ? nil : e; return true }
        catch { lastError = (error as? Err)?.message ?? error.localizedDescription; return false }
    }

    func changePassword(current: String, new n: String) async -> Bool {
        guard let tok = sessionToken else { return false }
        busy = true; lastError = nil; defer { busy = false }
        do { _ = try await post("account.php", ["action": "change_password", "token": tok, "current_password": current, "new_password": n]); return true }
        catch { lastError = (error as? Err)?.message ?? error.localizedDescription; return false }
    }

    private func clearLocal() async {
        _ = Keychain.set(Self.kSession, "")
        _ = Keychain.set(Self.kUsername, "")
        _ = Keychain.set("zefv_role", "")
        username = nil; email = nil; role = .member
        usernameCustomization = .default
    }

    func logout() async {
        if let tok = sessionToken { _ = try? await post("account.php", ["action": "logout", "token": tok]) }
        await clearLocal()
    }

    func updateUsernameCustomization(colorHex: String? = nil,
                                     fontStyle: UsernameFontStyle? = nil,
                                     gifBackground: Bool? = nil) -> Bool {
        guard let name = username, !name.isEmpty else { return false }
        var next = usernameCustomization
        if let colorHex, let normalized = Self.normalizeHex(colorHex) { next.colorHex = normalized }
        if let fontStyle { next.fontStyle = fontStyle }
        if let gifBackground { next.gifBackground = gifBackground }
        usernameCustomization = next
        saveCustomization(next, for: name)
        return true
    }

    private func saveCustomization(_ customization: UsernameCustomization, for username: String) {
        guard !username.isEmpty, let data = try? JSONEncoder().encode(customization) else { return }
        UserDefaults.standard.set(data, forKey: customizationKey(for: username))
    }

    private func loadCustomization(for username: String?) {
        guard let username, !username.isEmpty else {
            usernameCustomization = .default
            return
        }
        guard let data = UserDefaults.standard.data(forKey: customizationKey(for: username)),
              let customization = try? JSONDecoder().decode(UsernameCustomization.self, from: data) else {
            usernameCustomization = .default
            return
        }
        usernameCustomization = customization
    }

    private func customizationKey(for username: String) -> String {
        Self.kCustomizationPrefix + username.lowercased()
    }

    private static func normalizeHex(_ value: String) -> String? {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard hex.count == 6, Int(hex, radix: 16) != nil else { return nil }
        return hex
    }

    enum Err: Error { case badURL, server(String)
        var message: String { switch self { case .badURL: return "Bad URL"; case .server(let m): return m } }
    }
}
