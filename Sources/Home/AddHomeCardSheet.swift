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

    @State private var linkInput = ""
    @State private var topicInput = ""
    @State private var playlistPurpose: Purpose = .worship

    private var existingKeys: Set<String> { Set(cards.map(\.dedupeKey)) }

    var body: some View {
        NavigationStack {
            List {
                customSection
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

    // MARK: - Custom

    /// The two cards that do not have to already exist somewhere else: any
    /// YouTube link, and any search term you keep coming back to.
    @ViewBuilder
    private var customSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                TextField("YouTube 영상·재생목록 링크 붙여넣기", text: $linkInput, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)
                if !linkInput.isEmpty, pastedVideoId == nil, pastedPlaylistId == nil {
                    Text("링크를 알아볼 수 없습니다")
                        .font(.caption2).foregroundStyle(.orange)
                }
                HStack {
                    // A shared playlist arrives in a message, so the link is
                    // already on the clipboard by the time this sheet opens.
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        linkInput = text
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)

                    Spacer()
                    if pastedPlaylistId != nil {
                        // Which feed it also belongs on. A shared set is
                        // usually 찬양, so that leads.
                        Picker("", selection: $playlistPurpose) {
                            Text("찬양").tag(Purpose.worship)
                            Text("말씀").tag(Purpose.word)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)

                        Button("재생목록 카드") { addPlaylistCard() }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                    if pastedVideoId != nil {
                        Button("영상 카드") { addVideoCard() }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("검색어, 예: 나는 예배자입니다", text: $topicInput)
                    .font(.footnote)
                HStack {
                    Spacer()
                    Button("주제 카드 추가") { addTopicCard() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .disabled(trimmedTopic.count < 2)
                }
            }
        } header: {
            Text("직접 만들기")
        } footer: {
            Text("영상 카드는 탭하면 바로 재생됩니다. 재생목록은 내 것이 아니어도, 공개 범위가 '일부 공개'여도 링크만 있으면 추가됩니다. 주제 카드는 검색창을 그 검색어로 열어 주며 저장된 결과부터 보여 주므로 units를 쓰지 않습니다.")
        }
    }

    private var pastedVideoId: String? {
        let trimmed = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return YouTubeID.parse(trimmed)
    }

    private var pastedPlaylistId: String? {
        let trimmed = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return YouTubeID.parsePlaylist(trimmed)
    }

    private var trimmedTopic: String {
        topicInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addVideoCard() {
        guard let id = pastedVideoId else { return }
        add(kind: .video, targetId: id, title: "영상")
        linkInput = ""
        Task {
            // Title comes from the API when signed in; the placeholder above
            // means the card is usable the instant it is added either way.
            guard auth.isSignedIn else { return }
            let client = AppServices.client(auth: auth, quota: quota)
            guard let video = try? await client.videos(ids: [id]).first,
                  let title = video.snippet?.title else { return }
            cards.first { $0.dedupeKey == "video-\(id)" }?.title = title
            try? modelContext.save()
        }
    }

    /// Works for a playlist you do not own, which is the point: a church
    /// channel whose uploads are all unlisted has nothing in its public
    /// uploads feed, but an unlisted *playlist* of those uploads is readable
    /// by anyone holding the link.
    private func addPlaylistCard() {
        guard let id = pastedPlaylistId else { return }
        let purpose = playlistPurpose
        // Keep the whole link when it is a collaboration invite: the id alone
        // loses the token that lets a teammate join.
        let raw = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let invite = YouTubeID.isCollaborationInvite(raw) ? raw : nil

        add(kind: .playlist, targetId: id, title: "재생목록")
        pinToFeed(id: id, title: "재생목록", purpose: purpose,
                  thumbnail: nil, count: 0, invite: invite)
        linkInput = ""

        Task {
            guard auth.isSignedIn else { return }
            let client = AppServices.client(auth: auth, quota: quota)
            guard let playlist = try? await client.playlist(id: id) else { return }
            cards.first { $0.dedupeKey == "playlist-\(id)" }?.title = playlist.title
            pinToFeed(
                id: id,
                title: playlist.title,
                purpose: purpose,
                thumbnail: playlist.thumbnailURL?.absoluteString,
                count: playlist.itemCount,
                invite: invite
            )
            try? modelContext.save()
        }
    }

    /// A playlist put on the home screen also belongs on its tab.
    ///
    /// Adding it in one place and having to add it again in another is busy
    /// work — the home card says which playlist matters, and 찬양 or 말씀 is
    /// where you go looking for it later.
    private func pinToFeed(
        id: String,
        title: String,
        purpose: Purpose,
        thumbnail: String?,
        count: Int,
        invite: String?
    ) {
        let existing = (try? modelContext.fetch(FetchDescriptor<CachedPlaylist>())) ?? []
        if let match = existing.first(where: { $0.playlistId == id }) {
            match.purposeRaw = purpose.rawValue
            match.isPinned = true
            if title != "재생목록" { match.title = title }
            if let thumbnail { match.thumbnailURLString = thumbnail }
            if count > 0 { match.itemCount = count }
            if let invite { match.inviteURLString = invite }
        } else {
            let playlist = CachedPlaylist(
                playlistId: id,
                channelId: "",
                title: title,
                thumbnailURLString: thumbnail,
                itemCount: count,
                purpose: purpose,
                isPinned: true,
                inviteURLString: invite
            )
            modelContext.insert(playlist)
        }
        try? modelContext.save()
    }

    private func addTopicCard() {
        let topic = trimmedTopic
        guard topic.count >= 2 else { return }
        add(kind: .topic, targetId: topic, title: topic)
        topicInput = ""
    }

    // MARK: - Sections

    @ViewBuilder
    private var shortcutSection: some View {
        let available = [
            (HomeCardKind.reading, "오늘의 시편", "그날의 시편 · 앞뒤 날짜로 이동"),
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
