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
    /// Acted on, not drawn — see Unobserved.
    @Environment(\.playerActions) private var host: PlayerHost!
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

    @Environment(\.quotaLedger) private var quota: QuotaLedger!   // for clients only — see Unobserved

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
    @State private var showHealth = false

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
    /// A chart the team already made, opened from a 콘티 row.
    @State private var openChart: SavedSong?
    /// The song a picked audio file will be analysed as.
    /// The chip a leader tapped, and what it was about.
    @State private var assigning: AssignmentTarget?
    /// The service whose 찬양 are being filled from a playlist.
    @State private var fillingFrom: TeamService?
    /// A playlist's songs read and waiting for their titles to be checked.
    @State private var reviewing: PushReview?
    struct PushReview: Identifiable {
        let service: TeamService
        let playlistTitle: String
        var songs: [TeamSong]
        /// Open at once, while the playlist and the Songs tab are read.
        var loading = false
        /// What the service already has on the Songs tab, to merge with.
        var existing: [TeamSong] = []
        /// The title each video carries on the sheet, read once.
        var sheetTitles: [String: String] = [:]
        let id = UUID()
    }
    @State private var exportingTo: TeamService?
    /// The playlist chosen in the picker, filled in once it has closed —
    /// the review opens then, not over a sheet still going away.
    @State private var pendingFill: (playlistId: String, title: String, service: TeamService)?
    @State private var buildingPDF = false
    /// The service whose 악보 are open on the stand.
    /// 전체 악보 open: the service, and the song it opens at — the one
    /// whose title was tapped. One value, so the start cannot lag the open.
    @State private var standOpen: StandOpen?
    /// The service whose 지난 예배 record is being previewed.
    @State private var recording: TeamService?
    /// Assignments already seen on this device, so each is said once.
    @AppStorage("team.seenAssignments") private var seenAssignmentsRaw = ""
    /// A song being made the 헌금송, or its prayer changed.
    @State private var offeringEdit: OfferingEdit?
    struct OfferingEdit: Identifiable {
        let service: TeamService
        let item: PlanItem
        let id = UUID()
    }
    struct StandOpen: Identifiable {
        let service: TeamService
        var startSong: String? = nil
        let id = UUID()
    }
    /// One song's chart on the stand — its 악보 button.
    @State private var standSong: SongStand?

    struct SongStand: Identifiable {
        let service: TeamService
        let song: String
        var id: String { service.id + "|" + song }
    }
    @State private var preparingStand = false
    /// The stand was opened to make the next 콘티 version.
    @State private var makingConti = false
    @State private var assigningConti: (file: Attachment, service: TeamService)?
    @State private var confirmTidy = false
    @State private var tidying = false
    @State private var tidyNote: String?
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
                if DebugHarness.openStand,
                   let first = team.services.first(where: { Calendar.current.isDateInToday($0.date) }) ?? team.services.first {
                    // Give the folder a moment to be read, then open as a tap would.
                    try? await Task.sleep(for: .seconds(3))
                    await placeContiPages(first)
                    standOpen = StandOpen(service: first)
                }
                if DebugHarness.seedTeam { return }
                #endif
                team.configure(auth: auth, planning: planning)
                guard auth.canUseSheets else { return }
                if team.services.isEmpty, let sheetId {
                    await team.load(sheetId: sheetId)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $exportingTo) { service in
                ExportToPlaylistSheet(service: service)
                    .environmentObject(team)
            }
            .sheet(item: $offeringEdit) { edit in
                OfferingSheet(song: edit.item.title, prayer: edit.item.offering.prayer,
                              isOffering: edit.item.offering.isOffering,
                              onSave: { prayer in
                                  await setOffering(edit, isOffering: true, prayer: prayer)
                              },
                              onRemove: { await setOffering(edit, isOffering: false, prayer: nil) },
                              onCancel: { offeringEdit = nil })
            }
            .sheet(item: $reviewing) { review in
                SongTitleReviewSheet(playlistTitle: review.playlistTitle, songs: review.songs, loading: review.loading,
                                     remembered: { song in
                                         song.videoId.flatMap { SongTitleChoices.title(for: $0) ?? review.sheetTitles[$0] }
                                     },
                                     existing: review.existing,
                                     onSend: { songs in
                                         reviewing = nil
                                         Task { await write(songs, to: review.service) }
                                     },
                                     onCancel: { reviewing = nil })
            }
            .sheet(item: $fillingFrom, onDismiss: {
                guard let next = pendingFill else { return }
                pendingFill = nil
                Task { await push(next.playlistId, title: next.title, to: next.service) }
            }) { service in
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
                    // Read once the picker has gone (its onDismiss).
                    pendingFill = (playlistId, title, service)
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
            .sheet(isPresented: $showHealth) {
                SheetHealthView(sheetId: sheetId)
                    .environmentObject(team)
                    .environmentObject(auth)
                    .environmentObject(planning)
            }
            .sheet(isPresented: Binding(get: { assigningConti != nil }, set: { if !$0 { assigningConti = nil } })) {
                if let entry = assigningConti {
                    ContiPagesSheet(attachment: entry.file,
                                    songs: team.plan(for: entry.service).filter { $0.kind == .song }.map(\.title))
                        .environmentObject(team)
                }
            }
            .sheet(item: $recording) { service in
                ServiceRecordSheet(service: service, sheetId: sheetId)
                    .environmentObject(team)
            }
            .fullScreenCover(item: $standOpen) { open in
                let service = open.service
                let items = standItems(service)
                ScoreStandView(items: items,
                               startAt: open.startSong.flatMap { song in items.firstIndex { $0.song == song } } ?? 0,
                               setTitle: service.date.formatted(.dateTime.month().day()) + " " + service.title,
                               versions: songVersions(service),
                               setFileName: nextContiName(service),
                               exportOnOpen: makingConti,
                               setCaptions: contiCaptions(service),
                               notices: offeringNotices(service),
                               contiScope: ContiChoice.scope(service),
                               removeVersion: removeVersion,
                               shareChoice: sheetId == nil || team.isReadOnly ? nil : { item in
                                   await team.chooseForConti(item, service: service, sheetId: sheetId!)
                               },
                               uploadSet: sheetId == nil || !team.canAttach ? nil : { data, name, pages in
                                   await team.uploadConti(data, name: name, pages: pages, service: service, sheetId: sheetId!,
                                                          by: team.actingEmail(auth: auth, planning: planning) ?? "")
                               })
            }
            .fullScreenCover(item: $standSong) { entry in
                let versions = songVersions(entry.service)
                let scope = ContiChoice.scope(entry.service)
                ScoreStandView(items: (versions[entry.song].flatMap { ContiChoice.pick($0, scope: scope, song: entry.song) })
                                    .map { [$0] } ?? [],
                               setTitle: PlanSongTitle.split(entry.song).title,
                               versions: versions.filter { $0.key == entry.song },
                               notices: offeringNotices(entry.service),
                               contiScope: scope,
                               removeVersion: removeVersion,
                               shareChoice: sheetId == nil || team.isReadOnly ? nil : { item in
                                   await team.chooseForConti(item, service: entry.service, sheetId: sheetId!)
                               })
            }
            .sheet(item: $responding) { ResponseSheet(service: $0) }
            .sheet(item: $reordering) { service in
                ReorderPlanSheet(service: service, sheetId: sheetId)
                    .environmentObject(team)
            }
            .navigationDestination(item: $openChart) { LeadSheetView(song: $0) }
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

                    Button("교회 계정 연결 — 팀 시트·악보") {
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
                Button("YouTube 계정 다시 로그인") {
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
                        Text("시트에 쓰는 계정: \(email) (\(planning.isSignedIn ? "교회 계정" : "YouTube 계정"))")
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
                    .accessibilityLabel("찬양팀 Sheet 열기")
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
                    // Which of the two accounts the sheet is written as —
                    // the one every answer and assignment here goes in under.
                    if let email = team.actingEmail(auth: auth, planning: planning) {
                        Text(planning.isSignedIn ? "교회 계정: " : "YouTube 계정: ").foregroundStyle(.secondary)
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
                        Button("교회 계정 연결 — 팀 시트·악보") {
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

                // 워크플로 점검, at the end of this line rather than a line
                // of its own: pinned, because the warnings sit at the top of
                // the list and the list opens scrolled past them.
                if let counts = sheetHealthCounts {
                    Button { showHealth = true } label: {
                        Label(counts, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(counts.contains("문제") ? .red : .orange)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("워크플로 점검: \(counts)")
                }
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

    /// The same song more than once on a service.
    @ViewBuilder
    private var duplicateSongsWarning: some View {
        if !team.duplicateSongs.isEmpty, let sheetId {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("같은 곡이 두 번 이상 들어간 줄이 \(team.duplicateSongs.rows.count)개 있습니다",
                          systemImage: "square.on.square")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Songs 탭 \(team.duplicateSongs.rows.map(String.init).joined(separator: ", "))번 줄은 같은 날 같은 영상이 이미 위에 있습니다. 정리하면 처음 것만 남기고 이 줄들을 비운 뒤, 그 예배의 순서를 1번부터 다시 매깁니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            repairing = true
                            if let failure = await team.repairDuplicateSongs(sheetId: sheetId) {
                                pushNote = failure
                            } else {
                                Toast.shared.show("중복된 곡을 정리했습니다")
                            }
                            repairing = false
                        }
                    } label: {
                        if repairing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("중복 정리", systemImage: "wand.and.stars")
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

    /// What 워크플로 점검 says needs attention, as SheetHealthView shows it.
    private var attention: [SheetAudit.Finding] {
        SheetAudit.needsAttention(
            team.audit(accounts: SheetHealthView.accounts(auth: auth, planning: planning)))
    }

    /// "점검 · 문제 1 · 확인 2", or nil when clean — short enough to sit at
    /// the end of the account line.
    private var sheetHealthCounts: String? {
        let found = attention
        guard !found.isEmpty else { return nil }
        let problems = found.filter { $0.severity == .problem }.count
        let warnings = found.count - problems
        var parts: [String] = []
        if problems > 0 { parts.append("문제 \(problems)") }
        if warnings > 0 { parts.append("확인 \(warnings)") }
        return "점검 · " + parts.joined(separator: " · ")
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
                    HStack {
                        Button { openURL(url) } label: {
                            Label("찬양팀 Sheet", systemImage: "tablecells")
                        }
                        Spacer()
                        // Only when it would change something: a header
                        // left unfrozen, a colour rule missing. Asked, not
                        // done — it changes how a shared document looks for
                        // everyone, so the person pressing it should know.
                        if team.sheetNeedsTidy || tidying, !team.isReadOnly {
                            Button { confirmTidy = true } label: {
                                // Not a Label: in a list row it takes the
                                // row's icon column and spreads apart.
                                HStack(spacing: 4) {
                                    Image(systemName: "paintbrush")
                                    Text(tidying ? "정리하는 중" : "보기 좋게 정리")
                                }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.accentColor))
                            }
                            .disabled(tidying)
                        }
                    }
                    .buttonStyle(.borderless)
                    .task(id: sheetId) {
                        if let sheetId { await team.checkTidy(sheetId: sheetId) }
                    }
                }
                // Every chart the team has put up, in Drive: the shared 콘티
                // folder, which everyone sees. The folder this account's own
                // uploads go to holds only its own, so it is the fallback.
                if let url = ContiFolder.folderURL ?? DriveClient.folderURL {
                    Button { openURL(url) } label: {
                        Label("악보 Archive", systemImage: "archivebox")
                    }
                }
                // The charts for one song, when the team keeps them together
                // in the shared drive (설정 › 곡별 악보 폴더).
                if let url = MusicSheetFolder.url {
                    Button { openURL(url) } label: {
                        Label(MusicSheetFolder.name ?? "곡별 악보 폴더", systemImage: "folder")
                    }
                }
                if let url = ChurchSheetSource.url {
                    Button { openURL(url) } label: {
                        Label([AppSecrets.churchName, "예배 정보 Sheet"].compactMap { $0 }.joined(separator: " "),
                              systemImage: "building.columns")
                    }
                    if let problem = team.churchSheetProblem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                // Always reachable, so "is everything set up right?" has an
                // answer even when the answer is yes.
                Button { showHealth = true } label: {
                    HStack {
                        Label("워크플로 점검", systemImage: "stethoscope")
                        Spacer()
                        let count = attention.count
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(.orange))
                        }
                    }
                }
            } footer: {
                Text("시트에서 바꾼 내용은 이 화면을 아래로 당겨 새로 고치면 반영됩니다.")
            }
            .confirmationDialog("팀 시트를 정리할까요?", isPresented: $confirmTidy,
                                titleVisibility: .visible) {
                Button("정리하기") {
                    guard let sheetId else { return }
                    Task {
                        tidying = true
                        tidyNote = await team.tidySheet(sheetId: sheetId)
                        tidying = false
                    }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("모양만 바꿉니다. 탭마다 머리글 고정·굵게, 이번 주 줄 강조, 지난 날짜 흐리게, 응답(가능·미정·어려움·자리비움)에 색을 입힙니다. 내용은 하나도 바뀌거나 지워지지 않고, 여러 번 눌러도 규칙이 겹쳐 쌓이지 않습니다.")
            }
            .alert("시트 정리", isPresented: .constant(tidyNote != nil)) {
                Button("확인") { tidyNote = nil }
            } message: {
                Text(tidyNote ?? "")
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
                duplicateSongsWarning
                assignmentBanner

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
                if let passage = note.passage {
                    churchNoteLine("본문", passage)
                }
                if let preacher = note.preacher {
                    churchNoteLine("설교자", preacher)
                }
                if let song = note.dedicationSong {
                    churchNoteLine("헌신찬양", song)
                }
                Text("\([AppSecrets.churchName, "예배 정보 Sheet"].compactMap { $0 }.joined(separator: " "))에서 가져옴")
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

            }

            let songs = items.filter { $0.kind == .song && $0.videoId != nil }
            // Under the songs' own ▶, in the same column: the whole set in
            // order. It used to be a full-width row further down, between
            // buttons that edit the 순서 — the one thing here that only
            // listens.
            if songs.count > 1 {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button {
                        host.play(
                            queue: songs.compactMap { item in
                                item.videoId.map { PlayableVideo(id: $0, title: item.title) }
                            },
                            startIndex: 0,
                            purpose: .worship,
                            curated: true
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Text("찬양 이어 듣기").font(.footnote.weight(.semibold))
                            // Centred in the same width as each song's ▶,
                            // so it stands in that column, a size larger.
                            Image(systemName: "play.circle").font(.title2)
                                .frame(width: Self.playColumn)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("찬양만 이어 듣기")
                }
            }

            servicePDFRow(service)

            // Then one button for adding, moving and removing lines — a
            // line added at the end is usually moved next.
            if !team.isReadOnly {
                Button {
                    reordering = service
                } label: {
                    Label("순서 추가 및 조정", systemImage: "list.bullet.indent")
                }
                .buttonStyle(.borderless)
            }
            // For the team's chat: who is on what, what is still open, who
            // has not answered, and the sheet for anyone without the app.
            Button {
                SharePresenter.present(items: [rosterText(service)])
            } label: {
                Label("배정표 보내기", systemImage: "paperplane")
            }
            .buttonStyle(.borderless)

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

            // The other way: the 콘티 written out to a playlist, so the set
            // can be listened through in YouTube.
            if items.contains(where: { $0.kind == .song && $0.videoId != nil }) {
                Button {
                    exportingTo = service
                } label: {
                    Label("재생목록으로 내보내기", systemImage: "square.and.arrow.up")
                }
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

    /// This song's chart, one tap away and the only 악보 mark on the row:
    /// the charts put up for it, on the stand — or, when nobody has put one
    /// up, the 코드표 the app made by listening. 📎 beside it is where
    /// charts are added, found and taken off; 전체 악보 under the 순서 opens
    /// the whole set.
    ///
    /// It used to be five marks — this button, 「악보 G」 under the title,
    /// a green 「악보」 for the app's 코드표, 🔍 and a counted 📎 — which
    /// read as five different things about one chart.
    @ViewBuilder
    private func chartButton(_ item: PlanItem, in service: TeamService) -> some View {
        let uploaded = songVersions(service)[item.title]?.isEmpty == false
        let made = uploaded ? nil : existingSheet(forTitle: item.title)
        if uploaded || made != nil {
            // The key the chart was last shown in, only when it is not the
            // 순서's: a chart left in the wrong key is caught before Sunday.
            let off = uploaded ? offKey(item, in: service) : nil
            let tint = off == nil ? Color.accentColor : .orange
            Button {
                if uploaded { standSong = SongStand(service: service, song: item.title) } else { openChart = made }
            } label: {
                // Not a Label: in a list row it takes the row's icon column.
                // The word on iPad; a phone gives the title the width.
                ChartBadge(text: [isWide ? "악보" : nil, off].compactMap { $0 }.joined(separator: " "),
                           systemImage: "music.note.list", tint: tint)
                .frame(minHeight: Self.rowButtonHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tint)
            .accessibilityLabel("\(PlanSongTitle.split(item.title).title) 악보 보기"
                                + (off.map { ", 악보는 \($0) 키" } ?? ""))
        } else {
            // No chart yet — often, for a song just added to the 콘티: the
            // search where the chart would be, the one found attached to
            // this song of this service (ScoreFinder).
            SheetMusicMenu(title: item.title, channel: channelTitle(forVideo: item.videoId),
                           published: sheetLinks(forVideo: item.videoId), videoId: item.videoId,
                           destination: ScoreDestination(service: service, song: item.title, key: item.key)) {
                ChartBadge(text: isWide ? "악보 검색" : "", systemImage: "doc.text.magnifyingglass", tint: .secondary)
                    .frame(minHeight: Self.rowButtonHeight)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(PlanSongTitle.split(item.title).title) 악보 검색")
        }
    }

    /// The key the song's chart was last shown in, when it differs from the
    /// key the 순서 gives it.
    private func offKey(_ item: PlanItem, in service: TeamService) -> String? {
        guard let planned = item.key, let chartKey = chartKey(for: item, in: service) else { return nil }
        let chartRoot = ScoreRecognition.keyRoot(chartKey.replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: "♯", with: "#"))
        return ScoreRecognition.keyRoot(planned) == chartRoot ? nil : chartKey
    }

    /// Who leads the song, then which recording: one quiet line.
    private func songDetails(person: String?, details: [String]) -> Text? {
        let rest = details.joined(separator: " · ")
        switch (person, rest.isEmpty) {
        case (nil, true): return nil
        case (let person?, true): return Text(person).foregroundStyle(.secondary)
        case (nil, false): return Text(rest).foregroundStyle(.tertiary)
        case (let person?, false):
            return Text("\(Text(person).foregroundStyle(.secondary))  \(Text(rest).foregroundStyle(.tertiary))")
        }
    }

    /// A song plays as the 콘티: every song of the service in order,
    /// starting here — next and previous go through the set, as in a
    /// playlist. Anything else plays alone.
    private func play(_ item: PlanItem, in service: TeamService, videoId id: String) {
        if item.kind == .song {
            let songs = team.plan(for: service).filter { $0.kind == .song && $0.videoId != nil }
            let queue = songs.compactMap { song in
                song.videoId.map { PlayableVideo(id: $0, title: song.title) }
            }
            let start = songs.firstIndex { $0.id == item.id } ?? 0
            host.play(queue: queue, startIndex: start, purpose: .worship, curated: true)
        } else {
            host.play(queue: [PlayableVideo(id: id, title: item.title)], startIndex: 0)
        }
    }

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
                // A song as the song: its title and key first, then who
                // leads it and which recording — the hymn number, the team,
                // the year — one quiet line under it (PlanSongTitle).
                if item.kind == .song {
                    let parts = PlanSongTitle.split(item.title, channel: channelTitle(forVideo: item.videoId))
                    // The key it is played in, right after the title: what
                    // a player looks for first. One text, so on a phone the
                    // key wraps with the title rather than squeezing it.
                    let key = item.key.map {
                        Text("  \($0)").font(.subheadline.weight(.bold)).foregroundStyle(Color.accentColor)
                    } ?? Text("")
                    Text("\(Text(parts.title).font(.subheadline.weight(.medium)))\(key)")
                        .fixedSize(horizontal: false, vertical: true)
                    if let details = songDetails(person: item.person,
                                                 details: (parts.hymn.map { ["찬송가 \($0)장"] } ?? []) + parts.meta) {
                        details.font(.caption2).lineLimit(1)
                    }
                } else {
                    Text(item.title).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.kind != .song {
                    HStack(spacing: 6) {
                        Text(item.kind.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let key = item.key {
                            Text(key).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                        }
                        if let person = item.person {
                            Text(person).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                // The offering song says so, and who prays; its notes show
                // without the mark they carry.
                let offering = item.offering
                if item.kind == .song, offering.isOffering {
                    // Not a Label: in a list row it takes the row's icon
                    // column and spreads apart. A tap changes who prays.
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "gift")
                        Text("헌금송" + (offering.prayer.map { " · 헌금기도 \($0)" } ?? " · 헌금기도자 정하기"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !team.isReadOnly else { return }
                        offeringEdit = OfferingEdit(service: service, item: item)
                    }
                }
                if let notes = item.kind == .song ? offering.rest : item.notes {
                    Text(notes).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                // The team's memo for the song, from any Sunday it was sung.
                if item.kind == .song, let memo = team.memo(for: item.title) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "note.text")
                        Text(memo.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }
            // A song's title opens 전체 악보 at its chart, the rest of the
            // set a swipe away — what a player reaches for on the day. A song
            // with no chart yet plays instead, as ▶ does.
            .contentShape(Rectangle())
            .onTapGesture {
                guard item.kind == .song else { return }
                if songVersions(service)[item.title]?.isEmpty == false {
                    makingConti = false
                    standOpen = StandOpen(service: service, startSong: item.title)
                } else if let id = item.videoId {
                    play(item, in: service, videoId: id)
                }
            }

            Spacer(minLength: 0)

            if item.kind == .song { chartButton(item, in: service) }

            // Songs only. 악보 belong to a song; a 대표기도 or a 광고 line
            // has nothing to attach, and a clip on every row turned the
            // 순서 into a column of identical icons.
            //
            // Plain whatever is attached: the 악보 button beside it says
            // whether there is a chart. This is where one is added, found
            // on the web, or taken off.
            if item.kind == .song {
                let madeChart = existingSheet(forTitle: item.title)
                AttachmentMenu(service: service, song: item.title, sheetId: sheetId,
                               channel: channelTitle(forVideo: item.videoId),
                               published: sheetLinks(forVideo: item.videoId),
                               finds: ScoreDestination(service: service, song: item.title, key: item.key),
                               appChart: madeChart.map { chart in { openChart = chart } }) {
                    Image(systemName: "paperclip")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30, minHeight: Self.rowButtonHeight)
                        .contentShape(Rectangle())
                }
                .environmentObject(team)
                .environmentObject(auth)
                .environmentObject(planning)
            }

            if let id = item.videoId {
                Button {
                    play(item, in: service, videoId: id)
                } label: {
                    Image(systemName: "play.circle.fill").font(.title3)
                        .frame(width: Self.playColumn, height: Self.rowButtonHeight)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 3)
    }


    /// The channel a 순서 song's video came from, when the app has seen it —
    /// it names the team, which decides the 악보 menu's official store.
    private func channelTitle(forVideo id: String?) -> String? {
        guard let id else { return nil }
        let descriptor = FetchDescriptor<CachedVideo>(predicate: #Predicate { $0.videoId == id })
        return (try? modelContext.fetch(descriptor))?.first?.channelTitle
    }

    /// Chart links the upload's own description gives — the team's official
    /// 악보 — when the video is cached; the player shows the same ones.
    private func sheetLinks(forVideo id: String?) -> [SheetMusicLink] {
        guard let id else { return [] }
        let descriptor = FetchDescriptor<CachedVideo>(predicate: #Predicate { $0.videoId == id })
        guard let description = (try? modelContext.fetch(descriptor))?.first?.descriptionText else { return [] }
        return WorshipSetParser.sheetMusicLinks(description)
    }

    /// The key this song's attached chart was last shown in on the stand.
    private func chartKey(for item: PlanItem, in service: TeamService) -> String? {
        team.attachments(for: service, song: item.title)
            .lazy.compactMap { ScoreKeyStore.key(for: $0.fileId) }.first
    }

    /// One document for the Sunday: the 순서, then every 악보 behind it.
    ///
    /// On a music stand you want one thing to swipe through, not eleven
    /// links. Rebuilt rather than cached, because the attachments change
    /// right up to Saturday night and a stale PDF is worse than none — the
    /// whole point is that whoever opens it has the current one.
    @ViewBuilder
    private func servicePDFRow(_ service: TeamService) -> some View {
        let built = team.attachments(for: service).first { $0.belongsToService && ContiPages.isBuilt($0) }
        let pieces = team.attachments(for: service).filter { !$0.belongsToService }
        let contis = team.contis(for: service)
        let stand = standItems(service)

        // Two choices, on the right under 찬양 이어 듣기 and drawn like
        // each song's 악보: the service's 콘티 — every version, the folder,
        // the ways to add or make one — and the whole set on the stand.
        if team.plan(for: service).contains(where: { $0.kind == .song }) {
            VStack(alignment: .trailing, spacing: 6) {
                // After the service, the songs outlive the 콘티 — next
                // week's overwrites this one: kept in the archive playlist
                // and on each song's 지난 예배, offered once the service is
                // over, where "what we sang" is a fact rather than a plan.
                // Rechecked each minute: the badges come when the service
                // ends, not on the next redraw after it. On one line when
                // the four fit (iPad); else 기록 · 보관 above, rather than
                // four badges squeezed until their words wrap (iPhone).
                TimelineView(.everyMinute) { _ in
                    let after = hasHappened(service)
                    let set = HStack(spacing: 10) {
                        contiMenu(service, contis: contis, built: built, pieces: pieces)
                        standButton(service, stand: stand)
                    }
                    let kept = HStack(spacing: 10) {
                        recordBadge(service)
                        archiveBadge(service)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Spacer(minLength: 0)
                            if after { kept }
                            set
                        }
                        VStack(alignment: .trailing, spacing: 8) {
                            if after { kept }
                            set
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                if let note = archiveStore.note, hasHappened(service) {
                    Text(note).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                Group {
                    if preparingStand {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("콘티 파일을 곡별로 나누는 중…")
                        }
                    } else {
                        // Charts borrowed from an earlier service count: they
                        // are what 전체 악보 and the 콘티 will use.
                        let borrowed = stand.filter { $0.earlierDay != nil }.count
                        Text(contis.isEmpty && pieces.isEmpty && borrowed == 0
                             ? "콘티 폴더에 날짜로 시작하는 콘티 PDF를 두거나, 곡마다 📎로 악보를 올리세요."
                             : [contis.first.map { "콘티 \(($0.name as NSString).deletingPathExtension)" },
                                pieces.isEmpty ? nil : "곡별 악보 \(pieces.count)개",
                                borrowed == 0 ? nil : "지난 예배 악보 \(borrowed)곡"]
                                .compactMap { $0 }.joined(separator: " · ") + " — 전체 악보는 순서의 키로 봅니다.")
                            .multilineTextAlignment(.trailing)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// 기록 — each song's key and notes onto its 지난 예배 on the 곡 메모
    /// tab — offered once the service is over, after a preview.
    @ViewBuilder
    private func recordBadge(_ service: TeamService) -> some View {
        if !team.sung(in: service).isEmpty, sheetId != nil {
            let recorded = team.isRecorded(service)
            Button { recording = service } label: {
                ChartBadge(text: recorded ? "기록됨" : "기록",
                           systemImage: recorded ? "checkmark.circle.fill" : "square.and.pencil",
                           tint: recorded ? .green : .accentColor, large: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(recorded ? Color.green : Color.accentColor)
            .accessibilityLabel(recorded ? "곡 메모에 기록됨" : "곡 메모에 예배 기록")
        }
    }

    /// 보관 — into CCC_예배찬양곡_모음 — drawn as the badges beside it. Once
    /// filed it stops being a button: again could only add duplicates.
    @ViewBuilder
    private func archiveBadge(_ service: TeamService) -> some View {
        let songs = team.plan(for: service).filter { $0.kind == .song && $0.videoId != nil }
        if !songs.isEmpty {
            let archived = archiveStore.hasArchived(service)
            Button {
                Task { await archive(service, songs: songs) }
            } label: {
                HStack(spacing: 4) {
                    if archiveStore.isWorking { ProgressView().controlSize(.small) }
                    ChartBadge(text: archived ? "보관됨" : "보관",
                               systemImage: archived ? "checkmark.circle.fill" : "tray.and.arrow.down",
                               tint: archived ? .green : .accentColor, large: true)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(archived ? Color.green : Color.accentColor)
            .disabled(archived || archiveStore.isWorking || !auth.isSignedIn)
            .accessibilityLabel(archived ? "CCC_예배찬양곡_모음에 보관됨" : "CCC_예배찬양곡_모음에 보관")
        }
    }

    private func standButton(_ service: TeamService, stand: [ScoreStandItem]) -> some View {
        Button {
            Task {
                preparingStand = true
                await placeContiPages(service)
                preparingStand = false
                makingConti = false
                standOpen = StandOpen(service: service)
            }
        } label: {
            ChartBadge(text: "전체 악보", systemImage: "music.note.list", large: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(stand.isEmpty ? Color.secondary : Color.accentColor)
        .disabled(stand.isEmpty || preparingStand)
    }

    /// The service's 콘티: every version, newest first, each opening its
    /// file; the folder they live in; the page assignment of the newest;
    /// and the other ways to have one — upload a file, or make it here.
    private func contiMenu(_ service: TeamService, contis: [Attachment], built: Attachment?,
                           pieces: [Attachment]) -> some View {
        Menu {
            if !contis.isEmpty {
                Section("콘티 — 최신부터") {
                    ForEach(Array(contis.enumerated()), id: \.element.id) { index, conti in
                        Button { openURL(conti.url) } label: {
                            Label((conti.name as NSString).deletingPathExtension + (index == 0 ? " · 최신" : ""),
                                  systemImage: index == 0 ? "doc.richtext.fill" : "doc.richtext")
                        }
                    }
                }
                if let latest = contis.first {
                    Button { assigningConti = (latest, service) } label: {
                        Label("곡별 페이지 지정 — 최신 콘티", systemImage: "rectangle.split.3x1")
                    }
                }
            }
            // The other way round: the songs' charts — each in its chosen
            // version and key — put together as the next 콘티 version, to be
            // saved into the 콘티 folder from the share sheet.
            Button {
                Task {
                    preparingStand = true
                    await placeContiPages(service)
                    preparingStand = false
                    makingConti = true
                    standOpen = StandOpen(service: service)
                }
            } label: {
                Label("새 콘티 만들기 — \(nextContiName(service))", systemImage: "doc.badge.plus")
            }
            .disabled(standItems(service).isEmpty)
            if let folder = ContiFolder.folderURL {
                Button { openURL(folder) } label: { Label("콘티 폴더 열기", systemImage: "folder") }
            }
            Section {
                AttachmentMenu(service: service, song: "", sheetId: sheetId) {
                    Label("콘티 파일 올리기", systemImage: "square.and.arrow.up")
                }
                if let built {
                    Button { openURL(built.url) } label: { Label("순서표 + 악보 PDF 열기", systemImage: "doc") }
                }
                Button {
                    Task { await buildServicePDF(service) }
                } label: {
                    Label(built == nil ? "순서표 + 원래 키 악보 PDF 만들기" : "순서표 + 원래 키 악보 PDF 다시 만들기",
                          systemImage: "doc.badge.plus")
                }
                .disabled(pieces.isEmpty || buildingPDF)
            }
        } label: {
            // Making one is what the button is for; the versions already
            // made head its menu.
            HStack(spacing: 4) {
                if buildingPDF { ProgressView().controlSize(.small) }
                ChartBadge(text: "콘티 생성", systemImage: "doc.badge.plus", large: true)
            }
        }
        .menuOrder(.fixed)
        .foregroundStyle(Color.accentColor)
    }

    /// The service's song charts in 순서 order, each with the key the 순서
    /// gives that song.
    /// Every version of each song's chart, newest first: its pages in each
    /// of the latest 콘티 versions and each chart attached to it.
    ///
    /// The team works both ways. A 콘티 may come first and everything is
    /// read from it; or each song's charts are shared first — compared,
    /// transposed — and the 콘티 is put together from them, its versions
    /// rising as the team agrees how to sing it. So no source wins by kind:
    /// the newest does, whether a 콘티 or a song's chart attached after it.
    private func songVersions(_ service: TeamService) -> [String: [ScoreStandItem]] {
        let plan = team.plan(for: service)
        let attachments = team.attachments(for: service)
        let contis = Array(team.contis(for: service).prefix(3))
        let day = DateFormatter()
        day.dateFormat = "M/d"
        var out: [String: [ScoreStandItem]] = [:]
        for song in plan where song.kind == .song {
            var sources: [(item: ScoreStandItem, at: Date?, rank: Int)] = []
            for (rank, conti) in contis.enumerated() {
                let pages = ContiPages.pages(of: conti.fileId, for: song.title)
                guard !pages.isEmpty else { continue }
                let stem = (conti.name as NSString).deletingPathExtension
                let pageText = pages.count == 1 ? "\(pages[0] + 1)쪽" : "\(pages[0] + 1)–\(pages[pages.count - 1] + 1)쪽"
                sources.append((ScoreStandItem(attachment: conti, song: song.title, teamKey: song.key, pages: pages,
                                               versionLabel: "콘티 \(stem) · \(pageText)"),
                                conti.addedAt, rank))
            }
            for (offset, chart) in attachments.enumerated() where !chart.belongsToService && PlanSongTitle.sameSong(chart.song, song.title) {
                let when = chart.addedAt.map { " · \(day.string(from: $0)) 올림" } ?? ""
                sources.append((ScoreStandItem(attachment: chart, song: song.title, teamKey: song.key,
                                               versionLabel: "악보 \(chart.name)\(when)"),
                                chart.addedAt, 100 - offset))
            }
            // Newest first; without a time, the 콘티's own version order,
            // then the sheet's (later rows were added later).
            sources.sort { a, b in
                switch (a.at, b.at) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.rank < b.rank
                }
            }
            // Nothing for it on this service: the charts it was last played
            // from, on an earlier one — a song coming round again should not
            // look as if the team had never had a chart for it.
            if sources.isEmpty {
                for chart in team.earlierCharts(videoId: song.videoId, title: song.title, before: service.date) {
                    sources.append((ScoreStandItem(attachment: chart, song: song.title, teamKey: song.key,
                                                   versionLabel: "악보 \(chart.name)", earlierDay: chart.date),
                                    chart.addedAt, 0))
                }
            }
            if !sources.isEmpty { out[song.title] = sources.map(\.item) }
        }
        return out
    }

    // MARK: - Assignments

    /// Services coming where the leader has put this member on a part, not
    /// yet seen on this device. Schedule is where a leader assigns, and
    /// nothing told the member — they found out on Sunday, or by asking.
    private var newAssignments: [(service: TeamService, parts: [String], key: String)] {
        guard let me = team.rosterName(for: team.actingEmail(auth: auth, planning: planning) ?? "") else { return [] }
        let seen = Set(seenAssignmentsRaw.split(separator: "\n").map(String.init))
        return team.assignments(of: me).filter { !seen.contains($0.key) }
    }

    @ViewBuilder
    private var assignmentBanner: some View {
        let fresh = newAssignments
        if !fresh.isEmpty {
            Section {
                ForEach(fresh, id: \.key) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: "music.mic")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RosterMessage.day(entry.service.date) + " " + entry.service.title)
                                .font(.subheadline.weight(.semibold))
                            Text(RosterMessage.withRo(entry.parts.joined(separator: ", ")) + " 배정되었습니다")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("확인") {
                            seenAssignmentsRaw += (seenAssignmentsRaw.isEmpty ? "" : "\n") + entry.key
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { scrollTo?(Calendar.current.startOfDay(for: entry.service.date)) }
                }
            }
            .listRowBackground(Color.accentColor.opacity(0.12))
            // Seen here: no notification for it later.
            .onAppear {
                #if DEBUG
                if DebugHarness.notifyCheck { return }
                #endif
                TeamNotifications.markNotified(fresh.map(\.key))
            }
        }
    }

    /// 배정표 보내기's message for a service: the parts as the row's chips
    /// show them — who answered for a part and whom the leader put on one —
    /// an empty 인도 or keys first, and the service's own time.
    private func rosterText(_ service: TeamService) -> String {
        let staffed = holders(service, team.responses(for: service))
        var order: [String] = [], people: [String: [String]] = [:]
        for holder in staffed.holders {
            if people[holder.role] == nil { order.append(holder.role) }
            people[holder.role, default: []].append(holder.who)
        }
        let parts = staffed.missing.map { (part: $0, who: "") }
            + order.map { (part: $0, who: people[$0]!.joined(separator: ", ")) }
        return RosterMessage.text(day: service.date, title: service.title,
                                  time: service.time ?? Self.clockFormatter.string(from: serviceStart(service)),
                                  parts: parts, pending: team.pendingNames(for: service), link: teamSheetURL)
    }

    /// The 헌금송 mark written; the sheet closes on success.
    private func setOffering(_ edit: OfferingEdit, isOffering: Bool, prayer: String?) async -> String? {
        guard let sheetId else { return "시트가 연결되어 있지 않습니다." }
        let failure = await team.setOffering(edit.item, in: edit.service, isOffering: isOffering,
                                             prayer: prayer, sheetId: sheetId)
        if failure == nil { offeringEdit = nil }
        return failure
    }

    /// What each song's chart carries besides, by song as written: as the
    /// 헌금송, who prays and the call before the offering; and the team's
    /// 곡 메모. The first line heads the card.
    private func offeringNotices(_ service: TeamService) -> [String: String] {
        var out: [String: String] = [:]
        for item in team.plan(for: service) where item.kind == .song {
            var lines: [String] = []
            if item.offering.isOffering {
                lines += ["헌금 찬양" + (item.offering.prayer.map { " · 헌금기도: \($0)" } ?? ""), OfferingNote.call]
            }
            if let memo = team.memo(for: item.title) {
                lines += lines.isEmpty ? ["팀 메모", memo.text] : ["메모: " + memo.text]
            }
            if !lines.isEmpty { out[item.title] = lines.joined(separator: "\n") }
        }
        return out
    }

    /// A song's chart taken off it from the stand — its attachment row, and
    /// its file when this account put it up.
    private func removeVersion(_ version: ScoreStandItem) async -> String? {
        guard let sheetId else { return "시트가 연결되어 있지 않습니다." }
        return await team.removeAttachment(version.attachment, sheetId: sheetId)
    }

    /// Each song's corner line on a 콘티 made here, by song as written:
    /// 「2026/10/18 주일2부 - 1. 곡」 — numbered among the songs, as sung.
    private func contiCaptions(_ service: TeamService) -> [String: String] {
        let songs = team.plan(for: service).filter { $0.kind == .song }
        var out: [String: String] = [:]
        for (index, song) in songs.enumerated() where out[song.title] == nil {
            out[song.title] = ContiCaption.text(date: service.date, service: service.title,
                                                order: index + 1, song: PlanSongTitle.split(song.title).title)
        }
        return out
    }

    /// The stand's set: each song's newest version, then the rest.
    private func standItems(_ service: TeamService) -> [ScoreStandItem] {
        let plan = team.plan(for: service)
        let attachments = team.attachments(for: service)
        let versions = songVersions(service)
        // Each song in the version chosen for the 콘티, else its newest.
        let scope = ContiChoice.scope(service)
        var items = plan.filter { $0.kind == .song }.compactMap { song in
            versions[song.title].flatMap { ContiChoice.pick($0, scope: scope, song: song.title) }
        }
        // Charts on songs no longer in the 순서, after it. The same song by
        // the way the rest of the app matches it: a chart attached under
        // 「곡」 and the 순서's 「[찬송가] 곡 | 팀」 are one song, and an
        // exact match put every chart in the set twice.
        let songs = plan.filter { $0.kind == .song }.map(\.title)
        items += attachments.filter { chart in
            !chart.belongsToService && !songs.contains { PlanSongTitle.sameSong($0, chart.song) }
        }
            .map { ScoreStandItem(attachment: $0, song: $0.song, teamKey: nil) }
        // What of the newest 콘티 is no song of the 순서, or all of it when
        // its pages could not be placed.
        if let latest = team.contis(for: service).first {
            let name = (latest.name as NSString).deletingPathExtension
            if let placed = ContiPages.cached(latest.fileId), !placed.isEmpty {
                let count = ContiPages.pageCount(latest.fileId) ?? ((placed.keys.max() ?? 0) + 1)
                let rest = (0..<count).filter { placed[$0] == nil }
                if !rest.isEmpty {
                    items.append(ScoreStandItem(attachment: latest, song: "\(name) · 나머지", teamKey: nil, pages: rest))
                }
            } else if items.isEmpty {
                items.append(ScoreStandItem(attachment: latest, song: name, teamKey: nil))
            }
        }
        return items
    }

    /// The name of the 콘티 that would come next: the latest's name a
    /// version up — 「20261018 주일예배 찬양 v3」 — or, with none yet,
    /// 「YYYYMMDD <service> 찬양 v1」.
    private func nextContiName(_ service: TeamService) -> String {
        let contis = team.contis(for: service)
        let next = (contis.map { ContiFolder.version(in: $0.name) }.max() ?? 0) + 1
        if let latest = contis.first {
            let stem = (latest.name as NSString).deletingPathExtension
                .replacingOccurrences(of: #"(?i)[\s_\-(]*v(?:er)?\.?\s*\d{1,2}\)?\s*$"#, with: "", options: .regularExpression)
            return "\(stem) v\(next)"
        }
        let day = DateFormatter()
        day.dateFormat = "yyyyMMdd"
        return "\(day.string(from: service.date)) \(service.title) 찬양 v\(next)"
    }

    /// Works out, once per file, which page of the latest 콘티 versions is
    /// which song.
    private func placeContiPages(_ service: TeamService) async {
        let songs = team.plan(for: service).filter { $0.kind == .song }.map(\.title)
        for conti in team.contis(for: service).prefix(3) {
            await ContiPages.compute(for: conti, songs: songs)
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
        // and a list of five dated ones is a list nobody reads. Replaced
        // only once the new one is up — removing first lost the old PDF
        // whenever the upload then failed — and only the app's own, never a
        // 콘티 file a teammate uploaded.
        if let failure = await team.attach(
            data: pdf, name: "\(day)-콘티.pdf", mimeType: "application/pdf",
            song: "", to: service, sheetId: sheetId, by: who, replacingSameName: true
        ) {
            pushNote = failure
        }
    }

    private func removeItem(_ item: PlanItem, from service: TeamService) async {
        guard let sheetId else { return }
        pushNote = nil
        let failure = await team.removePlanItem(item, from: service, sheetId: sheetId)
        pushNote = failure
        Toast.shared.sheet(failure.map { "지우지 못했습니다 — \($0)" },
                           saved: "「\(PlanSongTitle.split(item.title).title)」 순서에서 뺌 — 시트에 저장됨")
    }

    // MARK: - Pushing the 콘티

    /// The review opens at once, saying it is reading; the playlist and the
    /// Songs tab are read together, not one after the other; the keys songs
    /// were last played in are looked up in one pass for all of them.
    ///
    /// WHY: choosing a playlist used to show nothing but a small spinner in
    /// the button for the length of two reads in a row, a search of every
    /// earlier service for every song, and a fixed wait for the picker to
    /// close — seconds, with nothing on screen to say anything was coming.
    private func push(_ playlistId: String, title: String, to service: TeamService) async {
        guard let sheetId else { return }
        pushNote = nil
        let review = PushReview(service: service, playlistTitle: title, songs: [], loading: true)
        reviewing = review

        let client = AppServices.client(auth: auth, quota: quota)
        async let itemsRead = try? client.playlistItems(playlistId: playlistId)
        async let rowsRead = try? team.rawSongRows(sheetId: sheetId)
        let items = await itemsRead
        let rows = await rowsRead
        // Closed meanwhile: nothing more to fill in.
        guard reviewing?.id == review.id else { return }
        guard let items else {
            reviewing = nil
            pushNote = "재생목록을 불러오지 못했습니다."
            return
        }

        let lastKey = team.lastKeys(before: service.date)
        let songs: [TeamSong] = items.enumerated().compactMap { index, item -> TeamSong? in
            guard !item.isUnavailable, let id = item.videoId else { return nil }
            let chart = existingSheet(forTitle: item.title)
            return TeamSong(
                order: index + 1,
                title: item.title,
                url: YouTubeID.watchURL(id),
                // The key the team last played it in; else a chart the app
                // made of it; else blank for the leader to fill.
                key: lastKey(id, item.title) ?? chart?.keyLabel,
                transpose: chart?.semitoneShift ?? 0,
                notes: nil,
                channel: item.channelTitle
            )
        }
        guard !songs.isEmpty else {
            reviewing = nil
            pushNote = "재생할 수 있는 곡이 없습니다."
            return
        }
        // What is already there, each with its row — to merge with, never
        // to overwrite unasked.
        var existing: [TeamSong] = []
        if let rows {
            let day = Calendar.current.startOfDay(for: service.date)
            existing = (TeamStore.parseSongs(rows)[day] ?? []).sorted { $0.order < $1.order }.map { song in
                var song = song
                if let row = song.row, rows.indices.contains(row - 1) { song.sheetRow = rows[row - 1] }
                return song
            }
        }
        #if DEBUG
        // The sample team has no sheet: its 순서's songs stand in.
        if existing.isEmpty, team.isSample {
            existing = team.plan(for: service).filter { $0.kind == .song }.enumerated().map { index, item in
                TeamSong(order: index + 1, title: item.title, url: item.url, key: item.key, transpose: 0, notes: item.notes)
            }
        }
        #endif
        guard reviewing?.id == review.id else { return }
        reviewing?.songs = songs
        reviewing?.existing = existing
        reviewing?.sheetTitles = team.sheetTitles()
        reviewing?.loading = false
    }

    /// The checked songs, onto the Songs tab for this service.
    private func write(_ songs: [TeamSong], to service: TeamService) async {
        #if DEBUG
        if team.isSample {
            team.samplePush(songs, to: service)
            pushNote = "\(songs.count)곡을 순서에 넣었습니다 (샘플 — 시트에는 쓰지 않음)."
            return
        }
        #endif
        guard let sheetId else { return }
        isPushing = true
        pushNote = nil
        defer { isPushing = false }
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
    /// Over: an hour and a half after it starts, which is about how long a
    /// service runs. Offered from the day itself, it appeared at midnight —
    /// eleven hours before anyone had sung anything.
    private func hasHappened(_ service: TeamService) -> Bool {
        Date() >= serviceStart(service).addingTimeInterval(90 * 60)
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
    /// The part is the schedule's when the leader has put me on one — the
    /// part my answer was filed under is only what I offered.
    private func answerLabel(_ mine: TeamSignup?, shown: SignupStatus?, service: TeamService) -> String {
        guard let shown else { return "미지정" }
        if shown == .available {
            if let me = team.rosterName(for: team.actingEmail(auth: auth, planning: planning) ?? ""),
               let parts = team.assignments(of: me).first(where: { $0.service.id == service.id })?.parts {
                return parts.joined(separator: " · ")
            }
            if let role = mine?.role, !role.isEmpty { return role }
        }
        return shown.label
    }

    /// Records one of the three answers.
    ///
    /// 가능 needs a part to be filed against: the one already chosen, else
    /// the usual one, else the first the sheet lists. The other two are true
    /// of every part at once, so they never ask.
    /// `tracked: false` from the ✓ ? ✕ control, which shows its own answer
    /// while it is written — setting `inFlight` would redraw the whole
    /// screen on each press (AnswerControl).
    private func record(_ status: SignupStatus, for upcoming: TeamService, tracked: Bool = true) async {
        let key = upcoming.id
        if rowError[key] != nil { rowError[key] = nil }
        if tracked { inFlight[key] = .some(status) }
        defer { if tracked { inFlight[key] = nil } }

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

        // Cleared first: setAvailability only ever sets it, so an error from
        // any earlier write was read back after every later answer that
        // went through, and shown under the row as this one's.
        team.errorMessage = nil
        await team.setAvailability(
            status, service: upcoming, role: part,
            email: email, name: auth.displayName ?? email, sheetId: sheetId
        )
        if let message = team.errorMessage { rowError[key] = message }
        Toast.shared.sheet(team.errorMessage.map { "응답을 저장하지 못했습니다 — \($0)" },
                           saved: "\(RosterMessage.day(upcoming.date)) \(status.label) — 시트에 저장됨")
    }

    /// Takes the answer back, under every address that is me.
    private func clearAnswer(for upcoming: TeamService, tracked: Bool = true) async {
        let key = upcoming.id
        if rowError[key] != nil { rowError[key] = nil }
        if tracked { inFlight[key] = .some(nil) }
        defer { if tracked { inFlight[key] = nil } }

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
        Toast.shared.sheet(ok ? nil : rowError[key],
                           saved: "\(RosterMessage.day(upcoming.date)) 응답 취소 — 시트에 저장됨")
    }

    /// The two parts a service cannot happen without, in the order they are
    /// always shown. Fixed rather than read from the sheet's Order column,
    /// so the row does not reshuffle as the sheet is edited.
    private static let keyRoleNames = ["인도", "반주"]

    /// Those two as the sheet names them — a chip says 「Keys 미지정」 on a
    /// sheet that calls the part Keys.
    private var coreNames: [String] {
        Self.keyRoleNames.map { core in
            team.roleColumns.sorted { $0.value < $1.value }.map(\.key).first { PartAliases.matches($0, core) }
                ?? team.roles.first { PartAliases.matches($0.name, core) }?.name
                ?? core
        }
    }

    /// The column the 순서's ▶ buttons stand in.
    private static let playColumn: CGFloat = 34
    /// The 순서 row's buttons share one height, so they line up.
    private static let rowButtonHeight: CGFloat = 32

    /// What a tapped chip was about: a part, a person, or both.
    struct AssignmentTarget: Identifiable {
        let service: TeamService
        let role: String?
        let person: String?
        var id: String { "\(service.id)-\(role ?? "")-\(person ?? "")" }
    }

    /// Somebody on a part, by their own answer or by the leader's plan.
    private struct Holder {
        let role: String
        let who: String
        /// Set only when they answered, which is what makes the chip green
        /// rather than the orange of a plan they have not agreed to.
        let signupId: String?
        /// Their answer: put on 인도 and said 어려움 is a gap the leader
        /// must see, on the chip that says 인도.
        let status: SignupStatus?
        /// The part, numbered when it has more than one person: VOCAL1.
        var label: String
    }

    /// Everyone on every part for a service, and which of 인도 and 반주 has
    /// nobody.
    ///
    /// WHY A LIST, NOT A NAME PER PART: any part can have several people —
    /// two on VOCAL, two on 건반 — and the row kept one per part, so the
    /// second answer or assignment simply was not shown. Each part's people
    /// come from their answers first — somebody saying "I will" is a
    /// stronger fact than a name typed into a plan — and then from the
    /// schedule's cell, which may hold several names. A part with more than
    /// one is numbered, 보컬1 and 보컬2, so the chips say who is which.
    ///
    /// Parts are matched through PartAliases, so a sheet that writes 인도자
    /// or Piano answers for 인도 and 반주.
    private func holders(_ service: TeamService, _ answers: [TeamSignup]) -> (holders: [Holder], missing: [String]) {
        var groups: [(role: String, people: [(who: String, answer: TeamSignup?)])] = []
        func group(_ role: String) -> Int {
            if let index = groups.firstIndex(where: { PartAliases.matches($0.role, role) }) { return index }
            groups.append((role, []))
            return groups.count - 1
        }
        func samePerson(_ a: String, _ b: String) -> Bool {
            let x = a.replacingOccurrences(of: " ", with: ""), y = b.replacingOccurrences(of: " ", with: "")
            return x == y || (min(x.count, y.count) >= 2 && (x.contains(y) || y.contains(x)))
        }
        func answer(of name: String) -> TeamSignup? {
            answers.first { samePerson(displayName($0), name) || samePerson($0.name, name) }
        }
        // 인도 and the keys first, by the sheet's own words for them (Keys,
        // 건반 …), then the schedule's columns in its own order.
        let core = coreNames
        for role in core { _ = group(role) }
        for role in team.roleColumns.sorted(by: { $0.value < $1.value }).map(\.key) { _ = group(role) }

        // ONE PERSON, ONE PLACE. The schedule's cell — the leader's
        // decision — places a person, and their answer only colours it.
        // An answer used to be placed by the part it was filed under as
        // well, so 「가능」 under Keys and then 인도 from the leader showed
        // the same person twice; on the 응답 tab, where an answer has no
        // part until the next reload, as a bare green name beside the
        // orange 인도. In column order, then by name: a dictionary's own
        // order changes from one launch to the next, and so did the chips'.
        let planned = service.assignments.sorted {
            (team.roleColumns[$0.key] ?? .max, $0.key) < (team.roleColumns[$1.key] ?? .max, $1.key)
        }
        var placed: [String] = []
        for (role, cell) in planned {
            let index = group(role)
            for name in TeamSheet.names(inCell: cell)
            where !groups[index].people.contains(where: { samePerson($0.who, name) }) {
                let said = answer(of: name)
                groups[index].people.append((said.map(displayName) ?? name, said))
                if let said { placed.append(said.id) }
            }
        }
        // Then whoever said yes for a part and is not on the schedule yet.
        for answer in answers where answer.status == .available && !answer.role.isEmpty
            && !placed.contains(answer.id) {
            groups[group(answer.role)].people.append((displayName(answer), answer))
        }
        var out: [Holder] = []
        for group in groups {
            for (number, person) in group.people.enumerated() {
                out.append(Holder(role: group.role, who: person.who, signupId: person.answer?.id,
                                  status: person.answer?.status,
                                  label: group.people.count > 1 ? "\(group.role)\(number + 1)" : group.role))
            }
        }
        let missing = core.filter { role in !out.contains { PartAliases.matches($0.role, role) } }
        return (out, missing)
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
                                if let note = team.churchNote(for: upcoming),
                                   let sermon = note.sermonTitle ?? note.passage {
                                    Text([sermon, note.sermonTitle == nil ? nil : note.passage]
                                        .compactMap { $0 }.joined(separator: " · "))
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
                if team.usesGrid {
                    // On the 응답 tab an answer is only that — the part is
                    // the leader's, on Schedule. Said, not offered.
                    Section(mine?.role.isEmpty == false ? "배정된 파트: \(mine!.role)" : "응답") {
                        ForEach([SignupStatus.available, .maybe, .declined, .away], id: \.self) { status in
                            Button {
                                Task { await answer(status, for: upcoming, role: nil) }
                            } label: {
                                if shown == status { Label(status.label, systemImage: "checkmark") } else { Text(status.label) }
                            }
                        }
                    }
                } else {
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
                    Text(answerLabel(mine, shown: shown, service: upcoming))
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
            AnswerControl(saved: mine?.status, isPast: upcoming.isPast, isReadOnly: team.isReadOnly,
                          tint: tint) { status in
                if let status { await record(status, for: upcoming, tracked: false) }
                else { await clearAnswer(for: upcoming, tracked: false) }
            }
            .id(upcoming.id)
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

    /// Picking a part is answering: one gesture, not a sheet and a switch.
    private func choose(_ role: String, for upcoming: TeamService) async {
        guard let sheetId, let email = team.actingEmail(auth: auth, planning: planning)
        else { return }
        usualRole = role
        // On the row at once; the sheet after (see record).
        inFlight[upcoming.id] = .some(.available)
        defer { inFlight[upcoming.id] = nil }
        team.errorMessage = nil
        await team.setAvailability(
            .available, service: upcoming, role: role,
            email: email, name: auth.displayName ?? email, sheetId: sheetId
        )
        Toast.shared.sheet(team.errorMessage.map { "응답을 저장하지 못했습니다 — \($0)" },
                           saved: "\(RosterMessage.day(upcoming.date)) \(role) 가능 — 시트에 저장됨")
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
        inFlight[upcoming.id] = .some(status)
        defer { inFlight[upcoming.id] = nil }
        team.errorMessage = nil
        await team.setAvailability(
            status, service: upcoming, role: part,
            email: email, name: auth.displayName ?? email, sheetId: sheetId
        )
        Toast.shared.sheet(team.errorMessage.map { "응답을 저장하지 못했습니다 — \($0)" },
                           saved: "\(RosterMessage.day(upcoming.date)) \(status.label) — 시트에 저장됨")
    }

    /// 인도 then 반주 then everyone else: the two parts that decide whether a
    /// service can happen lead the line, in that order, whether or not anyone
    /// has them. An empty 인도 is the most important thing on the row, and it
    /// cannot be the absence of a chip.
    private func chipsLine(_ upcoming: TeamService,
                           answers: [TeamSignup],
                           open: Bool) -> some View {
        let pending = team.pendingNames(for: upcoming)
        let staffed = holders(upcoming, answers)
        let spokenFor = Set(staffed.holders.compactMap(\.signupId))
        let rest = answers.filter { !spokenFor.contains($0.id) }

        // Wrapping on both sizes.
        //
        // iPad used to keep them on one scrolling line so every row stayed
        // the same height, which made the month scannable — but it also hid
        // half the team behind a scroll nobody tries, on the row whose job is
        // to say who is on. Seeing everyone beats rows of equal height.
        return ChipFlow { chips(upcoming, staffed, rest, pending, open: open) }
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
                       _ staffed: (holders: [Holder], missing: [String]),
                       _ rest: [TeamSignup],
                       _ pending: [String],
                       open: Bool) -> some View {
        ForEach(staffed.missing, id: \.self) { role in
            assignable(service, role: role, person: nil) {
                chip("\(role) 미지정", detail: nil, color: .red)
            }
        }
        ForEach(Array(staffed.holders.enumerated()), id: \.offset) { _, holder in
            // Green when they answered for it, orange and dashed when it is
            // only the leader's plan and they have not said yes yet.
            assignable(service, role: holder.role, person: nil) {
                chip(holder.who,
                     detail: holder.status.map { $0 == .available ? holder.label : "\(holder.label) · \($0.label)" }
                        ?? holder.label,
                     color: holder.status.map(tint) ?? .orange,
                     dashed: holder.signupId == nil)
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

/// The 순서's chart buttons — a song's 악보, 콘티 생성, 전체 악보 — drawn
/// alike, so they read as one kind of thing. Not a Label: in a list row a
/// Label takes the row's icon column and spreads apart.
private struct ChartBadge: View {
    let text: String
    let systemImage: String
    var tint: Color = .accentColor
    /// The service's own — 콘티 생성, 전체 악보 — stand larger than a
    /// song's: they act on the whole set, and are reached for first.
    var large = false

    var body: some View {
        HStack(spacing: large ? 5 : 3) {
            Image(systemName: systemImage)
            if !text.isEmpty { Text(text) }
        }
        .font(large ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, large ? 14 : (text.isEmpty ? 8 : 9)).padding(.vertical, large ? 9 : 5)
        .background(Capsule().fill(tint.opacity(0.15)))
    }
}

/// ✓ ? ✕ for one service: three segments in a track, one highlight that
/// slides to the answer. Pressing the chosen one takes the answer back.
///
/// WHY ITS OWN VIEW: the answer being written used to live in the screen's
/// own state, so every press redrew all of 예배 준비 — every week, every
/// 순서, every chart lookup — in the same frame the highlight started to
/// move, and again when the sheet answered. On a phone that was the stutter.
/// Here a press redraws three buttons.
///
/// WHY IT NEVER WAITS: the sheet takes a read and a write per answer, and
/// taps were refused until both came back, so a second tap in that second
/// did nothing. Now the highlight moves at once, and taps made while one
/// answer is being written are kept — the last one is what is written next.
private struct AnswerControl: View {
    /// What the sheet holds for me.
    let saved: SignupStatus?
    let isPast: Bool
    let isReadOnly: Bool
    let tint: (SignupStatus) -> Color
    /// Writes an answer; nil takes it back.
    let send: (SignupStatus?) async -> Void

    /// The answer pressed, until the sheet has it. `.some(nil)` is a
    /// taken-back answer.
    @State private var picked: SignupStatus??
    @State private var sending = false
    @State private var queued: SignupStatus??

    private static let order: [SignupStatus] = [.available, .maybe, .declined]
    private static let symbols = ["checkmark", "questionmark", "xmark"]
    private static let width: CGFloat = 34

    private var shown: SignupStatus? { picked ?? saved }
    // An unanswered week wears the accent until it is answered. A grey
    // track reads the same whether you have answered or not, and the screen
    // exists to collect answers. Only for weeks still ahead.
    private var needsAnswer: Bool { shown == nil && !isPast }

    var body: some View {
        let at = shown.flatMap { Self.order.firstIndex(of: $0) }
        HStack(spacing: 0) {
            ForEach(Array(Self.order.enumerated()), id: \.offset) { index, status in
                segment(status, symbol: Self.symbols[index])
            }
        }
        // One highlight behind the three, moved to the answer.
        .background(alignment: .leading) {
            Capsule()
                .fill(shown.map(tint) ?? Color.clear)
                .frame(width: Self.width, height: 28)
                .offset(x: CGFloat(at ?? 0) * Self.width)
                .opacity(at == nil ? 0 : 1)
        }
        .allowsHitTesting(!isReadOnly)
        .padding(2)
        .background(
            Capsule().fill(needsAnswer ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemFill))
        )
        .overlay(
            Capsule().strokeBorder(needsAnswer ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10),
                                   lineWidth: needsAnswer ? 1 : 0.5)
        )
        // The sheet caught up, or said no: the highlight goes where it says,
        // sliding too.
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: saved)
    }

    private func segment(_ status: SignupStatus, symbol: String) -> some View {
        let isOn = shown == status
        return Button { press(status) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                // Solid when chosen. Yellow needs a dark glyph; the other
                // two carry white.
                .foregroundStyle(isOn
                                 ? (status == .maybe ? Color.black : Color.white)
                                 : (needsAnswer ? Color.accentColor.opacity(0.85) : Color.secondary))
                .frame(width: Self.width, height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private func press(_ status: SignupStatus) {
        let target: SignupStatus? = shown == status ? nil : status
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { picked = .some(target) }
        UISelectionFeedbackGenerator().selectionChanged()
        if sending {
            queued = .some(target)
        } else {
            Task { await write(target) }
        }
    }

    /// Writes, then whatever was pressed meanwhile — the last press only.
    private func write(_ first: SignupStatus?) async {
        sending = true
        var next = first
        var written: SignupStatus?? = nil
        while written != .some(next) {
            await send(next)
            written = .some(next)
            if let later = queued {
                queued = nil
                next = later
            }
        }
        sending = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { picked = nil }
    }
}
