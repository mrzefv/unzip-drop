//
//  ImportView.swift
//

import SwiftUI

struct ImportView: View {
    @EnvironmentObject var session: Session

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
                            Button {
                                DocumentPickerPresenter.pickZip { url in
                                    if let url { session.importPicked(url) }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "tray.and.arrow.down.fill")
                                    Text("Choose Zip").fontWeight(.semibold)
                                    Spacer()
                                }
                                .padding(.vertical, 12).padding(.horizontal, 14)
                                .background(session.busy ? Theme.subtle : Theme.accent)
                                .foregroundStyle(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .disabled(session.busy)
                        }
                    }

                    if session.busy {
                        HStack(spacing: 10) {
                            ProgressView().tint(Theme.accent)
                            Text(session.status ?? "Working…").font(.caption).foregroundStyle(Theme.subtle)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }

                    if let name = session.archiveName, session.root != nil, !session.busy {
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
                }
                .padding(16)
            }
        }
        .alert("Import failed",
               isPresented: Binding(get: { session.errorMessage != nil },
                                    set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK", role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }
}
