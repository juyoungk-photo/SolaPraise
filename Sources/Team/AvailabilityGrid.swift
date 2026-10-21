//
//  AvailabilityGrid.swift
//  SolaPraise
//
//  The 응답 tab: who can serve when, answered on the sheet itself.
//
//      예배     | 날짜       | 주영 | 다원 | 지혜 | …
//      주일2부  | 2026-10-25 | 가능 | 미정 |      |
//      주일2부  | 2026-11-01 |      | 가능 | 어려움 |
//
//  WHY: the team must be able to answer without the app. The Signups tab
//  this replaces took one row per answer — date, part, e-mail address,
//  name, a status in English, a timestamp — which nobody types by hand,
//  so the sheet alone could not be used to answer at all. Here a member
//  finds their own column and picks from a dropdown, and everyone sees the
//  month at a glance. The app reads and writes the same cells.
//
//  A row is a service, a column a member by name — the name on the
//  Members tab, which is also how a member without an address is counted.
//  Which part a member plays is the leader's call, made on Schedule.
//
//  Pure, so it is checked without a network: Tools/check-availability-grid.swift.
//

import Foundation

enum AvailabilityGrid {

    static let tab = "응답"

    /// The words the dropdown offers, in its order.
    static let choices = ["가능", "미정", "어려움", "자리비움"]

    /// A status's word on the grid: available → 가능.
    static func word(_ status: String) -> String {
        switch status {
        case "available": return "가능"
        case "maybe": return "미정"
        case "declined": return "어려움"
        case "away": return "자리비움"
        default: return status
        }
    }

    struct Layout: Equatable {
        /// The service's name column (예배), when there is one.
        var service: Int?
        var date: Int
        /// Each member's column, by the name in its header.
        var members: [(name: String, column: Int)]

        static func == (a: Layout, b: Layout) -> Bool {
            a.service == b.service && a.date == b.date
                && a.members.map(\.name) == b.members.map(\.name)
                && a.members.map(\.column) == b.members.map(\.column)
        }

        init?(header: [String]) {
            guard let date = TeamSheet.column(header, ["날짜", "date"]) else { return nil }
            let service = TeamSheet.column(header, ["예배", "service"])
            self.date = date
            self.service = service
            members = header.enumerated().compactMap { index, raw in
                let name = raw.trimmingCharacters(in: .whitespaces)
                guard index != date, index != service, !name.isEmpty else { return nil }
                return (name, index)
            }
        }

        func column(for name: String) -> Int? {
            let key = name.trimmingCharacters(in: .whitespaces)
            return members.first { $0.name == key }?.column
        }
    }

    /// One answer on the grid.
    struct Answer: Equatable {
        let day: Date
        let service: String
        let name: String
        /// available / maybe / declined / away.
        let status: String
        /// 1-based sheet row and 0-based column, to write it back.
        let row: Int
        let column: Int
    }

    /// Every answer given. A blank cell is no answer — not 가능 — and a
    /// word the app does not know is left out (the audit says so).
    static func answers(_ rows: [[String]]) -> [Answer] {
        guard let header = rows.first, let layout = Layout(header: header) else { return [] }
        var out: [Answer] = []
        for (offset, row) in rows.enumerated() where offset > 0 {
            func cell(_ i: Int?) -> String {
                guard let i, row.indices.contains(i) else { return "" }
                return row[i].trimmingCharacters(in: .whitespaces)
            }
            guard let date = TeamSheet.day(cell(layout.date)) else { continue }
            for member in layout.members {
                let raw = cell(member.column)
                guard !raw.isEmpty, let status = TeamSheet.statusWords[raw.lowercased()] else { continue }
                out.append(Answer(day: Calendar.current.startOfDay(for: date), service: cell(layout.service),
                                  name: member.name, status: status, row: offset + 1, column: member.column))
            }
        }
        return out
    }

    /// The 1-based row for a service: by its day, and its name when the grid
    /// has a 예배 column and more than one service falls on that day.
    static func row(for day: Date, service: String, in rows: [[String]]) -> Int? {
        guard let header = rows.first, let layout = Layout(header: header) else { return nil }
        let matches = rows.enumerated().filter { offset, row in
            offset > 0 && row.indices.contains(layout.date)
                && TeamSheet.day(row[layout.date]).map { Calendar.current.isDate($0, inSameDayAs: day) } == true
        }
        if matches.count > 1, let column = layout.service,
           let named = matches.first(where: { $0.element.indices.contains(column)
                                              && sameService($0.element[column], service) }) {
            return named.offset + 1
        }
        return matches.first.map { $0.offset + 1 }
    }

    /// 「주일2부」 and 「주일 2부예배」 are one service.
    static func sameService(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            var t = s.replacingOccurrences(of: " ", with: "")
            if t.hasSuffix("예배") { t = String(t.dropLast(2)) }
            return t.lowercased()
        }
        return key(a) == key(b)
    }

    /// The whole grid made from what is known: one row per service, one
    /// column per member, each answer in its place — what 시트 정리 writes
    /// when the tab is first made, carrying the Signups answers over.
    ///
    /// - answers: by day, by member name, the status (available, …).
    static func build(services: [(day: Date, title: String)], members: [String],
                      answers: [Date: [String: String]]) -> [[String]] {
        var out = [["예배", "날짜"] + members]
        for service in services {
            let day = Calendar.current.startOfDay(for: service.day)
            let given = answers[day] ?? [:]
            out.append([service.title, TeamSheet.dateFormatter.string(from: service.day)]
                       + members.map { given[$0].map(word) ?? "" })
        }
        return out
    }

    // MARK: - Making the tab

    /// What a member reading the sheet needs to know, on the header's first
    /// cell as a note.
    static let note = """
    응답하는 법: 자기 이름 열에서, 예배 날짜마다 가능 · 미정 · 어려움 · 자리비움 중 하나를 고르세요. \
    비워 두면 아직 응답하지 않은 것입니다. 파트는 리더가 Schedule 탭에서 정합니다. \
    이름은 Members 탭의 이름과 같아야 합니다. 새 예배는 Schedule에 더하면 앱의 워크플로 점검에서 이 탭에도 줄이 생깁니다.
    """

    /// The tab's look and its dropdown, as Sheets batchUpdate requests:
    /// header frozen with the service and date beside every answer, the four
    /// words to pick from in every member's column — with room for members
    /// added later — each coloured as the app colours it, and the note.
    static func formatRequests(gid: Int, members: Int, rows: Int) -> [[String: Any]] {
        func colour(_ c: SheetTidy.Colour) -> [String: Double] { ["red": c.red, "green": c.green, "blue": c.blue] }
        let answers: [String: Any] = ["sheetId": gid, "startRowIndex": 1, "endRowIndex": max(rows, 2) + 200,
                                      "startColumnIndex": 2, "endColumnIndex": 2 + members + 20]
        var out: [[String: Any]] = [
            ["updateSheetProperties": [
                "properties": ["sheetId": gid, "gridProperties": ["frozenRowCount": 1, "frozenColumnCount": 2]],
                "fields": "gridProperties.frozenRowCount,gridProperties.frozenColumnCount"]],
            ["repeatCell": [
                "range": ["sheetId": gid, "startRowIndex": 0, "endRowIndex": 1],
                "cell": ["userEnteredFormat": ["textFormat": ["bold": true],
                                               "backgroundColor": colour(SheetTidy.headerShade),
                                               "horizontalAlignment": "CENTER"]],
                "fields": "userEnteredFormat(textFormat.bold,backgroundColor,horizontalAlignment)"]],
            ["repeatCell": [
                "range": answers,
                "cell": ["userEnteredFormat": ["horizontalAlignment": "CENTER"]],
                "fields": "userEnteredFormat.horizontalAlignment"]],
            ["setDataValidation": [
                "range": answers,
                "rule": ["condition": ["type": "ONE_OF_LIST",
                                       "values": choices.map { ["userEnteredValue": $0] }],
                         "strict": true, "showCustomUi": true,
                         "inputMessage": "가능 · 미정 · 어려움 · 자리비움 중에서 고르세요"]]],
            ["updateCells": [
                "range": ["sheetId": gid, "startRowIndex": 0, "endRowIndex": 1, "startColumnIndex": 0, "endColumnIndex": 1],
                "rows": [["values": [["note": note]]]],
                "fields": "note"]],
            ["updateDimensionProperties": [
                "range": ["sheetId": gid, "dimension": "COLUMNS", "startIndex": 2, "endIndex": 2 + members + 20],
                "properties": ["pixelSize": 72], "fields": "pixelSize"]],
        ]
        let colours: [(String, SheetTidy.Colour)] = [("가능", SheetTidy.available), ("미정", SheetTidy.maybe),
                                                      ("어려움", SheetTidy.declined), ("자리비움", SheetTidy.away)]
        for (word, shade) in colours {
            out.append(["addConditionalFormatRule": ["index": 0, "rule": [
                "ranges": [answers],
                "booleanRule": ["condition": ["type": "TEXT_EQ", "values": [["userEnteredValue": word]]],
                                "format": ["backgroundColor": colour(shade)]]]]])
        }
        return out
    }

    /// The services the grid needs a row for and does not have: from four
    /// weeks back, every one on Schedule — by day and name.
    static func missingServices(_ services: [(day: Date, title: String)], in rows: [[String]],
                                from start: Date) -> [(day: Date, title: String)] {
        services.filter { service in
            service.day >= start && row(for: service.day, service: service.title, in: rows).map { row in
                // Found by day alone, when the grid names another service
                // that day: still missing.
                guard let header = rows.first, let layout = Layout(header: header),
                      let column = layout.service, rows.indices.contains(row - 1),
                      rows[row - 1].indices.contains(column) else { return true }
                let named = rows[row - 1][column]
                return named.isEmpty || sameService(named, service.title)
            } != true
        }
    }

    // MARK: - One name for each part

    /// The team's words for each part, one per job: English, as the team
    /// writes parts — A.G. and E.G. are two guitars, which 「기타」 cannot
    /// tell apart — except 인도, which says what it means better than any
    /// English. 피아노 on Roles, 건반 on Schedule and 반주 in the app were
    /// one job in three spellings; a member reading the sheet could not tell
    /// they matched. A plain 「기타」 is the acoustic one, as Schedule has it.
    static let partNames: [(name: String, spellings: [String])] = [
        ("인도", ["인도", "인도자", "리더", "lead", "leader", "worship leader", "wl"]),
        ("Keys", ["keys", "건반", "피아노", "piano", "keyboard", "키보드", "반주", "반주자"]),
        ("A.G.", ["a.g.", "ag", "기타", "guitar", "acoustic", "acoustic guitar", "어쿠스틱", "어쿠스틱기타", "통기타"]),
        ("E.G.", ["e.g.", "eg", "electric", "electric guitar", "일렉", "일렉기타"]),
        ("Bass", ["bass", "베이스"]),
        ("Drum", ["drum", "drums", "드럼"]),
        ("Vocal", ["vocal", "vocals", "보컬", "싱어"]),
    ]

    /// The team's word for a part spelled another way; nil when it is
    /// already that word, or not a part this list knows (보컬2 stays).
    static func unifiedPart(_ raw: String) -> String? {
        let key = raw.replacingOccurrences(of: " ", with: "").lowercased()
        guard !key.isEmpty,
              let part = partNames.first(where: { $0.spellings.contains { $0.replacingOccurrences(of: " ", with: "") == key } }),
              part.name != raw.trimmingCharacters(in: .whitespaces) else { return nil }
        return part.name
    }
}
