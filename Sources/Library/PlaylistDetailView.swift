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
                }
                .onMove { offsets, destination in
                    Task { await move(from: offsets, to: destination) }
                }
                .onDelete { offsets in
                    Task { await remove(at: offsets) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("^[\(items.count) video](inflect: true) · \(playlist.privacy.label)")
                    if let editError {
                        Text(editError).foregroundStyle(.red)
                    } else {
                        Text("Each reorder or removal costs 50 units. \(quota.unitsRemaining.formatted()) left today.")
                    }
                }
            }
        }
        .listStyle(.plain)
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

    private func remove(at offsets: IndexSet) async {
        let doomed = offsets.map { items[$0] }
        items.remove(atOffsets: offsets)
        editError = nil

        let client = AppServices.client(auth: auth, quota: quota)
        for item in doomed {
            do {
                try await client.removePlaylistItem(itemId: item.id)
            } catch {
                editError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await load()
                return
            }
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
