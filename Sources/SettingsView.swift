//
//  SettingsView.swift
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var config: Config
    @State private var showToken = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    HStack { Text("Settings").font(.title2.bold()).foregroundStyle(Theme.text); Spacer() }

                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Target repo", systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.headline).foregroundStyle(Theme.text)
                            field("Owner",  $config.owner,   "mrzefv")
                            field("Repo",   $config.repo,    "my-repo")
                            field("Branch", $config.branch,  "main")
                            field("Subpath (optional)", $config.subpath, "e.g. incoming")
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Access token", systemImage: "key.fill").font(.headline).foregroundStyle(Theme.text)
                            Text("Fine-grained or classic PAT with Contents: read & write on the target repo. Stored in the Keychain, never leaves the device except to api.github.com.")
                                .font(.caption).foregroundStyle(Theme.subtle)
                            HStack {
                                Group {
                                    if showToken { TextField("github_pat_… / ghp_…", text: $config.token) }
                                    else { SecureField("github_pat_… / ghp_…", text: $config.token) }
                                }
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(10).background(Theme.bg).foregroundStyle(Theme.text)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                Button { showToken.toggle() } label: {
                                    Image(systemName: showToken ? "eye.slash" : "eye").foregroundStyle(Theme.subtle)
                                }
                            }
                            if config.hasToken {
                                Button(role: .destructive) { config.token = "" } label: {
                                    Label("Clear token", systemImage: "trash").font(.caption)
                                }
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Theme.appName).font(.headline).foregroundStyle(Theme.text)
                            Text("Version \(Theme.appVersion)").font(.caption).foregroundStyle(Theme.subtle)
                            Text("Drop a zip, extract on-device, push the files straight to a repo.")
                                .font(.caption2).foregroundStyle(Theme.subtle)
                        }
                    }

                    Text(Theme.owner).font(.footnote).foregroundStyle(Theme.subtle)
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Theme.subtle)
            TextField(placeholder, text: text)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .padding(10).background(Theme.bg).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
