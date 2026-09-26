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

    @EnvironmentObject private var host: PlayerHost
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
    @State private var isLoadingPlaylist = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject private var daily: DailyReading
    @State private var showReading = false
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
            .fullScreenCover(isPresented: $showReading) {
                ReadingView { showReading = false }
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
            scrollBody(proxy)
        }
    }

    private func scrollBody(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            // Pinned section header rather than a top safe-area inset: the
            // inset moved vertically as the navigation chrome animated, which
            // read as the bar flickering away.
            LazyVStack(alignment: .leading, spacing: 26, pinnedViews: [.sectionHeaders]) {
                Section {
                bibleBar
                heroRow

                if !pinnedPlaylists.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("고정됨", systemImage: "pin.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(pinnedPlaylists) { playlist in
                            Button { Task { await openPlaylist(playlist) } } label: {
                                PlaylistBar(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
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
                } header: {
                    if !channels.isEmpty {
                        ChannelJumpBar(channels: channels) { channel in
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(channel.youtubeChannelId, anchor: .top)
                            }
                        }
                    }
                }
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

    /// The text itself, before any video.
    ///
    /// 말씀 opened straight into uploads, which put watching ahead of
    /// reading on the tab named for the word. The reading is the errand;
    /// the videos are how someone else works through it.
    private var bibleBar: some View {
        Button { showReading = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "text.book.closed.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(daily.title(for: daily.translation))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(daily.isCurrentRead ? "읽음" : "오늘의 성경 읽기")
                        .font(.caption2)
                        .foregroundStyle(daily.isCurrentRead ? .green : .secondary)
                }

                Spacer(minLength: 0)

                if daily.isCurrentRead {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// One hero on a phone, two side by side on an iPad.
    ///
    /// The two are the day's two obligations and they are not the same
    /// errand: today's devotional, and last Sunday's preaching. On a phone
    /// there is only room to lead with one, so the daily one wins.
    @ViewBuilder
    private var heroRow: some View {
        let today = pinnedVideo
        let sermon = latestSermon
        if today != nil || sermon != nil {
            HStack(alignment: .top, spacing: 14) {
                if let today {
                    Button { play(today, in: [today]) } label: {
                        PinnedVideoCard(video: today)
                    }
                    .buttonStyle(.plain)
                }
                if sizeClass == .regular, let sermon, sermon.videoId != today?.videoId {
                    Button { play(sermon, in: [sermon]) } label: {
                        PinnedVideoCard(video: sermon)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    /// Today's from the pinned channel — which on a Saturday is 토요예배,
    /// because that is what the channel published that day. Following the
    /// channel's own newest upload gets this right without the app having to
    /// know the week's shape.
    private var pinnedVideo: CachedVideo? {
        guard let pinned = channels.first(where: \.isPinned) else { return nil }
        return allVideos.first { $0.channelId == pinned.youtubeChannelId }
    }

    /// The most recent Sunday sermon cut, by the church's own title marker.
    private var latestSermon: CachedVideo? {
        allVideos.first { $0.title.contains("코너스톤교회-") }
    }

    private var pinnedPlaylists: [CachedPlaylist] {
        allPlaylists
            .filter { $0.purposeRaw == Purpose.word.rawValue }
            .sorted { ($0.isPinned ? 0 : 1, $0.title) < ($1.isPinned ? 0 : 1, $1.title) }
    }

    private func openPlaylist(_ playlist: CachedPlaylist) async {
        guard auth.isSignedIn else {
            playlistError = "재생목록을 열려면 Google 로그인이 필요합니다."
            return
        }
        let client = AppServices.client(auth: auth, quota: quota)
        let filter = playlist.titleFilter
        guard let items = try? await client.recentPlaylistItems(
            playlistId: playlist.playlistId,
            pages: filter == nil ? 1 : 2
        ) else {
            playlistError = "\(playlist.title): 재생목록을 불러오지 못했습니다."
            return
        }
        let queue = items.compactMap { item -> PlayableVideo? in
            guard !item.isUnavailable else { return nil }
            if let filter, !item.title.contains(filter) { return nil }
            return PlayableVideo(item: item)
        }
        guard !queue.isEmpty else {
            playlistError = "\(playlist.title): 최근 항목에서 찾지 못했습니다."
            return
        }
        host.play(queue: queue, startIndex: 0)
    }

    /// Latest N for a channel, minus whatever is already a hero card.
    private func videos(for channel: Channel) -> [CachedVideo] {
        let heroIds = Set([pinnedVideo?.videoId, latestSermon?.videoId].compactMap { $0 })
        return allVideos
            .filter { $0.channelId == channel.youtubeChannelId && !heroIds.contains($0.videoId) }
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
                guard !item.isUnavailable else { return nil }
                return PlayableVideo(item: item)
            }
            guard !queue.isEmpty else {
                playlistError = "\(playlist.title): 재생할 수 있는 영상이 없습니다."
                return
            }
            host.play(queue: queue, startIndex: 0)
        } catch {
            playlistError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func play(_ video: CachedVideo, in section: [CachedVideo]) {
        let queue = section.map {
            PlayableVideo(cached: $0)
        }
        let start = queue.firstIndex { $0.id == video.videoId } ?? 0
        host.play(queue: queue, startIndex: start)
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

    private var columns: [GridItem] { FeedGrid.columns }

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

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(videos) { video in
                    Button { onSelect(video) } label: { VideoCard(video: video) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            // Channels like 공동체성경읽기 organise by playlist, so the videos
            // alone are only half the channel. After the grid, not before:
            // the newest episode is what the 말씀 tab is for, and a strip of
            // playlists above it pushed that below the fold.
            if !playlists.isEmpty { playlistBlock }
        }
    }

    /// Three rows, then a way through to the rest.
    ///
    /// A horizontal strip does not survive a channel with eighty playlists —
    /// you cannot tell how many there are, you cannot skim them, and reaching
    /// the far end is a long sideways drag.
    private var playlistBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                ChannelPlaylistsView(channel: channel, playlists: playlists) { playlist in
                    onSelectPlaylist?(playlist)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("재생목록")
                        .font(.footnote.weight(.semibold))
                    Text("\(playlists.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if playlists.count > Self.previewCount {
                        Text("전체 보기").font(.caption2)
                    }
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(Color.primary)
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                ForEach(playlists.prefix(Self.previewCount)) { playlist in
                    Button { onSelectPlaylist?(playlist) } label: {
                        PlaylistBar(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private static let previewCount = 3
}

