//
//  ZefvClient.swift
//  Client for the zefv.dev API. Handles register/login/session, profile
//  reads and edits, MDID device linking, and IPA uploads that produce
//  ready-to-tap `itms-services://` install URLs against the user's
//  own `slug.zefv.dev` subdomain.
//
//  Auth model:
//    * Username + password creates an account. The MDID (see MDID.swift)
//      is linked as a device — a user can log in from another phone with
//      the same username/password and that phone's MDID gets added to
//      their account too.
//    * A session token is returned on register/login and cached in the
//      local Keychain. All authenticated calls send it as X-Auth-Token.
//    * MDID + a device-name hint are sent on register/login only.
//

import Foundation
import UIKit

// MARK: - API models

nonisolated struct ZefvUser: Codable, Sendable, Equatable {
    let username:          String
    let display_name:      String?
    let xp:                Int
    let level:             Int
    let xp_current_level:  Int
    let xp_next_level:     Int
    let rank:              Int
    let rank_name:         String
    let quota_bytes:       Int
    let bytes_used:        Int
    let style:             ZefvStyle
    let created_at:        Int?

    /// Convenience: the public URL for this user's OTA endpoint.
    var subdomainURL: URL? { URL(string: "https://\(username).zefv.dev/") }
}

nonisolated struct ZefvStyle: Codable, Sendable, Equatable {
    /// Solid hex like `#00d0aa` (ranks 0–2).
    let color:         String?
    /// Two+ hex stops for a linear gradient (rank 3).
    let gradient:      [String]?
    /// `"rainbow"` or `"rainbow_glow"` (ranks 4–5).
    let animated:      String?
    /// `"regular"` or `"bold"`.
    let weight:        String?
    /// `"none"`, `"gradient"`, `"animated_hue"`, `"animated_hue_glow"`.
    let effect:        String?
    /// Only for rank 5 admins with a custom emoji set.
    let emoji_prefix:  String?
}

nonisolated struct ZefvUploadResult: Codable, Sendable, Equatable {
    let ipa_url:      String
    let plist_url:    String
    let install_url:  String     // itms-services://...
    let size_bytes:   Int
    let user:         ZefvUser
}

nonisolated struct ZefvUploadEntry: Codable, Sendable, Equatable, Identifiable {
    let filename:       String
    let bundle_id:      String
    let version:        String?
    let display_name:   String?
    let size_bytes:     Int
    let install_count:  Int
    let uploaded_at:    Int
    let ipa_url:        String
    let plist_url:      String
    let install_url:    String

    var id: String { bundle_id }
}

nonisolated struct ZefvRank: Codable, Sendable, Equatable, Identifiable {
    let rank:          Int
    let name:          String
    let min_level:     Int
    let quota_mb:      Int
    let min_slug_len:  Int
    let style_preview: ZefvStyle

    var id: Int { rank }
}

nonisolated struct ZefvDevice: Codable, Sendable, Equatable, Identifiable {
    let mdid:           String
    let device_name:    String?
    let first_seen_at:  Int
    let last_seen_at:   Int
    var id: String { mdid }
}

nonisolated struct ZefvCheckUsername: Codable, Sendable {
    let available:   Bool
    let reason:      String?
    let min_length:  Int?
}

// MARK: - Errors

nonisolated struct ZefvError: Error, LocalizedError {
    let status:  Int
    let message: String
    var errorDescription: String? {
        status == 0 ? message : "\(status): \(message)"
    }
}

// MARK: - Client

@MainActor
final class ZefvClient: ObservableObject {
    static let shared = ZefvClient()

    /// Base URL of the API. Change if you migrate to a different host.
    static let baseURL = URL(string: "https://api.zefv.dev")!

    // Published so SwiftUI views can observe login state changes.
    @Published private(set) var currentUser: ZefvUser?
    @Published private(set) var isAuthenticated: Bool = false

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {
        // Seed the login state from the local Keychain on init so views
        // can show the right UI immediately — /me is called after to
        // refresh the actual user object.
        isAuthenticated = (token?.isEmpty == false)
        if isAuthenticated {
            Task { try? await refresh() }
        }
    }

    // MARK: Token storage (per-device — deliberately NOT iCloud-synced)

    private static let tokenKey = "zefv-auth-token"

    var token: String? {
        get {
            let raw = Keychain.get(Self.tokenKey)
            return (raw?.isEmpty == false) ? raw : nil
        }
        set {
            if let v = newValue, !v.isEmpty {
                Keychain.set(Self.tokenKey, v)
            } else {
                Keychain.set(Self.tokenKey, "")
            }
            isAuthenticated = (newValue?.isEmpty == false)
            if !isAuthenticated { currentUser = nil }
        }
    }

    // MARK: - Auth

    /// Registers a new account. The MDID for this device is linked as
    /// the first device on the account.
    @discardableResult
    func register(username: String, password: String, displayName: String? = nil) async throws -> ZefvUser {
        struct Req: Codable { let username: String; let password: String; let display_name: String? }
        struct Resp: Codable { let token: String; let user: ZefvUser }
        let r: Resp = try await send(
            "POST", "/register",
            body: Req(username: username, password: password, display_name: displayName),
            authenticated: false,
            deviceHeaders: true
        )
        self.token = r.token
        self.currentUser = r.user
        return r.user
    }

    /// Log in as an existing user. If this device's MDID is not already
    /// linked to the account it will be added.
    @discardableResult
    func login(username: String, password: String) async throws -> ZefvUser {
        struct Req: Codable { let username: String; let password: String }
        struct Resp: Codable { let token: String; let user: ZefvUser }
        let r: Resp = try await send(
            "POST", "/login",
            body: Req(username: username, password: password),
            authenticated: false,
            deviceHeaders: true
        )
        self.token = r.token
        self.currentUser = r.user
        return r.user
    }

    /// Revoke the current session token on the server, then wipe locally.
    func logout() async {
        struct Empty: Codable {}
        _ = try? await send("POST", "/logout", body: Empty(), authenticated: true, deviceHeaders: false) as Empty
        self.token = nil
    }

    /// Refresh the cached user profile from /me. Throws + logs out on 401.
    @discardableResult
    func refresh() async throws -> ZefvUser {
        struct Resp: Codable { let user: ZefvUser }
        do {
            let r: Resp = try await send("GET", "/me", body: Optional<String>.none, authenticated: true)
            self.currentUser = r.user
            return r.user
        } catch let e as ZefvError where e.status == 401 {
            self.token = nil
            throw e
        }
    }

    // MARK: - Profile

    /// Update display name and (rank ≥ 5) custom emoji.
    @discardableResult
    func updateProfile(displayName: String? = nil, customEmoji: String? = nil) async throws -> ZefvUser {
        struct Req: Encodable { var display_name: String?; var custom_emoji: String? }
        struct Resp: Codable { let user: ZefvUser }
        let r: Resp = try await send(
            "PATCH", "/me",
            body: Req(display_name: displayName, custom_emoji: customEmoji),
            authenticated: true
        )
        self.currentUser = r.user
        return r.user
    }

    /// Rename the account. Rank-gated on the server (short names require
    /// higher ranks — see `/ranks`). Also moves the user's on-server
    /// directory so their subdomain URL changes.
    @discardableResult
    func rename(to newUsername: String) async throws -> ZefvUser {
        struct Req: Codable { let username: String }
        struct Resp: Codable { let user: ZefvUser }
        let r: Resp = try await send(
            "POST", "/me/rename",
            body: Req(username: newUsername),
            authenticated: true
        )
        self.currentUser = r.user
        return r.user
    }

    /// Change password. Server revokes all OTHER sessions on success —
    /// current session (this device) stays active.
    func changePassword(current: String, new: String) async throws {
        struct Req: Codable { let current_password: String; let new_password: String }
        struct Resp: Codable { let changed: Bool }
        _ = try await send(
            "POST", "/change-password",
            body: Req(current_password: current, new_password: new),
            authenticated: true
        ) as Resp
    }

    /// Pre-flight username availability check (no auth required).
    func checkUsername(_ username: String) async throws -> ZefvCheckUsername {
        struct Req: Codable { let username: String }
        return try await send("POST", "/check-username",
                              body: Req(username: username),
                              authenticated: false)
    }

    // MARK: - Devices

    /// List every MDID linked to this account.
    func devices() async throws -> [ZefvDevice] {
        struct Resp: Codable { let devices: [ZefvDevice] }
        let r: Resp = try await send("GET", "/me/devices", body: Optional<String>.none, authenticated: true)
        return r.devices
    }

    // MARK: - Ranks (public)

    /// Rank definitions for in-app previews / tier upgrade UI.
    func ranks() async throws -> [ZefvRank] {
        struct Resp: Codable { let ranks: [ZefvRank] }
        let r: Resp = try await send("GET", "/ranks", body: Optional<String>.none, authenticated: false)
        return r.ranks
    }

    // MARK: - Uploads

    /// List the current user's IPAs on the server.
    func uploads() async throws -> [ZefvUploadEntry] {
        struct Resp: Codable { let uploads: [ZefvUploadEntry] }
        let r: Resp = try await send("GET", "/uploads", body: Optional<String>.none, authenticated: true)
        return r.uploads
    }

    /// Delete a specific upload by bundle id.
    func deleteUpload(bundleID: String) async throws {
        let path = "/uploads/" + (bundleID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bundleID)
        struct Resp: Codable { let deleted: String }
        _ = try await send("DELETE", path, body: Optional<String>.none, authenticated: true) as Resp
    }

    /// Upload a signed IPA. Returns the ready-to-open install URL.
    ///
    /// The server auto-generates the accompanying `manifest.plist` and
    /// serves both files from `slug.zefv.dev/<safeBundle>.ipa|.plist`
    /// with a valid `*.zefv.dev` Let's Encrypt cert.
    ///
    /// The multipart body is assembled on a background task (a 200 MB IPA
    /// would otherwise stall the main actor for seconds). `onProgress` is
    /// always invoked on the main actor.
    func upload(ipaURL: URL,
                bundleID: String,
                version: String,
                name: String,
                onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> ZefvUploadResult {
        guard let tok = token, !tok.isEmpty else {
            throw ZefvError(status: 401, message: "Not signed in")
        }

        let boundary = "----zefv-\(UUID().uuidString)"
        let mdid     = MDID.current        // read on main actor before hopping off

        // Assemble the multipart body on disk, off the main actor.
        let tmpBody = try await Task.detached(priority: .userInitiated) {
            try Self.buildMultipartBody(
                ipaURL: ipaURL, bundleID: bundleID, version: version, name: name,
                boundary: boundary
            ) { p in
                // Hop back to main for UI progress. Fire-and-forget is fine —
                // progress is advisory.
                if let onProgress {
                    Task { @MainActor in onProgress(p * 0.95) }   // reserve 5% for server ack
                }
            }
        }.value
        defer { try? FileManager.default.removeItem(at: tmpBody) }

        var req = URLRequest(url: Self.baseURL.appendingPathComponent("upload"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(tok,  forHTTPHeaderField: "X-Auth-Token")
        req.setValue(mdid, forHTTPHeaderField: "X-MDID")

        // upload(for:fromFile:) streams from disk without loading into memory.
        let (data, response) = try await session.upload(for: req, fromFile: tmpBody)
        try Self.throwIfErrorStatus(response, data: data)

        onProgress?(1.0)

        let result = try decoder.decode(ZefvUploadResult.self, from: data)
        self.currentUser = result.user   // XP was awarded — update in place
        return result
    }

    /// Writes a multipart/form-data body to a temp file and returns its URL.
    /// Runs nonisolated so it can be called from a detached task. The IPA is
    /// streamed in 1 MB chunks so memory stays flat regardless of IPA size.
    nonisolated private static func buildMultipartBody(
        ipaURL: URL, bundleID: String, version: String, name: String,
        boundary: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws -> URL {
        let tmpBody = FileManager.default.temporaryDirectory
            .appendingPathComponent("zefv-upload-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: tmpBody.path, contents: nil)

        guard let out = try? FileHandle(forWritingTo: tmpBody) else {
            throw ZefvError(status: 0, message: "Couldn't create upload buffer")
        }
        defer { try? out.close() }

        func write(_ s: String) throws { try out.write(contentsOf: Data(s.utf8)) }
        func field(_ n: String, _ v: String) throws {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(n)\"\r\n\r\n")
            try write("\(v)\r\n")
        }

        try field("bundle_id", bundleID)
        try field("version",   version)
        try field("name",      name)

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"ipa\"; filename=\"app.ipa\"\r\n")
        try write("Content-Type: application/octet-stream\r\n\r\n")

        guard let inp = try? FileHandle(forReadingFrom: ipaURL) else {
            throw ZefvError(status: 0, message: "Couldn't open IPA at \(ipaURL.path)")
        }
        defer { try? inp.close() }

        let total = (try? FileManager.default.attributesOfItem(atPath: ipaURL.path)[.size] as? Int) ?? 0
        var written = 0
        let chunk = 1024 * 1024
        while let d = try? inp.read(upToCount: chunk), !d.isEmpty {
            try out.write(contentsOf: d)
            written += d.count
            if total > 0 { onProgress(min(1.0, Double(written) / Double(total))) }
        }

        try write("\r\n--\(boundary)--\r\n")
        try out.synchronize()
        return tmpBody
    }

    // MARK: - Convenience

    /// Open the install URL — iOS handles the `itms-services://` scheme
    /// and prompts the user to install. Must be called on the main actor.
    func openInstall(_ installURL: String) {
        guard let u = URL(string: installURL) else { return }
        UIApplication.shared.open(u)
    }

    // MARK: - Low-level HTTP

    private func send<T: Decodable, B: Encodable>(
        _ method: String, _ path: String,
        body: B?, authenticated: Bool, deviceHeaders: Bool = false
    ) async throws -> T {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        req.httpMethod = method
        if authenticated {
            guard let tok = token, !tok.isEmpty else {
                throw ZefvError(status: 401, message: "Not signed in")
            }
            req.setValue(tok, forHTTPHeaderField: "X-Auth-Token")
        }
        if deviceHeaders {
            req.setValue(MDID.current, forHTTPHeaderField: "X-MDID")
            req.setValue(MDID.deviceName, forHTTPHeaderField: "X-Device-Name")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: req)
        try Self.throwIfErrorStatus(response, data: data)

        // For endpoints that return no body / empty JSON, decode leniently.
        if data.isEmpty, let empty = try? decoder.decode(T.self, from: Data("{}".utf8)) {
            return empty
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // Include the raw body in the message so debugging isn't blind.
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ZefvError(status: 0, message: "Decode failed: \(error.localizedDescription) — body: \(body.prefix(200))")
        }
    }

    private static func throwIfErrorStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ZefvError(status: 0, message: "Non-HTTP response")
        }
        guard http.statusCode >= 400 else { return }
        // API returns {"error": "..."} on failures.
        let msg: String = {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let m = obj["error"] as? String { return m }
            return String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        }()
        throw ZefvError(status: http.statusCode, message: msg)
    }
}
