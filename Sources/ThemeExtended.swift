//
//  ThemeExtended.swift
//  Advanced theme system with gradients and multi-color support.
//

import SwiftUI

// MARK: - Theme Presets

struct ThemePreset: Identifiable {
    let id: String
    let name: String
    let primaryHex: String
    let secondaryHex: String
    let accentHex: String
    let description: String
    
    func apply() {
        Theme.setAccentColor(hex: accentHex)
        UserDefaults.standard.set(primaryHex, forKey: "theme_primary_hex")
        UserDefaults.standard.set(secondaryHex, forKey: "theme_secondary_hex")
    }
}

extension ThemePreset {
    static let presets: [ThemePreset] = [
        ThemePreset(
            id: "ocean",
            name: "Ocean",
            primaryHex: "006994",
            secondaryHex: "00D4FF",
            accentHex: "64CCFF",
            description: "Cool blue ocean vibes"
        ),
        ThemePreset(
            id: "sunset",
            name: "Sunset",
            primaryHex: "FF6B35",
            secondaryHex: "FF9933",
            accentHex: "FFCC00",
            description: "Warm sunset colors"
        ),
        ThemePreset(
            id: "forest",
            name: "Forest",
            primaryHex: "1B4D3E",
            secondaryHex: "66CC99",
            accentHex: "90EE90",
            description: "Natural forest tones"
        ),
        ThemePreset(
            id: "cyberpunk",
            name: "Cyberpunk",
            primaryHex: "FF00FF",
            secondaryHex: "00FFFF",
            accentHex: "B366FF",
            description: "Neon cyberpunk style"
        ),
        ThemePreset(
            id: "candy",
            name: "Candy",
            primaryHex: "FF1493",
            secondaryHex: "FF69B4",
            accentHex: "FF66B2",
            description: "Sweet candy colors"
        ),
        ThemePreset(
            id: "minimal",
            name: "Minimal",
            primaryHex: "FFFFFF",
            secondaryHex: "CCCCCC",
            accentHex: "333333",
            description: "Clean minimal design"
        )
    ]
}

// MARK: - Multi-Color Particle Gradients

struct ParticleGradient {
    let colors: [Color]
    let name: String
    
    static let gradients: [ParticleGradient] = [
        ParticleGradient(
            colors: [Color(hex: "FF6B6B"), Color(hex: "4ECDC4")],
            name: "Coral Wave"
        ),
        ParticleGradient(
            colors: [Color(hex: "667EEA"), Color(hex: "764BA2")],
            name: "Purple Dream"
        ),
        ParticleGradient(
            colors: [Color(hex: "F093FB"), Color(hex: "F5576C")],
            name: "Pink Sunset"
        ),
        ParticleGradient(
            colors: [Color(hex: "4FACFE"), Color(hex: "00F2FE")],
            name: "Cyan Wave"
        ),
        ParticleGradient(
            colors: [Color(hex: "43E97B"), Color(hex: "38F9D7")],
            name: "Mint Fresh"
        ),
        ParticleGradient(
            colors: [Color(hex: "FA709A"), Color(hex: "FEE140")],
            name: "Warm Fire"
        )
    ]
}

// MARK: - System Theme Sync

struct SystemThemeSync {
    static func syncWithSystem() {
        let appearance = UITraitCollection.current.userInterfaceStyle
        UserDefaults.standard.set(
            appearance == .dark ? "dark" : "light",
            forKey: "theme_appearance_mode"
        )
    }
    
    static func shouldUseDarkMode() -> Bool {
        let saved = UserDefaults.standard.string(forKey: "theme_appearance_mode")
        if saved == "auto" {
            return UITraitCollection.current.userInterfaceStyle == .dark
        }
        return saved == "dark"
    }
}

// MARK: - Color Extension for Hex Support

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let rgb = Int(hex, radix: 16) ?? 0
        
        let red = Double((rgb >> 16) & 0xFF) / 255.0
        let green = Double((rgb >> 8) & 0xFF) / 255.0
        let blue = Double(rgb & 0xFF) / 255.0
        
        self.init(red: red, green: green, blue: blue)
    }
}
