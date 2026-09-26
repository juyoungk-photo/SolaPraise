//
//  Models.swift
//  SolaPraise
//
//  SwiftData models. These are a LOCAL CACHE ONLY.
//
//  Playlists are deliberately absent: they live in the user's real YouTube
//  account and are read live, so the library can never fork from what the
//  YouTube app shows. What is cached here is the whitelist, the feed
//  metadata that RSS gives us for free, and local-only watch stats.
//

import Foundation
import SwiftData

// MARK: - Purpose

/// The app's two jobs. Every channel and topic search belongs to exactly one.
enum Purpose: String, Codable, CaseIterable, Identifiable {
    case worship
    case word
    /// 교제 — fellowship. Neither 말씀 nor 찬양, so it stays out of both feeds
    /// and surfaces through 보관함 and 홈 instead of getting its own tab.
    case fellowship

    var id: String { rawValue }

    var title: String {
        switch self {
        case .worship:    return "찬양"
        case .word:       return "말씀"
        case .fellowship: return "교제"
        }
    }
    var symbolName: String {
        switch self {
        case .worship:    return "music.note"
        case .word:       return "book.closed"
        case .fellowship: return "person.2"
        }
    }
}

// MARK: - Channel (the whitelist)

@Model
final class Channel {
    /// YouTube's UC… channel id. Unique — adding the same channel twice is a no-op.
    @Attribute(.unique) var youtubeChannelId: String
    var title: String
    var handle: String?
    var thumbnailURLString: String?
    var purposeRaw: String
    var sortOrder: Int
    /// At most one channel per purpose is pinned; its newest upload gets the
    /// big card at the top of that tab.
    var isPinned: Bool
    var addedAt: Date
    var lastRefreshedAt: Date?

    init(
        youtubeChannelId: String,
        title: String,
        handle: String? = nil,
        thumbnailURLString: String? = nil,
        purpose: Purpose,
        sortOrder: Int = 0,
        isPinned: Bool = false
    ) {
        self.youtubeChannelId = youtubeChannelId
        self.title = title
        self.handle = handle
        self.thumbnailURLString = thumbnailURLString
        self.purposeRaw = purpose.rawValue
        self.sortOrder = sortOrder
        self.isPinned = isPinned
        self.addedAt = Date()
    }

    var purpose: Purpose {
        get { Purpose(rawValue: purposeRaw) ?? .word }
        set { purposeRaw = newValue.rawValue }
    }
    var thumbnailURL: URL? { thumbnailURLString.flatMap(URL.init(string:)) }
    var feedURL: URL? { YouTubeID.rssFeedURL(channelId: youtubeChannelId) }

    /// Compact label for the jump bar. Channel titles carry suffixes like
    /// "- SF BayArea" or "Scripture Union Korea" that make chips so wide only
    /// one fits on screen, which defeats the point of a shortcut row.
    var shortTitle: String {
        var name = title
        for separator in [" - ", " – ", " | ", "("] {
            if let range = name.range(of: separator) {
                name = String(name[..<range.lowerBound])
            }
        }
        name = name.trimmingCharacters(in: .whitespaces)
        // Drop a trailing latin transliteration ("성서유니온 Scripture Union").
        if let firstLatin = name.firstIndex(where: { $0.isASCII && $0.isLetter }),
           name.distance(from: name.startIndex, to: firstLatin) > 1 {
            name = String(name[..<firstLatin]).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? title : name
    }
}

// MARK: - CachedVideo (feed metadata)

@Model
final class CachedVideo {
    @Attribute(.unique) var videoId: String
    var title: String
    var channelId: String?
    var channelTitle: String?
    var thumbnailURLString: String?
    var publishedAt: Date?
    /// Nil until a batched videos.list call fills it in — RSS omits duration.
    var durationSeconds: Int?
    var sourceRaw: String
    var fetchedAt: Date
    /// nil = not yet checked. false = the rights holder blocks embedding, so
    /// the in-app player will fail and we must hand off to YouTube.
    var isEmbeddable: Bool?
    /// Filled by the same batched videos.list that fetches durations, so it
    /// costs nothing extra — comparing two uploads of one worship song needs
    /// it as much as the length does.
    var viewCount: Int?

    /// Kept at the top of its feed.
    ///
    /// Not only playlists: a three-hour "찬송가 연속 듣기" is a set list that
    /// happens to be one video, and it is exactly the thing you want waiting
    /// on the tab rather than buried under this week's uploads.
    var isPinned: Bool = false

    /// Raw description. Worship channels publish set lists with timestamps and
    /// keys here, which WorshipSetParser turns into a jumpable song list.
    var descriptionText: String?

    init(
        videoId: String,
        title: String,
        channelId: String? = nil,
        channelTitle: String? = nil,
        thumbnailURLString: String? = nil,
        publishedAt: Date? = nil,
        durationSeconds: Int? = nil,
        source: Source
    ) {
        self.videoId = videoId
        self.title = title
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.thumbnailURLString = thumbnailURLString
        self.publishedAt = publishedAt
        self.durationSeconds = durationSeconds
        self.sourceRaw = source.rawValue
        self.fetchedAt = Date()
    }

    enum Source: String, Codable {
        case rss            // free
        case topicSearch    // cost 100 units
        case manual
    }

    var source: Source {
        get { Source(rawValue: sourceRaw) ?? .rss }
        set { sourceRaw = newValue.rawValue }
    }
    var thumbnailURL: URL? { thumbnailURLString.flatMap(URL.init(string:)) }
    var durationLabel: String? {
        durationSeconds.map(ISO8601Duration.format)
    }

    /// Set list published in the description, if any.
    var worshipSet: [WorshipSetItem] {
        WorshipSetParser.parse(descriptionText ?? "")
    }
}

// MARK: - CachedPlaylist (a channel's own playlists)

/// Playlists published by a whitelisted channel — 공동체성경읽기 organises its
/// readings this way, so the videos alone are only half the channel.
@Model
final class CachedPlaylist {
    @Attribute(.unique) var playlistId: String
    var channelId: String
    var title: String
    var thumbnailURLString: String?
    var itemCount: Int
    var fetchedAt: Date

    /// Which feed this playlist belongs on, when it was added deliberately.
    ///
    /// Nil for playlists discovered by walking a channel — those inherit the
    /// channel's purpose. Set when someone pastes a link, because a worship
    /// playlist can live on a channel filed under 말씀: a church posts its
    /// sermons and its worship from the same account.
    var purposeRaw: String?

    /// Kept at the top of its feed.
    ///
    /// A channel can have eighty playlists and you return to three of them.
    /// Pinning is how those three stop being eighty scrolls away.
    var isPinned: Bool = false

    /// Keeps only the items whose title contains this.
    ///
    /// YouTube's auto-generated "Live streams" playlist holds every stream a
    /// channel has ever made, which for a church means weekday 모닝워십 by the
    /// hundred with the Sunday services scattered among them. The playlist is
    /// still the right source — it updates itself and needs no maintenance —
    /// but it needs narrowing to be worth opening.
    var titleFilter: String?

    /// The full YouTube invite URL, when the playlist was added from one.
    ///
    /// A collaborative playlist's invite carries a `jct` token, and that
    /// token is what actually lets someone join as a collaborator — the
    /// playlist id alone only lets them read. Keeping it means the owner can
    /// re-send the invite to a new team member without going to find it
    /// again. Device only: it is closer to a credential than to a link, and
    /// it is never written into the app's source.
    var inviteURLString: String?

    init(playlistId: String, channelId: String, title: String,
         thumbnailURLString: String? = nil, itemCount: Int = 0,
         purpose: Purpose? = nil, isPinned: Bool = false,
         titleFilter: String? = nil, inviteURLString: String? = nil) {
        self.playlistId = playlistId
        self.channelId = channelId
        self.title = title
        self.thumbnailURLString = thumbnailURLString
        self.itemCount = itemCount
        self.fetchedAt = Date()
        self.purposeRaw = purpose?.rawValue
        self.isPinned = isPinned
        self.titleFilter = titleFilter
        self.inviteURLString = inviteURLString
    }

    var inviteURL: URL? { inviteURLString.flatMap(URL.init(string:)) }
    var isCollaborative: Bool { inviteURL != nil }

    var thumbnailURL: URL? { thumbnailURLString.flatMap(URL.init(string:)) }
}

// MARK: - TopicSearch (saved scoped searches)

@Model
final class TopicSearch {
    var label: String
    var query: String
    var purposeRaw: String
    var sortOrder: Int
    var lastRunAt: Date?
    var createdAt: Date

    init(label: String, query: String, purpose: Purpose, sortOrder: Int = 0) {
        self.label = label
        self.query = query
        self.purposeRaw = purpose.rawValue
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    var purpose: Purpose {
        get { Purpose(rawValue: purposeRaw) ?? .worship }
        set { purposeRaw = newValue.rawValue }
    }
}

// MARK: - WatchEvent (local stats)

@Model
final class WatchEvent {
    var videoId: String
    var title: String?
    var startedAt: Date
    var secondsWatched: Int
    var completed: Bool

    init(videoId: String, title: String? = nil, startedAt: Date = Date(),
         secondsWatched: Int = 0, completed: Bool = false) {
        self.videoId = videoId
        self.title = title
        self.startedAt = startedAt
        self.secondsWatched = secondsWatched
        self.completed = completed
    }
}

// MARK: - Schema

enum SolaPraiseSchema {
    static let models: [any PersistentModel.Type] = [
        Channel.self,
        CachedVideo.self,
        TopicSearch.self,
        WatchEvent.self,
        HomeCard.self,
        SavedSong.self,
        CachedPlaylist.self
    ]
}
