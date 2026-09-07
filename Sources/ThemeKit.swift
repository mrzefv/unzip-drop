//
//  ThemeKit.swift
//  App-wide theme: live accent color, dark-mode toggle, and an animated
//  background that renders behind every tab. Driven by ThemeManager
//  (an ObservableObject) so changing the accent updates the whole app live.
//
//  Ported to match the web plugin (msign.party color wheel) — same 6
//  backgrounds (None / Particles / Trailing Balls / Matrix / Binary Rain /
//  Confetti), same 5 particle shapes, same 8 presets, same #FF8800 default.
//

import SwiftUI

// MARK: - Theme store

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var accentHex: String {
        didSet {
            UserDefaults.standard.set(accentHex, forKey: "theme_accent_hex")
            Theme.setAccentColor(hex: accentHex)
        }
    }
    @Published var darkMode: Bool {
        didSet { UserDefaults.standard.set(darkMode, forKey: "theme_dark_mode") }
    }
    @Published var background: BackgroundStyle {
        didSet { UserDefaults.standard.set(background.rawValue, forKey: "theme_bg_style") }
    }
    @Published var particleShape: ParticleShape {
        didSet { UserDefaults.standard.set(particleShape.rawValue, forKey: "theme_particle_shape") }
    }

    // MARK: - Background styles (mirrors the web plugin's `cw-bg-*` set)

    enum BackgroundStyle: String, CaseIterable, Identifiable {
        case none     = "None"
        case particles = "Particles"
        case balls    = "Trailing Balls"
        case matrix   = "Matrix"
        case binary   = "Binary Rain"
        case confetti = "Confetti"

        var id: String { rawValue }

        /// SF Symbol for the small tile in the picker row on the left.
        var icon: String {
            switch self {
            case .none:      return "circle.slash"
            case .particles: return "sparkles"
            case .balls:     return "circle.hexagongrid.fill"
            case .matrix:    return "square.grid.3x3.fill"
            case .binary:    return "chevron.left.forwardslash.chevron.right"
            case .confetti:  return "party.popper.fill"
            }
        }
    }

    // MARK: - Particle shape (only applies when background == .particles)

    enum ParticleShape: String, CaseIterable, Identifiable {
        case circle, square, triangle, star, diamond
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .circle:   return "circle.fill"
            case .square:   return "square.fill"
            case .triangle: return "triangle.fill"
            case .star:     return "star.fill"
            case .diamond:  return "diamond.fill"
            }
        }
    }

    var accent: Color { Color(hex: accentHex) }

    /// Presets — matches the web plugin's swatches exactly.
    static let presets: [String] = [
        "#FF8800", "#FF3B5C", "#A855F7", "#3B82F6",
        "#10B981", "#F59E0B", "#EF4444", "#06B6D4",
    ]

    private init() {
        // Default accent matches the web plugin: #FF8800
        accentHex = UserDefaults.standard.string(forKey: "theme_accent_hex") ?? "#FF8800"
        darkMode  = UserDefaults.standard.object(forKey: "theme_dark_mode") as? Bool ?? true
        background = BackgroundStyle(rawValue: UserDefaults.standard.string(forKey: "theme_bg_style") ?? "") ?? .particles
        particleShape = ParticleShape(rawValue: UserDefaults.standard.string(forKey: "theme_particle_shape") ?? "") ?? .circle
    }
}

// MARK: - Animated background dispatcher

struct ParticleBackground: View {
    var accent: Color
    var style: ThemeManager.BackgroundStyle
    // Kept as an environment observer so a shape change re-renders particles.
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black
            switch style {
            case .none:
                EmptyView()
            case .particles:
                ParticleField(color: accent, shape: theme.particleShape)
            case .balls:
                TrailingBallsField(color: accent)
            case .matrix:
                MatrixField(color: accent)
            case .binary:
                BinaryRainField(color: accent)
            case .confetti:
                ConfettiField(color: accent)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Shape drawing helper

/// Draws a filled shape centred at `center` with the given `size` into a
/// GraphicsContext, matching the web plugin's `drawShape(name, size)` function.
private func drawParticleShape(_ ctx: inout GraphicsContext,
                               shape: ThemeManager.ParticleShape,
                               center: CGPoint,
                               size: CGFloat,
                               color: Color,
                               opacity: Double,
                               rotation: Double) {
    ctx.drawLayer { layer in
        layer.translateBy(x: center.x, y: center.y)
        layer.rotate(by: .radians(rotation))
        let r = size / 2
        var path = Path()
        switch shape {
        case .circle:
            path.addEllipse(in: CGRect(x: -r, y: -r, width: size, height: size))
        case .square:
            path.addRect(CGRect(x: -r, y: -r, width: size, height: size))
        case .triangle:
            path.move(to: CGPoint(x: 0, y: -r))
            path.addLine(to: CGPoint(x: r * 0.866, y: r * 0.5))
            path.addLine(to: CGPoint(x: -r * 0.866, y: r * 0.5))
            path.closeSubpath()
        case .star:
            let spikes = 5
            for s in 0..<(spikes * 2) {
                let radius: CGFloat = (s % 2 == 0) ? r : r * 0.45
                let ang = (.pi / Double(spikes)) * Double(s) - .pi / 2
                let px = CGFloat(cos(ang)) * radius
                let py = CGFloat(sin(ang)) * radius
                if s == 0 { path.move(to: CGPoint(x: px, y: py)) }
                else      { path.addLine(to: CGPoint(x: px, y: py)) }
            }
            path.closeSubpath()
        case .diamond:
            path.move(to: CGPoint(x: 0, y: -r))
            path.addLine(to: CGPoint(x: r, y: 0))
            path.addLine(to: CGPoint(x: 0, y: r))
            path.addLine(to: CGPoint(x: -r, y: 0))
            path.closeSubpath()
        }
        layer.fill(path, with: .color(color.opacity(opacity)))
    }
}

// MARK: - Particles

/// particles.js-style constellation: floating particles of a chosen shape
/// with faint lines connecting nearby pairs.
struct ParticleField: View {
    var color: Color
    var shape: ThemeManager.ParticleShape
    private let count = 42
    private let linkDist: CGFloat = 150

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                var pts: [(pt: CGPoint, size: CGFloat, alpha: Double, rot: Double)] = []
                pts.reserveCapacity(count)
                for i in 0..<count {
                    let seed = Double(i) * 12.9898
                    let sx = abs(sin(seed))
                    let sy = abs(cos(seed * 1.7))
                    let x = (sx + 0.05 * sin(t * 0.13 + seed)).truncatingRemainder(dividingBy: 1) * size.width
                    let y = (sy + 0.05 * cos(t * 0.11 + seed)).truncatingRemainder(dividingBy: 1) * size.height
                    let sz: CGFloat = 6 + CGFloat(abs(sin(seed * 3.7))) * 7  // 6–13
                    let a  = 0.55 + abs(sin(seed * 2.1)) * 0.4               // 0.55–0.95
                    let rt = t * 0.4 + seed
                    pts.append((CGPoint(x: abs(x), y: abs(y)), sz, a, rt))
                }

                // Link lines between nearby particles
                for i in 0..<pts.count {
                    for j in (i + 1)..<pts.count {
                        let dx = pts[i].pt.x - pts[j].pt.x
                        let dy = pts[i].pt.y - pts[j].pt.y
                        let dist = (dx * dx + dy * dy).squareRoot()
                        if dist < linkDist {
                            var path = Path()
                            path.move(to: pts[i].pt)
                            path.addLine(to: pts[j].pt)
                            let op = (1 - Double(dist / linkDist)) * 0.42
                            ctx.stroke(path,
                                       with: .color(color.opacity(op)),
                                       lineWidth: 1.1)
                        }
                    }
                }
                // Draw the particles themselves
                for p in pts {
                    drawParticleShape(&ctx,
                                      shape: shape,
                                      center: p.pt,
                                      size: p.size,
                                      color: color,
                                      opacity: p.alpha,
                                      rotation: p.rot)
                }
            }
        }
        .drawingGroup()
    }
}

// MARK: - Trailing Balls

/// Three small balls with fading accent trails that overlap creating
/// intricate patterns. Uses TimelineView with a running clock; positions
/// and trails are recomputed each frame from a compact state machine.
struct TrailingBallsField: View {
    var color: Color

    @State private var balls: [Ball] = []
    private let maxTrail = 70

    struct Ball {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var trail: [CGPoint]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { ctx, size in
                // Initialize on first frame with a size we know
                if balls.isEmpty {
                    var seeded: [Ball] = []
                    for i in 0..<3 {
                        let seed = Double(i) * 17.3
                        let ang = seed
                        let speed = 0.9 + (abs(sin(seed * 2.1))) * 0.5
                        seeded.append(Ball(
                            x: size.width * (0.2 + CGFloat(abs(sin(seed))) * 0.6),
                            y: size.height * (0.2 + CGFloat(abs(cos(seed))) * 0.6),
                            vx: CGFloat(cos(ang) * speed),
                            vy: CGFloat(sin(ang) * speed),
                            trail: []
                        ))
                    }
                    DispatchQueue.main.async { self.balls = seeded }
                    return
                }

                var updated = balls
                for i in 0..<updated.count {
                    var b = updated[i]
                    b.x += b.vx
                    b.y += b.vy
                    let r: CGFloat = 5
                    if b.x - r < 0 { b.x = r; b.vx = -b.vx }
                    if b.x + r > size.width  { b.x = size.width  - r; b.vx = -b.vx }
                    if b.y - r < 0 { b.y = r; b.vy = -b.vy }
                    if b.y + r > size.height { b.y = size.height - r; b.vy = -b.vy }
                    b.trail.append(CGPoint(x: b.x, y: b.y))
                    if b.trail.count > maxTrail { b.trail.removeFirst() }
                    updated[i] = b

                    // Draw fading trail
                    for t in 1..<b.trail.count {
                        var path = Path()
                        path.move(to: b.trail[t - 1])
                        path.addLine(to: b.trail[t])
                        let op = Double(t) / Double(b.trail.count) * 0.7
                        ctx.stroke(path,
                                   with: .color(color.opacity(op)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    // Glowing ball
                    let ballRect = CGRect(x: b.x - r, y: b.y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: ballRect), with: .color(color))
                    // Glow ring
                    ctx.fill(Path(ellipseIn: ballRect.insetBy(dx: -4, dy: -4)),
                             with: .color(color.opacity(0.3)))
                }
                // Publish updated state for next frame
                DispatchQueue.main.async { self.balls = updated }
            }
        }
        .drawingGroup()
    }
}

// MARK: - Matrix

/// Slow falling 0/1 digits in vertical columns, classic Matrix rain.
struct MatrixField: View {
    var color: Color
    private let fontSize: CGFloat = 14

    @State private var drops: [CGFloat] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let cols = max(1, Int(size.width / fontSize))
                if drops.count != cols {
                    var d = [CGFloat]()
                    d.reserveCapacity(cols)
                    for _ in 0..<cols { d.append(CGFloat.random(in: -50 ... 0)) }
                    DispatchQueue.main.async { self.drops = d }
                    return
                }

                var updated = drops
                for i in 0..<cols {
                    let ch = Bool.random() ? "0" : "1"
                    let x = CGFloat(i) * fontSize
                    let y = updated[i] * fontSize
                    let text = Text(ch)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundColor(color.opacity(0.85))
                    ctx.draw(text, at: CGPoint(x: x + fontSize / 2, y: y))
                    if y > size.height && Double.random(in: 0...1) > 0.985 {
                        updated[i] = 0
                    }
                    // Slow: 0.18–0.36 per frame, matches web
                    updated[i] += 0.18 + CGFloat.random(in: 0 ... 0.18)
                }
                DispatchQueue.main.async { self.drops = updated }
            }
        }
        .drawingGroup()
    }
}

// MARK: - Binary Rain

/// Slower, longer multi-character binary streams per column with per-column
/// speed variance. Head bright, tail fades. Matches the web plugin's
/// `startBinary()`.
struct BinaryRainField: View {
    var color: Color
    private let fontSize: CGFloat = 12

    struct BinaryCol {
        var y: CGFloat            // top-of-stream position (in char units)
        var speed: CGFloat        // per-frame drop speed (char units)
        var chars: [Character]    // the binary string this column shows
    }
    @State private var cols: [BinaryCol] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let colCount = max(1, Int(size.width / fontSize))
                if cols.count != colCount {
                    var c = [BinaryCol]()
                    c.reserveCapacity(colCount)
                    for _ in 0..<colCount {
                        let len = Int.random(in: 12 ... 28)
                        var chars = [Character]()
                        for _ in 0..<len { chars.append(Bool.random() ? "0" : "1") }
                        c.append(BinaryCol(
                            y: CGFloat.random(in: -50 ... -5),
                            speed: 0.15 + CGFloat.random(in: 0 ... 0.35),
                            chars: chars
                        ))
                    }
                    DispatchQueue.main.async { self.cols = c }
                    return
                }

                var updated = cols
                for i in 0..<colCount {
                    var col = updated[i]
                    col.y += col.speed
                    if col.y * fontSize > size.height + CGFloat(col.chars.count) * fontSize {
                        col.y = -CGFloat(col.chars.count) - CGFloat.random(in: 0 ... 10)
                        col.speed = 0.15 + CGFloat.random(in: 0 ... 0.35)
                        for k in 0..<col.chars.count { col.chars[k] = Bool.random() ? "0" : "1" }
                    }
                    // Occasional shimmer
                    if Double.random(in: 0...1) < 0.02 && !col.chars.isEmpty {
                        let idx = Int.random(in: 0..<col.chars.count)
                        col.chars[idx] = Bool.random() ? "0" : "1"
                    }
                    // Draw: head bright, tail fades
                    for k in 0..<col.chars.count {
                        let y = (col.y + CGFloat(k)) * fontSize
                        if y < 0 || y > size.height + fontSize { continue }
                        let op = 0.15 + Double(k) / Double(col.chars.count) * 0.7
                        let text = Text(String(col.chars[k]))
                            .font(.system(size: fontSize, design: .monospaced))
                            .foregroundColor(color.opacity(op))
                        ctx.draw(text, at: CGPoint(x: CGFloat(i) * fontSize + fontSize / 2, y: y))
                    }
                    updated[i] = col
                }
                DispatchQueue.main.async { self.cols = updated }
            }
        }
        .drawingGroup()
    }
}

// MARK: - Confetti

/// Real paper-strip-style confetti: thin rectangles that tumble (3D flip
/// simulated by squashing width with cos(flip)) and sway horizontally.
struct ConfettiField: View {
    var color: Color

    struct Piece {
        var x: CGFloat
        var y: CGFloat
        var w: CGFloat
        var h: CGFloat
        var vy: CGFloat
        var vx: CGFloat
        var sway: Double
        var swaySpeed: Double
        var rot: Double
        var vr: Double
        var flip: Double
        var flipSpeed: Double
        var alpha: Double
    }
    @State private var pieces: [Piece] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { ctx, size in
                let N = min(120, Int(size.width / 14))
                if pieces.count != N {
                    var seeded: [Piece] = []
                    seeded.reserveCapacity(N)
                    for _ in 0..<N {
                        seeded.append(Piece(
                            x: CGFloat.random(in: 0...size.width),
                            y: CGFloat.random(in: -size.height...size.height),
                            w: 6 + CGFloat.random(in: 0...5),
                            h: 10 + CGFloat.random(in: 0...7),
                            vy: 1.0 + CGFloat.random(in: 0...1.8),
                            vx: -0.6 + CGFloat.random(in: 0...1.2),
                            sway: Double.random(in: 0...(.pi * 2)),
                            swaySpeed: 0.02 + Double.random(in: 0...0.03),
                            rot: Double.random(in: 0...(.pi * 2)),
                            vr: -0.05 + Double.random(in: 0...0.10),
                            flip: Double.random(in: 0...(.pi * 2)),
                            flipSpeed: 0.08 + Double.random(in: 0...0.10),
                            alpha: 0.55 + Double.random(in: 0...0.4)
                        ))
                    }
                    DispatchQueue.main.async { self.pieces = seeded }
                    return
                }

                var updated = pieces
                for i in 0..<updated.count {
                    var p = updated[i]
                    p.sway += p.swaySpeed
                    p.x += p.vx + CGFloat(sin(p.sway)) * 0.4
                    p.y += p.vy
                    p.rot += p.vr
                    p.flip += p.flipSpeed

                    if p.y > size.height + 20 {
                        p.y = -20
                        p.x = CGFloat.random(in: 0...size.width)
                    }
                    if p.x < -20 { p.x = size.width + 20 }
                    if p.x > size.width + 20 { p.x = -20 }

                    let widthScale = max(0.1, CGFloat(abs(cos(p.flip))))
                    let drawAlpha = cos(p.flip) < 0 ? p.alpha * 0.55 : p.alpha

                    ctx.drawLayer { layer in
                        layer.translateBy(x: p.x, y: p.y)
                        layer.rotate(by: .radians(p.rot))
                        let w = p.w * widthScale
                        let rect = CGRect(x: -w / 2, y: -p.h / 2, width: w, height: p.h)
                        layer.fill(Path(rect), with: .color(color.opacity(drawAlpha)))
                    }
                    updated[i] = p
                }
                DispatchQueue.main.async { self.pieces = updated }
            }
        }
        .drawingGroup()
    }
}

// MARK: - Palette dropdown

struct ThemePalettePanel: View {
    @ObservedObject var theme = ThemeManager.shared
    @Binding var expandedWheel: Bool
    @Binding var expandedBackground: Bool
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {

            // ─── Accent color card (collapsible wheel) ───
            card {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.accent)
                            .frame(width: 46, height: 46)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.accent.opacity(0.45), lineWidth: 2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ACCENT COLOR").font(.system(size: 11, weight: .heavy)).kerning(1).foregroundStyle(Theme.subtle)
                            Text(theme.accentHex.uppercased())
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Button { withAnimation { expandedWheel.toggle() } } label: {
                            Image(systemName: expandedWheel ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    if expandedWheel {
                        ColorWheel(hex: $theme.accentHex).frame(height: 240)
                        HStack(spacing: 10) {
                            ForEach(ThemeManager.presets, id: \.self) { hex in
                                Button { theme.accentHex = hex } label: {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Circle().stroke(
                                                .white.opacity(theme.accentHex.caseInsensitiveCompare(hex) == .orderedSame ? 0.95 : 0),
                                                lineWidth: 2.5)
                                        )
                                }
                            }
                        }
                    }
                }
            }

            // ─── Appearance (dark/light) ───
            card {
                HStack(spacing: 12) {
                    tile(theme.darkMode ? "moon.fill" : "sun.max.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("APPEARANCE").font(.system(size: 11, weight: .heavy)).kerning(1).foregroundStyle(Theme.subtle)
                        Text(theme.darkMode ? "Dark mode" : "Light mode").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    }
                    Spacer()
                    Toggle("", isOn: $theme.darkMode).labelsHidden().tint(theme.accent)
                }
            }

            // ─── Background style (collapsible with live mini-preview) ───
            card {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        // The mini-preview tile reflects the CURRENT bg style,
                        // matching the web plugin's `#cw-bg-preview-mini`.
                        BgMiniPreview(style: theme.background, accent: theme.accent)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BACKGROUND").font(.system(size: 11, weight: .heavy)).kerning(1).foregroundStyle(Theme.subtle)
                            Text(theme.background.rawValue).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        }
                        Spacer()
                        Button { withAnimation { expandedBackground.toggle() } } label: {
                            Image(systemName: expandedBackground ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    if expandedBackground {
                        // 2-column grid of the 6 backgrounds
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                  spacing: 8) {
                            ForEach(ThemeManager.BackgroundStyle.allCases) { s in
                                Button { theme.background = s } label: {
                                    HStack(spacing: 10) {
                                        BgMiniPreview(style: s, accent: theme.accent)
                                            .frame(width: 32, height: 32)
                                        Text(s.rawValue)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1).minimumScaleFactor(0.85)
                                        Spacer(minLength: 0)
                                        if theme.background == s {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(theme.accent)
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(theme.background == s
                                                ? theme.accent.opacity(0.14)
                                                : Color.white.opacity(0.03))
                                    .foregroundStyle(theme.background == s ? .white : Theme.subtle)
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .stroke(theme.background == s ? theme.accent : Color.white.opacity(0.08),
                                                lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }

                        // Particle shape sub-row (only when Particles is active)
                        if theme.background == .particles {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("PARTICLE SHAPE")
                                    .font(.system(size: 11, weight: .heavy)).kerning(1)
                                    .foregroundStyle(Theme.subtle)
                                    .padding(.top, 4)
                                HStack(spacing: 6) {
                                    ForEach(ThemeManager.ParticleShape.allCases) { s in
                                        Button { theme.particleShape = s } label: {
                                            Image(systemName: s.icon)
                                                .font(.system(size: 14))
                                                .frame(maxWidth: .infinity, minHeight: 34)
                                                .background(theme.particleShape == s
                                                            ? theme.accent.opacity(0.14)
                                                            : Color.white.opacity(0.03))
                                                .foregroundStyle(theme.particleShape == s ? theme.accent : Theme.subtle)
                                                .overlay(RoundedRectangle(cornerRadius: 8)
                                                    .stroke(theme.particleShape == s ? theme.accent : Color.white.opacity(0.08),
                                                            lineWidth: 1))
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.10, green: 0.08, blue: 0.12))
        .overlay(RoundedRectangle(cornerRadius: 20)
            .stroke(theme.accent.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: 360)
        .padding(.horizontal, 12)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.14, green: 0.11, blue: 0.17))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func tile(_ icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accent.opacity(0.18))
                .frame(width: 40, height: 40)
            Image(systemName: icon).foregroundStyle(theme.accent)
        }
    }
}

// MARK: - Live mini-preview tile

/// Matches the web plugin's `#cw-bg-preview-mini` / `.cw-pv-*` behaviour:
/// a small tile that renders a static representation of the chosen bg
/// (dots for particles/balls, mini "01" text for matrix/binary, angled
/// strips for confetti). Used in both the collapsed bg row and the list.
struct BgMiniPreview: View {
    var style: ThemeManager.BackgroundStyle
    var accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(accent.opacity(0.35), lineWidth: 1))
            content
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .none:
            Image(systemName: "circle.slash")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.4))
        case .particles:
            Canvas { ctx, size in
                let cx = size.width / 2, cy = size.height / 2
                let dots = [
                    CGPoint(x: cx - 8, y: cy - 6),
                    CGPoint(x: cx + 6, y: cy - 8),
                    CGPoint(x: cx - 4, y: cy + 8),
                    CGPoint(x: cx + 8, y: cy + 5),
                ]
                // Faint links between neighbours
                for i in 0..<dots.count {
                    for j in (i + 1)..<dots.count {
                        var p = Path()
                        p.move(to: dots[i]); p.addLine(to: dots[j])
                        ctx.stroke(p, with: .color(accent.opacity(0.28)), lineWidth: 0.7)
                    }
                }
                for pt in dots {
                    let r: CGFloat = 2
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                             with: .color(accent))
                }
            }
        case .balls:
            Canvas { ctx, size in
                let cx = size.width / 2, cy = size.height / 2
                let balls = [
                    CGPoint(x: cx - 7, y: cy + 3),
                    CGPoint(x: cx + 4, y: cy - 5),
                    CGPoint(x: cx + 6, y: cy + 6),
                ]
                for pt in balls {
                    let r: CGFloat = 2.5
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                             with: .color(accent))
                }
            }
        case .matrix:
            Text("10\n01\n11")
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundStyle(accent)
                .lineSpacing(-1)
                .multilineTextAlignment(.center)
        case .binary:
            Text("101\n010\n110")
                .font(.system(size: 6, weight: .medium, design: .monospaced))
                .foregroundStyle(accent)
                .lineSpacing(-1)
                .multilineTextAlignment(.center)
        case .confetti:
            Canvas { ctx, size in
                let cx = size.width / 2, cy = size.height / 2
                let strips: [(CGPoint, CGFloat)] = [
                    (CGPoint(x: cx - 7, y: cy - 5),  0.5),
                    (CGPoint(x: cx + 4, y: cy - 2), -0.7),
                    (CGPoint(x: cx - 3, y: cy + 6),  0.4),
                    (CGPoint(x: cx + 6, y: cy + 4), -0.5),
                ]
                for (pt, angle) in strips {
                    ctx.drawLayer { layer in
                        layer.translateBy(x: pt.x, y: pt.y)
                        layer.rotate(by: .radians(angle))
                        let rect = CGRect(x: -2, y: -1, width: 4, height: 2)
                        layer.fill(Path(rect), with: .color(accent))
                    }
                }
            }
        }
    }
}

// MARK: - Color wheel (HSB ring, tap/drag to pick)

struct ColorWheel: View {
    @Binding var hex: String
    @State private var pos: CGPoint = .zero

    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let r = d / 2
            ZStack {
                // Hue/sat wheel
                AngularGradient(gradient: Gradient(colors: wheelColors), center: .center)
                    .mask(Circle())
                    .overlay(
                        RadialGradient(colors: [.white, .white.opacity(0)],
                                       center: .center, startRadius: 0, endRadius: r)
                            .blendMode(.screen)
                            .mask(Circle())
                    )
                // Hollow black centre, matching web
                Circle().fill(Color.black).frame(width: r * 0.55, height: r * 0.55)
                // Cursor
                Circle().stroke(.white, lineWidth: 3)
                    .frame(width: 26, height: 26)
                    .position(pos == .zero ? c : pos)
            }
            .frame(width: d, height: d)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let dx = v.location.x - c.x, dy = v.location.y - c.y
                let dist = min((dx * dx + dy * dy).squareRoot(), r)
                let ang = atan2(dy, dx)
                pos = CGPoint(x: c.x + cos(ang) * dist, y: c.y + sin(ang) * dist)
                let hue = (ang / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
                let sat = dist / r
                hex = Color(hue: hue, saturation: sat, brightness: 1).toHex()
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var wheelColors: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
            Color(hue: $0, saturation: 1, brightness: 1)
        }
    }
}

extension Color {
    func toHex() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Shared open/close state for the palette panel
// Any tab's palette button toggles this shared state.

@MainActor
final class ThemePanelState: ObservableObject {
    static let shared = ThemePanelState()
    @Published var open = false
    private init() {}
}
