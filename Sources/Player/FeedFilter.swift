//
//  FeedFilter.swift
//  SolaPraise
//
//  What a feed's 「next」 and a 찬양 search show, and what they leave out.
//  Shown and switched in 설정 › 피드·찬양 검색.
//
//  Two rules, both in plain sight:
//
//  - 안내·공지·예고편 are left out: not something to listen to.
//  - A Short is shown as its ORIGINAL when that is at hand — the same song
//    from the same channel, at full length. Never just dropped: a Short
//    may be the only upload of a song, and the first version of this,
//    which dropped anything up to 70 seconds and any title with 「shorts」
//    in it, also played a team's three-song 콘티 as two.
//
//  The video actually chosen always plays as it is, and a playlist or a 콘티
//  is never touched (PlayerHost.play curated:).
//
//  Foundation only: Tools/check-feed-filter.swift runs it.
//

import Foundation

enum FeedFilter {
    static let noticesKey = "feed.skipNotices"
    static let originalsKey = "feed.shortsToOriginal"

    /// Matched in a title in any case.
    static let noticeWords = ["안내", "공지", "예고", "teaser", "trailer"]
    /// A Short is a minute or less, or says so in its title.
    static let shortsSeconds = 60

    static var skipsNotices: Bool {
        UserDefaults.standard.object(forKey: noticesKey) as? Bool ?? true
    }

    static var prefersOriginals: Bool {
        UserDefaults.standard.object(forKey: originalsKey) as? Bool ?? true
    }

    struct Item: Equatable {
        let id: String
        let title: String
        let seconds: Int?
        let channel: String?
    }

    static func isNotice(_ title: String) -> Bool {
        let lower = title.lowercased()
        return noticeWords.contains { lower.contains($0) }
    }

    static func isShort(_ item: Item) -> Bool {
        if let seconds = item.seconds, seconds <= shortsSeconds { return true }
        return item.title.lowercased().contains("#shorts")
    }

    /// The full-length upload a Short was cut from: the same song, from the
    /// same channel, not itself a Short.
    static func original(of short: Item, among pool: [Item]) -> Item? {
        guard let channel = short.channel, !channel.isEmpty else { return nil }
        return pool.first { candidate in
            candidate.id != short.id && candidate.channel == channel && !isShort(candidate)
                && PlanSongTitle.sameSong(candidate.title, short.title)
        }
    }

    /// `items` as shown: notices out, each Short as its original when that
    /// is in `items` or `pool` — once, where the Short stood or where the
    /// original already was. `chosen`: the video picked by hand, kept as it
    /// is.
    static func arrange(_ items: [Item], pool: [Item] = [], keeping chosen: String? = nil,
                        skippingNotices: Bool = skipsNotices,
                        preferringOriginals: Bool = prefersOriginals) -> [Item] {
        let everything = items + pool
        let listed = Set(items.map(\.id))
        var out: [Item] = []
        var seen = Set<String>()
        for item in items {
            if item.id == chosen {
                if seen.insert(item.id).inserted { out.append(item) }
                continue
            }
            if skippingNotices, isNotice(item.title) { continue }
            if preferringOriginals, isShort(item), let original = original(of: item, among: everything) {
                // Already further down the list: it stands there, once.
                if listed.contains(original.id) { continue }
                if seen.insert(original.id).inserted { out.append(original) }
                continue
            }
            if seen.insert(item.id).inserted { out.append(item) }
        }
        return out
    }
}
