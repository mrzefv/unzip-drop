//
//  MV1ELiveClient.swift
//  Receives live UIView-hierarchy captures pushed by the injected mv1E Live dylib —
//  via the VPS relay (apii.zefv.dev/flex) or a local HTTP URL on the same Wi-Fi.
//

import Foundation

nonisolated struct LiveNode: Decodable, Identifiable {
    let cls: String
    let x: Double, y: Double, w: Double, h: Double
    let alpha: Double
    let hidden: Bool
    let depth: Int
    let text: String?
    let png: String?            // base64 PNG snapshot (optional)
    let children: [LiveNode]
    var id: String { "\(cls)-\(x)-\(y)-\(w)-\(h)-\(depth)" }

    private enum CodingKeys: String, CodingKey {
        case cls = "class", x, y, w, h, alpha, hidden, depth, text, png, children
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        cls = try c.decodeIfPresent(String.self, forKey: .cls) ?? "UIView"
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 0
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 0
        alpha = try c.decodeIfPresent(Double.self, forKey: .alpha) ?? 1
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text)
        png = try c.decodeIfPresent(String.self, forKey: .png)
        children = try c.decodeIfPresent([LiveNode].self, forKey: .children) ?? []
    }
}

nonisolated struct LiveCapture: Decodable {
    let bundle: String
    let app: String?
    let ts: Double?
    let screen: Screen?
    let root: LiveNode
    struct Screen: Decodable { let w: Double; let h: Double }
}

nonisolated struct LiveIndexEntry: Decodable, Identifiable {
    let bundle: String; let app: String; let ts: Double
    var id: String { bundle }
}

nonisolated enum MV1ELive {

    /// Base derived from the cert source (…/ota/cert.php → …/flex).
    private static func endpoint(_ file: String) -> URL? {
        guard let base = URL(string: ServerConfig.certSourceURL) else { return nil }
        return base.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("flex").appendingPathComponent(file)
    }
    private static func req(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url); r.timeoutInterval = 20; r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        return r
    }

    /// List captures the VPS currently holds.
    static func index() async -> [LiveIndexEntry] {
        guard let u = endpoint("pull.php"),
              let (d, r) = try? await URLSession.shared.data(for: req(u)),
              ((r as? HTTPURLResponse)?.statusCode ?? 0) < 400,
              let dict = try? JSONDecoder().decode([String: LiveIndexEntry].self, from: d)
        else { return [] }
        return dict.values.sorted { ($0.ts) > ($1.ts) }
    }

    /// Fetch the latest capture for a bundle from the VPS.
    static func fetch(bundle: String) async throws -> LiveCapture {
        guard var comps = endpoint("pull.php").map({ URLComponents(url: $0, resolvingAgainstBaseURL: false)! }) else {
            throw URLError(.badURL)
        }
        comps.queryItems = [URLQueryItem(name: "bundle", value: bundle)]
        let (d, resp) = try await URLSession.shared.data(for: req(comps.url!))
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 400 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(LiveCapture.self, from: d)
    }

    /// Fetch a capture from a local HTTP URL (dylib's on-device listener).
    static func fetchLocal(urlString: String) async throws -> LiveCapture {
        guard let u = URL(string: urlString) else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.timeoutInterval = 8
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 400 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(LiveCapture.self, from: d)
    }

    /// Flatten a tree into (node, index) for rendering.
    static func flatten(_ root: LiveNode) -> [LiveNode] {
        var out: [LiveNode] = []
        func walk(_ n: LiveNode) { out.append(n); n.children.forEach(walk) }
        walk(root)
        return out
    }
}
