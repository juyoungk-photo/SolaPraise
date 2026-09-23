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
    @State private var showReading = false
    @State private var isEditing = false
    @State private var playRequest: FeedPlayRequest?
    @State private var showSearch = false
    @State private var isLoadingPlaylist = false
    @State private var playlistError: String?
    @StateObject private var feed = FeedStore()

    /// Cards laid out as explicit rows.
    ///
    /// LazyVGrid cannot do mixed-width cells — `gridCellColumns` only applies
    /// inside SwiftUI's `Grid`, and in a LazyVGrid it is silently ignored,
    /// which left wide cards rendering narrow with holes beside them. So the
    /// rows are built by hand: a wide card takes a row to itself, narrow ones
    /// pair up.
    private var rows: [[HomeCard]] {
        var result: [[HomeCard]] = []
        var pending: [HomeCard] = []

        for card in cards {
            if card.kind.isWide {
                if !pending.isEmpty { result.append(pending); pending = [] }
                result.append([card])
            } else {
                pending.append(card)
                if pending.count == 2 { result.append(pending); pending = [] }
            }
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(row) { card in
                                cardView(card)
                                    .frame(maxWidth: .infinity)
                            }
                            // Keeps a lone narrow card at half width instead
                            // of stretching across the row.
                            if row.count == 1 && !row[0].kind.isWide {
                                Color.clear.frame(maxWidth: .infinity)
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
            .safeAreaInset(edge: .bottom) { searchBar }
            .navigationTitle("홈")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEditing ? "완료" : "편집") { isEditing.toggle() }
                        .font(.subheadline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showAddCard) { AddHomeCardSheet() }
            .sheet(isPresented: $showSearch) { HomeSearchSheet() }
            .fullScreenCover(isPresented: $showReading) {
                ReadingView { showReading = false }
            }
            .fullScreenCover(item: $playRequest) { request in
                WatchScreen(queue: request.queue, startIndex: request.startIndex)
            }
            .refreshable { await refreshFeeds() }
            .task {
                seedDefaultsIfEmpty()
                // Home depends on cached videos for the channel and 시편 듣기
                // cards, so it must be able to fill that cache itself — the
                // 말씀 tab used to be the only thing that ever refreshed.
                if allVideos.isEmpty { await refreshFeeds() }
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

    // MARK: - Card rendering

    @ViewBuilder
    private func cardView(_ card: HomeCard) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                guard !isEditing else { return }
                open(card)
            } label: {
                HomeCardView(
                    card: card,
                    subtitle: subtitle(for: card),
                    thumbnailURL: thumbnail(for: card),
                    isRead: card.kind == .reading ? daily.isCurrentRead : false
                )
            }
            .buttonStyle(.plain)

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

    private func subtitle(for card: HomeCard) -> String? {
        switch card.kind {
        case .reading:
            return daily.title(for: daily.translation)
        case .psalmAudio:
            return psalmAudioVideo.map(\.title) ?? "시편 \(daily.chapter)편 · 아직 없음"
        case .channel:
            return latestVideo(for: card)?.title
        case .playlist:
            return "탭하면 재생"
        case .search:
            return "\(quota.searchesRemaining)회 남음"
        }
    }

    private func thumbnail(for card: HomeCard) -> URL? {
        switch card.kind {
        case .channel:    return latestVideo(for: card)?.thumbnailURL
        case .psalmAudio: return psalmAudioVideo?.thumbnailURL
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
        let n = daily.chapter
        // 공동체성경읽기 titles psalm readings "시편 72편 (개역개정)" — 편 is the
        // counter for psalms, even though the same channel uses 장 for other
        // books ("마태복음 12장"). Both are accepted anyway, plus an optional
        // space, so a title-format change does not silently break the card.
        //
        // The digits are bounded on the right so 시편 7편 cannot match inside
        // 시편 72편.
        let pattern = "시편\\s*\\(n)\\s*[편장]"
        return allVideos.first { video in
            guard video.channelId == DefaultChannels.psalmAudioChannelId else { return false }
            return video.title.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func latestVideo(for card: HomeCard) -> CachedVideo? {
        guard let id = card.targetId else { return nil }
        return allVideos.first { $0.channelId == id }
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
                queue: [PlayableVideo(
                    id: video.videoId,
                    title: video.title,
                    channelTitle: video.channelTitle,
                    durationSeconds: video.durationSeconds
                )],
                startIndex: 0
            )

        case .psalmAudio:
            guard let video = psalmAudioVideo else { return }
            playRequest = FeedPlayRequest(
                queue: [PlayableVideo(
                    id: video.videoId, title: video.title,
                    channelTitle: video.channelTitle,
                    durationSeconds: video.durationSeconds
                )],
                startIndex: 0
            )

        case .playlist:
            guard let playlistId = card.targetId else { selection = .library; return }
            Task { await playPlaylist(playlistId, title: card.title) }

        case .search:
            // Stay on Home — the sheet opens with the keyboard already up.
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
                guard !item.isUnavailable, let id = item.videoId else { return nil }
                return PlayableVideo(id: id, title: item.title, channelTitle: item.channelTitle)
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

    private func refreshFeeds() async {
        let client = auth.isSignedIn ? AppServices.client(auth: auth, quota: quota) : nil
        await feed.refresh(purpose: nil, context: modelContext, client: client)
    }

    // MARK: - Defaults

    /// First run gets a usable screen rather than an empty one: today's psalm,
    /// a card per Word channel, and search.
    private func seedDefaultsIfEmpty() {
        #if DEBUG
        print("[SolaPraise] home seeding: existing cards=\(cards.count) channels=\(channels.count)")
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
