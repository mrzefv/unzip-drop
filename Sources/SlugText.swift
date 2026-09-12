//
//  SlugText.swift
//  Onboarding shell shown once on first launch (mSign-style welcome), plus the
//  reusable OnboardingLogo. The logo renders /Resources/onboarding_logo.png if
//  present, and animates an /Resources/onboarding.gif when supplied; otherwise
//  it falls back to a drawn mark so the build never depends on the assets.
//
//  Drop your logo + gif into Sources/Resources as:
//      onboarding_logo.png     (static logo / app mark)
//      onboarding.gif          (optional animated splash)
//

import SwiftUI
import UIKit
import ImageIO

// MARK: - Onboarding gate

@MainActor
final class Onboarding: ObservableObject {
    static let shared = Onboarding()
    private let key = "uzd_onboarded_v1"
    @Published var needsOnboarding: Bool
    private init() { needsOnboarding = !UserDefaults.standard.bool(forKey: key) }
    func complete() { UserDefaults.standard.set(true, forKey: key); needsOnboarding = false }
}

struct OnboardingView: View {
    var onDone: () -> Void
    @State private var page = 0

    private struct Slide { let icon: String; let title: String; let body: String }
    private let slides: [Slide] = [
        .init(icon: "square.and.arrow.down.on.square.fill", title: "Sign on device",
              body: "Import an IPA, pick a certificate, and sign it right here — no computer, no Xcode."),
        .init(icon: "square.grid.2x2.fill", title: "Your Library",
              body: "Downloaded and imported apps live in Library. Sign, install over the air, or clean up from one place."),
        .init(icon: "signature", title: "Signed & installable",
              body: "Everything you sign lands in the Signed tab, ready to reinstall or share any time."),
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ThemeBackgroundLayer()
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                OnboardingLogo(size: 120).padding(.bottom, 8)
                Text("mSign").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                Text("MRzefv · mrzefv.com").font(.footnote).foregroundStyle(Theme.subtle).padding(.bottom, 18)

                TabView(selection: $page) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { i, s in
                        VStack(spacing: 14) {
                            Image(systemName: s.icon).font(.system(size: 40, weight: .semibold)).foregroundStyle(Theme.accent)
                            Text(s.title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                            Text(s.body).font(.system(size: 14)).foregroundStyle(Theme.subtle)
                                .multilineTextAlignment(.center).padding(.horizontal, 30)
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(height: 230)

                VStack(spacing: 10) {
                    Button {
                        if page < slides.count - 1 { withAnimation { page += 1 } } else { onDone() }
                    } label: {
                        Text(page < slides.count - 1 ? "Next" : "Get started")
                            .font(.system(size: 16, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.accent).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Button("Skip") { onDone() }
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.subtle)
                }
                .padding(.horizontal, 30).padding(.bottom, 30)
            }
        }
        .preferredColorScheme(AppTheme.shared.colorScheme)
    }
}

// MARK: - Logo (PNG → GIF → drawn fallback)

struct OnboardingLogo: View {
    var size: CGFloat = 100
    var body: some View {
        if let gif = AnimatedImage.named("onboarding") {
            gif.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else if let ui = UIImage(named: "onboarding_logo") ?? loadResourcePNG("onboarding_logo") {
            Image(uiImage: ui).resizable().scaledToFit()
                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22).fill(Theme.accent.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.22).stroke(Theme.accent.opacity(0.4), lineWidth: 1))
                Image(systemName: "signature").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(Theme.accent)
            }
            .frame(width: size, height: size)
        }
    }

    private func loadResourcePNG(_ name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let d = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: d)
    }
}

// MARK: - Minimal animated-GIF view (no dependencies)

struct AnimatedImage: UIViewRepresentable {
    let frames: [UIImage]
    let duration: TimeInterval

    static func named(_ name: String) -> AnimatedImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
              let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        var imgs: [UIImage] = []; var total: TimeInterval = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            imgs.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let dt = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                  ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            total += max(dt, 0.02)
        }
        return imgs.isEmpty ? nil : AnimatedImage(frames: imgs, duration: total)
    }

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.animationImages = frames
        v.animationDuration = duration
        v.image = frames.first
        v.startAnimating()
        return v
    }
    func updateUIView(_ uiView: UIImageView, context: Context) {}
}
