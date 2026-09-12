//
//  ZefvAccountScreen.swift
//  Optional account onboarding — Sign in / Register against the VPS API.
//  Presented from the Settings footer when there is no account, and re-usable
//  from the first-run onboarding "Create account" path.
//

import SwiftUI

struct ZefvAccountScreen: View {
    @ObservedObject private var account = ZefvAccount.shared
    @Environment(\.dismiss) private var dismiss

    enum Mode { case signIn, register }
    @State private var mode: Mode
    @State private var username = ""
    @State private var password = ""
    /// false when embedded in AccountScreen — stay put and let the profile take over.
    let dismissOnSuccess: Bool

    init(mode: Mode = .register, dismissOnSuccess: Bool = true) {
        _mode = State(initialValue: mode); self.dismissOnSuccess = dismissOnSuccess
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ThemeBackgroundLayer()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    header

                    Picker("", selection: $mode) {
                        Text("Register").tag(Mode.register)
                        Text("Sign In").tag(Mode.signIn)
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: 10) {
                        field("Username", text: $username, secure: false)
                        field("Password", text: $password, secure: true)
                    }

                    if let e = account.lastError {
                        Text(e).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: submit) {
                        HStack {
                            if account.busy { ProgressView().tint(.black) }
                            Text(mode == .register ? "Create account" : "Sign in")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent).foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(account.busy || username.isEmpty || password.isEmpty)

                    VStack(spacing: 4) {
                        Text("Your device ID (MDID)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.subtle)
                        Text(MDID.current).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
                        Text("An account links this MDID to a role across reinstalls. You can also keep using the app as a guest.")
                            .font(.system(size: 11)).foregroundStyle(Theme.subtle).multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(AppTheme.shared.colorScheme)
        .onChange(of: account.isLoggedIn) { if $0 && dismissOnSuccess { dismiss() } }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34).background(Theme.accent.opacity(0.14)).clipShape(Circle())
                }
            }
            OnboardingLogo(size: 84)
            Text(mode == .register ? "Create an MSign account" : "Welcome back")
                .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
        }
    }

    private func field(_ ph: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField(ph, text: text) }
            else { TextField(ph, text: text).autocorrectionDisabled().textInputAutocapitalization(.never) }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14).padding(.vertical, 13)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func submit() {
        Task {
            _ = mode == .register
                ? await account.register(username: username, password: password)
                : await account.login(username: username, password: password)
        }
    }
}
