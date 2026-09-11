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
struct TabTitleBar<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            trailing
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .floatingGlassBar(edge: .top, cornerRadius: 28)
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
