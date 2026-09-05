//
//  Config.swift
//  GitHub target settings. Text fields persist to UserDefaults; the token
//  lives in the Keychain.
//

import SwiftUI

@MainActor
final class Config: ObservableObject {
    private let d = UserDefaults.standard

    @Published var owner:   String { didSet { owner = Self.clean(owner);     d.set(owner,   forKey: "uzd_owner") } }
    @Published var repo:    String { didSet { repo = Self.clean(repo);       d.set(repo,    forKey: "uzd_repo") } }
    @Published var branch:  String { didSet { branch = Self.clean(branch);   d.set(branch,  forKey: "uzd_branch") } }
    @Published var subpath: String { didSet { subpath = Self.clean(subpath); d.set(subpath, forKey: "uzd_subpath") } }
    @Published var token:   String { didSet { token = Self.clean(token);     Keychain.set("gh_token", token) } }

    /// Strip whitespace/newlines that sneak in from paste and mobile keyboards.
    private static func clean(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    var hasToken: Bool { !token.isEmpty }

    init() {
        owner   = Self.clean(d.string(forKey: "uzd_owner")   ?? "")
        repo    = Self.clean(d.string(forKey: "uzd_repo")    ?? "")
        branch  = Self.clean(d.string(forKey: "uzd_branch")  ?? "main")
        subpath = Self.clean(d.string(forKey: "uzd_subpath") ?? "")
        token   = Self.clean(Keychain.get("gh_token")        ?? "")
    }
}
