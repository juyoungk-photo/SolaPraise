//
//  DefaultChannels.swift
//  SolaPraise
//
//  The channels the app starts with.
//
//  Their UC… ids are baked in rather than resolved at runtime, which means
//  adding them costs ZERO quota and works with no Google account at all —
//  the feeds are plain RSS. Resolving a @handle would need channels.list and
//  therefore a signed-in user.
//

import Foundation
import SwiftData

struct SuggestedChannel: Identifiable, Hashable {
    let channelId: String
    let title: String
    let handle: String
    let purpose: Purpose
    let isPinned: Bool

    var id: String { channelId }
}

enum DefaultChannels {

    /// Verified against each channel's own page, which advertises exactly
    /// these ids in its RSS link, and each feed checked for entries — a
    /// channel whose RSS returns nothing is indistinguishable in the app from
    /// one that was never added.
    static let all: [SuggestedChannel] = [
        // ── 말씀 ──────────────────────────────────────────────
        SuggestedChannel(channelId: "UCr1z2X_zyeC8GMbLv4swMVA",
                         title: "⛪ 코너스톤교회", handle: "@c3sfbay",
                         purpose: .word, isPinned: true),
        SuggestedChannel(channelId: "UCroCQn7T3UZsE8N5oyaIP1w",
                         title: "성서유니온 (매일성경)", handle: "@scriptureunionKR",
                         purpose: .word, isPinned: false),
        SuggestedChannel(channelId: "UCISl2wEDnzYeg-k_kElfN4Q",
                         title: "공동체성경읽기", handle: "@PRS",
                         purpose: .word, isPinned: false),
        SuggestedChannel(channelId: "UCKKIJZpEm8lF_RCVXMHVIVA",
                         title: "말씀PT", handle: "@english_bible",
                         purpose: .word, isPinned: false),

        // ── 찬양 ──────────────────────────────────────────────
        SuggestedChannel(channelId: "UCrnxDS-QclED-ej-MFxr8tA",
                         title: "MARKERS WORSHIP", handle: "@MarkersWorship",
                         purpose: .worship, isPinned: true),
        SuggestedChannel(channelId: "UCCJMY5J7tSmopE6kuRNs1Zw",
                         title: "아이자야씩스티원", handle: "@i6tyone",
                         purpose: .worship, isPinned: false),
        SuggestedChannel(channelId: "UCmDCtLeqOzF7_uf_UXoNiYA",
                         title: "F.I.A WORSHIP", handle: "@FIAWORSHIP",
                         purpose: .worship, isPinned: false),
        SuggestedChannel(channelId: "UCqZ6R9Js2HG-6ZNP71soeUg",
                         title: "어노인팅", handle: "@anointingworship",
                         purpose: .worship, isPinned: false),
        SuggestedChannel(channelId: "UCwmy8BC5ng0a0PWKDuRH08Q",
                         title: "ALL THAT HYMN 올댓힘", handle: "@ALLTHATHYMN645",
                         purpose: .worship, isPinned: false),
        SuggestedChannel(channelId: "UCjYmM82SWsjck55t1e6rzpQ",
                         title: "Delivery Project", handle: "@deliveryproject_korea",
                         purpose: .worship, isPinned: false),
        SuggestedChannel(channelId: "UCn5qdSP9lz6BIl4bPwM41qg",
                         title: "YWAM Worship Korea", handle: "@ywamworshipkorea",
                         purpose: .worship, isPinned: false),

        // ── 교제 ──────────────────────────────────────────────
        // Id read off @c3sfbay-tv's own page. Its RSS feed 404s, which is the
        // usual flakiness rather than a wrong id — the API path serves it.
        SuggestedChannel(channelId: "UCkgmi4DRdECaM2N_ErJANPw",
                         title: "📺 Cornerstone TV", handle: "@c3sfbay-tv",
                         purpose: .fellowship, isPinned: false)
    ]

    /// Playlists the app starts with, pinned to a feed by hand.
    ///
    /// A church posts its sermons and its worship from one account, so channel
    /// purpose cannot separate them — 코너스톤교회 is filed under 말씀, but its
    /// Sunday livestreams open with the worship team playing, which is 찬양 and
    /// is what the team itself wants to review afterwards.
    ///
    /// The id is YouTube's own auto-generated "Live streams" playlist:
    /// every channel has one at UULV + the channel id minus its UC prefix. It
    /// needs no lookup and no maintenance — new services appear in it on their
    /// own.
    /// `titleFilter` is not optional decoration here: the Live playlist holds
    /// every stream the church has ever made — over 1,300 — and the weekly
    /// shape is four weekday 모닝워십 to one 토요예배 and one 2부예배. Unfiltered
    /// it is a devotional feed with the services scattered through it, which
    /// is the wrong list entirely for 찬양.
    ///
    /// "예배" is the filter because it separates exactly along that line: both
    /// weekend services carry it and 모닝워십 does not. A narrower "부예배"
    /// would have dropped 토요예배, which has the worship team too.
    static let defaultPlaylists: [(playlistId: String, title: String, purpose: Purpose, titleFilter: String?)] = [
        (
            "UULV" + "r1z2X_zyeC8GMbLv4swMVA",
            "코너스톤교회 주일·토요예배",
            .worship,
            "예배"
        )
    ]

    /// Long-form sets pinned to 찬양 out of the box.
    ///
    /// These are single videos, not playlists — a three-hour 찬송가 연속 듣기
    /// is a set list that happens to be one upload. They are the thing you
    /// put on and leave on, so they belong at the top of the tab rather than
    /// sinking under this week's uploads.
    static let defaultPinnedVideos: [(videoId: String, title: String, channelId: String, channelTitle: String)] = [
        (
            "EwY1Z6_6H3I",
            "일상에 틀어 놓는 잔잔한 찬송가 연속 듣기ㅣ어쿠스틱 편곡ㅣ3시간",
            "UCwmy8BC5ng0a0PWKDuRH08Q",
            "ALL THAT HYMN 올댓힘"
        ),
        (
            "Xsnhus5FkKw",
            "신나는 찬송가 리스트 1-5 총집합 (피아편곡 / 54곡 연속듣기)",
            "UCmDCtLeqOzF7_uf_UXoNiYA",
            "F.I.A WORSHIP"
        )
    ]

    /// The channel whose psalm readings pair with the 시편 screen.
    static let psalmAudioChannelId = "UCISl2wEDnzYeg-k_kElfN4Q"   // 공동체성경읽기

    /// Adds any default channel that has never been seeded on this device.
    ///
    /// Not "only when empty": that left every device stuck with whichever
    /// defaults existed at first launch, so later additions — the worship
    /// channels, 교제 — could never arrive. A per-channel record means a
    /// channel you delete stays deleted rather than reappearing.
    @MainActor
    static func seedIfEmpty(context: ModelContext) {
        let defaults = UserDefaults.standard
        let seededKey = "channels.seededIds"
        var seeded = Set(defaults.stringArray(forKey: seededKey) ?? [])

        let existing = (try? context.fetch(FetchDescriptor<Channel>())) ?? []
        let present = Set(existing.map(\.youtubeChannelId))
        var order = (existing.map(\.sortOrder).max() ?? -1) + 1

        var added = 0
        for suggestion in all {
            guard !present.contains(suggestion.channelId),
                  !seeded.contains(suggestion.channelId) else { continue }
            context.insert(Channel(
                youtubeChannelId: suggestion.channelId,
                title: suggestion.title,
                handle: suggestion.handle,
                purpose: suggestion.purpose,
                sortOrder: existing.isEmpty ? all.firstIndex(where: { $0.channelId == suggestion.channelId }) ?? order : order,
                isPinned: existing.isEmpty && suggestion.isPinned
            ))
            seeded.insert(suggestion.channelId)
            order += 1
            added += 1
        }

        seedPlaylists(context: context, defaults: defaults)
        seedPinnedVideos(context: context, defaults: defaults)

        guard added > 0 else { return }
        defaults.set(Array(seeded), forKey: seededKey)
        try? context.save()
        #if DEBUG
        print("[SolaPraise] seeded \(added) new default channels")
        #endif
    }

    @MainActor
    private static func seedPinnedVideos(context: ModelContext, defaults: UserDefaults) {
        let key = "videos.seededPinned"
        var seeded = Set(defaults.stringArray(forKey: key) ?? [])

        let existing = (try? context.fetch(FetchDescriptor<CachedVideo>())) ?? []
        var added = 0

        for entry in defaultPinnedVideos {
            guard !seeded.contains(entry.videoId) else { continue }
            if let known = existing.first(where: { $0.videoId == entry.videoId }) {
                // Already fetched by a feed refresh — just pin it.
                known.isPinned = true
            } else {
                let video = CachedVideo(
                    videoId: entry.videoId,
                    title: entry.title,
                    channelId: entry.channelId,
                    channelTitle: entry.channelTitle,
                    // i.ytimg serves art for every video at a fixed path, so
                    // the card is complete before any API call is made.
                    thumbnailURLString: "https://i.ytimg.com/vi/\(entry.videoId)/mqdefault.jpg",
                    source: .manual
                )
                video.isPinned = true
                context.insert(video)
            }
            seeded.insert(entry.videoId)
            added += 1
        }

        guard added > 0 else { return }
        defaults.set(Array(seeded), forKey: key)
        try? context.save()
    }

    /// Same per-item record as the channels, so a playlist you remove stays
    /// removed rather than coming back on the next launch.
    @MainActor
    private static func seedPlaylists(context: ModelContext, defaults: UserDefaults) {
        let key = "playlists.seededIds"
        var seeded = Set(defaults.stringArray(forKey: key) ?? [])

        let existing = (try? context.fetch(FetchDescriptor<CachedPlaylist>())) ?? []
        let present = Set(existing.map(\.playlistId))

        var added = 0
        for entry in defaultPlaylists {
            // Correct one already seeded rather than leaving a device stuck
            // with an earlier, wrong definition of the same playlist.
            if let existing = existing.first(where: { $0.playlistId == entry.playlistId }) {
                if existing.titleFilter != entry.titleFilter || existing.title != entry.title {
                    existing.title = entry.title
                    existing.titleFilter = entry.titleFilter
                    added += 1
                }
                seeded.insert(entry.playlistId)
                continue
            }
            guard !present.contains(entry.playlistId),
                  !seeded.contains(entry.playlistId) else { continue }
            context.insert(CachedPlaylist(
                playlistId: entry.playlistId,
                channelId: "",
                title: entry.title,
                purpose: entry.purpose,
                titleFilter: entry.titleFilter
            ))
            seeded.insert(entry.playlistId)
            added += 1
        }

        guard added > 0 else { return }
        defaults.set(Array(seeded), forKey: key)
        try? context.save()
    }
}
