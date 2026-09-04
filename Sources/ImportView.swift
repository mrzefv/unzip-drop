//
//  ImportView.swift
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @EnvironmentObject var session: Session
    @State private var picking = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    HStack { Text("Import").font(.title2.bold()).foregroundStyle(Theme.text); Spacer() }

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Open a .zip", systemImage: "archivebox").font(.headline).foregroundStyle(Theme.text)
                            Text("Pick a zip, or share one into Unzip Drop from Files or Safari. It extracts on-device — a single wrapping folder is flattened automatically.")
                                .font(.caption).foregroundStyle(Theme.subtle)
                            Button { picking = true } label: {
                                HStack {
                                    Image(systemName: "tray.and.arrow.down.fill")
                                    Text("Choose Zip").fontWeight(.semibold)
                                    Spacer()
                                }
                                .padding(.vertical, 12).padding(.horizontal, 14)
                                .background(Theme.accent).foregroundStyle(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }

                    if session.busy { ProgressView().tint(Theme.accent).padding(.top, 4) }

                    if let name = session.archiveName, session.root != nil {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(name, systemImage: "shippingbox.fill").font(.headline).foregroundStyle(Theme.text)
                                Text("\(session.fileCount) files · \(ByteCountFormatter.string(fromByteCount: session.totalBytes, countStyle: .file))")
                                    .font(.caption).foregroundStyle(Theme.subtle)
                                Text("Browse it in Contents, or send it up in Push.")
                                    .font(.caption2).foregroundStyle(Theme.subtle)
                                Button(role: .destructive) { session.reset() } label: {
                                    Label("Clear", systemImage: "trash").font(.caption)
                                }
                                .padding(.top, 2)
                            }
                        }
                    }

                    if let s = session.status, session.root == nil, !session.busy {
                        Text(s).font(.caption).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip], allowsMultipleSelection: false) { res in
            if case let .success(urls) = res, let u = urls.first { session.importPicked(u) }
        }
    }
}
