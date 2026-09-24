//
//  WordFeedView.swift
//  SolaPraise
//
//  Purpose 2: the daily Word — QT and prayer from whitelisted channels.
//
//  Everything here is finite by construction: a pinned hero card, then a hard
//  cap of `perChannelCap` videos per channel, then an explicit end marker.
//  There is no pagination and nothing below the fold that loads more.
//

import SwiftUI
import SwiftData

struct WordFeedView: View {

    /// The hard cap. Changing this number is the only way to see more, which
    /// is exactly the point.
    private static var perChannelCap: Int {
        #if DEBUG
        if let override = DebugHarness.perChannelCap { return override }
        #endif
        return 4
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @StateObject private var feed = FeedStore()

    // A combined filter+sort @Query blows the SwiftUI type-checker's budget
    // here; querying all channels and filtering in a computed property is both
    // faster to compile and cheap at this size.
    @Query(sort: [SortDescriptor(\Channel.sortOrder), SortDescriptor(\Channel.addedAt)])
    private var allChannels: [Channel]

    private var channels: [Channel] {
        allChannels.filter { $0.purposeRaw == Purpose.word.rawValue }
    }

    @Query(sort: [SortDescriptor(\CachedVideo.publishedAt, order: .reverse)])
    private var allVideos: [CachedVideo]

    @Query(sort: [SortDescriptor(\CachedPlaylist.title)])
    private var allPlaylists: [CachedPlaylist]

    @State private var showSettings = false
    @State private var showAddChannel = false
    @State private var playRequest: FeedPlayRequest?
    @State private var isLoadingPlaylist = false
    @State private var playlistError: String?

    var body: some View {
        NavigationStack {
            Group {
                if channels.isEmpty {
                    emptyState
                } else {
                    feedScroll
                }
            }
            .navigationTitle("말씀")
            // Inline, because a large title plus the pinned channel bar leaves
            // a dead band roughly 200pt tall and pushes the chips off screen.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showAddChannel) { AddChannelView(defaultPurpose: .word) }
            .fullScreenCover(item: $playRequest) { request in
                WatchScreen(queue: request.queue, startIndex: request.startIndex)
            }
            .refreshable { await refresh() }
            .task {
                #if DEBUG
                print("[SolaPraise] WordFeed channels=\(channels.count) allChannels=\(allChannels.count) videos=\(allVideos.count)")
                #endif
                // Only auto-refresh when there is nothing to show; otherwise
                // the cached feed is already correct and a fetch is waste.
                if !channels.isEmpty && allVideos.isEmpty { await refresh() }
            }
            .onChange(of: channels.count) { _, count in
                // First channel just added — fill the feed straight away
                // rather than making the user pull to refresh.
                guard count > 0, allVideos.isEmpty else { return }
                Task { await refresh() }
            }
        }
    }

    // MARK: - Feed

    private var feedScroll: some View {
        ScrollViewReader { proxy in
            scrollBody
                .safeAreaInset(edge: .top) {
                    ChannelJumpBar(channels: channels) { channel in
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(channel.youtubeChannelId, anchor: .top)
                        }
                    }
                }
        }
    }

    private var scrollBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if let hero = pinnedVideo {
                    Button { play(hero, in: [hero]) } label: {
                        PinnedVideoCard(video: hero)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                ForEach(channels) { channel in
                    let videos = videos(for: channel)
                    if !videos.isEmpty {
                        ChannelSection(
                            channel: channel,
                            videos: videos,
                            playlists: playlists(for: channel),
                            onSelect: { video in play(video, in: videos) },
                            onSelectPlaylist: { playlist in
                                Task { await playPlaylist(playlist) }
                            }
                        )
                        .id(channel.youtubeChannelId)
                    }
                }

                if isLoadingPlaylist {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("불러오는 중…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                }
                if let playlistError {
                    Text(playlistError).font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }
                if let message = feed.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }

                FeedEndMarker(refreshedAt: feed.lastRefreshedAt, text: "여기까지입니다")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No channels yet", systemImage: "book.closed")
        } description: {
            Text("Add your church and QT channels — 매일성경, 주일예배, 새벽기도 — and their newest videos appear here each morning.")
        } actions: {
            Button("Add a channel") { showAddChannel = true }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Derived data

    /// The pinned channel's newest upload, shown as the hero card.
    private var pinnedVideo: CachedVideo? {
        guard let pinned = channels.first(where: \.isPinned) else { return nil }
        return allVideos.first { $0.channelId == pinned.youtubeChannelId }
    }

    /// Latest N for a channel, minus whatever is already the hero card.
    private func videos(for channel: Channel) -> [CachedVideo] {
        let heroId = pinnedVideo?.videoId
        return allVideos
            .filter { $0.channelId == channel.youtubeChannelId && $0.videoId != heroId }
            .prefix(Self.perChannelCap)
            .map { $0 }
    }

    // MARK: - Actions

    private func playlists(for channel: Channel) -> [CachedPlaylist] {
        allPlaylists.filter { $0.channelId == channel.youtubeChannelId }
    }

    /// Loads a channel playlist and starts playing it.
    private func playPlaylist(_ playlist: CachedPlaylist) async {
        guard auth.isSignedIn else {
            playlistError = "플레이리스트를 재생하려면 Google 로그인이 필요합니다."
            return
        }
        isLoadingPlaylist = true
        playlistError = nil
        defer { isLoadingPlaylist = false }

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            let items = try await client.playlistItems(playlistId: playlist.playlistId)
            let queue = items.compactMap { item -> PlayableVideo? in
                guard !item.isUnavailable, let id = item.videoId else { return nil }
                return PlayableVideo(item: item)
            }
            guard !queue.isEmpty else {
                playlistError = "\(playlist.title): 재생할 수 있는 영상이 없습니다."
                return
            }
            playRequest = FeedPlayRequest(queue: queue, startIndex: 0)
        } catch {
            playlistError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func play(_ video: CachedVideo, in section: [CachedVideo]) {
        let queue = section.map {
            PlayableVideo(cached: $0)
        }
        let start = queue.firstIndex { $0.id == video.videoId } ?? 0
        playRequest = FeedPlayRequest(queue: queue, startIndex: start)
    }

    private func refresh() async {
        let client = auth.isSignedIn ? AppServices.client(auth: auth, quota: quota) : nil
        await feed.refresh(purpose: .word, context: modelContext, client: client)
    }
}

// MARK: - Channel section

struct ChannelSection: View {
    let channel: Channel
    let videos: [CachedVideo]
    var playlists: [CachedPlaylist] = []
    let onSelect: (CachedVideo) -> Void
    var onSelectPlaylist: ((CachedPlaylist) -> Void)? = nil

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let url = channel.thumbnailURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle().fill(.quaternary)
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                }
                Text(channel.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(videos.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            // Channels like 공동체성경읽기 organise by playlist, so the videos
            // alone are only half the channel.
            if !playlists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(playlists) { playlist in
                            Button {
                                onSelectPlaylist?(playlist)
                            } label: {
                                PlaylistChip(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(videos) { video in
                    Button { onSelect(video) } label: { VideoCard(video: video) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct PlaylistChip: View {
    let playlist: CachedPlaylist

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 34, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("^[\(playlist.itemCount) video](inflect: true)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 200, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Play request

struct FeedPlayRequest: Identifiable {
    let id = UUID()
    let queue: [PlayableVideo]
    let startIndex: Int
}
