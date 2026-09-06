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

    private var entries: [SignedEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? signed.entries : signed.entries.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Signed").font(.title2.bold()).foregroundStyle(Theme.text)
                        Spacer()
                        Text("\(signed.entries.count)").font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                    }
                    if signed.entries.isEmpty {
                        Card { Text("Nothing signed yet. Library tab › pick an IPA › Sign.").font(.caption).foregroundStyle(Theme.subtle) }
                    } else {
                        TextField("Search", text: $search)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .padding(10).background(Theme.card).foregroundStyle(Theme.text)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if let error { Card { Text(error).font(.caption).foregroundStyle(.orange) } }
                    ForEach(entries) { e in row(e) }
                }
                .padding(16)
            }
        }
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
    }

    private func row(_ e: SignedEntry) -> some View {
        HStack(spacing: 12) {
            icon(e.iconURL.flatMap { try? Data(contentsOf: $0) })
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(e.bundleID) · v\(e.version)").font(.caption.monospaced()).foregroundStyle(Theme.subtle).lineLimit(1)
                Text("\(e.certName) · \(e.signedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(Theme.subtle)
            }
            Spacer()
            Button { Task { await install(e) } } label: {
                if installing == e.id { ProgressView().tint(Theme.accent) }
                else { Image(systemName: "arrow.down.app.fill").font(.system(size: 22)).foregroundStyle(.green) }
            }
            .disabled(installing != nil)
            Menu {
                Button { share = URLItem(url: e.ipaURL) } label: { Label("Share IPA", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { signed.delete(e) } label: { Label("Delete", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Theme.subtle) }
        }
        .padding(12).background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func icon(_ data: Data?) -> some View {
        Group {
            if let data, let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(Theme.accent)) }
        }
        .frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func install(_ e: SignedEntry) async {
        installing = e.id; error = nil
        do { try await OTAInstaller.shared.install(e) } catch { self.error = error.localizedDescription }
        installing = nil
    }
}
