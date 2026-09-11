//
//  UserRole.swift
//  SIPA / msign
//
//  Local, server-independent role model.
//
//  Everyone is `.member` by default. `.developer` and `.admin` are granted
//  on-device via an unlock code (see MSAccountService.unlock) and the grant
//  is persisted in the Keychain (AVXIDManager), so it survives app updates
//  and delete/reinstall — no API involved.
//

import SwiftUI

enum UserRole: String, Codable, CaseIterable, Comparable {
    case member
    case developer
    case admin

    /// Higher rank = more privilege.
    var rank: Int {
        switch self {
        case .member:    return 0
        case .developer: return 1
        case .admin:     return 2
        }
    }

    static func < (lhs: UserRole, rhs: UserRole) -> Bool { lhs.rank < rhs.rank }

    var title: String {
        switch self {
        case .member:    return "Member"
        case .developer: return "Developer"
        case .admin:     return "Admin"
        }
    }

    var badgeText: String { title.uppercased() }

    var icon: String {
        switch self {
        case .member:    return "person.fill"
        case .developer: return "hammer.fill"
        case .admin:     return "crown.fill"
        }
    }

    var color: Color {
        switch self {
        case .member:    return .green
        case .developer: return .cyan
        case .admin:     return .red
        }
    }

    // MARK: - Privilege gates
    //
    // Baseline features stay available to everyone (.member). These flags
    // describe the *extra* surfaces unlocked for elevated roles. Tune freely.

    /// At or above Developer.
    var isElevated: Bool { self >= .developer }

    /// Exactly Admin.
    var isAdmin: Bool { self == .admin }

    var canAccessAdvanced:       Bool { self >= .developer }
    var canAccessDeveloperTools: Bool { self >= .developer }
    var canManageSources:        Bool { self >= .developer }
    var canAccessAdminTools:     Bool { self == .admin }
}

// MARK: - Role gating for SwiftUI

extension View {
    /// Show the view only when the current role meets `min`. Otherwise it is
    /// removed from the hierarchy entirely.
    ///
    ///     SomeAdminRow().roleGated(.admin)
    ///     advancedSection.roleGated(.developer)
    @ViewBuilder
    func roleGated(_ min: UserRole) -> some View {
        if MSAccountService.shared.role >= min {
            self
        }
    }
}
