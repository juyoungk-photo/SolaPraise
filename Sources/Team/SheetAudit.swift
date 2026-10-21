//
//  SheetAudit.swift
//  SolaPraise
//
//  워크플로 점검: is the team's setup in a state where things will work?
//
//  WHY THIS EXISTS: every serious bug in 예배 준비 so far was silent. Songs
//  written two columns right vanished from the 콘티. One video went in seven
//  times because nothing said the first add had worked. Membership was
//  judged by the YouTube account while answers were filed under the church
//  account. A failed church-sheet read looked like an empty week. None of
//  them threw; each looked like "no data yet" until the user noticed.
//
//  This turns those failure SHAPES into checks that run on every load, so
//  the next one is reported by the app rather than found on a Sunday. It
//  reads only what the app has already loaded and writes nothing.
//
//  Pure Foundation over raw rows, so it runs the same in the app and in
//  Tools/check-sheet-audit.swift, which holds a fixture for every case.
//  WHEN A NEW KIND OF BUG IS FOUND, ADD ITS SHAPE HERE AND A FIXTURE THERE.
//

import Foundation

enum SheetAudit {

    enum Severity: Int, Comparable {
        case ok, note, warning, problem
        static func < (l: Severity, r: Severity) -> Bool { l.rawValue < r.rawValue }
    }

    /// What can be done about a finding from inside the app.
    enum Fix: Equatable {
        case repairShiftedRows
        case repairDuplicates
        case tidySongTitles
        case connectChurchAccount
        case signInMain
    }

    struct Finding: Identifiable, Equatable {
        /// Stable, so a test can ask for a check by name.
        let id: String
        let severity: Severity
        let area: String
        let title: String
        var detail: String = ""
        var fix: Fix? = nil
    }

    /// Who is signed in as what. See the accounts memory: the YouTube
    /// sign-in and the church account are different people as far as the
    /// sheet is concerned, and checks must use the one that ACTS.
    struct Accounts: Equatable {
        var mainEmail: String?
        var mainHasYouTube = false
        var churchEmail: String?
        var churchSheetConfigured = false
        var churchSheetProblem: String?

        /// Whoever writes answers and attachments: the church account when
        /// connected, otherwise the main sign-in. TeamStore.actingEmail.
        var acting: String? { churchEmail ?? mainEmail }
    }

    struct Input {
        var schedule: [[String]]?
        var songs: [[String]]?
        var signups: [[String]]?
        var members: [[String]]?
        var plan: [[String]]?
        /// The Attachments tab, when there is one.
        var attachments: [[String]]? = nil
        /// The 응답 tab, when there is one (AvailabilityGrid).
        var grid: [[String]]? = nil
        var accounts = Accounts()
        /// False for a read from outside the app (Tools/audit-live-sheet),
        /// which has no sign-in to judge.
        var checksAccounts = true
        var today = Date()
    }

    static func run(_ input: Input) -> [Finding] {
        var out: [Finding] = []
        let roster = rosterEmails(input.members)
        if input.checksAccounts { out += accounts(input.accounts, roster: roster) }
        out += structure(input)
        if let songs = input.songs {
            out += songsTab(songs)
            out += songTitles(songs, attachments: input.attachments)
        }
        if let schedule = input.schedule { out += scheduleTab(schedule, today: input.today) }
        if let signups = input.signups { out += signupsTab(signups, roster: roster) }
        if let members = input.members { out += membersTab(members, grid: input.grid != nil) }
        if let grid = input.grid { out += gridTab(grid, schedule: input.schedule, members: input.members, today: input.today) }
        if let plan = input.plan, plan.count > 1 { out += undatedRows(plan, tab: "Plan", id: "plan.undated") }
        return out.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.id < $1.id }
    }

    /// Problems and warnings — what the pinned line counts.
    static func needsAttention(_ findings: [Finding]) -> [Finding] {
        findings.filter { $0.severity >= .warning }
    }

    // MARK: - Accounts

    private static func accounts(_ a: Accounts, roster: Set<String>) -> [Finding] {
        var out: [Finding] = []
        let area = "계정"

        if a.mainEmail == nil {
            out.append(.init(id: "account.noMain", severity: .warning, area: area,
                             title: "YouTube 계정으로 로그인되어 있지 않습니다",
                             detail: "재생목록 만들기와 내 재생목록은 로그인해야 쓸 수 있습니다.",
                             fix: .signInMain))
        } else if !a.mainHasYouTube {
            out.append(.init(id: "account.noYouTubeScope", severity: .warning, area: area,
                             title: "YouTube 권한이 없습니다",
                             detail: "로그인은 되어 있지만 YouTube 권한이 빠져 있어 재생목록을 만들 수 없습니다.",
                             fix: .signInMain))
        }

        guard let acting = a.acting?.lowercased() else {
            out.append(.init(id: "account.noActing", severity: .problem, area: area,
                             title: "응답할 계정이 없습니다",
                             detail: "로그인하거나 교회 계정을 연결해야 응답·첨부를 할 수 있습니다.",
                             fix: .connectChurchAccount))
            return out
        }

        if roster.isEmpty {
            out.append(.init(id: "account.noRoster", severity: .note, area: area,
                             title: "Members 탭이 없어 명단 확인을 건너뜁니다"))
        } else if roster.contains(acting) {
            out.append(.init(id: "account.actingListed", severity: .ok, area: area,
                             title: "응답 계정이 명단에 있습니다",
                             detail: "\(acting) 로 응답·첨부가 기록됩니다."))
        } else if a.churchEmail == nil,
                  let main = a.mainEmail?.lowercased(), !roster.contains(main) {
            // The exact mismatch this app has shipped before: the YouTube
            // address is not the one on the roster, and the church account
            // that IS on it was never connected.
            out.append(.init(id: "account.connectChurch", severity: .problem, area: area,
                             title: "명단에 없는 YouTube 계정으로 응답하고 있습니다",
                             detail: "\(main) 은 Members 탭에 없습니다. 명단에 있는 교회 계정을 연결하면 그 주소로 응답이 기록됩니다.",
                             fix: .connectChurchAccount))
        } else {
            out.append(.init(id: "account.actingNotListed", severity: .problem, area: area,
                             title: "응답 계정이 명단에 없습니다",
                             detail: "\(acting) 로 기록되는 응답은 명단의 누구와도 이어지지 않아, 그 사람은 계속 미응답으로 보입니다."))
        }

        if a.churchSheetConfigured, let problem = a.churchSheetProblem {
            out.append(.init(id: "account.churchSheet", severity: .warning, area: area,
                             title: "교회 정보 시트를 읽지 못했습니다", detail: problem,
                             fix: a.churchEmail == nil ? .connectChurchAccount : nil))
        }
        return out
    }

    // MARK: - Structure

    private static func structure(_ input: Input) -> [Finding] {
        var out: [Finding] = []
        var required: [(String, [[String]]?, [[String]])] = [
            ("Schedule", input.schedule, [["date", "날짜"]]),
            ("Songs", input.songs, [["date", "날짜"], ["title", "곡", "곡명", "찬양"]]),
        ]
        // Answers come from the 응답 tab when the sheet has one; Signups is
        // then history, and its absence is no fault. Without either, there
        // is nowhere to answer.
        if input.grid == nil {
            required.append(("Signups", input.signups, [["date", "날짜"], ["role", "파트", "역할"],
                                                        ["memberemail", "email", "이메일"], ["status", "상태", "응답"]]))
        }
        for (tab, rows, headers) in required {
            guard let rows, let header = rows.first else {
                out.append(.init(id: "structure.missing.\(tab)", severity: .problem, area: "시트 구조",
                                 title: "\(tab) 탭이 없거나 비어 있습니다"))
                continue
            }
            let missing = headers.filter { TeamSheet.column(header, $0) == nil }.map { $0[0] }
            if !missing.isEmpty {
                // The parsers fall back to fixed positions, which is right
                // only for a sheet laid out exactly as the template was.
                out.append(.init(id: "structure.header.\(tab)", severity: .warning, area: "시트 구조",
                                 title: "\(tab) 탭에서 열 이름을 찾지 못했습니다",
                                 detail: "\(missing.joined(separator: ", ")) — 기본 위치로 읽고 있어, 열 순서가 다르면 엉뚱한 칸을 읽습니다."))
            }
        }
        // Attachments is optional — created on the first upload — but a tab
        // of that name whose header cannot be found makes every upload fail.
        if let rows = input.attachments,
           rows.contains(where: { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }),
           TeamSheet.headerIndex(rows, tab: TeamSheet.attachmentsTab) == nil {
            out.append(.init(id: "structure.header.Attachments", severity: .problem, area: "시트 구조",
                             title: "Attachments 탭의 머리글을 찾을 수 없습니다",
                             detail: "Date · Song · Name · FileId · URL 머리글이 맨 위 15줄 안에 있어야 악보를 첨부할 수 있습니다."))
        }
        return out
    }

    // MARK: - Songs

    /// Songs entered under a video's title — 「[4k] 곡 (Solo. 이름) - 팀 |
    /// ep.3」 — and the charts filed under it. Not wrong, so only a note;
    /// but the 콘티 reads as a list of uploads. See SongTitleTidy.
    private static func songTitles(_ songs: [[String]], attachments: [[String]]?) -> [Finding] {
        let plan = SongTitleTidy.plan(songs: songs, attachments: attachments)
        let files = Set(plan.attachments.map(\.row)).count
        guard plan.titles > 0 || files > 0 else { return [] }
        var detail = "Title에는 곡 제목만 남기고, 팀·앨범·연도는 「참고버전」 열로 옮깁니다."
        if files > 0 { detail += " 첨부 \(files)개의 곡 이름과 파일 이름도 맞춥니다." }
        if let header = songs.first, let layout = SongTitleTidy.layout(header: header) {
            detail += layout.move != nil
                ? " Key·Transpose를 Title 바로 옆으로 옮기고 참고버전 열을 더합니다."
                : " 참고버전 열을 더합니다."
        }
        return [.init(id: "songs.videoTitles", severity: .note, area: "Songs 탭",
                      title: plan.titles > 0 ? "영상 제목이 그대로인 곡 \(plan.titles)개" : "영상 제목이 그대로인 첨부 \(files)개",
                      detail: detail, fix: .tidySongTitles)]
    }

    private static func songsTab(_ rows: [[String]]) -> [Finding] {
        var out: [Finding] = []
        let area = "Songs 탭"

        let shifted = TeamSheet.shiftedRows(in: rows)
        if !shifted.isEmpty {
            out.append(.init(id: "songs.shifted", severity: .problem, area: area,
                             title: "칸이 밀린 줄 \(shifted.count)개",
                             detail: "\(list(shifted.map(\.row)))번 줄은 콘티에 보이지 않습니다.",
                             fix: .repairShiftedRows))
        }

        let duplicates = TeamSheet.duplicateSongRows(in: rows)
        if !duplicates.isEmpty {
            out.append(.init(id: "songs.duplicates", severity: .warning, area: area,
                             title: "같은 곡이 두 번 이상 들어간 줄 \(duplicates.rows.count)개",
                             detail: "\(list(duplicates.rows))번 줄.",
                             fix: .repairDuplicates))
        }

        out += undatedRows(rows, tab: "Songs", id: "songs.undated", ignoringShifted: shifted.map(\.row))

        // Two songs claiming one place in the order: the 콘티 shows them,
        // but which plays first is a coin toss.
        if let header = rows.first {
            let dateColumn = TeamSheet.column(header, ["date", "날짜"]) ?? 0
            let orderColumn = TeamSheet.column(header, ["order", "순서", "#"]) ?? 1
            var seen: [String: Int] = [:]
            var clashes: [String] = []
            for (offset, cells) in rows.enumerated() where offset > 0 {
                guard let date = TeamSheet.day(cell(cells, dateColumn)),
                      let order = Int(cell(cells, orderColumn)) else { continue }
                let key = TeamSheet.dateFormatter.string(from: date) + "#\(order)"
                if let first = seen[key] { clashes.append("\(first)·\(offset + 1)") }
                else { seen[key] = offset + 1 }
            }
            if !clashes.isEmpty {
                out.append(.init(id: "songs.orderClash", severity: .warning, area: area,
                                 title: "순서 번호가 겹치는 곡 \(clashes.count)쌍",
                                 detail: "\(clashes.prefix(6).joined(separator: ", "))번 줄. 예배 준비의 「순서 바꾸기」로 다시 매기세요."))
            }
        }

        // Blank lines between songs are harmless to this version, and were
        // the precondition for the column drift in older ones: Google's
        // append guessed the table from them. Worth knowing while any older
        // build may still be installed somewhere.
        let blanks = blankRowsBetweenData(rows)
        if !blanks.isEmpty {
            out.append(.init(id: "songs.blankRows", severity: .note, area: area,
                             title: "중간에 빈 줄 \(blanks.count)개",
                             detail: "\(list(blanks))번 줄. 이 버전에는 문제가 없지만, 예전 버전 앱이 남아 있다면 그 앱의 추가가 칸이 밀릴 수 있습니다."))
        }

        if out.isEmpty {
            out.append(.init(id: "songs.ok", severity: .ok, area: area,
                             title: "칸 밀림·중복·날짜 문제 없음"))
        }
        return out
    }

    // MARK: - Schedule

    private static func scheduleTab(_ rows: [[String]], today: Date) -> [Finding] {
        var out = undatedRows(rows, tab: "Schedule", id: "schedule.undated")
        guard let header = rows.first else { return out }
        let dateColumn = TeamSheet.column(header, ["date", "날짜"]) ?? 0
        let titleColumn = TeamSheet.column(header, ["title", "service", "구분", "type", "예배", "행사", "예배명"])

        var seen: [String: Int] = [:]
        var repeats: [Int] = []
        var upcoming = 0
        let start = Calendar.current.startOfDay(for: today)
        for (offset, cells) in rows.enumerated() where offset > 0 {
            guard let date = TeamSheet.day(cell(cells, dateColumn)) else { continue }
            if date >= start { upcoming += 1 }
            let key = TeamSheet.dateFormatter.string(from: date) + "|" + cell(cells, titleColumn).lowercased()
            if seen[key] != nil { repeats.append(offset + 1) } else { seen[key] = offset + 1 }
        }
        // A service at 12:30 AM: a time typed as 12:30, which Sheets reads
        // as half past midnight. Every service on the live sheet said so,
        // and the 순서's clock started from it.
        if let timeColumn = TeamSheet.column(header, ["time", "시간"]) {
            let night = rows.enumerated().filter { offset, cells in
                guard offset > 0, TeamSheet.day(cell(cells, dateColumn)) != nil,
                      let time = TeamSheet.timeFormatter.date(from: cell(cells, timeColumn)) else { return false }
                return Calendar.current.component(.hour, from: time) < 5
            }.map { $0.offset + 1 }
            if !night.isEmpty {
                out.append(.init(id: "schedule.nightTime", severity: .warning, area: "Schedule 탭",
                                 title: "예배 시간이 한밤중으로 적혀 있습니다",
                                 detail: "\(list(night))번 줄. 「12:30 AM」은 자정 30분입니다 — 낮 12시 30분이면 12:30 PM, 오전 11시 30분이면 11:30 AM으로 고쳐 주세요. 예배 순서의 시각이 이 시간에서 시작합니다."))
            }
        }
        if !repeats.isEmpty {
            out.append(.init(id: "schedule.repeats", severity: .warning, area: "Schedule 탭",
                             title: "같은 날 같은 예배가 두 줄",
                             detail: "\(list(repeats))번 줄. 앱은 한 줄만 보여 주고 다른 줄의 배정은 보이지 않습니다."))
        }
        if upcoming == 0 {
            out.append(.init(id: "schedule.noUpcoming", severity: .note, area: "Schedule 탭",
                             title: "앞으로 예정된 예배가 없습니다",
                             detail: "Schedule 탭에 다음 날짜들을 추가하세요."))
        } else if out.isEmpty {
            out.append(.init(id: "schedule.ok", severity: .ok, area: "Schedule 탭",
                             title: "예정된 예배 \(upcoming)개"))
        }
        return out
    }

    // MARK: - Signups

    private static func signupsTab(_ rows: [[String]], roster: Set<String>) -> [Finding] {
        var out: [Finding] = []
        guard let header = rows.first else { return out }
        let area = "Signups 탭"
        let date = TeamSheet.column(header, ["date", "날짜"]) ?? 0
        let role = TeamSheet.column(header, ["role", "파트", "역할"]) ?? 1
        let email = TeamSheet.column(header, ["memberemail", "email", "이메일"]) ?? 2
        let status = TeamSheet.column(header, ["status", "상태", "응답"]) ?? 4

        var unknownWords: [String: [Int]] = [:]
        var strangers: [String: Int] = [:]
        var seen: Set<String> = []
        var repeats: [Int] = []
        for (offset, cells) in rows.enumerated() where offset > 0 {
            guard let day = TeamSheet.day(cell(cells, date)) else { continue }
            let word = cell(cells, status)
            if TeamSheet.signupStatus(word) == nil { unknownWords[word, default: []].append(offset + 1) }
            let address = cell(cells, email).lowercased()
            if !roster.isEmpty, !address.isEmpty, !roster.contains(address) {
                strangers[address, default: 0] += 1
            }
            let key = TeamSheet.dateFormatter.string(from: day) + "|" + cell(cells, role).lowercased() + "|" + address
            if !seen.insert(key).inserted { repeats.append(offset + 1) }
        }

        if !unknownWords.isEmpty {
            let words = unknownWords.keys.sorted().map { "「\($0)」" }.joined(separator: ", ")
            out.append(.init(id: "signups.unknownStatus", severity: .warning, area: area,
                             title: "앱이 모르는 응답 \(unknownWords.values.map(\.count).reduce(0, +))개",
                             detail: "\(words) 은 가능으로 읽힙니다. 가능·미정·어려움·자리비움 중 하나로 고치세요."))
        }
        if !strangers.isEmpty {
            out.append(.init(id: "signups.notOnRoster", severity: .warning, area: area,
                             title: "명단에 없는 주소의 응답 \(strangers.values.reduce(0, +))개",
                             detail: "\(strangers.keys.sorted().joined(separator: ", ")) — 명단의 다른 주소로 로그인한 사람의 응답일 가능성이 큽니다. 그 사람은 미응답으로 보입니다."))
        }
        if !repeats.isEmpty {
            out.append(.init(id: "signups.repeats", severity: .warning, area: area,
                             title: "같은 사람·같은 파트 응답이 여러 줄",
                             detail: "\(list(repeats))번 줄. 앱은 그중 하나만 읽습니다."))
        }
        if out.isEmpty {
            out.append(.init(id: "signups.ok", severity: .ok, area: area, title: "응답 기록 이상 없음"))
        }
        return out
    }

    // MARK: - Members

    // MARK: - 응답

    /// The 응답 tab as a member with only the sheet meets it: a column to
    /// answer in, a row for every service coming, and words the app reads.
    /// Each failure is silent — an answer under a misspelt name is nobody's,
    /// a service without a row cannot be answered at all.
    private static func gridTab(_ rows: [[String]], schedule: [[String]]?, members: [[String]]?,
                                today: Date) -> [Finding] {
        var out: [Finding] = []
        let area = "응답 탭"
        guard let header = rows.first, let layout = AvailabilityGrid.Layout(header: header) else {
            return [.init(id: "grid.noDate", severity: .problem, area: area,
                          title: "첫 줄에 「날짜」 열이 없습니다",
                          detail: "앱이 응답을 읽지 못합니다. 첫 줄을 「예배 · 날짜 · 이름들」로 두세요.")]
        }
        // The roster's names: active ones need a column; any name is a
        // known one.
        var active: [String] = [], known = Set<String>()
        if let members, let top = members.first {
            let name = TeamSheet.column(top, ["name", "이름"]) ?? 1
            let flag = TeamSheet.column(top, ["active", "사용", "활성"])
            for cells in members.dropFirst() {
                let who = cell(cells, name)
                guard !who.isEmpty else { continue }
                known.insert(who)
                if !["false", "no", "n", "0"].contains(cell(cells, flag).lowercased()) { active.append(who) }
            }
        }
        let columns = layout.members.map(\.name)
        let strangers = members == nil ? [] : columns.filter { !known.contains($0) }
        if !strangers.isEmpty {
            out.append(.init(id: "grid.unknownName", severity: .warning, area: area,
                             title: "Members 탭에 없는 이름의 열",
                             detail: "\(strangers.joined(separator: ", ")) — 이름이 Members 탭과 다르면 그 사람은 응답해도 미응답으로 보입니다. 두 탭의 이름을 똑같이 맞춰 주세요."))
        }
        let missing = active.filter { !columns.contains($0) }
        if !missing.isEmpty {
            out.append(.init(id: "grid.missingMember", severity: .warning, area: area,
                             title: "응답할 열이 없는 멤버 \(missing.count)명",
                             detail: "\(missing.joined(separator: ", ")) — 시트에서 응답할 곳이 없습니다. 위의 「응답 탭 정리」로 열을 더하세요."))
        }
        var unknown: [String] = []
        for (offset, cells) in rows.enumerated() where offset > 0 {
            for member in layout.members {
                let word = cell(cells, member.column)
                if !word.isEmpty, TeamSheet.statusWords[word.lowercased()] == nil {
                    unknown.append("\(TeamSheet.columnLetter(member.column))\(offset + 1) 「\(word)」")
                }
            }
        }
        if !unknown.isEmpty {
            out.append(.init(id: "grid.unknownWord", severity: .warning, area: area,
                             title: "앱이 모르는 응답 \(unknown.count)개",
                             detail: unknown.prefix(6).joined(separator: ", ") + " — 가능 · 미정 · 어려움 · 자리비움 중 하나로 고쳐 주세요. 이 칸은 응답으로 세지 않습니다."))
        }
        // Services coming that have no row.
        var noRow: [String] = []
        if let schedule, let top = schedule.first {
            let date = TeamSheet.column(top, ["date", "날짜"]) ?? 0
            let title = TeamSheet.column(top, ["title", "service", "구분", "type", "예배", "행사", "예배명"])
            let start = Calendar.current.startOfDay(for: today)
            let coming = schedule.dropFirst().compactMap { cells -> (day: Date, title: String)? in
                guard let day = TeamSheet.day(cell(cells, date)), day >= start else { return nil }
                return (day, cell(cells, title))
            }
            noRow = AvailabilityGrid.missingServices(coming, in: rows, from: start)
                .map { TeamSheet.dateFormatter.string(from: $0.day) }
            if !noRow.isEmpty {
                out.append(.init(id: "grid.missingService", severity: .warning, area: area,
                                 title: "응답할 줄이 없는 예정 예배 \(noRow.count)개",
                                 detail: noRow.prefix(6).joined(separator: ", ") + " — 시트에서는 이 날짜에 응답할 수 없습니다. 위의 「응답 탭 정리」로 줄을 더하세요."))
            }
        }
        if out.isEmpty {
            out.append(.init(id: "grid.ok", severity: .ok, area: area,
                             title: "멤버 \(columns.count)명이 시트에서 바로 응답할 수 있습니다"))
        }
        return out
    }

    private static func membersTab(_ rows: [[String]], grid: Bool = false) -> [Finding] {
        var out: [Finding] = []
        guard let header = rows.first else { return out }
        let email = TeamSheet.column(header, ["email", "이메일", "메일"]) ?? 0
        var seen: Set<String> = []
        var repeats: [String] = []
        var malformed: [Int] = []
        var missing: [Int] = []
        for (offset, cells) in rows.enumerated() where offset > 0 {
            guard cells.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            let address = cell(cells, email).lowercased()
            if address.isEmpty { missing.append(offset + 1); continue }
            if !address.contains("@") || address.contains(" ") { malformed.append(offset + 1) }
            if !seen.insert(address).inserted { repeats.append(address) }
        }
        if !malformed.isEmpty {
            out.append(.init(id: "members.malformed", severity: .warning, area: "Members 탭",
                             title: "주소 형식이 아닌 칸 \(malformed.count)개",
                             detail: "\(list(malformed))번 줄. 이 사람은 로그인해도 명단에 없는 것으로 나옵니다."))
        }
        if !repeats.isEmpty {
            out.append(.init(id: "members.repeats", severity: .note, area: "Members 탭",
                             title: "같은 주소가 두 번", detail: repeats.joined(separator: ", ")))
        }
        if !missing.isEmpty {
            out.append(.init(id: "members.noEmail", severity: .note, area: "Members 탭",
                             title: "주소가 없는 사람 \(missing.count)명",
                             detail: grid
                                ? "\(list(missing))번 줄. 시트의 응답 탭에서는 응답할 수 있고, 앱으로 응답하려면 로그인하는 주소가 필요합니다."
                                : "\(list(missing))번 줄. 이 사람은 앱에서 응답할 수 없습니다."))
        }
        return out
    }

    // MARK: - Shared pieces

    /// Rows with content but a date no parser can read — invisible rows.
    private static func undatedRows(_ rows: [[String]], tab: String, id: String,
                                    ignoringShifted shifted: [Int] = []) -> [Finding] {
        guard let header = rows.first else { return [] }
        let dateColumn = TeamSheet.column(header, ["date", "날짜"]) ?? 0
        var bad: [Int] = []
        for (offset, cells) in rows.enumerated() where offset > 0 {
            let row = offset + 1
            guard !shifted.contains(row),
                  cells.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            let raw = cell(cells, dateColumn)
            // An empty date is a continuation line some planners use; a
            // date that is THERE and unreadable is the silent failure.
            if !raw.isEmpty, TeamSheet.day(raw) == nil { bad.append(row) }
        }
        guard !bad.isEmpty else { return [] }
        return [.init(id: id, severity: .problem, area: "\(tab) 탭",
                      title: "날짜를 읽을 수 없는 줄 \(bad.count)개",
                      detail: "\(list(bad))번 줄은 앱에 보이지 않습니다. 날짜를 2026-10-18 이나 10/18/2026 처럼 적어 주세요.")]
    }

    private static func rosterEmails(_ members: [[String]]?) -> Set<String> {
        guard let members, let header = members.first else { return [] }
        let email = TeamSheet.column(header, ["email", "이메일", "메일"]) ?? 0
        return Set(members.dropFirst().map { cell($0, email).lowercased() }.filter { !$0.isEmpty })
    }

    private static func blankRowsBetweenData(_ rows: [[String]]) -> [Int] {
        let filled = rows.indices.filter { index in
            rows[index].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        guard let last = filled.last else { return [] }
        return (1..<last).filter { !filled.contains($0) }.map { $0 + 1 }
    }

    private static func cell(_ cells: [String], _ index: Int?) -> String {
        guard let index, cells.indices.contains(index) else { return "" }
        return cells[index].trimmingCharacters(in: .whitespaces)
    }

    private static func list(_ rows: [Int]) -> String {
        let shown = rows.prefix(8).map(String.init).joined(separator: ", ")
        return rows.count > 8 ? shown + " 외 \(rows.count - 8)개" : shown
    }
}
