//
//  ChannelDetailView.swift
//  SolaPraise
//
//  One channel's own page: its playlists and its recent videos.
//
//  Used from 보관함, where channels that are neither 말씀 nor 찬양 live —
//  교제 content like 코너스톤TV that is worth keeping but should not clutter
//  the two purpose feeds.
//

import SwiftUI
import SwiftData

struct ChannelDetailView: View {
    let channel: Channel

    @EnvironmentObject private var host: PlayerHost
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @EnvironmentObject private var planning: PlanningAuth
    @EnvironmentObject private var channelManager: ChannelManagerAuth
    @StateObject private var feed = FeedStore()

    @Query(sort: [SortDescriptor(\CachedVideo.publishedAt, order: .reverse)])
    private var allVideos: [CachedVideo]

    @Query private var allPlaylists: [CachedPlaylist]
    @State private var isLoadingPlaylist = false
    /// The shared list holds a sealed part this device cannot open.
    @State private var listLocked = SharedChannelList.isLocked
    @State private var showsPublishing = false
    @State private var managesChannel = false
    @State private var errorMessage: String?
    /// The year chip chosen over the playlists; nil shows the newest.
    @State private var year: Int?

    private var videos: [CachedVideo] {
        allVideos.filter { $0.channelId == channel.youtubeChannelId }
    }
    private var playlists: [CachedPlaylist] {
        allPlaylists.filter { $0.channelId == channel.youtubeChannelId }
    }

    private var columns: [GridItem] { FeedGrid.columns }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // The church's list is sealed and this device cannot open it
                // yet: say so where the missing services would be.
                if channel.purpose == .fellowship, listLocked {
                    ChurchPasswordCard { await refresh() } isStillLocked: { SharedChannelList.isLocked }
                        .padding(.horizontal, 16)
                }

                // Playlists first: a channel like this one keeps its
                // services as playlists, and its recent uploads come second.
                if !playlists.isEmpty { playlistSection }

                if videos.isEmpty && playlists.isEmpty {
                    ContentUnavailableView(
                        "볼 수 있는 영상이 없습니다",
                        systemImage: "play.slash",
                        description: Text(emptyExplanation)
                    )
                    .padding(.top, 40)
                } else if !videos.isEmpty {
                    Text("최근 영상")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(videos.prefix(30)) { video in
                            Button { play(video) } label: { VideoCard(video: video) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if isLoadingPlaylist {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("불러오는 중…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }

                FeedEndMarker(refreshedAt: feed.lastRefreshedAt)
            }
            .padding(.top, 12)
        }
        .navigationTitle(channel.shortTitle)
        .navigationBarTitleDisplayMode(.inline)
        // The manager's card, one tap from the top. It used to sit at the
        // bottom of the page, under every recent video — on a channel that
        // shows thirty of them nobody scrolled that far, and it read as
        // missing. Only for an account YouTube says manages this channel;
        // that account is connected in 설정 › 계정.
        .toolbar {
            if managesChannel || showsCardForReview {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsPublishing = true } label: {
                        Label("멤버 공유", systemImage: SharedListPublisher.isOn(for: channel.youtubeChannelId)
                              ? "person.2.wave.2.fill" : "person.2.wave.2")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .sheet(isPresented: $showsPublishing) {
            NavigationStack {
                ScrollView {
                    SharedListPublishCard(channelId: channel.youtubeChannelId)
                        .padding(16)
                }
                .navigationTitle("멤버에게 공유")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료") { showsPublishing = false }
                    }
                }
            }
        }
        .refreshable { await refresh() }
        .task { if videos.isEmpty { await refresh() } }
        .task(id: channelManager.isSignedIn || auth.isSignedIn) {
            managesChannel = SharedListPublisher.knownManagedChannels.contains(channel.youtubeChannelId)
            guard channelManager.isSignedIn || auth.isSignedIn else { managesChannel = false; return }
            managesChannel = await SharedListPublisher.managedChannels(auth: auth, quota: quota, manager: channelManager)
                .contains(channel.youtubeChannelId)
        }
    }

    /// -uiTestPublishCard: the manager's card, for layout review signed out.
    private var showsCardForReview: Bool {
        #if DEBUG
        return DebugHarness.args.contains("-uiTestPublishCard")
        #else
        return false
        #endif
    }

    /// Why a channel shows nothing — usually that it has nothing public.
    /// A church channel posts its services 일부 공개 (unlisted), and YouTube
    /// lists those only to an account that manages the channel; everyone
    /// else sees an empty channel. A playlist of them, shared by link, is
    /// what anyone can watch without signing in.
    private var emptyExplanation: String {
        "이 채널에는 공개된 영상이 없습니다. '일부 공개' 영상은 채널을 관리하는 계정으로 로그인했을 때만 보입니다. "
            + "교회 공유 폴더의 「관심 채널」 시트에 링크가 올라오면, 로그인 없이도 다음 새로고침 때 여기에 나타납니다. "
            + "채널을 관리하는 분은 설정 › 계정에서 「채널 관리 계정」을 연결하면, 이 페이지 오른쪽 위에 멤버 공유 메뉴가 나타납니다."
    }

    // MARK: - Playlists

    /// Cards with artwork, then a way through to all of them.
    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                ChannelPlaylistsView(
                    channel: channel,
                    playlists: playlists,
                    onSelect: { playlist in Task { await play(playlist) } },
                    onPinChanged: { try? modelContext.save() }
                )
            } label: {
                HStack(spacing: 6) {
                    Text("재생목록")
                        .font(.subheadline.weight(.semibold))
                    Text("\(playlists.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if playlists.count > Self.playlistPreviewCount {
                        Text("전체 보기").font(.caption)
                    }
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)

            if !years.isEmpty { yearChips }
            if let year, gridPlaylists.isEmpty {
                Text("\(String(year))년 재생목록이 없습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }

            // Top-aligned: a one-line title must not push its card down
            // beside a two-line one.
            LazyVGrid(columns: columns.map { var column = $0; column.alignment = .top; return column }, spacing: 16) {
                ForEach(gridPlaylists) { playlist in
                    Button { Task { await play(playlist) } } label: {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        PlaylistPinButton(playlist: playlist, purpose: channel.purpose) {
                            try? modelContext.save()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Years

    private var years: [Int] {
        PlaylistYears.chips(playlists.map { ($0.title, $0.publishedAt) })
    }

    /// The church's own 「2026」 playlist, if it keeps one.
    private func yearPlaylist(_ year: Int) -> CachedPlaylist? {
        playlists.first { PlaylistYears.yearOnly($0.title) == year }
    }

    /// Years as filters over the playlists. A year playlist is not a card
    /// among the services it collects; it is reached from its chip's menu.
    private var yearChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "최근", isSelected: year == nil) { year = nil }
                ForEach(years, id: \.self) { candidate in
                    FilterChip(title: String(candidate), isSelected: year == candidate) {
                        year = year == candidate ? nil : candidate
                    }
                    .contextMenu {
                        if let playlist = yearPlaylist(candidate) {
                            Button { Task { await play(playlist) } } label: {
                                Label("「\(playlist.title)」 재생목록 재생", systemImage: "play.fill")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// The newest few, or every playlist of the chosen year.
    private var gridPlaylists: [CachedPlaylist] {
        let services = shownPlaylists.filter { years.isEmpty || PlaylistYears.yearOnly($0.title) == nil }
        guard let year else { return Array(services.prefix(Self.playlistPreviewCount)) }
        return services.filter { PlaylistYears.year(title: $0.title, publishedAt: $0.publishedAt) == year }
    }

    /// Pinned first, then the newest.
    private var shownPlaylists: [CachedPlaylist] {
        playlists.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast)
        }
    }

    /// As many as fill two rows of the grid.
    private static let playlistPreviewCount = 6

    // MARK: - Actions

    private func play(_ video: CachedVideo) {
        let queue = videos.prefix(30).map {
            PlayableVideo(cached: $0)
        }
        let start = queue.firstIndex { $0.id == video.videoId } ?? 0
        host.play(queue: Array(queue), startIndex: start)
    }

    private func play(_ playlist: CachedPlaylist) async {
        guard auth.canReadYouTube else {
            errorMessage = "재생목록을 열려면 Google 로그인이 필요합니다."
            return
        }
        isLoadingPlaylist = true
        errorMessage = nil
        defer { isLoadingPlaylist = false }

        let client = AppServices.client(auth: auth, quota: quota)
        do {
            let items = try await client.playlistItems(playlistId: playlist.playlistId)
            let queue = items.compactMap { item -> PlayableVideo? in
                guard !item.isUnavailable else { return nil }
                return PlayableVideo(item: item)
            }
            guard !queue.isEmpty else {
                errorMessage = "재생할 수 있는 영상이 없습니다."
                return
            }
            host.play(queue: queue, startIndex: 0, curated: true)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func refresh() async {
        let client = auth.canReadYouTube ? AppServices.client(auth: auth, quota: quota) : nil
        await feed.refresh(purpose: channel.purpose, context: modelContext, client: client)
        listLocked = SharedChannelList.isLocked
    }
}

// MARK: - Playlist bar

/// The preview form: one full-width line, no artwork.
///
/// A playlist's thumbnail is the first video's frame, which for a 말씀 channel
/// is a title card that looks like every other title card on that channel. It
/// took a third of the width to say nothing, and squeezed the one thing that
/// does identify a playlist — its name — into two cramped lines. A wide bar
/// gives the name the room instead.
struct PlaylistBar: View {
    let playlist: CachedPlaylist

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: playlist.isCollaborative
                  ? "person.2.fill"
                  : (playlist.isPinned ? "pin.fill" : "list.bullet.rectangle.portrait"))
                .font(.caption)
                .foregroundStyle(.tint)

            Text(playlist.title)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(Color.primary)

            // YouTube generates one of these per channel and fills it with
            // every stream the channel has ever run, so what is in it is the
            // service as it happened rather than anything anyone curated.
            // Worth saying, because "주일 2부예배" reads like a set list.
            if playlist.isLiveArchive {
                badge("실황", .red)
            } else if playlist.isAutoCollected {
                // Not the church's playlist: the app's filter over that
                // channel's uploads. The channel has no standing 주일 설교
                // list, so this is assembled rather than published.
                badge("자동 모음", .secondary)
            }

            Spacer(minLength: 8)

            // Zero means "not fetched yet", not "empty" — a pinned link
            // starts that way — so it shows nothing rather than a 0 that
            // reads as an empty playlist.
            if playlist.itemCount > 0 {
                Text("\(playlist.itemCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "play.circle.fill")
                .font(.body)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - Playlist row

/// The full-list form, where artwork earns its place: you are scanning dozens
/// and a frame is another way to recognise one. Named for the channel page
/// because 보관함 has its own row for YTPlaylist.
struct ChannelPlaylistRow: View {
    let playlist: CachedPlaylist

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: playlist.thumbnailURL, width: 72, height: 41)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if playlist.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                    Text(playlist.title)
                        .font(.footnote)
                        .lineLimit(2)
                        .foregroundStyle(Color.primary)
                }
                Text("^[\(playlist.itemCount) video](inflect: true)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

// MARK: - All playlists

/// Every playlist on one channel. A list, not a sideways strip: some church
/// channels run to dozens, and the only way to find one among them is to
/// scroll the way lists scroll and to search.
struct ChannelPlaylistsView: View {
    let channel: Channel
    let playlists: [CachedPlaylist]
    let onSelect: (CachedPlaylist) -> Void
    var onPinChanged: (() -> Void)? = nil

    @State private var searchText = ""
    @State private var year: Int?

    private var years: [Int] { PlaylistYears.chips(playlists.map { ($0.title, $0.publishedAt) }) }

    private var shown: [CachedPlaylist] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var list = playlists
        if let year {
            list = list.filter { PlaylistYears.year(title: $0.title, publishedAt: $0.publishedAt) == year }
        }
        guard !needle.isEmpty else { return list }
        return list.filter { $0.title.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            // The same years as the channel page, as filters.
            if !years.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: "전체", isSelected: year == nil) { year = nil }
                        ForEach(years, id: \.self) { candidate in
                            FilterChip(title: String(candidate), isSelected: year == candidate) {
                                year = year == candidate ? nil : candidate
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(shown) { playlist in
                    HStack(spacing: 10) {
                        Button { onSelect(playlist) } label: { ChannelPlaylistRow(playlist: playlist) }
                            .buttonStyle(.plain)
                        // In plain sight: a pin hidden in a long-press menu
                        // was a feature nobody found.
                        Button {
                            togglePin(playlist)
                        } label: {
                            Image(systemName: playlist.isPinned ? "pin.fill" : "pin")
                                .font(.body)
                                .foregroundStyle(playlist.isPinned ? Color.accentColor : Color.secondary)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playlist.isPinned ? "고정 해제" : "고정")
                    }
                    .swipeActions(edge: .trailing) {
                        Button { togglePin(playlist) } label: {
                            Label(playlist.isPinned ? "고정 해제" : "고정",
                                  systemImage: playlist.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(playlist.isPinned ? .gray : .accentColor)
                    }
                }
            } footer: {
                if shown.isEmpty {
                    Text("검색과 일치하는 재생목록이 없습니다.")
                } else {
                    Text("고정한 재생목록만 \(channel.purpose.title) 탭의 이 채널 아래에 보입니다. · ^[\(shown.count) playlist](inflect: true)")
                }
            }
        }
        .listStyle(.plain)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "재생목록 검색"
        )
        .navigationTitle(channel.shortTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func togglePin(_ playlist: CachedPlaylist) {
        playlist.isPinned.toggle()
        // As PlaylistPinButton: unpinned is shown nowhere.
        playlist.purposeRaw = playlist.isPinned ? channel.purpose.rawValue : nil
        onPinChanged?()
    }
}

// MARK: - Playlist card

/// A playlist as a card, the size of a video card: artwork, title, count.
/// On a channel page the artwork is what tells one series from another.
///
/// Drawn as a stack — two edges behind the artwork, as YouTube draws a
/// playlist — so a playlist never reads as one more video on a page that
/// shows both.
struct PlaylistCard: View {
    let playlist: CachedPlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 3)
                    .padding(.horizontal, 16)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(height: 3)
                    .padding(.horizontal, 8)
                ZStack(alignment: .bottomTrailing) {
                    Color(.secondarySystemBackground)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            if let url = playlist.thumbnailURL {
                                AsyncImage(url: url) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: { Color.clear }
                            } else {
                                Image(systemName: "list.bullet.rectangle.portrait")
                                    .font(.title2).foregroundStyle(.secondary)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet").font(.caption2)
                        Text(playlist.itemCount > 0 ? "재생목록 · \(playlist.itemCount)" : "재생목록")
                    }
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
                }
            }
            HStack(spacing: 4) {
                if playlist.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint)
                }
                Text(playlist.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(Color.primary)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Sharing with members

/// The channel manager's switch: add this channel's unlisted services to the
/// church's shared list, now and on every launch after.
struct SharedListPublishCard: View {
    let channelId: String

    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @EnvironmentObject private var planning: PlanningAuth
    @EnvironmentObject private var manager: ChannelManagerAuth

    @State private var isOn = false
    @State private var isWorking = false
    @State private var outcome: SharedListPublisher.Outcome?
    @State private var hasPassword = SharedChannelList.password != nil
    @State private var passwordInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isOn) {
                Label("멤버에게 자동 공유", systemImage: "person.2.wave.2")
                    .font(.subheadline.weight(.semibold))
            }
            Text("이 채널을 관리하는 계정이면, 일부 공개 재생목록과 새로 올라온 영상을 교회 공유 폴더의 「관심 채널」 시트에 올립니다. "
                 + "목록은 교회 암호로 암호화되어, 폴더 링크만으로는 읽을 수 없습니다. 멤버는 같은 암호를 한 번 입력합니다. "
                 + "앱을 열 때마다(한 시간에 한 번까지) 새 영상을 더합니다. 비공개 영상은 올리지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Whose eyes the channel is read through: only an account that
            // manages it sees its unlisted services.
            HStack {
                if manager.isSignedIn {
                    Label("채널 관리 계정 \(manager.email ?? "")", systemImage: "person.badge.key")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("해제") { manager.signOut() }
                        .font(.caption)
                } else {
                    Label(auth.email.map { "YouTube 계정 \($0)" } ?? "", systemImage: "person.badge.key")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }
            if hasPassword {
                HStack {
                    Label("교회 암호가 이 기기에 저장되어 있습니다", systemImage: "lock.fill")
                        .font(.caption)
                    Spacer()
                    Button("바꾸기") { hasPassword = false }
                        .font(.caption)
                }
            } else {
                HStack {
                    SecureField("교회 암호 (멤버와 같은 암호)", text: $passwordInput)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                    Button("저장") {
                        SharedChannelList.password = passwordInput
                        passwordInput = ""
                        hasPassword = true
                        if isOn { Task { await publish() } }
                    }
                    .disabled(passwordInput.count < 4)
                }
            }
            if isWorking {
                ProgressView().controlSize(.small)
            } else if let outcome {
                Text(outcome.message)
                    .font(.caption)
                    .foregroundStyle(isProblem(outcome) ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .onAppear { isOn = SharedListPublisher.isOn(for: channelId) }
        .onChange(of: isOn) { _, on in
            SharedListPublisher.set(on, for: channelId)
            guard on else { outcome = nil; return }
            Task { await publish() }
        }
    }

    private func publish() async {
        isWorking = true
        defer { isWorking = false }
        let client = SharedListPublisher.client(auth: auth, quota: quota, manager: manager)
        let usePlanning = planning.isSignedIn
        let sheets = SheetsClient { [auth, planning] in
            usePlanning ? try await planning.token() : try await auth.accessToken()
        }
        outcome = await SharedListPublisher.publish(channelId: channelId, client: client, sheets: sheets,
                                                    password: SharedChannelList.password)
    }

    private func isProblem(_ outcome: SharedListPublisher.Outcome) -> Bool {
        switch outcome {
        case .added, .upToDate: return false
        default: return true
        }
    }
}

// MARK: - The church's password

/// Where a member enters the church's password, once: the shared list's
/// sealed part opens with it (SharedListCipher). Kept in the Keychain.
struct ChurchPasswordCard: View {
    let reload: () async -> Void
    let isStillLocked: () -> Bool

    @State private var input = ""
    @State private var isChecking = false
    @State private var wrong = false

    init(reload: @escaping () async -> Void, isStillLocked: @escaping () -> Bool) {
        self.reload = reload
        self.isStillLocked = isStillLocked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("교회 멤버 암호", systemImage: "lock")
                .font(.subheadline.weight(.semibold))
            Text("교회가 일부 공개 예배 목록을 암호로 잠가 두었습니다. 교회에서 받은 암호를 한 번 입력하면 이 기기에서 계속 보입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("암호", text: $input)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await check() } }
                if isChecking {
                    ProgressView()
                } else {
                    Button("열기") { Task { await check() } }
                        .disabled(input.isEmpty)
                }
            }
            if wrong {
                Text("암호가 맞지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        SharedChannelList.password = input
        await reload()
        wrong = isStillLocked()
        // Emptied either way: a wrong one left in the field had the next
        // attempt typed onto its end.
        if wrong { SharedChannelList.password = nil }
        input = ""
    }
}
