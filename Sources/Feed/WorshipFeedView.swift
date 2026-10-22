//
//  WorshipFeedView.swift
//  SolaPraise
//
//  Purpose 1: worship music — scoped feed, budgeted search, curation.
//
//  Two search modes, deliberately unequal:
//    • Typing filters what is already cached — your channels and saved
//      topics — free, instant, no network.
//    • YouTube 전체 검색 costs 100 units: pressing return, or the button
//      under your own results, with the day's remaining searches on it.
//      Once it has run, its results replace the button — the button sitting
//      above results it had already fetched read as "these are not the
//      results yet".
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

    @EnvironmentObject private var host: PlayerHost
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @EnvironmentObject private var team: TeamStore
    @StateObject private var feed = FeedStore()

    @Query(sort: [SortDescriptor(\Channel.sortOrder), SortDescriptor(\Channel.addedAt)])
    private var allChannels: [Channel]

    @Query(sort: [SortDescriptor(\TopicSearch.sortOrder), SortDescriptor(\TopicSearch.createdAt)])
    private var topics: [TopicSearch]

    @Query(sort: [SortDescriptor(\CachedVideo.publishedAt, order: .reverse)])
    private var allVideos: [CachedVideo]

    @State private var searchText = ""
    /// What completion draws from, built once per change of what it is
    /// built from — reading song titles out of video titles is not free.
    @State private var completionPool: [SongCompletion.Candidate] = []
    /// The pool's songs by their letters, to know when a song is reached.
    @State private var completionTitles: Set<String> = []
    @StateObject private var history = SearchHistory.shared("worship")
    /// Nil means every whitelisted channel.
    @State private var channelFilter: String?
    /// A saved topic's query, narrowing the feed to titles that have it.
    @State private var topicFilter: String?
    @State private var showAddPlaylist = false

    @Query(sort: [SortDescriptor(\CachedPlaylist.title)])
    private var allPlaylists: [CachedPlaylist]

    @Query private var savedSongs: [SavedSong]

    /// Videos this app has already produced a chart from.
    private var sheetedVideoIds: Set<String> {
        Set(savedSongs.compactMap(\.videoId))
    }
    @State private var remoteResults: [YTSearchResult] = []
    /// The query `remoteResults` answer. Typing on makes them another
    /// query's results, and they are hidden until searched again.
    @State private var remoteQuery: String?
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var showSettings = false
    @State private var showAddTopic = false
    @State private var addTarget: PlayableVideo?
    /// 곡 by default — the tab is for finding a song to sing; a three-hour
    /// set and a 20-second clip are a choice away. Kept as last chosen.
    @AppStorage("worship.length") private var length: WorshipLength = .song
    /// videoId → (duration, views), filled by one videos.list after a search.
    @State private var resultDetail: [String: (Int?, Int?)] = [:]

    private var channels: [Channel] {
        allChannels.filter { $0.purposeRaw == Purpose.worship.rawValue }
    }

    var body: some View {
        NavigationStack {
            content
                .bottomChrome()
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
                .searchSuggestions { suggestionRows }
                .task(id: poolKey) { buildCompletionPool() }
                .onSubmit(of: .search) { Task { await runRemoteSearch() } }
                .onChange(of: searchText) { _, newValue in
                    if newValue.isEmpty { remoteResults = []; searchError = nil }
                }
                .sheet(isPresented: $showSettings) { SettingsView() }
                .sheet(isPresented: $showAddTopic) { AddTopicSheet() }
                .sheet(isPresented: $showAddPlaylist) { AddPlaylistSheet(purpose: .worship) }
                .sheet(item: $addTarget) { AddToPlaylistSheet(video: $0) }
                .refreshable { await refresh() }
                .task { await refreshIfNeeded() }
                #if DEBUG
                .onAppear { if let query = DebugHarness.searchQuery { searchText = query } }
                #endif
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showAddPlaylist = true } label: {
                Image(systemName: "text.badge.plus")
            }
            .accessibilityLabel("재생목록 추가")

            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("설정")
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

    // MARK: - Completion

    /// As a title is typed, the songs it can be — the team's first, with
    /// when it was last sung (SongCompletion). Nothing typed: the searches
    /// made before. A song reached is not completed again, so the results
    /// below are not covered by a list of longer titles.
    @ViewBuilder
    private var suggestionRows: some View {
        if trimmedSearch.isEmpty {
            ForEach(history.entries, id: \.self) { query in
                Label(query, systemImage: "clock.arrow.circlepath")
                    .searchCompletion(query)
            }
        } else if !completionTitles.contains(String(String.UnicodeScalarView(SongCompletion.letters(trimmedSearch)))) {
            ForEach(SongCompletion.suggest(trimmedSearch, from: completionPool), id: \.text) { found in
                HStack(spacing: 8) {
                    Label(found.text, systemImage: Self.symbol(found.source))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let detail = found.detail {
                        Text(detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .searchCompletion(found.text)
            }
        }
    }

    private static func symbol(_ source: SongCompletion.Source) -> String {
        switch source {
        case .team:    return "music.note.list"
        case .chosen:  return "checkmark.seal"
        case .history: return "clock.arrow.circlepath"
        case .video:   return "play.rectangle"
        }
    }

    private var poolKey: String {
        "\(allVideos.count)|\(team.songs.count)|\(team.services.count)|\(history.entries.count)"
    }

    private func buildCompletionPool() {
        var pool: [SongCompletion.Candidate] = []
        // The team's songs: the latest Sunday each was sung, its key, and
        // how often — a song sung ten times is the likelier one.
        // Every 순서 — a Plan tab's where the team keeps one, else the
        // Songs tab's — and the Songs tab's days that have no service.
        var sung: [String: (title: String, day: Date, key: String?, count: Int)] = [:]
        var days: [Date: [(title: String, key: String?)]] = [:]
        for service in team.services {
            let day = Calendar.current.startOfDay(for: service.date)
            days[day, default: []] += team.plan(for: service).filter { $0.kind == .song }.map { ($0.title, $0.key) }
        }
        for (day, list) in team.songs where days[day] == nil {
            days[day] = list.map { ($0.title, $0.key) }
        }
        for (day, list) in days {
            for song in list {
                let title = PlanSongTitle.split(song.title).title
                let id = String(String.UnicodeScalarView(SongCompletion.letters(title)))
                guard !id.isEmpty else { continue }
                var entry = sung[id] ?? (title, day, song.key, 0)
                entry.count += 1
                // The last time it was sung; a coming service only when it
                // has not been sung yet.
                let today = Calendar.current.startOfDay(for: Date())
                let better = entry.day > today ? (day <= today || day < entry.day) : (day <= today && day >= entry.day)
                if better { entry.day = day; entry.key = song.key ?? entry.key }
                sung[id] = entry
            }
        }
        let calendar = Calendar.current
        for entry in sung.values {
            let date = calendar.dateComponents([.month, .day], from: entry.day)
            let detail = ["\(date.month ?? 0)/\(date.day ?? 0)", entry.key].compactMap { $0 }.joined(separator: " · ")
            pool.append(.init(text: entry.title, source: .team, detail: detail, weight: entry.count * 5))
        }
        pool += SongTitleChoices.all.map { .init(text: $0, source: .chosen) }
        pool += history.entries.enumerated().map { index, query in
            .init(text: query, source: .history, weight: (history.entries.count - index) * 3)
        }
        var seen = Set<String>()
        for video in worshipVideos.prefix(500) {
            let title = SongTitleChoices.title(for: video.videoId)
                ?? PlanSongTitle.split(video.title, channel: video.channelTitle).title
            guard title.count <= 40, seen.insert(title).inserted else { continue }
            pool.append(.init(text: title, source: .video))
        }
        completionPool = pool
        completionTitles = Set(pool.filter { $0.source != .history }
            .map { String(String.UnicodeScalarView(SongCompletion.letters($0.text))) })
    }

    // MARK: - This week

    /// The team's next service with songs to play — its songs in order.
    private var nextSet: (service: TeamService, songs: [PlanItem])? {
        for service in team.services.filter({ !$0.isPast }).sorted(by: { $0.date < $1.date }) {
            let songs = team.plan(for: service).filter { $0.kind == .song && $0.videoId != nil }
            if !songs.isEmpty { return (service, songs) }
        }
        return nil
    }

    /// 이번 주 찬양: what the team is singing next, a tap from listening —
    /// the set to learn, at the top of the tab you open to listen.
    ///
    /// WHY HERE: the songs were only reachable from 예배 준비, three taps
    /// down a schedule, so the week's 찬양 was the thing the 찬양 tab
    /// could not play.
    @ViewBuilder
    private var thisWeek: some View {
        if let next = nextSet {
            VStack(alignment: .leading, spacing: 8) {
                Button { playSet(next.songs, from: 0) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "music.note.list")
                            .font(.caption)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("이번 주 찬양")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            Text(RosterMessage.day(next.service.date) + " " + next.service.title
                                 + " · \(next.songs.count)곡")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("이번 주 찬양 이어 듣기")

                // Each song, in order: one starts the set from there.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(next.songs.enumerated()), id: \.offset) { index, song in
                            Button { playSet(next.songs, from: index) } label: {
                                HStack(spacing: 5) {
                                    Text("\(index + 1)")
                                        .font(.caption2.monospacedDigit().weight(.bold))
                                        .foregroundStyle(.tint)
                                    Text(PlanSongTitle.split(song.title).title)
                                        .font(.caption)
                                        .lineLimit(1)
                                    if let key = song.key, !key.isEmpty {
                                        Text(key)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.10)))
            .padding(.horizontal, 16)
        }
    }

    private func playSet(_ songs: [PlanItem], from index: Int) {
        host.play(queue: songs.compactMap { item in
                      item.videoId.map { PlayableVideo(id: $0, title: item.title) }
                  },
                  startIndex: index, purpose: .worship, curated: true)
    }

    // MARK: - Browse

    private var browseScroll: some View {
            ScrollView {
                // A pinned section header, not a safeAreaInset.
                //
                // The inset shared the top safe area with `.searchable`'s
                // drawer, so every time iOS animated the search field on
                // scroll it dragged the channel row up and down with it —
                // which looked like the bar flickering out of existence. A
                // pinned header lives in the scroll's own coordinate space
                // and stays put.
                LazyVStack(alignment: .leading, spacing: 26, pinnedViews: [.sectionHeaders]) {
                    Section {
                    thisWeek

                    if !pinnedPlaylists.isEmpty || !pinnedVideos.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("고정됨", systemImage: "pin.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(pinnedPlaylists) { playlist in
                                Button {
                                    Task { await playPlaylist(playlist) }
                                } label: {
                                    PlaylistBar(playlist: playlist)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if let invite = playlist.inviteURL {
                                        // The invite, not the plain link: a
                                        // teammate needs the token to join
                                        // as a collaborator, not just to
                                        // read.
                                        ShareLink(item: invite) {
                                            Label("팀원 초대 링크 공유",
                                                  systemImage: "person.2.badge.plus")
                                        }
                                    }
                                    PlaylistPinButton(playlist: playlist, purpose: .worship) {
                                        try? modelContext.save()
                                    }
                                }
                            }

                            ForEach(pinnedVideos) { video in
                                // Swipe to unpin, as well as the long press.
                                //
                                // These two were pinned as examples and
                                // looked permanent: the only way to take one
                                // down was a context menu nobody opens on a
                                // row that does not look like it has one.
                                SwipeToRemoveRow(onRemove: {
                                    video.isPinned = false
                                    try? modelContext.save()
                                }, symbol: "pin.slash", tint: .orange,
                                   accessibility: "고정 해제") {
                                // Content with a tap gesture, not a Button: a
                                // Button claims the drag before the swipe can
                                // see it, so the row played instead of
                                // revealing anything. The same trap the
                                // playlist and queue rows fell into.
                                PinnedSetBar(video: video)
                                .contentShape(Rectangle())
                                .onTapGesture { play(video, in: pinnedVideos) }
                                .contextMenu {
                                    pinToggle(video)
                                    SheetMusicMenu(title: video.title, channel: video.channelTitle) {
                                        Label("공식 악보 찾기",
                                              systemImage: "doc.text.magnifyingglass")
                                    }
                                    AudioSourceMenu(title: video.title,
                                                    seconds: video.durationSeconds,
                                                    artist: video.channelTitle) {
                                        Label("음원 찾기",
                                              systemImage: "waveform.badge.magnifyingglass")
                                    }
                                    AddToServiceMenu(title: video.title,
                                                     videoId: video.videoId,
                                                     channel: video.channelTitle) {
                                        Label("콘티에 추가",
                                              systemImage: "calendar.badge.plus")
                                    }
                                }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                if channels.isEmpty && topics.isEmpty {
                    emptyGuidance
                }

                    // One feed, newest first.
                    //
                    // Grouping by channel forced a choice nobody was making:
                    // you do not sit down to watch MARKERS, you sit down to
                    // find a song. Per-channel sections also meant the newest
                    // upload in the app could be four sections down, and a cap
                    // per section hid better matches behind worse ones.
                    // Channel is a filter now, for when it actually matters.
                    let feedVideos = browseVideos
                    if !feedVideos.isEmpty {
                        LazyVGrid(columns: FeedGrid.columns, spacing: 16) {
                            ForEach(feedVideos) { video in
                                Button { play(video, in: feedVideos) } label: {
                                    VideoCard(video: video,
                                              hasSheet: sheetedVideoIds.contains(video.videoId))
                                }
                                .buttonStyle(.plain)
                                .contextMenu { pinToggle(video) }
                            }
                        }
                        .padding(.horizontal, 16)
                    } else if !(channels.isEmpty && topics.isEmpty) {
                        Text(channelFilter == nil && topicFilter == nil
                             ? "아직 불러온 영상이 없습니다. 아래로 당겨 새로고침하세요."
                             : "이 필터에 해당하는 영상이 없습니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                    }

                if let message = feed.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }

                    if !(channels.isEmpty && topics.isEmpty) {
                        FeedEndMarker(refreshedAt: feed.lastRefreshedAt)
                    }
                    } header: {
                        // Every filter on one pinned row — see FilterBar.
                        // Channels are the one people reach for most, so
                        // the row stays in view while the feed scrolls.
                        if !(channels.isEmpty && topics.isEmpty) {
                            WorshipFilterRow(channels: channels, topics: topics,
                                             channelFilter: $channelFilter, topicFilter: $topicFilter,
                                             length: $length) { showAddTopic = true }
                        }
                    }
                }
                .padding(.top, 8)
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
                    ResultSection(title: "내 채널·주제에서", subtitle: "\(local.count)개 · 저장된 영상", videos: local) { video in
                        play(video, in: local)
                    } onAdd: { video in
                        addTarget = playable(video)
                    }
                } else {
                    Text("내 채널과 주제에는 「\(trimmedSearch)」이(가) 없습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }

                remoteSection
            }
            .padding(.top, 12)
        }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the YouTube results on hand answer what is typed now.
    private var hasRemoteResults: Bool {
        !remoteResults.isEmpty && remoteQuery == trimmedSearch
    }

    @ViewBuilder
    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !hasRemoteResults {
                Button {
                    Task { await runRemoteSearch() }
                } label: {
                    HStack {
                        Image(systemName: "globe")
                        Text("YouTube 전체에서 「\(trimmedSearch)」 검색")
                            .lineLimit(1)
                        Spacer()
                        Text("오늘 \(quota.searchesRemaining)회 남음")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(isSearching || !quota.canSearch || trimmedSearch.isEmpty)
                .padding(.horizontal, 16)
            }

            if isSearching {
                ProgressView().padding(.horizontal, 16)
            }
            if let searchError {
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }
            if hasRemoteResults {
                RemoteResultSection(results: FeedFilter.arrangeResults(remoteResults, seconds: { resultDetail[$0]?.0 }),
                                    detail: resultDetail) { result in
                    guard let id = result.videoId else { return }
                    let info = resultDetail[id]
                    host.play(queue: [PlayableVideo(
                            id: id, title: result.title,
                            channelTitle: result.snippet?.channelTitle,
                            durationSeconds: info?.0,
                            publishedAt: result.snippet?.publishedAt,
                            viewCount: info?.1,
                            channelId: result.snippet?.channelId
                        )], startIndex: 0, purpose: .worship)
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
        // Spaces, half-typed syllables and initials, as completion reads
        // them: 「주경외함」 finds 「주 경외함으로」.
        let needle = searchText.lowercased()
        return worshipVideos
            .filter { $0.title.lowercased().contains(needle) || SongCompletion.matches(searchText, title: $0.title) }
            .prefix(20)
            .map { $0 }
    }

    /// Playlists pinned to 찬양 by link.
    ///
    /// A church's worship playlist commonly lives on the same channel as its
    /// sermons, so it cannot be found by following channel purpose — it has
    /// to be pinned deliberately.
    private var pinnedPlaylists: [CachedPlaylist] {
        allPlaylists
            .filter { $0.purposeRaw == Purpose.worship.rawValue }
            .sorted { ($0.isPinned ? 0 : 1, $0.title) < ($1.isPinned ? 0 : 1, $1.title) }
    }

    /// Long-form sets kept at the top. Excluded from the feed below so they
    /// are not listed twice.
    private var pinnedVideos: [CachedVideo] {
        allVideos.filter { $0.isPinned }
    }

    private func pinToggle(_ video: CachedVideo) -> some View {
        Button {
            video.isPinned.toggle()
            try? modelContext.save()
        } label: {
            Label(video.isPinned ? "고정 해제" : "찬양에 고정",
                  systemImage: video.isPinned ? "pin.slash" : "pin")
        }
    }

    private func playPlaylist(_ playlist: CachedPlaylist) async {
        guard auth.canReadYouTube else {
            searchError = "재생목록을 열려면 Google 로그인이 필요합니다."
            return
        }
        let client = AppServices.client(auth: auth, quota: quota)
        // Bounded: an auto-generated Live playlist runs to thousands of items
        // and is newest-first, so recent pages are what a "latest service" row
        // means. Filtered because such a playlist holds everything the channel
        // ever streamed, not the one kind you pinned it for.
        let filter = playlist.titleFilter
        guard let items = try? await client.recentPlaylistItems(
            playlistId: playlist.playlistId,
            // One page is 50 streams, about eight weeks — a dozen services
            // after filtering, which is more than a "latest service" row can
            // use. Two gives headroom if the mix shifts.
            pages: filter == nil ? 1 : 2
        ) else {
            searchError = "\(playlist.title): 재생목록을 불러오지 못했습니다."
            return
        }
        let queue = items.compactMap { item -> PlayableVideo? in
            guard !item.isUnavailable else { return nil }
            if let filter, !item.title.contains(filter) { return nil }
            return PlayableVideo(item: item)
        }
        guard !queue.isEmpty else {
            searchError = playlist.titleFilter == nil
                ? "\(playlist.title): 재생할 수 있는 영상이 없습니다."
                : "\(playlist.title): 최근 항목에서 찾지 못했습니다."
            return
        }
        // A filtered playlist is not the playlist: nothing is saved back.
        host.play(queue: queue, startIndex: 0, purpose: .worship, curated: true,
                  source: filter == nil ? .init(playlistId: playlist.playlistId, title: playlist.title) : nil)
    }

    /// The browse feed: every worship video the cache holds, newest first,
    /// narrowed by the topic, channel and length chips.
    private var browseVideos: [CachedVideo] {
        let channelIds = Set(channels.map(\.youtubeChannelId))
        return allVideos
            .filter { video in
                if let channelFilter {
                    return video.channelId == channelFilter
                }
                if let topicFilter, !topicFilter.isEmpty {
                    return video.title.lowercased().contains(topicFilter.lowercased())
                        && (video.channelId.map(channelIds.contains) ?? false
                            || video.sourceRaw == CachedVideo.Source.topicSearch.rawValue)
                }
                // Topic-search results belong here too: they were fetched for
                // 찬양 and have no channel in the whitelist.
                return video.channelId.map(channelIds.contains) ?? false
                    || video.sourceRaw == CachedVideo.Source.topicSearch.rawValue
            }
            .filter { length.matches(seconds: $0.durationSeconds) }
            // 안내 · 공지 · 예고편 out, as 설정 › 피드·찬양 검색 says.
            .filter { !(FeedFilter.skipsNotices && FeedFilter.isNotice($0.title)) }
            .filter { !$0.isPinned }
            .prefix(Self.browseCap)
            .map { $0 }
    }

    /// Enough to browse, finite by design. The feed still ends.
    private static let browseCap = 120

    private func cappedVideos(forChannel channel: Channel) -> [CachedVideo] {
        allVideos
            .filter { $0.channelId == channel.youtubeChannelId }
            .filter { length.matches(seconds: $0.durationSeconds) }
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
        host.play(queue: queue, startIndex: start, purpose: .worship)
    }

    private func runRemoteSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, auth.canReadYouTube else {
            searchError = auth.canReadYouTube ? nil : "YouTube 전체 검색은 Google 로그인이 필요합니다."
            return
        }
        isSearching = true
        searchError = nil
        defer { isSearching = false }

        history.record(query)

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            remoteResults = try await client.search(query: query)
            remoteQuery = query
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
        let client = auth.canReadYouTube ? AppServices.client(auth: auth, quota: quota) : nil
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
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            // By song: one row each, its other uploads folded under it.
            ForEach(Array(SongGroups.group(videos, title: \.title, channel: \.channelTitle).enumerated()),
                    id: \.offset) { _, group in
                VersionGroup(count: group.items.count) {
                    row(group.items[0])
                } others: {
                    ForEach(group.items.dropFirst()) { row($0) }
                }
            }
        }
    }

    private func row(_ video: CachedVideo) -> some View {
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

/// One song's uploads: the first as a row, the rest behind 「다른 버전 N개」,
/// opened in place — compared side by side, not hunted for down the list.
private struct VersionGroup<First: View, Others: View>: View {
    let count: Int
    @ViewBuilder let first: First
    @ViewBuilder let others: Others
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            first
            if count > 1 {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { open.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack")
                        Text(open ? "버전 접기" : "다른 버전 \(count - 1)개")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tint)
                    .padding(.leading, 16 + 88 + 10)
                }
                .buttonStyle(.plain)
                if open {
                    VStack(alignment: .leading, spacing: 8) { others }
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.04))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
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
        let groups = SongGroups.group(results, title: \.title, channel: { $0.snippet?.channelTitle })
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("YouTube 전체 검색 결과").font(.subheadline.weight(.semibold))
                Text(groups.count == results.count ? "\(results.count)개" : "\(groups.count)곡 · 영상 \(results.count)개")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VersionGroup(count: group.items.count) {
                    row(group.items[0])
                } others: {
                    ForEach(group.items.dropFirst()) { row($0) }
                }
            }
        }
    }

    private func row(_ result: YTSearchResult) -> some View {
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
