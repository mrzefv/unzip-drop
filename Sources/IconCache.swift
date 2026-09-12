//
//  IconCache.swift
//  Memory (decoded UIImage) + disk (URLCache) icon cache with a prefetcher.
//  SourceIcon reads the memory tier synchronously, so a prefetched icon never
//  shows a placeholder, not even for one frame.
//

import SwiftUI

final class IconCache: @unchecked Sendable {
    static let shared = IconCache()

    private let mem = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private let inflight = NSLock()
    private var loading: Set<URL> = []

    private init() {
        mem.countLimit = 600
        mem.totalCostLimit = 96 * 1024 * 1024
        // One shared, generous disk cache: AsyncImage (news/screenshots) benefits too.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.urlCache = URLCache.shared
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)
    }

    /// Synchronous memory lookup — safe to call from a View body.
    func cached(_ url: URL) -> UIImage? { mem.object(forKey: url as NSURL) }

    /// Load (disk cache → network), decode off-main, store in memory.
    @discardableResult
    func load(_ url: URL, maxPixel: CGFloat = 256) async -> UIImage? {
        if let img = cached(url) { return img }
        inflight.lock(); let dup = loading.contains(url); if !dup { loading.insert(url) }; inflight.unlock()
        if dup { // someone else is fetching; poll the memory tier briefly
            for _ in 0..<40 { try? await Task.sleep(nanoseconds: 50_000_000); if let img = cached(url) { return img } }
            return nil
        }
        defer { inflight.lock(); loading.remove(url); inflight.unlock() }
        guard let (data, _) = try? await session.data(from: url), data.count <= 8 * 1024 * 1024 else { return nil }
        let img = await Task.detached(priority: .utility) { Self.decode(data, maxPixel: maxPixel) }.value
        if let img { mem.setObject(img, forKey: url as NSURL, cost: Int(img.size.width * img.size.height * 4)) }
        return img
    }

    /// Warm the first N icons of a list, a few at a time, without blocking anything.
    func prefetch(_ urls: [URL], limit: Int = 40, concurrency: Int = 6) async {
        let todo = Array(urls.prefix(limit)).filter { cached($0) == nil }
        guard !todo.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var it = todo.makeIterator()
            for _ in 0..<concurrency { if let u = it.next() { group.addTask(priority: .utility) { await self.load(u) } } }
            for await _ in group { if let u = it.next() { group.addTask(priority: .utility) { await self.load(u) } } }
        }
    }

    private nonisolated static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        // Downsample via ImageIO so a 1024² PNG becomes a small bitmap before it hits memory.
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else { return UIImage(data: data) }
        let thumbOpts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

/// Drop-in icon view: memory hit renders synchronously; otherwise loads and fades in.
struct CachedIcon: View {
    let url: URL?
    let side: CGFloat
    var fallback: String = ""
    var corner: CGFloat? = nil

    @State private var image: UIImage?

    var body: some View {
        let img = image ?? url.flatMap { IconCache.shared.cached($0) }
        let r = corner ?? side * 0.22
        ZStack {
            if let img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: r, style: .continuous).fill(Theme.accent.opacity(0.15))
                Text(String(fallback.prefix(1)).uppercased()).font(.system(size: side * 0.42, weight: .bold)).foregroundStyle(Theme.accent)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .task(id: url) {
            guard let url, image == nil, IconCache.shared.cached(url) == nil else { return }
            if let loaded = await IconCache.shared.load(url, maxPixel: max(side * 3, 192)) {
                withAnimation(.easeIn(duration: 0.12)) { image = loaded }
            }
        }
    }
}
