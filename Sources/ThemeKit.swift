//
//  ThemeKit.swift
//  Live theme state (accent · appearance · background), the palette dropdown
//  shown from the top bar, and the particle-network background.
//

import SwiftUI

// MARK: - State

enum ThemeBackground: String, CaseIterable, Identifiable {
    case particles, grid, none
    var id: String { rawValue }
    var title: String {
        switch self { case .particles: return "Particles"; case .grid: return "Grid"; case .none: return "Plain" }
    }
    var icon: String {
        switch self { case .particles: return "sparkles"; case .grid: return "square.grid.3x3"; case .none: return "rectangle" }
    }
}

@MainActor
final class AppTheme: ObservableObject {
    static let shared = AppTheme()
    private let d = UserDefaults.standard

    /// Bumped on every change; RootView re-ids the tab content so every view re-reads Theme.*.
    @Published private(set) var revision = 0
    @Published var panelShown = false

    @Published var accentHex: String { didSet { d.set(accentHex, forKey: Theme.keyAccent); bump() } }
    @Published var isDark: Bool { didSet { d.set(isDark, forKey: Theme.keyDark); bump() } }
    @Published var primaryHex: String { didSet { d.set(primaryHex, forKey: Theme.keyPrimary); bump() } }
    @Published var secondaryHex: String { didSet { d.set(secondaryHex, forKey: Theme.keySecondary); bump() } }
    @Published var background: ThemeBackground { didSet { d.set(background.rawValue, forKey: Theme.keyBackground); bump() } }

    private init() {
        accentHex  = Theme.accentHex
        isDark     = Theme.isDark
        primaryHex = d.string(forKey: Theme.keyPrimary) ?? (Theme.isDark ? "163041" : "CFE8FF")
        secondaryHex = d.string(forKey: Theme.keySecondary) ?? (Theme.isDark ? "0B1016" : "FFF3E8")
        background = ThemeBackground(rawValue: d.string(forKey: Theme.keyBackground) ?? "") ?? .particles
    }
    private func bump() { revision &+= 1 }

    var accent: Color { Color(hex: accentHex) }
    var primaryColor: Color { Color(hex: primaryHex) }
    var secondaryColor: Color { Color(hex: secondaryHex) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var activePreset: ThemePreset? {
        ThemePreset.presets.first {
            $0.primaryHex.uppercased() == primaryHex.uppercased() &&
            $0.secondaryHex.uppercased() == secondaryHex.uppercased() &&
            $0.accentHex.uppercased() == accentHex.uppercased()
        }
    }
    var activeGradient: ParticleGradient? {
        ParticleGradient.gradients.first {
            $0.colors.count >= 2 &&
            ($0.colors[0].hexString() ?? "") == primaryHex.uppercased() &&
            ($0.colors[1].hexString() ?? "") == secondaryHex.uppercased()
        }
    }

    static let presets: [String] = ["2ED9C3", "FFA773", "64CCFF", "B366FF", "FF66B2", "90EE90", "FFCC00", "FF453A", "FFFFFF"]

    func apply(_ preset: ThemePreset) {
        primaryHex = preset.primaryHex
        secondaryHex = preset.secondaryHex
        accentHex = preset.accentHex
    }

    func apply(_ gradient: ParticleGradient) {
        guard gradient.colors.count >= 2,
              let first = gradient.colors[0].hexString(),
              let second = gradient.colors[1].hexString() else { return }
        primaryHex = first
        secondaryHex = second
    }
}

// MARK: - Palette button (top bar)

struct ThemePaletteButton: View {
    @ObservedObject private var theme = AppTheme.shared
    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            theme.panelShown.toggle()
        } label: {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Theme")
    }
}

// MARK: - Dropdown panel

struct ThemePanel: View {
    @ObservedObject private var theme = AppTheme.shared
    @State private var showSwatches = false
    @State private var picked: Color = Theme.accent

    var body: some View {
        VStack(spacing: 10) {
            Menu {
                ForEach(ThemePreset.presets) { preset in
                    Button { theme.apply(preset) } label: {
                        Label(preset.name, systemImage: theme.activePreset?.id == preset.id ? "checkmark" : "paintpalette")
                    }
                }
            } label: {
                row(icon: "paintpalette.fill", swatch: nil, label: "THEME", value: theme.activePreset?.name ?? "Custom") {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.subtle)
                }
            }
            .buttonStyle(.plain)
            .background(panelCard)

            // Accent color
            VStack(spacing: 0) {
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showSwatches.toggle() } } label: {
                    row(icon: nil, swatch: Theme.accent, label: "ACCENT COLOR", value: "#\(theme.accentHex.uppercased())") {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.subtle)
                            .rotationEffect(.degrees(showSwatches ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)

                if showSwatches {
                    HStack(spacing: 8) {
                        ForEach(AppTheme.presets, id: \.self) { hex in
                            Button { theme.accentHex = hex; picked = Color(hex: hex) } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.white.opacity(theme.accentHex.uppercased() == hex ? 0.9 : 0.15), lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                        ColorPicker("", selection: $picked, supportsOpacity: false)
                            .labelsHidden().frame(width: 26, height: 26)
                            .onChange(of: picked) { c in if let h = c.hexString() { theme.accentHex = h } }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
            .background(panelCard)

            Menu {
                ForEach(ParticleGradient.gradients, id: \.name) { gradient in
                    Button { theme.apply(gradient) } label: {
                        Label(gradient.name, systemImage: theme.activeGradient?.name == gradient.name ? "checkmark" : "sparkles")
                    }
                }
            } label: {
                row(icon: "sparkles", swatch: nil, label: "DYNAMIC COLORS", value: theme.activeGradient?.name ?? "Custom mix") {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.subtle)
                }
            }
            .buttonStyle(.plain)
            .background(panelCard)

            // Appearance
            row(icon: theme.isDark ? "moon.fill" : "sun.max.fill", swatch: nil, label: "APPEARANCE", value: theme.isDark ? "Dark mode" : "Light mode") {
                Toggle("", isOn: $theme.isDark).labelsHidden().tint(Theme.accent)
            }
            .background(panelCard)

            // Background
            Menu {
                ForEach(ThemeBackground.allCases) { b in
                    Button { theme.background = b } label: {
                        Label(b.title, systemImage: b == theme.background ? "checkmark" : b.icon)
                    }
                }
            } label: {
                row(icon: theme.background.icon, swatch: nil, label: "BACKGROUND", value: theme.background.title) {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.subtle)
                }
            }
            .buttonStyle(.plain)
            .background(panelCard)
        }
        .padding(12)
        .frame(width: 320)
        .background(Theme.bg)
    }

    private var panelCard: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Theme.accent.opacity(theme.isDark ? 0.10 : 0.12))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.accent.opacity(0.25), lineWidth: 1))
    }

    private func row<T: View>(icon: String?, swatch: Color?, label: String, value: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(swatch ?? Theme.accent.opacity(0.18))
                if let icon { Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent) }
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 10, weight: .bold)).kerning(1.2).foregroundStyle(Theme.subtle)
                Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Backgrounds

/// Drifting node network (mSign look) tinted with the accent. Non-interactive.
struct ParticleBackground: View {
    var accent: Color = Theme.accent
    var colors: [Color] = [Theme.accent]
    var count: Int = 44
    var linkDistance: CGFloat = 120

    /// Reference box so the Canvas closure can advance the simulation without state churn.
    private final class Sim {
        struct Node { var x: CGFloat; var y: CGFloat; var vx: CGFloat; var vy: CGFloat }
        var nodes: [Node] = []
        var last: Date = .now

        func step(to date: Date, in size: CGSize, count: Int) -> [Node] {
            if nodes.count != count {
                nodes = (0..<count).map { _ in
                    Node(x: .random(in: 0...max(size.width, 1)), y: .random(in: 0...max(size.height, 1)),
                         vx: .random(in: -14...14), vy: .random(in: -14...14))
                }
            }
            let dt = CGFloat(min(max(date.timeIntervalSince(last), 0), 0.1))
            last = date
            for i in nodes.indices {
                nodes[i].x += nodes[i].vx * dt; nodes[i].y += nodes[i].vy * dt
                if nodes[i].x < 0 || nodes[i].x > size.width  { nodes[i].vx.negate(); nodes[i].x = min(max(nodes[i].x, 0), size.width) }
                if nodes[i].y < 0 || nodes[i].y > size.height { nodes[i].vy.negate(); nodes[i].y = min(max(nodes[i].y, 0), size.height) }
            }
            return nodes
        }
    }
    @State private var sim = Sim()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            Canvas { ctx, size in
                let ns = sim.step(to: tl.date, in: size, count: count)
                let palette = colors.isEmpty ? [accent] : colors
                var lines = Path()
                for i in 0..<ns.count {
                    for j in (i + 1)..<ns.count {
                        let dx = ns[i].x - ns[j].x, dy = ns[i].y - ns[j].y
                        let dist = sqrt(dx * dx + dy * dy)
                        guard dist < linkDistance else { continue }
                        lines.move(to: CGPoint(x: ns[i].x, y: ns[i].y))
                        lines.addLine(to: CGPoint(x: ns[j].x, y: ns[j].y))
                    }
                }
                ctx.stroke(lines, with: .color(palette[0].opacity(0.22)), lineWidth: 0.6)
                for (index, n) in ns.enumerated() {
                    let r: CGFloat = 2.2
                    let color = palette[index % palette.count]
                    ctx.fill(Path(ellipseIn: CGRect(x: n.x - r, y: n.y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(0.85)))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Static hairline grid.
struct GridBackground: View {
    var primary: Color = Theme.accent
    var secondary: Color = Theme.accent
    var body: some View {
        Canvas { ctx, size in
            var vertical = Path()
            var horizontal = Path()
            let step: CGFloat = 28
            var x: CGFloat = 0; while x <= size.width { vertical.move(to: CGPoint(x: x, y: 0)); vertical.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0; while y <= size.height { horizontal.move(to: CGPoint(x: 0, y: y)); horizontal.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(vertical, with: .color(primary.opacity(0.08)), lineWidth: 0.5)
            ctx.stroke(horizontal, with: .color(secondary.opacity(0.07)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

struct AmbientGradientBackground: View {
    var primary: Color
    var secondary: Color
    var accent: Color
    var isDark: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            GeometryReader { proxy in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let width = max(proxy.size.width, 1)
                let height = max(proxy.size.height, 1)
                ZStack {
                    glow(color: primary, size: width * 0.95, x: width * (0.18 + 0.06 * sin(t / 6)), y: height * (0.22 + 0.04 * cos(t / 5)))
                    glow(color: secondary, size: width * 0.9, x: width * (0.82 + 0.05 * cos(t / 7)), y: height * (0.28 + 0.05 * sin(t / 4.5)))
                    glow(color: accent, size: width, x: width * (0.5 + 0.08 * sin(t / 8)), y: height * (0.84 + 0.04 * cos(t / 6.5)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func glow(color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(isDark ? 0.22 : 0.16))
            .frame(width: size, height: size)
            .blur(radius: size * 0.16)
            .position(x: x, y: y)
    }
}

/// Picks the configured background overlay.
struct ThemeBackgroundLayer: View {
    @ObservedObject private var theme = AppTheme.shared
    var body: some View {
        ZStack {
            AmbientGradientBackground(primary: theme.primaryColor, secondary: theme.secondaryColor, accent: theme.accent, isDark: theme.isDark)
            switch theme.background {
            case .particles:
                ParticleBackground(accent: theme.accent, colors: [theme.accent, theme.primaryColor, theme.secondaryColor])
            case .grid:
                GridBackground(primary: theme.primaryColor, secondary: theme.secondaryColor)
            case .none:
                EmptyView()
            }
        }
    }
}
