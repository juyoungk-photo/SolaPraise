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
import CryptoKit
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
    /// The contents' fingerprint, for telling the same file uploaded twice.
    var hash: String? = nil
    /// When it was put up — to tell a song's chart attached after the
    /// 콘티 from one made before it.
    var addedAt: Date? = nil
    /// Marked on the Attachments tab's 콘티 column: the version of its song
    /// the team chose to play from — one shared choice, seen on the sheet.
    var chosenForConti = false

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
    /// The channel of the video it came from, when known: it tells the
    /// team from the song in the video's title (PlanSongTitle).
    var channel: String? = nil
    /// What the Order cell said when it was not a number (「헌금찬양」).
    var orderLabel: String? = nil
    /// A title chosen or typed when the song came in (SongTitleReviewSheet)
    /// — written in place of the one read out of the video's title.
    var chosenTitle: String? = nil
    /// A song already on the sheet, kept in a merge: its row as it was,
    /// every column — written back whole, with only its date and order set,
    /// so moving it loses nothing the app does not own (참고버전, notes,
    /// a team's own columns).
    var sheetRow: [String]? = nil
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

    var order: Int
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
    /// What the Order cell said when it was not a number — the team writes
    /// 「헌금찬양」 there.
    var orderLabel: String? = nil

    var id: String { "\(order)-\(title)" }
    var videoId: String? { url.flatMap { YouTubeID.parse($0.absoluteString) } }
    /// The offering song, and who prays, as its notes or Order cell say.
    var offering: OfferingNote.Parsed { OfferingNote.parse(notes: notes, orderLabel: orderLabel) }
}

/// What a member said about one service.
///
/// 자리비움 is deliberately separate from 어려움. "I cannot do this Sunday"
/// and "I am away for a month" need different responses from a leader, and
/// collapsing them into one word loses the distinction that decides whether
/// to ask again next week.
enum SignupStatus: String {
    case available, maybe, declined, away

    /// Read through TeamSheet.statusWords, the list the sheet audit also
    /// uses. An unknown word stays 가능, as before — and is now reported.
    init(raw: String) {
        self = TeamSheet.signupStatus(raw).flatMap(SignupStatus.init(rawValue:)) ?? .available
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
    /// Songs-tab rows whose cells were written too far right — see
    /// shiftedRows. Shown as a warning with a repair, never fixed silently.
    @Published private(set) var damagedSongRows: [TeamSheet.ShiftedRow] = []
    /// The same song entered more than once on a service — see
    /// TeamSheet.duplicateSongRows. Shown with a tidy-up, never fixed silently.
    @Published private(set) var duplicateSongs = TeamSheet.DuplicateSongs(rows: [], renumber: [])

    // The tabs exactly as last read, for 워크플로 점검. Kept rather than
    // re-read: the audit should judge what the screen is showing.
    @Published private(set) var rawSchedule: [[String]]?
    @Published private(set) var rawSongs: [[String]]?
    @Published private(set) var rawSignups: [[String]]?
    /// The 응답 tab, when the sheet has one (AvailabilityGrid). Then answers
    /// are read from and written to it, and Signups is history.
    @Published private(set) var usesGrid = false
    /// The 곡 메모 tab's memos (SongMemos), when the sheet has the tab.
    @Published private(set) var songMemos: [SongMemos.Memo] = []
    /// The 곡 메모 tab as read, for its 지난 예배 column.
    @Published private(set) var rawSongMemos: [[String]] = []
    @Published private(set) var rawGrid: [[String]]?
    @Published private(set) var rawMembers: [[String]]?
    @Published private(set) var rawPlan: [[String]]?

    /// The one place a fresh read of the Songs tab is taken in.
    ///
    /// It used to be done inline in five places, each re-deriving some of
    /// songs, shifted rows and duplicates — and one of them, the reorder,
    /// only the songs, so a warning could outlive the problem it described.
    private func adoptSongRows(_ rows: [[String]]) {
        rawSongs = rows
        songs = Self.parseSongs(rows)
        damagedSongRows = TeamSheet.shiftedRows(in: rows)
        duplicateSongs = TeamSheet.duplicateSongRows(in: rows)
    }

    /// 워크플로 점검 over what was last loaded. See SheetAudit.
    func audit(accounts: SheetAudit.Accounts) -> [SheetAudit.Finding] {
        // Nothing loaded yet is not a broken sheet.
        guard lastLoaded != nil else { return [] }
        var accounts = accounts
        accounts.churchSheetProblem = churchSheetProblem
        #if DEBUG
        // The sample team's member stands in for a real sign-in.
        if isSample {
            accounts.churchEmail = sampleActingEmail
            accounts.mainEmail = accounts.mainEmail ?? "youtube@example.com"
            accounts.mainHasYouTube = true
        }
        #endif
        // On a sheet answered on the 응답 tab, Signups is history: checked
        // as live, its old duplicates counted against a sheet with none.
        return SheetAudit.run(SheetAudit.Input(
            schedule: rawSchedule, songs: rawSongs, signups: usesGrid ? nil : rawSignups,
            members: rawMembers, plan: rawPlan, grid: rawGrid, accounts: accounts))
    }

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
                       churchNotes: [Date: ChurchNote] = [:],
                       attachments: [Date: [Attachment]] = [:]) {
        isSample = true
        usesGrid = DebugHarness.sampleGrid
        sampleActingEmail = members.sorted().first
        self.services = services
        self.roles = roles
        self.signups = signups
        self.plans = plans
        self.memberEmails = members
        self.members = roster
        self.churchNotes = churchNotes
        self.attachments = attachments
        // A minimal sheet behind the sample, so 워크플로 점검 has tabs to
        // read — and, with -uiTestDuplicates, a real repeated song in them.
        let day = TeamSheet.dateFormatter.string(from: services.first { !$0.isPast }?.date ?? Date())
        var songRows: [[String]] = [["Date", "Order", "Title", "YouTubeURL"],
                                    [day, "1", "Sample", "https://youtu.be/AAAAAAAAAAA"],
                                    // Entered under a video's whole title, for 곡 제목 정리.
                                    [day, "2", "새 노래 | NEW SONG | 어느 워십", "https://youtu.be/BBBBBBBBBBB"]]
        if DebugHarness.seedDuplicates {
            songRows += [[day, "2", "Sample", "https://youtu.be/AAAAAAAAAAA"],
                         [day, "3", "Sample", "https://youtu.be/AAAAAAAAAAA"]]
        }
        adoptSongRows(songRows)
        rawSchedule = [["Date", "Service"], [day, "주일 2부예배"]]
        rawSignups = [["Date", "Role", "MemberEmail", "MemberName", "Status"]]
        rawMembers = [["Name", "Email"]] + members.sorted().map { ["", $0] }
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
        driveAccount = planning.email
        TeamStore.current = self
        lastActingEmail = actingEmail(auth: auth, planning: planning)
    }

    /// Whose Drive `drive` writes to: whose corrections files are whose.
    private var driveAccount: String?

    /// The app's one store, for code with no view to be handed it — a 콘티
    /// file's page map read while splitting it (ContiPages).
    static weak var current: TeamStore?

    /// Who writes, as of the last configure — for rows written outside a
    /// view that knows the accounts.
    private(set) var lastActingEmail: String?

    // MARK: - Rows that may have moved

    static let sheetMovedMessage =
        "시트가 그 사이에 바뀌어(정렬·줄 이동 등) 쓰지 않았습니다. 새로 불러왔으니 다시 시도해 주세요."

    /// Whether a remembered row still holds these values. When it does not,
    /// the sheet is reloaded so the next attempt uses fresh row numbers.
    private func confirm(_ tab: String, row: Int, holds expected: [String],
                         sheetId: String, client: SheetsClient) async -> Bool {
        guard let cells = try? await client.row(sheetId: sheetId, tab: tab, number: row) else { return false }
        if TeamSheet.row(cells, holds: expected) { return true }
        await load(sheetId: sheetId)
        return false
    }

    private func dateText(_ service: TeamService) -> String {
        TeamSheet.dateFormatter.string(from: service.date)
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
    // MARK: - 헌금송

    /// Marks a song of the 순서 as the offering song, with who prays — or
    /// unmarks it — in its Notes cell on the Songs tab, keeping the rest of
    /// what the notes say (OfferingNote). Returns an error message, or nil.
    func setOffering(_ item: PlanItem, in service: TeamService, isOffering: Bool,
                     prayer: String?, sheetId: String) async -> String? {
        beginWrite()
        defer { endWrite() }
        let notes = OfferingNote.notes(isOffering: isOffering, prayer: prayer, rest: item.offering.rest)
        #if DEBUG
        if isSample {
            let day = Calendar.current.startOfDay(for: service.date)
            if let index = plans[day]?.firstIndex(where: { $0.id == item.id }), let old = plans[day]?[index] {
                plans[day]?[index] = PlanItem(order: old.order, kind: old.kind, title: old.title, minutes: old.minutes,
                                              person: old.person, key: old.key, url: old.url, notes: notes, row: old.row,
                                              orderLabel: isOffering ? old.orderLabel : nil)
            }
            return nil
        }
        #endif
        // The 순서 read from a Plan tab is laid out by the team; only the
        // Songs tab is known well enough to write into.
        guard !hasPlanTab else { return "Plan 탭으로 순서를 쓰는 시트에서는 Plan 탭의 메모에 「헌금송 · 헌금기도: 이름」을 적어 주세요." }
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        guard let row = item.row, row >= 2 else { return "줄 번호를 알 수 없습니다." }
        do {
            let rows = try await rawSongRows(sheetId: sheetId)
            guard let header = rows.first,
                  let notesColumn = TeamSheet.column(header, ["notes", "note", "비고", "메모"]) else {
                return "Songs 탭에 Notes(비고) 열이 없어 적지 못했습니다."
            }
            guard await confirm(TeamSheet.songsTab, row: row, holds: [item.title], sheetId: sheetId, client: client) else {
                return Self.sheetMovedMessage
            }
            func range(_ column: Int) -> String {
                let cell = "\(TeamSheet.columnLetter(column))\(row)"
                return "\(TeamSheet.songsTab)!\(cell):\(cell)"
            }
            var updates: [(range: String, rows: [[String]])] = [(range(notesColumn), [[notes ?? ""]])]
            // Unmarked: an Order cell that said 헌금찬양 says its place again.
            if !isOffering, item.orderLabel != nil,
               let orderColumn = TeamSheet.column(header, ["order", "순서", "#"]) {
                updates.append((range(orderColumn), [[String(item.order)]]))
            }
            try await client.batchWrite(sheetId: sheetId, updates: updates)
            await load(sheetId: sheetId)
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 적지 못했습니다."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - What the team said about a song before
    //
    // PRINCIPLE: whatever a person tells the app about a song — its title,
    // its key, its charts — is found again the next time the song comes
    // round, from whichever door it comes in by. These are the lookups;
    // the playlist fill, 콘티에 추가 and a service's 악보 use them.

    /// A song's 순서 entries on services before `day`, most recent first —
    /// by its video, else by its title.
    private func earlierEntries(videoId: String?, title: String, before day: Date) -> [(TeamService, PlanItem)] {
        let start = Calendar.current.startOfDay(for: day)
        var out: [(TeamService, PlanItem)] = []
        for service in services.filter({ $0.date < start }).sorted(by: { $0.date > $1.date }) {
            if let item = plan(for: service).first(where: { song in
                song.kind == .song && ((videoId != nil && song.videoId == videoId) || PlanSongTitle.sameSong(song.title, title))
            }) {
                out.append((service, item))
            }
        }
        return out
    }

    /// The key the team last played a song in, from its most recent earlier
    /// 순서 that gave one. A song coming round again came in keyless.
    func lastKey(videoId: String?, title: String, before day: Date) -> String? {
        earlierEntries(videoId: videoId, title: title, before: day)
            .lazy.compactMap { $0.1.key?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// The song's title as the team last wrote it for this video, as the
    /// Songs tab carries it. A title fixed by hand once is the title.
    func sheetTitle(forVideo id: String) -> String? {
        sheetTitles(only: id)[id]
    }

    /// Every video's title on the sheet, from the service nearest today
    /// that has it — read in one pass, for a list of songs at once.
    func sheetTitles(only id: String? = nil) -> [String: String] {
        let today = Calendar.current.startOfDay(for: Date())
        var titles: [String: String] = [:]
        var settled = Set<String>()
        for service in services.sorted(by: { abs($0.date.timeIntervalSince(today)) < abs($1.date.timeIntervalSince(today)) }) {
            for item in plan(for: service) where item.kind == .song {
                guard let video = item.videoId, id == nil || video == id, settled.insert(video).inserted else { continue }
                let title = PlanSongTitle.forSheet(item.title).title
                if !title.isEmpty { titles[video] = title }
            }
            if let id, settled.contains(id) { break }
        }
        return titles
    }

    /// The charts the team attached to a song on the most recent earlier
    /// service that had any, newest first: the chart it last played from.
    func earlierCharts(videoId: String?, title: String, before day: Date) -> [Attachment] {
        let start = Calendar.current.startOfDay(for: day)
        let songs = Set([title] + earlierEntries(videoId: videoId, title: title, before: day).map(\.1.title))
        let charts = attachments.filter { $0.key < start }.values.joined().filter { chart in
            !chart.belongsToService && ScoreArchive.isScore(chart.name)
                && songs.contains { PlanSongTitle.sameSong($0, chart.song) }
        }
        guard let last = charts.map(\.date).max() else { return [] }
        return charts.filter { Calendar.current.isDate($0.date, inSameDayAs: last) }
            .sorted { ($0.addedAt ?? $0.date) > ($1.addedAt ?? $1.date) }
    }

    /// The song a video is, as the team's 순서 names it — the nearest
    /// service that has it, its title without the hymn number's suffix.
    /// What a person tidied or chose on the sheet beats a fresh reading of
    /// the video's title, and it is the same on every teammate's device.
    func songTitle(forVideo id: String) -> String? {
        let today = Calendar.current.startOfDay(for: Date())
        let nearest = services.sorted { abs($0.date.timeIntervalSince(today)) < abs($1.date.timeIntervalSince(today)) }
        for service in nearest {
            if let item = plan(for: service).first(where: { $0.kind == .song && $0.videoId == id }) {
                let title = PlanSongTitle.split(item.title).title
                return title.isEmpty ? nil : title
            }
        }
        return nil
    }

    func plan(for service: TeamService) -> [PlanItem] {
        let day = Calendar.current.startOfDay(for: service.date)
        if let items = plans[day], !items.isEmpty {
            return items.sorted { $0.order < $1.order }
        }
        return songs(for: service).map {
            PlanItem(order: $0.order, kind: .song, title: $0.title,
                     minutes: nil, person: nil, key: $0.key, url: $0.url,
                     notes: $0.notes, row: $0.row, orderLabel: $0.orderLabel)
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
            .first { (usesGrid || $0.role == role) && $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    // MARK: - Loading

    /// One load at a time: a call made while one runs waits for it.
    ///
    /// WHY: at launch the root and 예배 준비 both saw no services yet and
    /// both loaded — every tab read twice, side by side, each publishing
    /// as it went, the screen redrawn for both.
    func load(sheetId: String) async {
        if let running = loading, running.sheetId == sheetId {
            await running.task.value
            return
        }
        let id = UUID()
        let task = Task { await performLoad(sheetId: sheetId) }
        loading = (id, sheetId, task)
        await task.value
        if loading?.id == id { loading = nil }
    }
    private var loading: (id: UUID, sheetId: String, task: Task<Void, Never>)?

    private func performLoad(sheetId: String) async {
        guard let client else { return }
        lastSheetId = sheetId
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let generation = editGeneration

        do {
            // Every tab at once. They were read one after another — ten
            // round trips end to end on each pull to refresh — and each
            // was put on screen as it came, so the screen was redrawn ten
            // times with half a sheet. Each tab still fails on its own: the
            // four the app cannot do without throw, the rest are optional.
            // Every tab through readTable: its header is found by name
            // wherever it sits, not assumed to be row 1.
            async let scheduleRows = client.readTable(sheetId: sheetId, tab: TeamSheet.scheduleTab)
            async let roleRows     = client.readTable(sheetId: sheetId, tab: TeamSheet.rolesTab)
            async let songRows     = client.readTable(sheetId: sheetId, tab: TeamSheet.songsTab)
            async let signupRows   = client.readTable(sheetId: sheetId, tab: TeamSheet.signupsTab)
            // Optional tab: absent on a sheet made before the order of
            // service existed, which must keep working.
            async let planRows     = try? client.readTable(sheetId: sheetId, tab: TeamSheet.planTab)
            async let memberRows   = try? client.readTable(sheetId: sheetId, tab: TeamSheet.membersTab)
            async let gridRows     = try? client.read(sheetId: sheetId, range: AvailabilityGrid.tab)
            async let memoRows     = try? client.read(sheetId: sheetId, range: SongMemos.quotedTab)
            async let titles       = try? client.tabTitles(sheetId: sheetId)
            async let attachmentRows = try? client.readTable(sheetId: sheetId, tab: TeamSheet.attachmentsTab)
            async let church       = fetchChurchNotes(client: client)

            let (schedule, roleData, songData, signupData) =
                try await (scheduleRows, roleRows, songRows, signupRows)
            let (planRead, memberRead, gridRead, memoRead, titleRead, attachmentRead, churchRead) =
                await (planRows, memberRows, gridRows, memoRows, titles, attachmentRows, church)

            // Read while an answer, an assignment or a removal was being
            // written: this is the sheet from before it, and putting it on
            // screen would take back what the person just did. The last
            // write to finish reads again (endWrite).
            if writesInFlight > 0 || editGeneration != generation {
                reloadWhenSettled = true
                return
            }

            // All at once: one redraw, never half a sheet.
            let planData = planRead ?? []
            plans = Self.parsePlan(planData)
            roles = Self.parseRoles(roleData)
            services = Self.parseSchedule(schedule, roles: roles)
            roleColumns = Self.scheduleRoleColumns(schedule)
            playlistColumn = Self.schedulePlaylistColumn(schedule)
            adoptSongRows(songData)
            rawSchedule = schedule
            rawSignups = signupData
            rawPlan = planData
            signups = Self.parseSignups(signupData)
            signupLayout = SignupLayout(header: signupData.first ?? [])
            memberEmails = applyMembers(memberRead)
            // After the roster: a grid column is a member by name.
            applyGrid(gridRead ?? [])
            rawSongMemos = memoRead ?? []
            songMemos = SongMemos.parse(rawSongMemos)
            hasWeekTab = titleRead?.contains(WeekTab.tab) ?? false
            hasCorrectionsTab = titleRead?.contains(CorrectionsTab.tab) ?? false
            churchNotes = churchRead.notes
            churchSheetProblem = churchRead.problem
            applyAttachments(attachmentRead)
            lastLoaded = Date()
            needsAuthorization = false
        } catch SheetsClient.SheetsError.http(403, let message) {
            needsAuthorization = true
            errorMessage = message ?? "시트를 읽을 권한이 없습니다."
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        // Drive, not the sheet: after, so the sheet is on screen first.
        await loadContiFolder()
    }

    // MARK: - Writes under way

    /// Writes to the sheet now running, and how many have finished: a
    /// load compares them to know whether what it read is already old.
    private var writesInFlight = 0
    private var editGeneration = 0
    /// A load read while a write ran and put nothing on screen.
    private var reloadWhenSettled = false
    private var lastSheetId: String?

    /// Around every write that changes the screen first (an answer, an
    /// assignment, a removal …): a load that reads meanwhile reads the
    /// sheet from before it, and must not paint over it.
    private func beginWrite() { writesInFlight += 1 }

    private func endWrite() {
        writesInFlight -= 1
        editGeneration += 1
        guard writesInFlight == 0, reloadWhenSettled, let sheetId = lastSheetId else { return }
        reloadWhenSettled = false
        Task { await self.load(sheetId: sheetId) }
    }

    /// The church sheet's two columns, if there is a church sheet.
    ///
    /// Never throws outward and never sets `errorMessage`. This is a
    /// different document, owned by someone else, and the team's own planner
    /// has to keep working when it is missing, renamed, unshared or simply
    /// not configured — a 403 here is not the team's problem to see.
    private func fetchChurchNotes(client: SheetsClient) async -> (notes: [Date: ChurchNote], problem: String?) {
        guard let id = ChurchSheetSource.current,
              let range = ChurchSheet.encodedRange else { return ([:], nil) }
        do {
            let rows = try await client.readEncoded(sheetId: id, encodedRange: range)
            return (ChurchSheet.notes(from: rows), nil)
        } catch {
            // Said, not swallowed. 설교제목 and 헌신찬양 simply vanishing is
            // indistinguishable from the office not having filled them in,
            // and the usual cause — reading with an account the church
            // sheet is not shared with — has a one-tap fix.
            if case SheetsClient.SheetsError.http(let code, _) = error, code == 403 || code == 404 {
                return ([:], "교회 정보 시트를 이 계정으로 열 수 없습니다. 위의 「계정 변경」에서 교회 계정을 연결하세요.")
            }
            return ([:], "교회 정보 시트를 불러오지 못했습니다.")
        }
    }

    /// Why the church sheet's 설교제목 and 헌신찬양 are missing, when they
    /// are missing because of a failure rather than an empty week.
    @Published private(set) var churchSheetProblem: String?

    /// What the church sheet says about a service, if anything.
    func churchNote(for service: TeamService) -> ChurchNote? {
        churchNotes[Calendar.current.startOfDay(for: service.date)]
    }

    /// The Members tab is optional. Without one, anyone who can open the
    /// sheet counts as a member — which is the same thing, since Google's own
    /// sharing is what actually protects it.
    private func applyMembers(_ read: [[String]]?) -> Set<String> {
        guard let rows = read, rows.count > 1 else { members = []; rawMembers = nil; return [] }
        rawMembers = rows

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
        // On the 응답 tab a member answers by name, address or not.
        let answeredNames = Set((signups[day] ?? []).map { $0.name.replacingOccurrences(of: " ", with: "") })
        // Somebody the leader has put on a part is already on the row, in
        // orange, saying exactly what they are down for. Listing them again
        // as 미응답 was the same person twice on one line — and it made a
        // service that had just been staffed look untouched.
        //
        // They have still not answered, and the orange hollow ring is what
        // says so. The 미응답 chips are for the people the row would
        // otherwise not mention at all.
        // Each person in a cell: a part can hold several, 「지혜, 민수」.
        let assigned = service.assignments.values
            .flatMap(TeamSheet.names(inCell:))
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
            .filter { !answeredNames.contains($0.name.replacingOccurrences(of: " ", with: "")) }
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
            // By name when there is no address: on the 응답 tab a member
            // without one answers too, and they must not merge into one.
            seen[signup.email.isEmpty ? "name:" + signup.name : signup.email.lowercased()] = signup
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
        beginWrite()
        defer { endWrite() }
        #if DEBUG
        if isSample {
            if DebugHarness.slowSheet { try? await Task.sleep(for: .seconds(1)) }
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
        if usesGrid {
            await setGridAvailability(status, service: service, email: email, name: name,
                                      sheetId: sheetId, client: client)
            return
        }
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
            var existing = mySignup(for: service, role: role, email: email)
            // The remembered row must still be this answer; a sorted tab
            // would otherwise have this answer overwrite someone else's.
            if let target = existing?.row, target >= 2,
               !(await confirm(TeamSheet.signupsTab, row: target,
                               holds: [dateText(service), email, role], sheetId: sheetId, client: client)) {
                await load(sheetId: sheetId)
                existing = mySignup(for: service, role: role, email: email)
            }
            var writtenRow = existing?.row

            // The header is above every data row, so anything below 2 is not
            // a real row to rewrite — append and learn where it went.
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

    // MARK: - A new 콘티, put up

    /// Whether the last upload landed in the folder it was asked for.
    private var lastUploadWentToFolder = false

    /// A 콘티 made here, put up for the team: into the 콘티 folder when this
    /// account may write there, else the app's 악보 folder — either way on
    /// the Attachments tab as the service's file, so every app lists it as
    /// the newest 콘티 and the sheet links to it. A message for the person.
    func uploadConti(_ data: Data, name: String, service: TeamService, sheetId: String, by who: String) async -> String {
        if let failure = await attach(data: data, name: name, mimeType: "application/pdf", song: "",
                                      to: service, sheetId: sheetId, by: who, folder: ContiFolder.folderId) {
            return "팀에 올리지 못했습니다: \(failure)\n공유 창에서 직접 저장하세요."
        }
        await loadContiFolder()
        return lastUploadWentToFolder
            ? "「\(name)」을 콘티 폴더에 올렸습니다. 팀 시트 Attachments와 모든 앱에서 바로 보입니다."
            : "「\(name)」을 팀에 올렸습니다 — 팀 시트 Attachments와 모든 앱에서 보입니다. 이 계정은 콘티 폴더에 쓸 수 없어 그 폴더에는 들어가지 않았습니다."
    }

    // MARK: - Who is on what

    /// Services coming where a member is on a part, by the roster's name —
    /// each with a key that changes when the parts do, so a change is news.
    func assignments(of name: String) -> [(service: TeamService, parts: [String], key: String)] {
        services.filter { !$0.isPast }.sorted { $0.date < $1.date }.prefix(8).compactMap { service in
            let cells = service.assignments
                .sorted { (roleColumns[$0.key] ?? .max, $0.key) < (roleColumns[$1.key] ?? .max, $1.key) }
                .map { (part: $0.key, cell: $0.value) }
            let parts = RosterMessage.parts(of: name, in: cells, names: TeamSheet.names(inCell:))
            guard !parts.isEmpty else { return nil }
            return (service, parts, "\(service.id)|\(parts.joined(separator: ","))|\(name)")
        }
    }

    /// Whether a member has answered for a service — by address, or by name
    /// on the 응답 tab.
    func hasAnswered(_ service: TeamService, email: String, name: String) -> Bool {
        (signups[Calendar.current.startOfDay(for: service.date)] ?? []).contains {
            (!email.isEmpty && $0.email.caseInsensitiveCompare(email) == .orderedSame) || $0.name == name
        }
    }

    // MARK: - 이번 주 tab

    /// Whether the sheet has the 이번 주 tab, as of the last check.
    @Published private(set) var hasWeekTab = false

    /// Writes the 이번 주 tab (WeekTab): made the first time, its formulas
    /// written again after — the columns may have moved. Read back after,
    /// so a date the formulas cannot find is said rather than shown as an
    /// empty page. Run only from a button. Returns a message for the
    /// person, or nil when all is well.
    func prepareWeekTab(sheetId: String) async -> String? {
        #if DEBUG
        if isSample { return "샘플 모드에서는 시트를 바꾸지 않습니다." }
        #endif
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        let tab = WeekTab.tab, quoted = "'\(WeekTab.tab)'"
        do {
            let titles = try await client.tabTitles(sheetId: sheetId)
            let attachmentHeader = titles.contains(TeamSheet.attachmentsTab)
                ? (try? await client.readTable(sheetId: sheetId, tab: TeamSheet.attachmentsTab))?.first : nil
            guard let schedule = rawSchedule?.first, let songs = rawSongs?.first,
                  let cells = WeekTab.cells(.init(schedule: schedule, songs: songs, attachments: attachmentHeader,
                                                  memos: titles.contains(SongMemos.tab))) else {
                return "Schedule · Songs 탭에서 날짜 열을 찾지 못해 만들지 않았습니다."
            }
            let isNew = !titles.contains(tab)
            if isNew { try await client.addSheet(sheetId: sheetId, title: tab) }
            guard let gid = try await client.tabGid(sheetId: sheetId, title: tab) else { return "이번 주 탭을 만들지 못했습니다." }
            // Every cell of the area written, blanks too: a value left where
            // a formula spills would stop it with #REF!.
            let width = 8, height = max(cells.count + 45, 60)
            var grid = cells.map { row in row + [String](repeating: "", count: max(0, width - row.count)) }
            while grid.count < height { grid.append([String](repeating: "", count: width)) }
            try await client.batchWrite(sheetId: sheetId, updates: [("\(quoted)!A1:H\(height)", grid)])
            if isNew { try await client.formatUpdate(sheetId: sheetId, requests: WeekTab.formatRequests(gid: gid, rows: cells.count)) }
            hasWeekTab = true
            let shown = try await client.read(sheetId: sheetId, range: "\(quoted)!A1:C1").first ?? []
            let date = shown.count > 1 ? shown[1].trimmingCharacters(in: .whitespaces) : ""
            if date.isEmpty || date.hasPrefix("#") {
                return "「이번 주」 탭을 만들었지만 다음 예배 날짜를 찾지 못했습니다. Schedule의 날짜가 날짜가 아닌 글자로 적혀 있거나, 앞으로의 예배가 없을 수 있습니다."
            }
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 만들지 못했습니다."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - 곡 메모

    /// The team's memo for a song, however the 순서 spells it.
    func memo(for song: String) -> SongMemos.Memo? {
        SongMemos.memo(for: song, in: songMemos)
    }

    /// A song's memo written on the 곡 메모 tab — over its own row, or a new
    /// one; the tab made the first time. Blank clears it. Returns an error
    /// message, or nil.
    func setMemo(_ text: String, for song: String, by who: String, sheetId: String) async -> String? {
        beginWrite()
        defer { endWrite() }
        let title = PlanSongTitle.forSheet(song).title
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = TeamSheet.dateFormatter.string(from: Date())
        func remember(row: Int) {
            songMemos.removeAll { PlanSongTitle.sameSong($0.song, song) }
            if !words.isEmpty { songMemos.append(.init(song: title, text: words, by: who, row: row)) }
        }
        #if DEBUG
        if isSample { remember(row: 0); return nil }
        #endif
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        let tab = SongMemos.quotedTab
        do {
            try await ensureMemoTab(sheetId: sheetId, client: client)
            let rows = try await client.read(sheetId: sheetId, range: tab)
            guard let top = rows.first, let layout = SongMemos.Layout(header: top) else {
                return "곡 메모 탭의 첫 줄에 「곡 · 메모」 머리글이 없어 적지 못했습니다."
            }
            let existing = SongMemos.row(for: song, in: rows)
            // From the row as it is: columns the team added keep their words,
            // and the song stays as the team wrote it.
            var cells = existing.map { rows[$0 - 1] } ?? []
            while cells.count < max(top.count, 4) { cells.append("") }
            if existing == nil { cells[layout.song] = title }
            cells[layout.memo] = words
            if let by = layout.by { cells[by] = who }
            if let at = layout.at { cells[at] = stamp }
            let row: Int
            if let existing {
                row = existing
                let last = TeamSheet.columnLetter(cells.count - 1)
                try await client.write(sheetId: sheetId, range: "\(tab)!A\(row):\(last)\(row)", row: cells)
            } else {
                guard !words.isEmpty else { return nil }
                row = try await client.append(sheetId: sheetId, tab: tab, row: cells) ?? 0
            }
            remember(row: row)
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 메모를 적지 못했습니다."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func ensureMemoTab(sheetId: String, client: SheetsClient) async throws {
        guard !(try await client.tabTitles(sheetId: sheetId)).contains(SongMemos.tab) else { return }
        try await client.addSheet(sheetId: sheetId, title: SongMemos.tab)
        let last = TeamSheet.columnLetter(SongMemos.header.count - 1)
        try await client.write(sheetId: sheetId, range: "\(SongMemos.quotedTab)!A1:\(last)1", row: SongMemos.header)
    }

    // MARK: - 지난 예배

    /// A service's songs as recorded: the title, the key played, the notes.
    func sung(in service: TeamService) -> [SongMemos.Sung] {
        plan(for: service).filter { $0.kind == .song }
            .map { .init(title: $0.title, key: $0.key, notes: $0.notes) }
    }

    /// A song's 지난 예배 lines, newest first.
    func history(for song: String) -> [String] {
        SongMemos.history(for: song, in: rawSongMemos)
    }

    /// The service is on every one of its songs' 지난 예배 already.
    func isRecorded(_ service: TeamService) -> Bool {
        SongMemos.isRecorded(day: service.date, songs: sung(in: service), in: rawSongMemos)
    }

    /// What recording would write, as the tab stands — for the preview.
    func recordPreview(_ service: TeamService) -> [(song: String, line: String)] {
        sung(in: service).map { (PlanSongTitle.split($0.title).title, SongMemos.line(day: service.date, $0)) }
    }

    /// Writes the service onto each song's 지난 예배: one cell on the song's
    /// own row, a new row for a song the tab has not met, the heading when
    /// the tab has none. Nothing else is touched. Returns an error message,
    /// or nil.
    func record(_ service: TeamService, sheetId: String) async -> String? {
        beginWrite()
        defer { endWrite() }
        let songs = sung(in: service)
        guard !songs.isEmpty else { return nil }
        #if DEBUG
        if isSample {
            if rawSongMemos.isEmpty { rawSongMemos = [SongMemos.header] }
            if let plan = SongMemos.record(day: service.date, songs: songs, in: rawSongMemos) {
                apply(plan)
            }
            return nil
        }
        #endif
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        let tab = SongMemos.quotedTab
        do {
            try await ensureMemoTab(sheetId: sheetId, client: client)
            let rows = try await client.read(sheetId: sheetId, range: tab)
            guard let plan = SongMemos.record(day: service.date, songs: songs, in: rows) else {
                return "곡 메모 탭의 첫 줄에 「곡 · 메모」 머리글이 없어 적지 못했습니다."
            }
            let letter = TeamSheet.columnLetter(plan.column)
            var updates: [(range: String, rows: [[String]])] = []
            if plan.needsHeading { updates.append(("\(tab)!\(letter)1", [[SongMemos.historyHeader]])) }
            for cell in plan.cells { updates.append(("\(tab)!\(letter)\(cell.row)", [[Self.asText(cell.text)]])) }
            try await client.batchWrite(sheetId: sheetId, updates: updates)
            for row in plan.newRows {
                try await client.append(sheetId: sheetId, tab: SongMemos.tab, row: row.map(Self.asText))
            }
            rawSongMemos = try await client.read(sheetId: sheetId, range: tab)
            songMemos = SongMemos.parse(rawSongMemos)
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 기록하지 못했습니다."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A line that is only a date stays the words typed: written as
    /// USER_ENTERED, 「2026-10-18」 would become a date cell and read back
    /// in the sheet's own format.
    private static func asText(_ text: String) -> String {
        TeamSheet.day(text) != nil && !text.contains("\n") ? "'" + text : text
    }

    #if DEBUG
    private func apply(_ plan: SongMemos.Record) {
        while rawSongMemos[0].count <= plan.column { rawSongMemos[0].append("") }
        if plan.needsHeading { rawSongMemos[0][plan.column] = SongMemos.historyHeader }
        for cell in plan.cells where rawSongMemos.indices.contains(cell.row - 1) {
            while rawSongMemos[cell.row - 1].count <= plan.column { rawSongMemos[cell.row - 1].append("") }
            rawSongMemos[cell.row - 1][plan.column] = cell.text
        }
        rawSongMemos += plan.newRows
    }
    #endif

    // MARK: - The version a 콘티 takes

    static let contiColumnNames = ["콘티", "conti", "use"]

    /// The version of a song the team plays from, marked on the Attachments
    /// tab — ✓ on its row, cleared on the song's other charts that day — so
    /// it is one choice for the whole team, read on the sheet by anyone.
    /// A 콘티's pages chosen clears every mark: unmarked means the newest.
    /// Returns an error message, or nil.
    func chooseForConti(_ item: ScoreStandItem, service: TeamService, sheetId: String) async -> String? {
        beginWrite()
        defer { endWrite() }
        let day = Calendar.current.startOfDay(for: service.date)
        let songCharts = (attachments[day] ?? []).filter {
            !$0.belongsToService && PlanSongTitle.sameSong($0.song, item.song)
        }
        let chosenId = item.pages == nil && item.earlierDay == nil ? item.attachment.fileId : nil
        func apply() {
            for chart in songCharts {
                if let i = attachments[day]?.firstIndex(where: { $0.fileId == chart.fileId }) {
                    attachments[day]?[i].chosenForConti = chart.fileId == chosenId
                }
            }
        }
        // On screen first, then on the sheet; put back if the sheet says no.
        // `songCharts` keeps the marks as they were, which is also what the
        // writes below are worked out from.
        apply()
        func undo() {
            for chart in songCharts {
                if let i = attachments[day]?.firstIndex(where: { $0.fileId == chart.fileId }) {
                    attachments[day]?[i].chosenForConti = chart.chosenForConti
                }
            }
        }
        #if DEBUG
        if isSample { return nil }
        #endif
        guard let client else { undo(); return "시트에 연결되어 있지 않습니다." }
        do {
            let (header, _) = try await ensureAttachmentsTab(sheetId: sheetId, client: client)
            guard let column = TeamSheet.column(header, Self.contiColumnNames) else {
                undo()
                return "Attachments 탭에 콘티 열을 만들지 못했습니다."
            }
            var updates: [(range: String, rows: [[String]])] = []
            for chart in songCharts {
                guard let row = chart.row, row >= 2 else { continue }
                let want = chart.fileId == chosenId ? "✓" : ""
                guard want != (chart.chosenForConti ? "✓" : "") else { continue }
                guard await confirm(TeamSheet.attachmentsTab, row: row, holds: [chart.fileId],
                                    sheetId: sheetId, client: client) else { undo(); return Self.sheetMovedMessage }
                let at = "\(TeamSheet.columnLetter(column))\(row)"
                updates.append(("\(TeamSheet.attachmentsTab)!\(at):\(at)", [[want]]))
            }
            if !updates.isEmpty { try await client.batchWrite(sheetId: sheetId, updates: updates) }
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            undo()
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 팀과 나누지 못했습니다. 이 기기에서만 콘티에 넣습니다."
        } catch {
            undo()
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - The 응답 tab

    private func loadGrid(sheetId: String, client: SheetsClient) async {
        applyGrid((try? await client.read(sheetId: sheetId, range: AvailabilityGrid.tab)) ?? [])
    }

    private func applyGrid(_ rows: [[String]]) {
        guard let header = rows.first, AvailabilityGrid.Layout(header: header) != nil else {
            usesGrid = false
            rawGrid = nil
            return
        }
        usesGrid = true
        rawGrid = rows
        signups = gridSignups(rows)
    }

    /// The grid's answers as the rest of the app reads answers: each member
    /// by the roster's address for that name, and the part the leader has
    /// put them on for that service, if any.
    private func gridSignups(_ rows: [[String]]) -> [Date: [TeamSignup]] {
        var out: [Date: [TeamSignup]] = [:]
        for answer in AvailabilityGrid.answers(rows) {
            let member = members.first { $0.name.trimmingCharacters(in: .whitespaces) == answer.name }
            // That day's service by name when the grid names it — 주일예배
            // and 팀연습 on one day staff different parts.
            let sameDay = services.filter { Calendar.current.isDate($0.date, inSameDayAs: answer.day) }
            let service = sameDay.first { !answer.service.isEmpty && AvailabilityGrid.sameService($0.title, answer.service) }
                ?? sameDay.first
            // Matched as the roster message matches: 「김주영」 in a cell is
            // 주영's column.
            let part = service.flatMap { service in
                RosterMessage.parts(of: answer.name,
                                    in: service.assignments
                                        .sorted { (roleColumns[$0.key] ?? .max, $0.key) < (roleColumns[$1.key] ?? .max, $1.key) }
                                        .map { (part: $0.key, cell: $0.value) },
                                    names: TeamSheet.names(inCell:)).first
            } ?? ""
            out[answer.day, default: []].append(TeamSignup(role: part, email: member?.email ?? "", name: answer.name,
                                                           statusRaw: answer.status, row: answer.row))
        }
        return out
    }

    /// An answer written to the member's cell: their column by the roster's
    /// name, the service's row — made when the grid has none yet, as a
    /// column is for a member it has not met.
    private func setGridAvailability(_ status: SignupStatus, service: TeamService, email: String, name: String,
                                     sheetId: String, client: SheetsClient) async {
        guard var grid = rawGrid, let header = grid.first,
              let layout = AvailabilityGrid.Layout(header: header) else { return }
        let tab = AvailabilityGrid.tab
        let person = rosterName(for: email) ?? name
        func cell(_ column: Int, _ row: Int) -> String {
            let at = "\(TeamSheet.columnLetter(column))\(row)"
            return "\(tab)!\(at):\(at)"
        }
        do {
            isReadOnly = false
            var column = layout.column(for: person)
            if column == nil {
                let index = max(header.count, 2)
                try await client.write(sheetId: sheetId, range: cell(index, 1), row: [person])
                while grid[0].count < index { grid[0].append("") }
                grid[0].append(person)
                column = index
            }
            var row = AvailabilityGrid.row(for: service.date, service: service.title, in: grid)
            // The remembered row must still be this service: a grid sorted
            // in a browser would otherwise take this answer onto another day.
            if let target = row, !(await confirm(tab, row: target, holds: [dateText(service)],
                                                sheetId: sheetId, client: client)) {
                errorMessage = Self.sheetMovedMessage
                return
            }
            if row == nil {
                row = try await client.append(sheetId: sheetId, tab: tab, row: [service.title, dateText(service)])
                if let row {
                    while grid.count < row { grid.append([]) }
                    grid[row - 1] = [service.title, dateText(service)]
                }
            }
            guard let row, let column else { return }
            let word = AvailabilityGrid.word(status.rawValue)
            try await client.write(sheetId: sheetId, range: cell(column, row), row: [word])
            while grid[row - 1].count <= column { grid[row - 1].append("") }
            grid[row - 1][column] = word
            rawGrid = grid
            signups = gridSignups(grid)
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            errorMessage = "이 시트에 편집 권한이 없어 응답을 저장하지 못했습니다. 시트 주인에게 이 계정을 편집자로 추가해 달라고 요청하세요."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// What 시트를 멤버용으로 정리 would do, in words, before it is asked.
    func gridSetupPreview() -> [String] {
        let start = Calendar.current.date(byAdding: .day, value: -28, to: Calendar.current.startOfDay(for: Date()))!
        let schedule = services.sorted { $0.date < $1.date }.map { (day: $0.date, title: $0.title) }
        let names = members.filter(\.isActive).map(\.name).filter { !$0.isEmpty }
        var lines: [String] = []
        if let grid = rawGrid, let header = grid.first, let layout = AvailabilityGrid.Layout(header: header) {
            let newNames = names.filter { layout.column(for: $0) == nil }
            let newRows = AvailabilityGrid.missingServices(schedule, in: grid, from: start)
            if !newNames.isEmpty { lines.append("응답 탭에 멤버 열 추가: " + newNames.joined(separator: ", ")) }
            if !newRows.isEmpty { lines.append("응답 탭에 예배 줄 \(newRows.count)개 추가") }
        } else {
            let carried = signups.filter { $0.key >= start }.values.reduce(0) { $0 + $1.count }
            lines.append("「응답」 탭을 새로 만듭니다: 예배 \(schedule.filter { $0.day >= start }.count)줄 × 멤버 \(names.count)명. 칸마다 가능 · 미정 · 어려움 · 자리비움 드롭다운.")
            if carried > 0 { lines.append("Signups 탭의 응답 \(carried)개를 옮겨 적습니다. Signups 탭은 기록으로 그대로 둡니다.") }
        }
        let renames = partRenames()
        if !renames.isEmpty {
            lines.append("파트 이름 통일: " + renames.map { "\($0.from) → \($0.to)" }.joined(separator: ", "))
        }
        return lines
    }

    /// Part names spelled otherwise on Roles and in Schedule's header —
    /// each renamed only where the new name is not already there, so two
    /// spellings of one part do not become two parts of the same name.
    private func partRenames() -> [(from: String, to: String)] {
        var out: [(from: String, to: String)] = []
        for names in [roles.map(\.name), roleColumns.sorted { $0.value < $1.value }.map(\.key)] {
            var taken = Set(names)
            for name in names {
                guard let to = AvailabilityGrid.unifiedPart(name), !taken.contains(to) else { continue }
                taken.insert(to)
                if !out.contains(where: { $0.from == name }) { out.append((name, to)) }
            }
        }
        return out
    }

    /// Makes the sheet usable without the app: the 응답 tab — made, carrying
    /// the Signups answers over, or topped up with new members and services
    /// — and each part called one name on Roles and Schedule. Run only from
    /// a button, after its preview. Returns an error message, or nil.
    func prepareGrid(sheetId: String) async -> String? {
        #if DEBUG
        if isSample { return "샘플 모드에서는 시트를 바꾸지 않습니다." }
        #endif
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        let tab = AvailabilityGrid.tab
        let start = Calendar.current.date(byAdding: .day, value: -28, to: Calendar.current.startOfDay(for: Date()))!
        let schedule = services.sorted { $0.date < $1.date }.map { (day: $0.date, title: $0.title) }
        let names = members.filter(\.isActive).map(\.name).filter { !$0.isEmpty }
        do {
            let titles = try await client.tabTitles(sheetId: sheetId)
            if !titles.contains(tab) {
                // The answers given so far, each member by the roster's name;
                // a later row for the same person and day wins.
                var carried: [Date: [String: String]] = [:]
                for (day, list) in signups {
                    for signup in list.sorted(by: { ($0.row ?? 0) < ($1.row ?? 0) }) {
                        let who = rosterName(for: signup.email) ?? signup.name
                        carried[day, default: [:]][who] = signup.status.rawValue
                    }
                }
                let rows = AvailabilityGrid.build(services: schedule.filter { $0.day >= start },
                                                  members: names, answers: carried)
                try await client.addSheet(sheetId: sheetId, title: tab)
                guard let gid = try await client.tabGid(sheetId: sheetId, title: tab) else {
                    return "응답 탭을 만들지 못했습니다."
                }
                let last = TeamSheet.columnLetter(rows[0].count - 1)
                try await client.batchWrite(sheetId: sheetId, updates: [("\(tab)!A1:\(last)\(rows.count)", rows)])
                try await client.formatUpdate(sheetId: sheetId, requests:
                    AvailabilityGrid.formatRequests(gid: gid, members: names.count, rows: rows.count))
            } else {
                let grid = try await client.read(sheetId: sheetId, range: tab)
                guard let header = grid.first, let layout = AvailabilityGrid.Layout(header: header) else {
                    return "응답 탭의 첫 줄에 「날짜」 열이 없어 고치지 않았습니다."
                }
                let newNames = names.filter { layout.column(for: $0) == nil }
                if !newNames.isEmpty {
                    let from = TeamSheet.columnLetter(header.count), to = TeamSheet.columnLetter(header.count + newNames.count - 1)
                    try await client.batchWrite(sheetId: sheetId, updates: [("\(tab)!\(from)1:\(to)1", [newNames])])
                }
                for service in AvailabilityGrid.missingServices(schedule, in: grid, from: start) {
                    _ = try await client.append(sheetId: sheetId, tab: tab,
                                                row: [service.title, TeamSheet.dateFormatter.string(from: service.day)])
                }
            }
            try await unifyPartNames(sheetId: sheetId, client: client)
            await load(sheetId: sheetId)
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 정리하지 못했습니다."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Roles' names and Schedule's part headers, each in the team's one word.
    private func unifyPartNames(sheetId: String, client: SheetsClient) async throws {
        var updates: [(range: String, rows: [[String]])] = []
        let roleRows = try await client.read(sheetId: sheetId, range: TeamSheet.rolesTab)
        if let headerAt = TeamSheet.headerIndex(roleRows, tab: TeamSheet.rolesTab) {
            let column = TeamSheet.column(roleRows[headerAt], ["role", "파트", "역할", "name"]) ?? 0
            var taken = Set(roleRows.dropFirst(headerAt + 1).compactMap { $0.indices.contains(column) ? $0[column] : nil })
            for (offset, row) in roleRows.enumerated() where offset > headerAt && row.indices.contains(column) {
                if let to = AvailabilityGrid.unifiedPart(row[column]), taken.insert(to).inserted {
                    let at = "\(TeamSheet.columnLetter(column))\(offset + 1)"
                    updates.append(("\(TeamSheet.rolesTab)!\(at):\(at)", [[to]]))
                }
            }
        }
        let scheduleRows = try await client.read(sheetId: sheetId, range: TeamSheet.scheduleTab)
        if let headerAt = TeamSheet.headerIndex(scheduleRows, tab: TeamSheet.scheduleTab) {
            let parts = Self.scheduleRoleColumns([scheduleRows[headerAt]])
            var taken = Set(parts.keys)
            for (name, column) in parts.sorted(by: { $0.value < $1.value }) {
                if let to = AvailabilityGrid.unifiedPart(name), taken.insert(to).inserted {
                    let at = "\(TeamSheet.columnLetter(column))\(headerAt + 1)"
                    updates.append(("\(TeamSheet.scheduleTab)!\(at):\(at)", [[to]]))
                }
            }
        }
        if !updates.isEmpty { try await client.batchWrite(sheetId: sheetId, updates: updates) }
    }

    // MARK: - Attachments

    /// The Attachments tab, if the sheet has one.
    ///
    /// Optional like Plan: a team that has never attached anything has no
    /// such tab, and that is not an error. The tab is created on the first
    /// upload rather than demanded up front.
    /// The Attachments tab's header as last read: where its columns are,
    /// for a read of two of them (editsIds).
    private var attachmentsHeader: [String]?

    private func applyAttachments(_ read: [[String]]?) {
        guard let rows = read, rows.count > 1 else { attachments = [:]; return }

        let header = rows[0]
        attachmentsHeader = header
        let dateCol = TeamSheet.column(header, ["date", "날짜"]) ?? TeamSheet.Attachments.date
        let songCol = TeamSheet.column(header, ["song", "곡", "찬양"]) ?? TeamSheet.Attachments.song
        let nameCol = TeamSheet.column(header, ["name", "이름", "파일"]) ?? TeamSheet.Attachments.name
        let idCol = TeamSheet.column(header, ["fileid", "파일id"]) ?? TeamSheet.Attachments.fileId
        let urlCol = TeamSheet.column(header, ["url", "link", "링크"]) ?? TeamSheet.Attachments.url
        let byCol = TeamSheet.column(header, ["addedby", "올린사람", "작성자"])
        let hashCol = TeamSheet.column(header, ["hash", "해시"])
        let atCol = TeamSheet.column(header, ["addedat", "올린시각"])
        let contiCol = TeamSheet.column(header, Self.contiColumnNames)
        let iso = ISO8601DateFormatter()

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
                           row: offset + 1, hash: cell(hashCol).isEmpty ? nil : cell(hashCol),
                           addedAt: iso.date(from: cell(atCol)),
                           chosenForConti: !cell(contiCol).isEmpty)
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

    /// A Drive folder's name as it is now, through the church account.
    func folderName(_ id: String) async -> String? {
        await drive?.name(of: id)
    }

    func attachments(for service: TeamService) -> [Attachment] {
        attachments[Calendar.current.startOfDay(for: service.date)] ?? []
    }

    /// Files attached to one song, matched on the title the 콘티 shows.
    func attachments(for service: TeamService, song: String) -> [Attachment] {
        // By the song, not the spelling: the sheet's titles are tidied from
        // a video's long title, and a file attached under either is still
        // that song's.
        let key = song.trimmingCharacters(in: .whitespaces)
        // "" is the service's own files — the 콘티 — and matches only "".
        guard !key.isEmpty else { return attachments(for: service).filter { $0.song.isEmpty } }
        return attachments(for: service).filter { !$0.song.isEmpty && PlanSongTitle.sameSong($0.song, key) }
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
        by email: String,
        replacingSameName: Bool = false,
        folder: String? = nil
    ) async -> String? {
        guard let client, let drive else { return "구글 계정에 연결되어 있지 않습니다." }
        lastUploadWentToFolder = false

        // The tab first, then Drive: a sheet that will not take the row
        // should not leave a file behind in Drive to clean up.
        let header: [String]
        let rows: [[String]]
        do {
            (header, rows) = try await ensureAttachmentsTab(sheetId: sheetId, client: client)
        } catch {
            if case SheetsClient.SheetsError.http(403, _) = error { isReadOnly = true }
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        // ONE FILE, ONE ATTACHMENT. The same photo picked twice, a retry
        // after a slow upload, or the same PDF sent from the iPad and the
        // phone used to become two Drive files and two charts on the stand.
        // Contents are fingerprinted; the same contents on the same song of
        // the same service are not uploaded again.
        let hash = Self.fingerprint(data)
        if let existing = TeamSheet.Attachments.duplicate(in: rows, date: service.date, song: song, hash: hash) {
            return "이미 올린 파일입니다 — 「\(existing)」. 같은 파일은 한 번만 올라갑니다."
        }

        let uploaded: DriveClient.Uploaded
        do {
            // Into the folder asked for when this account may write there;
            // else the app's own 악보 folder, as every upload goes.
            if let folder, let placed = try? await drive.upload(data: data, name: name, mimeType: mimeType, folder: folder) {
                uploaded = placed
                lastUploadWentToFolder = true
            } else {
                uploaded = try await drive.upload(data: data, name: name, mimeType: mimeType)
            }
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        do {
            // Placed by the tab's own column names, so a tab whose columns
            // were rearranged still gets each value in its column.
            let row = TeamSheet.place([
                (["date", "날짜"], TeamSheet.dateFormatter.string(from: service.date)),
                (["song", "곡", "찬양"], song),
                (["name", "이름", "파일"], name),
                (["fileid", "파일id"], uploaded.fileId),
                (["url", "link", "링크"], uploaded.link.absoluteString),
                (["addedby", "by", "올린사람"], email),
                (["addedat", "at", "올린시각"], ISO8601DateFormatter().string(from: Date())),
                (["hash", "해시"], hash)
            ], header: header)
            let written = try await client.append(
                sheetId: sheetId, tab: TeamSheet.attachmentsTab, row: row
            )
            let day = Calendar.current.startOfDay(for: service.date)
            // A transposed chart sent again in the same key replaces the
            // one before rather than piling up beside it.
            let replaced = replacingSameName
                ? attachments(for: service, song: song).filter { $0.name == name } : []
            attachments[day, default: []].append(
                Attachment(date: service.date, song: song, name: name,
                           fileId: uploaded.fileId, url: uploaded.link,
                           addedBy: email, row: written, hash: hash, addedAt: Date())
            )
            for old in replaced { _ = await removeAttachment(old, sheetId: sheetId) }
            errorMessage = nil
            return nil
        } catch {
            // The sheet refused, so take the orphan back out of Drive.
            try? await drive.delete(fileId: uploaded.fileId)
            if case SheetsClient.SheetsError.http(403, _) = error { isReadOnly = true }
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Formats the team sheet for reading — see SheetTidy. Touches no data.
    /// Returns a sentence for the person who pressed it.
    /// The sheet is missing a frozen header or a colour rule that 정리
    /// would add: shown as a badge beside 찬양팀 Sheet, not as a row of
    /// its own that is there whether or not it would do anything.
    @Published private(set) var sheetNeedsTidy = false

    /// Asks once per sheet a session — reading the tabs' formatting costs a
    /// read per tab, and a sheet is not untidied by the app.
    func checkTidy(sheetId: String) async {
        #if DEBUG
        // The sample sheet is never read; it shows the badge so its place
        // in the layout can be reviewed.
        if isSample { sheetNeedsTidy = true; return }
        #endif
        guard let client, !isReadOnly, tidyCheckedSheet != sheetId else { return }
        tidyCheckedSheet = sheetId
        guard let tabs = try? await client.tidyTabs(sheetId: sheetId) else { return }
        sheetNeedsTidy = !tabs.isEmpty && SheetTidy.isNeeded(tabs)
    }
    private var tidyCheckedSheet: String?

    func tidySheet(sheetId: String) async -> String {
        #if DEBUG
        if isSample { return "샘플 모드에서는 시트를 바꾸지 않습니다." }
        #endif
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        do {
            let tabs = try await client.tidyTabs(sheetId: sheetId)
            guard !tabs.isEmpty else { return "정리할 탭을 찾지 못했습니다." }
            let requests = SheetTidy.requests(for: tabs)
            try await client.formatUpdate(sheetId: sheetId, requests: requests)
            sheetNeedsTidy = false
            let added = requests.filter { $0["addConditionalFormatRule"] != nil }.count
            let names = tabs.map(\.title).joined(separator: ", ")
            return added == 0
                ? "\(names) 탭의 머리글을 다시 맞췄습니다. 색 규칙은 이미 있습니다."
                : "\(names) 탭을 정리했습니다. 색 규칙 \(added)개를 더했습니다."
        } catch {
            if case SheetsClient.SheetsError.http(403, _) = error {
                return "이 계정은 시트를 볼 수만 있습니다. 편집 권한이 있는 계정으로 정리하세요."
            }
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The Attachments tab's header, creating the tab the first time one
    /// is needed.
    ///
    /// Whether the tab EXISTS is asked by its name. It used to be inferred
    /// from row 1 having something in it — so a team that inserted a row
    /// above the header, or left row 1 blank, had every upload fail with
    /// Google refusing to create 「Attachments」 a second time. Adding a TAB
    /// is safe where adding a COLUMN is not: a new tab cannot shift
    /// anything the team already has.
    private func ensureAttachmentsTab(sheetId: String, client: SheetsClient) async throws -> (header: [String], rows: [[String]]) {
        let tab = TeamSheet.attachmentsTab
        // Raw, for where the header really is; anchored, as every reader
        // of this tab sees it.
        let raw = (try? await client.read(sheetId: sheetId, range: tab)) ?? []
        let rows = TeamSheet.anchorHeader(raw, tab: tab)
        if var header = rows.first, let index = TeamSheet.headerIndex(raw, tab: tab) {
            // A tab from before these columns gets each added at the end of
            // its header, where it disturbs nothing.
            for (name, aliases) in [("Hash", ["hash", "해시"]), ("콘티", Self.contiColumnNames)]
            where TeamSheet.column(header, aliases) == nil {
                let at = (header.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? -1) + 1
                let cell = "\(tab)!\(TeamSheet.columnLetter(at))\(index + 1)"
                if (try? await client.write(sheetId: sheetId, range: "\(cell):\(cell)", row: [name])) != nil {
                    while header.count < at { header.append("") }
                    if header.count == at { header.append(name) } else { header[at] = name }
                }
            }
            return (header, rows)
        }
        if !(try await client.tabTitles(sheetId: sheetId)).contains(tab) {
            try await client.addSheet(sheetId: sheetId, title: tab)
        }
        // The tab exists with no header the app recognises. An empty tab
        // gets one; a tab holding something else is not written over.
        let hasContent = rows.contains { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !hasContent else {
            throw SheetsClient.SheetsError.badRange(
                "Attachments 탭에 Date · Song · Name · FileId · URL 머리글이 없습니다. 머리글 줄을 넣거나, 다른 용도의 탭이면 이름을 바꿔 주세요.")
        }
        let header = TeamSheet.Attachments.header
        try await client.write(sheetId: sheetId,
                               range: "\(tab)!A1:\(TeamSheet.columnLetter(header.count - 1))1",
                               row: header)
        return (header, [header])
    }

    /// A file's contents, fingerprinted: SHA-256, hex.
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The 콘티 folder

    /// The files in the church's 콘티 folder — see ContiFolder.
    @Published private(set) var contiFiles: [ContiFolder.File] = []
    @Published private(set) var contiFolderProblem: String?

    func loadContiFolder() async {
        guard let id = ContiFolder.folderId else { contiFiles = []; contiFolderProblem = nil; return }
        if let files = await ContiFolder.list(folderId: id, apiKey: AppSecrets.youtubeAPIKey) {
            contiFiles = files
            contiFolderProblem = nil
        } else {
            contiFolderProblem = "콘티 폴더를 읽지 못했습니다. 폴더가 「링크가 있는 모든 사용자」에게 공유되어 있는지 확인하세요."
        }
    }

    /// A service's 콘티 files, newest first: the folder's versions for its
    /// day, then any uploaded through the app onto the service. The app's
    /// own 「콘티 PDF 만들기」 output is not among them.
    func contis(for service: TeamService) -> [Attachment] {
        let fromFolder = ContiFolder.versions(for: service.date, in: contiFiles).map { file in
            // The sheet's row for it, when one was made.
            var item = attachment(fileId: file.id)
                ?? Attachment(date: service.date, song: "", name: file.name, fileId: file.id,
                              url: file.url, addedBy: "")
            item.addedAt = file.modified ?? item.addedAt
            return item
        }
        let uploaded = attachments(for: service)
            .filter { $0.belongsToService && !ContiPages.isBuilt($0) && !fromFolder.map(\.fileId).contains($0.fileId) }
            .reversed()
        return fromFolder + uploaded
    }

    // MARK: - Shared corrections

    /// The attachment as last read from the sheet — or a file of the 콘티
    /// folder — by file id.
    func attachment(fileId: String) -> Attachment? {
        if let row = attachments.values.lazy.flatMap({ $0 }).first(where: { $0.fileId == fileId }) { return row }
        guard let file = contiFiles.first(where: { $0.id == fileId }) else { return nil }
        return Attachment(date: file.date ?? Date(), song: "", name: file.name, fileId: file.id,
                          url: file.url, addedBy: "")
    }

    // MARK: - The 교정 tab

    /// What a share came to: the writing it is (「tab#3」), and the chart's
    /// corrections as the team now has them — this device's put together
    /// with anyone else's since (EditMerge).
    struct SharedResult {
        let revision: String
        let entry: SharedEdits.Entry
    }

    /// The tab's rows by chart, as of the last look (correctionRevisions).
    private var correctionRows: [String: CorrectionsTab.Row] = [:]
    private var hasCorrectionsTab = false

    /// Which writing of a chart's corrections the team has, as last seen:
    /// its row of the 교정 tab.
    func knownRevision(fileId: String, part: String) -> String? {
        if let row = correctionRows[CorrectionsTab.key(fileId: fileId, part: part)] {
            return CorrectionsTab.token(row.revision)
        }
        // Pages assigned again since: the rows that hold them, as one
        // writing (fetchCorrection puts them together).
        if let wanted = Self.pageList(part) {
            let held = correctionRows.filter { key, _ in
                key.hasPrefix(fileId + "|pages:")
                    && !Set(Self.pageList(String(key.dropFirst(fileId.count + 1))) ?? []).isDisjoint(with: wanted)
            }
            if !held.isEmpty {
                return "remap#" + wanted.map(String.init).joined(separator: ",") + "@"
                    + held.values.map { "\($0.row).\($0.revision)" }.sorted().joined(separator: ",")
            }
        }
        return nil
    }

    /// One look at what changed: the tab's file, part and writing columns,
    /// in a single request. Every 3 seconds while a chart is open.
    func correctionRevisions() async -> [String: String]? {
        guard let client, let sheetId = TeamSheetSource.current else { return nil }
        guard hasCorrectionsTab,
              let columns = try? await client.readColumns(
                sheetId: sheetId,
                ranges: ["\(CorrectionsTab.tab)!A:A", "\(CorrectionsTab.tab)!C:C", "\(CorrectionsTab.tab)!D:D"]),
              columns.count == 3 else { return hasCorrectionsTab ? nil : [:] }
        correctionRows = CorrectionsTab.index(files: columns[0], parts: columns[1], revisions: columns[2])
        var out: [String: String] = [:]
        for (key, row) in correctionRows { out[key] = CorrectionsTab.token(row.revision) }
        return out
    }

    /// A chart part's corrections, the writing they are, and who wrote it.
    func fetchCorrection(fileId: String, part: String) async -> (revision: String, entry: SharedEdits.Entry, by: String?)? {
        guard let client, let sheetId = TeamSheetSource.current else { return nil }
        if let row = correctionRows[CorrectionsTab.key(fileId: fileId, part: part)] {
            guard let read = await correctionRow(row.row, sheetId: sheetId, client: client) else { return nil }
            return (CorrectionsTab.token(row.revision), read.entry, read.by)
        }
        // A song of a 콘티 file whose pages were assigned again since it was
        // corrected: its corrections are under the old page list. Taken page
        // by page from whichever rows hold them, rather than lost.
        if let wanted = Self.pageList(part) {
            var byPage: [Int: [ScoreChord]] = [:]
            var who: String?
            for (key, row) in correctionRows where key.hasPrefix(fileId + "|pages:") {
                guard let theirs = Self.pageList(String(key.dropFirst(fileId.count + 1))),
                      !Set(theirs).isDisjoint(with: wanted),
                      let read = await correctionRow(row.row, sheetId: sheetId, client: client),
                      let chords = read.entry.chords else { continue }
                for (index, page) in theirs.enumerated() where chords.indices.contains(index) { byPage[page] = chords[index] }
                who = read.by
            }
            if !byPage.isEmpty {
                return (knownRevision(fileId: fileId, part: part) ?? "remap",
                        SharedEdits.Entry(chords: wanted.map { byPage[$0] ?? [] }), who)
            }
        }
        return nil
    }

    /// A row's corrections and who wrote them.
    private func correctionRow(_ row: Int, sheetId: String, client: SheetsClient) async -> (entry: SharedEdits.Entry, by: String?)? {
        let layout = CorrectionsTab.Layout.standard
        let range = "\(CorrectionsTab.tab)!\(TeamSheet.columnLetter(layout.body))\(row):\(TeamSheet.columnLetter(layout.by))\(row)"
        guard let cells = (try? await client.read(sheetId: sheetId, range: range))?.first,
              let text = cells.first, let entry = CorrectionsBody.decode(text) else { return nil }
        let by = cells.count > layout.by - layout.body ? cells[layout.by - layout.body] : ""
        return (entry, by.isEmpty ? nil : by)
    }

    /// 「pages:2,3」 → [2, 3].
    private static func pageList(_ part: String) -> [Int]? {
        guard part.hasPrefix("pages:") else { return nil }
        let pages = part.dropFirst(6).split(separator: ",").compactMap { Int($0) }
        return pages.isEmpty ? nil : pages
    }

    /// The tab, made the first time and hidden: it is the app's, written
    /// in JSON, and a member reading the sheet has nothing to do there.
    private func ensureCorrectionsTab(sheetId: String, client: SheetsClient) async throws {
        if hasCorrectionsTab { return }
        if !(try await client.tabTitles(sheetId: sheetId)).contains(CorrectionsTab.tab) {
            try await client.addSheet(sheetId: sheetId, title: CorrectionsTab.tab)
            let last = TeamSheet.columnLetter(CorrectionsTab.header.count - 1)
            try await client.write(sheetId: sheetId, range: "\(CorrectionsTab.tab)!A1:\(last)1", row: CorrectionsTab.header)
            if let gid = try await client.tabGid(sheetId: sheetId, title: CorrectionsTab.tab) {
                try? await client.formatUpdate(sheetId: sheetId, requests: [[
                    "updateSheetProperties": ["properties": ["sheetId": gid, "hidden": true], "fields": "hidden"]
                ]])
            }
        }
        hasCorrectionsTab = true
    }

    /// Writes a chart part's corrections into its row of the tab: the row
    /// as it is now, `change` laid on it, the next writing number — read
    /// back, and made again on top of anyone else's that landed first.
    /// - pdfPages, sizes: the chart's pages in the file and their size in
    ///   points, for the XFDF rectangles other PDF readers place chords by.
    func shareCorrection(fileId: String, part: String, pdfPages: [Int] = [], sizes: [CGSize] = [],
                         _ change: (inout SharedEdits.Entry) -> Void) async -> Result<SharedResult, ShareEditsError> {
        guard let client, let sheetId = TeamSheetSource.current else { return .failure(.noAccess) }
        let item = attachment(fileId: fileId)
        let song = item.map { $0.song.isEmpty ? $0.name : $0.song } ?? ""
        let who = lastActingEmail.flatMap { rosterName(for: $0) } ?? lastActingEmail ?? ""
        let layout = CorrectionsTab.Layout.standard
        let lastColumn = TeamSheet.columnLetter(CorrectionsTab.header.count - 1)
        do {
            try await ensureCorrectionsTab(sheetId: sheetId, client: client)
            for _ in 0..<3 {
                _ = await correctionRevisions()
                let key = CorrectionsTab.key(fileId: fileId, part: part)
                let found = correctionRows[key]
                var entry = SharedEdits.Entry()
                if let found {
                    let range = "\(CorrectionsTab.tab)!\(TeamSheet.columnLetter(layout.body))\(found.row)"
                    if let text = (try? await client.read(sheetId: sheetId, range: range))?.first?.first,
                       let kept = CorrectionsBody.decode(text) {
                        entry = kept
                    }
                }
                let before = entry
                change(&entry)
                // Nothing new: the team has it already — the one who fixed it
                // shared first, or a stand in the room is making sure. No
                // writing, so ten stands making sure are not ten writes.
                if let found, entry == before {
                    return .success(SharedResult(revision: CorrectionsTab.token(found.revision), entry: entry))
                }
                guard let body = CorrectionsBody.encode(entry, part: part, pdfPages: pdfPages, sizes: sizes),
                      body.count <= CorrectionsTab.largestBody else {
                    return .failure(.failed("교정이 시트 한 칸보다 커서 공유하지 못했습니다"))
                }
                let revision = (found?.revision ?? 0) + 1
                let stamp = TeamSheet.dateFormatter.string(from: Date()) + " · " + String(UUID().uuidString.prefix(6))
                var cells = Array(repeating: "", count: CorrectionsTab.header.count)
                cells[layout.file] = fileId
                cells[layout.song] = song
                cells[layout.part] = part
                cells[layout.revision] = String(revision)
                cells[layout.body] = body
                cells[layout.by] = who
                cells[layout.at] = stamp
                let row: Int
                if let found {
                    row = found.row
                    try await client.write(sheetId: sheetId, range: "\(CorrectionsTab.tab)!A\(row):\(lastColumn)\(row)", row: cells)
                } else {
                    guard let appended = try await client.append(sheetId: sheetId, tab: CorrectionsTab.tab, row: cells)
                    else { continue }
                    row = appended
                }
                // Read back: ours, or someone else's that landed after it.
                let back = (try? await client.read(sheetId: sheetId, range: "\(CorrectionsTab.tab)!A\(row):\(lastColumn)\(row)"))?.first ?? []
                let stuck = back.indices.contains(layout.at) && back[layout.at] == stamp
                if back.isEmpty || stuck {
                    correctionRows[key] = .init(row: row, revision: revision)
                    return .success(SharedResult(revision: CorrectionsTab.token(revision), entry: entry))
                }
            }
            return .failure(.failed("다른 팀원과 동시에 고쳐 공유하지 못했습니다"))
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            return .failure(.noAccess)
        } catch {
            return .failure(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    /// A chart taken off: its rows of the 교정 tab go with it, rather than
    /// staying as corrections to a file nobody can open.
    private func clearCorrections(of fileId: String, sheetId: String, client: SheetsClient) async {
        guard hasCorrectionsTab else { return }
        _ = await correctionRevisions()
        let width = CorrectionsTab.header.count
        let last = TeamSheet.columnLetter(width - 1)
        let rows = correctionRows.filter { $0.key.hasPrefix(fileId + "|") }
        guard !rows.isEmpty else { return }
        try? await client.batchWrite(sheetId: sheetId, updates: rows.values.map { row in
            ("\(CorrectionsTab.tab)!A\(row.row):\(last)\(row.row)", [[String](repeating: "", count: width)])
        })
        for key in rows.keys { correctionRows[key] = nil }
    }

    /// Which page of a 콘티 file is which song, as set by hand, for the team.
    func sharePageAssignment(fileId: String, pages: [Int: String]) async -> Result<String, ShareEditsError> {
        await shareCorrection(fileId: fileId, part: CorrectionsTab.pageMapPart) { entry in
            entry.pages = Dictionary(uniqueKeysWithValues: pages.map { (String($0.key), $0.value) })
        }.map(\.revision)
    }

    /// The page map someone set by hand for a 콘티 file, if any.
    func pageAssignment(fileId: String) async -> [String: String]? {
        if correctionRows.isEmpty { _ = await correctionRevisions() }
        return await fetchCorrection(fileId: fileId, part: CorrectionsTab.pageMapPart)?.entry.pages
    }

    enum ShareEditsError: Error {
        case noAccess, notFound, moved, failed(String)
    }

    /// Removes an attachment from the sheet and from Drive.
    func removeAttachment(_ item: Attachment, sheetId: String) async -> String? {
        #if DEBUG
        // The sample team has no sheet: taken off here only, so the flow
        // can be tried end to end.
        if isSample {
            attachments[Calendar.current.startOfDay(for: item.date)]?.removeAll { $0.fileId == item.fileId }
            return nil
        }
        #endif
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        guard let row = item.row, row >= 2 else { return "줄 번호를 알 수 없습니다." }
        guard await confirm(TeamSheet.attachmentsTab, row: row, holds: [item.fileId],
                            sheetId: sheetId, client: client) else {
            return Self.sheetMovedMessage
        }
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
            await clearCorrections(of: item.fileId, sheetId: sheetId, client: client)
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
        beginWrite()
        defer { endWrite() }
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
        // On screen first, then on the sheet — the read that checks the row
        // and the write take a second or two, and the chip waiting for them
        // read as a tap that did not take. Put back if the sheet says no.
        let before = service.assignments[role] ?? ""
        applyAssignmentLocally(role: role, value: value, service: service)
        func undo() { applyAssignmentLocally(role: role, value: before, service: service) }
        guard await confirm(TeamSheet.scheduleTab, row: row, holds: [dateText(service)],
                            sheetId: sheetId, client: client) else {
            undo()
            return Self.sheetMovedMessage
        }
        do {
            isReadOnly = false
            try await client.write(sheetId: sheetId, range: cell, row: [value])
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            undo()
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 지정하지 못했습니다."
        } catch {
            undo()
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
        guard await confirm(TeamSheet.scheduleTab, row: row, holds: [dateText(service)],
                            sheetId: sheetId, client: client) else {
            return Self.sheetMovedMessage
        }
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
        // On the 응답 tab an answer's part is read from the schedule, so a
        // new assignment gives it one now rather than on the next reload.
        if usesGrid, let rawGrid { signups = gridSignups(rawGrid) }
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
        beginWrite()
        defer { endWrite() }
        let day = Calendar.current.startOfDay(for: service.date)
        func isMine(_ signup: TeamSignup) -> Bool {
            emails.contains { $0.caseInsensitiveCompare(signup.email) == .orderedSame }
        }
        let mine = (signups[day] ?? []).filter(isMine)
        func forget() {
            signups[day]?.removeAll(where: isMine)
        }
        #if DEBUG
        if isSample {
            if DebugHarness.slowSheet { try? await Task.sleep(for: .seconds(1)) }
            forget(); return true
        }
        #endif
        guard let client else { forget(); return true }

        // On the 응답 tab: the member's cell blanked — no answer, as a blank
        // cell always means there.
        if usesGrid, var grid = rawGrid, let header = grid.first,
           let layout = AvailabilityGrid.Layout(header: header) {
            do {
                for signup in mine {
                    guard let row = signup.row, row >= 2, let column = layout.column(for: signup.name),
                          await confirm(AvailabilityGrid.tab, row: row, holds: [dateText(service)],
                                        sheetId: sheetId, client: client) else { continue }
                    let at = "\(TeamSheet.columnLetter(column))\(row)"
                    try await client.write(sheetId: sheetId, range: "\(AvailabilityGrid.tab)!\(at):\(at)", row: [""])
                    if grid.indices.contains(row - 1), grid[row - 1].indices.contains(column) { grid[row - 1][column] = "" }
                }
                rawGrid = grid
                signups = gridSignups(grid)
                return true
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return false
            }
        }

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
                // Only a row that is still this person's answer for this day.
                guard let signup = mine.first(where: { $0.row == target }),
                      await confirm(TeamSheet.signupsTab, row: target,
                                    holds: [dateText(service), signup.email, signup.role],
                                    sheetId: sheetId, client: client) else { continue }
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
        guard let header = try? await client.readTable(
            sheetId: sheetId, tab: TeamSheet.planTab
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
        beginWrite()
        defer { endWrite() }
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
        // Off the screen first; back if the sheet says no. It used to wait
        // for three round trips — the whole tab read for its width — with
        // the swiped row still standing there.
        let keptPlan = plans[day], keptSongs = songs[day]
        plans[day]?.removeAll { $0.id == item.id }
        if !hasPlanTab {
            songs[day]?.removeAll { $0.order == item.order && $0.title == item.title }
        }
        func undo() { plans[day] = keptPlan; songs[day] = keptSongs }

        // The row number is from the last load. If somebody has since
        // deleted or inserted a row in the browser, it now points at a
        // different line — and clearing it would remove someone else's
        // song without a word. So the row must still hold this title. The
        // same read gives its width.
        let current = (try? await client.read(sheetId: sheetId,
                                              range: "\(tab)!A\(row):AZ\(row)"))?.first ?? []
        let wanted = item.title.trimmingCharacters(in: .whitespaces)
        guard current.contains(where: { $0.trimmingCharacters(in: .whitespaces) == wanted }) else {
            undo()
            await load(sheetId: sheetId)
            return "시트가 그 사이에 바뀌어 지우지 않았습니다. 새로 불러왔으니 다시 확인해 주세요."
        }
        let width = max(current.count, 7)
        let last = TeamSheet.columnLetter(width - 1)

        do {
            isReadOnly = false
            try await client.write(
                sheetId: sheetId,
                range: "\(tab)!A\(row):\(last)\(row)",
                row: [String](repeating: "", count: width)
            )
            errorMessage = nil
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            undo()
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 지우지 못했습니다."
        } catch {
            undo()
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Writes a new running order for a service.
    ///
    /// Only the Order cell of each row is touched. The rows stay where they
    /// are on the sheet — nothing is moved, inserted or deleted — so every
    /// other service's rows, and every row number the app holds, are exactly
    /// as they were. Reordering is a renumbering, which is also what a
    /// leader would do by hand.
    ///
    /// Through whichever tab the items came from, for the same reason as
    /// removePlanItem: a sheet with no Plan tab shows its Songs as the
    /// order of service.
    func reorder(_ items: [PlanItem],
                 in service: TeamService,
                 sheetId: String) async -> String? {
        beginWrite()
        defer { endWrite() }
        let day = Calendar.current.startOfDay(for: service.date)

        #if DEBUG
        if isSample {
            let renumbered = items.enumerated().map { index, item -> PlanItem in
                var copy = item; copy.order = index + 1; return copy
            }
            if hasPlanTab { plans[day] = renumbered }
            else {
                songs[day] = renumbered.map {
                    TeamSong(order: $0.order, title: $0.title, url: $0.url,
                             key: $0.key, transpose: 0, notes: $0.notes, row: $0.row)
                }
            }
            return nil
        }
        #endif
        guard let client else { return "시트에 연결되어 있지 않습니다." }

        let tab = hasPlanTab ? TeamSheet.planTab : TeamSheet.songsTab
        do {
            let table = try await client.readTable(sheetId: sheetId, tab: tab)
            let header = table.first ?? []
            guard let orderColumn = TeamSheet.column(header, ["order", "순서", "#"]) else {
                return "\(tab) 탭에 순서(Order) 열이 없습니다."
            }
            let letter = TeamSheet.columnLetter(orderColumn)

            // Every row must be known before any is written. A reorder that
            // stops halfway leaves two songs both numbered 2, which is worse
            // than not reordering at all.
            let rows = items.compactMap(\.row)
            guard rows.count == items.count, rows.allSatisfy({ $0 >= 2 }) else {
                return "줄 번호를 알 수 없는 항목이 있습니다. 새로 고친 뒤 다시 시도해 주세요."
            }
            // Each remembered row must still hold its song. Sorted in the
            // browser since the last load, these numbers would renumber
            // other songs — so nothing is written unless every row checks.
            let moved = zip(items, rows).contains { item, row in
                !(table.indices.contains(row - 1) && TeamSheet.row(table[row - 1], holds: [item.title]))
            }
            if moved {
                await load(sheetId: sheetId)
                return Self.sheetMovedMessage
            }

            try await client.batchWrite(
                sheetId: sheetId,
                updates: zip(items, rows).enumerated().map { index, pair in
                    (range: "\(tab)!\(letter)\(pair.1)", rows: [[String(index + 1)]])
                }
            )

            // Re-read, as everywhere else that writes: what is shown is
            // what the sheet holds.
            if hasPlanTab {
                plans = Self.parsePlan(try await client.readTable(sheetId: sheetId, tab: TeamSheet.planTab))
            } else {
                adoptSongRows(try await rawSongRows(sheetId: sheetId))
            }
            return nil
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
    #if DEBUG
    /// The sample team's 순서 given these songs, in memory — the titles as
    /// they would be written — so a fill and a merge can be tried in a
    /// simulator. Other lines keep their places; the songs fill the song
    /// places in order, any more after.
    func samplePush(_ incoming: [TeamSong], to service: TeamService) {
        let day = Calendar.current.startOfDay(for: service.date)
        var plan = plans[day] ?? []
        var queue = incoming.map { song in
            PlanItem(order: 0, kind: .song,
                     title: song.chosenTitle ?? (song.sheetRow == nil
                                                 ? PlanSongTitle.forSheet(song.title, channel: song.channel).title
                                                 : song.title),
                     minutes: nil, person: nil, key: song.key, url: song.url, notes: song.notes, row: nil)
        }
        plan = plan.compactMap { item in
            guard item.kind == .song else { return item }
            return queue.isEmpty ? nil : queue.removeFirst()
        } + queue
        for index in plan.indices { plan[index].order = index + 1 }
        plans[day] = plan
    }
    #endif

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

        func cells(_ song: TeamSong, over existing: [String]? = nil) -> [String] {
            if let kept = song.sheetRow {
                var row = Array(kept.prefix(layout.width))
                while row.count < layout.width { row.append("") }
                row[layout.date] = day
                // A label there — 「헌금찬양」 — is the team's, not a position.
                if Int(row[layout.order].trimmingCharacters(in: .whitespaces)) != nil || row[layout.order].isEmpty {
                    row[layout.order] = String(song.order)
                }
                return row
            }
            // The song, not the video's title; the recording in 참고버전.
            // A title chosen by hand is written as chosen, and the video's
            // own title goes to 참고버전 whole: what the reading made of it
            // is what was set aside.
            let tidy = PlanSongTitle.forSheet(song.title, channel: song.channel)
            return layout.row(
                date: day,
                order: String(song.order),
                title: song.chosenTitle ?? tidy.title,
                url: song.url?.absoluteString ?? "",
                key: song.key ?? "",
                transpose: song.transpose == 0 ? "" : String(song.transpose),
                notes: song.notes ?? "",
                reference: song.chosenTitle == nil ? tidy.reference : song.title,
                // Columns the app does not own are left exactly as they
                // were. This passed nil for every row, and a push blanked the
                // Service column of each row it rewrote.
                existing: existing
            )
        }

        var updates: [(range: String, rows: [[String]])] = []
        for (index, song) in incoming.enumerated() where index < targets.count {
            let row = targets[index]
            let before = existingRows.indices.contains(row - 1) ? existingRows[row - 1] : nil
            updates.append((
                "\(TeamSheet.songsTab)!A\(row):\(layout.lastColumnLetter)\(row)",
                [cells(song, over: before.map { Array($0.prefix(layout.width)) })]
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

        // What was written, not what came in: a song's title here is the
        // video's, and a title chosen in 곡 제목 확인 showed as the reading
        // it replaced until something reloaded. Then the sheet itself, read
        // again — the honest look, as 콘티에 추가 does.
        songs[Calendar.current.startOfDay(for: service.date)] = incoming.map { song in
            var written = song
            if song.sheetRow == nil {
                written = TeamSong(order: song.order,
                                   title: song.chosenTitle ?? PlanSongTitle.forSheet(song.title, channel: song.channel).title,
                                   url: song.url, key: song.key, transpose: song.transpose, notes: song.notes,
                                   channel: song.channel)
            }
            return written
        }
        await load(sheetId: sheetId)
        return PushResult(written: incoming.count, replaced: targets.count)
    }

    /// Adds one song to a service's 콘티.
    ///
    /// The path from "this is the one" to "it is on Sunday's list" ran
    /// through a playlist: add it there, pin the playlist, push the whole
    /// thing — which also overwrote whatever was already planned. Deciding
    /// on a single song is the common case and now takes one action.
    /// What happened when a song was added, for the confirmation bubble.
    enum AppendResult: Equatable {
        case added
        /// Already on that service — nothing written.
        case alreadyThere
        /// Written, but not where the 콘티 reads it.
        case misplaced
        case failed(String)
    }

    func appendSong(
        title: String,
        videoId: String,
        key: String?,
        channel: String? = nil,
        to service: TeamService,
        sheetId: String
    ) async -> AppendResult {
        // The key the team last played it in, when nothing else gives one.
        let key = key ?? lastKey(videoId: videoId, title: title, before: service.date)
        #if DEBUG
        // In memory, so the add, its bubble and the duplicate guard can be
        // driven in a simulator without a sheet.
        if isSample {
            let day = Calendar.current.startOfDay(for: service.date)
            if (plans[day] ?? []).contains(where: { $0.videoId == videoId }) { return .alreadyThere }
            let order = ((plans[day] ?? []).map(\.order).max() ?? 0) + 1
            plans[day, default: []].append(PlanItem(
                order: order, kind: .song, title: title, minutes: nil, person: nil,
                key: key, url: YouTubeID.watchURL(videoId), notes: nil, row: nil))
            return .added
        }
        #endif
        guard let client else { return .failed("시트에 연결되어 있지 않습니다.") }
        do {
            let existing = try await rawSongRows(sheetId: sheetId)
            let layout = SongLayout(header: existing.first ?? [])
            let day = Calendar.current.startOfDay(for: service.date)
            let dayText = TeamSheet.dateFormatter.string(from: service.date)

            // Never the same video twice on one service.
            //
            // There was no guard, and no sign on screen that an add had
            // worked, so a song that did not appear was added again — one
            // 콘티 ended up with the same video seven times. Checked against
            // the whole row, not the parsed view, so a copy sitting in the
            // wrong columns (invisible to the parser) still counts.
            let already = existing.dropFirst().contains { row in
                row.contains { TeamSheet.day($0).map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
                    && row.contains { TeamSheet.videoKey($0) == videoId }
            }
            if already { return .alreadyThere }

            // Numbered from the sheet as it stands NOW, not from what this
            // device last loaded. The local copy was why three appends in a
            // row all came out as order 4 — none of them could see the
            // others, because each one landed somewhere the parser did not
            // read and never made it back into `songs`.
            let fresh = Self.parseSongs(existing)[day] ?? []
            let next = (fresh.map(\.order).max() ?? 0) + 1

            // The song as its title, the video's packaging in 참고버전.
            let tidy = PlanSongTitle.forSheet(title, channel: channel)
            try await client.append(
                sheetId: sheetId,
                tab: TeamSheet.songsTab,
                row: layout.row(
                    date: dayText,
                    order: String(next),
                    title: tidy.title,
                    url: YouTubeID.watchURL(videoId)?.absoluteString ?? "",
                    key: key ?? "",
                    transpose: "",
                    notes: "",
                    reference: tidy.reference,
                    existing: nil
                )
            )
            // Re-read rather than patch in place.
            //
            // Appending to the local copy showed the song immediately — and
            // went on showing it even when the write had landed in the wrong
            // columns and the sheet no longer agreed. The screen and the
            // sheet then disagreed until something forced a reload, and
            // switching account was what forced it: the 순서 appeared to
            // CHANGE with the account, when in fact the reload was the first
            // honest look at the sheet. What is shown is now always what the
            // sheet holds.
            adoptSongRows(try await rawSongRows(sheetId: sheetId))
            errorMessage = nil

            // And checked: the song must now be in the 콘티 as the app reads
            // it. If it is not, saying so is the whole difference between a
            // person retrying blindly and a person seeing the warning above.
            let landed = (songs[day] ?? []).contains {
                $0.url.flatMap { TeamSheet.videoKey($0.absoluteString) } == videoId
            }
            return landed ? .added : .misplaced
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            return .failed(message)
        }
    }

    /// Clears every repeated copy and renumbers the services they were on.
    ///
    /// Only from a button, like the shifted-row repair. Recomputed from a
    /// fresh read immediately before writing, so a row somebody changed in
    /// the meantime is judged as it is now, not as it was on screen. Rows
    /// are cleared, not deleted: deleting would move every row below, and
    /// another member's app may be holding those row numbers.
    func repairDuplicateSongs(sheetId: String) async -> String? {
        #if DEBUG
        if isSample {
            adoptSongRows(Array((rawSongs ?? []).prefix(2)))
            return nil
        }
        #endif
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        do {
            let rows = try await rawSongRows(sheetId: sheetId)
            let found = TeamSheet.duplicateSongRows(in: rows)
            guard !found.isEmpty else {
                duplicateSongs = found
                return nil
            }
            let layout = SongLayout(header: rows.first ?? [])
            let width = max(rows.first?.count ?? 0, layout.width)
            let last = TeamSheet.columnLetter(width - 1)
            let orderColumn = TeamSheet.columnLetter(layout.order)

            var updates: [(range: String, rows: [[String]])] = found.rows.map {
                ("\(TeamSheet.songsTab)!A\($0):\(last)\($0)",
                 [[String](repeating: "", count: width)])
            }
            updates += found.renumber.map {
                ("\(TeamSheet.songsTab)!\(orderColumn)\($0.row)", [[String($0.order)]])
            }
            try await client.batchWrite(sheetId: sheetId, updates: updates)

            adoptSongRows(try await rawSongRows(sheetId: sheetId))
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 정리하지 못했습니다."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Video titles to song titles

    /// Songs' titles from the videos' titles, the recording in 참고버전, and
    /// the attachments renamed to match. See SongTitleTidy.
    ///
    /// Only from a button: it rearranges the team's own document. First the
    /// columns — Key and Transpose beside Title, a 참고버전 column after
    /// them — by Sheets' own move and insert, which carry every row's cells
    /// along; then single cells, never whole rows, worked out from a fresh
    /// read made after the columns moved.
    func tidySongTitles(sheetId: String, channels: [String: String]) async -> String? {
        #if DEBUG
        if isSample { return "샘플 모드에서는 시트를 바꾸지 않습니다." }
        #endif
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        do {
            // Row numbers below count from a header on the first row, as
            // every other write here does; a tab laid out otherwise is not
            // guessed at.
            for tab in [TeamSheet.songsTab, TeamSheet.attachmentsTab] {
                let raw = (try? await client.read(sheetId: sheetId, range: tab)) ?? []
                if let index = TeamSheet.headerIndex(raw, tab: tab), index != 0 {
                    return "\(tab) 탭의 머리글이 첫 줄에 있지 않아 정리하지 않았습니다."
                }
            }

            var songs = try await rawSongRows(sheetId: sheetId)
            if let header = songs.first, let layout = SongTitleTidy.layout(header: header) {
                guard let gid = try await client.tabGid(sheetId: sheetId, title: TeamSheet.songsTab) else {
                    return "Songs 탭을 찾지 못했습니다."
                }
                var requests: [[String: Any]] = []
                if let move = layout.move, let title = TeamSheet.column(header, ["title", "곡", "곡명", "찬양"]) {
                    requests.append(["moveDimension": [
                        "source": ["sheetId": gid, "dimension": "COLUMNS",
                                   "startIndex": move.lowerBound, "endIndex": move.upperBound],
                        "destinationIndex": title + 1
                    ]])
                }
                requests.append(["insertDimension": [
                    "range": ["sheetId": gid, "dimension": "COLUMNS",
                              "startIndex": layout.insertReferenceAt, "endIndex": layout.insertReferenceAt + 1],
                    "inheritFromBefore": true
                ]])
                try await client.formatUpdate(sheetId: sheetId, requests: requests)
                let cell = "\(TeamSheet.songsTab)!\(TeamSheet.columnLetter(layout.insertReferenceAt))1"
                try await client.write(sheetId: sheetId, range: "\(cell):\(cell)", row: ["참고버전"])
                songs = try await rawSongRows(sheetId: sheetId)
            }

            let attachments = try? await client.readTable(sheetId: sheetId, tab: TeamSheet.attachmentsTab)
            let plan = SongTitleTidy.plan(songs: songs, attachments: attachments, channels: channels)
            var updates: [(range: String, rows: [[String]])] = plan.songs.map {
                let cell = "\(TeamSheet.columnLetter($0.column))\($0.row)"
                return ("\(TeamSheet.songsTab)!\(cell):\(cell)", [[$0.value]])
            }
            updates += plan.attachments.map {
                let cell = "\(TeamSheet.columnLetter($0.column))\($0.row)"
                return ("\(TeamSheet.attachmentsTab)!\(cell):\(cell)", [[$0.value]])
            }
            if !updates.isEmpty { try await client.batchWrite(sheetId: sheetId, updates: updates) }
            await load(sheetId: sheetId)
            return nil
        } catch SheetsClient.SheetsError.http(403, _) {
            isReadOnly = true
            return "이 시트에 편집 권한이 없어 정리하지 못했습니다."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Rows written in the wrong columns

    /// Moves every shifted row back into place.
    ///
    /// Only ever run from a button. It rewrites the team's own document,
    /// and a person should see the count and choose — but the data in those
    /// rows is correct, only misplaced, so the fix is a move and nothing is
    /// guessed. The full original width is written so the stray cells at
    /// the far right are cleared rather than left behind as a second copy.
    func repairDamagedSongRows(sheetId: String) async -> String? {
        guard let client else { return "시트에 연결되어 있지 않습니다." }
        do {
            let rows = try await rawSongRows(sheetId: sheetId)
            let damaged = TeamSheet.shiftedRows(in: rows)
            let headerWidth = rows.first?.count ?? 8
            for item in damaged {
                let width = max(rows[item.row - 1].count, headerWidth)
                let cells = item.repaired
                    + [String](repeating: "", count: max(0, width - item.repaired.count))
                try await client.write(
                    sheetId: sheetId,
                    range: "\(TeamSheet.songsTab)!A\(item.row):\(TeamSheet.columnLetter(width - 1))\(item.row)",
                    row: cells
                )
            }
            // Re-checked as a whole: moving rows back can reveal copies
            // that were hidden while they sat in the wrong columns.
            adoptSongRows(try await rawSongRows(sheetId: sheetId))
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The Songs tab exactly as it stands, so a push knows which rows to
    /// rewrite rather than guessing from the parsed view.
    func rawSongRows(sheetId: String) async throws -> [[String]] {
        guard let client else { throw SheetsClient.SheetsError.noSheet }
        return try await client.readTable(sheetId: sheetId, tab: TeamSheet.songsTab)
    }

    // MARK: - Parsing

    static func parseRoles(_ rows: [[String]]) -> [TeamRole] {
        // By header name, like every other tab: a Roles tab laid out
        // Order · Name · Active would otherwise read its numbers as parts.
        let header = rows.first ?? []
        let nameCol = TeamSheet.column(header, ["name", "role", "파트", "역할", "이름"]) ?? TeamSheet.Roles.name
        let orderCol = TeamSheet.column(header, ["order", "순서"]) ?? TeamSheet.Roles.order
        let activeCol = TeamSheet.column(header, ["active", "사용", "활성"]) ?? TeamSheet.Roles.active
        return rows.dropFirst().compactMap { row in
            guard row.count > nameCol else { return nil }
            let name = row[nameCol].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let active = row.count > activeCol ? row[activeCol].lowercased() : "true"
            guard !["false", "no", "n", "0"].contains(active) else { return nil }
            let order = row.count > orderCol ? Double(row[orderCol]) ?? 0 : 0
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

            let orderCell = cell(orderCol)
            var song = TeamSong(
                    order: Int(orderCell ?? "") ?? (out[Calendar.current.startOfDay(for: date)]?.count ?? 0) + 1,
                    title: title,
                    url: cell(urlCol).flatMap(URL.init(string:)),
                    key: playedKey ?? cell(keyCol),
                    transpose: semitones,
                    notes: cell(notesCol),
                    // +1: the loop is over every row including the header,
                    // and sheets count from 1.
                    row: offset + 1
                )
            // A label kept, not lost to a number: 「헌금찬양」 marks the
            // offering song.
            if let orderCell, Int(orderCell) == nil { song.orderLabel = orderCell }
            out[Calendar.current.startOfDay(for: date), default: []].append(song)
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
            // By the tab's own column names: this team's Members tab is
            // Name · Email · Active, and the fixed Email · Name · Active
            // order put the address in the Name column.
            let header = (try? await client.readTable(sheetId: sheetId, tab: TeamSheet.membersTab))?.first ?? []
            let cells = header.isEmpty ? [address, name, "TRUE"] : TeamSheet.place([
                (["email", "이메일", "메일"], address), (["name", "이름"], name), (["active", "사용", "활성"], "TRUE")
            ], header: header)
            let row = try await client.append(
                sheetId: sheetId, tab: TeamSheet.membersTab, row: cells
            )
            members.append(Member(email: address, name: name, isActive: true, row: row ?? 0))
            if !address.isEmpty { memberEmails.insert(address) }
            // Their column on the 응답 tab too: without it a new member has
            // nowhere to answer on the sheet.
            if usesGrid, let header = rawGrid?.first, !name.isEmpty,
               AvailabilityGrid.Layout(header: header)?.column(for: name) == nil {
                let at = "\(TeamSheet.columnLetter(header.count))1"
                try await client.write(sheetId: sheetId, range: "\(AvailabilityGrid.tab)!\(at):\(at)", row: [name])
                rawGrid?[0].append(name)
            }
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
            // Only the Active cell, found by name, and only on a row that is
            // still this person's.
            let table = try await client.readTable(sheetId: sheetId, tab: TeamSheet.membersTab)
            guard let header = table.first,
                  let column = TeamSheet.column(header, ["active", "사용", "활성"]) else {
                errorMessage = "Members 탭에 Active 열이 없습니다."
                return
            }
            guard table.indices.contains(member.row - 1),
                  TeamSheet.row(table[member.row - 1], holds: [member.email]) else {
                await load(sheetId: sheetId)
                errorMessage = Self.sheetMovedMessage
                return
            }
            try await client.write(
                sheetId: sheetId,
                range: "\(TeamSheet.membersTab)!\(TeamSheet.columnLetter(column))\(member.row)",
                row: [active ? "TRUE" : "FALSE"]
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
              let rows = try? await client.readTable(sheetId: sheetId, tab: TeamSheet.liveTab)
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

        do {
            let header = (try? await client.readTable(sheetId: sheetId, tab: TeamSheet.liveTab))?.first ?? []
            let row = header.isEmpty
                ? [TeamSheet.dateFormatter.string(from: service.date), String(order),
                   ISO8601DateFormatter().string(from: Date()), name]
                : TeamSheet.place([
                    (["date", "날짜"], TeamSheet.dateFormatter.string(from: service.date)),
                    (["currentorder", "order", "현재순서"], String(order)),
                    (["updatedat", "updated", "시각"], ISO8601DateFormatter().string(from: Date())),
                    (["updatedby", "by", "진행"], name)
                ], header: header)
            if let existing = liveRows[day], existing >= 2,
               await confirm(TeamSheet.liveTab, row: existing, holds: [dateText(service)],
                             sheetId: sheetId, client: client) {
                try await client.write(
                    sheetId: sheetId,
                    range: "\(TeamSheet.liveTab)!A\(existing):\(TeamSheet.columnLetter(max(row.count, 1) - 1))\(existing)",
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
        /// Past Z as well: a tab whose header runs to AA was written into
        /// A…Z with one value too many, which Sheets refuses.
        var lastColumnLetter: String { TeamSheet.columnLetter(max(width - 1, 0)) }
    }

    private(set) var signupLayout = SignupLayout(header: [])

    /// The Songs tab's own column order, for the same reason.
    struct SongLayout {
        var date = 0, order = 1, title = 2, url = 3, key = 4, transpose = 5, notes = 6
        /// 참고버전: which recording the song was taken from. Nil on a sheet
        /// without the column — nothing is written there then.
        var reference: Int?
        var width = 7


        init(header: [String]) {
            guard !header.isEmpty else { return }
            width = max(header.count, 7)
            date = TeamSheet.column(header, ["date", "날짜"]) ?? 0
            order = TeamSheet.column(header, ["order", "순서", "#"]) ?? 1
            title = TeamSheet.column(header, ["title", "곡", "곡명", "찬양"]) ?? 2
            url = TeamSheet.column(header, ["youtubeurl", "url", "link", "링크", "영상"]) ?? 3
            key = TeamSheet.column(header, ["key", "키", "원키", "원곡키"]) ?? 4
            transpose = TeamSheet.column(header, ["transpose", "연주키", "조옮김"]) ?? 5
            notes = TeamSheet.column(header, ["notes", "note", "비고", "메모"]) ?? 6
            reference = TeamSheet.column(header, TeamSheet.referenceColumnNames)
        }

        func row(date: String, order: String, title: String, url: String,
                 key: String, transpose: String, notes: String,
                 reference: String? = nil,
                 existing: [String]?) -> [String] {
            var cells = existing ?? [String](repeating: "", count: width)
            while cells.count < width { cells.append("") }
            func put(_ index: Int, _ value: String) {
                if cells.indices.contains(index) { cells[index] = value }
            }
            put(self.date, date); put(self.order, order); put(self.title, title)
            put(self.url, url); put(self.key, key)
            put(self.transpose, transpose); put(self.notes, notes)
            // Only filled, never cleared: a leader's own note there stays.
            if let column = self.reference, let reference, !reference.isEmpty,
               cells.indices.contains(column), cells[column].trimmingCharacters(in: .whitespaces).isEmpty {
                cells[column] = reference
            }
            return cells
        }

        /// Past Z as well: a tab whose header runs to AA was written into
        /// A…Z with one value too many, which Sheets refuses.
        var lastColumnLetter: String { TeamSheet.columnLetter(max(width - 1, 0)) }
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
