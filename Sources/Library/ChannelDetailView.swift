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
                if !playlists.isEmpty {
                    Text("재생목록")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(playlists) { playlist in
                                Button {
                                    Task { await play(playlist) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(playlist.title)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(2)
                                            .foregroundStyle(Color.primary)
                                        Text("^[\(playlist.itemCount) video](inflect: true)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 150, alignment: .leading)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color(.secondarySystemBackground))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

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

    // MARK: - Actions

    private func play(_ video: CachedVideo) {
        let queue = videos.prefix(30).map {
            PlayableVideo(id: $0.videoId, title: $0.title,
                          channelTitle: $0.channelTitle,
                          durationSeconds: $0.durationSeconds)
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
                guard !item.isUnavailable, let id = item.videoId else { return nil }
                return PlayableVideo(id: id, title: item.title, channelTitle: item.channelTitle)
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
