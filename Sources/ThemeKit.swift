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
    @Published var background: ThemeBackground { didSet { d.set(background.rawValue, forKey: Theme.keyBackground); bump() } }

    private init() {
        accentHex  = Theme.accentHex
        isDark     = Theme.isDark
        background = ThemeBackground(rawValue: d.string(forKey: Theme.keyBackground) ?? "") ?? .particles
    }
    private func bump() { revision &+= 1 }

    var accent: Color { Color(hex: accentHex) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }

    static let presets: [String] = ["2ED9C3", "FFA773", "64CCFF", "B366FF", "FF66B2", "90EE90", "FFCC00", "FF453A", "FFFFFF"]
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
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
        VStack(spacing: 8) {
            // Accent color
            VStack(spacing: 0) {
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showSwatches.toggle() } } label: {
                    row(icon: nil, swatch: Theme.accent, label: "ACCENT COLOR", value: "#\(theme.accentHex.uppercased())") {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.subtle)
                            .rotationEffect(.degrees(showSwatches ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)

                if showSwatches {
                    HStack(spacing: 8) {
                        ForEach(AppTheme.presets, id: \.self) { hex in
                            Button { theme.accentHex = hex; picked = Color(hex: hex) } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Color.white.opacity(theme.accentHex.uppercased() == hex ? 0.9 : 0.15), lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                        ColorPicker("", selection: $picked, supportsOpacity: false)
                            .labelsHidden().frame(width: 22, height: 22)
                            .onChange(of: picked) { c in if let h = c.hexString() { theme.accentHex = h } }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 10)
                }
            }
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
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.subtle)
                }
            }
            .buttonStyle(.plain)
            .background(panelCard)
        }
        .padding(8)
        .frame(width: 270)
        .background(Theme.bg)
    }

    private var panelCard: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Theme.accent.opacity(theme.isDark ? 0.10 : 0.12))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accent.opacity(0.25), lineWidth: 1))
    }

    private func row<T: View>(icon: String?, swatch: Color?, label: String, value: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(swatch ?? Theme.accent.opacity(0.18))
                if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent) }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 9, weight: .bold)).kerning(1.1).foregroundStyle(Theme.subtle)
                Text(value).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Backgrounds

/// Drifting node network (mSign look) tinted with the accent. Non-interactive.
struct ParticleBackground: View {
    var accent: Color = Theme.accent
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
                ctx.stroke(lines, with: .color(accent.opacity(0.22)), lineWidth: 0.6)
                for n in ns {
                    let r: CGFloat = 2.2
                    ctx.fill(Path(ellipseIn: CGRect(x: n.x - r, y: n.y - r, width: r * 2, height: r * 2)), with: .color(accent.opacity(0.85)))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Static hairline grid.
struct GridBackground: View {
    var accent: Color = Theme.accent
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            let step: CGFloat = 28
            var x: CGFloat = 0; while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0; while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(p, with: .color(accent.opacity(0.07)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Picks the configured background overlay.
struct ThemeBackgroundLayer: View {
    @ObservedObject private var theme = AppTheme.shared
    var body: some View {
        switch theme.background {
        case .particles: ParticleBackground(accent: theme.accent)
        case .grid:      GridBackground(accent: theme.accent)
        case .none:      EmptyView()
        }
    }
}
