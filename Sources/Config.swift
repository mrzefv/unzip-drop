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

    init() {
        owner   = d.string(forKey: "uzd_owner")   ?? ""
        repo    = d.string(forKey: "uzd_repo")    ?? ""
        branch  = d.string(forKey: "uzd_branch")  ?? "main"
        subpath = d.string(forKey: "uzd_subpath") ?? ""
        token   = Keychain.get("gh_token")        ?? ""
    }
}
