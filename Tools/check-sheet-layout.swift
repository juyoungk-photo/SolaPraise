//
//  check-sheet-layout.swift
//  SolaPraise
//
//  Checks that the team sheet is read and written by what it says, not by
//  where things happen to be.
//
//  WHY THIS EXISTS: a leader reorganised the sheet by hand and uploads
//  broke. The Attachments header had moved to row 2; the app read row 1 as
//  the header, found it blank, and tried to create a tab that already
//  existed. The same assumption ran through every tab. And the Members tab
//  was Name · Email · Active while the app wrote Email · Name · Active —
//  the address landed in the Name column. A sorted tab was the third way:
//  writes address rows by remembered number.
//
//  Run:
//      swiftc -O -o /tmp/layoutcheck \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift \
//          Tools/check-sheet-layout.swift
//      /tmp/layoutcheck
//

import Foundation

@main
struct CheckSheetLayout {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { print("       \(detail())"); failures += 1 }
        }

        // THE CASE THAT BROKE: a blank row above the Attachments header.
        let attachments: [[String]] = [
            [],
            ["Date", "Song", "Name", "FileId", "URL", "AddedBy", "AddedAt"],
            ["2026-10-18", "Song A", "a.jpg", "FILE1", "https://drive.google.com/file/d/FILE1/view", "x", "t"],
        ]
        check("a header on row 2 is found",
              TeamSheet.headerIndex(attachments, tab: TeamSheet.attachmentsTab) == 1)
        let anchored = TeamSheet.anchorHeader(attachments, tab: TeamSheet.attachmentsTab)
        check("anchored: the header comes first", anchored.first?.first == "Date")
        check("anchored: data rows keep their sheet row numbers",
              anchored.count == 3 && anchored[2].first == "2026-10-18" && anchored[1].isEmpty,
              "got \(anchored)")

        // A title row and a note above the Songs header.
        let songs: [[String]] = [
            ["2026 찬양 콘티"],
            ["(날짜는 YYYY-MM-DD로)"],
            ["Order", "Title", "Date", "Key", "YouTubeURL"],
            ["1", "Song A", "2026-10-18", "G", ""],
        ]
        check("a header under a title and a note is found",
              TeamSheet.headerIndex(songs, tab: TeamSheet.songsTab) == 2)
        check("a title row is never taken for the header",
              TeamSheet.anchorHeader(songs, tab: TeamSheet.songsTab)[0].contains("Title"))
        check("a tab with no recognisable header is left as it is",
              TeamSheet.anchorHeader([["foo"], ["bar"]], tab: TeamSheet.songsTab) == [["foo"], ["bar"]])
        check("a header already on row 1 is left as it is",
              TeamSheet.anchorHeader(Array(songs.dropFirst(2)), tab: TeamSheet.songsTab)
                == Array(songs.dropFirst(2)))

        // Members laid out Name · Email · Active — the real sheet's order.
        let members = ["Name", "Email", "Active"]
        let placed = TeamSheet.place([
            (["email", "이메일", "메일"], "new@example.com"), (["name", "이름"], "새 팀원"),
            (["active", "사용", "활성"], "TRUE")
        ], header: members)
        check("a new member's address goes in the Email column",
              placed == ["새 팀원", "new@example.com", "TRUE"], "got \(placed)")

        // Columns rearranged on Attachments.
        let shuffled = ["URL", "Date", "FileId", "Song", "Name"]
        let row = TeamSheet.place([
            (["date", "날짜"], "2026-10-18"), (["song", "곡"], "Song A"), (["name", "이름"], "a.jpg"),
            (["fileid"], "FILE1"), (["url", "link"], "https://x"), (["addedby", "by"], "who")
        ], header: shuffled)
        check("values follow their columns, and a column the tab lacks is left out",
              row == ["https://x", "2026-10-18", "FILE1", "Song A", "a.jpg"], "got \(row)")

        // A sorted tab: the remembered row now holds someone else.
        let before = ["2026-10-18", "인도", "me@example.com", "나", "available"]
        let after = ["2026-10-11", "반주", "you@example.com", "너", "available"]
        check("a row that still holds the answer is confirmed",
              TeamSheet.row(before, holds: ["2026-10-18", "me@example.com", "인도"]))
        check("a row that now holds someone else is refused",
              !TeamSheet.row(after, holds: ["2026-10-18", "me@example.com", "인도"]))
        check("dates compare as days, however the sheet shows them",
              TeamSheet.row(["10/18/2026", "ME@example.com"], holds: ["2026-10-18", "me@example.com"]))

        // Tidy follows the header down: frozen through it, rules below it.
        let tab = SheetTidy.Tab(gid: 1, title: TeamSheet.attachmentsTab,
                                header: ["Date", "Song", "Name", "FileId", "URL"],
                                headerRow: 1, columnCount: 7, frozenRows: 0, existingFormulas: [])
        let requests = SheetTidy.requests(for: [tab])
        let freeze = requests.compactMap { ($0["updateSheetProperties"] as? [String: Any])?["properties"] as? [String: Any] }
            .compactMap { ($0["gridProperties"] as? [String: Any])?["frozenRowCount"] as? Int }.first
        check("tidy freezes through a header on row 2", freeze == 2, "got \(String(describing: freeze))")
        let formula = requests.compactMap { r -> String? in
            guard let add = r["addConditionalFormatRule"] as? [String: Any],
                  let rule = add["rule"] as? [String: Any],
                  let b = rule["booleanRule"] as? [String: Any],
                  let c = b["condition"] as? [String: Any],
                  let v = c["values"] as? [[String: Any]] else { return nil }
            return v.first?["userEnteredValue"] as? String
        }.first ?? ""
        check("tidy's date rules start on the first data row (3)", formula.contains("$A3"), "got \(formula)")

        print(failures == 0 ? "\nall sheet layout checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
