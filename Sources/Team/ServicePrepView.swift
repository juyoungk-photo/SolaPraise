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
    @State private var live: TeamService?

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
                } else if auth.isSignedIn, !auth.canUseSheets || team.needsAuthorization {
                    // The session predates the scope, so the sheet is fine
                    // and the token is not. Say which, and fix it here.
                    ContentUnavailableView {
                        Label("시트 접근 권한이 필요합니다", systemImage: "lock.rotation")
                    } description: {
                        Text("로그인할 때는 없던 권한입니다. 먼저 위 버튼으로 허용해 보고, 그래도 안 되면 다시 로그인하세요. 그래도 같은 문제라면 Cloud Console의 OAuth 동의 화면에 spreadsheets 범위가 등록되어 있는지 확인해야 합니다.")
                    } actions: {
                        VStack(spacing: 10) {
                            Button("시트 권한 허용") {
                                Task {
                                    let ok = await auth.requestScopes(
                                        ["https://www.googleapis.com/auth/spreadsheets"]
                                    )
                                    if ok, let sheetId { await team.load(sheetId: sheetId) }
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            // Incremental consent fails outright if the scope
                            // is not listed on the OAuth consent screen, and
                            // a full re-login is the only thing that then
                            // picks it up.
                            Button("로그아웃 후 다시 로그인") {
                                Task {
                                    auth.signOut()
                                    await auth.signIn()
                                    if let sheetId { await team.load(sheetId: sheetId) }
                                }
                            }
                            .buttonStyle(.bordered)

                            if let email = auth.email {
                                Text("현재 계정: \(email)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let message = team.errorMessage {
                                Text(message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
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
            .fullScreenCover(item: $live) { LiveServiceView(service: $0) }
            // An alert, not a confirmationDialog. On iPad the latter is a
            // popover anchored to whatever presented it, and anchored to a
            // row inside a List it was drawn clipped — the buttons were
            // there and invisible. An alert is centred and identical on both.
            .alert(
                "이 예배의 콘티를 덮어씁니다",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                presenting: pending
            ) { push in
                Button("채우기") {
                    if let service { Task { await self.push(push.playlist, to: service) } }
                }
                Button("취소", role: .cancel) { pending = nil }
            } message: { push in
                Text("「\(push.playlist.title)」의 곡으로 이 날짜의 목록이 바뀝니다. 이미 적어 둔 키와 메모는 앱이 아는 값이 있을 때만 채워집니다.")
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
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let service, !team.plan(for: service).isEmpty {
                Button { live = service } label: {
                    Image(systemName: "play.square.stack")
                }
                .accessibilityLabel("라이브 진행")
            }
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
            responseSection(service)
            roleSection(service)
            upcomingSection

            if let message = team.errorMessage {
                Section { Text(message).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    // MARK: - Order of service

    @ViewBuilder
    private func songSection(_ service: TeamService) -> some View {
        let items = team.plan(for: service)
        let times = TeamStore.startTimes(for: items, from: serviceStart(service))
        let total = items.compactMap(\.minutes).reduce(0, +)

        Section {
            if items.isEmpty {
                Text("이 예배의 순서가 비어 있습니다. 시트의 Plan 탭에 추가하거나, 아래에서 재생목록으로 찬양을 채우세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    planRow(item, startsAt: times[item.id])
                }

                let songs = items.filter { $0.kind == .song && $0.videoId != nil }
                if !songs.isEmpty {
                    Button {
                        host.play(
                            queue: songs.compactMap { item in
                                item.videoId.map { PlayableVideo(id: $0, title: item.title) }
                            },
                            startIndex: 0
                        )
                    } label: {
                        Label("찬양만 이어 듣기", systemImage: "play.fill")
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
                        Label("재생목록에서 찬양 채우기", systemImage: "square.and.arrow.down")
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
            HStack {
                Text("순서")
                Spacer()
                if total > 0 {
                    // The number a leader is actually watching.
                    Text("\(total)분")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if team.hasPlanTab {
                Text("시작 시각은 \(Self.clockFormatter.string(from: serviceStart(service)))을 기준으로 계산합니다. 길이를 적지 않은 순서는 시계를 넘기지 않으므로 그 뒤는 대략적인 값입니다.")
            } else {
                Text("시트에 Plan 탭을 추가하면 기도·설교·광고까지 포함한 순서와 시간이 보입니다. 지금은 Songs 탭의 찬양만 보여 주고 있습니다.")
            }
        }
    }

    /// 11:00 unless the leader wrote a time into the service title or notes.
    ///
    /// Guessed rather than configured, because a second service time is one
    /// more thing to set up and nearly every service in this church starts on
    /// the hour. A time anywhere in the title or notes wins over the guess.
    private func serviceStart(_ service: TeamService) -> Date {
        let calendar = Calendar.current
        let haystack = [service.title, service.notes ?? ""].joined(separator: " ")
        if let match = haystack.range(of: "\\b([0-9]{1,2})[:시]([0-9]{2})\\b",
                                      options: .regularExpression) {
            let digits = haystack[match].split(whereSeparator: { !$0.isNumber })
            if digits.count == 2, let h = Int(digits[0]), let m = Int(digits[1]),
               (0...23).contains(h), (0...59).contains(m) {
                return calendar.date(bySettingHour: h, minute: m, second: 0,
                                     of: service.date) ?? service.date
            }
        }
        return calendar.date(bySettingHour: 11, minute: 0, second: 0,
                             of: service.date) ?? service.date
    }

    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        return f
    }()

    private func planRow(_ item: PlanItem, startsAt: Date?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                if let startsAt {
                    Text(Self.clockFormatter.string(from: startsAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(item.kind == .song ? Color.accentColor : .secondary)
                }
                if let minutes = item.minutes {
                    Text("\(minutes)분")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 54, alignment: .trailing)

            Image(systemName: item.kind.symbolName)
                .font(.caption)
                .foregroundStyle(item.kind == .song ? Color.accentColor : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline)
                HStack(spacing: 6) {
                    if item.kind != .song {
                        Text(item.kind.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let key = item.key {
                        Text(key).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    }
                    if let person = item.person {
                        Text(person).font(.caption2).foregroundStyle(.secondary)
                    }
                    if item.kind == .song, existingSheet(forTitle: item.title) != nil {
                        Label("악보", systemImage: "music.quarternote.3")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                if let notes = item.notes {
                    Text(notes).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if item.kind == .song {
                SheetMusicMenu(title: item.title) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let id = item.videoId {
                Button {
                    host.play(queue: [PlayableVideo(id: id, title: item.title)], startIndex: 0)
                } label: {
                    Image(systemName: "play.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 3)
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

        let songs: [TeamSong] = items.enumerated().compactMap { index, item -> TeamSong? in
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
                ? "\(result.written)곡을 Songs 탭에 보냈습니다. 기존 \(result.replaced)줄을 바꿨습니다."
                : "\(result.written)곡을 Songs 탭에 보냈습니다."
        } catch {
            pushNote = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Who has answered

    /// The leader's actual question is who has said nothing.
    ///
    /// A list of volunteers tells you who is coming. It does not tell you
    /// who still has to be asked, and that is the list that turns into
    /// messages on a Thursday night.
    @ViewBuilder
    private func responseSection(_ service: TeamService) -> some View {
        let answers = team.responses(for: service)
        let silent = team.unanswered(for: service)
        Group {
            Section {
                ForEach(answers) { answer in
                    HStack {
                        Text(answer.name.isEmpty ? answer.email : answer.name)
                            .font(.subheadline)
                        Spacer()
                        Text(answer.status.label)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(tint(answer.status).opacity(0.18), in: Capsule())
                            .foregroundStyle(tint(answer.status))
                    }
                }
                ForEach(silent, id: \.self) { email in
                    HStack {
                        Text(email).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text("미응답").font(.caption).foregroundStyle(.tertiary)
                    }
                }

                NavigationLink {
                    MembersView()
                } label: {
                    Label(team.memberEmails.isEmpty ? "팀원 명단 만들기" : "팀원 명단",
                          systemImage: "person.2")
                        .font(.subheadline)
                }
            } header: {
                HStack {
                    Text("응답")
                    Spacer()
                    if !silent.isEmpty {
                        Text("\(silent.count)명 미응답")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                if team.memberEmails.isEmpty {
                    Text("명단이 없으면 누가 답했는지는 알아도 누가 아직 답하지 않았는지는 알 수 없습니다.")
                }
            }
        }
    }

    private func tint(_ status: SignupStatus) -> Color {
        switch status {
        case .available: return .green
        case .declined:  return .red
        case .away:      return .orange
        }
    }

    // MARK: - Weeks ahead

    /// Who is serving over the coming Sundays.
    ///
    /// The question a leader asks is never only about this week — it is
    /// "who have I asked too often" and "what is still unfilled in three
    /// weeks". One service at a time cannot answer either.
    @ViewBuilder
    private var upcomingSection: some View {
        let future = team.services.filter { !$0.isPast }.prefix(6)
        if future.count > 1 {
            Section {
                ForEach(Array(future)) { upcoming in
                    Button { selected = upcoming } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(upcoming.date, format: .dateTime.month().day().weekday())
                                    .font(.subheadline.weight(
                                        upcoming.id == service?.id ? .semibold : .regular
                                    ))
                                Text(upcoming.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            filledSummary(upcoming)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("다음 예배")
            } footer: {
                Text("비어 있는 파트가 몇 개인지 먼저 보입니다. 날짜를 누르면 그 예배로 바뀝니다.")
            }
        }
    }

    private func filledSummary(_ upcoming: TeamService) -> some View {
        let filled = team.roles.filter { upcoming.assignments[$0.name] != nil }.count
        let total = team.roles.count
        let complete = total > 0 && filled == total
        return HStack(spacing: 4) {
            Image(systemName: complete ? "checkmark.circle.fill" : "person.badge.clock")
                .font(.caption2)
            Text(total > 0 ? "\(filled)/\(total)" : "—")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(complete ? Color.green : .secondary)
    }

    /// A chart the team has already made for this song, matched on title.
    private func existingSheet(forTitle title: String) -> SavedSong? {
        let needle = title.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return nil }
        return sheets.first { $0.title.contains(needle) || needle.contains($0.title) }
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
                Text("\(auth.email ?? "이 계정")은 시트를 볼 수만 있어 사인업을 저장할 수 없습니다. 시트 주인(교회 계정)에게 이 주소를 편집자로 추가해 달라고 하세요. 앱은 계정을 하나만 쓰므로, 시트 주인 계정으로 로그인할 필요는 없습니다.")
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
            let away = team.signupsAll(for: service, role: role.name)
                .filter { $0.status == .away }
            if !away.isEmpty {
                Text("자리비움: " + away.map(\.name).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if !email.isEmpty, !service.isPast, !team.isReadOnly {
                HStack(spacing: 8) {
                    statusButton("가능", .available, mine, service, role, .green)
                    statusButton("어려움", .declined, mine, service, role, .red)
                    statusButton("자리비움", .away, mine, service, role, .orange)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private func statusButton(
        _ title: String,
        _ status: SignupStatus,
        _ mine: TeamSignup?,
        _ service: TeamService,
        _ role: TeamRole,
        _ tint: Color
    ) -> some View {
        let selected = mine?.status == status
        return Button {
            Task { await setAvailability(status, service, role) }
        } label: {
            Label(title, systemImage: selected ? "largecircle.fill.circle" : "circle")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(selected ? tint : .secondary)
    }

    private func setAvailability(_ value: SignupStatus, _ service: TeamService, _ role: TeamRole) async {
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
