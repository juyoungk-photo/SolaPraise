//
//  SongTitleReviewSheet.swift
//  SolaPraise
//
//  재생목록에서 찬양 채우기, before anything is written: each song's title as
//  the 순서 will carry it, to keep, change to another reading of the
//  video's title, or type.
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
    /// The songs to write, with any title chosen here.
    let onSend: ([TeamSong]) -> Void
    let onCancel: () -> Void

    @State private var titles: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        row(index, song)
                    }
                } footer: {
                    Text("영상 제목에서 곡 이름을 골라 적었습니다. 앨범이나 예배 시리즈 이름이 잘못 잡혔으면 「다른 이름」에서 고르거나 직접 고치세요. 원래 영상 제목은 참고버전에 남습니다.")
                }
            }
            .navigationTitle("곡 제목 확인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("\(songs.count)곡 보내기") { onSend(chosen()) }
                        .disabled(titles.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
        }
        .onAppear {
            if titles.isEmpty { titles = songs.map { PlanSongTitle.forSheet($0.title, channel: $0.channel).title } }
        }
    }

    @ViewBuilder
    private func row(_ index: Int, _ song: TeamSong) -> some View {
        if titles.indices.contains(index) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                    TextField("곡 제목", text: $titles[index])
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
                // The video's title as it came, to judge the reading by.
                Text(song.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 30)
            }
            .padding(.vertical, 2)
        }
    }

    /// A title changed here is the song's; one left as read is not marked,
    /// so it is written exactly as before.
    private func chosen() -> [TeamSong] {
        songs.enumerated().map { index, song in
            var song = song
            let title = titles[index].trimmingCharacters(in: .whitespaces)
            if title != PlanSongTitle.forSheet(song.title, channel: song.channel).title { song.chosenTitle = title }
            return song
        }
    }
}
