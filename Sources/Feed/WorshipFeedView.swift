//
//  WorshipFeedView.swift
//  SolaPraise
//
//  Purpose 1: worship music — scoped feed, budgeted search, curation.
//
//  Two search modes, deliberately unequal:
//    • Typing filters what is already cached — free, instant, no network.
//    • "Search all of YouTube" is an explicit second tap costing 100 units,
//      with the remaining budget shown on the button itself. Feeling that
//      cost is the point; it is what stops idle searching.
//

import SwiftUI
import SwiftData

struct WorshipFeedView: View {

    private static var perSectionCap: Int {
        #if DEBUG
        if let override = DebugHarness.perChannelCap { return override }
        #endif
        return 6
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @StateObject private var feed = FeedStore()

    @Query(sort: [SortDescriptor(\Channel.sortOrder), SortDescriptor(\Channel.addedAt)])
    private var allChannels: [Channel]

    @Query(sort: [SortDescriptor(\TopicSearch.sortOrder), SortDescriptor(\TopicSearch.createdAt)])
    private var topics: [TopicSearch]

    @Query(sort: [SortDescriptor(\CachedVideo.publishedAt, order: .reverse)])
    private var allVideos: [CachedVideo]

    @State private var searchText = ""
    @StateObject private var history = SearchHistory.shared("worship")
    @State private var remoteResults: [YTSearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var showSettings = false
    @State private var showAddTopic = false
    @State private var playRequest: FeedPlayRequest?
    @State private var addTarget: PlayableVideo?
    @State private var genre: WorshipGenre = .all
    /// videoId → (duration, views), filled by one videos.list after a search.
    @State private var resultDetail: [String: (Int?, Int?)] = [:]

    private var channels: [Channel] {
        allChannels.filter { $0.purposeRaw == Purpose.worship.rawValue }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("찬양")
            .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                // .navigationBarDrawer(.always) keeps the field pinned; the
                // default placement lets it scroll away, so it vanished as
                // soon as you moved down to a channel.
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "찬양·곡 검색"
                )
                .searchSuggestions {
                    ForEach(history.entries, id: \.self) { query in
                        Label(query, systemImage: "clock.arrow.circlepath")
                            .searchCompletion(query)
                    }
                }
                .onSubmit(of: .search) { Task { await runRemoteSearch() } }
                .onChange(of: searchText) { _, newValue in
                    if newValue.isEmpty { remoteResults = []; searchError = nil }
                }
                .sheet(isPresented: $showSettings) { SettingsView() }
                .sheet(isPresented: $showAddTopic) { AddTopicSheet() }
                .sheet(item: $addTarget) { AddToPlaylistSheet(video: $0) }
                .fullScreenCover(item: $playRequest) { request in
                    WatchScreen(queue: request.queue, startIndex: request.startIndex)
                }
                .refreshable { await refresh() }
                .task { await refreshIfNeeded() }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .topBarLeading) {
            // Compact + fixedSize: the full "100/100" form gets truncated to
            // "100/…" beside a large navigation title.
            Label("\(quota.searchesRemaining)", systemImage: "magnifyingglass")
                // Toolbars default Labels to icon-only, which hides the count.
                .labelStyle(.titleAndIcon)
                .font(.caption.monospacedDigit())
                .foregroundStyle(quota.canSearch ? Color.secondary : Color.orange)
                .fixedSize()
                .accessibilityLabel("\(quota.searchesRemaining) of \(QuotaLedger.dailySearchLimit) searches left today")
        }
    }

    @ViewBuilder
    private var content: some View {
        if searchText.isEmpty {
            browseScroll
        } else {
            searchScroll
        }
    }

    // MARK: - Browse

    private var browseScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    genreChips
                    topicChips

                if channels.isEmpty && topics.isEmpty {
                    emptyGuidance
                }

                    ForEach(channels) { channel in
                        let videos = cappedVideos(forChannel: channel)
                        if !videos.isEmpty {
                            ChannelSection(channel: channel, videos: videos) { video in
                                play(video, in: videos)
                            }
                            .id(channel.youtubeChannelId)
                        }
                    }

                ForEach(topics) { topic in
                    let videos = cappedVideos(forTopic: topic)
                    if !videos.isEmpty {
                        TopicSection(topic: topic, videos: videos) { video in
                            play(video, in: videos)
                        }
                    }
                }

                if let message = feed.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }

                    if !(channels.isEmpty && topics.isEmpty) {
                        FeedEndMarker(refreshedAt: feed.lastRefreshedAt)
                    }
                }
                .padding(.top, 8)
            }
            .safeAreaInset(edge: .top) {
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

    /// Genre filters over the cache — free and instant, unlike a search.
    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WorshipGenre.allCases) { option in
                    Text(option.title)
                        .font(.caption.weight(genre == option ? .semibold : .medium))
                        .foregroundStyle(genre == option ? Color.white : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(genre == option
                                           ? Color.accentColor
                                           : Color(.secondarySystemBackground))
                        )
                        .contentShape(Capsule())
                        .onTapGesture { genre = option }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var topicChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(topics) { topic in
                    Text(topic.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.quaternary, in: Capsule())
                }
                Button { showAddTopic = true } label: {
                    Label("Topic", systemImage: "plus")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
    }

    private var emptyGuidance: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "music.note")
        } description: {
            Text("Add worship channels in Settings, or save a topic like 찬양 피아노 — its results refresh once a day.")
        } actions: {
            Button("Add a topic") { showAddTopic = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }

    // MARK: - Search

    private var searchScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                let local = localMatches
                if !local.isEmpty {
                    ResultSection(title: "In your channels & topics", subtitle: "free", videos: local) { video in
                        play(video, in: local)
                    } onAdd: { video in
                        addTarget = playable(video)
                    }
                }

                remoteSection

                if local.isEmpty && remoteResults.isEmpty && !isSearching {
                    Text("Nothing cached matches “\(searchText)”. Search all of YouTube to look wider.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await runRemoteSearch() }
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Search all of YouTube")
                    Spacer()
                    Text("\(quota.searchesRemaining) of \(QuotaLedger.dailySearchLimit) left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .disabled(isSearching || !quota.canSearch)
            .padding(.horizontal, 16)

            if isSearching {
                ProgressView().padding(.horizontal, 16)
            }
            if let searchError {
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }
            if !remoteResults.isEmpty {
                RemoteResultSection(results: remoteResults, detail: resultDetail) { result in
                    guard let id = result.videoId else { return }
                    let info = resultDetail[id]
                    playRequest = FeedPlayRequest(
                        queue: [PlayableVideo(
                            id: id, title: result.title,
                            channelTitle: result.snippet?.channelTitle,
                            durationSeconds: info?.0,
                            publishedAt: result.snippet?.publishedAt,
                            viewCount: info?.1
                        )],
                        startIndex: 0
                    )
                } onAdd: { result in
                    guard let id = result.videoId else { return }
                    let info = resultDetail[id]
                    addTarget = PlayableVideo(
                        id: id, title: result.title,
                        channelTitle: result.snippet?.channelTitle,
                        durationSeconds: info?.0,
                        publishedAt: result.snippet?.publishedAt,
                        viewCount: info?.1
                    )
                }
            }
        }
    }

    // MARK: - Derived

    private var worshipChannelIds: Set<String> {
        Set(channels.map(\.youtubeChannelId))
    }

    /// Cached videos relevant to this tab: worship channels plus topic results.
    private var worshipVideos: [CachedVideo] {
        let ids = worshipChannelIds
        return allVideos.filter { video in
            video.sourceRaw == CachedVideo.Source.topicSearch.rawValue
                || (video.channelId.map { ids.contains($0) } ?? false)
        }
    }

    private var localMatches: [CachedVideo] {
        let needle = searchText.lowercased()
        return worshipVideos
            .filter { $0.title.lowercased().contains(needle) }
            .prefix(20)
            .map { $0 }
    }

    private func cappedVideos(forChannel channel: Channel) -> [CachedVideo] {
        allVideos
            .filter { $0.channelId == channel.youtubeChannelId }
            .filter { genre.matches($0.title) }
            .prefix(Self.perSectionCap)
            .map { $0 }
    }

    private func cappedVideos(forTopic topic: TopicSearch) -> [CachedVideo] {
        let needle = topic.query.lowercased()
        return allVideos
            .filter { $0.sourceRaw == CachedVideo.Source.topicSearch.rawValue }
            .filter { $0.title.lowercased().contains(needle) || needle.isEmpty }
            .prefix(Self.perSectionCap)
            .map { $0 }
    }

    // MARK: - Actions

    private func playable(_ video: CachedVideo) -> PlayableVideo {
        PlayableVideo(cached: video)
    }

    private func play(_ video: CachedVideo, in section: [CachedVideo]) {
        let queue = section.map(playable)
        let start = queue.firstIndex { $0.id == video.videoId } ?? 0
        playRequest = FeedPlayRequest(queue: queue, startIndex: start)
    }

    private func runRemoteSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, auth.isSignedIn else {
            searchError = auth.isSignedIn ? nil : "Sign in to search all of YouTube."
            return
        }
        isSearching = true
        searchError = nil
        defer { isSearching = false }

        history.record(query)

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            remoteResults = try await client.search(query: query)
            // One extra unit buys duration and view count for every hit —
            // without them you cannot tell a studio cut from a live set.
            let ids = remoteResults.compactMap(\.videoId)
            if !ids.isEmpty, let videos = try? await client.videos(ids: ids) {
                var map: [String: (Int?, Int?)] = [:]
                for v in videos { map[v.id] = (v.durationSeconds, v.viewCount) }
                resultDetail = map
            }
        } catch {
            searchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func refreshIfNeeded() async {
        guard !channels.isEmpty || !topics.isEmpty else { return }
        await refresh()
    }

    private func refresh() async {
        let client = auth.isSignedIn ? AppServices.client(auth: auth, quota: quota) : nil
        await feed.refresh(purpose: .worship, context: modelContext, client: client)
        await feed.refreshTopics(context: modelContext, client: client)
    }
}

// MARK: - Sections

private struct TopicSection: View {
    let topic: TopicSearch
    let videos: [CachedVideo]
    let onSelect: (CachedVideo) -> Void

    private var columns: [GridItem] { FeedGrid.columns }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("From “\(topic.label)”")
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
        }
    }
}

private struct ResultSection: View {
    let title: String
    let subtitle: String
    let videos: [CachedVideo]
    let onSelect: (CachedVideo) -> Void
    let onAdd: (CachedVideo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 16)

            ForEach(videos) { video in
                HStack(spacing: 10) {
                    Button { onSelect(video) } label: {
                        HStack(spacing: 10) {
                            Thumbnail(url: video.thumbnailURL, width: 88, height: 50)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(video.title).font(.footnote).lineLimit(2)
                                if let channel = video.channelTitle {
                                    Text(channel).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { onAdd(video) } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct RemoteResultSection: View {
    let results: [YTSearchResult]
    let detail: [String: (Int?, Int?)]
    let onSelect: (YTSearchResult) -> Void
    let onAdd: (YTSearchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From YouTube")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)

            ForEach(results) { result in
                HStack(spacing: 10) {
                    Button { onSelect(result) } label: {
                        HStack(spacing: 10) {
                            Thumbnail(url: result.snippet?.thumbnails?.best, width: 88, height: 50)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).font(.footnote).lineLimit(2)
                                if let channel = result.snippet?.channelTitle {
                                    Text(channel).font(.caption2).foregroundStyle(.secondary)
                                }
                                // Publish date, length and views — the three
                                // things that separate one upload of a song
                                // from another.
                                HStack(spacing: 5) {
                                    if let published = result.snippet?.publishedAt {
                                        Text(published, format: .dateTime.year().month())
                                    }
                                    let info = result.videoId.flatMap { detail[$0] }
                                    if let secs = info?.0 {
                                        Text("·")
                                        Text(ISO8601Duration.format(secs)).monospacedDigit()
                                    }
                                    if let views = info?.1 {
                                        Text("·")
                                        Text(WatchScreen.compactCount(views)).monospacedDigit()
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { onAdd(result) } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Add topic

struct AddTopicSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label, e.g. 찬양 피아노", text: $label)
                    TextField("Search terms", text: $query)
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("Runs once a day and costs 100 units per run. Leave the search terms blank to reuse the label.")
                }
            }
            .navigationTitle("Saved topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty else { return }

        let existing = (try? modelContext.fetch(FetchDescriptor<TopicSearch>())) ?? []
        modelContext.insert(TopicSearch(
            label: trimmedLabel,
            query: trimmedQuery.isEmpty ? trimmedLabel : trimmedQuery,
            purpose: .worship,
            sortOrder: (existing.map(\.sortOrder).max() ?? 0) + 1
        ))
        try? modelContext.save()
        dismiss()
    }
}
