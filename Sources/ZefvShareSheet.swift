//
//  ZefvShareSheet.swift
//  Modal that uploads a signed IPA to zefv.dev and presents the resulting
//  install URL so the user can tap Install (opens itms-services:// via
//  Safari), copy the link, or share it.
//
//  Also exposes `ZefvShareBadge` — a small "Share via zefv.dev" button that
//  callers can drop into any post-signing UI. Tapping it presents the sheet
//  if the user is authenticated, or nudges them to Settings if not.
//
//  Intended use:
//    .sheet(isPresented: $showShare) {
//        ZefvShareSheet(ipaURL: entry.ipaURL, bundleID: entry.bundleID,
//                       version: entry.version, name: entry.name)
//    }
//

import SwiftUI

struct ZefvShareSheet: View {
    let ipaURL: URL
    let bundleID: String
    let version: String
    let name: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = ZefvClient.shared

    @State private var phase: Phase = .prepping
    @State private var progress: Double = 0
    @State private var result: ZefvUploadResult?
    @State private var error: String?
    @State private var copyFlashed = false

    enum Phase { case prepping, uploading, done, failed, notAuthed }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Share via zefv.dev")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(phase == .done ? "Done" : "Cancel") { dismiss() }
                }
            }
            .task { await start() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .notAuthed: notAuthedView
        case .prepping, .uploading: uploadingView
        case .done: doneView
        case .failed: failedView
        }
    }

    // MARK: Not signed in

    private var notAuthedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Sign in to zefv.dev first")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Create an account or sign in from Settings → zefv.dev Account, then try again.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.top, 4)
        }
        .padding(.top, 60)
    }

    // MARK: Uploading

    private var uploadingView: some View {
        VStack(spacing: 20) {
            appHeader
            VStack(spacing: 10) {
                ProgressView(value: max(0.02, progress))
                    .tint(Theme.accent)
                    .frame(height: 6)
                    .clipShape(Capsule())
                HStack {
                    Text(phase == .prepping ? "Preparing…" : "Uploading…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(20)
            .background(cardBg)

            if let user = client.currentUser {
                Text("Will publish at:")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Text("https://\(user.username).zefv.dev/")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()
        }
        .padding(20)
    }

    // MARK: Done — show install URL

    private var doneView: some View {
        VStack(spacing: 18) {
            appHeader
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("Published!")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let user = result?.user {
                    HStack(spacing: 6) {
                        Text("+ 5 XP · you're now")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                        SlugText(user, size: 12)
                    }
                }
            }

            // Install URL card
            if let r = result {
                VStack(alignment: .leading, spacing: 10) {
                    Text("PLIST URL").font(.system(size: 10, weight: .heavy)).kerning(0.5)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(r.plist_url)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    HStack(spacing: 10) {
                        actionBtn(icon: "arrow.down.circle.fill", label: "Install now", filled: true) {
                            client.openInstall(r.install_url)
                        }
                        actionBtn(icon: "doc.on.doc", label: copyFlashed ? "Copied" : "Copy link", filled: false) {
                            UIPasteboard.general.string = r.plist_url
                            withAnimation { copyFlashed = true }
                            Task {
                                try? await Task.sleep(nanoseconds: 1_400_000_000)
                                withAnimation { copyFlashed = false }
                            }
                        }
                    }
                    ShareLink(item: URL(string: r.plist_url) ?? URL(string: "https://zefv.dev")!) {
                        Label("Share plist URL", systemImage: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(white: 0.11))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
                .background(cardBg)
            }

            Text("Anyone with the install link can tap it in Safari and install your signed IPA — as long as the signing certificate is trusted on their device.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 4)

            Spacer()
        }
        .padding(20)
    }

    // MARK: Failed

    private var failedView: some View {
        VStack(spacing: 14) {
            appHeader
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Upload failed")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(error ?? "Unknown error")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button("Retry") {
                Task { await start() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Shared UI

    private var appHeader: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "app.badge").foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(bundleID) · v\(version)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var cardBg: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(white: 0.09))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func actionBtn(icon: String, label: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label).font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(filled ? .black : .white)
            .background(filled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(white: 0.14)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Upload driver

    private func start() async {
        guard client.isAuthenticated else { phase = .notAuthed; return }
        phase = .prepping
        progress = 0
        error = nil
        result = nil
        do {
            let r = try await client.upload(
                ipaURL: ipaURL,
                bundleID: bundleID,
                version: version,
                name: name,
                onProgress: { p in
                    // Closure is @MainActor — direct @State mutation is safe.
                    if phase == .prepping { phase = .uploading }
                    progress = p
                }
            )
            result = r
            progress = 1
            phase = .done
        } catch let e as ZefvError {
            error = e.message
            phase = .failed
        } catch {
            self.error = error.localizedDescription
            phase = .failed
        }
    }
}

// MARK: - Compact "Share via zefv.dev" button

struct ZefvShareBadge: View {
    let ipaURL: URL
    let bundleID: String
    let version: String
    let name: String

    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.circle.fill")
                Text("Share via zefv.dev")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.black)
            .background(Theme.accent)
            .clipShape(Capsule())
        }
        .sheet(isPresented: $show) {
            ZefvShareSheet(ipaURL: ipaURL, bundleID: bundleID, version: version, name: name)
        }
    }
}
