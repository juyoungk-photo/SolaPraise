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

    @AppStorage("psalm.channelId") private var channelId = DefaultChannels.psalmAudioChannelId

    @State private var chapter = 1
    @State private var downloaded = ""
    @State private var note: String?
    @State private var isWorking = false
    @State private var playRequest: FeedPlayRequest?

    private var match: CachedVideo? {
        allVideos.first {
            $0.channelId == channelId
                && ScriptureReference.psalmChapter(in: $0.title) == chapter
        }
    }

    var body: some View {
        NavigationStack {
            List {
                selectionSection
                if let match { foundSection(match) } else { lookupSection }
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
                describeDownloaded()
            }
            .onChange(of: chapter) { _, _ in note = nil; describeDownloaded() }
            .onChange(of: channelId) { _, _ in note = nil; describeDownloaded() }
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

            LabeledContent("내려받은 시편", value: downloaded)
        } header: {
            Text("찾을 대상")
        } footer: {
            // "150편 중 1편" read as a limitation of the channel. It is not —
            // it is how much this device has fetched so far.
            Text("오늘은 시편 \(daily.chapter)편입니다. '내려받은 시편'은 이 기기에 저장된 편 수이며, 채널이 실제로 가진 양과는 다릅니다. 「영상 찾기」를 누르면 이 채널의 시편 재생목록을 한 번에 가져옵니다.")
        }
    }

    // MARK: - Result

    private func foundSection(_ video: CachedVideo) -> some View {
        Section {
            Button {
                playRequest = FeedPlayRequest(
                    queue: [PlayableVideo(
                        id: video.videoId, title: video.title,
                        channelTitle: video.channelTitle,
                        durationSeconds: video.durationSeconds,
                        publishedAt: video.publishedAt
                    )],
                    startIndex: 0
                )
            } label: {
                HStack(spacing: 10) {
                    VideoMetaRow(video: PlayableVideo(
                        id: video.videoId, title: video.title,
                        channelTitle: video.channelTitle,
                        durationSeconds: video.durationSeconds,
                        publishedAt: video.publishedAt
                    ))
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("찾은 영상")
        } footer: {
            if let note { Text(note) }
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

            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text(auth.isSignedIn
                 ? "① 이 채널의 시편 재생목록을 먼저 확인합니다 (약 3 units). ② 없으면 이 채널만 대상으로 검색합니다 (100 units). 유튜브 전체 검색이 아닙니다. 남은 검색 \(quota.searchesRemaining)회."
                 : "Google 로그인이 필요합니다.")
        }
    }

    // MARK: - Lookup

    /// Counts distinct chapters held locally, not videos: a channel may post
    /// the same psalm more than once.
    private func describeDownloaded() {
        let psalms = allVideos.filter {
            $0.channelId == channelId && $0.title.contains("시편")
        }
        let chapters = Set(psalms.compactMap { ScriptureReference.psalmChapter(in: $0.title) })
        downloaded = chapters.isEmpty ? "없음" : "\(chapters.count)편"
    }

    private func lookUp() async {
        isWorking = true
        note = nil
        defer { isWorking = false }

        let client = AppServices.client(auth: auth, quota: quota)
        let before = quota.unitsUsed

        note = "재생목록 확인 중…"
        let ingested = await feed.ingestPsalmPlaylist(
            context: modelContext, client: client, channelId: channelId
        )
        describeDownloaded()
        if match != nil {
            note = "재생목록에서 찾음 · \(ingested)편 내려받음 · \(quota.unitsUsed - before) units"
            return
        }

        guard quota.canSearch else {
            note = "오늘 검색 예산을 모두 사용했습니다"
            return
        }

        note = "채널 검색 중… (100 units)"
        let found = await feed.findPsalmVideo(
            chapter: chapter, context: modelContext, client: client, channelId: channelId
        )
        describeDownloaded()
        note = found != nil
            ? "채널 검색에서 찾음 · \(quota.unitsUsed - before) units"
            : "이 채널에 시편 \(chapter)편이 없습니다"
    }
}
