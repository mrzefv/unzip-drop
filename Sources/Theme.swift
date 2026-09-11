//
//  Theme.swift
//

import SwiftUI

enum Theme {
    static let bg      = Color(red: 0.06, green: 0.07, blue: 0.08)
    static let card    = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let stroke  = Color.white.opacity(0.08)
    static let text    = Color(red: 0.92, green: 0.95, blue: 0.96)
    static let subtle  = Color(red: 0.55, green: 0.60, blue: 0.63)
    static let accent  = Color(red: 0.18, green: 0.85, blue: 0.76)

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
