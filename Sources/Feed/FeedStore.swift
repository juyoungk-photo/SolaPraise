//
//  FeedStore.swift
//  SolaPraise
//
//  Refresh orchestration for both feeds.
//
//  The expensive-looking part is deliberately free: channel uploads come from
//  the Atom feed (0 units). The only quota spent here is one batched
//  videos.list per 50 videos that still lack a duration — and only for videos
//  we have never seen before, so a steady-state daily refresh costs ~1 unit.
//

import Foundation
import SwiftData
import SwiftUI

@MainActor
final class FeedStore: ObservableObject {

    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefreshedAt: Date?

    private let rss: YouTubeRSSClient
    private static let lastRefreshKey = "feed.lastRefreshedAt"

    init(rss: YouTubeRSSClient = YouTubeRSSClient()) {
        self.rss = rss
        let stored = UserDefaults.standard.object(forKey: Self.lastRefreshKey) as? Date
        self.lastRefreshedAt = stored
    }

    /// Refreshes every active channel (optionally limited to one purpose).
    ///
    /// A failing channel is recorded but never aborts the run — one private or
    /// renamed channel must not stop the rest of the morning's QT arriving.
    func refresh(
        purpose: Purpose? = nil,
        context: ModelContext,
        client: YouTubeAPIClient?
    ) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        let channels = fetchChannels(purpose: purpose, context: context)
        #if DEBUG
        print("[SolaPraise] refresh purpose=\(purpose?.rawValue ?? "all") channels=\(channels.count)")
        #endif
        guard !channels.isEmpty else { return }

        var failures: [String] = []
        var seenIds = existingVideoIds(context: context)

        for channel in channels {
            // Prefer the API when we have a token: RSS is free but flaky, and
            // one unit per channel is a rounding error against 10,000/day.
            if let client {
                // The psalm-reading channel is fetched deeply so every
                // "시편 N장" is available to match against, not just recent
                // uploads. 1 unit per 50 — a few units, once.
                // The psalm-reading channel needs depth: its individual
                // 시편 readings sit far behind its daily 30분 신구약 uploads.
                // But do it ONCE — re-running a 1000-item walk on every
                // refresh would burn ~20 units each time for nothing, so once
                // a decent catalogue is cached we drop back to a shallow
                // fetch for new uploads.
                let isPsalmChannel = channel.youtubeChannelId == DefaultChannels.psalmAudioChannelId
                let alreadyDeep = isPsalmChannel && cachedCount(for: channel.youtubeChannelId, context: context) >= 400
                let depth = (isPsalmChannel && !alreadyDeep) ? 1000 : 15
                if let items = try? await client.channelUploads(channelId: channel.youtubeChannelId, limit: depth),
                   !items.isEmpty {
                    for item in items {
                        guard let videoId = item.videoId, !seenIds.contains(videoId) else { continue }
                        context.insert(CachedVideo(
                            videoId: videoId,
                            title: item.title,
                            channelId: channel.youtubeChannelId,
                            channelTitle: item.channelTitle ?? channel.title,
                            thumbnailURLString: item.thumbnailURL?.absoluteString,
                            publishedAt: item.contentDetails?.videoPublishedAt,
                            source: .rss
                        ))
                        if let last = try? context.fetch(FetchDescriptor<CachedVideo>(
                            predicate: #Predicate { $0.videoId == videoId }
                        )).first {
                            last.descriptionText = item.descriptionText
                        }
                        seenIds.insert(videoId)
                    }
                    channel.lastRefreshedAt = Date()
                    #if DEBUG
                    print("[SolaPraise] API OK \(channel.title): \(items.count) videos")
                    #endif
                    continue
                }
            }

            do {
                let feed = try await rss.fetch(channelId: channel.youtubeChannelId)

                // The feed knows the channel's real title; adopt it if ours is
                // a placeholder from a hand-typed id.
                if let feedTitle = feed.channelTitle, !feedTitle.isEmpty {
                    channel.title = feedTitle
                }

                for video in feed.videos where !seenIds.contains(video.videoId) {
                    context.insert(CachedVideo(
                        videoId: video.videoId,
                        title: video.title,
                        channelId: video.channelId ?? channel.youtubeChannelId,
                        channelTitle: video.authorName ?? channel.title,
                        thumbnailURLString: video.thumbnailURL?.absoluteString,
                        publishedAt: video.published,
                        source: .rss
                    ))
                    seenIds.insert(video.videoId)
                }
                channel.lastRefreshedAt = Date()
                #if DEBUG
                print("[SolaPraise] RSS OK \(channel.title): \(feed.videos.count) videos")
                #endif
            } catch {
                failures.append(channel.title)
                #if DEBUG
                print("[SolaPraise] RSS FAIL \(channel.title) [\(channel.youtubeChannelId)]: \(error)")
                #endif
            }
        }

        try? context.save()
        await fillMissingDurations(context: context, client: client)
        await refreshChannelPlaylists(channels: channels, context: context, client: client)
        if purpose == nil || purpose == .fellowship, let client {
            await syncSharedList(context: context, client: client)
        }
        await fillMissingPlaylistDetails(context: context, client: client)
        if let client { await addSharedListChannels(context: context, client: client) }

        let now = Date()
        lastRefreshedAt = now
        UserDefaults.standard.set(now, forKey: Self.lastRefreshKey)

        if !failures.isEmpty {
            errorMessage = "Couldn't refresh: \(failures.joined(separator: ", "))"
        }
    }

    /// Fills in what a playlist pinned from a link does not come with.
    ///
    /// Pinning from a URL gives the app an id and nothing else, so the row
    /// read "재생목록 0" with no artwork until somebody opened it. One call
    /// covers fifty of them for a single unit, so this is cheap enough to
    /// run on an ordinary refresh.
    /// The church's shared list of unlisted playlists (SharedChannelList):
    /// what it names is added to 관심 채널, and what it no longer names
    /// leaves — only what the list itself added. A list that could not be
    /// read changes nothing. Details and the channel come in the next step.
    private func syncSharedList(context: ModelContext, client: YouTubeAPIClient) async {
        var read: SharedChannelList.Listing?
        #if DEBUG
        // -uiTestSharedList "<the list's text>": as if the folder held it.
        if let at = DebugHarness.args.firstIndex(of: "-uiTestSharedList"), at + 1 < DebugHarness.args.count {
            read = SharedChannelList.listing(in: DebugHarness.args[at + 1])
        }
        #endif
        if read == nil, let folderId = ContiFolder.folderId { read = await SharedChannelList.fetch(folderId: folderId) }
        guard let listing = read else { return }

        // Playlists.
        let cached = (try? context.fetch(FetchDescriptor<CachedPlaylist>())) ?? []
        let known = Set(cached.map(\.playlistId))
        for id in listing.playlists where !known.contains(id) {
            context.insert(CachedPlaylist(playlistId: id, channelId: "", title: "재생목록",
                                          purpose: .fellowship, isSharedListed: true))
        }
        let listed = Set(listing.playlists)
        for playlist in cached where playlist.isSharedListed && !listed.contains(playlist.playlistId) {
            context.delete(playlist)
        }

        // Videos: those the list names, and the newest of each listed
        // playlist — so a service added to the playlist shows under 최근
        // 영상 too, on a channel whose own feed lists nothing.
        var wanted = listing.videos
        var complete = true
        for id in listing.playlists {
            guard let items = try? await client.recentPlaylistItems(playlistId: id, pages: 1) else {
                complete = false; continue
            }
            for item in items.prefix(20) where !item.isUnavailable {
                if let video = item.videoId, !wanted.contains(video) { wanted.append(video) }
            }
        }
        let videos = (try? context.fetch(FetchDescriptor<CachedVideo>())) ?? []
        let have = Set(videos.map(\.videoId))
        let missing = wanted.filter { !have.contains($0) }
        if !missing.isEmpty, let details = try? await client.videos(ids: missing) {
            for video in details {
                let cachedVideo = CachedVideo(
                    videoId: video.id, title: video.snippet?.title ?? "영상",
                    channelId: video.snippet?.channelId, channelTitle: video.snippet?.channelTitle,
                    thumbnailURLString: video.snippet?.thumbnails?.best?.absoluteString,
                    publishedAt: video.snippet?.publishedAt, durationSeconds: video.durationSeconds,
                    source: .manual)
                cachedVideo.isSharedListed = true
                cachedVideo.isEmbeddable = video.isEmbeddable
                context.insert(cachedVideo)
            }
        }
        // Only on a complete read: a playlist that failed to load must not
        // take its services off everyone's page.
        if complete {
            let keep = Set(wanted)
            for video in videos where video.isSharedListed && !keep.contains(video.videoId) {
                context.delete(video)
            }
        }

        // A channel the list brought in leaves with its last listed item.
        let key = Self.sharedListChannelsKey
        var added = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let keptVideoChannels = videos.filter { $0.isSharedListed && wanted.contains($0.videoId) }.compactMap(\.channelId)
        let stillListed = Set(cached.filter { $0.isSharedListed && listed.contains($0.playlistId) }.map(\.channelId))
            .union(keptVideoChannels)
        for channel in (try? context.fetch(FetchDescriptor<Channel>())) ?? []
        where added.contains(channel.youtubeChannelId) && !stillListed.contains(channel.youtubeChannelId) {
            context.delete(channel)
            added.remove(channel.youtubeChannelId)
        }
        UserDefaults.standard.set(Array(added), forKey: key)
        try? context.save()
        #if DEBUG
        print("[SolaPraise] shared list: \(listing.playlists.count) playlist(s), \(listing.videos.count) video(s), \(wanted.count) video(s) shown")
        #endif
    }

    private func fillMissingPlaylistDetails(
        context: ModelContext, client: YouTubeAPIClient?
    ) async {
        guard let client else { return }
        let cached = (try? context.fetch(FetchDescriptor<CachedPlaylist>())) ?? []
        let incomplete = cached.filter { $0.itemCount == 0 || $0.thumbnailURLString == nil || $0.channelId.isEmpty }
        guard !incomplete.isEmpty else { return }

        guard let fetched = try? await client.playlists(ids: incomplete.map(\.playlistId))
        else { return }

        let byId = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for playlist in incomplete {
            guard let detail = byId[playlist.playlistId] else { continue }
            // A count of zero means "not known yet" here, so only a real
            // count overwrites it — a genuinely empty playlist stays at 0
            // either way.
            if detail.itemCount > 0 { playlist.itemCount = detail.itemCount }
            if playlist.thumbnailURLString == nil {
                playlist.thumbnailURLString = detail.thumbnailURL?.absoluteString
            }
            // Its channel, so a playlist added by link — an unlisted one
            // from a channel with nothing public — shows on that channel's
            // page as well as where it was pinned.
            if playlist.channelId.isEmpty, let owner = detail.snippet?.channelId { playlist.channelId = owner }
            if playlist.publishedAt == nil { playlist.publishedAt = detail.snippet?.publishedAt }
            // The placeholder title a pinned link starts with.
            if playlist.title == "재생목록" || playlist.title.isEmpty, !detail.title.isEmpty {
                playlist.title = detail.title
            }
        }
        try? context.save()
    }

    /// A playlist on the church's list shows on its channel's page, so that
    /// channel joins 관심 채널 if this member does not have it — once: a
    /// channel the member then removes stays removed.
    private static let sharedListChannelsKey = "sharedList.addedChannels"

    private func addSharedListChannels(context: ModelContext, client: YouTubeAPIClient) async {
        let key = Self.sharedListChannelsKey
        var added = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let playlists = (try? context.fetch(FetchDescriptor<CachedPlaylist>())) ?? []
        let channels = (try? context.fetch(FetchDescriptor<Channel>())) ?? []
        let have = Set(channels.map(\.youtubeChannelId))
        let sharedVideos = (try? context.fetch(FetchDescriptor<CachedVideo>(
            predicate: #Predicate { $0.isSharedListed }))) ?? []
        let wanted = Set(playlists.filter(\.isSharedListed).map(\.channelId))
            .union(sharedVideos.compactMap(\.channelId))
            .filter { !$0.isEmpty && !have.contains($0) && !added.contains($0) }
        guard !wanted.isEmpty else { return }
        var order = (channels.map(\.sortOrder).max() ?? 0) + 1
        for id in wanted.sorted() {
            guard let found = try? await client.channel(for: .channelId(id)) else { continue }
            context.insert(Channel(youtubeChannelId: found.id, title: found.title, handle: found.handle,
                                   thumbnailURLString: found.thumbnailURL?.absoluteString,
                                   purpose: .fellowship, sortOrder: order))
            order += 1
            added.insert(id)
        }
        UserDefaults.standard.set(Array(added), forKey: key)
        try? context.save()
    }

    /// A channel's own playlists, 1 unit each. Cheap, and for channels that
    /// organise by playlist the videos alone are only half the story.
    private func refreshChannelPlaylists(
        channels: [Channel], context: ModelContext, client: YouTubeAPIClient?
    ) async {
        guard let client else { return }

        let existing = (try? context.fetch(FetchDescriptor<CachedPlaylist>())) ?? []
        var known = Set(existing.map(\.playlistId))

        for channel in channels {
            guard let playlists = try? await client.channelPlaylists(channelId: channel.youtubeChannelId) else {
                continue
            }
            for playlist in playlists {
                // Known ones are refreshed rather than skipped: a series
                // grows week by week, and a count frozen at the day it was
                // first seen made a live series look abandoned.
                if let cached = existing.first(where: { $0.playlistId == playlist.id }) {
                    cached.itemCount = playlist.itemCount
                    cached.publishedAt = playlist.snippet?.publishedAt
                    continue
                }
                guard !known.contains(playlist.id) else { continue }
                let cached = CachedPlaylist(
                    playlistId: playlist.id,
                    channelId: channel.youtubeChannelId,
                    title: playlist.title,
                    thumbnailURLString: playlist.thumbnailURL?.absoluteString,
                    itemCount: playlist.itemCount
                )
                cached.publishedAt = playlist.snippet?.publishedAt
                context.insert(cached)
                known.insert(playlist.id)
            }
        }
        try? context.save()
        // Best effort: a psalm playlist that is not there yet is not a
        // reason to fail the refresh that found the channels.
        _ = await ingestPsalmPlaylist(context: context, client: client)
    }

    /// Pulls 공동체성경읽기's psalm playlist into the cache.
    ///
    /// Walking that channel's uploads does not work: it publishes a daily
    /// 30분 신구약 video, so the 1000 most recent uploads contain zero psalm
    /// readings — verified on device. But the channel indexes itself by book
    /// ("19. 시편_장별 구절 영상"), so one playlist holds all 150 chapters for
    /// about 3 units. Runs once; afterwards the cache already has them.
    func ingestPsalmPlaylist(context: ModelContext, client: YouTubeAPIClient?,
                             channelId: String = DefaultChannels.psalmAudioChannelId) async -> Int {
        guard let client else { return 0 }

        let psalmChannel = channelId
        let cached = (try? context.fetch(FetchDescriptor<CachedVideo>())) ?? []
        // Already have a healthy number of psalm readings? Nothing to do.
        let existingPsalms = cached.filter {
            $0.channelId == psalmChannel && $0.title.contains("시편")
        }
        guard existingPsalms.count < 100 else { return 0 }

        let playlists = (try? context.fetch(FetchDescriptor<CachedPlaylist>())) ?? []
        guard let psalmList = playlists.first(where: {
            $0.channelId == psalmChannel && $0.title.contains("시편")
        }) else { return 0 }

        guard let items = try? await client.playlistItems(playlistId: psalmList.playlistId) else { return 0 }

        var known = Set(cached.map(\.videoId))
        for item in items {
            guard let videoId = item.videoId, !known.contains(videoId) else { continue }
            context.insert(CachedVideo(
                videoId: videoId,
                title: item.title,
                channelId: psalmChannel,
                channelTitle: item.channelTitle,
                thumbnailURLString: item.thumbnailURL?.absoluteString,
                publishedAt: item.contentDetails?.videoPublishedAt,
                source: .manual
            ))
            known.insert(videoId)
        }
        try? context.save()
        #if DEBUG
        print("[SolaPraise] psalm playlist '\(psalmList.title)' → \(items.count) items")
        #endif
        return items.count
    }

    /// Finds one specific psalm reading by searching the channel directly.
    ///
    /// The fallback when the playlist route has not filled the cache. Costs
    /// 100 units, so it is only ever triggered by an explicit tap — never
    /// automatically, or opening the app 100 times would spend the day.
    @discardableResult
    func findPsalmVideo(chapter: Int, context: ModelContext,
                        client: YouTubeAPIClient?,
                        channelId: String = DefaultChannels.psalmAudioChannelId) async -> CachedVideo? {
        guard let client else { return nil }
        guard let results = try? await client.search(
            query: "시편 \(chapter)편", channelId: channelId, maxResults: 10
        ) else { return nil }

        let pattern = "시편\\s*\(chapter)\\s*[편장]"
        guard let match = results.first(where: {
            $0.title.range(of: pattern, options: .regularExpression) != nil
        }) ?? results.first, let videoId = match.videoId else { return nil }

        let existing = (try? context.fetch(FetchDescriptor<CachedVideo>(
            predicate: #Predicate { $0.videoId == videoId }
        )).first) ?? nil
        if let existing { return existing }

        let video = CachedVideo(
            videoId: videoId,
            title: match.title,
            channelId: channelId,
            channelTitle: match.snippet?.channelTitle,
            thumbnailURLString: match.snippet?.thumbnails?.best?.absoluteString,
            publishedAt: match.snippet?.publishedAt,
            source: .manual
        )
        context.insert(video)
        try? context.save()
        return video
    }

    // MARK: - Topic searches

    /// Runs each saved topic search at most once per day.
    ///
    /// Each one costs 100 units, so the once-a-day guard matters: five topics
    /// refreshed on every view appearance would burn the entire daily budget
    /// in twenty screen visits.
    func refreshTopics(context: ModelContext, client: YouTubeAPIClient?) async {
        guard let client else { return }

        let topics = (try? context.fetch(FetchDescriptor<TopicSearch>())) ?? []
        let stale = topics.filter { topic in
            guard let last = topic.lastRunAt else { return true }
            return !Calendar.current.isDateInToday(last)
        }
        guard !stale.isEmpty else { return }

        var seenIds = existingVideoIds(context: context)

        for topic in stale {
            guard let results = try? await client.search(query: topic.query) else {
                // Budget gone or network down — stop, don't hammer the rest.
                break
            }
            for result in results {
                guard let id = result.videoId, !seenIds.contains(id) else { continue }
                context.insert(CachedVideo(
                    videoId: id,
                    title: result.title,
                    channelId: result.snippet?.channelId,
                    channelTitle: result.snippet?.channelTitle,
                    thumbnailURLString: result.snippet?.thumbnails?.best?.absoluteString,
                    publishedAt: result.snippet?.publishedAt,
                    source: .topicSearch
                ))
                seenIds.insert(id)
            }
            topic.lastRunAt = Date()
        }

        try? context.save()
        await fillMissingDurations(context: context, client: client)
    }

    // MARK: - Durations

    /// RSS omits duration, so top it up with one videos.list per 50 — 1 unit
    /// each. Purely cosmetic, so any failure here is swallowed.
    private func fillMissingDurations(context: ModelContext, client: YouTubeAPIClient?) async {
        guard let client else { return }

        let descriptor = FetchDescriptor<CachedVideo>(
            predicate: #Predicate { $0.durationSeconds == nil }
        )
        let pending = (try? context.fetch(descriptor)) ?? []

        // The newest handful go in whether or not they need a duration.
        //
        // This call already knows liveBroadcastContent, and a live broadcast
        // is the one piece of state that goes stale on its own: 모닝워십
        // streams just before six and YouTube does not publish the archive
        // until that evening, so for the whole day between them the live
        // video IS the service. Checking it costs nothing — videos.list is
        // one unit for up to fifty ids either way.
        var newestDescriptor = FetchDescriptor<CachedVideo>(
            sortBy: [SortDescriptor(\CachedVideo.publishedAt, order: .reverse)]
        )
        newestDescriptor.fetchLimit = 20
        let newest = (try? context.fetch(newestDescriptor)) ?? []

        var wanted: [CachedVideo] = []
        var seen = Set<String>()
        for video in newest + pending where !seen.contains(video.videoId) {
            seen.insert(video.videoId)
            wanted.append(video)
        }
        guard !wanted.isEmpty else { return }

        // Cap the catch-up so adding several channels at once can't spend an
        // unbounded number of units in a single refresh.
        let ids = Array(wanted.prefix(200)).map(\.videoId)
        guard let videos = try? await client.videos(ids: ids) else { return }

        var durationById: [String: Int] = [:]
        var embeddableById: [String: Bool] = [:]
        var viewsById: [String: Int] = [:]
        var publishedById: [String: Date] = [:]
        var liveById: [String: Bool] = [:]
        for v in videos {
            if let secs = v.durationSeconds { durationById[v.id] = secs }
            embeddableById[v.id] = v.isEmbeddable
            if let views = v.viewCount { viewsById[v.id] = views }
            if let published = v.snippet?.publishedAt { publishedById[v.id] = published }
            liveById[v.id] = v.isLiveNow
        }
        guard !durationById.isEmpty || !embeddableById.isEmpty || !liveById.isEmpty
        else { return }

        var descriptionById: [String: String] = [:]
        for v in videos {
            if let text = v.snippet?.description, !text.isEmpty { descriptionById[v.id] = text }
        }
        let now = Date()
        for video in wanted {
            if let live = liveById[video.videoId] {
                video.isLiveNow = live
                video.liveCheckedAt = now
            }
            if let secs = durationById[video.videoId] { video.durationSeconds = secs }
            if let ok = embeddableById[video.videoId] { video.isEmbeddable = ok }
            if let views = viewsById[video.videoId] { video.viewCount = views }
            // Some feed sources carry no publish date at all, and the title
            // often does not say either — this is the one call that knows.
            if video.publishedAt == nil { video.publishedAt = publishedById[video.videoId] }
            if video.descriptionText == nil { video.descriptionText = descriptionById[video.videoId] }
        }
        try? context.save()
    }

    // MARK: - Fetch helpers

    private func fetchChannels(purpose: Purpose?, context: ModelContext) -> [Channel] {
        var descriptor = FetchDescriptor<Channel>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.addedAt)]
        )
        if let purpose {
            let raw = purpose.rawValue
            descriptor.predicate = #Predicate { $0.purposeRaw == raw }
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    /// How many videos we already hold for a channel — used to avoid
    /// repeating the expensive deep catalogue walk.
    private func cachedCount(for channelId: String, context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<CachedVideo>(
            predicate: #Predicate { $0.channelId == channelId }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// One query instead of a lookup per video — an upsert loop that fetches
    /// per id turns a 15-video feed into 15 round trips against the store.
    private func existingVideoIds(context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<CachedVideo>()
        let all = (try? context.fetch(descriptor)) ?? []
        return Set(all.map(\.videoId))
    }
}
