//
//  TeamStore.swift
//  SolaPraise
//
//  One Sunday's worth of preparation, read from the team sheet.
//
//  This is the thing a playlist cannot be. A playlist is an ordered list of
//  videos; a service also has a date, a set of roles, who filled them, the
//  key each song is actually played in, and the notes the leader left. The
//  sheet already holds all of it, so the app's job is to show it in the order
//  a musician needs it and to let a member sign up without leaving.
//

import Foundation
import SwiftUI

// MARK: - What a service is made of

struct TeamRole: Identifiable, Hashable {
    let name: String
    let order: Double
    var id: String { name }

    /// 인도자 and 반주자 decide whether a service can happen at all.
    ///
    /// Every other part can be covered, moved or dropped; these two cannot.
    /// So they sort to the top regardless of the Order column, and the sheet
    /// does not have to be maintained for that to stay true.
    var isCore: Bool { PartAliases.isCore(name) }
}

/// A file attached to a service, or to one song in it.
///
/// The bytes live in Drive; this is the index row on the sheet that points
/// at them. `song` empty means the file belongs to the whole service — the
/// combined 콘티 PDF is filed that way.
struct Attachment: Identifiable, Hashable {
    let date: Date
    let song: String
    let name: String
    let fileId: String
    let url: URL
    let addedBy: String
    /// 1-based row on the Attachments tab, so it can be cleared.
    var row: Int?

    var id: String { fileId }
    var belongsToService: Bool { song.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct TeamSong: Identifiable, Hashable {
    let order: Int
    let title: String
    let url: URL?
    /// The key the team plays it in, as the leader typed it. Authoritative
    /// over anything detection produces.
    let key: String?
    let transpose: Int
    let notes: String?
    /// 1-based row on the Songs tab.
    ///
    /// Without this, deleting a song from a 콘티 silently did nothing. Most
    /// teams have no Plan tab, so their 순서 IS the Songs tab promoted into
    /// one — and the promotion dropped the row, leaving the delete with
    /// nowhere to write. It refused, into a note at the bottom of a screen
    /// nobody was looking at.
    var row: Int? = nil
    var id: String { "\(order)-\(title)" }

    var videoId: String? { url.flatMap { YouTubeID.parse($0.absoluteString) } }
}

/// One line in the order of service.
struct PlanItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case song, prayer, reading, sermon, announcement, offering, transition, other

        init(raw: String) {
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch key {
            case "song", "찬양", "곡":            self = .song
            case "prayer", "기도":                self = .prayer
            case "reading", "말씀", "성경봉독":    self = .reading
            case "sermon", "설교":                self = .sermon
            case "announcement", "광고", "환영":   self = .announcement
            case "offering", "헌금", "봉헌":       self = .offering
            case "transition", "전환", "간주":     self = .transition
            default:                              self = Kind(rawValue: key) ?? .other
            }
        }

        var label: String {
            switch self {
            case .song:         return "찬양"
            case .prayer:       return "기도"
            case .reading:      return "말씀"
            case .sermon:       return "설교"
            case .announcement: return "광고"
            case .offering:     return "헌금"
            case .transition:   return "전환"
            case .other:        return "순서"
            }
        }

        var symbolName: String {
            switch self {
            case .song:         return "music.note"
            case .prayer:       return "hands.and.sparkles"
            case .reading:      return "book.closed"
            case .sermon:       return "text.bubble"
            case .announcement: return "megaphone"
            case .offering:     return "basket"
            case .transition:   return "arrow.right"
            case .other:        return "circle"
            }
        }
    }

    let order: Int
    let kind: Kind
    let title: String
    /// Planned length. Nil means nobody has estimated it, which is different
    /// from zero and must not be added into a running time as if it were.
    let minutes: Int?
    let person: String?
    let key: String?
    let url: URL?
    let notes: String?
    /// 1-based row, so an edit rewrites in place.
    let row: Int?

    var id: String { "\(order)-\(title)" }
    var videoId: String? { url.flatMap { YouTubeID.parse($0.absoluteString) } }
}

/// What a member said about one service.
///
/// 자리비움 is deliberately separate from 어려움. "I cannot do this Sunday"
/// and "I am away for a month" need different responses from a leader, and
/// collapsing them into one word loses the distinction that decides whether
/// to ask again next week.
enum SignupStatus: String {
    case available, maybe, declined, away

    init(raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "declined", "불가", "어려움":            self = .declined
        case "away", "자리비움", "부재":               self = .away
        case "maybe", "미정", "아마", "tentative":    self = .maybe
        default:                                     self = .available
        }
    }

    var label: String {
        switch self {
        case .available: return "가능"
        case .maybe:     return "미정"
        case .declined:  return "어려움"
        case .away:      return "자리비움"
        }
    }
}

struct TeamSignup: Identifiable, Hashable {
    let role: String
    let email: String
    let name: String
    let statusRaw: String
    /// 1-based row on the Signups tab, so an update rewrites in place rather
    /// than appending a second opinion.
    ///
    /// Optional because a signup created in this session has no row until
    /// the append reports one. It used to default to 0, and the next edit
    /// then addressed "A0:F0" — an invalid range, which failed silently and
    /// made the buttons look like they had stopped toggling after the first
    /// tap.
    let row: Int?
    var id: String { "\(role)|\(email)" }

    var status: SignupStatus { SignupStatus(raw: statusRaw) }
    var isAvailable: Bool { status == .available }
}

struct TeamService: Identifiable, Hashable {
    let date: Date
    let title: String
    /// As written on the sheet: "11:30 AM", "7:30 PM". Guessing this was
    /// wrong — 주일예배 is 11:30, 금요 Worship is 7:30 PM, 팀연습 is 9:30 AM,
    /// and a single assumed hour was right for almost none of them.
    let time: String?
    let location: String?
    let notes: String?
    /// Role name → assigned member, as filled in on the Schedule tab.
    let assignments: [String: String]
    /// The service's shared 찬양 playlist, from the Schedule tab's Playlist
    /// column. One per service, written once by whoever creates it and read
    /// by everybody — which is what makes it the team's playlist rather than
    /// one person's.
    var playlistId: String? = nil
    /// 1-based row on the Schedule tab, so an assignment knows where to
    /// write. nil for a service that did not come from a sheet — the DEBUG
    /// sample — and assignment is refused rather than guessed in that case.
    var row: Int? = nil
    /// Several services can fall on one day — 주일예배 and a 팀연습 the
    /// evening before a 금요 Worship — so the date alone is not an identity.
    var id: String { "\(date.timeIntervalSince1970)-\(title)" }

    var isPast: Bool { date < Calendar.current.startOfDay(for: Date()) }

    /// A rehearsal is scheduled and staffed like a service but has no order
    /// of service, so the tab should not offer one.
    var isRehearsal: Bool {
        let key = title.replacingOccurrences(of: " ", with: "")
        return key.contains("연습") || key.lowercased().contains("rehearsal")
    }

    /// Clock time from the sheet, falling back to the morning only when the
    /// sheet says nothing.
    func start(on calendar: Calendar = .current) -> Date {
        guard let time, let parsed = TeamSheet.timeFormatter.date(from: time.trimmingCharacters(in: .whitespaces))
        else {
            return calendar.date(bySettingHour: 11, minute: 0, second: 0, of: date) ?? date
        }
        let parts = calendar.dateComponents([.hour, .minute], from: parsed)
        return calendar.date(bySettingHour: parts.hour ?? 11,
                             minute: parts.minute ?? 0,
                             second: 0, of: date) ?? date
    }
}

// MARK: - Store

@MainActor
final class TeamStore: ObservableObject {

    @Published private(set) var services: [TeamService] = []
    @Published private(set) var roles: [TeamRole] = []
    @Published private(set) var songs: [Date: [TeamSong]] = [:]
    @Published private(set) var plans: [Date: [PlanItem]] = [:]

    /// Where each service currently is, and who last said so.
    @Published private(set) var liveOrder: [Date: Int] = [:]
    @Published private(set) var liveUpdatedBy: [Date: String] = [:]
    /// The sheet row holding that, so advancing rewrites rather than appends.
    private var liveRows: [Date: Int] = [:]
    @Published private(set) var signups: [Date: [TeamSignup]] = [:]
    @Published private(set) var memberEmails: Set<String> = []
    /// 헌신찬양 and 설교제목 from the church's own sheet, by day.
    @Published private(set) var churchNotes: [Date: ChurchNote] = [:]
    /// Role name → 0-based column on the Schedule tab, so an assignment
    /// knows which cell to write. Empty until a schedule has been read.
    @Published private(set) var roleColumns: [String: Int] = [:]
    /// Whether the Members tab names who the leaders are.
    @Published private(set) var hasLeaderColumn = false
    /// 0-based Playlist column on the Schedule tab, when the sheet has one.
    @Published private(set) var playlistColumn: Int?

    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var lastLoaded: Date?

    /// Set when a write comes back 403 while reads are fine.
    ///
    /// The sheet is commonly owned by the church's account while people sign
    /// in with their own, so "can read" and "can write" are genuinely
    /// separate here: link sharing gives everyone the first and nobody the
    /// second. Signing up silently failing would be the worst version of
    /// that, so it is stated and the buttons stop pretending.
    @Published private(set) var isReadOnly = false

    /// Set when even a READ comes back 403.
    ///
    /// With the sheet shared to anyone-with-the-link, a refused read cannot
    /// be about the document — it is the token missing the scope. Inferring
    /// that from `grantedScopes` alone proved unreliable on a restored
    /// session, so the server's answer is treated as the authority.
    @Published var needsAuthorization = false

    private var client: SheetsClient?
    private var drive: DriveClient?

    /// Attachments by service day. Empty for a sheet with no Attachments
    /// tab, which is every sheet until someone attaches something.
    @Published private(set) var attachments: [Date: [Attachment]] = [:]

    /// Which account reaches the sheet.
    ///
    /// The planning account when one is connected, otherwise whichever
    /// account is signed in for YouTube. Rebuilt whenever that changes, so
    /// connecting a church account mid-session takes effect without a
    /// relaunch.
    private var usingPlanningAccount = false

    /// Forgets everything read from the sheet.
    ///
    /// Signing out used to leave the roster, the schedule and everyone's
    /// answers in memory. The tab hides itself, so nobody saw it — until the
    /// next person signed in on the same iPad and the previous team's
    /// schedule was there waiting, before any load had run.
    func reset() {
        services = []
        roles = []
        songs = [:]
        plans = [:]
        signups = [:]
        memberEmails = []
        liveOrder = [:]
        liveUpdatedBy = [:]
        liveRows = [:]
        errorMessage = nil
        needsAuthorization = false
        isReadOnly = false
        lastLoaded = nil
        client = nil
        usingPlanningAccount = false
    }

#if DEBUG
    /// Set in sample mode: answering is applied in memory instead of being
    /// written to a sheet, so the whole answer flow can be driven in a
    /// simulator. Without it the switch bailed on a nil sheet id and looked
    /// exactly like the bug it was meant to be testing.
    private(set) var isSample = false
    var sampleActingEmail: String?

    /// Drops sample data straight in, for reviewing 예배 without a sheet.
    func installSample(services: [TeamService], roles: [TeamRole],
                       signups: [Date: [TeamSignup]], plans: [Date: [PlanItem]],
                       members: Set<String>, roster: [Member] = [],
                       churchNotes: [Date: ChurchNote] = [:]) {
        isSample = true
        sampleActingEmail = members.sorted().first
        self.services = services
        self.roles = roles
        self.signups = signups
        self.plans = plans
        self.memberEmails = members
        self.members = roster
        self.churchNotes = churchNotes
        self.isReadOnly = false
        self.lastLoaded = Date()
    }
#endif

    func configure(auth: GoogleAuthManager, planning: PlanningAuth) {
        let wantsPlanning = planning.isSignedIn
        guard client == nil || wantsPlanning != usingPlanningAccount else { return }
        usingPlanningAccount = wantsPlanning
        client = SheetsClient {
            wantsPlanning
                ? try await planning.token()
                : try await auth.accessToken()
        }
        // Drive ONLY through the planning grant.
        //
        // Google refuses youtube and drive.file in one authorization
        // request, so the main sign-in cannot carry Drive at all. This
        // grant has no YouTube scope and can. `canAttach` is what the UI
        // asks before offering to upload.
        drive = planning.isSignedIn
            ? DriveClient { try await planning.token() }
            : nil
    }

    /// The address writes will be attributed to.
    func actingEmail(auth: GoogleAuthManager, planning: PlanningAuth) -> String? {
        #if DEBUG
        if let sampleActingEmail { return sampleActingEmail }
        #endif
        return planning.isSignedIn ? planning.email : auth.email
    }

    /// The next service that has not happened yet, which is what anyone
    /// opening this tab is almost always here for.
    var upcoming: TeamService? {
        services.first { !$0.isPast } ?? services.last
    }

    /// The order of service, or the 콘티 promoted into one.
    ///
    /// A sheet without a Plan tab still has songs, and a list of songs is a
    /// perfectly good order of service for a team that only plans music — so
    /// it is shown as one rather than showing nothing.
    func plan(for service: TeamService) -> [PlanItem] {
        let day = Calendar.current.startOfDay(for: service.date)
        if let items = plans[day], !items.isEmpty {
            return items.sorted { $0.order < $1.order }
        }
        return songs(for: service).map {
            PlanItem(order: $0.order, kind: .song, title: $0.title,
                     minutes: nil, person: nil, key: $0.key, url: $0.url,
                     notes: $0.notes, row: $0.row)
        }
    }

    var hasPlanTab: Bool { !plans.isEmpty }

    /// Clock times for a plan, from a start time and the planned lengths.
    ///
    /// An item with no length does not advance the clock, and everything
    /// after an unestimated item is therefore approximate — which is honest,
    /// and better than inventing a duration to keep the arithmetic tidy.
    static func startTimes(for items: [PlanItem], from start: Date) -> [String: Date] {
        var out: [String: Date] = [:]
        var cursor = start
        for item in items {
            out[item.id] = cursor
            guard let minutes = item.minutes, minutes > 0 else { continue }
            cursor = cursor.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return out
    }

    func songs(for service: TeamService) -> [TeamSong] {
        (songs[Calendar.current.startOfDay(for: service.date)] ?? [])
            .sorted { $0.order < $1.order }
    }

    func signups(for service: TeamService, role: String) -> [TeamSignup] {
        (signups[Calendar.current.startOfDay(for: service.date)] ?? [])
            .filter { $0.role == role && $0.isAvailable }
    }

    /// Every response for a role, whatever it said.
    func signupsAll(for service: TeamService, role: String) -> [TeamSignup] {
        (signups[Calendar.current.startOfDay(for: service.date)] ?? [])
            .filter { $0.role == role }
    }

    func mySignup(for service: TeamService, role: String, email: String) -> TeamSignup? {
        (signups[Calendar.current.startOfDay(for: service.date)] ?? [])
            .first { $0.role == role && $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    // MARK: - Loading

    func load(sheetId: String) async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Four reads rather than one batch: each tab is parsed
            // differently and a failure in one should not lose the others.
            async let scheduleRows = client.read(sheetId: sheetId, range: TeamSheet.scheduleTab)
            async let roleRows     = client.read(sheetId: sheetId, range: TeamSheet.rolesTab)
            async let songRows     = client.read(sheetId: sheetId, range: TeamSheet.songsTab)
            async let signupRows   = client.read(sheetId: sheetId, range: TeamSheet.signupsTab)

            let (schedule, roleData, songData, signupData) =
                try await (scheduleRows, roleRows, songRows, signupRows)

            // Optional tab: absent on a sheet made before the order of
            // service existed, which must keep working.
            let planData = (try? await client.read(sheetId: sheetId, range: TeamSheet.planTab)) ?? []
            plans = Self.parsePlan(planData)

            roles = Self.parseRoles(roleData)
            services = Self.parseSchedule(schedule, roles: roles)
            roleColumns = Self.scheduleRoleColumns(schedule)
            playlistColumn = Self.schedulePlaylistColumn(schedule)
            songs = Self.parseSongs(songData)
            signups = Self.parseSignups(signupData)
            signupLayout = SignupLayout(header: signupData.first ?? [])
            memberEmails = await loadMembers(sheetId: sheetId, client: client)
            await loadChurchNotes(client: client)
            await loadAttachments(sheetId: sheetId, client: client)
            lastLoaded = Date()
            needsAuthorization = false
        } catch SheetsClient.SheetsError.http(403, let message) {
            needsAuthorization = true
            errorMessage = message ?? "시트를 읽을 권한이 없습니다."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The church sheet's two columns, if there is a church sheet.
    ///
    /// Never throws outward and never sets `errorMessage`. This is a
    /// different document, owned by someone else, and the team's own planner
    /// has to keep working when it is missing, renamed, unshared or simply
    /// not configured — a 403 here is not the team's problem to see.
    private func loadChurchNotes(client: SheetsClient) async {
        guard let id = ChurchSheetSource.current,
              let range = ChurchSheet.encodedRange else { churchNotes = [:]; return }
        guard let rows = try? await client.readEncoded(sheetId: id, encodedRange: range)
        else { churchNotes = [:]; return }
        churchNotes = ChurchSheet.notes(from: rows)
    }

    /// What the church sheet says about a service, if anything.
    func churchNote(for service: TeamService) -> ChurchNote? {
        churchNotes[Calendar.current.startOfDay(for: service.date)]
    }

    /// The Members tab is optional. Without one, anyone who can open the
    /// sheet counts as a member — which is the same thing, since Google's own
    /// sharing is what actually protects it.
    private func loadMembers(sheetId: String, client: SheetsClient) async -> Set<String> {
        guard let rows = try? await client.read(sheetId: sheetId, range: TeamSheet.membersTab),
              rows.count > 1 else { members = []; return [] }

        let header = rows[0]
        // Name before Email is just as natural to write, and reading by
        // position turned the name into the address.
        let emailCol = TeamSheet.column(header, ["email", "이메일", "메일"]) ?? 0
        let nameCol = TeamSheet.column(header, ["name", "이름"]) ?? 1
        let activeCol = TeamSheet.column(header, ["active", "사용", "활성"])
        // Optional. A sheet without it is handled in `canAssign`, not here.
        let leaderCol = TeamSheet.column(header, ["leader", "리더", "팀장", "인도자여부", "관리자"])
        hasLeaderColumn = leaderCol != nil

        var emails: Set<String> = []
        var list: [Member] = []
        for (offset, row) in rows.enumerated() where offset > 0 {
            func cell(_ i: Int) -> String {
                row.count > i ? row[i].trimmingCharacters(in: .whitespaces) : ""
            }
            let email = cell(emailCol)
            let name = cell(nameCol)
            // A member with no address yet is still on the team.
            //
            // Requiring one dropped eight of nine people from this roster,
            // so the leader saw a team of one and nobody listed as still to
            // answer. They cannot respond in the app until they have an
            // address, which is exactly what showing them as pending says.
            guard !name.isEmpty || email.contains("@") else { continue }
            let activeCell = activeCol.map { cell($0).lowercased() } ?? "true"
            let active = !["false", "no", "n", "0"].contains(activeCell)
            let leaderCell = leaderCol.map { cell($0).lowercased() } ?? ""
            let isLeader = ["true", "yes", "y", "o", "1", "리더", "팀장"].contains(leaderCell)
            list.append(Member(email: email, name: name, isActive: active,
                               row: offset + 1, isLeader: isLeader))
            if active, email.contains("@") { emails.insert(email.lowercased()) }
        }
        members = list
        return emails
    }

    // MARK: - Signing up

    /// Records availability, rewriting the member's existing row when they
    /// already answered — otherwise saying yes then no would leave both.
    /// Everyone on the roster who has not answered for this service.
    ///
    /// The leader's real question is not who said yes — it is who has said
    /// nothing, because that is the list to go and ask. Members who are away
    /// have answered and are not chased.
    func unanswered(for service: TeamService) -> [String] {
        guard !memberEmails.isEmpty else { return [] }
        let day = Calendar.current.startOfDay(for: service.date)
        let answered = Set((signups[day] ?? []).map { $0.email.lowercased() })
        return memberEmails.subtracting(answered).sorted()
    }

    /// Everyone on the roster who has not answered, named.
    ///
    /// Includes members with no address: they cannot answer at all, which
    /// makes them more pending rather than less.
    func pendingNames(for service: TeamService) -> [String] {
        let day = Calendar.current.startOfDay(for: service.date)
        let answered = Set((signups[day] ?? []).map { $0.email.lowercased() })
        // Somebody the leader has put on a part is already on the row, in
        // orange, saying exactly what they are down for. Listing them again
        // as 미응답 was the same person twice on one line — and it made a
        // service that had just been staffed look untouched.
        //
        // They have still not answered, and the orange hollow ring is what
        // says so. The 미응답 chips are for the people the row would
        // otherwise not mention at all.
        let assigned = service.assignments.values
            .map { $0.replacingOccurrences(of: " ", with: "") }
            .filter { !$0.isEmpty }

        // Loosely, because the two tabs are typed by different people. The
        // Schedule cell says 김은혜 where the Members tab says 은혜 — the
        // leader writes the full name into the plan and the roster carries
        // what the team calls her. Exact matching left her listed as 미응답
        // on a week she had just been given 반주.
        //
        // Two characters minimum on the shorter side, so a one-letter cell —
        // an initial, a stray 'x' marking a column — cannot swallow a name
        // it merely appears inside.
        func isAssigned(_ name: String) -> Bool {
            let needle = name.replacingOccurrences(of: " ", with: "")
            guard !needle.isEmpty else { return false }
            return assigned.contains { cell in
                if cell == needle { return true }
                let shorter = min(cell.count, needle.count)
                guard shorter >= 2 else { return false }
                return cell.contains(needle) || needle.contains(cell)
            }
        }

        return members
            .filter { $0.isActive }
            .filter { $0.email.isEmpty || !answered.contains($0.email.lowercased()) }
            .map { $0.name.isEmpty ? $0.email : $0.name }
            .filter { !isAssigned($0) }
            .sorted()
    }

    /// The roster's name for an address.
    ///
    /// One place sets how a person is shown: the Members tab. A signup row
    /// carries whatever name the app happened to know when it was written —
    /// for a Google account that is the profile name, "Juyoung Kim", which
    /// is not what the team calls anyone. Changing 이름 on the Members tab
    /// now changes it everywhere, including on answers already given.
    func rosterName(for email: String) -> String? {
        let match = members.first {
            !$0.email.isEmpty && $0.email.caseInsensitiveCompare(email) == .orderedSame
        }
        let name = match?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }

    /// Every address that is me.
    ///
    /// With the church account connected there are two, and an answer filed
    /// under one of them was somebody else's as far as the other was
    /// concerned — the row showed "Juyoung Kim 보컬" and the switch beside it
    /// did nothing, because the app was looking at a different address.
    func myAddresses(auth: GoogleAuthManager, planning: PlanningAuth) -> [String] {
        #if DEBUG
        if let sampleActingEmail { return [sampleActingEmail] }
        #endif
        return [auth.email, planning.email].compactMap { $0 }.filter { !$0.isEmpty }
    }

    func isMe(_ email: String, auth: GoogleAuthManager, planning: PlanningAuth) -> Bool {
        myAddresses(auth: auth, planning: planning).contains {
            $0.caseInsensitiveCompare(email) == .orderedSame
        }
    }

    func responses(for service: TeamService) -> [TeamSignup] {
        let day = Calendar.current.startOfDay(for: service.date)
        // One line per person, not per role, which is how a leader reads it.
        var seen: [String: TeamSignup] = [:]
        for signup in signups[day] ?? [] {
            seen[signup.email.lowercased()] = signup
        }
        // Who is coming first. That is the question being asked; declines
        // and absences are the answer to a different one.
        func rank(_ status: SignupStatus) -> Int {
            switch status {
            case .available: return 0
            // A maybe is still somebody considering it, so it sorts above a
            // no — a leader reading the line wants the possibles next.
            case .maybe:     return 1
            case .declined:  return 2
            case .away:      return 3
            }
        }
        return seen.values.sorted {
            (rank($0.status), $0.name) < (rank($1.status), $1.name)
        }
    }

    func setAvailability(
        _ status: SignupStatus,
        service: TeamService,
        role: String,
        email: String,
        name: String,
        sheetId: String
    ) async {
        #if DEBUG
        if isSample {
            let day = Calendar.current.startOfDay(for: service.date)
            var list = signups[day] ?? []
            list.removeAll { $0.email.caseInsensitiveCompare(email) == .orderedSame }
            list.append(TeamSignup(role: role, email: email, name: name,
                                   statusRaw: status.rawValue, row: nil))
            signups[day] = list
            return
        }
        #endif
        guard let client else { return }
        let day = Calendar.current.startOfDay(for: service.date)
        let row = signupLayout.row(
            date: TeamSheet.dateFormatter.string(from: service.date),
            role: role,
            email: email,
            name: name,
            status: status.rawValue,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )

        do {
            isReadOnly = false
            let existing = mySignup(for: service, role: role, email: email)
            var writtenRow = existing?.row

            // Row 1 is the header, so anything below 2 is not a real row to
            // rewrite — append and learn where it went.
            if let target = existing?.row, target >= 2 {
                try await client.write(
                    sheetId: sheetId,
                    range: "\(TeamSheet.signupsTab)!A\(target):\(signupLayout.lastColumnLetter)\(target)",
                    row: row
                )
            } else {
                writtenRow = try await client.append(
                    sheetId: sheetId, tab: TeamSheet.signupsTab, row: row
                )
            }

            // Reflect it immediately; the sheet is the truth but a reload is
            // four round trips and this is one tap.
            var list = signups[day] ?? []
            list.removeAll { $0.role == role && $0.email.caseInsensitiveCompare(email) == .orderedSame }
            list.append(TeamSignup(role: role, email: email, name: name,
                                   statusRaw: status.rawValue, row: writtenRow))
            signups[day] = list
        } catch SheetsClient.SheetsError.http(403, _) {
            // Reads work, so this is not the scope and not the sheet being
            // missing: this account has view access where it needs edit.
            isReadOnly = true
            errorMessage = "이 시트에 편집 권한이 없어 사인업을 저장하지 못했습니다. 시트 주인에게 이 계정을 편집자로 추가해 달라고 요청하세요."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Attachments

    /// The Attachments tab, if the sheet has one.
    ///
    /// Optional like Plan: a team that has never attached anything has no
    /// such tab, and that is not an error. The tab is created on the first
    /// upload rather than demanded up front.
    private func loadAttachments(sheetId: String, client: SheetsClient) async {
        guard let rows = try? await client.read(
            sheetId: sheetId, range: TeamSheet.attachmentsTab
        ), rows.count > 1 else { attachments = [:]; return }

        let header = rows[0]
        let dateCol = TeamSheet.column(header, ["date", "날짜"]) ?? TeamSheet.Attachments.date
        let songCol = TeamSheet.column(header, ["song", "곡", "찬양"]) ?? TeamSheet.Attachments.song
        let nameCol = TeamSheet.column(header, ["name", "이름", "파일"]) ?? TeamSheet.Attachments.name
        let idCol = TeamSheet.column(header, ["fileid", "파일id"]) ?? TeamSheet.Attachments.fileId
        let urlCol = TeamSheet.column(header, ["url", "link", "링크"]) ?? TeamSheet.Attachments.url
        let byCol = TeamSheet.column(header, ["addedby", "올린사람", "작성자"])

        var out: [Date: [Attachment]] = [:]
        for (offset, row) in rows.enumerated() where offset > 0 {
            func cell(_ i: Int?) -> String {
                guard let i, row.count > i else { return "" }
                return row[i].trimmingCharacters(in: .whitespaces)
            }
            guard let date = TeamSheet.day(cell(dateCol)) else { continue }
            let link = cell(urlCol)
            guard let url = URL(string: link), !cell(idCol).isEmpty else { continue }
            out[Calendar.current.startOfDay(for: date), default: []].append(
                Attachment(date: date, song: cell(songCol), name: cell(nameCol),
                           fileId: cell(idCol), url: url, addedBy: cell(byCol),
                           row: offset + 1)
            )
        }
        attachments = out
    }

    /// Whether this device can upload an attachment.
    ///
    /// Reading one never needs this — every file is shared by link — so a
    /// member without the second grant still opens everything the team has
    /// attached. Only putting a new file up requires it.
    var canAttach: Bool { drive != nil }

    func attachments(for service: TeamService) -> [Attachment] {
        attachments[Calendar.current.startOfDay(for: service.date)] ?? []
    }

    /// Files attached to one song, matched on the title the 콘티 shows.
    func attachments(for service: TeamService, song: String) -> [Attachment] {
        let key = song.trimmingCharacters(in: .whitespaces)
        return attachments(for: service).filter { $0.song == key }
    }

    /// Uploads a file and records it against a service, or one of its songs.
    ///
    /// Two writes that must both land: the bytes go to Drive and a row goes
    /// on the sheet. If the row fails the file is removed again, because a
    /// Drive file nothing points at is litter in somebody's Drive that they
    /// will never find to delete.
    func attach(
        data: Data,
        name: String,
        mimeType: String,
        song: String,
        to service: TeamService,
        sheetId: String,
        by email: String
    ) async -> String? {
        guard let client, let drive else { return "구글 계정에 연결되어 있지 않습니다." }

        let uploaded: DriveClient.Uploaded
        do {
            uploaded = try await drive.upload(data: data, name: name, mimeType: mimeType)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        let row = [
            TeamSheet.dateFormatter.string(from: service.date),
            song,
            name,
            uploaded.fileId,
            uploaded.link.absoluteString,
            email,
            ISO8601DateFormatter().string(from: Date())
        ]

        do {
            try await ensureAttachmentsTab(sheetId: sheetId, client: client)
            let written = try await client.append(
                sheetId: sheetId, tab: TeamSheet.attachmentsTab, row: row
            )
            let day = Calendar.current.startOfDay(for: service.date)
            attachments[day, default: []].append(
                Attachment(date: service.date, song: song, name: name,
                           fileId: uploaded.fileId, url: uploaded.link,
                           addedBy: email, row: written)
            )
            errorMessage = nil
            return nil
        } catch {
            // The sheet refused, so take the orphan back out of Drive.
            try? await drive.delete(fileId: uploaded.fileId)
            if case SheetsClient.SheetsError.http(403, _) = error { isReadOnly = true }
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Creates the Attachments tab the first time one is needed.
    ///
    /// Reading a tab that does not exist throws, which is how this knows.
    /// Adding a TAB is safe where adding a COLUMN is not: a new tab cannot
    /// shift anything the team already has.
    private func ensureAttachmentsTab(sheetId: String, client: SheetsClient) async throws {
        if let rows = try? await client.read(
            sheetId: sheetId, range: "\(TeamSheet.attachmentsTab)!1:1"
        ), !(rows.first ?? []).isEmpty {
            return
        }
        try await client.addSheet(sheetId: sheetId, title: TeamSheet.attachmentsTab)
        _ = try await client.append(
            sheetId: sheetId, tab: TeamSheet.attachmentsTab,
            row: TeamSheet.Attachments.header
        )
    }

    /// Removes an attachment from the sheet and from Drive.
    func removeAttachment(_ item: Attachment, sheetId: String) async -> String? {
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        guard let row = item.row, row >= 2 else { return "줄 번호를 알 수 없습니다." }
        do {
            try await client.write(
                sheetId: sheetId,
                range: "\(TeamSheet.attachmentsTab)!A\(row):\(TeamSheet.columnLetter(TeamSheet.Attachments.width - 1))\(row)",
                row: [String](repeating: "", count: TeamSheet.Attachments.width)
            )
            // Best effort: the file may belong to another member's Drive,
            // where this account cannot touch it. The index row is what the
            // app reads, so clearing that is what actually removes it.
            try? await drive?.delete(fileId: item.fileId)
            let day = Calendar.current.startOfDay(for: item.date)
            attachments[day]?.removeAll { $0.fileId == item.fileId }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Assigning somebody else

    /// Whether this account may put other people's names on the schedule.
    ///
    /// WHERE THE LINE ACTUALLY IS: the sheet is the permission system. Anyone
    /// Google has made an editor can already type any name into any cell from
    /// a browser, and nothing the app does changes that. So this is not a
    /// security control and must not be dressed up as one — it is there so
    /// that a team which has decided who schedules can have the app reflect
    /// that decision, and so the rest of the team does not reorder Sunday by
    /// mis-tapping a chip.
    ///
    /// A Members tab with no Leader column means the team has not made that
    /// decision, and the app does not invent one: everybody may assign, which
    /// is exactly what the sheet already allows them. Adding the column is
    /// how a team narrows it.
    func canAssign(email: String?) -> Bool {
        guard !isReadOnly else { return false }
        guard hasLeaderColumn else { return true }
        guard let email = email?.lowercased(), !email.isEmpty else { return false }
        return members.contains {
            $0.isLeader && $0.email.lowercased() == email
        }
    }

    /// The Schedule tab's own spelling of a part.
    ///
    /// The chips say 인도 and 반주 — short keys the row is built from — while
    /// the sheet's column is as often 인도자 or 반주자. keyPart already
    /// matches loosely in that direction when READING, so without the same
    /// rule here a tap on 인도 asked to write a column called 인도, which does
    /// not exist, and the save failed on a sheet that was perfectly correct.
    func scheduleRoleName(matching role: String) -> String? {
        if roleColumns[role] != nil { return role }
        let key = PartAliases.key(role)
        // Exact-but-for-spacing first, then the alias rule — so a tap on 반주
        // finds a sheet whose column is 반주자, 건반 or Piano.
        if let hit = roleColumns.keys.first(where: { PartAliases.key($0) == key }) { return hit }
        return roleColumns.keys
            .filter { PartAliases.matches($0, role) }
            .min { $0.count < $1.count }
    }

    /// Names that may be put into a role, newest roster first.
    var assignableNames: [String] {
        members.filter { $0.isActive && !$0.name.isEmpty }
            .map(\.name)
            .sorted()
    }

    /// Puts somebody's name in a role on the Schedule tab — or clears it.
    ///
    /// This writes the LEADER'S PLAN, not an answer. The distinction is the
    /// whole point of the two tabs: Schedule says who is meant to do it,
    /// Signups says who has agreed. Assigning somebody does not answer for
    /// them, and the chip stays orange until they say yes themselves.
    func assign(
        role: String,
        to name: String?,
        service: TeamService,
        sheetId: String
    ) async -> String? {
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (cleaned?.isEmpty ?? true) ? "" : cleaned!

        #if DEBUG
        if isSample {
            applyAssignmentLocally(role: role, value: value, service: service)
            return nil
        }
        #endif

        guard let client else { return "시트에 연결되어 있지 않습니다." }
        guard let row = service.row, row >= 2 else {
            return "이 예배가 시트의 몇 번째 줄인지 알 수 없어 지정할 수 없습니다. 새로 고친 뒤 다시 시도해 주세요."
        }
        guard let column = roleColumns[role] else {
            // The role exists on the Roles tab but has no column on Schedule.
            // Creating one would move every column to its right, which is a
            // destructive edit to somebody else's document — so it says what
            // to do instead of doing it.
            return "Schedule 탭에 「\(role)」 열이 없습니다. 시트에 열을 추가한 뒤 새로 고쳐 주세요."
        }

        let cell = "\(TeamSheet.scheduleTab)!\(TeamSheet.columnLetter(column))\(row)"
        do {
            isReadOnly = false
            try await client.write(sheetId: sheetId, range: cell, row: [value])
            applyAssignmentLocally(role: role, value: value, service: service)
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 지정하지 못했습니다."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Records a service's shared playlist on the Schedule tab.
    ///
    /// Written to the sheet rather than kept on the device, because the
    /// point is that it is the TEAM's playlist: one person makes it, and
    /// everybody else's app finds it on the next load. A copy held locally
    /// would be a playlist only its author could see.
    func setPlaylist(
        _ playlistId: String,
        for service: TeamService,
        sheetId: String
    ) async -> String? {
        #if DEBUG
        if isSample { applyPlaylistLocally(playlistId, service: service); return nil }
        #endif
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        guard let row = service.row, row >= 2 else {
            return "이 예배가 시트의 몇 번째 줄인지 알 수 없습니다. 새로 고친 뒤 다시 시도해 주세요."
        }
        guard let column = playlistColumn else {
            // Adding a column shifts every column to its right in a document
            // the team shares, so this says what to do instead of doing it.
            return "Schedule 탭에 「재생목록」 열을 추가한 뒤 새로 고쳐 주세요."
        }

        let cell = "\(TeamSheet.scheduleTab)!\(TeamSheet.columnLetter(column))\(row)"
        do {
            isReadOnly = false
            try await client.write(
                sheetId: sheetId, range: cell,
                row: [YouTubePlaylistID.url(playlistId)?.absoluteString ?? playlistId]
            )
            applyPlaylistLocally(playlistId, service: service)
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 저장하지 못했습니다."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func applyPlaylistLocally(_ playlistId: String, service: TeamService) {
        guard let index = services.firstIndex(where: { $0.id == service.id }) else { return }
        var updated = services[index]
        updated.playlistId = playlistId
        services[index] = updated
    }

    /// Every shared playlist the schedule names, newest service first.
    ///
    /// What the home screen and the 찬양 tab subscribe to, so a playlist one
    /// person created for Sunday reaches the whole team.
    var sharedPlaylists: [(service: TeamService, playlistId: String)] {
        services
            .sorted { $0.date > $1.date }
            .compactMap { service in
                service.playlistId.map { (service, $0) }
            }
    }

    /// Reflects the write without a four-round-trip reload.
    private func applyAssignmentLocally(role: String, value: String, service: TeamService) {
        guard let index = services.firstIndex(where: { $0.id == service.id }) else { return }
        var assignments = services[index].assignments
        if value.isEmpty { assignments.removeValue(forKey: role) }
        else { assignments[role] = value }
        services[index] = TeamService(
            date: services[index].date,
            title: services[index].title,
            time: services[index].time,
            location: services[index].location,
            notes: services[index].notes,
            assignments: assignments,
            row: services[index].row
        )
    }

    /// Takes back every answer this person has given for a service.
    ///
    /// Not one role's row — all of them. The sheet keeps a row per person
    /// PER PART, so somebody who answered 인도 one week and 반주 the next has
    /// two, and clearing only the one the row happened to be showing left
    /// the other behind still saying "available". The switch went off and
    /// came straight back on, which is exactly what it looked like.
    ///
    /// Blanked rather than deleted: parseSignups skips any row without a
    /// readable date, and deleting outright needs the tab's numeric id and a
    /// batchUpdate. The empty row is read by nothing.
    @discardableResult
    func clearAvailability(
        service: TeamService,
        emails: [String],
        sheetId: String
    ) async -> Bool {
        let day = Calendar.current.startOfDay(for: service.date)
        func isMine(_ signup: TeamSignup) -> Bool {
            emails.contains { $0.caseInsensitiveCompare(signup.email) == .orderedSame }
        }
        let mine = (signups[day] ?? []).filter(isMine)
        func forget() {
            signups[day]?.removeAll(where: isMine)
        }
        #if DEBUG
        if isSample { forget(); return true }
        #endif
        guard let client else { forget(); return true }

        let rows = mine.compactMap(\.row).filter { $0 >= 2 }
        guard !rows.isEmpty else {
            // Never reached the sheet, so there is nothing to blank.
            forget()
            return true
        }
        do {
            isReadOnly = false
            let blank = [String](repeating: "", count: signupLayout.width)
            for target in rows {
                try await client.write(
                    sheetId: sheetId,
                    range: "\(TeamSheet.signupsTab)!A\(target):\(signupLayout.lastColumnLetter)\(target)",
                    row: blank
                )
            }
            forget()
            errorMessage = nil
            return true
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            errorMessage = "이 시트에 편집 권한이 없어 응답을 취소하지 못했습니다."
            return false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Adds one item to a service's order — 특별순서, 헌금, 광고, anything the
    /// week has that the usual template does not.
    ///
    /// The screen used to say "add it on the sheet's Plan tab", which is true
    /// and useless on a phone in a sanctuary. The only thing the app could
    /// write was a playlist's songs, so every non-song item meant opening
    /// Google Sheets on something with a keyboard.
    ///
    /// Appended at the end with the next order number. Where it belongs in
    /// the service is the leader's business and the sheet is where it gets
    /// moved — this is for getting it in.
    @discardableResult
    func appendPlanItem(
        title: String,
        kind: PlanItem.Kind,
        minutes: Int?,
        to service: TeamService,
        sheetId: String
    ) async -> Bool {
        guard let client else { return false }
        let day = Calendar.current.startOfDay(for: service.date)
        let existing = plans[day] ?? []
        let order = (existing.map(\.order).max() ?? 0) + 1

        // The Plan tab's own column order, read from its header, so this
        // writes into the sheet the team actually has rather than one the app
        // wishes they had.
        guard let header = try? await client.read(
            sheetId: sheetId, range: "\(TeamSheet.planTab)!1:1"
        ).first, !header.isEmpty else {
            errorMessage = "시트에 Plan 탭이 없습니다. 먼저 Plan 탭을 만들어 주세요."
            return false
        }

        var cells = [String](repeating: "", count: header.count)
        func put(_ names: [String], _ value: String) {
            if let i = TeamSheet.column(header, names), cells.indices.contains(i) {
                cells[i] = value
            }
        }
        put(["date", "날짜"], TeamSheet.dateFormatter.string(from: service.date))
        put(["order", "#"], String(order))
        put(["type", "구분", "순서종류"], kind.label)
        put(["title", "내용", "순서"], title)
        if let minutes { put(["minutes", "분", "길이"], String(minutes)) }

        do {
            isReadOnly = false
            let row = try await client.append(
                sheetId: sheetId, tab: TeamSheet.planTab, row: cells
            )
            plans[day, default: []].append(
                PlanItem(order: order, kind: kind, title: title, minutes: minutes,
                         person: nil, key: nil, url: nil, notes: nil, row: row)
            )
            errorMessage = nil
            return true
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            errorMessage = "이 시트에 편집 권한이 없어 순서를 추가하지 못했습니다."
            return false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Takes one line out of a service's 순서.
    ///
    /// Blanked rather than deleted. Deleting a row outright needs the tab's
    /// numeric id and a batchUpdate, and it would renumber every row below
    /// it — including rows belonging to other Sundays, since one tab holds
    /// the whole season. parsePlan and parseSongs both skip a row with no
    /// readable date, so an empty row is read by nothing.
    ///
    /// Writes to whichever tab the item was read from: a sheet with no Plan
    /// tab shows its Songs as an order of service, and those rows live in
    /// Songs. Blanking the wrong tab would wipe an unrelated line.
    func removePlanItem(
        _ item: PlanItem,
        from service: TeamService,
        sheetId: String
    ) async -> String? {
        let day = Calendar.current.startOfDay(for: service.date)

        #if DEBUG
        if isSample {
            plans[day]?.removeAll { $0.id == item.id }
            return nil
        }
        #endif
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        guard let row = item.row, row >= 2 else {
            return "이 순서가 시트의 몇 번째 줄인지 알 수 없습니다. 새로 고친 뒤 다시 시도해 주세요."
        }

        let tab = hasPlanTab ? TeamSheet.planTab : TeamSheet.songsTab
        let header = (try? await client.read(sheetId: sheetId, range: "\(tab)!1:1"))?.first ?? []
        let width = max(header.count, 7)
        let last = TeamSheet.columnLetter(width - 1)

        do {
            isReadOnly = false
            try await client.write(
                sheetId: sheetId,
                range: "\(tab)!A\(row):\(last)\(row)",
                row: [String](repeating: "", count: width)
            )
            plans[day]?.removeAll { $0.id == item.id }
            if !hasPlanTab {
                songs[day]?.removeAll { $0.order == item.order && $0.title == item.title }
            }
            errorMessage = nil
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 지우지 못했습니다."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Pushing a 콘티 into the sheet

    struct PushResult {
        let written: Int
        let replaced: Int
    }

    /// Writes a playlist into the Songs tab as this service's 콘티.
    ///
    /// The point of the bridge: the playlist already holds the order and the
    /// links, and the app already knows the key from any chart the team has
    /// made — so the leader should not be retyping all three into a
    /// spreadsheet.
    ///
    /// Existing rows for the date are rewritten in place rather than
    /// appended to. Appending would leave last week's attempt underneath the
    /// new one, and the sheet is what the team reads on Sunday morning.
    func pushSongs(
        _ incoming: [TeamSong],
        to service: TeamService,
        sheetId: String,
        existingRows: [[String]]
    ) async throws -> PushResult {
        guard let client else { throw SheetsClient.SheetsError.noSheet }
        let day = TeamSheet.dateFormatter.string(from: service.date)

        // Written in the tab's own column order. This sheet has a Service
        // column the app never knew about, and a fixed order would have put
        // the title where the order goes and the link where the title goes —
        // right values, wrong cells, which is worse than refusing.
        let header = existingRows.first ?? []
        let layout = SongLayout(header: header)

        // 1-based sheet rows already holding this date.
        var targets: [Int] = []
        for (offset, row) in existingRows.enumerated() where offset > 0 {
            guard row.count > layout.date,
                  let date = TeamSheet.day(row[layout.date]),
                  Calendar.current.isDate(date, inSameDayAs: service.date) else { continue }
            targets.append(offset + 1)
        }

        func cells(_ song: TeamSong) -> [String] {
            layout.row(
                date: day,
                order: String(song.order),
                title: song.title,
                url: song.url?.absoluteString ?? "",
                key: song.key ?? "",
                transpose: song.transpose == 0 ? "" : String(song.transpose),
                notes: song.notes ?? "",
                // Columns the app does not own are left exactly as they were,
                // so a leader's own notes survive a push.
                existing: targets.isEmpty ? nil : nil
            )
        }

        var updates: [(range: String, rows: [[String]])] = []
        for (index, song) in incoming.enumerated() where index < targets.count {
            let row = targets[index]
            updates.append((
                "\(TeamSheet.songsTab)!A\(row):\(layout.lastColumnLetter)\(row)",
                [cells(song)]
            ))
        }
        // Rows the old 콘티 used and the new one does not: blanked, not left
        // behind claiming to be part of this Sunday.
        for row in targets.dropFirst(incoming.count) {
            updates.append((
                "\(TeamSheet.songsTab)!A\(row):\(layout.lastColumnLetter)\(row)",
                [Array(repeating: "", count: layout.width)]
            ))
        }
        if !updates.isEmpty {
            try await client.batchWrite(sheetId: sheetId, updates: updates)
        }

        // Anything beyond the rows that existed has to be appended.
        for song in incoming.dropFirst(targets.count) {
            try await client.append(sheetId: sheetId, tab: TeamSheet.songsTab, row: cells(song))
        }

        songs[Calendar.current.startOfDay(for: service.date)] = incoming
        return PushResult(written: incoming.count, replaced: targets.count)
    }

    /// Adds one song to a service's 콘티.
    ///
    /// The path from "this is the one" to "it is on Sunday's list" ran
    /// through a playlist: add it there, pin the playlist, push the whole
    /// thing — which also overwrote whatever was already planned. Deciding
    /// on a single song is the common case and now takes one action.
    func appendSong(
        title: String,
        videoId: String,
        key: String?,
        to service: TeamService,
        sheetId: String
    ) async -> Bool {
        guard let client else { return false }
        do {
            let existing = try await rawSongRows(sheetId: sheetId)
            let layout = SongLayout(header: existing.first ?? [])
            let day = Calendar.current.startOfDay(for: service.date)
            // Appended after whatever is already planned, not over it.
            let next = (songs[day]?.map(\.order).max() ?? 0) + 1

            try await client.append(
                sheetId: sheetId,
                tab: TeamSheet.songsTab,
                row: layout.row(
                    date: TeamSheet.dateFormatter.string(from: service.date),
                    order: String(next),
                    title: title,
                    url: YouTubeID.watchURL(videoId)?.absoluteString ?? "",
                    key: key ?? "",
                    transpose: "",
                    notes: "",
                    existing: nil
                )
            )
            songs[day, default: []].append(
                TeamSong(order: next, title: title,
                         url: YouTubeID.watchURL(videoId),
                         key: key, transpose: 0, notes: nil)
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// The Songs tab exactly as it stands, so a push knows which rows to
    /// rewrite rather than guessing from the parsed view.
    func rawSongRows(sheetId: String) async throws -> [[String]] {
        guard let client else { throw SheetsClient.SheetsError.noSheet }
        return try await client.read(sheetId: sheetId, range: TeamSheet.songsTab)
    }

    // MARK: - Parsing

    static func parseRoles(_ rows: [[String]]) -> [TeamRole] {
        rows.dropFirst().compactMap { row in
            guard row.count > TeamSheet.Roles.name else { return nil }
            let name = row[TeamSheet.Roles.name].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let active = row.count > TeamSheet.Roles.active
                ? row[TeamSheet.Roles.active].lowercased() : "true"
            guard !["false", "no", "n", "0"].contains(active) else { return nil }
            let order = row.count > TeamSheet.Roles.order
                ? Double(row[TeamSheet.Roles.order]) ?? 0 : 0
            return TeamRole(name: name, order: order)
        }
        .sorted {
            // Core parts first, then the sheet's own order within each group.
            ($0.isCore ? 0 : 1, $0.order, $0.name)
                < ($1.isCore ? 0 : 1, $1.order, $1.name)
        }
    }

    /// Columns are found by their header, not by position.
    ///
    /// A real planner does not have the columns in the order this app
    /// imagined. The team's existing one runs 구분 | Date | Time | Location |
    /// NOTE | 찬양 lead | 반주자 | 찬양 2…, which fixed indices would have
    /// read as gibberish. Anything not recognised as one of the known
    /// columns is a role, which is also how a team adds a part.
    /// Where each role column sits on the Schedule tab, by the header's own
    /// spelling. The same reserved-column reasoning as parseSchedule, kept
    /// beside it so the two cannot disagree about what is a role.
    static func scheduleRoleColumns(_ rows: [[String]]) -> [String: Int] {
        guard let header = rows.first else { return [:] }
        let reserved = Set(reservedScheduleColumns(header))
        var result: [String: Int] = [:]
        for (index, raw) in header.enumerated() where !reserved.contains(index) {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, result[name] == nil { result[name] = index }
        }
        return result
    }

    static func schedulePlaylistColumn(_ rows: [[String]]) -> Int? {
        guard let header = rows.first else { return nil }
        return TeamSheet.column(header, TeamSheet.playlistColumnNames)
    }

    private static func reservedScheduleColumns(_ header: [String]) -> [Int] {
        func column(_ names: [String]) -> Int? {
            header.firstIndex {
                names.contains($0.trimmingCharacters(in: .whitespaces).lowercased())
            }
        }
        return [
            column(["date", "날짜"]) ?? TeamSheet.Schedule.date,
            column(["title", "service", "구분", "type", "예배", "행사", "예배명"]),
            column(["time", "시간"]),
            column(["location", "장소"]),
            column(["note", "notes", "비고", "메모"]),
            // Not a part. Without this the column became a role called
            // Playlist, and the roster grew a phantom member holding a URL.
            column(TeamSheet.playlistColumnNames)
        ].compactMap { $0 }
    }

    static func parseSchedule(_ rows: [[String]], roles: [TeamRole]) -> [TeamService] {
        guard let header = rows.first else { return [] }

        func column(_ names: [String]) -> Int? {
            header.firstIndex {
                let key = $0.trimmingCharacters(in: .whitespaces).lowercased()
                return names.contains(key)
            }
        }
        let dateCol = column(["date", "날짜"]) ?? TeamSheet.Schedule.date
        // "Service" is what a planner calls this column at least as often
        // as "Title". Missing it meant the column was treated as a part, so
        // the roster grew a phantom named Service.
        let titleCol = column(["title", "service", "구분", "type", "예배", "행사", "예배명"])
        let timeCol = column(["time", "시간"])
        let locationCol = column(["location", "장소"])
        let notesCol = column(["note", "notes", "비고", "메모"])
        let playlistCol = column(TeamSheet.playlistColumnNames)

        let reserved = Set(
            [dateCol, titleCol, timeCol, locationCol, notesCol, playlistCol]
                .compactMap { $0 })
        let roleColumns = header.enumerated()
            .filter { !reserved.contains($0.offset) }
            .map { ($0.offset, $0.element.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.1.isEmpty }

        return rows.dropFirst().enumerated().compactMap { offset, row -> TeamService? in
            guard row.count > dateCol, let date = TeamSheet.day(row[dateCol]) else { return nil }

            func cell(_ index: Int?) -> String? {
                guard let index, row.count > index else { return nil }
                let value = row[index].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }

            var assignments: [String: String] = [:]
            for (index, name) in roleColumns where row.count > index {
                let who = row[index].trimmingCharacters(in: .whitespaces)
                if !who.isEmpty { assignments[name] = who }
            }

            return TeamService(
                date: date,
                title: cell(titleCol) ?? "주일예배",
                time: cell(timeCol),
                location: cell(locationCol),
                notes: cell(notesCol),
                assignments: assignments,
                // A pasted Sheets URL reduces to its id, the same way the
                // team sheet's own address does — a leader pasting the whole
                // link is the normal case, not a mistake.
                playlistId: cell(playlistCol).flatMap(YouTubePlaylistID.from),
                // +2: one for the header, one because sheets count from 1.
                row: offset + 2
            )
        }
        .sorted { $0.date < $1.date }
    }

    static func parseSongs(_ rows: [[String]]) -> [Date: [TeamSong]] {
        guard let header = rows.first else { return [:] }
        let dateCol = TeamSheet.column(header, ["date", "날짜"]) ?? 0
        let orderCol = TeamSheet.column(header, ["order", "순서", "#"])
        let titleCol = TeamSheet.column(header, ["title", "곡", "곡명", "찬양"]) ?? 2
        let urlCol = TeamSheet.column(header, ["youtubeurl", "url", "link", "링크", "영상"])
        let keyCol = TeamSheet.column(header, ["key", "키", "원키"])
        let transposeCol = TeamSheet.column(header, ["transpose", "연주키", "조옮김"])
        let notesCol = TeamSheet.column(header, ["notes", "note", "비고", "메모"])

        var out: [Date: [TeamSong]] = [:]
        for (offset, row) in rows.enumerated() where offset > 0 {
            guard row.count > dateCol, let date = TeamSheet.day(row[dateCol]) else { continue }
            func cell(_ i: Int?) -> String? {
                guard let i, row.count > i else { return nil }
                let v = row[i].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            guard let title = cell(titleCol) else { continue }

            // Transpose holds either a number of semitones or the key the
            // team actually plays in — "Ab" against an original of G. A key
            // written there is the more useful of the two, so it wins.
            let rawTranspose = cell(transposeCol)
            let semitones = rawTranspose.flatMap { Int($0) } ?? 0
            let playedKey = (rawTranspose.flatMap { Int($0) } == nil) ? rawTranspose : nil

            out[Calendar.current.startOfDay(for: date), default: []].append(
                TeamSong(
                    order: Int(cell(orderCol) ?? "") ?? (out[Calendar.current.startOfDay(for: date)]?.count ?? 0) + 1,
                    title: title,
                    url: cell(urlCol).flatMap(URL.init(string:)),
                    key: playedKey ?? cell(keyCol),
                    transpose: semitones,
                    notes: cell(notesCol),
                    // +1: the loop is over every row including the header,
                    // and sheets count from 1.
                    row: offset + 1
                )
            )
        }
        return out
    }

    // MARK: - Roster

    /// Everyone on the Members tab, with their row so a change rewrites.
    struct Member: Identifiable, Hashable {
        let email: String
        let name: String
        let isActive: Bool
        let row: Int
        /// From an optional Leader column on the Members tab. See
        /// `canAssign` for what happens when the sheet has no such column.
        var isLeader: Bool = false
        var id: String { email.lowercased() }
    }

    @Published private(set) var members: [Member] = []

    func addMember(email: String, name: String, sheetId: String) async {
        guard let client else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.isEmpty || address.contains("@") else {
            errorMessage = "이메일 주소가 아닙니다."
            return
        }
        guard address.isEmpty || !members.contains(where: {
            $0.email.lowercased() == address
        }) else {
            errorMessage = "이미 명단에 있습니다."
            return
        }
        do {
            let row = try await client.append(
                sheetId: sheetId, tab: TeamSheet.membersTab,
                row: [address, name, "TRUE"]
            )
            members.append(Member(email: address, name: name, isActive: true, row: row ?? 0))
            if !address.isEmpty { memberEmails.insert(address) }
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Deactivates rather than deletes.
    ///
    /// Removing the row would also remove the record that this person was
    /// ever on the team, and their signups would then point at nobody. A
    /// FALSE keeps the history and is reversible by the leader in one cell.
    func setMemberActive(_ active: Bool, member: Member, sheetId: String) async {
        guard let client, member.row >= 2 else { return }
        do {
            try await client.write(
                sheetId: sheetId,
                range: "\(TeamSheet.membersTab)!A\(member.row):C\(member.row)",
                row: [member.email, member.name, active ? "TRUE" : "FALSE"]
            )
            members = members.map {
                $0.id == member.id
                    ? Member(email: $0.email, name: $0.name, isActive: active, row: $0.row)
                    : $0
            }
            if active { memberEmails.insert(member.email.lowercased()) }
            else { memberEmails.remove(member.email.lowercased()) }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Live

    /// Reads only the Live tab — one request, so it can run on a short timer
    /// without costing what a full reload would.
    func pollLive(sheetId: String) async {
        guard let client,
              let rows = try? await client.read(sheetId: sheetId, range: TeamSheet.liveTab)
        else { return }

        guard let header = rows.first,
              let orderCol = TeamSheet.column(header, ["currentorder", "order", "현재순서"])
        else { return }
        let dateCol = TeamSheet.column(header, ["date", "날짜"]) ?? 0
        let byCol = TeamSheet.column(header, ["updatedby", "by", "진행"])

        var order: [Date: Int] = [:]
        var by: [Date: String] = [:]
        var at: [Date: Int] = [:]
        for (offset, row) in rows.enumerated() where offset > 0 {
            guard row.count > orderCol,
                  let date = TeamSheet.day(row[dateCol]),
                  let value = Int(row[orderCol].filter(\.isNumber))
            else { continue }
            let day = Calendar.current.startOfDay(for: date)
            order[day] = value
            at[day] = offset + 1
            if let byCol, row.count > byCol { by[day] = row[byCol] }
        }
        liveOrder = order
        liveUpdatedBy = by
        liveRows = at
    }

    /// Moves the service to an item, for everyone.
    func setLive(order: Int, service: TeamService, by name: String, sheetId: String) async {
        guard let client else { return }
        let day = Calendar.current.startOfDay(for: service.date)
        // Optimistic: the person tapping should not wait on a round trip to
        // see the thing they just did.
        liveOrder[day] = order
        liveUpdatedBy[day] = name

        let row = [
            TeamSheet.dateFormatter.string(from: service.date),
            String(order),
            ISO8601DateFormatter().string(from: Date()),
            name
        ]
        do {
            if let existing = liveRows[day], existing >= 2 {
                try await client.write(
                    sheetId: sheetId,
                    range: "\(TeamSheet.liveTab)!A\(existing):D\(existing)",
                    row: row
                )
            } else {
                liveRows[day] = try await client.append(
                    sheetId: sheetId, tab: TeamSheet.liveTab, row: row
                )
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    static func parsePlan(_ rows: [[String]]) -> [Date: [PlanItem]] {
        guard let header = rows.first else { return [:] }
        // A Plan tab is often made by duplicating Schedule and then editing
        // it, so insist on its own columns rather than reading a Schedule
        // as a garbled order of service.
        guard let typeCol = TeamSheet.column(header, ["type", "구분", "순서종류"]),
              let titleCol = TeamSheet.column(header, ["title", "내용", "순서"])
        else { return [:] }

        let dateCol = TeamSheet.column(header, ["date", "날짜"]) ?? 0
        let orderCol = TeamSheet.column(header, ["order", "#"])
        let minutesCol = TeamSheet.column(header, ["minutes", "분", "길이"])
        let personCol = TeamSheet.column(header, ["person", "담당", "맡은이"])
        let keyCol = TeamSheet.column(header, ["key", "키"])
        let urlCol = TeamSheet.column(header, ["youtubeurl", "url", "링크"])
        let notesCol = TeamSheet.column(header, ["notes", "note", "비고", "메모"])

        var out: [Date: [PlanItem]] = [:]
        for (offset, row) in rows.enumerated() where offset > 0 {
            guard row.count > dateCol, let date = TeamSheet.day(row[dateCol]) else { continue }
            func cell(_ i: Int?) -> String? {
                guard let i, row.count > i else { return nil }
                let v = row[i].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            guard let title = cell(titleCol) else { continue }
            let day = Calendar.current.startOfDay(for: date)
            out[day, default: []].append(
                PlanItem(
                    order: Int(cell(orderCol) ?? "") ?? (out[day]?.count ?? 0) + 1,
                    kind: PlanItem.Kind(raw: cell(typeCol) ?? ""),
                    title: title,
                    minutes: cell(minutesCol).flatMap { Int($0.filter(\.isNumber)) },
                    person: cell(personCol),
                    key: cell(keyCol),
                    url: cell(urlCol).flatMap(URL.init(string:)),
                    notes: cell(notesCol),
                    row: offset + 1
                )
            )
        }
        return out
    }

    /// Column letters for the Signups tab, in the order that tab actually
    /// has them.
    ///
    /// Writes were the last place still counting columns. The row was built
    /// as Date, Role, Email, Name, Status, UpdatedAt and pushed at A:F — so
    /// a tab with its columns in any other order would have been filled with
    /// the right values in the wrong cells, which is worse than failing.
    struct SignupLayout {
        var date = 0, role = 1, email = 2, name = 3, status = 4, updatedAt = 5
        var width = 6

        init(header: [String]) {
            guard !header.isEmpty else { return }
            width = max(header.count, 6)
            date = TeamSheet.column(header, ["date", "날짜"]) ?? 0
            role = TeamSheet.column(header, ["role", "파트", "역할"]) ?? 1
            email = TeamSheet.column(header, ["memberemail", "email", "이메일"]) ?? 2
            name = TeamSheet.column(header, ["membername", "name", "이름"]) ?? 3
            status = TeamSheet.column(header, ["status", "상태", "응답"]) ?? 4
            updatedAt = TeamSheet.column(header, ["updatedat", "updated", "시각"]) ?? 5
        }

        /// A row laid out for this tab, padded so every column is addressed.
        func row(date: String, role: String, email: String,
                 name: String, status: String, updatedAt: String) -> [String] {
            var cells = [String](repeating: "", count: width)
            func put(_ index: Int, _ value: String) {
                if cells.indices.contains(index) { cells[index] = value }
            }
            put(self.date, date); put(self.role, role); put(self.email, email)
            put(self.name, name); put(self.status, status); put(self.updatedAt, updatedAt)
            return cells
        }

        /// "A" … "Z", for the write range.
        var lastColumnLetter: String {
            String(UnicodeScalar(UInt8(65 + min(max(width - 1, 0), 25))))
        }
    }

    private(set) var signupLayout = SignupLayout(header: [])

    /// The Songs tab's own column order, for the same reason.
    struct SongLayout {
        var date = 0, order = 1, title = 2, url = 3, key = 4, transpose = 5, notes = 6
        var width = 7

        init(header: [String]) {
            guard !header.isEmpty else { return }
            width = max(header.count, 7)
            date = TeamSheet.column(header, ["date", "날짜"]) ?? 0
            order = TeamSheet.column(header, ["order", "순서", "#"]) ?? 1
            title = TeamSheet.column(header, ["title", "곡", "곡명", "찬양"]) ?? 2
            url = TeamSheet.column(header, ["youtubeurl", "url", "link", "링크", "영상"]) ?? 3
            key = TeamSheet.column(header, ["key", "키", "원키"]) ?? 4
            transpose = TeamSheet.column(header, ["transpose", "연주키", "조옮김"]) ?? 5
            notes = TeamSheet.column(header, ["notes", "note", "비고", "메모"]) ?? 6
        }

        func row(date: String, order: String, title: String, url: String,
                 key: String, transpose: String, notes: String,
                 existing: [String]?) -> [String] {
            var cells = existing ?? [String](repeating: "", count: width)
            while cells.count < width { cells.append("") }
            func put(_ index: Int, _ value: String) {
                if cells.indices.contains(index) { cells[index] = value }
            }
            put(self.date, date); put(self.order, order); put(self.title, title)
            put(self.url, url); put(self.key, key)
            put(self.transpose, transpose); put(self.notes, notes)
            return cells
        }

        var lastColumnLetter: String {
            String(UnicodeScalar(UInt8(65 + min(max(width - 1, 0), 25))))
        }
    }

    static func parseSignups(_ rows: [[String]]) -> [Date: [TeamSignup]] {
        guard let header = rows.first else { return [:] }
        let layout = SignupLayout(header: header)

        var out: [Date: [TeamSignup]] = [:]
        for (offset, row) in rows.enumerated() where offset > 0 {
            guard row.count > layout.email,
                  let date = TeamSheet.day(row[layout.date]) else { continue }
            func cell(_ i: Int) -> String { row.count > i ? row[i] : "" }
            out[Calendar.current.startOfDay(for: date), default: []].append(
                TeamSignup(
                    role: cell(layout.role),
                    email: cell(layout.email),
                    name: cell(layout.name),
                    statusRaw: cell(layout.status).isEmpty ? "available" : cell(layout.status),
                    row: offset + 1
                )
            )
        }
        return out
    }
}
