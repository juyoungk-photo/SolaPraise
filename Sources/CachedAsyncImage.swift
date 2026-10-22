//
//  CachedAsyncImage.swift
//  SolaPraise
//
//  AsyncImage that remembers: a thumbnail decoded once is drawn at once
//  the next time it is on screen — scrolled back to, a tab come back to.
//
//  WHY: AsyncImage keeps nothing in memory. Every card that scrolled back
//  into a feed of a hundred videos, every tab switched back to, started
//  again from the grey placeholder, fetched (from the small default URL
//  cache, or the network) and decoded on the way in — the grid blinked and
//  scrolling stuttered while it did. Here the decoded image is kept
//  (ImageMemory), prepared for display off the main thread, and the next
//  draw is synchronous.
//
//  The same two forms as AsyncImage, so it replaces it name for name.
//

import SwiftUI
import UIKit

struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    let content: (AsyncImagePhase) -> Content

    @State private var loaded: (url: URL, image: UIImage)?
    @State private var failed: URL?

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    init<I: View, P: View>(url: URL?,
                           @ViewBuilder content: @escaping (Image) -> I,
                           @ViewBuilder placeholder: @escaping () -> P)
    where Content == _ConditionalContent<I, P> {
        self.init(url: url) { phase in
            if case .success(let image) = phase { content(image) } else { placeholder() }
        }
    }

    var body: some View {
        content(phase)
            .task(id: url) {
                guard let url, ImageMemory.image(for: url) == nil else { return }
                if let image = await ImageMemory.load(url) {
                    loaded = (url, image)
                } else if !Task.isCancelled {
                    failed = url
                }
            }
    }

    private var phase: AsyncImagePhase {
        guard let url else { return .empty }
        if let image = loaded?.url == url ? loaded?.image : ImageMemory.image(for: url) {
            return .success(Image(uiImage: image))
        }
        return failed == url ? .failure(URLError(.cannotDecodeContentData)) : .empty
    }
}

/// Decoded images by URL, in memory, evicted by the system under pressure.
enum ImageMemory {
    nonisolated(unsafe) private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func load(_ url: URL) async -> UIImage? {
        if let known = image(for: url) { return known }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        // Decoded here, off the main thread, rather than on first draw.
        let ready = await image.byPreparingForDisplay() ?? image
        let pixels = ready.size.width * ready.size.height * ready.scale * ready.scale
        cache.setObject(ready, forKey: url as NSURL, cost: Int(pixels) * 4)
        return ready
    }
}
