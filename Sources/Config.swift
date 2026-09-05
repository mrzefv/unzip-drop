//
//  Config.swift
//  GitHub target settings. Text fields persist to UserDefaults; the token
//  lives in the Keychain.
//

import SwiftUI

@MainActor
final class Config: ObservableObject {
    private let d = UserDefaults.standard

    @Published var owner:   String { didSet { d.set(owner,   forKey: "uzd_owner") } }
    @Published var repo:    String { didSet { d.set(repo,    forKey: "uzd_repo") } }
    @Published var branch:  String { didSet { d.set(branch,  forKey: "uzd_branch") } }
    @Published var subpath: String { didSet { d.set(subpath, forKey: "uzd_subpath") } }
    @Published var token:   String { didSet { Keychain.set("gh_token", token) } }

    var hasToken: Bool { !token.isEmpty }

    /// Strip whitespace/newlines that sneak in from paste and mobile keyboards.
    /// Never call this from a didSet — reassigning a @Published property inside
    /// its own observer violates exclusive access and crashes.
    static func clean(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// Binding that cleans on write. Use for every text field bound to Config.
    func cleaned(_ kp: ReferenceWritableKeyPath<Config, String>) -> Binding<String> {
        Binding(get: { self[keyPath: kp] },
                set: { self[keyPath: kp] = Self.clean($0) })
    }

    init() {
        owner   = Self.clean(d.string(forKey: "uzd_owner")   ?? "")
        repo    = Self.clean(d.string(forKey: "uzd_repo")    ?? "")
        branch  = Self.clean(d.string(forKey: "uzd_branch")  ?? "main")
        subpath = Self.clean(d.string(forKey: "uzd_subpath") ?? "")
        token   = Self.clean(Keychain.get("gh_token")        ?? "")
    }
}
