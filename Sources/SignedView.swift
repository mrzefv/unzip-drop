//
//  SignedView.swift
//  Signed tab — every IPA signed on this device: reinstall, share, delete.
//

import SwiftUI
import UIKit

struct SignedView: View {
    @ObservedObject private var signed = SignedStore.shared
    @State private var installing: String?
    @State private var share: URLItem?
    @State private var error: String?
    @State private var search = ""
    @State private var sheetEntry: SignedEntry?
    @State private var showSearch = false
    @State private var selecting = false
    @State private var selected: Set<String> = []

    private var entries: [SignedEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? signed.entries : signed.entries.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Button { withAnimation { ThemePanelState.shared.open.toggle() } } label: {
                            Image(systemName: "paintpalette.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
                        }
                        Text("Signed").font(.title2.bold()).foregroundStyle(Theme.text)
                        Spacer()
                        if selecting {
                            Text("\(selected.count) selected").font(.caption).foregroundStyle(Theme.subtle)
                        } else {
                            Text("\(signed.entries.count)").font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                        }
                        Button { withAnimation { showSearch.toggle(); if !showSearch { search = "" } } } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                        Menu {
                            if selecting {
                                Button { selectAll() } label: { Label("Select all", systemImage: "checkmark.circle") }
                                Button(role: .destructive) { deleteSelected() } label: { Label("Delete selected", systemImage: "trash") }
                                Button { updateSelected() } label: { Label("Re-sign selected", systemImage: "checkmark.seal") }
                                Button { selecting = false; selected.removeAll() } label: { Label("Done", systemImage: "xmark") }
                            } else {
                                Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                            }
                        } label: {
                            Image(systemName: selecting ? "ellipsis.circle.fill" : "ellipsis.circle").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    if signed.entries.isEmpty {
                        Card { Text("Nothing signed yet. Library tab › pick an IPA › Sign.").font(.caption).foregroundStyle(Theme.subtle) }
                    } else if showSearch {
                        TextField("Search", text: $search)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .padding(10).background(Theme.card).foregroundStyle(Theme.text)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if let error { Card { Text(error).font(.caption).foregroundStyle(.orange) } }
                    VStack(spacing: 0) {
                        ForEach(entries) { e in
                            row(e)
                            if e.id != entries.last?.id {
                                Divider().overlay(Theme.stroke).padding(.leading, 84)
                            }
                        }
                    }
                }
                .padding(16)
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
        HStack(spacing: 14) {
            icon(e.iconURL.flatMap { try? Data(contentsOf: $0) })
            VStack(alignment: .leading, spacing: 5) {
                Text(e.name).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(e.version) · \(e.bundleID)").font(.system(size: 15)).foregroundStyle(Theme.subtle).lineLimit(1)
                Text("Signed \(relative(e.signedAt))").font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.card).foregroundStyle(Theme.subtle).clipShape(Capsule())
            }
            Spacer()
            if selecting {
                Image(systemName: selected.contains(e.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(selected.contains(e.id) ? Theme.accent : Theme.subtle)
            } else if installing == e.id { ProgressView().tint(Theme.accent) }
            else { Image(systemName: "arrow.up.forward").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent) }
        }
        .padding(.vertical, 14).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { toggle(e.id) } else { sheetEntry = e }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func selectAll() { selected = Set(entries.map { $0.id }) }
    private func deleteSelected() {
        for e in signed.entries where selected.contains(e.id) { signed.delete(e) }
        selected.removeAll(); selecting = false
    }
    private func updateSelected() {
        for e in signed.entries where selected.contains(e.id) { SignQueue.shared.enqueue(e.ipaURL) }
        selected.removeAll(); selecting = false
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func icon(_ data: Data?) -> some View {
        Group {
            if let data, let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(Theme.accent)) }
        }
        .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .background(Color.clear.ignoresSafeArea())
    }

    private func iconThumb(_ side: CGFloat) -> some View {
        Group {
            if let icon, let img = UIImage(data: icon) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: side * 0.22).fill(Theme.accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(Theme.accent)) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }
}
