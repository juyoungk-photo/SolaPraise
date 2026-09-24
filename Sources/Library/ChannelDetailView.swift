//
//  ChannelDetailView.swift
//  SolaPraise
//
//  One channel's own page: its playlists and its recent videos.
//
//  Used from 보관함, where channels that are neither 말씀 nor 찬양 live —
//  교제 content like 코너스톤TV that is worth keeping but should not clutter
//  the two purpose feeds.
//

import SwiftUI
import SwiftData

struct ChannelDetailView: View {
    let channel: Channel

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @StateObject private var feed = FeedStore()

    @Query(sort: [SortDescriptor(\CachedVideo.publishedAt, order: .reverse)])
    private var allVideos: [CachedVideo]

    @Query private var allPlaylists: [CachedPlaylist]

    @State private var playRequest: FeedPlayRequest?
    @State private var isLoadingPlaylist = false
    @State private var errorMessage: String?

    private var videos: [CachedVideo] {
        allVideos.filter { $0.channelId == channel.youtubeChannelId }
    }
    private var playlists: [CachedPlaylist] {
        allPlaylists.filter { $0.channelId == channel.youtubeChannelId }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if videos.isEmpty {
                    ContentUnavailableView(
                        "영상이 아직 없습니다",
                        systemImage: "play.slash",
                        description: Text("아래로 당겨 새로고침하세요.")
                    )
                    .padding(.top, 40)
                } else {
                    Text("최근 영상")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(videos.prefix(30)) { video in
                            Button { play(video) } label: { VideoCard(video: video) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if !playlists.isEmpty { playlistSection }

                if isLoadingPlaylist {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("불러오는 중…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }

                FeedEndMarker(refreshedAt: feed.lastRefreshedAt)
            }
            .padding(.top, 12)
        }
        .navigationTitle(channel.shortTitle)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playRequest) { request in
            WatchScreen(queue: request.queue, startIndex: request.startIndex)
        }
        .refreshable { await refresh() }
        .task { if videos.isEmpty { await refresh() } }
    }

    // MARK: - Playlists

    /// Three rows and a way through to the rest.
    ///
    /// These were a horizontal strip, which does not survive a channel with
    /// eighty playlists: you cannot see how many there are, you cannot skim
    /// them, and reaching the far end is a long sideways drag. Rows read at a
    /// glance and the full list scrolls the way lists do.
    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                ChannelPlaylistsView(channel: channel, playlists: playlists) { playlist in
                    Task { await play(playlist) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("재생목록")
                        .font(.subheadline.weight(.semibold))
                    Text("\(playlists.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if playlists.count > Self.playlistPreviewCount {
                        Text("전체 보기").font(.caption)
                    }
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                ForEach(playlists.prefix(Self.playlistPreviewCount)) { playlist in
                    Button { Task { await play(playlist) } } label: {
                        ChannelPlaylistRow(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private static let playlistPreviewCount = 3

    // MARK: - Actions

    private func play(_ video: CachedVideo) {
        let queue = videos.prefix(30).map {
            PlayableVideo(cached: $0)
        }
        let start = queue.firstIndex { $0.id == video.videoId } ?? 0
        playRequest = FeedPlayRequest(queue: Array(queue), startIndex: start)
    }

    private func play(_ playlist: CachedPlaylist) async {
        guard auth.isSignedIn else {
            errorMessage = "재생목록을 열려면 Google 로그인이 필요합니다."
            return
        }
        isLoadingPlaylist = true
        errorMessage = nil
        defer { isLoadingPlaylist = false }

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            let items = try await client.playlistItems(playlistId: playlist.playlistId)
            let queue = items.compactMap { item -> PlayableVideo? in
                guard !item.isUnavailable else { return nil }
                return PlayableVideo(item: item)
            }
            guard !queue.isEmpty else {
                errorMessage = "재생할 수 있는 영상이 없습니다."
                return
            }
            playRequest = FeedPlayRequest(queue: queue, startIndex: 0)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func refresh() async {
        let client = auth.isSignedIn ? AppServices.client(auth: auth, quota: quota) : nil
        await feed.refresh(purpose: channel.purpose, context: modelContext, client: client)
    }
}

// MARK: - Playlist row

/// Shared by the three-row preview and the full list, so they cannot drift.
/// Named for the channel page because 보관함 has its own row for YTPlaylist.
struct ChannelPlaylistRow: View {
    let playlist: CachedPlaylist

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: playlist.thumbnailURL, width: 72, height: 41)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.footnote)
                    .lineLimit(2)
                    .foregroundStyle(Color.primary)
                Text("^[\(playlist.itemCount) video](inflect: true)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

// MARK: - All playlists

/// Every playlist on one channel. A list, not a sideways strip: some church
/// channels run to dozens, and the only way to find one among them is to
/// scroll the way lists scroll and to search.
struct ChannelPlaylistsView: View {
    let channel: Channel
    let playlists: [CachedPlaylist]
    let onSelect: (CachedPlaylist) -> Void

    @State private var searchText = ""

    private var shown: [CachedPlaylist] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return playlists }
        return playlists.filter { $0.title.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            Section {
                ForEach(shown) { playlist in
                    Button { onSelect(playlist) } label: { ChannelPlaylistRow(playlist: playlist) }
                        .buttonStyle(.plain)
                }
            } footer: {
                if shown.isEmpty {
                    Text("검색과 일치하는 재생목록이 없습니다.")
                } else {
                    Text("^[\(shown.count) playlist](inflect: true)")
                }
            }
        }
        .listStyle(.plain)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "재생목록 검색"
        )
        .navigationTitle(channel.shortTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
