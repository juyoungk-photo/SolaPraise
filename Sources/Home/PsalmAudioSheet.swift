//
//  PsalmAudioSheet.swift
//  SolaPraise
//
//  Today's psalm reading, with the chapter and channel both adjustable.
//
//  A sheet rather than an inline tap action because the inline version failed
//  silently: it ran, set an error, and drew it far below the fold, so tapping
//  the card looked like nothing happened. A screen always shows its own state.
//

import SwiftUI
import SwiftData

struct PsalmAudioSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @EnvironmentObject private var daily: DailyReading

    @StateObject private var feed = FeedStore()

    @Query(sort: [SortDescriptor(\CachedVideo.publishedAt, order: .reverse)])
    private var allVideos: [CachedVideo]

    @Query(sort: [SortDescriptor(\Channel.sortOrder), SortDescriptor(\Channel.addedAt)])
    private var channels: [Channel]

    /// Remembered so the choice survives reopening the sheet.
    @AppStorage("psalm.channelId") private var channelId = DefaultChannels.psalmAudioChannelId

    @State private var chapter = 1
    @State private var status = ""
    @State private var foundVia: String?
    @State private var isWorking = false
    @State private var playRequest: FeedPlayRequest?

    private var match: CachedVideo? {
        let pattern = "시편\\s*\(chapter)\\s*[편장]"
        return allVideos.first {
            $0.channelId == channelId
                && $0.title.range(of: pattern, options: .regularExpression) != nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                selectionSection

                if let match {
                    Section {
                        Button {
                            playRequest = FeedPlayRequest(
                                queue: [PlayableVideo(
                                    id: match.videoId, title: match.title,
                                    channelTitle: match.channelTitle,
                                    durationSeconds: match.durationSeconds
                                )],
                                startIndex: 0
                            )
                        } label: {
                            Label(match.title, systemImage: "play.circle.fill")
                                .lineLimit(2)
                        }
                    } header: {
                        Text("찾은 영상")
                    } footer: {
                        if let foundVia { Text(foundVia) }
                    }
                } else {
                    lookupSection
                }
            }
            .navigationTitle("시편 듣기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .fullScreenCover(item: $playRequest) { request in
                WatchScreen(queue: request.queue, startIndex: request.startIndex)
            }
            .task {
                if chapter == 1 { chapter = daily.chapter }
                describeCache()
            }
            .onChange(of: chapter) { _, _ in foundVia = nil; describeCache() }
            .onChange(of: channelId) { _, _ in foundVia = nil; describeCache() }
        }
    }

    // MARK: - Selection

    private var selectionSection: some View {
        Section {
            Stepper(value: $chapter, in: 1...Psalms.chapterCount) {
                HStack {
                    Text("시편")
                    Text("\(chapter)편").bold().monospacedDigit()
                    if chapter != daily.chapter {
                        Button("오늘로") { chapter = daily.chapter }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                }
            }

            Picker("채널", selection: $channelId) {
                ForEach(channels) { channel in
                    Text(channel.shortTitle).tag(channel.youtubeChannelId)
                }
            }

            LabeledContent("캐시", value: status)
        } header: {
            Text("찾을 대상")
        } footer: {
            Text("오늘은 시편 \(daily.chapter)편입니다. 다른 편이나 다른 채널에서도 찾을 수 있습니다.")
        }
    }

    private var lookupSection: some View {
        Section {
            Button {
                Task { await lookUp() }
            } label: {
                HStack {
                    Label("영상 찾기", systemImage: "magnifyingglass")
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isWorking || !auth.isSignedIn)
        } footer: {
            Text(auth.isSignedIn
                 ? "① 이 채널의 시편 재생목록을 먼저 확인합니다 (약 3 units). ② 없으면 이 채널만 대상으로 검색합니다 (100 units). 유튜브 전체 검색이 아닙니다. 남은 검색 \(quota.searchesRemaining)회."
                 : "Google 로그인이 필요합니다.")
        }
    }

    // MARK: - Lookup

    private func describeCache() {
        let cached = allVideos.filter { $0.channelId == channelId }
        let psalms = cached.filter { $0.title.contains("시편") }
        status = "영상 \(cached.count)개 · 시편 \(psalms.count)개"
    }

    private func lookUp() async {
        isWorking = true
        foundVia = nil
        defer { isWorking = false }

        let client = AppServices.client(auth: auth, quota: quota)
        let before = quota.unitsUsed

        // ① Free-ish route: the channel's own psalm playlist.
        status = "재생목록 확인 중…"
        let ingested = await feed.ingestPsalmPlaylist(
            context: modelContext, client: client, channelId: channelId
        )
        describeCache()
        if match != nil {
            foundVia = "재생목록에서 찾음 · \(ingested)개 수집 · \(quota.unitsUsed - before) units 사용"
            return
        }

        // ② Channel-scoped search.
        guard quota.canSearch else {
            status = "검색 예산 소진"
            return
        }
        status = "채널 검색 중… (100 units)"
        let found = await feed.findPsalmVideo(
            chapter: chapter, context: modelContext, client: client, channelId: channelId
        )
        describeCache()
        if found != nil {
            foundVia = "채널 검색에서 찾음 · \(quota.unitsUsed - before) units 사용"
        } else {
            status = "이 채널에 시편 \(chapter)편이 없습니다"
        }
    }
}
