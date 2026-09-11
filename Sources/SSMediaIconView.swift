//
//  SSMediaIconView.swift
//  Ported from mSign (Layer 1). Rounded app-icon view — same public API as mSign's
//  (url / size / cornerRadius / inset) so mSign's Library/Signed rows drop in unchanged.
//
//  mSign's original used SDWebImageSwiftUI (AnimatedImage) + an AVQueuePlayer looping
//  view for video icons. unzip-drop builds phone-only via GitHub Actions with no SPM
//  packages, and these tabs only ever show local-file / static-PNG icons, so this uses
//  a native AsyncImage backend. GIF/video icons fall back to their first frame.
//

import SwiftUI
import UIKit

struct SSMediaIconView: View {
    let url: URL?
    var size: CGFloat = 50
    var cornerRadius: CGFloat = 12
    /// Breathing room so icons never look "zoomed"; 0 for edge-to-edge.
    var inset: CGFloat = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(Color.white.opacity(0.10))
            iconContent
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var iconContent: some View {
        if let url {
            if url.isFileURL {
                if let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img).resizable().scaledToFit().padding(inset)
                } else {
                    placeholder
                }
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit().padding(inset)
                    case .empty: ProgressView().tint(SSTheme.tintColor)
                    default: placeholder
                    }
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: "app.fill")
            .font(.system(size: size * 0.42))
            .foregroundStyle(SSTheme.tintColor.opacity(0.6))
    }
}
