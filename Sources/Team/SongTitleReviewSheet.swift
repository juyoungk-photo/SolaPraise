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
    /// The service's songs already on the sheet. When there are any, the
    /// next step is 곡 합치기 — never replacing them unasked.
    var existing: [TeamSong] = []
    @State private var merging = false
    /// The songs to merge, as they stood when 다음 was pressed.
    @State private var incoming: [TeamSong] = []
    /// The songs to write, with any title chosen here.
    let onSend: ([TeamSong]) -> Void
    let onCancel: () -> Void

    @State private var titles: [String] = []
    /// Each song's title read every way, once: reading a video's title is
    /// regular expressions over it, and the rows are drawn again on every
    /// keystroke and check — for a playlist of a few hundred, read again
    /// each time, the screen never finished drawing.
    @State private var readings: [Reading] = []
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
                    Text(existing.isEmpty
                         ? "넣을 곡만 체크하세요. 체크한 곡이 그 순서대로 들어갑니다. "
                         : "넣을 곡만 체크하세요. 이 예배에 이미 \(existing.count)곡이 있어, 다음 화면에서 어떻게 합칠지 정합니다. ") + Text("영상 제목에서 곡 이름을 골라 적었습니다 — 앨범이나 예배 시리즈 이름이 잘못 잡혔으면 「다른 이름」에서 고르거나 직접 고치세요. 원래 영상 제목은 참고버전에 남습니다.")
                }
            }
            .navigationDestination(isPresented: $merging) {
                MergeSongsView(existing: existing, incoming: incoming, onSend: onSend)
            }
            .navigationTitle("곡 제목 확인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing.isEmpty ? "\(count)곡 보내기" : "다음") {
                        let songs = chosen()
                        remember(songs)
                        if existing.isEmpty { onSend(songs) } else { incoming = songs; merging = true }
                    }
                    .disabled(count == 0 || taken.contains { titles[$0].trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            readings = songs.map { song in
                Reading(fresh: PlanSongTitle.forSheet(song.title, channel: song.channel).title,
                        remembered: remembered(song),
                        options: PlanSongTitle.candidates(song.title, channel: song.channel))
            }
            titles = readings.map { $0.remembered ?? $0.fresh }
            taken = Set(songs.indices)
        }
    }

    @ViewBuilder
    private func row(_ index: Int, _ song: TeamSong) -> some View {
        if titles.indices.contains(index), readings.indices.contains(index) {
            let reading = readings[index]
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
                    let options = reading.options.filter { $0 != titles[index] }
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
                if let before = reading.remembered, before == titles[index], before != reading.fresh {
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
    ///
    /// Reads only: it once kept each title as it went, from inside the
    /// view's body — a write to UserDefaults that redrew the screen, which
    /// ran it again, and the app froze on 재생목록에서 찬양 채우기.
    private func chosen() -> [TeamSong] {
        songs.indices.filter(taken.contains).enumerated().map { position, index in
            let song = songs[index]
            let title = titles[index].trimmingCharacters(in: .whitespaces)
            let fresh = readings.indices.contains(index) ? readings[index].fresh
                : PlanSongTitle.forSheet(song.title, channel: song.channel).title
            let changed = title != fresh
            return TeamSong(order: position + 1, title: song.title, url: song.url, key: song.key,
                            transpose: song.transpose, notes: song.notes, channel: song.channel,
                            chosenTitle: changed ? title : nil)
        }
    }

    /// Kept by video, for the player's searches and the rest
    /// (SongTitleChoices); a title put back as read forgets it. Once, when
    /// the songs are sent on.
    private func remember(_ songs: [TeamSong]) {
        for song in songs {
            guard let id = song.videoId else { continue }
            SongTitleChoices.set(song.chosenTitle, for: id)
        }
    }

    struct Reading {
        /// The title as read out of the video's.
        let fresh: String
        /// The title said for it before, here or on the sheet.
        let remembered: String?
        /// Other readings, for 「다른 이름」.
        let options: [String]
    }
}
