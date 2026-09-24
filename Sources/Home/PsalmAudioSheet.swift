//
//  PsalmAudioSheet.swift
//  SolaPraise
//
//  Today's psalm reading from 공동체성경읽기.
//
//  This is a sheet rather than an inline tap action because the inline version
//  failed silently: the lookup ran, set an error, and rendered it far below the
//  fold, so tapping the card appeared to do nothing at all. A screen always
//  shows its own state — found, searching, or why not.
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

    @State private var status = "확인 중…"
    @State private var isWorking = false
    @State private var playRequest: FeedPlayRequest?

    private var match: CachedVideo? {
        let n = daily.chapter
        let pattern = "시편\\s*\(n)\\s*[편장]"
        return allVideos.first {
            $0.channelId == DefaultChannels.psalmAudioChannelId
                && $0.title.range(of: pattern, options: .regularExpression) != nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("오늘", value: "시편 \(daily.chapter)편")
                    LabeledContent("채널", value: "공동체성경읽기")
                    LabeledContent("상태", value: status)
                }

                if let match {
                    Section("찾은 영상") {
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
                    }
                } else {
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
                             ? "먼저 채널의 시편 재생목록을 확인합니다(약 3 units). 없으면 해당 채널만 검색합니다(100 units). 남은 검색 \(quota.searchesRemaining)회."
                             : "Google 로그인이 필요합니다.")
                    }
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
            .task { refreshStatus() }
        }
    }

    private func refreshStatus() {
        let cached = allVideos.filter { $0.channelId == DefaultChannels.psalmAudioChannelId }
        let psalmTitled = cached.filter { $0.title.contains("시편") }
        status = match != nil
            ? "영상 있음"
            : "없음 (채널 캐시 \(cached.count)개, 시편 \(psalmTitled.count)개)"
    }

    private func lookUp() async {
        isWorking = true
        status = "재생목록 확인 중…"
        defer { isWorking = false }

        let client = AppServices.client(auth: auth, quota: quota)

        // Free route first: the channel indexes psalms in its own playlist.
        await feed.ingestPsalmPlaylist(context: modelContext, client: client)
        refreshStatus()
        if match != nil { return }

        guard quota.canSearch else {
            status = "검색 예산 소진 (0회 남음)"
            return
        }

        status = "채널 검색 중… (100 units)"
        let found = await feed.findPsalmVideo(
            chapter: daily.chapter, context: modelContext, client: client
        )
        refreshStatus()
        if found == nil {
            status = "이 채널에서 시편 \(daily.chapter)편을 찾지 못했습니다"
        }
    }
}
