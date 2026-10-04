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
    @EnvironmentObject private var planning: PlanningAuth

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
    @State private var responding: TeamService?

    @EnvironmentObject private var quota: QuotaLedger

    private var pinnedPlaylists: [CachedPlaylist] {
        allPlaylists.filter { $0.purposeRaw == Purpose.worship.rawValue }
    }

    private var sheetId: String? { TeamSheetSource.current }

    private var access: TeamAccess.State {
        TeamAccess.evaluate(
            sheetId: sheetId,
            email: auth.email,
            displayName: auth.displayName,
            roster: team.memberEmails
        )
    }
    private var service: TeamService? { selected ?? team.upcoming }

    var body: some View {
        NavigationStack {
            Group {
                if team.isLoading && team.services.isEmpty {
                    ProgressView("팀 시트 불러오는 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let service {
                    content(service)
                } else if case .notAMember(let email) = access {
                    ContentUnavailableView {
                        Label("명단에 없는 계정입니다", systemImage: "person.crop.circle.badge.questionmark")
                    } description: {
                        Text("\(email) 은 팀 시트의 Members 탭에 없습니다. 앱에 로그인한 주소와 명단에 적힌 주소가 다른 경우가 대부분입니다.")
                    } actions: {
                        VStack(spacing: 10) {
                            Button("이 계정을 명단에 추가") {
                                Task {
                                    guard let sheetId else { return }
                                    await team.addMember(
                                        email: email,
                                        name: auth.displayName ?? "",
                                        sheetId: sheetId
                                    )
                                    await team.load(sheetId: sheetId)
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            NavigationLink("팀원 명단 보기") { MembersView() }
                                .buttonStyle(.bordered)

                            if let message = team.errorMessage {
                                Text(message)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
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
            .miniPlayerDock()
            .navigationTitle("예배 준비")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .refreshable { if let sheetId { await team.load(sheetId: sheetId) } }
            .task {
                team.configure(auth: auth, planning: planning)
                guard auth.canUseSheets else { return }
                if team.services.isEmpty, let sheetId {
                    await team.load(sheetId: sheetId)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $live) { LiveServiceView(service: $0) }
            .sheet(item: $responding) { ResponseSheet(service: $0) }
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
                    HStack(spacing: 6) {
                        Text(service.title)
                        if let time = service.time { Text("· \(time)") }
                        if let where_ = service.location { Text("· \(where_)") }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if let notes = service.notes {
                        Text(notes)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 2)
            }

            if !service.isRehearsal { songSection(service) }
            scheduleSection

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

    /// The time the sheet gives, which is the only reliable source.
    ///
    /// This used to guess 11:00 and look for a time in the title. The team's
    /// own planner has a Time column and uses four different ones — 주일예배
    /// at 11:30, 금요 Worship at 7:30 PM, 팀연습 at 9:30 AM — so the guess
    /// was wrong for almost every row.
    private func serviceStart(_ service: TeamService) -> Date { service.start() }

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

    // MARK: - Response chips

    private func tint(_ status: SignupStatus) -> Color {
        switch status {
        case .available: return .green
        case .declined:  return .red
        case .away:      return .orange
        }
    }

    /// "주영 인도" — a person and what they are doing.
    private func chip(
        _ name: String,
        detail: String?,
        color: Color,
        dashed: Bool = false
    ) -> some View {
        HStack(spacing: 4) {
            if dashed {
                Circle()
                    .strokeBorder(color.opacity(0.6), lineWidth: 1)
                    .frame(width: 6, height: 6)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(name)
            if let detail {
                Text(detail).foregroundStyle(color.opacity(0.75))
            }
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(dashed ? 0.06 : 0.14)))
        .foregroundStyle(color)
    }

    // MARK: - The schedule

    /// Every upcoming service as a row you can answer on.
    ///
    /// A leader plans one Sunday at a time; a member answers for several at
    /// once, usually in one sitting when the month's schedule goes up. The
    /// tab used to make that a date picker — tap a week, scroll to the
    /// parts, answer, tap the next week — when it is really one list.
    @ViewBuilder
    private var scheduleSection: some View {
        let future = team.services.filter { !$0.isPast }
        if !future.isEmpty {
            Section {
                ForEach(future) { upcoming in
                    // A month label where the month turns, so scrolling
                    // through a quarter does not become undifferentiated.
                    if isFirstOfMonth(upcoming, in: future) {
                        Text(upcoming.date, format: .dateTime.year().month(.wide))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    scheduleRow(upcoming)
                }
            } header: {
                Text("예배표")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    // Whose answer this will be, with the way to change it
                    // right here. Burying that in Settings meant the wrong
                    // account stayed the wrong account.
                    HStack(spacing: 6) {
                        if let email = team.actingEmail(auth: auth, planning: planning) {
                            (Text("응답 계정: ").foregroundStyle(.secondary)
                             + Text(email)
                             + Text(planning.isSignedIn ? "" : " (YouTube 계정)")
                                .foregroundStyle(.secondary))
                        }
                        Spacer(minLength: 4)
                        if planning.isSignedIn {
                            Button("계정 변경") {
                                planning.signOut()
                                team.configure(auth: auth, planning: planning)
                            }
                        } else {
                            Button("교회 계정으로 전환") {
                                Task {
                                    await planning.signIn()
                                    team.configure(auth: auth, planning: planning)
                                    if let id = TeamSheetSource.current {
                                        await team.load(sheetId: id)
                                    }
                                }
                            }
                        }
                    }
                    .font(.caption)
                    if let message = planning.lastError {
                        Text(message).foregroundStyle(.orange)
                    }
                    Text("줄을 눌러 그 예배의 순서를 보고, 오른쪽에서 맡을 파트를 고르세요. 응답한 사람이 먼저 나옵니다.")
                }
            }
        }
    }

    private func isFirstOfMonth(_ service: TeamService, in list: [TeamService]) -> Bool {
        guard let index = list.firstIndex(where: { $0.id == service.id }) else { return false }
        guard index > 0 else { return true }
        return !Calendar.current.isDate(list[index - 1].date,
                                        equalTo: service.date, toGranularity: .month)
    }

    private func scheduleRow(_ upcoming: TeamService) -> some View {
        let email = team.actingEmail(auth: auth, planning: planning) ?? ""
        let answers = team.responses(for: upcoming)
        let mine = answers.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
        let filled = team.roles.filter { upcoming.assignments[$0.name] != nil }.count
        let coreGap = team.roles.filter { $0.isCore && upcoming.assignments[$0.name] == nil }

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button { selected = upcoming } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(upcoming.date, format: .dateTime.month().day().weekday())
                            .font(.subheadline.weight(
                                upcoming.id == service?.id ? .semibold : .regular
                            ))
                        HStack(spacing: 6) {
                            Text(upcoming.title)
                            if let time = upcoming.time { Text("· \(time)") }
                            if let where_ = upcoming.location { Text("· \(where_)") }
                            if team.roles.count > 0, !upcoming.isRehearsal {
                                Text("· \(filled)/\(team.roles.count)").monospacedDigit()
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                // Answering happens here, on the week it is about.
                Button { responding = upcoming } label: {
                    HStack(spacing: 4) {
                        if let mine {
                            Circle().fill(tint(mine.status)).frame(width: 7, height: 7)
                            // The part, when there is one — that is the
                            // answer. The status word only carries weight
                            // when the answer is no.
                            if mine.status == .available, !mine.role.isEmpty {
                                Text(mine.role)
                            } else {
                                Text(mine.status.label)
                            }
                        } else {
                            Image(systemName: "hand.raised").font(.caption2)
                            Text("응답하기")
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(mine.map { tint($0.status).opacity(0.16) }
                                       ?? Color(.secondarySystemBackground))
                    )
                    .foregroundStyle(mine.map { tint($0.status) } ?? Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(team.isReadOnly)
            }

            if !coreGap.isEmpty, !upcoming.isRehearsal {
                // The gap that decides whether the service can happen.
                Text("미정: " + coreGap.map(\.name).joined(separator: ", "))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }

            // Who is coming, then who is not, then who has not said.
            // Pending is the actionable one, so it is shown rather than
            // being the absence of a chip.
            let pending = team.pendingNames(for: upcoming)
            if answers.isEmpty, pending.isEmpty {
                Text("아직 응답 없음").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(answers) { answer in
                            // "주영 인도" reads as a fact about Sunday.
                            // "주영 가능" reads as a form someone filled in.
                            chip(
                                answer.name.isEmpty ? answer.email : answer.name,
                                detail: answer.status == .available
                                    ? (answer.role.isEmpty ? nil : answer.role)
                                    : answer.status.label,
                                color: tint(answer.status)
                            )
                        }
                        ForEach(pending, id: \.self) { who in
                            chip(who, detail: "미응답", color: .secondary, dashed: true)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// A chart the team has already made for this song, matched on title.
    private func existingSheet(forTitle title: String) -> SavedSong? {
        let needle = title.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return nil }
        return sheets.first { $0.title.contains(needle) || needle.contains($0.title) }
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
