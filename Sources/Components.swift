//
//  Components.swift
//

import SwiftUI
import UniformTypeIdentifiers

/// UIActivityViewController bridge (share a single file).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Export a folder (as a copy) into a user-chosen location in Files.
struct DirExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}

/// Floating glass title bar for the four tabs. Put it in `.safeAreaInset(edge: .top)`.
/// `center` renders a centered subtitle (mSign-style "57 Apps") behind the leading title.
struct TabTitleBar<Trailing: View>: View {
    let title: String
    var center: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        ZStack {
            if let center {
                Text(center).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.subtle)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            HStack(spacing: 12) {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                trailing
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .floatingGlassBar(edge: .top, cornerRadius: 28)
    }
}

// MARK: - mSign-style app row (shared by Library & Signed)

/// Tall row: 60pt icon · bold title · monospace version·bundle · status pill · ↗ action.
/// Edge-to-edge with a hairline divider — no bordered card.
struct MSignRow: View {
    let icon: Data?
    let title: String
    let subtitle: String        // "1.0 · com.mrzefv.unzipdrop"
    let badge: String           // "Signed 2d ago" / "Downloaded"
    var busy: Bool = false
    var accent: Color = Color(red: 0.25, green: 0.55, blue: 1.0)
    let onAction: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            MSignIcon(data: icon)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1).truncationMode(.middle)
                Text(badge).font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.white.opacity(0.06)).foregroundStyle(Theme.subtle).clipShape(Capsule())
            }
            Spacer(minLength: 8)
            if busy { ProgressView().tint(accent) }
            else {
                Button(action: onAction) {
                    Image(systemName: "arrow.up.forward").font(.system(size: 20, weight: .semibold)).foregroundStyle(accent)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

struct MSignIcon: View {
    let data: Data?
    var body: some View {
        Group {
            if let data, let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(Theme.accent)) }
        }
        .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// mSign search field — pill, no visible border.
struct MSignSearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.subtle)
            TextField(placeholder, text: $text)
                .autocorrectionDisabled().textInputAutocapitalization(.never).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.white.opacity(0.06)).clipShape(Capsule())
    }
}

struct TopBar: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
            Text("UNZIP DROP")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .kerning(1).foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .floatingGlassBar(edge: .top)
    }
}

/// Identifiable URL wrapper for .sheet(item:).
struct URLItem: Identifiable { let url: URL; var id: String { url.path } }
