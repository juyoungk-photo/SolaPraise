//
//  HomeView.swift
//  SolaPraise
//
//  The curated first screen: today's psalm, the QT channels that matter,
//  the praise-team playlist, and search — as cards the user owns.
//
//  Nothing appears here by algorithm. Every card was put there on purpose,
//  and any of them can be removed.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Binding var selection: ContentView.Tab

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @EnvironmentObject private var daily: DailyReading

    @Query(sort: [SortDescriptor(\HomeCard.sortOrder), SortDescriptor(\HomeCard.addedAt)])
    private var cards: [HomeCard]

    @Query(sort: [SortDescriptor(\Channel.sortOrder), SortDescriptor(\Channel.addedAt)])
    private var channels: [Channel]

    @Query(sort: [SortDescriptor(\CachedVideo.publishedAt, order: .reverse)])
    private var allVideos: [CachedVideo]

    @State private var showSettings = false
    @State private var showAddCard = false
    /// Pre-filled term when a 주제 card opens the search sheet.
    @State private var searchQuery = ""
    @State private var showReading = false
    @State private var isEditing = false
    @State private var playRequest: FeedPlayRequest?
    @State private var showSearch = false
    @State private var isLoadingPlaylist = false
    @State private var playlistError: String?
    @State private var showError = false
    @State private var showPsalmSheet = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var dayOffset: [String: Int] = [:]
    @AppStorage("psalm.channelId") private var psalmChannelId = DefaultChannels.psalmAudioChannelId
    @State private var isFindingPsalm = false
    @State private var attemptedPsalmChannels: Set<String> = []
    @State private var autoFindTask: Task<Void, Never>?
    @StateObject private var feed = FeedStore()

    /// Cards laid out as explicit rows.
    ///
    /// LazyVGrid cannot do mixed-width cells — `gridCellColumns` only applies
    /// inside SwiftUI's `Grid`, and in a LazyVGrid it is silently ignored,
    /// which left wide cards rendering narrow with holes beside them. So the
    /// rows are built by hand: a wide card takes a row to itself, narrow ones
    /// pair up.
    /// Two across on a phone, five on an iPad — matching the feed's card
    /// width, so a home tile and a video tile are the same size. At two, an
    /// iPad card grew to roughly 350pt and four tiles filled the screen.
    private var narrowCardsPerRow: Int { sizeClass == .regular ? 5 : 2 }

    private var rows: [[HomeCard]] {
        var result: [[HomeCard]] = []
        var pending: [HomeCard] = []

        for card in cards {
            // 시편 is pinned above the scroll, so it must not also be laid
            // out inside it.
            if card.kind == .reading { continue }
            if card.kind.isWide {
                if !pending.isEmpty { result.append(pending); pending = [] }
                result.append([card])
            } else {
                pending.append(card)
                if pending.count == narrowCardsPerRow {
                    result.append(pending); pending = []
                }
            }
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }

    /// Reordering happens in a plain List rather than by dragging tiles
    /// around the grid. The grid mixes full-width and half-width cards, so a
    /// drop target is ambiguous by construction — and this same nesting has
    /// already swallowed a Button's taps once. A List's move handles are
    /// unambiguous and they are what iOS users reach for.
    private var reorderList: some View {
        List {
            ForEach(cards) { card in
                HStack(spacing: 10) {
                    Image(systemName: card.kind.symbolName)
                        .font(.footnote)
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    Text(card.title).font(.subheadline)
                    Spacer()
                }
            }
            .onMove(perform: moveCards)
            .onDelete { offsets in
                for index in offsets { modelContext.delete(cards[index]) }
                renumber()
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
        .frame(height: CGFloat(cards.count) * 46 + 16)
        .scrollDisabled(true)
    }

    private func moveCards(from source: IndexSet, to destination: Int) {
        var ordered = cards
        ordered.move(fromOffsets: source, toOffset: destination)
        for (position, card) in ordered.enumerated() { card.sortOrder = position }
        try? modelContext.save()
    }

    /// Keeps sortOrder dense after a delete, so a later insert cannot land on
    /// a duplicate index and reorder itself.
    private func renumber() {
        for (position, card) in cards.enumerated() { card.sortOrder = position }
        try? modelContext.save()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if isEditing {
                        reorderList
                    } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(row) { card in
                                cardView(card)
                                    .frame(maxWidth: .infinity)
                            }
                            // Keeps a lone narrow card at half width instead
                            // of stretching across the row.
                            // Pad a short final row so its cards keep the
                            // width of a full one instead of stretching.
                            if !row.contains(where: { $0.kind.isWide }),
                               row.count < narrowCardsPerRow {
                                ForEach(0 ..< (narrowCardsPerRow - row.count), id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Button {
                    showAddCard = true
                } label: {
                    Label("카드 추가", systemImage: "plus")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if isLoadingPlaylist {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("플레이리스트 불러오는 중…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)
                }
                if let playlistError {
                    Text(playlistError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }

                FeedEndMarker(refreshedAt: nil, text: "오늘도 평안하세요")
            }
            .safeAreaInset(edge: .top) { pinnedReading }
            .safeAreaInset(edge: .bottom) { searchBar }
            .navigationTitle("홈")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEditing ? "완료" : "편집") {
                        if isEditing { renumber() }
                        isEditing.toggle()
                    }
                    .font(.subheadline)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showAddCard = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("카드 추가")
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showAddCard) { AddHomeCardSheet() }
            .sheet(isPresented: $showSearch) { HomeSearchSheet(initialQuery: searchQuery) }
            .sheet(isPresented: $showPsalmSheet) { PsalmAudioSheet() }
            // Debounced, because -/+ is held down: stepping ten chapters
            // should be one lookup after you stop, not ten while you go.
            .onChange(of: daily.chapter) { _, _ in
                autoFindTask?.cancel()
                autoFindTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await autoFindPsalmVideo()
                }
            }
            .task { await autoFindPsalmVideo() }
            .alert("시편 듣기", isPresented: $showError, presenting: playlistError) { _ in
                Button("확인", role: .cancel) { }
            } message: { message in
                Text(message)
            }
            .fullScreenCover(isPresented: $showReading) {
                ReadingView { showReading = false }
            }
            .fullScreenCover(item: $playRequest) { request in
                WatchScreen(queue: request.queue, startIndex: request.startIndex)
            }
            .refreshable { await refreshFeeds() }
            .task {
                seedDefaultsIfEmpty()
                removeObsoleteSearchCards()
                // Refresh once a day. "Only when empty" meant a device that
                // already had videos never picked up new default channels or
                // the psalm playlist — it would sit stale forever.
                let today = Calendar.current.startOfDay(for: Date())
                let stale = feed.lastRefreshedAt.map { $0 < today } ?? true
                if allVideos.isEmpty || stale { await refreshFeeds() }
                #if DEBUG
                if DebugHarness.showHomeSearch { showSearch = true }
                #endif
            }
        }
    }

    /// Always-reachable search. Pinned to the bottom rather than living in a
    /// card, so it stays under your thumb no matter how far you scroll — and
    /// so searching is never something you have to hunt for.
    private var searchBar: some View {
        Button {
            showSearch = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("찬양·말씀 검색")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(quota.searchesRemaining)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(quota.canSearch ? Color.secondary : Color.orange)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(Color(.secondarySystemBackground))
            )
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.94))
    }

    /// Today's psalm stays put while everything else scrolls under it.
    ///
    /// It is the one card that is the same errand every day, and scrolling
    /// past it to reach a channel meant scrolling back to read. Hidden while
    /// editing, where the card belongs in the reorder list instead.
    @ViewBuilder
    private var pinnedReading: some View {
        if !isEditing, let card = cards.first(where: { $0.kind == .reading }) {
            cardView(card)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                // An explicit colour, not .bar: on device that material
                // rendered as a black band with the content invisible behind
                // it, the same way it did in the channel jump bar.
                .background(Color(.systemBackground))
        }
    }

    // MARK: - Card rendering

    @ViewBuilder
    private func cardView(_ card: HomeCard) -> some View {
        ZStack(alignment: .topTrailing) {
            HomeCardView(
                card: card,
                subtitle: subtitle(for: card),
                thumbnailURL: thumbnail(for: card),
                isRead: card.kind == .reading ? daily.isCurrentRead : false,
                // Only the 시편 card steps. 시편 듣기 reads the same
                // `daily.chapter`, so it follows along without a second pair
                // of buttons competing for the same value.
                // 시편 steps its chapter, which is the same thing as its
                // day. A channel card steps through that channel's episodes.
                onStep: stepper(for: card)
            )
            // A tap gesture rather than a Button. Wrapping the card in
            // `Button { } label: { }` inside this nesting — ZStack in an
            // HStack in a LazyVStack in a ScrollView that also carries a
            // safeAreaInset — silently stopped delivering taps; the action
            // never ran, verified by logging inside it on device.
            .contentShape(Rectangle())
            .onTapGesture {
                #if DEBUG
                print("[SolaPraise] TAP card=\(card.kindRaw) editing=\(isEditing)")
                #endif
                guard !isEditing else { return }
                open(card)
            }

            if isEditing {
                Button {
                    modelContext.delete(card)
                    try? modelContext.save()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
    }

    private func stepper(for card: HomeCard) -> ((Int) -> Void)? {
        switch card.kind {
        case .reading:
            return { delta in daily.setChapter(Psalms.wrap(daily.chapter + delta)) }
        case .channel:
            return { delta in stepDay(card, by: delta) }
        default:
            return nil
        }
    }

    private func subtitle(for card: HomeCard) -> String? {
        switch card.kind {
        case .reading:
            return daily.title(for: daily.translation)
        case .psalmAudio:
            if let found = psalmAudioVideo {
                var parts = [found.title]
                if let secs = found.durationSeconds {
                    parts.append(ISO8601Duration.format(secs))
                }
                return parts.joined(separator: " · ")
            }
            if isFindingPsalm { return "찾는 중…" }
            // After the playlist has been read, a still-missing chapter means
            // the channel has not published it — say so, rather than implying
            // another tap will produce it for free.
            return attemptedPsalmChannels.contains(psalmChannelId)
                ? "시편 \(daily.chapter)편 · 채널에 없음, 탭하면 검색"
                : "시편 \(daily.chapter)편 · 탭하면 찾기"
        case .channel:
            guard let video = latestVideo(for: card) else { return nil }
            // The date is the point of a QT card, so it leads.
            guard let published = video.publishedAt else { return video.title }
            let day = published.formatted(.dateTime.month().day())
            return "\(day) · \(video.title)"
        case .playlist:
            return "탭하면 재생"
        case .video:
            return "탭하면 재생"
        case .topic:
            return card.targetId ?? card.title
        case .search:
            return "\(quota.searchesRemaining)회 남음"
        }
    }

    private func thumbnail(for card: HomeCard) -> URL? {
        switch card.kind {
        case .channel:    return latestVideo(for: card)?.thumbnailURL
        case .psalmAudio: return psalmAudioVideo?.thumbnailURL
        case .video:
            return card.targetId.flatMap {
                URL(string: "https://i.ytimg.com/vi/\($0)/mqdefault.jpg")
            }
        default:          return nil
        }
    }

    /// 공동체성경읽기's reading of whichever psalm is showing today.
    ///
    /// Matched from the local cache, so it costs nothing at lookup time. The
    /// cache is filled by FeedStore, which fetches this channel 1000 uploads
    /// deep — the individual psalm readings sit far behind its daily
    /// 30분 신구약 uploads, so a shallow fetch never reaches them.
    private var psalmAudioVideo: CachedVideo? {
        allVideos.first { video in
            // The same channel the 시편 듣기 sheet is set to. Hard-coding the
            // default here meant a reading found after changing the channel
            // there never reached this card.
            video.channelId == psalmChannelId
                && ScriptureReference.psalmChapter(in: video.title) == daily.chapter
        }
    }

    /// The episode for the day this card is currently showing.
    ///
    /// A QT channel publishes one episode per day, so "the newest upload" is
    /// only the right answer before today's has gone up — after which
    /// yesterday's is unreachable without leaving the home screen. The card
    /// picks by date and steps a day at a time, the way you would turn a page.
    private func latestVideo(for card: HomeCard) -> CachedVideo? {
        guard let id = card.targetId else { return nil }
        let episodes = allVideos.filter { $0.channelId == id }
        guard !episodes.isEmpty else { return nil }

        let offset = dayOffset[id] ?? 0
        guard offset != 0 else { return episodes.first }

        // Step through what exists rather than through the calendar: a channel
        // that skips a Saturday should go back to Friday, not to an empty day.
        let index = min(max(-offset, 0), episodes.count - 1)
        return episodes[index]
    }

    /// How many days back each channel card is showing. 0 is the newest.
    private func stepDay(_ card: HomeCard, by delta: Int) {
        guard let id = card.targetId else { return }
        let count = allVideos.filter { $0.channelId == id }.count
        guard count > 0 else { return }
        let next = (dayOffset[id] ?? 0) + delta
        // Clamped: forward stops at the newest, back stops at the oldest the
        // cache holds.
        dayOffset[id] = min(0, max(next, -(count - 1)))
    }

    // MARK: - Actions

    private func open(_ card: HomeCard) {
        switch card.kind {
        case .reading:
            showReading = true

        case .channel:
            // Straight into today's episode — that is the whole point of a
            // QT card. The rest of the channel is one tab away.
            guard let video = latestVideo(for: card) else {
                selection = .word
                return
            }
            playRequest = FeedPlayRequest(
                queue: [PlayableVideo(cached: video)],
                startIndex: 0
            )

        case .psalmAudio:
            // Always open the sheet: it reports its own state, so a tap can
            // never look like nothing happened.
            guard let video = psalmAudioVideo else {
                showPsalmSheet = true
                return
            }
            playRequest = FeedPlayRequest(
                queue: [PlayableVideo(cached: video)],
                startIndex: 0
            )

        case .playlist:
            guard let playlistId = card.targetId else { selection = .library; return }
            Task { await playPlaylist(playlistId, title: card.title) }

        case .video:
            guard let videoId = card.targetId else { return }
            playRequest = FeedPlayRequest(
                queue: [PlayableVideo(id: videoId, title: card.title)],
                startIndex: 0
            )

        case .topic:
            // Opens search pre-filled but does NOT spend a search: the cached
            // matches appear immediately and the 100-unit call stays a
            // deliberate second tap.
            searchQuery = card.targetId ?? card.title
            showSearch = true

        case .search:
            // Stay on Home — the sheet opens with the keyboard already up.
            searchQuery = ""
            showSearch = true
        }
    }

    /// Loads a playlist's items and starts playing, rather than dumping the
    /// user in the Library tab to find it themselves.
    private func playPlaylist(_ playlistId: String, title: String) async {
        guard auth.isSignedIn else {
            playlistError = "플레이리스트를 재생하려면 Google 로그인이 필요합니다."
            return
        }
        isLoadingPlaylist = true
        playlistError = nil
        defer { isLoadingPlaylist = false }

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            let items = try await client.playlistItems(playlistId: playlistId)
            let queue = items.compactMap { item -> PlayableVideo? in
                guard !item.isUnavailable else { return nil }
                return PlayableVideo(item: item)
            }
            guard !queue.isEmpty else {
                playlistError = "\(title): 재생할 수 있는 곡이 없습니다."
                return
            }
            playRequest = FeedPlayRequest(queue: queue, startIndex: 0)
        } catch {
            playlistError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func report(_ message: String) {
        playlistError = message
        showError = true
    }

    /// Pulls the channel's whole psalm playlist in, once, when a chapter the
    /// cache does not hold comes into view.
    ///
    /// This is the half of the lookup that is safe to run without asking. It
    /// is one playlistItems.list — about 3 units — and it brings back every
    /// psalm the channel has published at once, so after it runs, stepping
    /// through chapters costs nothing and shows the video immediately.
    ///
    /// The other half, a targeted search, is 100 units against a budget of
    /// 100 searches a day. Firing that on a step would mean holding + through
    /// ten chapters spent a tenth of the day's searching, so it stays behind
    /// the explicit 영상 찾기 button. That is the whole reason a step did not
    /// just produce a video: not caution about the playlist, caution about
    /// the search.
    private func autoFindPsalmVideo() async {
        guard psalmAudioVideo == nil, auth.isSignedIn, !isFindingPsalm else { return }
        // The ingest refuses to repeat once the channel is cached, but a
        // channel with few readings would retry on every step otherwise.
        guard !attemptedPsalmChannels.contains(psalmChannelId) else { return }

        isFindingPsalm = true
        defer { isFindingPsalm = false }

        let client = AppServices.client(auth: auth, quota: quota)
        let ingested = await feed.ingestPsalmPlaylist(
            context: modelContext, client: client, channelId: psalmChannelId
        )
        // Only mark it done when there was actually a playlist to read; a
        // zero means the playlist has not been cached yet, and a later
        // refresh may well make it work.
        if ingested > 0 { attemptedPsalmChannels.insert(psalmChannelId) }
    }

    /// Searches 공동체성경읽기 for today's psalm and caches it.
    private func findTodaysPsalmVideo() async {
        #if DEBUG
        print("[SolaPraise] PSALM tap chapter=\(daily.chapter) signedIn=\(auth.isSignedIn) canSearch=\(quota.canSearch) finding=\(isFindingPsalm)")
        #endif
        guard !isFindingPsalm else { return }
        guard auth.isSignedIn else {
            report("시편 영상을 찾으려면 Google 로그인이 필요합니다.")
            return
        }
        isFindingPsalm = true
        playlistError = nil
        defer { isFindingPsalm = false }

        let client = AppServices.client(auth: auth, quota: quota)
        // Try the free route first: the channel's own psalm playlist.
        _ = await feed.ingestPsalmPlaylist(context: modelContext, client: client)
        #if DEBUG
        let pls = (try? modelContext.fetch(FetchDescriptor<CachedPlaylist>())) ?? []
        let mine = pls.filter { $0.channelId == DefaultChannels.psalmAudioChannelId }
        print("[SolaPraise] PSALM after ingest: playlists=\(mine.count) match=\(psalmAudioVideo != nil)")
        #endif
        if psalmAudioVideo != nil { return }

        // Still nothing — one targeted search (100 units).
        guard quota.canSearch else {
            report("오늘 검색 예산을 모두 사용했습니다.")
            return
        }
        let found = await feed.findPsalmVideo(
            chapter: daily.chapter, context: modelContext, client: client
        )
        #if DEBUG
        print("[SolaPraise] PSALM search → \(found?.title ?? "nil")  quota=\(quota.unitsUsed)")
        #endif
        if found == nil {
            report("시편 \(daily.chapter)편 영상을 공동체성경읽기 채널에서 찾지 못했습니다.")
        } else {
            report("시편 \(daily.chapter)편을 찾았습니다. 카드를 다시 탭하면 재생됩니다.")
        }
    }

    private func refreshFeeds() async {
        let client = auth.isSignedIn ? AppServices.client(auth: auth, quota: quota) : nil
        await feed.refresh(purpose: nil, context: modelContext, client: client)
        // Independent of the purpose-scoped refreshes, so a Worship-tab
        // refresh claiming "already refreshed today" cannot starve it.
        _ = await feed.ingestPsalmPlaylist(context: modelContext, client: client)
    }

    // MARK: - Defaults

    /// First run gets a usable screen rather than an empty one: today's psalm,
    /// a card per Word channel, and search.
    /// Removes a 검색 card left over from before the pinned bottom search bar
    /// existed — it would otherwise sit there duplicating the bar forever,
    /// since seeding only runs when the card list is empty.
    private func removeObsoleteSearchCards() {
        let stale = cards.filter { $0.kind == .search }
        guard !stale.isEmpty else { return }
        for card in stale { modelContext.delete(card) }
        try? modelContext.save()
    }

    private func seedDefaultsIfEmpty() {
        #if DEBUG
        print("[SolaPraise] home seeding: existing cards=\(cards.count) channels=\(channels.count)")
        for c in cards {
            print("[SolaPraise]   card kind=\(c.kindRaw) title=\(c.title) target=\(c.targetId ?? "-")")
        }
        #endif
        guard cards.isEmpty else { return }

        var order = 0
        func add(_ kind: HomeCardKind, _ title: String, target: String? = nil) {
            modelContext.insert(HomeCard(kind: kind, targetId: target, title: title, sortOrder: order))
            order += 1
        }

        add(.reading, "시편")
        add(.psalmAudio, "시편 듣기", target: DefaultChannels.psalmAudioChannelId)
        add(.channel, "매일성경 QT", target: "UCroCQn7T3UZsE8N5oyaIP1w")
        add(.channel, "⛪ 코너스톤교회", target: "UCr1z2X_zyeC8GMbLv4swMVA")
        add(.playlist, "CCC 찬양콘티", target: "PLAMZz0bkBBUA")

        do {
            try modelContext.save()
            #if DEBUG
            print("[SolaPraise] home seeded \(order) cards")
            #endif
        } catch {
            #if DEBUG
            print("[SolaPraise] home seed SAVE FAILED: \(error)")
            #endif
        }
    }
}
