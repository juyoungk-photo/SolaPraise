//
//  PlaylistDetailView.swift
//  SolaPraise
//
//  One playlist's contents, read live and edited in place against your real
//  YouTube account.
//
//  Edits are applied optimistically to the local list, then sent. If the API
//  rejects one, the list is reloaded from the server rather than left showing
//  a change that never landed.
//

import SwiftUI

struct PlaylistDetailView: View {
    let playlist: YTPlaylist

    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger

    @State private var items: [YTPlaylistItem] = []
    @State private var durations: [String: Int] = [:]
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var editError: String?
    @State private var playRequest: FeedPlayRequest?

    /// What was just removed, and where it sat, so undo can put it back there.
    private struct Removal { let item: YTPlaylistItem; let position: Int }
    @State private var removed: Removal?
    @State private var isUndoing = false
    @State private var undoTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError, items.isEmpty {
                ErrorState(message: loadError) { Task { await load() } }
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Empty playlist",
                    systemImage: "music.note.list",
                    description: Text("Add songs from the Worship tab.")
                )
            } else {
                list
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !playableVideos.isEmpty {
                    Button {
                        playRequest = FeedPlayRequest(queue: playableVideos, startIndex: 0)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .accessibilityLabel("Play all")
                }
                if let url = YouTubeID.playlistURL(playlist.id) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
                EditButton()
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            WatchScreen(queue: request.queue, startIndex: request.startIndex)
        }
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
    }

    private var list: some View {
        List {
            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        play(from: item)
                    } label: {
                        PlaylistItemRow(
                            index: index + 1,
                            item: item,
                            durationSeconds: item.videoId.flatMap { durations[$0] }
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(item.isUnavailable)
                    // Swipe for the one thing you reach for; long press for
                    // the rest, the way YouTube's ⋮ menu works.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await remove(item, at: index) }
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        if !item.isUnavailable {
                            Button {
                                play(from: item)
                            } label: { Label("재생", systemImage: "play.fill") }
                        }
                        if index > 0 {
                            Button {
                                Task { await move(from: IndexSet(integer: index), to: 0) }
                            } label: { Label("맨 위로", systemImage: "arrow.up.to.line") }
                        }
                        if index < items.count - 1 {
                            Button {
                                Task {
                                    await move(from: IndexSet(integer: index),
                                               to: items.count)
                                }
                            } label: { Label("맨 아래로", systemImage: "arrow.down.to.line") }
                        }
                        if let videoId = item.videoId,
                           let url = YouTubeID.watchURL(videoId) {
                            ShareLink(item: url) {
                                Label("공유", systemImage: "square.and.arrow.up")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            Task { await remove(item, at: index) }
                        } label: { Label("재생목록에서 삭제", systemImage: "trash") }
                    }
                }
                .onMove { offsets, destination in
                    Task { await move(from: offsets, to: destination) }
                }
                .onDelete { offsets in
                    guard let index = offsets.first else { return }
                    let item = items[index]
                    Task { await remove(item, at: index) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("^[\(items.count) video](inflect: true) · \(playlist.privacy.label)")
                    if let editError {
                        Text(editError).foregroundStyle(.red)
                    } else {
                        Text("각 순서 변경과 삭제는 50 units입니다. 오늘 \(quota.unitsRemaining.formatted()) 남음.")
                    }
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) { undoBar }
    }

    /// A removal writes to the real YouTube account, so it gets a way back.
    ///
    /// Restoring appends by default, which is not undoing anything — the
    /// original position is sent with the insert, so the song returns where it
    /// was, for the same single write.
    @ViewBuilder
    private var undoBar: some View {
        if let removed {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("삭제됨 · \(removed.item.title)")
                    .font(.footnote)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("되돌리기") { Task { await undoRemoval() } }
                    .font(.footnote.weight(.semibold))
                    .disabled(isUndoing)
                if isUndoing { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .overlay(alignment: .top) { Divider() }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Playback

    private var playableVideos: [PlayableVideo] {
        items.compactMap { item in
            guard !item.isUnavailable, let id = item.videoId else { return nil }
            return PlayableVideo(
                id: id,
                title: item.title,
                channelTitle: item.channelTitle,
                durationSeconds: durations[id],
                publishedAt: item.contentDetails?.videoPublishedAt
            )
        }
    }

    private func play(from item: YTPlaylistItem) {
        guard let id = item.videoId else { return }
        let queue = playableVideos
        let start = queue.firstIndex { $0.id == id } ?? 0
        playRequest = FeedPlayRequest(queue: queue, startIndex: start)
    }

    // MARK: - Editing

    /// Only the moved item is sent — YouTube shifts the rest itself, so this
    /// costs one 50-unit write regardless of playlist length.
    private func move(from offsets: IndexSet, to destination: Int) async {
        guard let source = offsets.first else { return }
        var reordered = items
        reordered.move(fromOffsets: offsets, toOffset: destination)
        let newIndex = destination > source ? destination - 1 : destination
        guard reordered.indices.contains(newIndex) else { return }

        let moved = reordered[newIndex]
        guard let videoId = moved.videoId else { return }

        items = reordered
        editError = nil

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            _ = try await client.movePlaylistItem(
                itemId: moved.id,
                playlistId: playlist.id,
                videoId: videoId,
                to: newIndex
            )
        } catch {
            editError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await load()   // server is the truth; don't keep a phantom order
        }
    }

    private func remove(_ item: YTPlaylistItem, at index: Int) async {
        guard let position = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: position)
        editError = nil
        undoTask?.cancel()

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            try await client.removePlaylistItem(itemId: item.id)
        } catch {
            editError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await load()   // server is the truth
            return
        }

        withAnimation { removed = Removal(item: item, position: position) }
        // Long enough to notice and act on, short enough not to become part
        // of the furniture.
        undoTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation { removed = nil }
        }
    }

    private func undoRemoval() async {
        guard let removal = removed, let videoId = removal.item.videoId else { return }
        isUndoing = true
        defer { isUndoing = false }
        undoTask?.cancel()

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            _ = try await client.addVideo(videoId, to: playlist.id, at: removal.position)
            withAnimation { removed = nil }
            await load()
        } catch {
            editError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            items = try await client.playlistItems(playlistId: playlist.id)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        // Durations are a separate 1-unit-per-50 call; failure is cosmetic and
        // must never surface as a load error.
        let ids = items.compactMap(\.videoId)
        guard !ids.isEmpty, let videos = try? await client.videos(ids: ids) else { return }
        var map: [String: Int] = [:]
        for v in videos { if let s = v.durationSeconds { map[v.id] = s } }
        durations = map
    }
}

// MARK: - Row

private struct PlaylistItemRow: View {
    let index: Int
    let item: YTPlaylistItem
    let durationSeconds: Int?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)

            Thumbnail(url: item.thumbnailURL, width: 72, height: 41)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(item.isUnavailable ? .secondary : .primary)

                HStack(spacing: 6) {
                    if let channel = item.channelTitle {
                        Text(channel).lineLimit(1)
                    }
                    if let durationSeconds {
                        Text("·")
                        Text(ISO8601Duration.format(durationSeconds)).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
