//
//  MergeSongsView.swift
//  SolaPraise
//
//  곡 합치기: a playlist's songs into a service that already has some. One
//  list — what is there, marked 기존, and what comes in, marked 새 곡 —
//  put in order and trimmed before anything is written.
//
//  WHY: 재생목록에서 찬양 채우기 replaced the service's songs with the
//  playlist's. A leader adding three songs to a 순서 another had begun lost
//  the other's songs without being asked. Now nothing already there goes
//  unless it is taken out here, and a song already in the 순서 is not
//  added twice. Songs kept are written back as their rows were.
//

import SwiftUI

struct MergeSongsView: View {
    let existing: [TeamSong]
    let incoming: [TeamSong]
    let onSend: ([TeamSong]) -> Void

    private struct Line: Identifiable {
        /// 「old-2」, 「new-0」: by position in what came, so a line taken
        /// out stays out when the placement changes.
        let id: String
        let song: TeamSong
        let isNew: Bool
    }

    enum Placement: String, CaseIterable, Identifiable {
        case after = "기존 곡 뒤에", before = "기존 곡 앞에"
        var id: String { rawValue }
    }

    @State private var placement: Placement = .after
    @State private var lines: [Line] = []
    @State private var removed: Set<String> = []
    @State private var started = false

    /// New songs the 순서 already has — by video, else by title.
    private var duplicates: [TeamSong] {
        incoming.filter(isAlreadyThere)
    }

    private func isAlreadyThere(_ song: TeamSong) -> Bool {
        existing.contains { old in
            (old.videoId != nil && old.videoId == song.videoId)
                || PlanSongTitle.sameSong(old.title, song.chosenTitle ?? song.title)
        }
    }

    var body: some View {
        // The picker outside the list: in a list held in edit mode, a
        // control in a row does not take taps.
        VStack(spacing: 0) {
            Picker("새 곡 위치", selection: $placement) {
                ForEach(Placement.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .onChange(of: placement) { _, _ in arrange() }

            List {
                Section {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { position, line in
                        HStack(spacing: 10) {
                            Text("\(position + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(line.song)).lineLimit(2)
                                Text(line.isNew ? "새 곡" : "기존")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(line.isNew ? Color.accentColor : .secondary)
                            }
                            Spacer(minLength: 0)
                            if let key = line.song.key, !key.isEmpty {
                                Text(key).font(.subheadline.weight(.bold)).foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .onMove { lines.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        for offset in offsets { removed.insert(lines[offset].id) }
                        lines.remove(atOffsets: offsets)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("끌어서 순서를 바꾸고, 왼쪽으로 밀어 빼세요. 기존 곡은 빼지 않는 한 그대로 남고, 시트의 그 줄도 그대로 옮겨집니다.")
                        if !duplicates.isEmpty {
                            Text("이미 순서에 있는 \(duplicates.count)곡은 두 번 넣지 않았습니다: "
                                 + duplicates.map(title).joined(separator: ", "))
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
        }
        .navigationTitle("곡 합치기")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("\(lines.count)곡 보내기") { onSend(merged()) }
                    .disabled(lines.isEmpty)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            arrange()
        }
    }

    private func title(_ song: TeamSong) -> String {
        song.chosenTitle ?? PlanSongTitle.split(song.title, channel: song.channel).title
    }

    /// Existing and new, the new where the picker says; what was taken out
    /// stays out.
    private func arrange() {
        let old = existing.enumerated().map { Line(id: "old-\($0.offset)", song: $0.element, isNew: false) }
        let new = incoming.enumerated().filter { !isAlreadyThere($0.element) }
            .map { Line(id: "new-\($0.offset)", song: $0.element, isNew: true) }
        lines = (placement == .after ? old + new : new + old).filter { !removed.contains($0.id) }
    }

    /// The list as it stands, numbered again.
    private func merged() -> [TeamSong] {
        lines.enumerated().map { position, line in
            let song = line.song
            var out = TeamSong(order: position + 1, title: song.title, url: song.url, key: song.key,
                               transpose: song.transpose, notes: song.notes, channel: song.channel,
                               chosenTitle: song.chosenTitle)
            out.sheetRow = song.sheetRow
            return out
        }
    }
}
