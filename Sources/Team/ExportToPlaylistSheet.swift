//
//  ExportToPlaylistSheet.swift
//  SolaPraise
//
//  「재생목록으로 내보내기」: a service's 콘티 written out to a YouTube
//  playlist, so the team can listen through the set in YouTube itself.
//
//  Where it goes: the service's own playlist when the Schedule names one;
//  otherwise the one chosen here last, remembered on this device; otherwise
//  the team's 「CCC 찬양콘티」.
//
//  WHAT IS SHOWN IS WHAT IS WRITTEN. The screen is the playlist as it will
//  be — the 콘티's songs and, with 「지금 있는 곡 유지」, the songs already
//  in it after them — and, like 순서 추가 및 조정, it can be dragged into
//  another order and trimmed by a swipe before anything is sent. 내보내기
//  makes the playlist that list, in the fewest writes (PlaylistExport), and
//  says what that costs first.
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
    /// Keep the songs already in the playlist. Remembered, and on unless
    /// turned off: taking songs out of a shared playlist cannot be undone
    /// in YouTube, and the first version, off by default, emptied one.
    @AppStorage("conti.exportKeepsOthers") private var keepsOthers = true
    @State private var confirmingRemoval = false

    struct Destination: Hashable {
        let id: String
        let title: String
    }

    /// One row of the playlist-to-be.
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let video: String
        let title: String
        /// On this service's 콘티, rather than already in the playlist.
        let fromConti: Bool
    }

    @State private var destination: Destination?
    @State private var mine: [Destination] = []
    @State private var current: [YTPlaylistItem] = []
    @State private var entries: [Entry] = []
    @State private var loaded = false
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

    private var present: [(item: String, video: String)] {
        current.compactMap { item in item.videoId.map { (item: item.id, video: $0) } }
    }

    private var steps: [PlaylistExport.Step] {
        PlaylistExport.plan(current: present, wanted: entries.map(\.video))
    }

    var body: some View {
        NavigationStack {
            // The controls above the list, not inside it or in an inset on
            // it: the list is always in edit mode, and anything under that
            // — a switch, a picker — stops answering taps.
            VStack(spacing: 0) {
            controls
            List {
                if !auth.canReadYouTube {
                    EmptyView()
                } else if !loaded {
                    Section {
                        HStack { ProgressView(); Text("재생목록을 읽는 중…").foregroundStyle(.secondary) }
                    }
                } else {
                    Section {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).lineLimit(2)
                                    Text(badge(entry))
                                        .font(.caption2)
                                        .foregroundStyle(entry.fromConti ? Color.accentColor : .secondary)
                                }
                            }
                        }
                        .onMove { from, to in entries.move(fromOffsets: from, toOffset: to) }
                        .onDelete { entries.remove(atOffsets: $0) }
                    } header: {
                        HStack {
                            Text("내보낼 순서 · \(entries.count)곡")
                            Spacer()
                            if let snapshot, snapshot.map(\.video) != present.map(\.video) {
                                // The list as it was before the last export,
                                // to send back.
                                Button("내보내기 전으로") { entries = snapshot }
                                    .font(.caption)
                                    .textCase(nil)
                            }
                            Button("처음대로") { rebuild() }
                                .font(.caption)
                                .textCase(nil)
                        }
                    } footer: {
                        Text(summary)
                    }
                }

                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(done ? Color.green : Color.orange) }
                }
            }
            // Always in edit mode: dragging is what the list is for.
            .environment(\.editMode, .constant(.active))
            }
            .background(Color(.systemGroupedBackground))
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
                        Button("내보내기") {
                            // Asked first whenever a song would come out.
                            if removals > 0 { confirmingRemoval = true } else { Task { await export() } }
                        }
                        .disabled(done || !loaded || steps.isEmpty || !auth.isSignedIn)
                    }
                }
            }
            .disabled(working)
            .confirmationDialog("재생목록에서 \(removals)곡을 지울까요?", isPresented: $confirmingRemoval,
                                titleVisibility: .visible) {
                Button("\(removals)곡 지우고 내보내기", role: .destructive) { Task { await export() } }
                Button("취소", role: .cancel) {}
            } message: {
                Text("목록에 없는 곡은 「\(destination?.title ?? "재생목록")」에서 지워집니다. YouTube에서는 되돌릴 수 없지만, 이 앱이 내보내기 전 목록을 기억해 두어 「내보내기 전으로」로 다시 채울 수 있습니다.")
            }
        }
        .task {
            if destination == nil {
                destination = options.first { $0.id == service.playlistId }
                    ?? options.first { $0.id == chosenId }
                    ?? Self.teamPlaylist
            }
            await loadMine()
        }
        .task(id: destination) { await read(destination) }
        .onChange(of: keepsOthers) { rebuild() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                HStack {
                    Text("재생목록")
                    Spacer()
                    Picker("재생목록", selection: $destination) {
                        ForEach(options, id: \.self) { option in
                            Text(option.title).tag(Optional(option))
                        }
                    }
                    .labelsHidden()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                Divider().padding(.leading, 16)
                Toggle("지금 있는 곡 유지", isOn: $keepsOthers)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            Text((keepsOthers
                  ? "재생목록에 있던 곡은 콘티 뒤에 그대로 남습니다."
                  : "재생목록이 이 콘티만 담도록 다른 곡은 뺍니다.")
                 + " 아래 목록이 그대로 재생목록이 됩니다 — 끌어서 순서를 바꾸고, 왼쪽으로 밀어 빼세요."
                 + (auth.isSignedIn ? "" : " 내보내려면 재생목록을 만든 계정(또는 공동 작업자)으로 로그인하세요."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    private var removals: Int {
        steps.filter { if case .remove = $0 { return true }; return false }.count
    }

    // MARK: - Before each export

    /// The playlist as it was before the last export to it, on this device:
    /// its videos and titles in order. YouTube keeps no undo.
    private static func snapshotKey(_ id: String) -> String { "conti.exportBefore.\(id)" }

    private func saveSnapshot(for destination: Destination) {
        let rows = current.compactMap { item in item.videoId.map { [$0, item.snippet?.title ?? $0] } }
        UserDefaults.standard.set(rows, forKey: Self.snapshotKey(destination.id))
    }

    private var snapshot: [Entry]? {
        guard let id = destination?.id,
              let rows = UserDefaults.standard.array(forKey: Self.snapshotKey(id)) as? [[String]],
              !rows.isEmpty else { return nil }
        return rows.compactMap { row in
            row.count == 2 ? Entry(video: row[0], title: row[1], fromConti: false) : nil
        }
    }

    private func badge(_ entry: Entry) -> String {
        let inPlaylist = present.contains { $0.video == entry.video }
        switch (entry.fromConti, inPlaylist) {
        case (true, true):   return "콘티 · 이미 있음"
        case (true, false):  return "콘티 · 새로 추가"
        case (false, _):     return "재생목록에 있던 곡"
        }
    }

    /// What 내보내기 will do, counted, and its cost.
    private var summary: String {
        let steps = self.steps
        guard !steps.isEmpty else { return "재생목록이 이미 이 목록과 같습니다." }
        let adds = steps.filter { if case .add = $0 { return true }; return false }.count
        let removes = steps.filter { if case .remove = $0 { return true }; return false }.count
        let moves = steps.count - adds - removes
        let parts = [adds > 0 ? "추가 \(adds)" : nil, removes > 0 ? "빼기 \(removes)" : nil,
                     moves > 0 ? "순서 \(moves)" : nil].compactMap { $0 }
        return parts.joined(separator: " · ") + " — YouTube 할당량 \(PlaylistExport.cost(steps)) 사용"
    }

    // MARK: - Reading and writing

    private var client: YouTubeAPIClient { AppServices.client(auth: auth, quota: quota) }

    private func loadMine() async {
        guard auth.isSignedIn, let playlists = try? await client.myPlaylists() else { return }
        mine = playlists.map { Destination(id: $0.id, title: $0.snippet?.title ?? $0.id) }
    }

    private func read(_ destination: Destination?) async {
        loaded = false
        message = nil
        done = false
        guard let destination, auth.canReadYouTube else { return }
        do {
            current = try await client.playlistItems(playlistId: destination.id)
            rebuild()
            loaded = true
        } catch {
            // A read cut off by choosing another playlist is not a failure:
            // its replacement is already on the way.
            guard !Task.isCancelled else { return }
            message = "재생목록을 읽지 못했습니다: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The list as it starts: the 콘티, then — kept — what was there.
    private func rebuild() {
        let conti = songs.compactMap(\.videoId)
        let order = PlaylistExport.startingList(current: present.map(\.video), conti: conti,
                                                keepingOthers: keepsOthers)
        entries = order.map { video in
            if let song = songs.first(where: { $0.videoId == video }) {
                return Entry(video: video, title: PlanSongTitle.split(song.title).title, fromConti: true)
            }
            let title = current.first { $0.videoId == video }?.snippet?.title ?? video
            return Entry(video: video, title: title, fromConti: false)
        }
    }

    private func export() async {
        guard let destination else { return }
        let steps = self.steps
        working = true
        defer { working = false }
        var written = 0
        // Remembered before anything is touched.
        if steps.contains(where: { if case .remove = $0 { return true }; return false }) {
            saveSnapshot(for: destination)
        }
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
            message = "「\(destination.title)」을(를) 이 목록 \(entries.count)곡으로 맞췄습니다."
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            message = written == 0
                ? "바꾸지 못했습니다: \(reason) — 재생목록을 만든 계정으로 로그인했는지 확인하세요."
                : "\(written)/\(steps.count) 단계까지 했고 멈췄습니다: \(reason). 다시 열어 남은 것을 이어서 맞추세요."
            // What is there now, so the next press finishes rather than repeats.
            let wanted = entries
            await read(destination)
            entries = wanted
        }
    }
}
