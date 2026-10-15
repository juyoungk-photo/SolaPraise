//
//  MorningPlayback.swift
//  SolaPraise
//
//  Starts the morning: finds 모닝워십 live, or loads the chosen playlist,
//  and plays it — waiting, visibly, while the stream has not started.
//
//  App level, so it survives whichever tab the app opens on.
//

import SwiftUI

@MainActor
final class MorningPlayback: ObservableObject {

    enum Phase: Equatable {
        case idle
        case finding
        /// No stream yet; looking again every `pollInterval`.
        case waiting(since: Date)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?
    private let pollInterval: UInt64 = 30

    func start(host: PlayerHost, client: YouTubeAPIClient) {
        cancel()
        let content = MorningAlarm.content
        task = Task { [weak self] in
            guard let self else { return }
            switch content {
            case .morningWorship:
                await self.playMorningWorship(host: host, client: client)
            case let .playlist(id, title):
                await self.playPlaylist(id: id, title: title, host: host, client: client)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// While waiting: give up on the stream and play the latest service.
    func playRecentNow(host: PlayerHost, client: YouTubeAPIClient) {
        cancel()
        phase = .finding
        task = Task { [weak self] in
            guard let self else { return }
            let candidates = (try? await self.candidates(client: client)) ?? []
            guard !Task.isCancelled else { return }
            if let id = MorningWorshipPick.recent(in: candidates.map(\.pick)),
               let video = candidates.first(where: { $0.pick.id == id }) {
                self.phase = .idle
                host.play(queue: [video.playable], purpose: .word)
            } else {
                self.phase = .failed("지난 모닝워십을 찾지 못했습니다.")
            }
        }
    }

    // MARK: - 모닝워십

    private func playMorningWorship(host: PlayerHost, client: YouTubeAPIClient) async {
        phase = .finding
        let since = Date()
        while !Task.isCancelled {
            let candidates: [Found]
            do {
                candidates = try await self.candidates(client: client)
            } catch {
                phase = .failed("모닝워십을 확인하지 못했습니다. 네트워크를 확인하세요.")
                return
            }
            switch MorningWorshipPick.decide(candidates.map(\.pick), waitingSince: since) {
            case let .live(id), let .recent(id):
                guard let video = candidates.first(where: { $0.pick.id == id }) else { return }
                phase = .idle
                host.play(queue: [video.playable], purpose: .word)
                return
            case .wait:
                phase = .waiting(since: since)
                try? await Task.sleep(nanoseconds: pollInterval * 1_000_000_000)
            case .nothing:
                phase = .failed("모닝워십 영상이 없습니다.")
                return
            }
        }
    }

    private struct Found {
        let pick: MorningWorshipPick.Candidate
        let playable: PlayableVideo
    }

    /// The channel's newest uploads and streams, with their live state:
    /// two playlist reads and one videos.list — 3 units a look.
    private func candidates(client: YouTubeAPIClient) async throws -> [Found] {
        let channel = MorningAlarm.worshipChannelId
        let suffix = String(channel.dropFirst(2))
        var ids: [String] = []
        for playlist in ["UULV" + suffix, "UU" + suffix] {
            let items = (try? await client.recentPlaylistItems(playlistId: playlist, pages: 1)) ?? []
            for item in items.prefix(10) {
                if let id = item.videoId, !ids.contains(id) { ids.append(id) }
            }
        }
        guard !ids.isEmpty else { throw URLError(.cannotLoadFromNetwork) }
        let videos = try await client.videos(ids: ids)
        return videos.map { video in
            Found(pick: .init(id: video.id, title: video.snippet?.title ?? "",
                              broadcast: video.snippet?.liveBroadcastContent ?? "none",
                              publishedAt: video.snippet?.publishedAt),
                  playable: PlayableVideo(id: video.id, title: video.snippet?.title ?? "모닝워십",
                                          channelTitle: video.snippet?.channelTitle,
                                          durationSeconds: video.durationSeconds,
                                          publishedAt: video.snippet?.publishedAt,
                                          channelId: video.snippet?.channelId))
        }
    }

    // MARK: - Playlist

    private func playPlaylist(id: String, title: String, host: PlayerHost, client: YouTubeAPIClient) async {
        phase = .finding
        do {
            let items = try await client.playlistItems(playlistId: id)
            let queue = items.compactMap { $0.isUnavailable ? nil : PlayableVideo(item: $0) }
            guard !Task.isCancelled else { return }
            guard !queue.isEmpty else { phase = .failed("\(title): 재생할 수 있는 곡이 없습니다."); return }
            phase = .idle
            host.play(queue: queue, purpose: .worship, curated: true)
        } catch {
            phase = .failed("\(title)을(를) 불러오지 못했습니다.")
        }
    }
}

// MARK: - Banner

/// Shown while the morning is starting and the stream has not: what is
/// happening, and a way out of it.
struct MorningPlaybackBanner: View {
    @EnvironmentObject private var morning: MorningPlayback
    @EnvironmentObject private var host: PlayerHost
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger

    var body: some View {
        if morning.phase != .idle {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "sunrise.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline.weight(.semibold))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if morning.phase == .finding { ProgressView() }
                }
                HStack {
                    if case .waiting = morning.phase {
                        Button("지난 모닝워십 보기") {
                            morning.playRecentNow(host: host, client: AppServices.client(auth: auth, quota: quota))
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button(isFailure ? "닫기" : "취소") { morning.cancel() }
                        .buttonStyle(.bordered)
                }
                .font(.subheadline)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
            .frame(maxWidth: 560)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var isFailure: Bool {
        if case .failed = morning.phase { return true }
        return false
    }

    private var title: String {
        switch morning.phase {
        case .idle, .finding: return MorningAlarm.content.label + " 준비 중"
        case .waiting: return "모닝워십 라이브를 기다리는 중"
        case .failed: return "아침 예배를 틀지 못했습니다"
        }
    }

    private var detail: String {
        switch morning.phase {
        case .idle, .finding: return "잠시만 기다리세요."
        case let .waiting(since):
            let until = since.addingTimeInterval(MorningWorshipPick.longestWait)
            return "시작되면 바로 재생합니다. \(until.formatted(date: .omitted, time: .shortened))까지 시작하지 않으면 가장 최근 모닝워십을 틉니다."
        case let .failed(message): return message
        }
    }
}
