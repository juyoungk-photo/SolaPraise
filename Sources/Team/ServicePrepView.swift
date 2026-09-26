//
//  ServicePrepView.swift
//  SolaPraise
//
//  예배 준비 — one Sunday, everything needed to play it.
//
//  A playlist is an ordered list of videos. A service is that plus the date,
//  the roles, who filled them, the key each song is actually in, the leader's
//  notes, and the charts the team has made. This screen is where those stop
//  being four places.
//

import SwiftUI
import SwiftData

struct ServicePrepView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var host: PlayerHost
    @EnvironmentObject private var team: TeamStore

    @Query(sort: [SortDescriptor(\SavedSong.createdAt, order: .reverse)])
    private var sheets: [SavedSong]

    @State private var selected: TeamService?
    @State private var showSettings = false

    @Query(sort: [SortDescriptor(\CachedPlaylist.title)])
    private var allPlaylists: [CachedPlaylist]

    /// A push waiting on confirmation, because it rewrites the sheet the
    /// team reads on Sunday morning.
    private struct Push: Identifiable {
        let playlist: CachedPlaylist
        var id: String { playlist.playlistId }
    }
    @State private var pending: Push?
    @State private var isPushing = false
    @State private var pushNote: String?

    @EnvironmentObject private var quota: QuotaLedger

    private var pinnedPlaylists: [CachedPlaylist] {
        allPlaylists.filter { $0.purposeRaw == Purpose.worship.rawValue }
    }

    private var sheetId: String? { TeamSheetSource.current }
    private var service: TeamService? { selected ?? team.upcoming }

    var body: some View {
        NavigationStack {
            Group {
                if team.isLoading && team.services.isEmpty {
                    ProgressView("팀 시트 불러오는 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let service {
                    content(service)
                } else if auth.isSignedIn, !auth.canUseSheets {
                    // The session predates the scope, so the sheet is fine
                    // and the token is not. Say which, and fix it here.
                    ContentUnavailableView {
                        Label("시트 접근 권한이 필요합니다", systemImage: "lock.rotation")
                    } description: {
                        Text("로그인할 때는 없던 권한입니다. 아래를 눌러 한 번만 허용하면 됩니다. 로그아웃할 필요는 없습니다.")
                    } actions: {
                        Button("시트 권한 허용") {
                            Task {
                                let ok = await auth.requestScopes(
                                    ["https://www.googleapis.com/auth/spreadsheets"]
                                )
                                if ok, let sheetId { await team.load(sheetId: sheetId) }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView(
                        "예정된 예배가 없습니다",
                        systemImage: "calendar",
                        description: Text(team.errorMessage
                                          ?? "팀 시트의 Schedule 탭에 날짜를 추가하면 여기에 나타납니다.")
                    )
                }
            }
            .navigationTitle("예배 준비")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .refreshable { if let sheetId { await team.load(sheetId: sheetId) } }
            .task {
                team.configure(auth: auth)
                guard auth.canUseSheets else { return }
                if team.services.isEmpty, let sheetId {
                    await team.load(sheetId: sheetId)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog(
                "이 예배의 콘티를 덮어씁니다",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pending, let service {
                    Button("\(pending.playlist.title) 으로 채우기") {
                        Task { await push(pending.playlist, to: service) }
                    }
                }
                Button("취소", role: .cancel) { pending = nil }
            } message: {
                Text("시트의 이 날짜 곡 목록이 재생목록 내용으로 바뀝니다. 이미 적어 둔 키와 메모는 앱이 아는 값이 있을 때만 채워집니다.")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if team.services.count > 1 {
                Menu {
                    ForEach(team.services) { option in
                        Button {
                            selected = option
                        } label: {
                            Label(
                                option.date.formatted(.dateTime.month().day()) + " " + option.title,
                                systemImage: option.id == service?.id ? "checkmark" : ""
                            )
                        }
                    }
                } label: {
                    Image(systemName: "calendar")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
    }

    // MARK: - Content

    private func content(_ service: TeamService) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.date, format: .dateTime.year().month().day().weekday(.wide))
                        .font(.headline)
                    Text(service.title).font(.subheadline).foregroundStyle(.secondary)
                    if let notes = service.notes {
                        Text(notes)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 2)
            }

            songSection(service)
            roleSection(service)

            if let message = team.errorMessage {
                Section { Text(message).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    // MARK: - Songs

    @ViewBuilder
    private func songSection(_ service: TeamService) -> some View {
        let list = team.songs(for: service)
        Section {
            if list.isEmpty {
                Text("이 예배의 콘티가 아직 비어 있습니다. 시트의 Songs 탭에 추가하세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(list) { song in
                    songRow(song)
                }

                if !playable(list).isEmpty {
                    Button {
                        host.play(queue: playable(list), startIndex: 0)
                    } label: {
                        Label("콘티 전체 재생", systemImage: "play.fill")
                    }
                }
            }

            if pinnedPlaylists.isEmpty {
                Text("찬양 탭에 재생목록을 고정하면 여기로 보낼 수 있습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(pinnedPlaylists) { playlist in
                        Button(playlist.title) { pending = Push(playlist: playlist) }
                    }
                } label: {
                    HStack {
                        Label("재생목록에서 콘티 채우기", systemImage: "square.and.arrow.down")
                        Spacer()
                        if isPushing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isPushing)
            }

            if let note = pushNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("콘티")
        } footer: {
            Text("키는 시트에 적힌 값입니다. 팀이 실제로 연주하는 키이므로 감지된 키보다 우선합니다.")
        }
    }

    private func songRow(_ song: TeamSong) -> some View {
        HStack(spacing: 12) {
            Text("\(song.order)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.subheadline)
                HStack(spacing: 6) {
                    if let key = song.key {
                        Text(key)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    if song.transpose != 0 {
                        Text(song.transpose > 0 ? "+\(song.transpose)" : "\(song.transpose)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // A chart this team already made for the same song, so
                    // the work is not repeated every week.
                    if existingSheet(for: song) != nil {
                        Label("악보", systemImage: "music.quarternote.3")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if let notes = song.notes {
                        Text(notes).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            if let id = song.videoId {
                Button {
                    host.play(queue: [PlayableVideo(id: id, title: song.title)], startIndex: 0)
                } label: {
                    Image(systemName: "play.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }

    private func playable(_ list: [TeamSong]) -> [PlayableVideo] {
        list.compactMap { song in
            guard let id = song.videoId else { return nil }
            return PlayableVideo(id: id, title: song.title)
        }
    }

    /// Matched on title: the sheet names a song, the chart was made from a
    /// video whose title contains it.
    private func existingSheet(for song: TeamSong) -> SavedSong? {
        existingSheet(forTitle: song.title)
    }

    private func existingSheet(forTitle title: String) -> SavedSong? {
        let needle = title.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return nil }
        return sheets.first { $0.title.contains(needle) || needle.contains($0.title) }
    }

    // MARK: - Pushing the 콘티

    private func push(_ playlist: CachedPlaylist, to service: TeamService) async {
        guard let sheetId else { return }
        pending = nil
        isPushing = true
        pushNote = nil
        defer { isPushing = false }

        let client = AppServices.client(auth: auth, quota: quota)
        guard let items = try? await client.playlistItems(playlistId: playlist.playlistId) else {
            pushNote = "재생목록을 불러오지 못했습니다."
            return
        }

        let songs: [TeamSong] = items.enumerated().compactMap { index, item in
            guard !item.isUnavailable, let id = item.videoId else { return nil }
            let chart = existingSheet(forTitle: item.title)
            return TeamSong(
                order: index + 1,
                title: item.title,
                url: YouTubeID.watchURL(id),
                // The team's own key if a chart has one, otherwise what
                // detection guessed, otherwise blank for the leader to fill.
                key: chart?.keyLabel,
                transpose: chart?.semitoneShift ?? 0,
                notes: nil
            )
        }
        guard !songs.isEmpty else {
            pushNote = "재생할 수 있는 곡이 없습니다."
            return
        }

        do {
            let existing = try await team.rawSongRows(sheetId: sheetId)
            let result = try await team.pushSongs(
                songs, to: service, sheetId: sheetId, existingRows: existing
            )
            pushNote = result.replaced > 0
                ? "\(result.written)곡을 보냈습니다. 기존 \(result.replaced)줄을 바꿨습니다."
                : "\(result.written)곡을 보냈습니다."
        } catch {
            pushNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Roles

    @ViewBuilder
    private func roleSection(_ service: TeamService) -> some View {
        Section {
            if team.roles.isEmpty {
                Text("시트의 Roles 탭에 파트를 추가하면 여기에서 사인업할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(team.roles) { role in
                    roleRow(service, role)
                }
            }
        } header: {
            Text("파트")
        } footer: {
            if team.isReadOnly {
                Text("이 계정은 시트를 볼 수만 있어 사인업을 저장할 수 없습니다. 시트 주인에게 편집자로 추가해 달라고 요청하세요. 시트가 다른 계정(교회 계정) 소유라면, 앱에 로그인한 주소를 그대로 알려 주면 됩니다.")
            } else {
                Text("「가능」은 리더에게 알리는 것이고, 확정은 리더가 시트에서 이름을 넣어 정합니다.")
            }
        }
    }

    private func roleRow(_ service: TeamService, _ role: TeamRole) -> some View {
        let assigned = service.assignments[role.name]
        let volunteers = team.signups(for: service, role: role.name)
        let email = auth.email ?? ""
        let mine = team.mySignup(for: service, role: role.name, email: email)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(role.name).font(.subheadline.weight(.medium))
                Spacer()
                if let assigned {
                    Text(assigned)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                } else {
                    Text("미정").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !volunteers.isEmpty {
                Text("가능: " + volunteers.map(\.name).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !email.isEmpty, !service.isPast, !team.isReadOnly {
                HStack(spacing: 8) {
                    Button {
                        Task { await setAvailability(true, service, role) }
                    } label: {
                        Label("가능", systemImage: mine?.isAvailable == true
                              ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(mine?.isAvailable == true ? .green : .accentColor)

                    Button {
                        Task { await setAvailability(false, service, role) }
                    } label: {
                        Label("어려움", systemImage: mine?.isAvailable == false
                              ? "xmark.circle.fill" : "circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(mine?.isAvailable == false ? .red : .secondary)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private func setAvailability(_ value: Bool, _ service: TeamService, _ role: TeamRole) async {
        guard let sheetId, let email = auth.email else { return }
        await team.setAvailability(
            value,
            service: service,
            role: role.name,
            email: email,
            name: auth.displayName ?? email,
            sheetId: sheetId
        )
    }
}
