//
//  ThemeKit.swift
//  App-wide theme: live accent color, dark-mode toggle, and animated
//  backgrounds that render behind every tab. Ported to match the web
//  plugin — 6 backgrounds (None / Particles / Trailing Balls / Matrix /
//  Binary Rain / Confetti), 5 particle shapes, same 8 presets, #FF8800
//  default.
//
//  Animation architecture: each animated field owns a reference-typed
//  simulation state (`class`) so we can mutate it from inside `Canvas`
//  closures without touching `@State`. `TimelineView` drives redraws.
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

    enum BackgroundStyle: String, CaseIterable, Identifiable {
        case none     = "None"
        case particles = "Particles"
        case balls    = "Trailing Balls"
        case matrix   = "Matrix"
        case binary   = "Binary Rain"
        case confetti = "Confetti"

        var id: String { rawValue }

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

    static let presets: [String] = [
        "#FF8800", "#FF3B5C", "#A855F7", "#3B82F6",
        "#10B981", "#F59E0B", "#EF4444", "#06B6D4",
    ]

    private init() {
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
// Takes a GraphicsContext by value (Canvas gives us a value-typed one, not inout).
// Returns nothing — we call layer methods internally.

private func drawParticleShape(in ctx: GraphicsContext,
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

/// Constellation-style particles: seeded by index so positions are stable
/// per-particle, then perturbed with sin(t)/cos(t) for slow drift. Purely
/// time-driven — no mutable state.
struct ParticleField: View {
    var color: Color
    var shape: ThemeManager.ParticleShape
    private let count = 42
    private let linkDist: CGFloat = 150

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let t: Double = timeline.date.timeIntervalSinceReferenceDate
                var pts: [(pt: CGPoint, size: CGFloat, alpha: Double, rot: Double)] = []
                pts.reserveCapacity(count)
                for i in 0..<count {
                    let seed: Double = Double(i) * 12.9898
                    let sx: Double = abs(sin(seed))
                    let sy: Double = abs(cos(seed * 1.7))
                    let nx: Double = (sx + 0.11 * sin(t * 0.32 + seed)).truncatingRemainder(dividingBy: 1)
                    let ny: Double = (sy + 0.11 * cos(t * 0.28 + seed)).truncatingRemainder(dividingBy: 1)
                    let x: CGFloat = CGFloat(abs(nx)) * size.width
                    let y: CGFloat = CGFloat(abs(ny)) * size.height
                    let sz: CGFloat = CGFloat(6.0) + CGFloat(abs(sin(seed * 3.7))) * CGFloat(7.0)
                    let a:  Double  = 0.55 + abs(sin(seed * 2.1)) * 0.4
                    let rt: Double  = t * 0.4 + seed
                    pts.append((CGPoint(x: x, y: y), sz, a, rt))
                }
                // Links
                for i in 0..<pts.count {
                    for j in (i + 1)..<pts.count {
                        let dx: CGFloat = pts[i].pt.x - pts[j].pt.x
                        let dy: CGFloat = pts[i].pt.y - pts[j].pt.y
                        let dist: CGFloat = (dx * dx + dy * dy).squareRoot()
                        if dist < linkDist {
                            var path = Path()
                            path.move(to: pts[i].pt)
                            path.addLine(to: pts[j].pt)
                            let op: Double = (1.0 - Double(dist / linkDist)) * 0.42
                            ctx.stroke(path,
                                       with: .color(color.opacity(op)),
                                       lineWidth: 1.1)
                        }
                    }
                }
                // Shapes
                for p in pts {
                    drawParticleShape(in: ctx,
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

/// Reference-typed simulation so we can mutate it safely from inside Canvas.
@MainActor
private final class BallsState {
    struct Ball {
        var x: CGFloat; var y: CGFloat
        var vx: CGFloat; var vy: CGFloat
        var trail: [CGPoint]
    }
    var balls: [Ball] = []
    var lastSize: CGSize = .zero
    let maxTrail = 70

    func step(in size: CGSize) {
        // (Re)seed on size change / first frame
        if balls.isEmpty || lastSize != size {
            lastSize = size
            balls = (0..<3).map { i in
                let seed = Double(i) * 17.3
                let ang = seed
                let speed: Double = 0.9 + abs(sin(seed * 2.1)) * 0.5
                let baseX: CGFloat = CGFloat(0.2 + abs(sin(seed)) * 0.6)
                let baseY: CGFloat = CGFloat(0.2 + abs(cos(seed)) * 0.6)
                return Ball(
                    x: size.width  * baseX,
                    y: size.height * baseY,
                    vx: CGFloat(cos(ang) * speed),
                    vy: CGFloat(sin(ang) * speed),
                    trail: []
                )
            }
            return
        }
        for i in 0..<balls.count {
            var b = balls[i]
            b.x += b.vx
            b.y += b.vy
            let r: CGFloat = 5
            if b.x - r < 0 { b.x = r; b.vx = -b.vx }
            if b.x + r > size.width  { b.x = size.width  - r; b.vx = -b.vx }
            if b.y - r < 0 { b.y = r; b.vy = -b.vy }
            if b.y + r > size.height { b.y = size.height - r; b.vy = -b.vy }
            b.trail.append(CGPoint(x: b.x, y: b.y))
            if b.trail.count > maxTrail { b.trail.removeFirst() }
            balls[i] = b
        }
    }
}

struct TrailingBallsField: View {
    var color: Color
    // Reference type — mutation from Canvas is fine, no @State recursion.
    @State private var state = BallsState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            Canvas { ctx, size in
                state.step(in: size)
                let r: CGFloat = 5
                for b in state.balls {
                    for t in 1..<b.trail.count {
                        var path = Path()
                        path.move(to: b.trail[t - 1])
                        path.addLine(to: b.trail[t])
                        let op = Double(t) / Double(b.trail.count) * 0.7
                        ctx.stroke(path,
                                   with: .color(color.opacity(op)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    let rect = CGRect(x: b.x - r, y: b.y - r, width: r * CGFloat(2), height: r * CGFloat(2))
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                    ctx.fill(Path(ellipseIn: rect.insetBy(dx: CGFloat(-4), dy: CGFloat(-4))),
                             with: .color(color.opacity(0.3)))
                }
            }
        }
        .drawingGroup()
    }
}

// MARK: - Matrix

@MainActor
private final class MatrixState {
    var drops: [CGFloat] = []
    var lastColCount: Int = 0
    let fontSize: CGFloat = 14

    func step(in size: CGSize) -> Int {
        let cols = max(1, Int(size.width / fontSize))
        if drops.count != cols {
            drops = (0..<cols).map { _ in CGFloat.random(in: CGFloat(-50) ... CGFloat(0)) }
            lastColCount = cols
        }
        for i in 0..<cols {
            let y: CGFloat = drops[i] * fontSize
            if y > size.height && Double.random(in: 0...1) > 0.985 {
                drops[i] = CGFloat(0)
            }
            drops[i] += CGFloat(0.18) + CGFloat.random(in: CGFloat(0) ... CGFloat(0.18))
        }
        return cols
    }
}

struct MatrixField: View {
    var color: Color
    @State private var state = MatrixState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { ctx, size in
                let cols = state.step(in: size)
                let fs = state.fontSize
                for i in 0..<cols {
                    let ch = Bool.random() ? "0" : "1"
                    let x = CGFloat(i) * fs + fs / 2
                    let y = state.drops[i] * fs
                    let text = Text(ch)
                        .font(.system(size: fs, design: .monospaced))
                        .foregroundColor(color.opacity(0.85))
                    ctx.draw(text, at: CGPoint(x: x, y: y))
                }
            }
        }
        .drawingGroup()
    }
}

// MARK: - Binary Rain

@MainActor
private final class BinaryState {
    struct Col {
        var y: CGFloat
        var speed: CGFloat
        var chars: [Character]
    }
    var cols: [Col] = []
    let fontSize: CGFloat = 12

    func step(in size: CGSize) -> Int {
        let colCount = max(1, Int(size.width / fontSize))
        if cols.count != colCount {
            cols = (0..<colCount).map { _ in
                let len = Int.random(in: 12 ... 28)
                var chars = [Character]()
                for _ in 0..<len { chars.append(Bool.random() ? "0" : "1") }
                return Col(
                    y: CGFloat.random(in: CGFloat(-50) ... CGFloat(-5)),
                    speed: 0.15 + CGFloat.random(in: CGFloat(0) ... CGFloat(0.35)),
                    chars: chars
                )
            }
        }
        for i in 0..<colCount {
            var col = cols[i]
            col.y += col.speed
            if col.y * fontSize > size.height + CGFloat(col.chars.count) * fontSize {
                col.y = -CGFloat(col.chars.count) - CGFloat.random(in: CGFloat(0) ... CGFloat(10))
                col.speed = 0.15 + CGFloat.random(in: CGFloat(0) ... CGFloat(0.35))
                for k in 0..<col.chars.count { col.chars[k] = Bool.random() ? "0" : "1" }
            }
            if Double.random(in: 0...1) < 0.02 && !col.chars.isEmpty {
                let idx = Int.random(in: 0..<col.chars.count)
                col.chars[idx] = Bool.random() ? "0" : "1"
            }
            cols[i] = col
        }
        return colCount
    }
}

struct BinaryRainField: View {
    var color: Color
    @State private var state = BinaryState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { ctx, size in
                let count = state.step(in: size)
                let fs = state.fontSize
                for i in 0..<count {
                    let col = state.cols[i]
                    for k in 0..<col.chars.count {
                        let y = (col.y + CGFloat(k)) * fs
                        if y < 0 || y > size.height + fs { continue }
                        let op = 0.15 + Double(k) / Double(col.chars.count) * 0.7
                        let text = Text(String(col.chars[k]))
                            .font(.system(size: fs, design: .monospaced))
                            .foregroundColor(color.opacity(op))
                        ctx.draw(text, at: CGPoint(x: CGFloat(i) * fs + fs / 2, y: y))
                    }
                }
            }
        }
        .drawingGroup()
    }
}

// MARK: - Confetti

@MainActor
private final class ConfettiState {
    struct Piece {
        var x: CGFloat; var y: CGFloat
        var w: CGFloat; var h: CGFloat
        var vy: CGFloat; var vx: CGFloat
        var sway: Double; var swaySpeed: Double
        var rot: Double; var vr: Double
        var flip: Double; var flipSpeed: Double
        var alpha: Double
    }
    var pieces: [Piece] = []
    var lastN: Int = 0

    func step(in size: CGSize) {
        let N = min(120, Int(size.width / 14))
        if pieces.count != N {
            pieces = (0..<N).map { _ in
                let x:  CGFloat = CGFloat.random(in: CGFloat(0)...size.width)
                let y:  CGFloat = CGFloat.random(in: -size.height...size.height)
                let w:  CGFloat = CGFloat(6)  + CGFloat.random(in: CGFloat(0)...CGFloat(5))
                let h:  CGFloat = CGFloat(10) + CGFloat.random(in: CGFloat(0)...CGFloat(7))
                let vy: CGFloat = CGFloat(1.0) + CGFloat.random(in: CGFloat(0)...CGFloat(1.8))
                let vx: CGFloat = CGFloat(-0.6) + CGFloat.random(in: CGFloat(0)...CGFloat(1.2))
                let sway: Double      = Double.random(in: 0 ... (Double.pi * 2))
                let swaySpeed: Double = 0.02 + Double.random(in: 0 ... 0.03)
                let rot: Double       = Double.random(in: 0 ... (Double.pi * 2))
                let vr: Double        = -0.05 + Double.random(in: 0 ... 0.10)
                let flip: Double      = Double.random(in: 0 ... (Double.pi * 2))
                let flipSpeed: Double = 0.08 + Double.random(in: 0 ... 0.10)
                let alpha: Double     = 0.55 + Double.random(in: 0 ... 0.4)
                return Piece(
                    x: x, y: y, w: w, h: h,
                    vy: vy, vx: vx,
                    sway: sway, swaySpeed: swaySpeed,
                    rot: rot, vr: vr,
                    flip: flip, flipSpeed: flipSpeed,
                    alpha: alpha
                )
            }
            lastN = N
        }
        for i in 0..<pieces.count {
            var p = pieces[i]
            p.sway += p.swaySpeed
            p.x += p.vx + CGFloat(sin(p.sway)) * CGFloat(0.4)
            p.y += p.vy
            p.rot += p.vr
            p.flip += p.flipSpeed
            if p.y > size.height + CGFloat(20) {
                p.y = CGFloat(-20)
                p.x = CGFloat.random(in: CGFloat(0)...size.width)
            }
            if p.x < CGFloat(-20) { p.x = size.width + CGFloat(20) }
            if p.x > size.width + CGFloat(20) { p.x = CGFloat(-20) }
            pieces[i] = p
        }
    }
}

struct ConfettiField: View {
    var color: Color
    @State private var state = ConfettiState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            Canvas { ctx, size in
                state.step(in: size)
                for p in state.pieces {
                    let widthScale: CGFloat = max(CGFloat(0.1), CGFloat(abs(cos(p.flip))))
                    let drawAlpha: Double = cos(p.flip) < 0 ? p.alpha * 0.55 : p.alpha
                    ctx.drawLayer { layer in
                        layer.translateBy(x: p.x, y: p.y)
                        layer.rotate(by: .radians(p.rot))
                        let w: CGFloat = p.w * widthScale
                        let rect = CGRect(x: -w / CGFloat(2), y: -p.h / CGFloat(2), width: w, height: p.h)
                        layer.fill(Path(rect), with: .color(color.opacity(drawAlpha)))
                    }
                }
            }
        }
        .drawingGroup()
    }
}

// MARK: - Shared top-bar with accent bottom border
//
// A reusable header bar for tabs. Renders a title on the left and optional
// trailing content (buttons, chips, etc.) on the right, with a 2px accent
// bottom border that connects to the AccentFrame's side rails, forming a
// closed accent-tinted "window" around the tab content.

/// Accent-tinted frosted background: system blur (like the TabBar) with an
/// accent-colored wash on top so headers read as tinted glass, not flat fill.
/// Kept transparent enough that the dynamic ParticleBackground behind it
/// remains visible through the topbar.
struct AccentBarBlur: View {
    @ObservedObject private var theme = ThemeManager.shared
    var body: some View {
        ZStack {
            // Subtle frosted-glass layer — thin enough to see particles through
            Rectangle().fill(.ultraThinMaterial).opacity(0.55)
            // Light accent wash for tinting (transparent — particles still visible)
            theme.accent.opacity(0.18)
        }
        .ignoresSafeArea()
    }
}

// MARK: - AccentFrame top-inset override (per-screen)
//
// The global AccentFrame in RootView assumes a single-height AccentTopBar
// (~66pt below the safe area). Screens with a taller topbar stack (e.g.
// SourceDetailScreen: header + countBar) push down where the rails start
// by writing this preference. RootView listens with .onPreferenceChange.

struct AccentFrameTopInsetKey: PreferenceKey {
    // PreferenceKey's requirements are nonisolated. Under the project's
    // SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor these would otherwise be
    // MainActor-isolated and fail to satisfy the protocol cleanly. A
    // computed property (not stored) is required for `nonisolated`.
    nonisolated static var defaultValue: CGFloat { 66 }
    nonisolated static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Prefer the largest child's request — a nested view with a taller
        // topbar wins over the default.
        let next = nextValue()
        if next > value { value = next }
    }
}

extension View {
    /// Push the AccentFrame's rails down by this many points below the safe
    /// area top. Use to make rails clear a taller topbar stack in this screen.
    func accentFrameTopInset(_ inset: CGFloat) -> some View {
        preference(key: AccentFrameTopInsetKey.self, value: inset)
    }
}

struct AccentTopBar<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.subtle)
                    }
                }
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // Frosted material (like the TabBar) with an accent-colored tint
            // pushed over it — echoes the bottom TabBar's look but colored.
            .background(AccentBarBlur())
            // 2px accent bottom border — meets the AccentFrame's left/right rails
            Rectangle().fill(theme.accent).frame(height: 2)
        }
    }
}

extension AccentTopBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Accent bottom-border strip
//
// A reusable strip used INSIDE a tab (below the top bar or between content
// sections) that draws a 2px accent line at its bottom. Used for e.g. the
// "0 Apps by MRZefv" counter row on SourceDetailScreen.

struct AccentBottomBorder<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            content()
            Rectangle().fill(theme.accent).frame(height: 2)
        }
    }
}

// MARK: - Palette dropdown

struct ThemePalettePanel: View {
    @ObservedObject var theme = ThemeManager.shared
    @Binding var expandedWheel: Bool
    @Binding var expandedBackground: Bool
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {

            // Accent color card (collapsible wheel)
            card {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.accent)
                            .frame(width: 38, height: 38)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.accent.opacity(0.45), lineWidth: 2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ACCENT COLOR")
                                .font(.system(size: 10, weight: .heavy)).kerning(1)
                                .foregroundStyle(Theme.subtle)
                            Text(theme.accentHex.uppercased())
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Button { withAnimation { expandedWheel.toggle() } } label: {
                            Image(systemName: expandedWheel ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    if expandedWheel {
                        ColorWheel(hex: $theme.accentHex).frame(height: 190)
                        HStack(spacing: 8) {
                            ForEach(ThemeManager.presets, id: \.self) { hex in
                                Button { theme.accentHex = hex } label: {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Circle().stroke(
                                                .white.opacity(theme.accentHex.caseInsensitiveCompare(hex) == .orderedSame ? 0.95 : 0),
                                                lineWidth: 2)
                                        )
                                }
                            }
                        }
                    }
                }
            }

            // Appearance (dark/light)
            card {
                HStack(spacing: 12) {
                    tile(theme.darkMode ? "moon.fill" : "sun.max.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("APPEARANCE")
                            .font(.system(size: 10, weight: .heavy)).kerning(1)
                            .foregroundStyle(Theme.subtle)
                        Text(theme.darkMode ? "Dark mode" : "Light mode")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Toggle("", isOn: $theme.darkMode).labelsHidden().tint(theme.accent).scaleEffect(0.85)
                }
            }

            // Background style
            card {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        BgMiniPreview(style: theme.background, accent: theme.accent)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BACKGROUND")
                                .font(.system(size: 10, weight: .heavy)).kerning(1)
                                .foregroundStyle(Theme.subtle)
                            Text(theme.background.rawValue)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Button { withAnimation { expandedBackground.toggle() } } label: {
                            Image(systemName: expandedBackground ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    if expandedBackground {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                            GridItem(.flexible(), spacing: 6)],
                                  spacing: 6) {
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
        .padding(10)
        .background(Color(red: 0.10, green: 0.08, blue: 0.12))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(theme.accent.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 300)
        .padding(.horizontal, 12)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.14, green: 0.11, blue: 0.17))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func tile(_ icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.accent.opacity(0.18))
                .frame(width: 34, height: 34)
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(theme.accent)
        }
    }
}

// MARK: - Live mini-preview tile

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
                let cx = size.width / CGFloat(2), cy = size.height / CGFloat(2)
                let dots = [
                    CGPoint(x: cx - 8, y: cy - 6),
                    CGPoint(x: cx + 6, y: cy - 8),
                    CGPoint(x: cx - 4, y: cy + 8),
                    CGPoint(x: cx + 8, y: cy + 5),
                ]
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
                let cx = size.width / CGFloat(2), cy = size.height / CGFloat(2)
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
                let cx = size.width / CGFloat(2), cy = size.height / CGFloat(2)
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
            let c = CGPoint(x: g.size.width / CGFloat(2), y: g.size.height / CGFloat(2))
            let r = d / 2
            ZStack {
                AngularGradient(gradient: Gradient(colors: wheelColors), center: .center)
                    .mask(Circle())
                    .overlay(
                        RadialGradient(colors: [.white, .white.opacity(0)],
                                       center: .center, startRadius: 0, endRadius: r)
                            .blendMode(.screen)
                            .mask(Circle())
                    )
                Circle().fill(Color.black).frame(width: r * 0.55, height: r * 0.55)
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

@MainActor
final class ThemePanelState: ObservableObject {
    static let shared = ThemePanelState()
    @Published var open = false
    private init() {}
}
