//
//  check-week-tab.swift
//  SolaPraise
//
//  Checks the 이번 주 tab's formulas: each reads the column the team's own
//  header puts it in, on the tab it belongs to.
//
//  WHY THIS EXISTS: a formula pointing one column off shows the key where
//  the title belongs, or nothing at all — on the page the team opens
//  without the app, every week, with nobody told it is wrong.
//
//  Run:
//      swiftc -O -o /tmp/weektab \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift \
//          Sources/Feed/SongSearchSuggestions.swift Sources/Feed/PlanSongTitle.swift \
//          Sources/Team/OfferingNote.swift Sources/Team/SongMemos.swift Sources/Team/WeekTab.swift Tools/check-week-tab.swift
//      /tmp/weektab
//

import Foundation

@main
struct CheckWeekTab {
    static func main() {
        var failures = 0
        func expect(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("FAIL: \(message)") }
        }
        // As the live sheet lays them out: Service before Date on Schedule.
        let sources = WeekTab.Sources(
            schedule: ["Service", "Date", "Time", "Location", "인도", "Keys", "A.G.", "Bass"],
            songs: ["Date", "Service", "Order", "Title", "YouTubeURL", "Key", "Transpose", "Notes"],
            attachments: ["Date", "Song", "Name", "FileId", "URL", "AddedBy", "AddedAt", "Hash", "Edits", "콘티"],
            memos: true)
        guard let rows = WeekTab.cells(sources) else { print("FAIL: no cells"); exit(1) }
        let all = rows.flatMap { $0 }.joined(separator: "\n")

        expect(rows[0][1].contains("MINIFS(Schedule!$B$2:$B"), "next date from Schedule's Date (B)")
        expect(rows[0][2].contains("Schedule!$A$2:$A"), "service name from Schedule's Service (A)")
        expect(rows[0][3].contains("Schedule!$C$2:$C"), "time from Schedule's Time (C)")
        let partNames = rows.compactMap { $0.first }.filter { ["인도", "Keys", "A.G.", "Bass"].contains($0) }
        expect(partNames == ["인도", "Keys", "A.G.", "Bass"], "each part, not Time or Location: \(partNames)")
        expect(!rows.contains { $0.first == "Location" || $0.first == "Time" }, "Location and Time are not parts")
        let header = rows.firstIndex { $0.first == "순서" } ?? -1
        expect(header > 0, "a song table")
        let songs = header >= 0 && rows.count > header + 1 ? rows[header + 1] : []
        expect(songs.count == 8, "eight song columns")
        if songs.count == 8 {
            expect(songs[0].contains("Songs!$C$2:$C") && songs[0].contains("Songs!$A$2:$A=$B$1"), "order (C) by date (A)")
            expect(songs[1].contains("Songs!$D$2:$D"), "title (D)")
            expect(songs[2].contains("Songs!$F$2:$F"), "key (F)")
            expect(songs[3].contains("Songs!$G$2:$G"), "played key (G)")
            expect(songs[4].contains("Songs!$H$2:$H"), "notes (H)")
            expect(songs[5].contains("'곡 메모'!$A:$B"), "team memo from the quoted 곡 메모 tab")
            expect(songs[6].contains("Songs!$E$2:$E"), "video (E)")
            expect(songs[7].contains("Attachments!$E$2:$E") && songs[7].contains("Attachments!$J$2:$J<>\"\""),
                   "chart: the URL (E), the one marked in 콘티 (J) first")
        }
        expect(all.contains("Attachments!$B$2:$B=\"\""), "the 콘티 PDF: the service's file without a song")
        expect(!all.contains("$-"), "no column before A")

        // Without Attachments or 곡 메모: those columns left empty, the rest intact.
        let bare = WeekTab.cells(WeekTab.Sources(schedule: sources.schedule, songs: sources.songs,
                                                 attachments: nil, memos: false))
        let bareSongs = bare.flatMap { r in r.firstIndex { $0.first == "순서" }.map { r[$0 + 1] } } ?? []
        expect(bareSongs.count == 8 && bareSongs[5].isEmpty && bareSongs[7].isEmpty && bareSongs[1].contains("Songs!$D"),
               "no memo tab, no attachments: empty columns")
        expect(WeekTab.cells(WeekTab.Sources(schedule: ["Name"], songs: sources.songs, attachments: nil, memos: false)) == nil,
               "no Schedule date: no tab")

        if failures == 0 {
            print("all week tab checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
