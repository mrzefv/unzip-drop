//
//  ZefvAccountScreen.swift
//  Full-screen zefv.dev account management. Handles the three states:
//    * Not signed in → tabbed login / register form
//    * Signed in     → profile card with rank/XP/quota, linked devices,
//                      rename, change password, logout, delete-app-data
//    * Auto-refresh on appear
//
//  Design tokens match the existing app (Theme.accent, AccentBarBlur, etc).
//  Presented via .fullScreenCover from SettingsView.
//

import SwiftUI

struct ZefvAccountScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = ZefvClient.shared

    @State private var loading = false
    @State private var error: String?
    @State private var mode: AuthMode = .login   // used when not signed in
    @State private var devices: [ZefvDevice] = []
    @State private var showChangePassword = false
    @State private var showRename = false

    enum AuthMode { case login, register }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Group {
                    if let user = client.currentUser {
                        profileScroll(user: user)
                    } else {
                        authForm
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .bold))
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("zefv.dev")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .kerning(0.5)
                    }
                }
            }
            .task { await ensureFreshUser() }
            .sheet(isPresented: $showChangePassword) {
                ChangePasswordSheet().preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showRename) {
                RenameSheet().preferredColorScheme(.dark)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Not signed in — login / register

    private var authForm: some View {
        ScrollView {
            VStack(spacing: 22) {

                // Header
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 20)
                    Text(mode == .login ? "Sign in to zefv.dev" : "Create your zefv.dev account")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(mode == .login
                         ? "Continue with an existing username."
                         : "Your username becomes your subdomain: username.zefv.dev")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                // Mode picker
                Picker("", selection: $mode) {
                    Text("Sign in").tag(AuthMode.login)
                    Text("Register").tag(AuthMode.register)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 22)

                if mode == .login {
                    LoginForm(loading: $loading, error: $error)
                } else {
                    RegisterForm(loading: $loading, error: $error)
                }

                if let error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22)
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 8)
        }
        .disabled(loading)
    }

    // MARK: - Signed in — profile

    @ViewBuilder
    private func profileScroll(user: ZefvUser) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                profileHeader(user)
                identityCard(user)
                statsCard(user)
                devicesCard
                accountActions
                if let error {
                    Text(error).font(.system(size: 13))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22)
                }
                Spacer(minLength: 20)
            }
            .padding(.top, 8)
            .padding(.horizontal, 16)
        }
        .refreshable { await ensureFreshUser(force: true) }
    }

    private func profileHeader(_ user: ZefvUser) -> some View {
        VStack(spacing: 10) {
            avatar(user)
                .padding(.top, 8)
            SlugText(user, size: 26)
            RankChip(user: user)
            if let name = user.display_name, !name.isEmpty {
                Text(name)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text("\(user.username).zefv.dev")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private func avatar(_ user: ZefvUser) -> some View {
        ZStack {
            Circle().fill(avatarBg(user)).frame(width: 84, height: 84)
            Text(String(user.username.prefix(2)).uppercased())
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
    private func avatarBg(_ user: ZefvUser) -> some ShapeStyle {
        if let hexes = user.style.gradient, hexes.count >= 2 {
            let stops = hexes.compactMap { Color(zefvHex: $0) }
            return AnyShapeStyle(LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        if let hex = user.style.color, let c = Color(zefvHex: hex) {
            return AnyShapeStyle(c.opacity(0.7))
        }
        return AnyShapeStyle(Color.gray.opacity(0.4))
    }

    private func identityCard(_ user: ZefvUser) -> some View {
        VStack(spacing: 12) {
            row(icon: "person.crop.circle", title: "Username", value: user.username)
            divider
            row(icon: "signature", title: "Display name", value: user.display_name?.isEmpty == false ? user.display_name! : "—")
            divider
            row(icon: "link", title: "Subdomain", value: "\(user.username).zefv.dev")
        }
        .padding(14)
        .background(cardBg)
    }

    private func statsCard(_ user: ZefvUser) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            XPProgress(user: user)
            divider
            HStack(spacing: 12) {
                stat(label: "Rank", value: user.rank_name)
                stat(label: "Level", value: "\(user.level)")
                stat(label: "XP", value: "\(user.xp)")
            }
            divider
            HStack(spacing: 12) {
                stat(label: "Used",  value: byteString(user.bytes_used))
                stat(label: "Quota", value: user.quota_bytes < 0 ? "Unlimited" : byteString(user.quota_bytes))
            }
        }
        .padding(14)
        .background(cardBg)
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Linked devices")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("\(devices.count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            if devices.isEmpty {
                Text("Loading…").font(.caption).foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(devices) { d in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: mdidIsThisDevice(d.mdid) ? "iphone.radiowaves.left.and.right" : "iphone")
                            .foregroundStyle(mdidIsThisDevice(d.mdid) ? Theme.accent : .white.opacity(0.5))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(d.device_name ?? "Unnamed device")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                if mdidIsThisDevice(d.mdid) {
                                    Text("THIS DEVICE")
                                        .font(.system(size: 9, weight: .heavy))
                                        .kerning(0.5)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Theme.accent.opacity(0.2))
                                        .foregroundStyle(Theme.accent)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(d.mdid)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(14)
        .background(cardBg)
    }

    private var accountActions: some View {
        VStack(spacing: 10) {
            actionButton(icon: "pencil.circle.fill", title: "Change username", tint: Theme.accent) {
                showRename = true
            }
            actionButton(icon: "key.fill", title: "Change password", tint: Theme.accent) {
                showChangePassword = true
            }
            actionButton(icon: "arrow.right.circle", title: "Sign out", tint: .white) {
                Task {
                    loading = true
                    await client.logout()
                    loading = false
                }
            }
            actionButton(icon: "trash.circle", title: "Sign out & wipe local data", tint: .orange) {
                Task {
                    loading = true
                    await client.logout()
                    _ = MDID.reset()
                    loading = false
                }
            }
        }
    }

    // MARK: - Row helpers

    private func row(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            Spacer()
        }
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .heavy)).kerning(0.5)
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionButton(icon: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 22)
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(14)
            .background(cardBg)
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
    }
    private var cardBg: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(white: 0.09))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    // MARK: - Data ops

    private func ensureFreshUser(force: Bool = false) async {
        error = nil
        guard client.isAuthenticated else { return }
        if !force, client.currentUser != nil {
            // Still fetch devices even if user is cached
            await loadDevices()
            return
        }
        do {
            _ = try await client.refresh()
            await loadDevices()
        } catch let e as ZefvError where e.status == 401 {
            // Server rejected token — client already cleared it
            error = "Session expired — please sign in again."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadDevices() async {
        guard client.isAuthenticated else { devices = []; return }
        do {
            devices = try await client.devices()
        } catch {
            // Non-fatal; leave devices empty
            devices = []
        }
    }

    private func mdidIsThisDevice(_ mdid: String) -> Bool {
        mdid.caseInsensitiveCompare(MDID.current) == .orderedSame
    }

    private func byteString(_ n: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n); var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: v < 10 && i > 0 ? "%.1f %@" : "%.0f %@", v, units[i])
    }
}

// MARK: - Login form

private struct LoginForm: View {
    @Binding var loading: Bool
    @Binding var error: String?
    @State private var username = ""
    @State private var password = ""
    @ObservedObject private var client = ZefvClient.shared

    var body: some View {
        VStack(spacing: 12) {
            LabeledField(label: "Username", text: $username, prompt: "your_username", capitalization: .never)
            LabeledField(label: "Password", text: $password, prompt: "at least 8 characters", secure: true)

            Button {
                Task {
                    loading = true
                    error = nil
                    do {
                        _ = try await client.login(
                            username: username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                            password: password
                        )
                    } catch let e as ZefvError {
                        error = e.message
                    } catch {
                        self.error = error.localizedDescription
                    }
                    loading = false
                }
            } label: {
                HStack {
                    if loading { ProgressView().tint(.black) }
                    Text(loading ? "Signing in…" : "Sign in")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.black)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(loading || username.isEmpty || password.isEmpty)
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
    }
}

// MARK: - Register form (with live availability check)

private struct RegisterForm: View {
    @Binding var loading: Bool
    @Binding var error: String?
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var checkTask: Task<Void, Never>?
    @State private var availability: Availability = .idle
    @ObservedObject private var client = ZefvClient.shared

    enum Availability: Equatable {
        case idle, checking, available, unavailable(reason: String)
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                LabeledField(label: "Username", text: $username, prompt: "your_slug (min 5 chars)", capitalization: .never)
                    .onChange(of: username) { _ in scheduleCheck() }
                availabilityHint
                Text("Preview: \(username.isEmpty ? "your_slug" : username.lowercased()).zefv.dev")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 2)
            }

            LabeledField(label: "Password", text: $password, prompt: "at least 8 characters", secure: true)
            LabeledField(label: "Display name (optional)", text: $displayName, prompt: "Shown on your profile", capitalization: .words)

            Button {
                Task {
                    loading = true
                    error = nil
                    do {
                        _ = try await client.register(
                            username: username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                            password: password,
                            displayName: displayName.isEmpty ? nil : displayName
                        )
                    } catch let e as ZefvError {
                        error = e.message
                    } catch {
                        self.error = error.localizedDescription
                    }
                    loading = false
                }
            } label: {
                HStack {
                    if loading { ProgressView().tint(.black) }
                    Text(loading ? "Creating account…" : "Create account")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.black)
                .background(canSubmit ? Theme.accent : Color.gray.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(!canSubmit || loading)
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
    }

    private var canSubmit: Bool {
        // Server enforces 5-char minimum at rank 0 (Rookie); mirror it here.
        guard username.count >= 5, password.count >= 8 else { return false }
        switch availability {
        case .available, .idle:          return true   // .idle = check didn't run/failed — let server validate
        case .checking, .unavailable:    return false
        }
    }

    @ViewBuilder private var availabilityHint: some View {
        switch availability {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking…").font(.caption).foregroundStyle(.white.opacity(0.4))
        case .available:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Available")
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
        case .unavailable(let reason):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                Text(reasonText(reason))
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
        }
    }

    private func reasonText(_ reason: String) -> String {
        switch reason {
        case "reserved":  return "Reserved name"
        case "taken":     return "Already taken"
        case "invalid":   return "Invalid characters"
        case "too_short": return "Too short (need 5+)"
        case "too_long":  return "Too long (max 30)"
        default:          return "Unavailable"
        }
    }

    private func scheduleCheck() {
        checkTask?.cancel()
        let raw = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard raw.count >= 3 else {
            availability = .idle
            return
        }
        availability = .checking
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            do {
                let r = try await client.checkUsername(raw)
                if Task.isCancelled { return }
                await MainActor.run {
                    availability = r.available ? .available : .unavailable(reason: r.reason ?? "")
                }
            } catch {
                await MainActor.run { availability = .idle }
            }
        }
    }
}

// MARK: - Small labeled field

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var secure: Bool = false
    var capitalization: TextInputAutocapitalization = .never

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .kerning(0.3)
            Group {
                if secure {
                    SecureField(prompt, text: $text)
                } else {
                    TextField(prompt, text: $text)
                        .textInputAutocapitalization(capitalization)
                        .autocorrectionDisabled(capitalization == .never)
                }
            }
            .padding(12)
            .background(Color(white: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .foregroundStyle(.white)
        }
    }
}

// MARK: - Change password sheet

private struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var next = ""
    @State private var confirm = ""
    @State private var loading = false
    @State private var error: String?
    @State private var success = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if success {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 42)).foregroundStyle(.green)
                            Text("Password changed")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("All other devices signed out. This one stays.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 40)
                    } else {
                        LabeledField(label: "Current password", text: $current, secure: true)
                        LabeledField(label: "New password", text: $next, prompt: "min 8 characters", secure: true)
                        LabeledField(label: "Confirm new password", text: $confirm, secure: true)
                        if let error {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                        Button {
                            Task { await submit() }
                        } label: {
                            Text(loading ? "Changing…" : "Change password")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .foregroundStyle(.black)
                                .background(canSubmit ? Theme.accent : Color.gray.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(!canSubmit || loading)
                    }
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Change password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(success ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var canSubmit: Bool { current.count >= 8 && next.count >= 8 && next == confirm }

    private func submit() async {
        loading = true; error = nil
        do {
            try await ZefvClient.shared.changePassword(current: current, new: next)
            success = true
        } catch let e as ZefvError {
            error = e.message
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Rename sheet

private struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = ZefvClient.shared
    @State private var newName = ""
    @State private var loading = false
    @State private var error: String?
    @State private var availability: RegisterForm.Availability = .idle
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let user = client.currentUser {
                        HStack(spacing: 6) {
                            Text("Currently:").font(.caption).foregroundStyle(.white.opacity(0.5))
                            SlugText(user, size: 13)
                        }
                    }
                    LabeledField(label: "New username", text: $newName, prompt: "new_slug", capitalization: .never)
                        .onChange(of: newName) { _ in scheduleCheck() }
                    availabilityHint
                    Text("Preview: \(newName.isEmpty ? "new_slug" : newName.lowercased()).zefv.dev")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(loading ? "Renaming…" : "Rename")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.black)
                            .background(canSubmit ? Theme.accent : Color.gray.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!canSubmit || loading)
                    .padding(.top, 6)
                    Text("Rank determines the minimum length allowed. Your uploaded IPAs' URLs will change to the new subdomain.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 4)
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Change username")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var canSubmit: Bool { newName.count >= 3 && availability == .available }

    private var raw: String { newName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    @ViewBuilder private var availabilityHint: some View {
        switch availability {
        case .idle:      EmptyView()
        case .checking:  Text("Checking…").font(.caption).foregroundStyle(.white.opacity(0.4))
        case .available:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Available").fontWeight(.semibold)
            }.font(.system(size: 12)).foregroundStyle(.green)
        case .unavailable:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                Text("Not available").fontWeight(.semibold)
            }.font(.system(size: 12)).foregroundStyle(.orange)
        }
    }

    private func scheduleCheck() {
        checkTask?.cancel()
        guard raw.count >= 3 else { availability = .idle; return }
        availability = .checking
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            do {
                let r = try await client.checkUsername(raw)
                if Task.isCancelled { return }
                await MainActor.run {
                    availability = r.available ? .available : .unavailable(reason: r.reason ?? "")
                }
            } catch {
                await MainActor.run { availability = .idle }
            }
        }
    }

    private func submit() async {
        loading = true; error = nil
        do {
            _ = try await client.rename(to: raw)
            dismiss()
        } catch let e as ZefvError {
            error = e.message
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
