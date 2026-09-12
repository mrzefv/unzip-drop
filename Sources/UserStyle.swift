//
//  UserStyle.swift
//  Registered-user cosmetics: username color, rainbow text, animated (GIF)
//  profile background. Persisted locally so the chip renders instantly at launch.
//

import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct UserStyle: Equatable, Sendable {
    var colorHex: String = ""      // "#RRGGBB" or ""
    var rainbow: Bool = false
    var gifURL: String = ""
    var fontName: String = ""      // "" = system; else a PostScript/family name from `fonts`
    var sizeStep: Int = 2          // 1 S · 2 M · 3 L · 4 XL
    var badges: [String] = []      // server-assigned: founder, verified, dev, top_signer, og, supporter

    static let badgeMeta: [String: (title: String, icon: String, color: Color)] = [
        "founder":    ("FOUNDER",    "crown.fill",            Color(red: 1.0, green: 0.84, blue: 0.0)),
        "verified":   ("VERIFIED",   "checkmark.seal.fill",   Color(red: 0.2, green: 0.6, blue: 1.0)),
        "dev":        ("DEV",        "hammer.fill",           Color(red: 0.2, green: 0.85, blue: 0.75)),
        "top_signer": ("TOP SIGNER", "signature",             Color(red: 1.0, green: 0.55, blue: 0.1)),
        "og":         ("OG",         "flame.fill",            Color(red: 1.0, green: 0.27, blue: 0.23)),
        "supporter":  ("SUPPORTER",  "heart.fill",            Color(red: 1.0, green: 0.4, blue: 0.7)),
    ]

    /// Fonts that ship on iOS (no bundling needed). Label → font name ("" = system).
    static let fonts: [(label: String, name: String)] = [
        ("System", ""), ("Rounded", "system-rounded"), ("Mono", "system-mono"), ("Serif", "system-serif"),
        ("Marker Felt", "MarkerFelt-Wide"), ("Chalkduster", "Chalkduster"), ("Noteworthy", "Noteworthy-Bold"),
        ("Bradley Hand", "BradleyHandITCTT-Bold"), ("Snell Roundhand", "SnellRoundhand-Black"), ("Zapfino", "Zapfino"),
        ("Papyrus", "Papyrus"), ("Copperplate", "Copperplate-Bold"), ("American Typewriter", "AmericanTypewriter-Bold"),
        ("Futura", "Futura-CondensedExtraBold"), ("Didot", "Didot-Bold"), ("Optima", "Optima-ExtraBlack"),
        ("Courier", "Courier-Bold"), ("Avenir Next", "AvenirNext-Heavy"), ("Georgia", "Georgia-Bold"), ("Menlo", "Menlo-Bold"),
    ]
    static let sizes: [(label: String, step: Int, scale: CGFloat)] = [("S", 1, 0.85), ("M", 2, 1.0), ("L", 3, 1.2), ("XL", 4, 1.45)]
    var scale: CGFloat { Self.sizes.first { $0.step == sizeStep }?.scale ?? 1 }
    var fontLabel: String { Self.fonts.first { $0.name == fontName }?.label ?? "System" }

    /// Font for the username at a given base size/weight, honouring the chosen family and size step.
    func font(base: CGFloat, weight: Font.Weight = .bold) -> Font {
        let size = base * scale
        switch fontName {
        case "":              return .system(size: size, weight: weight)
        case "system-rounded": return .system(size: size, weight: weight, design: .rounded)
        case "system-mono":    return .system(size: size, weight: weight, design: .monospaced)
        case "system-serif":   return .system(size: size, weight: weight, design: .serif)
        default:               return UIFont(name: fontName, size: size) != nil ? .custom(fontName, size: size) : .system(size: size, weight: weight)
        }
    }

    static let none = UserStyle()
    private static let key = "zefv_user_style"

    init() {}
    init(json: [String: Any]?) {
        colorHex = (json?["color"] as? String) ?? ""
        rainbow  = (json?["rainbow"] as? Bool) ?? ((json?["rainbow"] as? Int) == 1)
        gifURL   = (json?["gif"] as? String) ?? ""
        fontName = (json?["font"] as? String) ?? ""
        let st = (json?["size"] as? Int) ?? Int((json?["size"] as? String) ?? "") ?? 2
        sizeStep = min(max(st, 1), 4)
        badges = (json?["badges"] as? [String]) ?? []
    }
    static func load() -> UserStyle {
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return .none }
        return UserStyle(json: d)
    }
    func save() {
        UserDefaults.standard.set(["color": colorHex, "rainbow": rainbow, "gif": gifURL, "font": fontName, "size": sizeStep, "badges": badges], forKey: Self.key)
    }

    var color: Color? { colorHex.count == 7 ? Color(hex: String(colorHex.dropFirst())) : nil }
    var hasGIF: Bool { URL(string: gifURL) != nil && !gifURL.isEmpty }

    static let presets = ["#FF453A", "#FF9F0A", "#FFD60A", "#30D158", "#2ED9C3", "#64D2FF", "#0A84FF", "#BF5AF2", "#FF66B2", "#FFFFFF"]
}

// MARK: - Badges

struct BadgeRow: View {
    let badges: [String]
    var size: CGFloat = 9
    var body: some View {
        if !badges.isEmpty {
            HStack(spacing: 5) {
                ForEach(badges, id: \.self) { b in
                    if let m = UserStyle.badgeMeta[b] {
                        HStack(spacing: 3) {
                            Image(systemName: m.icon).font(.system(size: size, weight: .bold))
                            Text(m.title).font(.system(size: size, weight: .heavy, design: .monospaced)).kerning(0.6)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .foregroundStyle(m.color)
                        .background(m.color.opacity(0.16))
                        .overlay(Capsule().stroke(m.color.opacity(0.5), lineWidth: 1))
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

// MARK: - Other users' styles (public lookup, batched + cached)

@MainActor
final class RemoteStyleCache: ObservableObject {
    static let shared = RemoteStyleCache()
    struct Entry: Sendable { let style: UserStyle; let role: UserRole; let badges: [String] }
    @Published private(set) var entries: [String: Entry] = [:]   // key: lowercased username
    private var misses: Set<String> = []
    private var pending: Set<String> = []
    private var flushTask: Task<Void, Never>?

    func entry(_ username: String) -> Entry? { entries[username.lowercased()] }

    /// Looks like something that could be a registered username.
    nonisolated static func plausible(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.count <= 32 && t.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "." }
    }

    /// Queue a lookup; requests are batched (up to 50) and flushed after 150 ms.
    func request(_ username: String) {
        let k = username.lowercased()
        guard Self.plausible(username), entries[k] == nil, !misses.contains(k), !pending.contains(k) else { return }
        pending.insert(k)
        flushTask?.cancel()
        flushTask = Task { try? await Task.sleep(nanoseconds: 150_000_000); await flush() }
    }

    private func flush() async {
        let batch = Array(pending.prefix(50)); batch.forEach { pending.remove($0) }
        guard !batch.isEmpty else { return }
        var comps = URLComponents(string: ZefvAccount.defaultBase + "style.php")!
        comps.queryItems = [URLQueryItem(name: "usernames", value: batch.joined(separator: ","))]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { batch.forEach { misses.insert($0) }; return }
        var found: Set<String> = []
        for (name, v) in obj {
            guard let dict = v as? [String: Any] else { continue }
            var st = UserStyle(json: dict["style"] as? [String: Any])
            st.badges = (dict["badges"] as? [String]) ?? []
            let role = UserRole(rawValue: (dict["role"] as? String) ?? "member") ?? .member
            entries[name.lowercased()] = Entry(style: st, role: role, badges: st.badges)
            found.insert(name.lowercased())
        }
        for k in batch where !found.contains(k) { misses.insert(k) }
        if !pending.isEmpty { await flush() }
    }
}

/// A username that may belong to a registered user: renders their style/badges if so, plain text otherwise.
struct RemoteStyledName: View {
    let name: String
    var base: CGFloat = 13
    var weight: Font.Weight = .medium
    var fallback: Color = Theme.subtle
    var showBadges: Bool = false
    @ObservedObject private var cache = RemoteStyleCache.shared

    var body: some View {
        let e = cache.entry(name)
        HStack(spacing: 6) {
            if let e {
                StyledUsername(name: name, style: e.style, base: base, weight: weight, fallback: fallback)
                if showBadges { BadgeRow(badges: e.badges, size: 8) }
            } else {
                Text(name).font(.system(size: base, weight: weight)).foregroundStyle(fallback).lineLimit(1)
            }
        }
        .onAppear { cache.request(name) }
    }
}

// MARK: - Styled username

/// Renders a username in the user's chosen color/font/size, or as a full animated rainbow.
struct StyledUsername: View {
    let name: String
    var style: UserStyle
    var font: Font = .system(size: 15, weight: .bold)   // legacy — ignored when `base` is given
    var base: CGFloat? = nil                            // base point size; style.scale multiplies it
    var weight: Font.Weight = .bold
    var fallback: Color = Theme.text

    @State private var hue: Double = 0

    private var resolvedFont: Font { base.map { style.font(base: $0, weight: weight) } ?? font }
    private static let spectrum: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red]

    var body: some View {
        if style.rainbow {
            Text(name).font(resolvedFont)
                .foregroundStyle(LinearGradient(colors: Self.spectrum, startPoint: .leading, endPoint: .trailing))
                .hueRotation(.degrees(hue))
                .fixedSize()
                .onAppear { withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { hue = 360 } }
        } else {
            Text(name).font(resolvedFont).foregroundStyle(style.color ?? fallback).fixedSize()
        }
    }
}

// MARK: - Animated GIF

/// Decodes every frame with ImageIO and plays it in a UIImageView. Also fine for static png/jpg/webp.
struct AnimatedImageView: UIViewRepresentable {
    let url: URL
    var contentMode: UIView.ContentMode = .scaleAspectFill

    /// UIImageView reports the image's pixel size as intrinsic size, which would blow the layout open.
    final class FillImageView: UIImageView {
        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
    }

    func makeUIView(context: Context) -> FillImageView {
        let v = FillImageView()
        v.contentMode = contentMode
        v.clipsToBounds = true
        v.backgroundColor = .clear
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.load(url, into: v)
        return v
    }
    func updateUIView(_ v: FillImageView, context: Context) {
        if context.coordinator.url != url { context.coordinator.load(url, into: v) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var url: URL?
        private var task: Task<Void, Never>?

        func load(_ url: URL, into view: UIImageView) {
            self.url = url
            task?.cancel()
            task = Task { [weak view] in
                let data: Data
                if let cached = GIFCache.shared.data(for: url) { data = cached }
                else {
                    // Hard cap: a hostile GIF URL must not be able to eat someone's RAM. 8 MB, checked on headers and bytes.
                    guard let (d, r) = try? await URLSession.shared.data(from: url),
                          (r.expectedContentLength <= 0 || r.expectedContentLength <= 8 * 1024 * 1024),
                          d.count <= 8 * 1024 * 1024 else { return }
                    GIFCache.shared.store(d, for: url); data = d
                }
                let decoded = await Task.detached(priority: .userInitiated) { Self.decode(data) }.value
                guard !Task.isCancelled, let view else { return }
                view.stopAnimating()
                if decoded.frames.count > 1 {
                    view.animationImages = decoded.frames
                    view.animationDuration = decoded.duration
                    view.animationRepeatCount = 0
                    view.image = decoded.frames.first
                    view.startAnimating()
                } else {
                    view.animationImages = nil
                    view.image = decoded.frames.first
                }
            }
        }

        private nonisolated static func decode(_ data: Data) -> (frames: [UIImage], duration: TimeInterval) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return ([], 0) }
            let n = CGImageSourceGetCount(src)
            var frames: [UIImage] = []; var total: TimeInterval = 0
            // Downscale big GIFs so we don't hold hundreds of full-res frames.
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 720,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            for i in 0..<n {
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { continue }
                frames.append(UIImage(cgImage: cg))
                total += Self.delay(src, i)
            }
            return (frames, max(total, 0.1))
        }

        private nonisolated static func delay(_ src: CGImageSource, _ i: Int) -> TimeInterval {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
            let dict = (props[kCGImagePropertyGIFDictionary] as? [CFString: Any])
                ?? (props[kCGImagePropertyWebPDictionary] as? [CFString: Any])
                ?? (props[kCGImagePropertyPNGDictionary] as? [CFString: Any])
            let unclamped = (dict?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (dict?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
            let clamped = (dict?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? (dict?[kCGImagePropertyAPNGDelayTime] as? Double)
            let d = unclamped ?? clamped ?? 0.1
            return d < 0.02 ? 0.1 : d
        }
    }
}

/// Tiny in-memory + disk cache so the profile background doesn't refetch every open.
final class GIFCache: @unchecked Sendable {
    static let shared = GIFCache()
    private let mem = NSCache<NSURL, NSData>()
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("gif-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private func file(_ url: URL) -> URL { dir.appendingPathComponent(String(url.absoluteString.hashValue.magnitude)) }
    func data(for url: URL) -> Data? {
        if let d = mem.object(forKey: url as NSURL) { return d as Data }
        if let d = try? Data(contentsOf: file(url)) { mem.setObject(d as NSData, forKey: url as NSURL); return d }
        return nil
    }
    func store(_ d: Data, for url: URL) {
        mem.setObject(d as NSData, forKey: url as NSURL)
        try? d.write(to: file(url), options: .atomic)
    }
}

/// Profile-card backdrop: animated background (if set) under a dark scrim so text stays readable.
struct ProfileBackdrop: View {
    var style: UserStyle
    var body: some View {
        ZStack {
            // ZStack sizes to its non-GIF content; GeometryReader keeps the GIF inside that box.
            Theme.card
            if style.hasGIF, let u = URL(string: style.gifURL) {
                GeometryReader { g in
                    AnimatedImageView(url: u).frame(width: g.size.width, height: g.size.height).clipped()
                }
                LinearGradient(colors: [Color.black.opacity(0.25), Color.black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}
