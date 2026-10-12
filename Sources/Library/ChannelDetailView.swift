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

    @EnvironmentObject private var host: PlayerHost
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @StateObject private var feed = FeedStore()

    @Query(sort: [SortDescriptor(\CachedVideo.publishedAt, order: .reverse)])
    private var allVideos: [CachedVideo]

    @Query private var allPlaylists: [CachedPlaylist]
    @State private var isLoadingPlaylist = false
    @State private var errorMessage: String?

    private var videos: [CachedVideo] {
        allVideos.filter { $0.channelId == channel.youtubeChannelId }
    }
    private var playlists: [CachedPlaylist] {
        allPlaylists.filter { $0.channelId == channel.youtubeChannelId }
    }

    private var columns: [GridItem] { FeedGrid.columns }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Playlists first: a channel like this one keeps its
                // services as playlists, and its recent uploads come second.
                if !playlists.isEmpty { playlistSection }

                if videos.isEmpty && playlists.isEmpty {
                    ContentUnavailableView(
                        "볼 수 있는 영상이 없습니다",
                        systemImage: "play.slash",
                        description: Text(emptyExplanation)
                    )
                    .padding(.top, 40)
                } else if !videos.isEmpty {
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
        .refreshable { await refresh() }
        .task { if videos.isEmpty { await refresh() } }
    }

    /// Why a channel shows nothing — usually that it has nothing public.
    /// A church channel posts its services 일부 공개 (unlisted), and YouTube
    /// lists those only to an account that manages the channel; everyone
    /// else sees an empty channel. A playlist of them, shared by link, is
    /// what anyone can watch without signing in.
    private var emptyExplanation: String {
        "이 채널에는 공개된 영상이 없습니다. '일부 공개' 영상은 채널을 관리하는 계정으로 로그인했을 때만 보입니다. "
            + "팀원 모두가 로그인 없이 보려면, 그 영상들을 담은 재생목록(일부 공개)의 링크를 「보관함 > 관심 채널 > 추가」에서 재생목록으로 추가하세요."
    }

    // MARK: - Playlists

    /// Cards with artwork, then a way through to all of them.
    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                ChannelPlaylistsView(
                    channel: channel,
                    playlists: playlists,
                    onSelect: { playlist in Task { await play(playlist) } },
                    onPinChanged: { try? modelContext.save() }
                )
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

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(shownPlaylists.prefix(Self.playlistPreviewCount)) { playlist in
                    Button { Task { await play(playlist) } } label: {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        PlaylistPinButton(playlist: playlist, purpose: channel.purpose) {
                            try? modelContext.save()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Pinned first, then the newest.
    private var shownPlaylists: [CachedPlaylist] {
        playlists.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast)
        }
    }

    /// As many as fill two rows of the grid.
    private static let playlistPreviewCount = 6

    // MARK: - Actions

    private func play(_ video: CachedVideo) {
        let queue = videos.prefix(30).map {
            PlayableVideo(cached: $0)
        }
        let start = queue.firstIndex { $0.id == video.videoId } ?? 0
        host.play(queue: Array(queue), startIndex: start)
    }

    private func play(_ playlist: CachedPlaylist) async {
        guard auth.canReadYouTube else {
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
            host.play(queue: queue, startIndex: 0)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func refresh() async {
        let client = auth.canReadYouTube ? AppServices.client(auth: auth, quota: quota) : nil
        await feed.refresh(purpose: channel.purpose, context: modelContext, client: client)
    }
}

// MARK: - Playlist bar

/// The preview form: one full-width line, no artwork.
///
/// A playlist's thumbnail is the first video's frame, which for a 말씀 channel
/// is a title card that looks like every other title card on that channel. It
/// took a third of the width to say nothing, and squeezed the one thing that
/// does identify a playlist — its name — into two cramped lines. A wide bar
/// gives the name the room instead.
struct PlaylistBar: View {
    let playlist: CachedPlaylist

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: playlist.isCollaborative
                  ? "person.2.fill"
                  : (playlist.isPinned ? "pin.fill" : "list.bullet.rectangle.portrait"))
                .font(.caption)
                .foregroundStyle(.tint)

            Text(playlist.title)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(Color.primary)

            // YouTube generates one of these per channel and fills it with
            // every stream the channel has ever run, so what is in it is the
            // service as it happened rather than anything anyone curated.
            // Worth saying, because "주일 2부예배" reads like a set list.
            if playlist.isLiveArchive {
                badge("실황", .red)
            } else if playlist.isAutoCollected {
                // Not the church's playlist: the app's filter over that
                // channel's uploads. The channel has no standing 주일 설교
                // list, so this is assembled rather than published.
                badge("자동 모음", .secondary)
            }

            Spacer(minLength: 8)

            // Zero means "not fetched yet", not "empty" — a pinned link
            // starts that way — so it shows nothing rather than a 0 that
            // reads as an empty playlist.
            if playlist.itemCount > 0 {
                Text("\(playlist.itemCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "play.circle.fill")
                .font(.body)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - Playlist row

/// The full-list form, where artwork earns its place: you are scanning dozens
/// and a frame is another way to recognise one. Named for the channel page
/// because 보관함 has its own row for YTPlaylist.
struct ChannelPlaylistRow: View {
    let playlist: CachedPlaylist

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: playlist.thumbnailURL, width: 72, height: 41)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if playlist.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                    Text(playlist.title)
                        .font(.footnote)
                        .lineLimit(2)
                        .foregroundStyle(Color.primary)
                }
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
    var onPinChanged: (() -> Void)? = nil

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
                    HStack(spacing: 10) {
                        Button { onSelect(playlist) } label: { ChannelPlaylistRow(playlist: playlist) }
                            .buttonStyle(.plain)
                        // In plain sight: a pin hidden in a long-press menu
                        // was a feature nobody found.
                        Button {
                            togglePin(playlist)
                        } label: {
                            Image(systemName: playlist.isPinned ? "pin.fill" : "pin")
                                .font(.body)
                                .foregroundStyle(playlist.isPinned ? Color.accentColor : Color.secondary)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playlist.isPinned ? "고정 해제" : "고정")
                    }
                    .swipeActions(edge: .trailing) {
                        Button { togglePin(playlist) } label: {
                            Label(playlist.isPinned ? "고정 해제" : "고정",
                                  systemImage: playlist.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(playlist.isPinned ? .gray : .accentColor)
                    }
                }
            } footer: {
                if shown.isEmpty {
                    Text("검색과 일치하는 재생목록이 없습니다.")
                } else {
                    Text("고정한 재생목록만 \(channel.purpose.title) 탭의 이 채널 아래에 보입니다. · ^[\(shown.count) playlist](inflect: true)")
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

    private func togglePin(_ playlist: CachedPlaylist) {
        playlist.isPinned.toggle()
        // As PlaylistPinButton: unpinned is shown nowhere.
        playlist.purposeRaw = playlist.isPinned ? channel.purpose.rawValue : nil
        onPinChanged?()
    }
}

// MARK: - Playlist card

/// A playlist as a card, the size of a video card: artwork, title, count.
/// On a channel page the artwork is what tells one series from another.
struct PlaylistCard: View {
    let playlist: CachedPlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Color(.secondarySystemBackground)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let url = playlist.thumbnailURL {
                            AsyncImage(url: url) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: { Color.clear }
                        } else {
                            Image(systemName: "list.bullet.rectangle.portrait")
                                .font(.title2).foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet").font(.caption2)
                    if playlist.itemCount > 0 { Text("\(playlist.itemCount)") }
                }
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
            }
            HStack(spacing: 4) {
                if playlist.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint)
                }
                Text(playlist.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(Color.primary)
            }
        }
        .contentShape(Rectangle())
    }
}
