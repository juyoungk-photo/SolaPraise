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
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\SavedSong.createdAt, order: .reverse)])
    private var sheets: [SavedSong]

    @State private var showSettings = false

    @Query(sort: [SortDescriptor(\CachedPlaylist.title)])
    private var allPlaylists: [CachedPlaylist]

    /// A push waiting on confirmation, because it rewrites the sheet the
    /// team reads on Sunday morning.
    /// A playlist waiting to be pushed, as plain values.
    ///
    /// It used to be a CachedPlaylist, which is a SwiftData model — fine for
    /// something pinned in the 찬양 tab, wrong for one the picker just found
    /// in the account or created a moment ago, neither of which is in the
    /// store.
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
    /// Months whose weeks are hidden. Filled on first load with every month
    /// but the one in hand — see monthHeader.
    @State private var foldedMonths: Set<Date> = []
    @State private var addingItemTo: TeamService?
    /// A chart the team already made, opened from a 콘티 row.
    @State private var openChart: SavedSong?
    /// The song a picked audio file will be analysed as.
    @State private var analysing: String?
    /// The chip a leader tapped, and what it was about.
    @State private var assigning: AssignmentTarget?
    /// The service whose 찬양 are being filled from a playlist.
    @State private var fillingFrom: TeamService?
    @State private var buildingPDF = false
    /// The service whose 악보 are open on the stand.
    @State private var standService: TeamService?
    @State private var repairing = false
    @State private var reordering: TeamService?

    /// iPad has room for the chips beside the service; a phone does not, and
    /// on a phone they stay on a second line.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
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
            .sheet(item: $fillingFrom) { service in
                FillFromPlaylistSheet(
                    service: service,
                    pinned: pinnedPlaylists,
                    sheetId: sheetId
                ) { playlistId, title in
                    // Straight in, against THIS service.
                    //
                    // It used to raise a confirmation that then pushed to
                    // `service` — "whichever row is expanded" — rather than
                    // to the one the picker was opened from. With 주일예배 and
                    // 팀연습 on the same day, `.day` matching returns the
                    // first of them, so a 콘티 could land on the wrong
                    // service entirely. The service is right here in the
                    // closure; there is no reason to go looking for it.
                    Task { await push(playlistId, title: title, to: service) }
                }
                .environmentObject(auth)
                .environmentObject(quota)
                .environmentObject(team)
            }
            .sheet(item: $assigning) { target in
                AssignRoleSheet(
                    service: target.service,
                    role: target.role,
                    person: target.person,
                    sheetId: sheetId
                )
                .environmentObject(team)
            }
            .fullScreenCover(item: $live) { LiveServiceView(service: $0) }
            .fullScreenCover(item: $standService) { service in
                ScoreStandView(items: standItems(service))
            }
            .sheet(item: $responding) { ResponseSheet(service: $0) }
            .sheet(item: $addingItemTo) { AddPlanItemSheet(service: $0) }
            .sheet(item: $reordering) { service in
                ReorderPlanSheet(service: service, sheetId: sheetId)
                    .environmentObject(team)
            }
            .navigationDestination(item: $openChart) { LeadSheetView(song: $0) }
            // Picking a file here hands it to 작업실 with the song's name
            // already attached, so the chart comes out labelled rather than
            // called whatever the file was.
            .fileImporter(
                isPresented: Binding(get: { analysing != nil },
                                     set: { if !$0 { analysing = nil } }),
                allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first,
                      let title = analysing else { return }
                StudioInbox.shared.submit(url: url, title: title)
                analysing = nil
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

                    Button("다른 계정·드라이브 권한 연결") {
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
            if let url = teamSheetURL {
                Button { openURL(url) } label: { Image(systemName: "tablecells") }
                    .accessibilityLabel("구글 시트에서 편집")
            }
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
    }

    // MARK: - Content

    /// Who is answering, pinned above the schedule.
    ///
    /// It used to be the first row of the list, where it scrolled away — and
    /// sat directly against the month heading in the same grey, so the two
    /// read as one indeterminate band. It is its own bar now, on the
    /// toolbar's material, with a rule under it.
    private var accountBar: some View {
            // Who is answering, and the way to change it, on one line.
            //
            // No heading above it and no instructions below it. "예배표"
            // named a list that is plainly a list of services, and the
            // sentence explaining that a row opens when you press it was
            // describing a chevron that already says so. A screen that
            // needs a caption is a screen to fix, not to caption.
        VStack(alignment: .leading, spacing: 4) {
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
                        Button("추가 연결 해제") {
                            planning.signOut()
                            team.configure(auth: auth, planning: planning)
                        }
                    } else {
                        Button("다른 계정·드라이브 권한 연결") {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Songs the sheet holds but nothing can read.
    ///
    /// Shown at the very top, before the schedule, because what it
    /// describes is songs MISSING from that schedule — and a warning below a
    /// list of services is read as being about the last of them.
    @ViewBuilder
    private var damagedRowsWarning: some View {
        if !team.damagedSongRows.isEmpty, let sheetId {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("시트에 칸이 밀린 찬양 \(team.damagedSongRows.count)곡이 있습니다",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Songs 탭 \(rowList)번 줄의 내용이 오른쪽으로 \(team.damagedSongRows.first?.shift ?? 0)칸 밀려 있어서 콘티에 보이지 않습니다. 내용은 그대로 남아 있으니 제자리로 옮기면 됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            repairing = true
                            if let failure = await team.repairDamagedSongRows(sheetId: sheetId) {
                                pushNote = failure
                            }
                            repairing = false
                        }
                    } label: {
                        if repairing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("제자리로 옮기기", systemImage: "arrow.left.to.line")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(repairing || team.isReadOnly)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var rowList: String {
        let rows = team.damagedSongRows.map(\.row)
        guard let first = rows.first, let last = rows.last else { return "" }
        // A contiguous run reads as a range; anything else as a list.
        return rows == Array(first...last) && rows.count > 2
            ? "\(first)–\(last)" : rows.map(String.init).joined(separator: ", ")
    }

    /// The way out to the sheet itself.
    ///
    /// The app deliberately does not cover everything the sheet can do —
    /// adding a service, renaming a role, fixing a date typed wrong — and
    /// without a door to it the answer to all of those was "find the URL
    /// somewhere else". It is the same document either way; this is the
    /// team's own planner, and editing it in Sheets is not a fallback.
    @ViewBuilder
    private var sheetLinkSection: some View {
        if TeamSheetSource.current != nil || ChurchSheetSource.current != nil {
            Section {
                if let url = teamSheetURL {
                    Button { openURL(url) } label: {
                        Label("구글 시트에서 편집", systemImage: "tablecells")
                    }
                }
                if let url = ChurchSheetSource.url {
                    Button { openURL(url) } label: {
                        Label("교회 정보 시트 열기", systemImage: "building.columns")
                    }
                }
            } footer: {
                Text("시트에서 바꾼 내용은 이 화면을 아래로 당겨 새로 고치면 반영됩니다.")
            }
        }
    }

    private var teamSheetURL: URL? {
        sheetId.flatMap { URL(string: "https://docs.google.com/spreadsheets/d/\($0)/edit") }
    }

    private func content() -> some View {
        ScrollViewReader { proxy in
            List {
                // One list, and nothing above it. The date and the 순서 used
                // to sit in their own block at the top, describing whichever
                // service was selected far below — so the schedule read as
                // a second, unrelated screen and selecting a row changed
                // something off screen. Every service is now a row that opens
                // where it is, and the next one is open to begin with.
                damagedRowsWarning

                scheduleSection

                if let message = team.errorMessage {
                    Section { Text(message).font(.caption).foregroundStyle(.orange) }
                }

                sheetLinkSection
            }
            // The section lost its header and kept the header's space, so the
            // list started with a band of nothing under the navigation title.
            // Plain, not grouped. The grouped style insets every row and
            // rounds the first and last of a section — which on a schedule
            // whose rows carry no card of their own meant side margins that
            // looked like a second container, and a month label wearing a
            // rounded top edge as if it were the start of one.
            .listStyle(.plain)
            .listSectionSpacing(.compact)
            .safeAreaInset(edge: .top, spacing: 0) { accountBar }
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
                let here = monthStart(next.date)
                foldedMonths = Set(team.services.map { monthStart($0.date) })
                    .subtracting([here])
                proxy.scrollTo(Calendar.current.startOfDay(for: next.date),
                               anchor: .top)
            }
        }
    }

    // MARK: - Order of service

    /// 설교제목 and 헌신찬양, as the church office wrote them.
    ///
    /// Said to come from the church sheet, because it does: nobody on the
    /// worship team can change these from here, and a line that looks
    /// editable but is not is worse than one that says where to go. Absent
    /// entirely when the office has not filled the week in — which is the
    /// normal state of a service three weeks out, and not an error.
    @ViewBuilder
    private func churchNoteBlock(_ service: TeamService) -> some View {
        if let note = team.churchNote(for: service) {
            VStack(alignment: .leading, spacing: 3) {
                if let sermon = note.sermonTitle {
                    churchNoteLine("설교", sermon)
                }
                if let song = note.dedicationSong {
                    churchNoteLine("헌신찬양", song)
                }
                Text("교회 시트에서 가져옴")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        }
    }

    private func churchNoteLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.footnote)
                .textSelection(.enabled)
        }
    }

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

            churchNoteBlock(service)

            if items.isEmpty {
                Text("아직 순서가 없습니다. 아래에서 한 줄씩 더하거나, 재생목록으로 찬양을 한 번에 채울 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    // Swipe a line out of the 순서.
                    //
                    // .swipeActions is a List feature and these rows live in
                    // a VStack inside a row of the schedule, so it does
                    // nothing here — the same reason the player's queue
                    // needed this. Never a full swipe: removing a song from
                    // Sunday by brushing the screen is not a mistake worth
                    // allowing, so the button has to be tapped.
                    SwipeToRemoveRow {
                        Task { await removeItem(item, from: service) }
                    } content: {
                        planRow(item, startsAt: times[item.id], in: service)
                    }
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

            if items.count > 1 {
                Button {
                    reordering = service
                } label: {
                    Label("순서 바꾸기", systemImage: "arrow.up.arrow.down")
                }
                .disabled(team.isReadOnly)
            }

            servicePDFRow(service)

            // A sheet rather than a menu. The menu could only list the
            // playlists pinned in the 찬양 tab — two, on most devices — and
            // the one a leader wants is usually the one they just built and
            // never pinned. The sheet lists everything in the account, and
            // carries the + that makes this service its own.
            Button {
                fillingFrom = service
            } label: {
                HStack {
                    Label("재생목록에서 찬양 채우기", systemImage: "square.and.arrow.down")
                    Spacer()
                    if isPushing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isPushing)

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

    private func planRow(_ item: PlanItem, startsAt: Date?,
                         in service: TeamService) -> some View {
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
                    if item.kind == .song, let chart = existingSheet(forTitle: item.title) {
                        // Tappable. It used to be a label that said a chart
                        // existed and gave you no way to it — the one place
                        // in the app that knew the team had already worked
                        // this song out, and a dead end.
                        Button { openChart = chart } label: {
                            Label("악보", systemImage: "music.quarternote.3")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let notes = item.notes {
                    Text(notes).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if item.kind == .song {
                Menu {
                    Section {
                        Button {
                            analysing = item.title
                        } label: {
                            Label("이 곡 분석하기", systemImage: "waveform.badge.magnifyingglass")
                        }
                    }
                    SheetMusicLinks(title: item.title)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Songs only. 악보 belong to a song; a 대표기도 or a 광고 line
            // has nothing to attach, and a clip on every row turned the
            // 순서 into a column of identical icons.
            if item.kind == .song {
            AttachmentMenu(service: service, song: item.title, sheetId: sheetId) {
                let count = team.attachments(for: service, song: item.title).count
                HStack(spacing: 2) {
                    Image(systemName: count > 0 ? "paperclip.circle.fill" : "paperclip")
                    if count > 1 {
                        Text("\(count)").font(.caption2.monospacedDigit())
                    }
                }
                .font(.footnote)
                .foregroundStyle(count > 0 ? Color.accentColor : .secondary)
                .frame(minWidth: 30, minHeight: 40)
                .contentShape(Rectangle())
            }
            .environmentObject(team)
            .environmentObject(auth)
            .environmentObject(planning)
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

    /// One document for the Sunday: the 순서, then every 악보 behind it.
    ///
    /// On a music stand you want one thing to swipe through, not eleven
    /// links. Rebuilt rather than cached, because the attachments change
    /// right up to Saturday night and a stale PDF is worse than none — the
    /// whole point is that whoever opens it has the current one.
    @ViewBuilder
    private func servicePDFRow(_ service: TeamService) -> some View {
        let built = team.attachments(for: service).first(where: \.belongsToService)
        let pieces = team.attachments(for: service).filter { !$0.belongsToService }

        // Shown as soon as the service has songs, not only once something
        // has been attached. Gating it on attachments made the one line
        // that explains the feature unreachable until you had already
        // worked the feature out.
        if team.plan(for: service).contains(where: { $0.kind == .song }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Button {
                        Task { await buildServicePDF(service) }
                    } label: {
                        Label(built == nil ? "콘티 PDF 만들기" : "콘티 PDF 다시 만들기",
                              systemImage: "doc.badge.arrow.up")
                    }
                    .disabled(buildingPDF || pieces.isEmpty)

                    if buildingPDF { ProgressView().controlSize(.small) }
                }

                // Every chart in the order it is played, each in the key
                // the 순서 gives it — the set, on one stand.
                if !pieces.isEmpty {
                    Button { standService = service } label: {
                        Label("악보 연주모드", systemImage: "music.note.list")
                    }
                }

                if let built {
                    Button { openURL(built.url) } label: {
                        Label("콘티 PDF 열기", systemImage: "doc.richtext")
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(pieces.isEmpty
                     ? "곡에 악보를 첨부하면 한 파일로 묶을 수 있습니다."
                     : "악보 \(pieces.count)개를 순서대로 묶습니다. 팀원은 링크로 바로 봅니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The service's song charts in 순서 order, each with the key the 순서
    /// gives that song.
    private func standItems(_ service: TeamService) -> [ScoreStandItem] {
        let plan = team.plan(for: service)
        let order = plan.enumerated().reduce(into: [String: Int]()) { out, pair in
            out[pair.element.title] = pair.offset
        }
        return team.attachments(for: service)
            .filter { !$0.belongsToService }
            .sorted { (order[$0.song] ?? .max) < (order[$1.song] ?? .max) }
            .map { item in
                ScoreStandItem(attachment: item, song: item.song,
                               teamKey: plan.first { $0.title == item.song }?.key)
            }
    }

    private func buildServicePDF(_ service: TeamService) async {
        guard let sheetId else { return }
        buildingPDF = true
        pushNote = nil
        defer { buildingPDF = false }

        let plan = team.plan(for: service)
        let order = plan.enumerated().reduce(into: [String: Int]()) { out, pair in
            out[pair.element.title] = pair.offset
        }
        // Behind the 순서 they are played in, not the order they happened to
        // be uploaded — the document is for reading top to bottom.
        let pieces = team.attachments(for: service)
            .filter { !$0.belongsToService }
            .sorted { (order[$0.song] ?? .max) < (order[$1.song] ?? .max) }

        var sources: [ServicePDF.Source] = []
        for item in pieces {
            // URLSession, not Data(contentsOf:): that blocked the main
            // thread for every download in turn, freezing the screen for
            // as long as the slowest chart took.
            guard let (data, _) = try? await URLSession.shared.data(from: item.url.directDownload)
            else { continue }
            sources.append(.init(name: item.name, song: item.song, data: data))
        }
        guard !sources.isEmpty else {
            pushNote = "첨부 파일을 불러오지 못했습니다."
            return
        }

        guard let pdf = ServicePDF.build(
            service: service, plan: plan,
            note: team.churchNote(for: service), sources: sources
        ) else {
            pushNote = "PDF를 만들지 못했습니다."
            return
        }

        let day = TeamSheet.dateFormatter.string(from: service.date)
        let who = team.actingEmail(auth: auth, planning: planning) ?? ""

        // Replace rather than accumulate: a service has one current 콘티 PDF
        // and a list of five dated ones is a list nobody reads.
        if let old = team.attachments(for: service).first(where: \.belongsToService) {
            _ = await team.removeAttachment(old, sheetId: sheetId)
        }
        if let failure = await team.attach(
            data: pdf, name: "\(day)-콘티.pdf", mimeType: "application/pdf",
            song: "", to: service, sheetId: sheetId, by: who
        ) {
            pushNote = failure
        }
    }

    private func removeItem(_ item: PlanItem, from service: TeamService) async {
        guard let sheetId else { return }
        pushNote = nil
        if let failure = await team.removePlanItem(item, from: service, sheetId: sheetId) {
            pushNote = failure
        }
    }

    // MARK: - Pushing the 콘티

    private func push(_ playlistId: String, title: String, to service: TeamService) async {
        guard let sheetId else { return }
        isPushing = true
        pushNote = nil
        defer { isPushing = false }

        let client = AppServices.client(auth: auth, quota: quota)
        guard let items = try? await client.playlistItems(playlistId: playlistId) else {
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
        // caption2 read as a footnote on names that are the point of
        // the row. One step up, and a point of width with it.
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        // Lifted a step. At 0.14 a filled chip sat almost flat against the
        // row and the colour was doing all the work; the fill should be
        // readable as a fill.
        .background(Capsule().fill(color.opacity(dashed ? 0.11 : 0.22)))
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
                ForEach(future) { upcoming in
                    // A month label where the month turns, so scrolling
                    // through a quarter does not become undifferentiated.
                    if isFirstOfMonth(upcoming, in: future) {
                        monthHeader(for: upcoming, in: future)
                    }
                    if !isFolded(upcoming) {
                    scheduleRow(upcoming)
                        // Dimmed, not hidden. Last Sunday is a record, not a
                        // decision, so it should be findable without
                        // competing with the week you still have to answer.
                        .opacity(upcoming.isPast ? 0.55 : 1)
                        // No panel under every row. The list drew one behind
                        // the whole schedule, which competed with the lit
                        // panel that marks the open service — two highlights
                        // for one thing. The open one is the only one now.
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        // The row owns its own spacing, so services sit a
                        // fixed distance apart instead of floating on
                        // whatever padding the list felt like adding.
                        .listRowInsets(EdgeInsets(top: 0, leading: 8,
                                                  bottom: 0, trailing: 12))
                    }
                }
            }
        }
    }

    /// A month, and whether its weeks are showing.
    ///
    /// A year of Sundays is a long scroll to answer three of them, so months
    /// other than the one in hand arrive folded: the header says how many
    /// are in there and opens them when tapped. The month holding the open
    /// service is always showing, because that is the one you came for.
    private func monthHeader(for service: TeamService,
                             in list: [TeamService]) -> some View {
        let month = monthStart(service.date)
        let count = list.filter { monthStart($0.date) == month }.count
        let folded = foldedMonths.contains(month)
        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                if folded { foldedMonths.remove(month) }
                else { foldedMonths.insert(month) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(service.date, format: .dateTime.year().month(.wide))
                    .font(.caption2.weight(.semibold))
                Image(systemName: folded ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                if folded {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                VStack { Divider() }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 14)
        .padding(.bottom, 2)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    private func monthStart(_ date: Date) -> Date {
        Calendar.current.date(from:
            Calendar.current.dateComponents([.year, .month], from: date)) ?? date
    }

    /// The month holding the open service never folds, whatever is in the set.
    private func isFolded(_ service: TeamService) -> Bool {
        let month = monthStart(service.date)
        if let open = self.service, monthStart(open.date) == month { return false }
        return foldedMonths.contains(month)
    }

    /// The gold rule beside a week still waiting on you.
    ///
    /// Off while the gold answer track carries that on its own — two marks
    /// for one fact was more emphasis than the row needed. The drawing stays
    /// so turning it back on is one `true`.
    private static let showsNeedsAnswerBar = false

    /// Shared by the row's padding and by anything aligning to the tile, so
    /// the two cannot drift apart again.
    private static let rowVerticalPadding: CGFloat = 10

    /// What dateTile comes out at: month strip, day, weekday, and the
    /// padding around them.
    private var tileHeight: CGFloat { isWide ? 58 : 50 }

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
        let outcome = await archiveStore.archive(
            entries,
            of: service,
            using: AppServices.client(auth: auth, quota: quota)
        )
        // Pin it to 찬양 the moment its id is known.
        //
        // The archive is created per account by findOrCreate, so there is no
        // fixed id to ship as a default — the first archive is the first
        // time anyone can know it. It is the team's standing collection of
        // what has actually been sung, which is exactly the thing worth
        // having at the top of the 찬양 tab beside the week's 콘티.
        if let outcome {
            SharedPlaylistSync.pin(
                id: outcome.playlistId,
                title: ServiceArchive.playlistTitle,
                context: modelContext
            )
        }
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

    /// What a tapped chip was about: a part, a person, or both.
    struct AssignmentTarget: Identifiable {
        let service: TeamService
        let role: String?
        let person: String?
        var id: String { "\(service.id)-\(role ?? "")-\(person ?? "")" }
    }

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
        if let answer = answers.first(where: {
            $0.status == .available && PartAliases.matches($0.role, role)
        }) {
            return KeyPart(role: role,
                           who: displayName(answer),
                           signupId: answer.id)
        }
        // Through PartAliases, so a sheet that writes 인도자, 반주자 or Piano
        // answers for 인도 and 반주. Somebody on Piano HAS staffed 반주, and
        // showing 「반주 미지정」 beside them was the screen failing to
        // understand its own schedule.
        if let planned = service.assignments.first(where: {
            PartAliases.matches($0.key, role)
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

                                // What this Sunday is about, from the church
                                // sheet. On the closed row because it is the
                                // question asked of a service you have not
                                // opened; 헌신찬양 waits inside, where the
                                // 순서 it belongs beside is.
                                if let sermon = team.churchNote(for: upcoming)?.sermonTitle {
                                    Text(sermon)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
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
                        chipsLine(upcoming, answers: answers, open: open)
                        Spacer(minLength: 8)
                    }

                    answerControl(upcoming, mine: mine,
                                  shown: shown, needsAnswer: needsAnswer)
                }

                if !isWide {
                    chipsLine(upcoming, answers: answers, open: open)
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
                    // Grows downward from the row rather than appearing all
                    // at once: the 순서 belongs to the service above it, and
                    // seeing it unroll from there is what says so.
                    serviceDetail(upcoming)
                        // One tap, one action.
                        //
                        // Every action under a service — 찬양만 이어 듣기, 순서
                        // 추가, 순서 바꾸기, 채우기 — sits inside a single row
                        // of the schedule List, and a List treats default-
                        // style Buttons in one row as one tap target: they
                        // ALL fired, and the last sheet set won. Pressing
                        // 순서 바꾸기 opened 재생목록에서 채우기; pressing 순서
                        // 추가 also started a song. Borderless makes each
                        // button its own target, and propagates to every one
                        // inside, including those added later.
                        .buttonStyle(.borderless)
                        .padding(.leading, isWide ? 62 : 54)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top)
                                .combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
        }
        .padding(.vertical, Self.rowVerticalPadding)
        .padding(.leading, 9)
        // The open service stands slightly off the page.
        //
        // Its 순서 sits inside it, so without a boundary the detail read as
        // loose rows belonging to the whole list rather than to one Sunday.
        // A lit panel rather than a border: it says "this one" without
        // drawing a box around half the screen.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(open ? Color.primary.opacity(0.10) : Color.clear)
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
            // Off for now — see showsNeedsAnswerBar.
            //
            // Its height and offset were hand-numbers that stopped matching
            // the tile the moment the row's padding changed, so it sat a few
            // points high and short of the tile it was meant to mark. Tied
            // to the same numbers the tile uses now, rather than guessed.
            if Self.showsNeedsAnswerBar, needsAnswer {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: tileHeight)
                    .padding(.top, Self.rowVerticalPadding)
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
        // A Sunday that has happened is a record, not a question.
        //
        // The control stayed live on past weeks, so a mis-tap while scrolling back
        // through the season rewrote who had been there — and the answer it
        // overwrote was the only record of it. Nothing is owed on a service
        // that is over, and nothing should be changeable about it either.
        .disabled(upcoming.isPast)
        .opacity(upcoming.isPast ? 0.45 : 1)
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
                           answers: [TeamSignup],
                           open: Bool) -> some View {
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
        return ChipFlow { chips(upcoming, parts, rest, pending, open: open) }
    }

    /// Whether this account may put other people's names on the schedule.
    /// See TeamStore.canAssign — this is the team's own decision, not a
    /// security boundary, and the sheet remains the thing that enforces.
    private var canAssign: Bool {
        team.canAssign(email: team.actingEmail(auth: auth, planning: planning))
    }

    /// A chip a leader can act on, wrapped so it opens the assignment sheet.
    ///
    /// onTapGesture rather than a Button: these sit inside a row that is
    /// itself a Button, and nesting them swallowed the tap entirely — the
    /// same trap this project has now hit on playlist rows, the player queue
    /// and the pinned videos.
    @ViewBuilder
    private func assignable(_ service: TeamService,
                            role: String?,
                            person: String?,
                            @ViewBuilder _ content: () -> some View) -> some View {
        // Same rule as the answer control: a Sunday that has happened is a
        // record. Re-assigning it by mis-tap would rewrite who actually led.
        if canAssign, !service.isPast {
            content()
                .contentShape(Capsule())
                .onTapGesture {
                    assigning = AssignmentTarget(
                        service: service,
                        // The chip says 인도; the sheet's column may say
                        // 인도자. Resolve to the sheet's spelling here so the
                        // picker opens on a part that actually exists.
                        role: role.flatMap { team.scheduleRoleName(matching: $0) } ?? role,
                        person: person
                    )
                }
        } else {
            content()
        }
    }

    @ViewBuilder
    private func chips(_ service: TeamService,
                       _ parts: [KeyPart],
                       _ rest: [TeamSignup],
                       _ pending: [String],
                       open: Bool) -> some View {
        ForEach(parts, id: \.role) { part in
            assignable(service, role: part.role, person: nil) {
                if let who = part.who {
                    // Green when somebody answered for it, orange when it is
                    // only the leader's plan and that person has not said yes
                    // yet.
                    chip(who, detail: part.role,
                         color: part.signupId == nil ? .orange : .green,
                         dashed: part.signupId == nil)
                } else {
                    chip("\(part.role) 미지정", detail: nil, color: .red)
                }
            }
        }
        ForEach(rest) { answer in
            // "주영 인도" reads as a fact about Sunday.
            // "주영 가능" reads as a form someone filled in.
            assignable(service, role: nil, person: displayName(answer)) {
                chip(
                    displayName(answer),
                    detail: answer.status == .available
                        ? (answer.role.isEmpty ? nil : answer.role)
                        : answer.status.label,
                    color: tint(answer.status)
                )
            }
        }
        // Closed, the people who have not answered are one chip saying how
        // many; open, they are named.
        //
        // Just the name was right — the hollow grey ring already says "has
        // not answered", so the word was restating the style. But on a team
        // of seven the names alone still ran to three rows on a phone, and
        // most of them were people who have done nothing. The ones who
        // ANSWERED are the news; the count is enough for the rest until you
        // open the week and want to chase someone.
        if open {
            ForEach(pending, id: \.self) { who in
                assignable(service, role: nil, person: who) {
                    chip(who, detail: nil, color: .secondary, dashed: true)
                }
            }
        } else if !pending.isEmpty {
            chip("미응답 \(pending.count)", detail: nil,
                 color: .secondary, dashed: true)
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
