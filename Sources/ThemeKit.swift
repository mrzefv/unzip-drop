//
//  ThemeKit.swift
//  App-wide theme: live accent color, dark-mode toggle, and an animated
//  particle background that renders behind every tab. Driven by ThemeManager
//  (an ObservableObject) so changing the accent updates the whole app live.
//

import SwiftUI

// MARK: - Theme store

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var accentHex: String { didSet { UserDefaults.standard.set(accentHex, forKey: "theme_accent_hex"); Theme.setAccentColor(hex: accentHex) } }
    @Published var darkMode: Bool { didSet { UserDefaults.standard.set(darkMode, forKey: "theme_dark_mode") } }
    @Published var background: BackgroundStyle { didSet { UserDefaults.standard.set(background.rawValue, forKey: "theme_bg_style") } }

    enum BackgroundStyle: String, CaseIterable, Identifiable {
        case particles = "Particles"
        case solid = "Solid"
        case gradient = "Gradient"
        var id: String { rawValue }
        var icon: String {
            switch self { case .particles: return "sparkles"; case .solid: return "square.fill"; case .gradient: return "circle.lefthalf.filled" }
        }
    }

    var accent: Color { Color(hex: accentHex) }

    static let presets: [String] = [
        "#FF9500", "#FF3B30", "#AF52DE", "#0A84FF",
        "#30B0A0", "#34C759", "#FF2D55", "#5E5CE6",
    ]

    private init() {
        accentHex = UserDefaults.standard.string(forKey: "theme_accent_hex") ?? "#FF9500"
        darkMode = UserDefaults.standard.object(forKey: "theme_dark_mode") as? Bool ?? true
        background = BackgroundStyle(rawValue: UserDefaults.standard.string(forKey: "theme_bg_style") ?? "") ?? .particles
    }
}

// MARK: - Animated particle background

struct ParticleBackground: View {
    var accent: Color
    var style: ThemeManager.BackgroundStyle

    var body: some View {
        switch style {
        case .solid:
            Color.black.ignoresSafeArea()
        case .gradient:
            LinearGradient(colors: [.black, accent.opacity(0.18), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        case .particles:
            ZStack {
                Color.black
                ParticleField(color: accent)
            }
            .ignoresSafeArea()
        }
    }
}

/// A lightweight constellation field: nodes drift, near ones link with lines.
/// TimelineView drives the animation so it runs in every tab background cheaply.
struct ParticleField: View {
    var color: Color
    private let count = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                var pts: [CGPoint] = []
                pts.reserveCapacity(count)
                for i in 0..<count {
                    let seed = Double(i) * 12.9898
                    let sx = abs(sin(seed) )
                    let sy = abs(cos(seed * 1.7))
                    // slow drift
                    let x = (sx + 0.04 * sin(t * 0.15 + seed)).truncatingRemainder(dividingBy: 1) * size.width
                    let y = (sy + 0.04 * cos(t * 0.12 + seed)).truncatingRemainder(dividingBy: 1) * size.height
                    pts.append(CGPoint(x: abs(x), y: abs(y)))
                }
                // links
                for i in 0..<pts.count {
                    for j in (i + 1)..<pts.count {
                        let dx = pts[i].x - pts[j].x, dy = pts[i].y - pts[j].y
                        let dist = (dx * dx + dy * dy).squareRoot()
                        if dist < 120 {
                            var path = Path()
                            path.move(to: pts[i]); path.addLine(to: pts[j])
                            ctx.stroke(path, with: .color(color.opacity(0.35 * (1 - dist / 120))), lineWidth: 0.6)
                        }
                    }
                }
                // nodes
                for p in pts {
                    let r: CGFloat = 2
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(color.opacity(0.8)))
                }
            }
        }
        .drawingGroup()
    }
}

// MARK: - Palette dropdown (matches the reference)

struct ThemePalettePanel: View {
    @ObservedObject var theme = ThemeManager.shared
    @Binding var expandedWheel: Bool
    @Binding var expandedBackground: Bool
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Accent color card (collapsible wheel)
            card {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10).fill(theme.accent).frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ACCENT COLOR").font(.system(size: 11, weight: .heavy)).kerning(1).foregroundStyle(Theme.subtle)
                            Text(theme.accentHex.uppercased()).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        }
                        Spacer()
                        Button { withAnimation { expandedWheel.toggle() } } label: {
                            Image(systemName: expandedWheel ? "chevron.up" : "chevron.down").foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    if expandedWheel {
                        ColorWheel(hex: $theme.accentHex).frame(height: 260)
                        HStack(spacing: 12) {
                            ForEach(ThemeManager.presets, id: \.self) { hex in
                                Button { theme.accentHex = hex } label: {
                                    Circle().fill(Color(hex: hex)).frame(width: 34, height: 34)
                                        .overlay(Circle().stroke(.white.opacity(theme.accentHex.caseInsensitiveCompare(hex) == .orderedSame ? 0.9 : 0), lineWidth: 2))
                                }
                            }
                        }
                    }
                }
            }

            // Dark mode
            card {
                HStack(spacing: 12) {
                    tile("moon.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("APPEARANCE").font(.system(size: 11, weight: .heavy)).kerning(1).foregroundStyle(Theme.subtle)
                        Text("Dark mode").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    }
                    Spacer()
                    Toggle("", isOn: $theme.darkMode).labelsHidden().tint(theme.accent)
                }
            }

            // Background style (collapsible)
            card {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        tile("sparkles")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BACKGROUND").font(.system(size: 11, weight: .heavy)).kerning(1).foregroundStyle(Theme.subtle)
                            Text(theme.background.rawValue).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        }
                        Spacer()
                        Button { withAnimation { expandedBackground.toggle() } } label: {
                            Image(systemName: expandedBackground ? "chevron.up" : "chevron.down").foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    if expandedBackground {
                        HStack(spacing: 10) {
                            ForEach(ThemeManager.BackgroundStyle.allCases) { s in
                                Button { theme.background = s } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: s.icon).font(.system(size: 16))
                                        Text(s.rawValue).font(.system(size: 11, weight: .semibold))
                                    }
                                    .padding(.vertical, 10).frame(maxWidth: .infinity)
                                    .background(theme.background == s ? theme.accent.opacity(0.2) : Color(white: 0.1))
                                    .foregroundStyle(theme.background == s ? theme.accent : Theme.subtle)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.background == s ? theme.accent : Theme.stroke, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.10, green: 0.08, blue: 0.12))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.accent.opacity(0.6), lineWidth: 1))
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
        ZStack { RoundedRectangle(cornerRadius: 10).fill(theme.accent.opacity(0.18)).frame(width: 40, height: 40)
            Image(systemName: icon).foregroundStyle(theme.accent) }
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
                // hue/sat wheel
                AngularGradient(gradient: Gradient(colors: wheelColors), center: .center)
                    .mask(Circle())
                    .overlay(
                        RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: r)
                            .blendMode(.screen).mask(Circle())
                    )
                Circle().fill(Color.black).frame(width: r * 0.55, height: r * 0.55)   // hollow center like the ref
                // selector
                Circle().stroke(.white, lineWidth: 3).frame(width: 30, height: 30).position(pos == .zero ? c : pos)
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
        stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) }
    }
}

extension Color {
    func toHex() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Shared open/close state for the palette panel (any tab's palette button toggles it)

@MainActor
final class ThemePanelState: ObservableObject {
    static let shared = ThemePanelState()
    @Published var open = false
    private init() {}
}
