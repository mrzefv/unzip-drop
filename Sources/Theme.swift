//
//  Theme.swift
//  Adaptive palette. Every color is computed from AppTheme's persisted state
//  (accent hex + dark/light) so a theme change re-skins the whole app.
//

import SwiftUI

nonisolated enum Theme {
    static let keyAccent     = "theme_accent_hex"
    static let keyDark       = "theme_dark"
    static let keyBackground = "theme_background"
    static let defaultAccent = "2ED9C3"

    static var isDark: Bool {
        UserDefaults.standard.object(forKey: keyDark) == nil ? true : UserDefaults.standard.bool(forKey: keyDark)
    }
    static var accentHex: String {
        let h = UserDefaults.standard.string(forKey: keyAccent) ?? ""
        return h.isEmpty ? defaultAccent : h
    }

    static var bg: Color     { isDark ? Color(red: 0.06, green: 0.07, blue: 0.08) : Color(red: 0.96, green: 0.96, blue: 0.97) }
    static var card: Color   { isDark ? Color(red: 0.11, green: 0.12, blue: 0.14) : Color.white }
    static var stroke: Color { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08) }
    static var text: Color   { isDark ? Color(red: 0.92, green: 0.95, blue: 0.96) : Color(red: 0.08, green: 0.09, blue: 0.10) }
    static var subtle: Color { isDark ? Color(red: 0.55, green: 0.60, blue: 0.63) : Color(red: 0.42, green: 0.46, blue: 0.49) }
    static var accent: Color { Color(hex: accentHex) }

    static let appName    = "mSign"
    static let appVersion = "1.0"
    static let owner      = "MRzefv · mrzefv.com"
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
