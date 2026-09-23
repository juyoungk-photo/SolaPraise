//
//  AddHomeCardSheet.swift
//  SolaPraise
//
//  Picks what to put on the home screen. Only things that already exist —
//  your channels, your playlists — so a card can never point at nothing.
//

import SwiftUI
import SwiftData

struct AddHomeCardSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger

    @Query private var cards: [HomeCard]
    @Query(sort: [SortDescriptor(\Channel.sortOrder), SortDescriptor(\Channel.addedAt)])
    private var channels: [Channel]

    @StateObject private var playlists = LoadState<[YTPlaylist]>()

    private var existingKeys: Set<String> { Set(cards.map(\.dedupeKey)) }

    var body: some View {
        NavigationStack {
            List {
                shortcutSection
                channelSection
                playlistSection
            }
            .navigationTitle("카드 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .task {
                guard auth.isSignedIn, playlists.value == nil else { return }
                let client = AppServices.client(auth: auth, quota: quota)
                await playlists.run { try await client.myPlaylists() }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var shortcutSection: some View {
        let available = [
            (HomeCardKind.reading, "시편", "오늘의 말씀"),
            (HomeCardKind.search, "검색", "찬양·말씀 검색")
        ].filter { !existingKeys.contains("\($0.0.rawValue)--") }

        if !available.isEmpty {
            Section("바로가기") {
                ForEach(available, id: \.0) { kind, title, detail in
                    Button {
                        add(kind: kind, targetId: nil, title: title)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title).foregroundStyle(.primary)
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: kind.symbolName)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var channelSection: some View {
        let available = channels.filter { !existingKeys.contains("channel-\($0.youtubeChannelId)") }

        Section {
            if channels.isEmpty {
                Text("먼저 설정에서 채널을 추가하세요. 코너스톤교회, 매일성경 같은 채널 주소를 붙여넣으면 됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if available.isEmpty {
                Text("모든 채널이 이미 홈에 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(available) { channel in
                    Button {
                        add(kind: .channel, targetId: channel.youtubeChannelId, title: channel.title)
                    } label: {
                        Label(channel.title, systemImage: channel.purpose.symbolName)
                            .foregroundStyle(.primary)
                    }
                }
            }
        } header: {
            Text("채널")
        }
    }

    @ViewBuilder
    private var playlistSection: some View {
        Section {
            if !auth.isSignedIn {
                Text("플레이리스트 카드를 추가하려면 Google 로그인이 필요합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if playlists.isLoading {
                HStack { ProgressView().controlSize(.small); Text("불러오는 중…") }
            } else if let message = playlists.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.orange)
            } else {
                let available = (playlists.value ?? [])
                    .filter { !existingKeys.contains("playlist-\($0.id)") }
                if available.isEmpty {
                    Text("추가할 플레이리스트가 없습니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(available) { playlist in
                        Button {
                            add(kind: .playlist, targetId: playlist.id, title: playlist.title)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.title).foregroundStyle(.primary)
                                    Text("^[\(playlist.itemCount) video](inflect: true)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "music.note.list")
                            }
                        }
                    }
                }
            }
        } header: {
            Text("플레이리스트")
        }
    }

    // MARK: - Add

    private func add(kind: HomeCardKind, targetId: String?, title: String) {
        let nextOrder = (cards.map(\.sortOrder).max() ?? 0) + 1
        modelContext.insert(HomeCard(kind: kind, targetId: targetId, title: title, sortOrder: nextOrder))
        try? modelContext.save()
    }
}
