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
                // No scrolling. Opening a row used to pull it to the top of
                // the screen, which moved everything the eye was holding on
                // to — you tapped a week and the list jumped somewhere else.
                // The row opens where it already is.
                expansion = .day(candidate.date)
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

    /// What the switch was asked to be, per service, while the write is in
    /// flight — see answerControl.
    /// The answer a row was just given, held until the write settles. The
    /// stored value does not change until the sheet has been written, so
    /// without this a button would light up and go straight back out.
    @State private var inFlight: [String: SignupStatus?] = [:]
    /// Why a particular row's answer did not take.
    @State private var rowError: [String: String] = [:]
    /// Done once per appearance of the list, not on every layout pass.
    @State private var didLandOnUpcoming = false
    @State private var addingItemTo: TeamService?

    /// iPad has room for the chips beside the service; a phone does not, and
    /// on a phone they stay on a second line.
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isWide: Bool { sizeClass == .regular }

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
            .sheet(item: $addingItemTo) { AddPlanItemSheet(service: $0) }
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
            // The section lost its header and kept the header's space, so the
            // list started with a band of nothing under the navigation title.
            .listSectionSpacing(.compact)
            .onAppear {
                scrollTo = { id in proxy.scrollTo(id, anchor: .top) }
                // Land on the next service, not on the oldest one.
                //
                // With past weeks above, opening the tab would otherwise
                // start months back. This is the one scroll the screen does:
                // tapping a row still opens it where it sits, because moving
                // the page under a finger that just pressed something is the
                // thing that was wrong before.
                guard !didLandOnUpcoming, let next = team.upcoming else { return }
                didLandOnUpcoming = true
                proxy.scrollTo(Calendar.current.startOfDay(for: next.date),
                               anchor: .top)
            }
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
                Text("아직 순서가 없습니다. 아래에서 한 줄씩 더하거나, 재생목록으로 찬양을 한 번에 채울 수 있습니다.")
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

            Button {
                addingItemTo = service
            } label: {
                Label("순서 추가", systemImage: "plus.circle")
            }
            .disabled(team.isReadOnly)

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
                    Text("지금은 Songs 탭의 찬양만 보여 주고 있습니다. 시트에 Plan 탭이 있으면 기도·설교·광고까지 시간과 함께 나옵니다.")
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
        case .maybe:     return .yellow
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
        // Past services stay, above the upcoming ones, oldest first.
        //
        // They were filtered out, which threw away the only record of what
        // the team actually sang — and took the 보관 button with it, since
        // that only appears once a service has happened and the row vanished
        // the moment it did. A schedule that forgets last Sunday the instant
        // it is over is a schedule you cannot look back at.
        let future = team.services.sorted { $0.date < $1.date }
        if !future.isEmpty {
            Section {
                // Who is answering, and the way to change it, on one line.
                //
                // No heading above it and no instructions below it. "예배표"
                // named a list that is plainly a list of services, and the
                // sentence explaining that a row opens when you press it was
                // describing a chevron that already says so. A screen that
                // needs a caption is a screen to fix, not to caption.
                HStack(spacing: 6) {
                    Group {
                        if let email = team.actingEmail(auth: auth, planning: planning) {
                            Text("로그인 계정: ").foregroundStyle(.secondary)
                                + Text(email)
                        } else {
                            Text("로그인된 계정이 없습니다").foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)

                    Menu {
                        if planning.isSignedIn {
                            Button("교회 계정 연결 해제") {
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
                    } label: {
                        // Tinted, not systemBackground: on a dark row that
                        // fill is the same colour as what is behind it, and
                        // the chip read as plain text rather than as
                        // something to press.
                        Text("계정 변경")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .font(.caption)

                if let message = planning.lastError {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

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
                        // Dimmed, not hidden. Last Sunday is a record, not a
                        // decision, so it should be findable without
                        // competing with the week you still have to answer.
                        .opacity(upcoming.isPast ? 0.55 : 1)
                }
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
                .font(.system(size: isWide ? 11 : 10, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(isSelected ? Color.accentColor : Color.secondary)
            Text(date, format: .dateTime.day())
                .font(.system(size: isWide ? 23 : 19, weight: .semibold))
                .monospacedDigit()
            // The weekday, where a calendar icon puts it. It used to sit in
            // the detail line beside the time, which is where you look for
            // "when", not for "which day" — and on a tile it costs nothing.
            // Coloured when it is not a Sunday, which is the exception worth
            // catching.
            Text(date, format: .dateTime.weekday(.abbreviated))
                .font(.system(size: isWide ? 10 : 9, weight: .medium))
                .foregroundStyle(isSunday(date) ? Color.secondary : Color.orange)
                .padding(.bottom, 2)
        }
        .frame(width: isWide ? 52 : 44)
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

    /// What to call somebody: the roster's name first.
    ///
    /// A signup row carries whatever name the app knew when it was written,
    /// which for a Google account is the profile name — "Juyoung Kim", not
    /// what the team calls anyone. The Members tab is where that is decided.
    private func displayName(_ signup: TeamSignup) -> String {
        if let roster = team.rosterName(for: signup.email) { return roster }
        if !signup.name.isEmpty { return signup.name }
        // Last resort, the part before the @. A full address in a chip is
        // both unreadable and wider than the chip, and it is a name the
        // person never chose.
        return signup.email.split(separator: "@").first.map(String.init)
            ?? signup.email
    }

    private func isSunday(_ date: Date) -> Bool {
        Calendar.current.component(.weekday, from: date) == 1
    }

    /// What the chip says about my own answer.
    private func answerLabel(_ mine: TeamSignup?, shown: SignupStatus?) -> String {
        guard let shown else { return "미지정" }
        if shown == .available, let role = mine?.role, !role.isEmpty { return role }
        return shown.label
    }

    /// Records one of the three answers.
    ///
    /// 가능 needs a part to be filed against: the one already chosen, else
    /// the usual one, else the first the sheet lists. The other two are true
    /// of every part at once, so they never ask.
    private func record(_ status: SignupStatus, for upcoming: TeamService) async {
        let key = upcoming.id
        rowError[key] = nil
        inFlight[key] = .some(status)
        defer { inFlight[key] = nil }

        guard let sheetId else {
            rowError[key] = "팀 시트가 연결되어 있지 않습니다. 설정에서 시트를 연결하세요."
            return
        }
        guard let email = team.actingEmail(auth: auth, planning: planning) else {
            rowError[key] = "응답할 계정이 없습니다. 로그인하거나 교회 계정을 연결하세요."
            return
        }

        let existing = team.responses(for: upcoming)
            .first { team.isMe($0.email, auth: auth, planning: planning) }
        let part = [existing?.role, usualRole, team.roles.first?.name]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "참여"
        if status == .available { usualRole = part }

        await team.setAvailability(
            status, service: upcoming, role: part,
            email: email, name: auth.displayName ?? email, sheetId: sheetId
        )
        if let message = team.errorMessage { rowError[key] = message }
    }

    /// Takes the answer back, under every address that is me.
    private func clearAnswer(for upcoming: TeamService) async {
        let key = upcoming.id
        rowError[key] = nil
        inFlight[key] = .some(nil)
        defer { inFlight[key] = nil }

        guard let sheetId else {
            rowError[key] = "팀 시트가 연결되어 있지 않습니다. 설정에서 시트를 연결하세요."
            return
        }
        let ok = await team.clearAvailability(
            service: upcoming,
            emails: team.myAddresses(auth: auth, planning: planning),
            sheetId: sheetId
        )
        if !ok {
            rowError[key] = team.errorMessage
                ?? "응답을 취소하지 못했습니다. 시트에 쓰지 못했습니다."
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
                           who: displayName(answer),
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
        let answers = team.responses(for: upcoming)
        let mine = answers.first { team.isMe($0.email, auth: auth, planning: planning) }
        let open = isOpen(upcoming)
        let shown = inFlight[upcoming.id] ?? mine?.status
        let needsAnswer = shown == nil && !upcoming.isPast

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 10) {
                    // The tile and the service name are one target. The tile
                    // sat outside the button and did nothing when pressed —
                    // which is the part of the row a finger goes to first,
                    // because it is the part that looks like a thing.
                    Button { toggle(upcoming) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            dateTile(upcoming.date, isSelected: open)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(upcoming.title)
                                        .font(.subheadline.weight(open ? .semibold : .regular))
                                        .lineLimit(1)
                                    Image(systemName: open ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tint)
                                }
                                // Time and place, and nothing else.
                                //
                                // There used to be a "0/6" here: roles filled
                                // over roles that exist. It counted the
                                // Schedule tab's assignment columns, which is
                                // not where anyone answers — so it read 0/6
                                // on a week four people had already said yes
                                // to. The chips on the next line say who is
                                // in, by name, which is the thing that was
                                // being approximated.
                                HStack(spacing: 6) {
                                    if let time = upcoming.time { Text(time) }
                                    if let where_ = upcoming.location { Text("· \(where_)") }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            // Fixed on iPad so the chips beside it start at
                            // the same x on every row; elastic on a phone,
                            // where it is the only thing on the line.
                            .frame(maxWidth: isWide ? 230 : .infinity,
                                   alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: isWide, vertical: false)

                    if isWide {
                        chipsLine(upcoming, answers: answers)
                        Spacer(minLength: 8)
                    }

                    answerControl(upcoming, mine: mine,
                                  shown: shown, needsAnswer: needsAnswer)
                }

                if !isWide {
                    chipsLine(upcoming, answers: answers)
                        .padding(.leading, 54)
                }

                // Why this row's answer did not take, where the answer was
                // given. It used to land in a section at the very bottom of a
                // schedule that runs months deep, which for a failure you are
                // looking straight at is the same as saying nothing.
                if let message = rowError[upcoming.id] {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.leading, isWide ? 62 : 54)
                }

                if open {
                    serviceDetail(upcoming).padding(.leading, isWide ? 62 : 54)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 9)
        // The open service stands slightly off the page.
        //
        // Its 순서 sits inside it, so without a boundary the detail read as
        // loose rows belonging to the whole list rather than to one Sunday.
        // A lit panel rather than a border: it says "this one" without
        // drawing a box around half the screen.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(open ? Color.primary.opacity(0.05) : Color.clear)
                .padding(.horizontal, -8)
                .padding(.vertical, -2)
        )
        // A rule down the edge of a week still waiting on you.
        //
        // The space is reserved on every row, painted on only some, so the
        // date tiles still start at the same x all the way down — the column
        // is the thing that makes the month scannable, and a bar that pushed
        // some rows sideways would cost more than it bought.
        .overlay(alignment: .topLeading) {
            if needsAnswer {
                // Beside the date, not down the whole row.
                //
                // Full height it ran the length of a row that on a phone is
                // two lines of wrapped chips tall — a long stripe next to a
                // track that is already gold, which is emphasis rather than
                // information. Cropped to the tile it reads as a mark on the
                // week itself, and the eye still finds it scanning the
                // column.
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: isWide ? 48 : 44)
                    .padding(.top, 8)
            }
        }
        .id(Calendar.current.startOfDay(for: upcoming.date))
    }

    /// Answering happens on the week it is about — and can be taken back
    /// there too. Plans change, and an answer you cannot withdraw is one
    /// people stop giving honestly.
    ///
    /// The menu picks the part in one gesture. It used to open a sheet: tap
    /// the chip, wait for the sheet, pick a part, close it, then find the
    /// switch — five steps to say "I'll lead". A part IS the answer, so
    /// choosing one from the menu answers as well.
    ///
    /// The switch stays for the thing it is good at: in or out, without
    /// thinking about which part.
    private func answerControl(_ upcoming: TeamService,
                               mine: TeamSignup?,
                               shown: SignupStatus?,
                               needsAnswer: Bool) -> some View {
        let key = upcoming.id
        return HStack(spacing: 8) {
            Menu {
                Section("맡을 파트") {
                    ForEach(team.roles) { role in
                        Button {
                            Task { await choose(role.name, for: upcoming) }
                        } label: {
                            if shown == .available, mine?.role == role.name {
                                Label(role.name, systemImage: "checkmark")
                            } else {
                                Text(role.name)
                            }
                        }
                    }
                }
                // Only the part lives in here now. 어려움 and 자리비움 were in
                // this menu, which is labelled 맡을 파트 and shaped like a
                // picker — asking "which part are you not doing?" to say you
                // cannot come. They are buttons of their own below.
                Section {
                    if mine != nil {
                        Button(role: .destructive) {
                            Task { await clearAnswer(for: upcoming) }
                        } label: { Label("응답 취소", systemImage: "arrow.uturn.backward") }
                    }
                    Button {
                        responding = upcoming
                    } label: { Label("누가 뭘 맡았는지 보기", systemImage: "person.2") }
                }
            } label: {
                HStack(spacing: 3) {
                    if let shown {
                        Circle().fill(tint(shown)).frame(width: 6, height: 6)
                    }
                    Text(answerLabel(mine, shown: shown))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(shown.map { tint($0).opacity(0.16) }
                                   ?? Color(.secondarySystemBackground))
                )
                .foregroundStyle(shown.map { tint($0) } ?? Color.secondary)
            }
            .disabled(team.isReadOnly)

            // Three answers, three segments, all three visible.
            //
            // A switch has two positions and there are three things to say —
            // yes, not sure, no — so "off" was carrying both "I cannot come"
            // and "I have not answered", which are opposite things to a
            // leader looking for a gap.
            //
            // They sit in a trough rather than floating free. Three outlined
            // glyphs on the page read as status being REPORTED; the same
            // three in a track, with one of them raised, read as a choice
            // being OFFERED. That is the whole difference between a row that
            // looks informative and a row that looks like a question.
            // An unanswered week wears the accent until it is answered.
            //
            // A grey track reads the same whether you have answered or not,
            // so a schedule of unanswered weeks was as quiet as a schedule
            // of finished ones — and the screen exists to collect answers.
            // Tinted, the rows still waiting on you are the loud ones and
            // the done ones recede. Only for weeks still ahead: nothing is
            // owed on a Sunday that has already happened.
            HStack(spacing: 0) {
                answerButton(.available, "checkmark", upcoming, shown,
                             needsAnswer: needsAnswer)
                answerButton(.maybe, "questionmark", upcoming, shown,
                             needsAnswer: needsAnswer)
                answerButton(.declined, "xmark", upcoming, shown,
                             needsAnswer: needsAnswer)
            }
            .padding(2)
            .background(
                Capsule().fill(needsAnswer
                               ? Color.accentColor.opacity(0.16)
                               : Color(.tertiarySystemFill))
            )
            .overlay(
                Capsule().strokeBorder(
                    needsAnswer ? Color.accentColor.opacity(0.55)
                                : Color.primary.opacity(0.10),
                    lineWidth: needsAnswer ? 1 : 0.5
                )
            )
        }
        .layoutPriority(1)
    }

    /// One segment of the three. Pressing the chosen one takes the answer
    /// back, so every segment is its own undo.
    private func answerButton(_ status: SignupStatus,
                              _ symbol: String,
                              _ upcoming: TeamService,
                              _ shown: SignupStatus?,
                              needsAnswer: Bool = false) -> some View {
        let isOn = shown == status
        return Button {
            Task {
                if isOn { await clearAnswer(for: upcoming) }
                else { await record(status, for: upcoming) }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                // Solid when chosen, so the answer is the thing that stands
                // out rather than the control around it. Yellow needs a dark
                // glyph; the other two carry white.
                .foregroundStyle(isOn
                                 ? (status == .maybe ? Color.black : Color.white)
                                 : (needsAnswer
                                    ? Color.accentColor.opacity(0.85)
                                    : Color.secondary))
                .frame(width: 34, height: 28)
                .background(
                    Capsule().fill(isOn ? tint(status) : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(team.isReadOnly || inFlight[upcoming.id] != nil)
        .accessibilityLabel(status.label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// Picking a part is answering: one gesture, not a sheet and a switch.
    private func choose(_ role: String, for upcoming: TeamService) async {
        guard let sheetId, let email = team.actingEmail(auth: auth, planning: planning)
        else { return }
        usualRole = role
        await team.setAvailability(
            .available, service: upcoming, role: role,
            email: email, name: auth.displayName ?? email, sheetId: sheetId
        )
    }

    private func answer(_ status: SignupStatus,
                        for upcoming: TeamService, role: String?) async {
        guard let sheetId, let email = team.actingEmail(auth: auth, planning: planning)
        else { return }
        // Declining does not need a part — "I cannot come" is true of every
        // part at once. It used to open the picker and ask which one you
        // were not doing.
        let part = (role?.isEmpty == false ? role!
                    : (usualRole.isEmpty ? (team.roles.first?.name ?? "참여") : usualRole))
        await team.setAvailability(
            status, service: upcoming, role: part,
            email: email, name: auth.displayName ?? email, sheetId: sheetId
        )
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

        // Wrapping on both sizes.
        //
        // iPad used to keep them on one scrolling line so every row stayed
        // the same height, which made the month scannable — but it also hid
        // half the team behind a scroll nobody tries, on the row whose job is
        // to say who is on. Seeing everyone beats rows of equal height.
        return ChipFlow { chips(parts, rest, pending) }
    }

    @ViewBuilder
    private func chips(_ parts: [KeyPart],
                       _ rest: [TeamSignup],
                       _ pending: [String]) -> some View {
        ForEach(parts, id: \.role) { part in
            if let who = part.who {
                // Green when somebody answered for it, orange when it is only
                // the leader's plan and that person has not said yes yet.
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
                displayName(answer),
                detail: answer.status == .available
                    ? (answer.role.isEmpty ? nil : answer.role)
                    : answer.status.label,
                color: tint(answer.status)
            )
        }
        // Just the name. The hollow grey ring already says "has not
        // answered" — it is the only chip drawn that way — so repeating the
        // word on every one of them spent a third of the line restating what
        // the style says, and pushed a team of seven onto three rows.
        ForEach(pending, id: \.self) { who in
            chip(who, detail: nil, color: .secondary, dashed: true)
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
