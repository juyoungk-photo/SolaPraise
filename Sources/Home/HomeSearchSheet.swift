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
    @EnvironmentObject private var host: PlayerHost
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger

    @Query(sort: [SortDescriptor(\CachedVideo.publishedAt, order: .reverse)])
    private var allVideos: [CachedVideo]

    /// Set when a 주제 card opens this sheet. The term is filled in and the
    /// cached matches show at once, but the 100-unit search stays a tap away.
    var initialQuery: String = ""

    @State private var text = ""
    @State private var remoteResults: [YTSearchResult] = []
    @State private var nextPageToken: String?
    /// The query the current results belong to, so "more" asks for more of
    /// the same rather than more of whatever is in the box now.
    @State private var searchedQuery = ""
    @State private var isSearching = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool
    @StateObject private var history = SearchHistory.shared("home")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                if text.isEmpty {
                    SearchHistoryChips(history: history) { query in
                        text = query
                        Task { await runRemoteSearch() }
                    }
                }
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
            // A brief hop gives the sheet time to present before the keyboard
            // is requested; focusing synchronously is unreliable here.
            .task {
                if text.isEmpty { text = initialQuery }
                try? await Task.sleep(for: .milliseconds(350))
                // A pre-filled term is already the query, so do not raise the
                // keyboard over the results the user came to see.
                fieldFocused = initialQuery.isEmpty
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
                    nextPageToken = nil; searchedQuery = ""
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
                            thumb: video.thumbnailURL,
                            published: video.publishedAt,
                            duration: video.durationSeconds
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
                            thumb: result.snippet?.thumbnails?.best,
                            published: result.snippet?.publishedAt,
                            duration: nil
                        ) }
                        .buttonStyle(.plain)
                    }

                    // Asked for, not prefetched: another page is another
                    // full search out of a hundred a day, so the cost is on
                    // the button rather than spent on scrolling.
                    if nextPageToken != nil {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            HStack(spacing: 8) {
                                if isSearching {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                }
                                Text("더 보기")
                                Spacer()
                                Text("검색 1회")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.footnote)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSearching || !quota.canSearch)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(title: String, channel: String?, thumb: URL?,
                     published: Date? = nil, duration: Int? = nil) -> some View {
        HStack(spacing: 10) {
            Thumbnail(url: thumb, width: 80, height: 45)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote).lineLimit(2).foregroundStyle(.primary)
                if let channel {
                    Text(channel).font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    if let published {
                        Text(published, format: .dateTime.year().month())
                    }
                    if let duration {
                        Text("·")
                        Text(ISO8601Duration.format(duration)).monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
        host.play(queue: [PlayableVideo(cached: video)], startIndex: 0)
    }

    private func play(_ result: YTSearchResult) {
        guard let id = result.videoId else { return }
        host.play(queue: [PlayableVideo(id: id, title: result.title,
                                  channelTitle: result.snippet?.channelTitle,
                                  publishedAt: result.snippet?.publishedAt)], startIndex: 0)
    }

    private func runRemoteSearch() async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard auth.canReadYouTube else {
            errorMessage = "YouTube 전체 검색은 Google 로그인이 필요합니다."
            return
        }
        history.record(query)
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            let page = try await client.searchPage(query: query)
            remoteResults = page.items
            nextPageToken = page.nextPageToken
            searchedQuery = query
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The next page, on request.
    ///
    /// Appended rather than replacing, because the thing you were looking at
    /// should not move when you ask for more.
    private func loadMore() async {
        guard let token = nextPageToken, !searchedQuery.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        let client = AppServices.client(auth: auth, quota: quota)
        do {
            let page = try await client.searchPage(query: searchedQuery, pageToken: token)
            let known = Set(remoteResults.compactMap(\.videoId))
            remoteResults += page.items.filter { $0.videoId.map { !known.contains($0) } ?? false }
            nextPageToken = page.nextPageToken
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
