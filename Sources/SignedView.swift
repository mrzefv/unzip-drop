//
//  SignedView.swift
//  Signed tab — every IPA signed on this device: reinstall, share, delete.
//

import SwiftUI
import UIKit

struct SignedView: View {
    @ObservedObject private var signed = SignedStore.shared
    @ObservedObject private var ota = OTAInstaller.shared
    @State private var installing: String?
    @State private var share: URLItem?
    @State private var error: String?
    @State private var search = ""
    @State private var sheetEntry: SignedEntry?

    private var entries: [SignedEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? signed.entries : signed.entries.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    @State private var installCounts: [String: Int] = [:]
    @State private var showSearch = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if signed.entries.isEmpty {
                        Card { Text("Nothing signed yet. Library tab › pick an IPA › Sign.").font(.caption).foregroundStyle(Theme.subtle) }
                    } else if showSearch {
                        MSignSearchField(placeholder: "Search", text: $search).padding(.bottom, 8)
                    }
                    if let error { Card { Text(error).font(.caption).foregroundStyle(.orange) }.padding(.bottom, 8) }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, e in
                        row(e)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { signed.delete(e) } label: { Label("Delete", systemImage: "trash") }
                            }
                        if idx < entries.count - 1 {
                            Divider().overlay(Theme.stroke).padding(.leading, 78)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 20)
            }
            .task { installCounts = await ZefvVPS.installCounts() }
            .safeAreaInset(edge: .top, spacing: 0) {
                TabTitleBar(title: "Signed", center: "\(signed.entries.count) Apps") {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { showSearch.toggle(); if !showSearch { search = "" } }
                    } label: {
                        Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(SSTheme.tintColor)
                    }
                }
            }
        }
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
        .sheet(item: $sheetEntry) { e in
            AppActionSheet(
                name: e.name, bundle: e.bundleID,
                icon: e.iconURL.flatMap { try? Data(contentsOf: $0) },
                actions: [
                    .init(title: "Install App", icon: "square.and.arrow.down", role: .normal) {
                        sheetEntry = nil; Task { await install(e) }
                    },
                    .init(title: "Re-Sign App", icon: "checkmark.seal", role: .normal) {
                        sheetEntry = nil; SignQueue.shared.enqueue(e.ipaURL)
                    },
                    .init(title: "Delete", icon: "trash", role: .destructive) {
                        sheetEntry = nil; signed.delete(e)
                    },
                ]
            )
            .presentationDetents([.height(340)])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
    }

    private func row(_ e: SignedEntry) -> some View {
        MSignAppRow(
            iconURL: e.iconURL,
            title: e.name,
            subtitle: "\(e.version) • \(e.bundleID)",
            pill: signedBadge(e),
            busy: installing == e.id,
            accent: SSTheme.tintColor,
            onTap: { sheetEntry = e }
        )
    }

    private func signedBadge(_ e: SignedEntry) -> String {
        let installs = installCounts[e.bundleID].map { " · \($0) install\($0 == 1 ? "" : "s")" } ?? ""
        return "Signed \(msignRelative(e.signedAt))\(installs)"
    }

    private func install(_ e: SignedEntry) async {
        installing = e.id; error = nil
        do { try await OTAInstaller.shared.install(e) } catch { self.error = error.localizedDescription }
        installing = nil
    }
}

// MARK: - Bottom action sheet (mSign-style: icon + bundle header, rows, footer)

struct AppActionSheet: View {
    struct Action: Identifiable {
        enum Role { case normal, destructive }
        let id = UUID()
        let title: String
        let icon: String
        let role: Role
        let run: () -> Void
    }

    let name: String
    let bundle: String
    let icon: Data?
    let actions: [Action]

    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)

    var body: some View {
        VStack(spacing: 0) {
            // Header: icon · name+bundle · (drag indicator handles dismiss)
            HStack(spacing: 12) {
                iconThumb(52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(bundle).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)

            VStack(spacing: 12) {
                ForEach(actions) { a in
                    Button(action: a.run) {
                        HStack(spacing: 12) {
                            Image(systemName: a.icon).font(.system(size: 18))
                                .foregroundStyle(a.role == .destructive ? .red : blue)
                            Text(a.title).font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(a.role == .destructive ? .red : Theme.text)
                            Spacer()
                            Image(systemName: "arrow.up.forward").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(a.role == .destructive ? .red : blue)
                        }
                        .padding(.vertical, 15).padding(.horizontal, 16)
                        .background(Color(white: 0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            Text("Made by ᴹᴿZEFv").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.subtle).padding(.top, 18).padding(.bottom, 8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }

    private func iconThumb(_ side: CGFloat) -> some View {
        Group {
            if let icon, let img = UIImage(data: icon) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: side * 0.22).fill(Theme.accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(Theme.accent)) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }
}
