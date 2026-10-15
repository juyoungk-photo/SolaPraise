//
//  ExportToPlaylistSheet.swift
//  SolaPraise
//
//  「재생목록으로 내보내기」: a service's 콘티 written out to a YouTube
//  playlist, so the team can listen through the set in YouTube itself.
//
//  Where it goes: the service's own playlist when the Schedule names one;
//  otherwise the one chosen here last, remembered on this device; otherwise
//  the team's 「CCC 찬양콘티」. What will change — songs in, songs out,
//  songs moved — and its quota cost are shown before anything is written
//  (PlaylistExport plans it).
//

import SwiftUI

struct ExportToPlaylistSheet: View {
    let service: TeamService

    @EnvironmentObject private var team: TeamStore
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @Environment(\.dismiss) private var dismiss

    /// The playlist chosen last on this device.
    @AppStorage("conti.exportPlaylist") private var chosenId = ""

    struct Destination: Hashable {
        let id: String
        let title: String
    }

    @State private var destination: Destination?
    @State private var mine: [Destination] = []
    @State private var current: [YTPlaylistItem] = []
    @State private var steps: [PlaylistExport.Step]?
    @State private var working = false
    @State private var message: String?
    @State private var done = false

    /// The team's shared 콘티 playlist, the default.
    private static var teamPlaylist: Destination? {
        DefaultChannels.defaultPlaylists.first { $0.title == "CCC 찬양콘티" }
            .map { Destination(id: $0.playlistId, title: $0.title) }
    }

    /// The 콘티's songs that have a video, in order.
    private var songs: [PlanItem] {
        team.plan(for: service).filter { $0.kind == .song && $0.videoId != nil }
    }

    private var options: [Destination] {
        var out: [Destination] = []
        if let own = service.playlistId { out.append(Destination(id: own, title: "이 예배의 재생목록")) }
        if let team = Self.teamPlaylist { out.append(team) }
        for playlist in mine where !out.contains(where: { $0.id == playlist.id }) { out.append(playlist) }
        if let destination, !out.contains(destination) { out.append(destination) }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("재생목록", selection: $destination) {
                        ForEach(options, id: \.self) { option in
                            Text(option.title).tag(Optional(option))
                        }
                    }
                } footer: {
                    Text("재생목록이 이 예배의 콘티와 같아지도록 곡을 더하고, 빼고, 순서를 맞춥니다. 재생목록을 만든 계정(또는 공동 작업자)으로 로그인해야 바꿀 수 있습니다.")
                }

                Section("바뀌는 것") {
                    if !auth.isSignedIn {
                        Text("YouTube 계정으로 로그인해야 재생목록을 바꿀 수 있습니다.")
                            .foregroundStyle(.secondary)
                    } else if let steps {
                        if steps.isEmpty {
                            Label("이미 콘티와 같습니다", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        } else {
                            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                                describe(step)
                            }
                            Text("YouTube 할당량 \(PlaylistExport.cost(steps)) 사용")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack { ProgressView(); Text("재생목록을 읽는 중…").foregroundStyle(.secondary) }
                    }
                }

                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(done ? Color.green : Color.orange) }
                }
            }
            .navigationTitle("재생목록으로 내보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(done ? "닫기" : "취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("내보내기") { Task { await export() } }
                            .disabled(done || steps?.isEmpty != false || !auth.isSignedIn)
                    }
                }
            }
            .disabled(working)
        }
        .task {
            if destination == nil {
                destination = options.first { $0.id == service.playlistId }
                    ?? options.first { $0.id == chosenId }
                    ?? Self.teamPlaylist
            }
            await loadMine()
        }
        .task(id: destination) { await planFor(destination) }
    }

    @ViewBuilder
    private func describe(_ step: PlaylistExport.Step) -> some View {
        switch step {
        case .remove(let item):
            Label(current.first { $0.id == item }?.snippet?.title ?? "곡", systemImage: "minus.circle")
                .foregroundStyle(.red)
        case .add(let video, let at):
            Label("\(at + 1). \(title(of: video))", systemImage: "plus.circle")
                .foregroundStyle(.green)
        case .move(_, let video, let to):
            Label("\(to + 1). \(title(of: video))", systemImage: "arrow.up.arrow.down.circle")
        }
    }

    private func title(of video: String) -> String {
        songs.first { $0.videoId == video }.map { PlanSongTitle.split($0.title).title } ?? video
    }

    // MARK: - Reading and writing

    private var client: YouTubeAPIClient { AppServices.client(auth: auth, quota: quota) }

    private func loadMine() async {
        guard auth.isSignedIn, let playlists = try? await client.myPlaylists() else { return }
        mine = playlists.map { Destination(id: $0.id, title: $0.snippet?.title ?? $0.id) }
    }

    private func planFor(_ destination: Destination?) async {
        steps = nil
        message = nil
        done = false
        guard let destination, auth.isSignedIn else { return }
        do {
            current = try await client.playlistItems(playlistId: destination.id)
            let present = current.compactMap { item in item.videoId.map { (item: item.id, video: $0) } }
            steps = PlaylistExport.plan(current: present, wanted: songs.compactMap(\.videoId))
        } catch {
            message = "재생목록을 읽지 못했습니다: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func export() async {
        guard let destination, let steps else { return }
        working = true
        defer { working = false }
        var written = 0
        do {
            for step in steps {
                switch step {
                case .remove(let item):
                    try await client.removePlaylistItem(itemId: item)
                case .add(let video, let at):
                    _ = try await client.addVideo(video, to: destination.id, at: at)
                case .move(let item, let video, let to):
                    _ = try await client.movePlaylistItem(itemId: item, playlistId: destination.id, videoId: video, to: to)
                }
                written += 1
            }
            chosenId = destination.id
            done = true
            message = "「\(destination.title)」을(를) 콘티 \(songs.count)곡과 같게 맞췄습니다."
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            message = written == 0
                ? "바꾸지 못했습니다: \(reason) — 재생목록을 만든 계정으로 로그인했는지 확인하세요."
                : "\(written)/\(steps.count) 단계까지 했고 멈췄습니다: \(reason). 다시 열어 남은 것을 이어서 맞추세요."
            // What is there now, so the next press finishes rather than repeats.
            await planFor(destination)
        }
    }
}
