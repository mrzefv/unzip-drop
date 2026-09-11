//
//  SSTheme.swift
//  Ported from mSign (Layer 1). Adaptive light/dark theme + orange tint default.
//
//  NOTE: mSign's original file also declared `Color(hex:)` / `hexString()`.
//  unzip-drop already ships a non-failable `Color(hex:)` in ThemeExtended.swift,
//  so those are provided by the adapter at the bottom instead of redeclared here.
//

import Foundation
import SwiftUI
import UIKit

struct SSTheme {
    // MARK: - Tint Color (orange by default)

    static var tintColor: Color {
        if let hexString = UserDefaults.standard.string(forKey: "appTintColorHex"),
           !hexString.isEmpty {
            return Color(hex: hexString)
        }
        return Color(hex: "FF9500")
    }

    // MARK: - Static Color Properties (backward compatibility)

    static let bg = Color.black
    static let green = Color.green
    static let subtle = Color.white.opacity(0.55)
    static let cardBg = Color(red: 0.1, green: 0.1, blue: 0.1)
    static let redBundle = Color.red.opacity(0.78)

    // MARK: - Adaptive Functions (Light/Dark Mode)

    static func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.1, green: 0.1, blue: 0.1) : Color(red: 0.95, green: 0.95, blue: 0.95)
    }

    static func subtleText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.55)
    }
}

// MARK: - Adaptive color helpers (from mSign SSThemeHelpers)

enum AdaptiveColors {
    static func background(_ cs: ColorScheme) -> Color { cs == .dark ? .black : .white }
    static func secondaryBackground(_ cs: ColorScheme) -> Color { cs == .dark ? Color(white: 0.12) : Color(white: 0.95) }
    static func cardBackground(_ cs: ColorScheme) -> Color { cs == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04) }
    static func border(_ cs: ColorScheme) -> Color { cs == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.1) }
    static func primaryText(_ cs: ColorScheme) -> Color { cs == .dark ? .white : Color(white: 0.1) }
    static func secondaryText(_ cs: ColorScheme) -> Color { cs == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6) }
    static func tertiaryText(_ cs: ColorScheme) -> Color { cs == .dark ? Color.white.opacity(0.5) : Color.black.opacity(0.45) }
}

enum AdaptiveTextStyle { case primary, secondary, tertiary }

extension View {
    func adaptiveBackground(_ cs: ColorScheme) -> some View { background(AdaptiveColors.background(cs)) }
    @ViewBuilder func adaptiveForeground(_ cs: ColorScheme, style: AdaptiveTextStyle = .primary) -> some View {
        switch style {
        case .primary:   foregroundColor(AdaptiveColors.primaryText(cs))
        case .secondary: foregroundColor(AdaptiveColors.secondaryText(cs))
        case .tertiary:  foregroundColor(AdaptiveColors.tertiaryText(cs))
        }
    }
}

struct AdaptiveTheme {
    let colorScheme: ColorScheme
    var background: Color { AdaptiveColors.background(colorScheme) }
    var secondaryBackground: Color { AdaptiveColors.secondaryBackground(colorScheme) }
    var cardBackground: Color { AdaptiveColors.cardBackground(colorScheme) }
    var border: Color { AdaptiveColors.border(colorScheme) }
    var primaryText: Color { AdaptiveColors.primaryText(colorScheme) }
    var secondaryText: Color { AdaptiveColors.secondaryText(colorScheme) }
    var tertiaryText: Color { AdaptiveColors.tertiaryText(colorScheme) }
    var tint: Color { SSTheme.tintColor }
    var bg: Color { SSTheme.background(for: colorScheme) }
    var cardBg: Color { SSTheme.cardBackground(for: colorScheme) }
    var subtle: Color { SSTheme.subtleText(for: colorScheme) }
}

// MARK: - Adapter: mSign expects a failable Color(hex:) returning Color?

extension Color {
    /// mSign code calls `Color(hex: x) ?? fallback`. unzip-drop's `Color(hex:)`
    /// is non-failable, so this bridges the optional call sites without a redeclare clash.
    static func msHex(_ hex: String) -> Color? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 3 || h.count == 6 || h.count == 8, Int(h, radix: 16) != nil else { return nil }
        return Color(hex: hex)
    }

    /// Hex string for the current color (used by tint pickers).
    func hexString() -> String? {
        let ui = UIColor(self)
        guard let comps = ui.cgColor.components, comps.count >= 3 else { return nil }
        return String(format: "%02lX%02lX%02lX",
                      lroundf(Float(comps[0]) * 255),
                      lroundf(Float(comps[1]) * 255),
                      lroundf(Float(comps[2]) * 255))
    }
}
