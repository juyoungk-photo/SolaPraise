//
//  QueueManageSheet.swift
//  SolaPraise
//
//  재생목록 관리: the player's queue in order — drag to move, swipe to take
//  out — like 순서 추가 및 조정.
//
//  The queue changes when 완료 is pressed; the song playing goes on where
//  it now stands. When the queue is a whole YouTube playlist, the new order
//  is saved back to it — on from the start when the playlist is the
//  signed-in account's own, since that is what 관리 on a playlist means:
//  the toggle was off by default, easily missed, and the playlist never
//  changed. Someone else's playlist is changed for this playback only, and
//  the sheet says why (a collaborator may still turn saving on). Each
//  change is a write (PlaylistExport makes it the fewest). Videos the
//  queue never showed — deleted, private — stay in the playlist, after.
//

import SwiftUI

struct QueueManageSheet: View {
    @EnvironmentObject private var host: PlayerHost
    @EnvironmentObject private var auth: GoogleAuthManager
    @Environment(\.quotaLedger) private var quota: QuotaLedger!   // for clients only — see Unobserved
    @Environment(\.dismiss) private var dismiss

    private struct Line: Identifiable {
        let id = UUID()
        let video: PlayableVideo
    }

    @State private var lines: [Line] = []
    @State private var original: [String] = []
    @State private var saveToYouTube = false
    /// The playlist is among the signed-in account's own; nil until known.
    @State private var ownsPlaylist: Bool?
    @State private var saving = false
    @State private var message: String?

    private var changed: Bool { lines.map(\.video.id) != original }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { position, line in
                        HStack(spacing: 10) {
                            if line.video.id == host.current?.id {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).frame(width: 22)
                            } else {
                                Text("\(position + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PlanSongTitle.split(line.video.title).title).lineLimit(2)
                                if let channel = line.video.channelTitle {
                                    Text(channel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onMove { lines.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { lines.remove(atOffsets: $0) }
                } footer: {
                    Text("끌어서 순서를 바꾸고, 왼쪽으로 밀어 빼세요. 「완료」를 누르면 지금 재생 중인 목록에 적용됩니다.")
                }

                if let source = host.source, auth.isSignedIn {
                    Section {
                        Toggle("YouTube 「\(source.title)」에도 저장", isOn: $saveToYouTube)
                    } footer: {
                        Text(ownsPlaylist == false
                             ? "다른 계정이 만든 재생목록이라 이번 재생에만 적용합니다. 이 재생목록의 공동 작업자라면 켜서 YouTube에도 저장할 수 있습니다."
                             : "재생목록 자체의 순서를 바꾸고, 뺀 곡은 재생목록에서도 지웁니다. YouTube에서는 되돌릴 수 없습니다.")
                    }
                    .task {
                        // Its own playlist: saved by default.
                        guard ownsPlaylist == nil else { return }
                        let mine = try? await AppServices.client(auth: auth, quota: quota).myPlaylists()
                        let owns = mine?.contains { $0.id == source.playlistId } ?? false
                        ownsPlaylist = owns
                        if owns { saveToYouTube = true }
                    }
                } else if host.source != nil {
                    Section {
                        Text("YouTube 계정으로 로그인하면 재생목록 자체에도 저장할 수 있습니다. 지금은 이번 재생에만 적용합니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(.orange) }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("재생목록 관리")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("완료") { Task { await apply() } }
                            .disabled(!changed || lines.isEmpty)
                    }
                }
            }
            .disabled(saving)
        }
        .onAppear {
            lines = host.queue.map { Line(video: $0) }
            original = host.queue.map(\.id)
        }
    }

    private func apply() async {
        let arranged = lines.map(\.video)
        if saveToYouTube, let source = host.source {
            saving = true
            defer { saving = false }
            if let failure = await save(arranged.map(\.id), to: source) {
                message = failure
                return
            }
            Toast.shared.show("YouTube 「\(source.title)」에 저장했습니다", symbol: "checkmark.circle.fill", tint: .green)
        }
        host.rearrange(arranged)
        dismiss()
    }

    /// The playlist made the new order, in the fewest writes. What the
    /// queue never held stays, after it.
    private func save(_ order: [String], to source: PlayerHost.QueueSource) async -> String? {
        let client = AppServices.client(auth: auth, quota: quota)
        do {
            let items = try await client.playlistItems(playlistId: source.playlistId)
            let present = items.compactMap { item in item.videoId.map { (item: item.id, video: $0) } }
            let shown = Set(original)
            let unseen = present.map(\.video).filter { !shown.contains($0) && !order.contains($0) }
            for step in PlaylistExport.plan(current: present, wanted: order + unseen) {
                switch step {
                case .remove(let item):
                    try await client.removePlaylistItem(itemId: item)
                case .add(let video, let at):
                    _ = try await client.addVideo(video, to: source.playlistId, at: at)
                case .move(let item, let video, let to):
                    _ = try await client.movePlaylistItem(itemId: item, playlistId: source.playlistId,
                                                          videoId: video, to: to)
                }
            }
            return nil
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return "YouTube 재생목록에 저장하지 못했습니다: \(reason) — 재생목록을 만든 계정으로 로그인했는지 확인하세요."
        }
    }
}
