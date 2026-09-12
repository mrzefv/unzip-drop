//
//  AccountPanel.swift
//  Top-bar account chip (MDID · chevron as guest, avatar · username · REGISTERED
//  when signed in) and the dropdown it opens: sign-in/register for guests,
//  profile · stats · navigate · quick tools · logout when signed in.
//

import SwiftUI

// MARK: - Cross-tab navigation requests

@MainActor
final class AppNav: ObservableObject {
    static let shared = AppNav()
    @Published var requestedTab: Int?          // 0 Browse · 1 Library · 2 Signed · 3 Settings
    @Published var openAccountScreen = false
    private init() {}
    func go(_ tab: Int) { requestedTab = tab; ZefvAccount.shared.panelShown = false }
}

// MARK: - Chip

struct AccountChip: View {
    @ObservedObject private var account = ZefvAccount.shared
    @ObservedObject private var staff = StaffGate.shared
    private var role: UserRole { staff.isStaff ? staff.role : account.role }
    private var usernameColor: Color { Color(hex: account.usernameCustomization.colorHex) }
    private var usernameFontDesign: Font.Design { account.usernameCustomization.fontStyle.fontDesign }

    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            account.panelShown.toggle()
        } label: {
            HStack(spacing: 6) {
                if account.isLoggedIn {
                    ZStack(alignment: .bottomTrailing) {
                        Circle().fill(Theme.accent).frame(width: 30, height: 30)
                        Text(String((account.username ?? "?").prefix(1)).uppercased())
                            .font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(.black)
                            .frame(width: 30, height: 30)
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Theme.bg, lineWidth: 1.5))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.username ?? "")
                            .font(.system(size: 12, weight: .bold, design: usernameFontDesign))
                            .foregroundStyle(usernameColor)
                            .lineLimit(1)
                        Text(role == .member ? "REGISTERED" : role.badgeText)
                            .font(.system(size: 8, weight: .heavy, design: .monospaced)).kerning(1).foregroundStyle(Theme.accent)
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("MDID").font(.system(size: 8, weight: .semibold, design: .monospaced)).kerning(1).foregroundStyle(Theme.subtle)
                        Text(staff.mdid).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.subtle)
                    .rotationEffect(.degrees(account.panelShown ? 180 : 0))
            }
            .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.05)).clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(account.isLoggedIn ? "Account" : "Sign in")
    }
}

// MARK: - Dropdown

struct AccountDropdown: View {
    @ObservedObject private var account = ZefvAccount.shared
    @ObservedObject private var staff = StaffGate.shared
    @ObservedObject private var signed = SignedStore.shared
    @ObservedObject private var nav = AppNav.shared

    @State private var registering = false
    @State private var username = ""
    @State private var password = ""
    @State private var confirmLogout = false

    private let dailyQuota = 25
    private var role: UserRole { staff.isStaff ? staff.role : account.role }
    private var usernameColor: Color { Color(hex: account.usernameCustomization.colorHex) }
    private var usernameFontDesign: Font.Design { account.usernameCustomization.fontStyle.fontDesign }
    private var signsToday: Int {
        let cal = Calendar.current
        return signed.entries.filter { cal.isDateInToday($0.signedAt) }.count
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.accent).frame(height: 3)
                if account.isLoggedIn { signedIn } else { guest }
            }
        }
        .frame(width: 340)
        .background(Theme.bg)
        .task { await account.refreshProfile() }
    }

    // MARK: Guest — YOUR MDID · SIGN QUOTA · sign in / register

    private var guest: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                label("touchid", "Your MDID")
                Text(staff.mdid).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
                label("chart.bar.xaxis", "Sign quota")
                quotaBar
            }
            .padding(16)
            Divider().overlay(Theme.stroke)
            VStack(spacing: 12) {
                field("Username", text: $username, secure: false)
                field("Password", text: $password, secure: true)
                if let e = account.lastError {
                    Text(e).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    Task {
                        let ok = registering
                            ? await account.register(username: username, password: password)
                            : await account.login(username: username, password: password)
                        if ok { username = ""; password = "" }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if account.busy { ProgressView().tint(.black) }
                        else { Image(systemName: registering ? "person.crop.circle.badge.plus" : "arrow.right.square.fill") }
                        Text(registering ? "REGISTER" : "SIGN IN").font(.system(size: 17, weight: .heavy, design: .monospaced)).kerning(1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.accent).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(account.busy || username.isEmpty || password.isEmpty)
                HStack(spacing: 4) {
                    Text(registering ? "Have an account?" : "No account?").foregroundStyle(Theme.subtle)
                    Button(registering ? "Sign in" : "Register") { withAnimation { registering.toggle(); account.lastError = nil } }
                        .foregroundStyle(Theme.accent)
                }
                .font(.system(size: 14, weight: .medium))
            }
            .padding(16)
        }
    }

    private var quotaBar: some View {
        HStack(spacing: 12) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.accent).frame(width: g.size.width * min(1, CGFloat(signsToday) / CGFloat(dailyQuota)))
                }
            }
            .frame(height: 6)
            Text("\(signsToday)/\(dailyQuota) today").font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.subtle)
        }
    }

    // MARK: Signed in — profile · stats · navigate · quick tools · logout

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 52, height: 52)
                    Text(String((account.username ?? "?").prefix(1)).uppercased())
                        .font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(.black)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.username ?? "")
                        .font(.system(size: 18, weight: .bold, design: usernameFontDesign))
                        .foregroundStyle(usernameColor)
                    Text(staff.mdid).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.subtle)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 9, height: 9)
                    Text("Verified").font(.system(size: 14)).foregroundStyle(Theme.text)
                }
            }
            .padding(16)
            Divider().overlay(Theme.stroke)

            HStack(spacing: 8) {
                Image(systemName: "iphone").foregroundStyle(Theme.accent)
                HStack(spacing: 6) {
                    Image(systemName: role.icon).font(.system(size: 11, weight: .bold))
                    Text(role.badgeText).font(.system(size: 11, weight: .heavy, design: .monospaced)).kerning(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(role.color)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(role.color.opacity(0.6), lineWidth: 1))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(Theme.stroke)

            label("chart.bar.xaxis", "User stats").padding(.horizontal, 16).padding(.top, 12)
            HStack(spacing: 0) {
                stat("\(signsToday)", "Signs used", Theme.accent)
                divider
                stat("1", "Devices", Theme.accent)
                divider
                stat("\(signed.entries.count)", "Signs total", .orange)
            }
            .padding(.vertical, 14)
            Divider().overlay(Theme.stroke)

            label("safari", "Navigate").padding(.horizontal, 16).padding(.top, 12)
            VStack(spacing: 0) {
                navRow("square.grid.3x3.fill", "Browse",   Color(red: 0.2, green: 0.6, blue: 1.0)) { nav.go(0) }
                navRow("square.grid.2x2.fill", "Library",  Color(red: 0.7, green: 0.35, blue: 1.0)) { nav.go(1) }
                navRow("signature",            "Signed",   .orange) { nav.go(2) }
                navRow("gearshape.fill",       "Settings", Theme.subtle) { nav.go(3) }
            }
            .padding(.vertical, 6)
            Divider().overlay(Theme.stroke)

            label("bolt.fill", "Quick tools").padding(.horizontal, 16).padding(.top, 12)
            HStack(spacing: 8) {
                tool("square.grid.2x2", "Library") { nav.go(1) }
                tool("iphone", "Devices") { nav.openAccountScreen = true; nav.go(3) }
                tool("signature", "Signer") { nav.go(1) }
                tool("gearshape.fill", "Config") { nav.go(3) }
            }
            .padding(16)
            Divider().overlay(Theme.stroke)

            Button { confirmLogout = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("LOGOUT").font(.system(size: 15, weight: .heavy, design: .monospaced)).kerning(1)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .foregroundStyle(.red)
                .background(Color.red.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.4), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(16)
            .confirmationDialog("Log out of \(account.username ?? "")?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Log out", role: .destructive) { Task { await account.logout() } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: Bits

    private var divider: some View { Rectangle().fill(Theme.stroke).frame(width: 1, height: 44) }

    private func label(_ icon: String, _ t: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(t.uppercased()).font(.system(size: 12, weight: .bold, design: .monospaced)).kerning(1.5)
        }
        .foregroundStyle(Theme.subtle)
    }

    private func stat(_ v: String, _ t: String, _ c: Color) -> some View {
        VStack(spacing: 4) {
            Text(v).font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(c)
            Text(t.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).kerning(1).foregroundStyle(Theme.subtle)
        }
        .frame(maxWidth: .infinity)
    }

    private func navRow(_ icon: String, _ t: String, _ c: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(c).frame(width: 24)
                Text(t.uppercased()).font(.system(size: 16, weight: .heavy, design: .monospaced)).kerning(1).foregroundStyle(c == Theme.subtle ? Theme.text : c)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tool(_ icon: String, _ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                Text(t.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).kerning(1).foregroundStyle(Theme.subtle)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func field(_ ph: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField(ph, text: text) }
            else { TextField(ph, text: text).autocorrectionDisabled().textInputAutocapitalization(.never) }
        }
        .font(.system(size: 16, design: .monospaced))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14).padding(.vertical, 14)
        .background(Color.white.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
