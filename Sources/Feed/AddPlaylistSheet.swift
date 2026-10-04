//
//  AddPlaylistSheet.swift
//  SolaPraise
//
//  Puts any YouTube playlist on a feed, by link.
//
//  A worship playlist often lives on a channel filed under 말씀 — a church
//  posts its sermons and its worship from the same account — so following the
//  channel's purpose is not enough. This pins the playlist itself, wherever it
//  came from, including one that is unlisted: "anyone with the link" applies
//  to the API too.
//

import SwiftUI
import SwiftData

struct AddPlaylistSheet: View {
    let purpose: Purpose

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger

    @State private var link = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var added: String?

    private var playlistId: String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return YouTubeID.parsePlaylist(trimmed)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("youtube.com/playlist?list=… 붙여넣기", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)

                    if !link.isEmpty, playlistId == nil {
                        Text("재생목록 링크를 알아볼 수 없습니다.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("\(purpose.title) 재생목록")
                } footer: {
                    Text("재생목록 주소만 있으면 됩니다. 내 재생목록이 아니어도, 공개 범위가 '일부 공개'여도 추가할 수 있습니다. 약 1 unit.")
                }

                Section {
                    Button {
                        Task { await add() }
                    } label: {
                        HStack {
                            Text("추가")
                            Spacer()
                            if isWorking { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(playlistId == nil || isWorking || !auth.canReadYouTube)

                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(added == nil ? .orange : .green)
                    }
                } footer: {
                    if !auth.canReadYouTube {
                        Text("Google 로그인이 필요합니다.")
                    }
                }
            }
            .navigationTitle("재생목록 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    private func add() async {
        guard let id = playlistId else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        let existing = (try? modelContext.fetch(FetchDescriptor<CachedPlaylist>())) ?? []
        if let match = existing.first(where: { $0.playlistId == id }) {
            // Already known from a channel walk — just file it on this feed.
            match.purposeRaw = purpose.rawValue
            try? modelContext.save()
            added = id
            message = "\(match.title) — \(purpose.title)에 추가했습니다."
            return
        }

        let client = AppServices.client(auth: auth, quota: quota)
        guard let playlist = try? await client.playlist(id: id) else {
            message = "재생목록을 찾을 수 없습니다. 링크와 공개 범위를 확인해 주세요."
            return
        }

        modelContext.insert(CachedPlaylist(
            playlistId: playlist.id,
            channelId: "",
            title: playlist.title,
            thumbnailURLString: playlist.thumbnailURL?.absoluteString,
            itemCount: playlist.itemCount,
            purpose: purpose
        ))
        try? modelContext.save()
        added = id
        link = ""
        message = "\(playlist.title) — \(purpose.title)에 추가했습니다."
    }
}
