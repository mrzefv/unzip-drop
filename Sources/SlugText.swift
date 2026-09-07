//
//  SlugText.swift
//  SwiftUI renderer for a zefv.dev username that respects the ZefvStyle
//  metadata returned by the API. Rank determines the effect:
//    Rookie/Verified/Trusted → solid color, optional bold
//    Elite   → horizontal gradient
//    Legend  → animated rainbow hue cycle
//    Admin   → animated rainbow + glow + optional emoji prefix
//

import SwiftUI

struct SlugText: View {
    let username: String
    let style: ZefvStyle
    /// Font size — defaults to 17pt (body). Callers override for headers, badges, etc.
    var size: CGFloat = 17
    /// If true, prefix with an @ sign for social-media style rendering.
    var showAtSign: Bool = false

    @State private var hueOffset: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            if let emoji = style.emoji_prefix, !emoji.isEmpty {
                Text(emoji).font(font)
            }
            renderedText
        }
        .onAppear { startAnimationIfNeeded() }
    }

    // MARK: - Text rendering

    @ViewBuilder private var renderedText: some View {
        let base = Text(showAtSign ? "@\(username)" : username).font(font)

        switch effect {
        case .none:
            base.foregroundStyle(solidColor)

        case .gradient:
            base.foregroundStyle(gradientFill)

        case .animatedHue:
            base.foregroundStyle(rainbowFill)

        case .animatedHueGlow:
            base
                .foregroundStyle(rainbowFill)
                .shadow(color: glowColor, radius: 6, x: 0, y: 0)
                .shadow(color: glowColor.opacity(0.6), radius: 12, x: 0, y: 0)
        }
    }

    // MARK: - Fill styles

    private var solidColor: Color {
        if let hex = style.color, let c = Color(zefvHex: hex) { return c }
        return .primary
    }

    private var gradientFill: LinearGradient {
        let stops: [Color] = (style.gradient ?? []).compactMap { Color(zefvHex: $0) }
        let colors = stops.isEmpty ? [.primary, .primary] : stops
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    private var rainbowFill: LinearGradient {
        // 6-stop rainbow shifted by hueOffset (0…1). Wraps for continuity.
        let n = 6
        let stops: [Color] = (0..<n).map { i in
            let h = (Double(i) / Double(n - 1) + hueOffset).truncatingRemainder(dividingBy: 1.0)
            return Color(hue: h, saturation: 0.95, brightness: 1.0)
        }
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }

    private var glowColor: Color {
        if let hex = style.color, let c = Color(zefvHex: hex) { return c }
        // Fallback: pick the middle of the rainbow.
        return Color(hue: (0.5 + hueOffset).truncatingRemainder(dividingBy: 1.0),
                     saturation: 0.9, brightness: 1.0)
    }

    // MARK: - Effect enum (parsed from ZefvStyle.effect)

    private enum Effect { case none, gradient, animatedHue, animatedHueGlow }

    private var effect: Effect {
        switch style.effect ?? "" {
        case "gradient":          return .gradient
        case "animated_hue":      return .animatedHue
        case "animated_hue_glow": return .animatedHueGlow
        default:                  return .none
        }
    }

    private var font: Font {
        let weight: Font.Weight = (style.weight == "bold") ? .bold : .regular
        return .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: - Animation

    private func startAnimationIfNeeded() {
        guard effect == .animatedHue || effect == .animatedHueGlow else { return }
        withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
            hueOffset = 1.0
        }
    }
}

// MARK: - Hex color init (namespaced so it can't collide with an
// existing `Color(hex:)` elsewhere in the project)

extension Color {
    /// Parses `#RRGGBB` or `#AARRGGBB`. Case-insensitive; leading `#` optional.
    init?(zefvHex: String) {
        var s = zefvHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            a = Double((v >> 24) & 0xFF) / 255
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >>  8) & 0xFF) / 255
            b = Double( v        & 0xFF) / 255
        } else {
            a = 1.0
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >>  8) & 0xFF) / 255
            b = Double( v        & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Convenience initializers

extension SlugText {
    /// Render straight from a `ZefvUser`.
    init(_ user: ZefvUser, size: CGFloat = 17, showAtSign: Bool = false) {
        self.username = user.username
        self.style    = user.style
        self.size     = size
        self.showAtSign = showAtSign
    }

    /// Preview a specific rank without an actual user (used in rank-upgrade screens).
    init(preview username: String, rank: ZefvRank, size: CGFloat = 17) {
        self.username = username
        self.style    = rank.style_preview
        self.size     = size
        self.showAtSign = false
    }
}

// MARK: - Rank chip (small pill next to the username)

struct RankChip: View {
    let user: ZefvUser
    var body: some View {
        Text(user.rank_name.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .kerning(0.6)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(fg)
            .background(bg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(fg.opacity(0.4), lineWidth: 1))
    }
    private var accent: Color {
        if let hex = user.style.color, let c = Color(zefvHex: hex) { return c }
        if let hexes = user.style.gradient, let first = hexes.first, let c = Color(zefvHex: first) { return c }
        return .primary
    }
    private var fg: Color { user.rank >= 3 ? .white : accent }
    private var bg: Color { user.rank >= 3 ? accent.opacity(0.35) : accent.opacity(0.15) }
}

// MARK: - XP progress bar (level N → N+1)

struct XPProgress: View {
    let user: ZefvUser
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Level \(user.level)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(user.xp) / \(user.xp_next_level) XP")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let span    = max(1, user.xp_next_level - user.xp_current_level)
                let filled  = max(0, user.xp - user.xp_current_level)
                let frac    = min(1.0, Double(filled) / Double(span))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(fillStyle)
                        .frame(width: proxy.size.width * frac)
                }
            }
            .frame(height: 6)
        }
    }
    private var fillStyle: some ShapeStyle {
        if let hexes = user.style.gradient, hexes.count >= 2 {
            let stops = hexes.compactMap { Color(zefvHex: $0) }
            return AnyShapeStyle(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
        }
        if let hex = user.style.color, let c = Color(zefvHex: hex) {
            return AnyShapeStyle(c)
        }
        return AnyShapeStyle(Color.accentColor)
    }
}
