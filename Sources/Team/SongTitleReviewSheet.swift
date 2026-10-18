//
//  SongTitleReviewSheet.swift
//  SolaPraise
//
//  재생목록에서 찬양 채우기, before anything is written: which of the
//  playlist's songs to take — a playlist is often longer than one Sunday —
//  and each song's title as the 순서 will carry it, to keep, change to
//  another reading of the video's title, or type.
//
//  WHY: the title is read out of the video's — and a video's title often
//  leads with an album or a worship series, which the reading cannot
//  always tell from the song. Written straight to the sheet, a wrong one
//  was the team's to find and fix there. Here it is one tap.
//

import SwiftUI

struct SongTitleReviewSheet: View {
    let playlistTitle: String
    let songs: [TeamSong]
    /// The title said for a song's video before — chosen here, or on the
    /// team's sheet. It is where the title starts.
    var remembered: (TeamSong) -> String? = { _ in nil }
    /// The songs to write, with any title chosen here.
    let onSend: ([TeamSong]) -> Void
    let onCancel: () -> Void

    @State private var titles: [String] = []
    /// The songs taken, by position. All, until some are left out.
    @State private var taken: Set<Int> = []
    @State private var started = false

    private var count: Int { taken.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        row(index, song)
                    }
                } header: {
                    HStack {
                        Text("\(songs.count)곡 중 \(count)곡")
                        Spacer()
                        Button(count == songs.count ? "모두 빼기" : "모두 넣기") {
                            taken = count == songs.count ? [] : Set(songs.indices)
                        }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                    }
                } footer: {
                    Text("넣을 곡만 체크하세요. 체크한 곡이 그 순서대로 들어가고, 보내면 이 예배의 Songs 목록이 이 곡들로 바뀝니다. 영상 제목에서 곡 이름을 골라 적었습니다 — 앨범이나 예배 시리즈 이름이 잘못 잡혔으면 「다른 이름」에서 고르거나 직접 고치세요. 원래 영상 제목은 참고버전에 남습니다.")
                }
            }
            .navigationTitle("곡 제목 확인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("\(count)곡 보내기") { onSend(chosen()) }
                        .disabled(count == 0 || taken.contains { titles[$0].trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            titles = songs.map { remembered($0) ?? PlanSongTitle.forSheet($0.title, channel: $0.channel).title }
            taken = Set(songs.indices)
        }
    }

    @ViewBuilder
    private func row(_ index: Int, _ song: TeamSong) -> some View {
        if titles.indices.contains(index) {
            let isTaken = taken.contains(index)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        if isTaken { taken.remove(index) } else { taken.insert(index) }
                    } label: {
                        Image(systemName: isTaken ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isTaken ? Color.accentColor : .secondary)
                            .frame(width: 28)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isTaken ? "\(titles[index]) 빼기" : "\(titles[index]) 넣기")
                    TextField("곡 제목", text: $titles[index])
                        .foregroundStyle(isTaken ? .primary : .secondary)
                        .font(.body.weight(.semibold))
                        .textInputAutocapitalization(.never)
                    let options = PlanSongTitle.candidates(song.title, channel: song.channel)
                        .filter { $0 != titles[index] }
                    if !options.isEmpty {
                        Menu {
                            ForEach(options, id: \.self) { option in
                                Button(option) { titles[index] = option }
                            }
                        } label: {
                            Text("다른 이름")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        .menuOrder(.fixed)
                        .buttonStyle(.borderless)
                    }
                }
                // Said before for this video, so not a fresh guess.
                if let before = remembered(song), before == titles[index],
                   before != PlanSongTitle.forSheet(song.title, channel: song.channel).title {
                    Label("지난번에 정한 이름", systemImage: "clock.arrow.circlepath")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, 36)
                }
                // The video's title as it came, to judge the reading by.
                Text(song.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 36)
            }
            .padding(.vertical, 2)
        }
    }

    /// The songs taken, numbered again in the playlist's order. A title
    /// changed here is the song's; one left as read is not marked, so it is
    /// written exactly as before.
    private func chosen() -> [TeamSong] {
        songs.indices.filter(taken.contains).enumerated().map { position, index in
            let song = songs[index]
            let title = titles[index].trimmingCharacters(in: .whitespaces)
            let changed = title != PlanSongTitle.forSheet(song.title, channel: song.channel).title
            // Kept by video, for the player's searches and the rest
            // (SongTitleChoices); a title put back as read forgets it.
            if let id = song.videoId { SongTitleChoices.set(changed ? title : nil, for: id) }
            return TeamSong(order: position + 1, title: song.title, url: song.url, key: song.key,
                            transpose: song.transpose, notes: song.notes, channel: song.channel,
                            chosenTitle: changed ? title : nil)
        }
    }
}
