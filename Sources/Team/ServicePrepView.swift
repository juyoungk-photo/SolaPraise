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
        // The address that answers, not the one that plays YouTube. With the
        // church account connected those are different addresses, and
        // judging membership by the YouTube one meant you could be on the
        // roster under a name your own answers were never filed under —
        // your row said 미응답 while your answer sat there under the other
        // address.
        TeamAccess.evaluate(
            sheetId: sheetId,
            email: team.actingEmail(auth: auth, planning: planning),
            displayName: planning.isSignedIn ? planning.email : auth.displayName,
            roster: team.memberEmails
        )
    }
    /// The open service — what the toolbar, the push and the archive act on.
    private var service: TeamService? {
        switch expansion {
        case .auto:          return team.upcoming
        case .none:          return nil
        case .day(let day):  return team.services.first {
            Calendar.current.isDate($0.date, inSameDayAs: day)
        } ?? team.upcoming
        }
    }

    private func isOpen(_ candidate: TeamService) -> Bool {
        service.map { Calendar.current.isDate($0.date, inSameDayAs: candidate.date) } ?? false
    }

    private func toggle(_ candidate: TeamService) {
        withAnimation(.snappy(duration: 0.22)) {
            if isOpen(candidate) {
                expansion = .none
            } else {
                expansion = .day(candidate.date)
                scrollTo?(candidate.date)
            }
        }
    }

    /// The part you usually take, remembered by ResponseSheet. Lets the
    /// switch answer on its own instead of making every yes a two-step.
    @AppStorage("team.usualRole") private var usualRole = ""

    @StateObject private var archiveStore = ServiceArchive()

    /// Which service is open. `.auto` means "the next one", which is what
    /// anyone opening this tab is here for; tapping a row pins it open and
    /// tapping it again closes everything.
    private enum Expansion: Equatable { case auto, none, day(Date) }
    @State private var expansion: Expansion = .auto

    /// Set by the List's ScrollViewReader so opening a row can bring it into
    /// view — a row near the bottom would otherwise unfold off screen.
    @State private var scrollTo: ((Date) -> Void)?

    var body: some View {
        NavigationStack {
            Group {
                if team.isLoading && team.services.isEmpty {
                    ProgressView("팀 시트 불러오는 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !team.services.isEmpty {
                    // Not "if there is a selected service": closing every row
                    // left nothing selected, and the screen then claimed
                    // there were no services at all.
                    content()
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
                    sheetTrouble
                } else {
                    ContentUnavailableView(
                        "예정된 예배가 없습니다",
                        systemImage: "calendar",
                        description: Text(team.errorMessage
                                          ?? "팀 시트의 Schedule 탭에 날짜를 추가하면 여기에 나타납니다.")
                    )
                }
            }
            .bottomChrome()
            .navigationTitle("예배 준비")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .refreshable { if let sheetId { await team.load(sheetId: sheetId) } }
            .task {
                #if DEBUG
                if DebugHarness.seedTeam { return }
                #endif
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

    /// Two different failures used to share one screen.
    ///
    /// "This token never asked for spreadsheets" and "Google refused this
    /// account on this sheet" need opposite fixes — grant a scope, or change
    /// who is asking — and the screen reported the first either way. Someone
    /// holding a perfectly granted token was told to re-grant it, which
    /// changes nothing and reads as the app being stuck.
    ///
    /// It also states what it knows: the account, whether the scope is
    /// actually on the token, which sheet, and Google's own words. A wrong
    /// account is the usual answer here and nothing on the screen used to
    /// say which account was being used.
    @ViewBuilder
    private var sheetTrouble: some View {
        let missingScope = !auth.canUseSheets
        ContentUnavailableView {
            Label(missingScope ? "시트 권한이 없습니다" : "시트를 열 수 없습니다",
                  systemImage: missingScope ? "lock.rotation" : "person.badge.key")
        } description: {
            if missingScope {
                Text("로그인할 때는 없던 권한입니다. 아래에서 허용하면 바로 열립니다.")
            } else {
                Text("권한은 있는데 Google이 이 시트에 대해 이 계정을 거절했습니다. 시트가 아래 주소와 공유되어 있는지, 아니면 교회 계정으로 바꿔야 하는지 확인하세요.")
            }
        } actions: {
            VStack(spacing: 10) {
                if missingScope {
                    Button("시트 권한 허용") {
                        Task {
                            let ok = await auth.requestScopes(
                                ["https://www.googleapis.com/auth/spreadsheets"]
                            )
                            if ok, let sheetId { await team.load(sheetId: sheetId) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("다시 시도") {
                        Task { if let sheetId { await team.load(sheetId: sheetId) } }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("교회 계정으로 전환") {
                        Task {
                            await planning.signIn()
                            team.configure(auth: auth, planning: planning)
                            if let sheetId { await team.load(sheetId: sheetId) }
                        }
                    }
                    .buttonStyle(.bordered)
                }

                // Incremental consent fails outright if the scope is not
                // listed on the OAuth consent screen, and a full re-login is
                // the only thing that then picks it up.
                Button("로그아웃 후 다시 로그인") {
                    Task {
                        auth.signOut()
                        await auth.signIn()
                        team.configure(auth: auth, planning: planning)
                        if let sheetId { await team.load(sheetId: sheetId) }
                    }
                }
                .buttonStyle(.bordered)

                VStack(spacing: 2) {
                    if let email = team.actingEmail(auth: auth, planning: planning) {
                        Text("계정: \(email)")
                    }
                    Text("spreadsheets 권한: \(auth.canUseSheets ? "있음" : "없음")")
                    if let sheetId {
                        Text("시트: \(sheetId.prefix(10))…")
                    }
                    if let message = team.errorMessage {
                        Text(message).foregroundStyle(.orange)
                    }
                    if let message = planning.lastError {
                        Text(message).foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
                            expansion = .day(option.date)
                            scrollTo?(option.date)
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

    private func content() -> some View {
        ScrollViewReader { proxy in
            List {
                // One list, and nothing above it. The date and the 순서 used
                // to sit in their own block at the top, describing whichever
                // service was selected far below — so the schedule read as
                // a second, unrelated screen and selecting a row changed
                // something off screen. Every service is now a row that opens
                // where it is, and the next one is open to begin with.
                scheduleSection

                if let message = team.errorMessage {
                    Section { Text(message).font(.caption).foregroundStyle(.orange) }
                }
            }
            .onAppear { scrollTo = { id in proxy.scrollTo(id, anchor: .top) } }
        }
    }

    // MARK: - Order of service

    /// What a service row shows when it is open: the 순서, and the things
    /// you do with it. A plain stack rather than a Section, because it now
    /// lives inside a row instead of being a screen of its own.
    @ViewBuilder
    private func serviceDetail(_ service: TeamService) -> some View {
        let items = team.plan(for: service)
        let times = TeamStore.startTimes(for: items, from: serviceStart(service))
        let total = items.compactMap(\.minutes).reduce(0, +)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("순서").font(.caption.weight(.semibold))
                Spacer()
                if total > 0 {
                    // The number a leader is actually watching.
                    Text("\(total)분")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)

            if let notes = service.notes {
                Text(notes).font(.footnote).foregroundStyle(.secondary)
            }

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

                    // After the service, the songs outlive the 콘티 — next
                    // week's overwrites this one. Offered from the day of the
                    // service onwards, which is when "what we sang" becomes a
                    // fact rather than a plan. Not `isPast`, which excludes
                    // today: the moment this is wanted is Sunday afternoon.
                    if hasHappened(service) {
                    let archived = archiveStore.hasArchived(service)
                    Button {
                        Task { await archive(service, songs: songs) }
                    } label: {
                        HStack {
                            Label(archived
                                  ? "CCC_예배찬양곡_모음에 보관됨"
                                  : "CCC_예배찬양곡_모음에 보관",
                                  systemImage: archived
                                  ? "checkmark.circle.fill" : "tray.and.arrow.down")
                            .foregroundStyle(archived ? Color.green : Color.accentColor)
                            Spacer()
                            if archiveStore.isWorking {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    // Once filed, the button stops being a button. Pressing
                    // it again could only add duplicates or discover there
                    // are none, and neither is worth a round trip or the
                    // doubt about which one just happened.
                    .disabled(archived || archiveStore.isWorking || !auth.isSignedIn)

                    if let note = archiveStore.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

            Group {
                if team.hasPlanTab {
                    Text("시작 시각은 \(Self.clockFormatter.string(from: serviceStart(service)))을 기준으로 계산합니다. 길이를 적지 않은 순서는 시계를 넘기지 않으므로 그 뒤는 대략적인 값입니다.")
                } else {
                    Text("시트에 Plan 탭을 추가하면 기도·설교·광고까지 포함한 순서와 시간이 보입니다. 지금은 Songs 탭의 찬양만 보여 주고 있습니다.")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
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
                // Whose answer this will be, and the note on how to answer.
                // Both sat in the section footer, below a schedule that runs
                // months deep — far enough down that the account you were
                // answering as was something you scrolled past. Directly
                // under the header it is read before the first answer.
                // Same font and styling, only moved.
                VStack(alignment: .leading, spacing: 4) {
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
                    Text("줄을 누르면 그 자리에서 예배 순서가 열립니다. 오른쪽 스위치가 참여 여부이고, 옆의 칩으로 파트를 고릅니다.")
                }
                // What a Section footer applies on its own, restated here
                // because the block is no longer in one. The account line
                // keeps its own .caption, as it always had.
                .font(.footnote)
                .foregroundStyle(.secondary)

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
            }
        }
    }

    /// The date as a calendar tile: month above, day below, the way a
    /// calendar icon reads. "Sun, Oct 4" put the least useful word first —
    /// nearly every one of these is a Sunday — and made every row start with
    /// the same three letters.
    private func dateTile(_ date: Date, isSelected: Bool) -> some View {
        VStack(spacing: 0) {
            Text(date, format: .dateTime.month(.abbreviated))
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(isSelected ? Color.accentColor : Color.secondary)
            Text(date, format: .dateTime.day())
                .font(.system(size: 19, weight: .semibold))
                .monospacedDigit()
                .padding(.vertical, 1)
        }
        .frame(width: 42)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    /// Copies what was sung into the standing archive playlist.
    private func archive(_ service: TeamService, songs: [PlanItem]) async {
        let entries = songs.compactMap { item in
            item.videoId.map { ServiceArchive.Song(videoId: $0, title: item.title) }
        }
        _ = await archiveStore.archive(
            entries,
            of: service,
            using: AppServices.client(auth: auth, quota: quota)
        )
    }

    /// Today counts. A service is archivable from its own morning, because
    /// the tap that files the set list happens on the way home.
    private func hasHappened(_ service: TeamService) -> Bool {
        let calendar = Calendar.current
        return calendar.startOfDay(for: service.date)
            <= calendar.startOfDay(for: Date())
    }

    private func isSunday(_ date: Date) -> Bool {
        Calendar.current.component(.weekday, from: date) == 1
    }

    /// What the chip says about my own answer.
    private func answerLabel(_ mine: TeamSignup?) -> String {
        guard let mine else { return "미지정" }
        switch mine.status {
        case .available: return mine.role.isEmpty ? "가능" : mine.role
        default:         return mine.status.label
        }
    }

    /// The switch, both ways.
    ///
    /// On needs a part to answer with: the one already chosen, else the usual
    /// one. With neither, the switch cannot invent an answer, so it opens the
    /// picker instead of turning itself on — the one case where it does not
    /// simply flip.
    private func setAnswered(_ isOn: Bool,
                             for upcoming: TeamService,
                             mine: TeamSignup?) async {
        guard let sheetId, let email = team.actingEmail(auth: auth, planning: planning)
        else { return }

        if isOn {
            let role = !(mine?.role.isEmpty ?? true) ? mine!.role : usualRole
            guard !role.trimmingCharacters(in: .whitespaces).isEmpty else {
                responding = upcoming
                return
            }
            await team.setAvailability(
                .available,
                service: upcoming,
                role: role,
                email: email,
                name: auth.displayName ?? email,
                sheetId: sheetId
            )
        } else {
            await team.clearAvailability(
                service: upcoming,
                email: email,
                sheetId: sheetId
            )
        }
    }

    /// The two parts a service cannot happen without, in the order they are
    /// always shown. Fixed rather than read from the sheet's Order column,
    /// so the row does not reshuffle as the sheet is edited.
    private static let keyRoleNames = ["인도", "반주"]

    private struct KeyPart {
        let role: String
        /// Who has it, by answer or by the leader's plan. Nil means nobody.
        let who: String?
        /// Set only when this came from someone's answer, which is both what
        /// makes it green and what keeps them from appearing twice on the row.
        let signupId: String?
    }

    /// Who holds 인도 or 반주 for a service.
    ///
    /// An answer wins over the sheet's own column: somebody saying "I will
    /// lead" is a stronger fact than a name typed into a plan weeks ago, and
    /// the two disagree often enough to matter.
    private func keyPart(_ role: String,
                         _ service: TeamService,
                         _ answers: [TeamSignup]) -> KeyPart {
        func squashed(_ text: String) -> String {
            text.replacingOccurrences(of: " ", with: "")
        }
        if let answer = answers.first(where: {
            $0.status == .available && squashed($0.role).contains(role)
        }) {
            return KeyPart(role: role,
                           who: answer.name.isEmpty ? answer.email : answer.name,
                           signupId: answer.id)
        }
        // Matched on the key rather than by exact name, because the sheet
        // writes 인도자 and 반주자 as often as 인도 and 반주.
        if let planned = service.assignments.first(where: {
            squashed($0.key).contains(role)
        })?.value, !planned.trimmingCharacters(in: .whitespaces).isEmpty {
            return KeyPart(role: role, who: planned, signupId: nil)
        }
        return KeyPart(role: role, who: nil, signupId: nil)
    }

    private func isFirstOfMonth(_ service: TeamService, in list: [TeamService]) -> Bool {
        guard let index = list.firstIndex(where: { $0.id == service.id }) else { return false }
        guard index > 0 else { return true }
        return !Calendar.current.isDate(list[index - 1].date,
                                        equalTo: service.date, toGranularity: .month)
    }

    /// One service: the date on the left, the service and my answer on the
    /// first line, who else is in on the second, and the 순서 below when it
    /// is open.
    ///
    /// The date tile is the row's left gutter and nothing else sits in that
    /// column, so the tiles line up straight down the list and the schedule
    /// reads as one run of weeks. Previously the answer control shared the
    /// first line with the tile and the chips hung below the whole row, so
    /// every row was a different shape and the dates wandered.
    private func scheduleRow(_ upcoming: TeamService) -> some View {
        let email = team.actingEmail(auth: auth, planning: planning) ?? ""
        let answers = team.responses(for: upcoming)
        let mine = answers.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
        let filled = team.roles.filter { upcoming.assignments[$0.name] != nil }.count
        let open = isOpen(upcoming)

        return HStack(alignment: .top, spacing: 10) {
            dateTile(upcoming.date, isSelected: open)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Button { toggle(upcoming) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(upcoming.title)
                                    .font(.subheadline.weight(open ? .semibold : .regular))
                                    .lineLimit(1)
                                Image(systemName: open ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tint)
                            }
                            HStack(spacing: 6) {
                                // Sunday is the usual answer, so it sits here
                                // rather than in front of the date — and it
                                // is coloured only when it is NOT a Sunday,
                                // which is the part worth noticing.
                                Text(upcoming.date, format: .dateTime.weekday(.abbreviated))
                                    .foregroundStyle(isSunday(upcoming.date)
                                                     ? Color.secondary : Color.orange)
                                if let time = upcoming.time { Text("· \(time)") }
                                if let where_ = upcoming.location { Text("· \(where_)") }
                                if team.roles.count > 0, !upcoming.isRehearsal {
                                    Text("· \(filled)/\(team.roles.count)").monospacedDigit()
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    answerControl(upcoming, mine: mine)
                }

                chipsLine(upcoming, answers: answers)

                if open { serviceDetail(upcoming) }
            }
        }
        .padding(.vertical, 4)
        .id(Calendar.current.startOfDay(for: upcoming.date))
    }

    /// Answering happens on the week it is about — and can be taken back
    /// there too. Plans change, and an answer you cannot withdraw is one
    /// people stop giving honestly.
    ///
    /// The chip picks the part, the switch is the answer itself. Keeping
    /// them apart is what lets the switch mean one thing: on, I am in; off,
    /// I have not answered.
    private func answerControl(_ upcoming: TeamService, mine: TeamSignup?) -> some View {
        HStack(spacing: 8) {
            Button { responding = upcoming } label: {
                HStack(spacing: 3) {
                    if let mine {
                        Circle().fill(tint(mine.status)).frame(width: 6, height: 6)
                    }
                    Text(answerLabel(mine))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(mine.map { tint($0.status).opacity(0.16) }
                                   ?? Color(.secondarySystemBackground))
                )
                .foregroundStyle(mine.map { tint($0.status) } ?? Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(team.isReadOnly)

            Toggle("", isOn: Binding(
                get: { mine?.status == .available },
                set: { isOn in
                    Task { await setAnswered(isOn, for: upcoming, mine: mine) }
                }
            ))
            .labelsHidden()
            .disabled(team.isReadOnly)
            .accessibilityLabel("이 예배에 참여")
        }
        .fixedSize()
    }

    /// 인도 then 반주 then everyone else: the two parts that decide whether a
    /// service can happen lead the line, in that order, whether or not anyone
    /// has them. An empty 인도 is the most important thing on the row, and it
    /// cannot be the absence of a chip.
    private func chipsLine(_ upcoming: TeamService,
                           answers: [TeamSignup]) -> some View {
        let pending = team.pendingNames(for: upcoming)
        let parts = Self.keyRoleNames.map { keyPart($0, upcoming, answers) }
        let spokenFor = Set(parts.compactMap(\.signupId))
        let rest = answers.filter { !spokenFor.contains($0.id) }

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(parts, id: \.role) { part in
                    if let who = part.who {
                        // Green when somebody answered for it, orange when it
                        // is only the leader's plan and that person has not
                        // said yes yet.
                        chip(who, detail: part.role,
                             color: part.signupId == nil ? .orange : .green,
                             dashed: part.signupId == nil)
                    } else {
                        chip("\(part.role) 미지정", detail: nil, color: .red)
                    }
                }
                ForEach(rest) { answer in
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

    /// A chart the team has already made for this song, matched on title.
    private func existingSheet(forTitle title: String) -> SavedSong? {
        let needle = title.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return nil }
        return sheets.first { $0.title.contains(needle) || needle.contains($0.title) }
    }

    private func setAvailability(_ value: SignupStatus, _ service: TeamService, _ role: TeamRole) async {
        guard let sheetId,
              let email = team.actingEmail(auth: auth, planning: planning)
        else { return }
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
