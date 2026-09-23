//
//  HomeSearchSheet.swift
//  SolaPraise
//
//  Search from the home screen without leaving it. The field takes focus the
//  moment the sheet opens, so tapping 검색 means you are already typing.
//
//  Same two-tier model as the Worship tab, and for the same reason: typing
//  filters what is already cached (free, instant), while searching all of
//  YouTube is a separate, visibly-priced tap.
//

import SwiftUI
import SwiftData

struct HomeSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger

    @Query(sort: [SortDescriptor(\CachedVideo.publishedAt, order: .reverse)])
    private var allVideos: [CachedVideo]

    @State private var text = ""
    @State private var remoteResults: [YTSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var playRequest: FeedPlayRequest?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                results
            }
            .navigationTitle("검색")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .fullScreenCover(item: $playRequest) { request in
                WatchScreen(queue: request.queue, startIndex: request.startIndex)
            }
            // A brief hop gives the sheet time to present before the keyboard
            // is requested; focusing synchronously is unreliable here.
            .task {
                try? await Task.sleep(for: .milliseconds(350))
                fieldFocused = true
            }
        }
    }

    // MARK: - Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("찬양·말씀 검색", text: $text)
                .focused($fieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { Task { await runRemoteSearch() } }
            if !text.isEmpty {
                Button {
                    text = ""; remoteResults = []; errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        List {
            if !localMatches.isEmpty {
                Section("내 채널·주제  ·  무료") {
                    ForEach(localMatches) { video in
                        Button { play(video) } label: { row(
                            title: video.title,
                            channel: video.channelTitle,
                            thumb: video.thumbnailURL
                        ) }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    Button {
                        Task { await runRemoteSearch() }
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("YouTube 전체 검색")
                            Spacer()
                            if isSearching {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("\(quota.searchesRemaining)회 남음")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isSearching || !quota.canSearch)

                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("전체 검색은 100 units를 사용합니다.")
                }
            }

            if !remoteResults.isEmpty {
                Section("YouTube") {
                    ForEach(remoteResults) { result in
                        Button { play(result) } label: { row(
                            title: result.title,
                            channel: result.snippet?.channelTitle,
                            thumb: result.snippet?.thumbnails?.best
                        ) }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(title: String, channel: String?, thumb: URL?) -> some View {
        HStack(spacing: 10) {
            Thumbnail(url: thumb, width: 80, height: 45)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote).lineLimit(2).foregroundStyle(.primary)
                if let channel {
                    Text(channel).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Data

    private var localMatches: [CachedVideo] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return allVideos
            .filter { $0.title.lowercased().contains(needle) }
            .prefix(15)
            .map { $0 }
    }

    private func play(_ video: CachedVideo) {
        playRequest = FeedPlayRequest(
            queue: [PlayableVideo(id: video.videoId, title: video.title,
                                  channelTitle: video.channelTitle,
                                  durationSeconds: video.durationSeconds)],
            startIndex: 0
        )
    }

    private func play(_ result: YTSearchResult) {
        guard let id = result.videoId else { return }
        playRequest = FeedPlayRequest(
            queue: [PlayableVideo(id: id, title: result.title,
                                  channelTitle: result.snippet?.channelTitle)],
            startIndex: 0
        )
    }

    private func runRemoteSearch() async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard auth.isSignedIn else {
            errorMessage = "YouTube 전체 검색은 Google 로그인이 필요합니다."
            return
        }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let client = AppServices.client(auth: auth, quota: quota)
        do { remoteResults = try await client.search(query: query) }
        catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
