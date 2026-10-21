//
//  WeekTab.swift
//  SolaPraise
//
//  The 이번 주 tab: the next service on one screen of the sheet — when, the
//  콘티, who plays what, and each song with its key, notes, the team's memo,
//  the video and the chart chosen for it — written as formulas, so it moves
//  on to the next service by itself every week, with or without the app.
//
//  WHY: a member without the app had five tabs to cross-read to know what
//  Sunday looks like. This is the one page to open. The app writes it once
//  (워크플로 점검); after that it is the sheet's own.
//
//  The formulas name the columns where the team's own headers put them, so
//  a sheet laid out differently still reads right. Pure, so the formulas
//  are checked without a network (Tools/check-week-tab.swift).
//

import Foundation

enum WeekTab {

    static let tab = "이번 주"

    struct Sources {
        /// Header rows as read: Schedule, Songs, and Attachments when the
        /// sheet has it.
        var schedule: [String]
        var songs: [String]
        var attachments: [String]?
        /// The 곡 메모 tab exists.
        var memos: Bool
    }

    /// One column of a tab from row 2 down: 「Songs!$D$2:$D」.
    private static func column(_ tab: String, _ index: Int) -> String {
        let letter = TeamSheet.columnLetter(index)
        let name = tab.contains(" ") ? "'\(tab)'" : tab
        return "\(name)!$\(letter)$2:$\(letter)"
    }

    /// The tab's cells, row by row from A1, formulas as typed.
    static func cells(_ s: Sources) -> [[String]]? {
        guard let sDate = TeamSheet.column(s.schedule, ["date", "날짜"]),
              let gDate = TeamSheet.column(s.songs, ["date", "날짜"]),
              let gTitle = TeamSheet.column(s.songs, ["title", "곡", "곡명", "찬양"]) else { return nil }
        let schedule = TeamSheet.scheduleTab, songs = TeamSheet.songsTab
        let when = column(schedule, sDate)
        let sTitle = TeamSheet.column(s.schedule, ["title", "service", "구분", "type", "예배", "행사", "예배명"])
        let sTime = TeamSheet.column(s.schedule, ["time", "시간"])
        let reserved = Set([sDate, sTitle, sTime,
                            TeamSheet.column(s.schedule, ["location", "장소"]),
                            TeamSheet.column(s.schedule, TeamSheet.playlistColumnNames)].compactMap { $0 })
        let parts = s.schedule.enumerated().filter { index, name in
            !reserved.contains(index) && !name.trimmingCharacters(in: .whitespaces).isEmpty
        }.map(\.offset)

        func first(_ tab: String, _ index: Int?) -> String {
            guard let index else { return "\"\"" }
            return "IFERROR(INDEX(FILTER(\(column(tab, index)), \(when)=$B$1), 1), \"\")"
        }

        var rows: [[String]] = []
        // When.
        rows.append(["다음 예배",
                     "=IFERROR(MINIFS(\(when), \(when), \">=\"&TODAY()), \"\")",
                     "=" + first(schedule, sTitle),
                     sTime.map { "=IFERROR(TEXT(INDEX(FILTER(\(column(schedule, $0)), \(when)=$B$1), 1), \"h:mm AM/PM\"), \"\")" } ?? ""])

        // The 콘티 file: the service's newest attachment without a song.
        let attachments = TeamSheet.attachmentsTab
        let aDate = s.attachments.flatMap { TeamSheet.column($0, ["date", "날짜"]) }
        let aSong = s.attachments.flatMap { TeamSheet.column($0, ["song", "곡", "찬양"]) }
        let aURL = s.attachments.flatMap { TeamSheet.column($0, ["url", "link", "링크"]) }
        let aConti = s.attachments.flatMap { TeamSheet.column($0, ["콘티", "conti", "use"]) }
        if let aDate, let aSong, let aURL {
            rows.append(["콘티 PDF", "=IFERROR(LET(v, FILTER(\(column(attachments, aURL)), \(column(attachments, aDate))=$B$1, \(column(attachments, aSong))=\"\"), INDEX(v, ROWS(v))), \"\")"])
        }
        rows.append([])

        // Who plays what — the part as Schedule names it.
        rows.append(["파트", "맡은 사람"])
        for index in parts {
            rows.append([s.schedule[index].trimmingCharacters(in: .whitespaces), "=" + first(schedule, index)])
        }
        rows.append([])

        // The songs, in the 순서's order.
        let gOrder = TeamSheet.column(s.songs, ["order", "순서", "#"])
        let gKey = TeamSheet.column(s.songs, ["key", "키", "원키"])
        let gPlayed = TeamSheet.column(s.songs, ["transpose", "연주키", "조옮김"])
        let gNotes = TeamSheet.column(s.songs, ["notes", "note", "비고", "메모"])
        let gURL = TeamSheet.column(s.songs, ["youtubeurl", "url", "link", "링크", "영상"])
        let byDate = "\(column(songs, gDate))=$B$1"
        func spill(_ index: Int?) -> String {
            guard let index else { return "" }
            return "=IFERROR(FILTER(\(column(songs, index)), \(byDate)), \"\")"
        }
        rows.append(["순서", "곡", "키", "연주키", "메모", "팀 메모", "영상", "악보"])
        let top = rows.count + 1
        let titles = "B\(top):B\(top + 39)"
        let memo = s.memos
            ? "=MAP(\(titles), LAMBDA(t, IF(t=\"\", \"\", IFERROR(VLOOKUP(t, '\(SongMemos.tab)'!$A:$B, 2, FALSE), \"\"))))"
            : ""
        var chart = ""
        if let aDate, let aSong, let aURL {
            let url = column(attachments, aURL), day = column(attachments, aDate), song = column(attachments, aSong)
            let all = "FILTER(\(url), \(day)=$B$1, \(song)=t)"
            let marked = aConti.map { "FILTER(\(url), \(day)=$B$1, \(song)=t, \(column(attachments, $0))<>\"\")" }
            // The chart marked ✓ for the 콘티, else the newest one put up.
            let newest = "IFERROR(LET(v, \(all), INDEX(v, ROWS(v))), \"\")"
            let pick = marked.map { "IFERROR(INDEX(\($0), 1), \(newest))" } ?? newest
            chart = "=MAP(\(titles), LAMBDA(t, IF(t=\"\", \"\", \(pick))))"
        }
        rows.append([spill(gOrder), spill(gTitle), spill(gKey), spill(gPlayed), spill(gNotes), memo, spill(gURL), chart])
        return rows
    }

    /// The tab's look: headings bold, the date shown as a date, a note on
    /// what this is, and a warning before anyone types over a formula.
    static func formatRequests(gid: Int, rows: Int) -> [[String: Any]] {
        [
            ["repeatCell": [
                "range": ["sheetId": gid, "startRowIndex": 0, "endRowIndex": 1, "startColumnIndex": 1, "endColumnIndex": 2],
                "cell": ["userEnteredFormat": ["numberFormat": ["type": "DATE", "pattern": "yyyy-mm-dd (ddd)"],
                                               "textFormat": ["bold": true]]],
                "fields": "userEnteredFormat(numberFormat,textFormat.bold)"]],
            ["repeatCell": [
                "range": ["sheetId": gid, "startColumnIndex": 0, "endColumnIndex": 1],
                "cell": ["userEnteredFormat": ["textFormat": ["bold": true]]],
                "fields": "userEnteredFormat.textFormat.bold"]],
            ["updateCells": [
                "range": ["sheetId": gid, "startRowIndex": 0, "endRowIndex": 1, "startColumnIndex": 0, "endColumnIndex": 1],
                "rows": [["values": [["note": "이 탭은 수식으로 다른 탭에서 다음 예배를 모아 보여 줍니다. 여기서 고치지 말고 Schedule · Songs · 곡 메모 탭에서 고치세요."]]]],
                "fields": "note"]],
            ["addProtectedRange": ["protectedRange": [
                "range": ["sheetId": gid],
                "description": "이번 주 — 수식으로 채워지는 탭",
                "warningOnly": true]]],
            ["updateDimensionProperties": [
                "range": ["sheetId": gid, "dimension": "COLUMNS", "startIndex": 1, "endIndex": 2],
                "properties": ["pixelSize": 220], "fields": "pixelSize"]],
            ["updateDimensionProperties": [
                "range": ["sheetId": gid, "dimension": "COLUMNS", "startIndex": 4, "endIndex": 6],
                "properties": ["pixelSize": 200], "fields": "pixelSize"]],
        ]
    }
}
