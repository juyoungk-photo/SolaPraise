//
//  check-shifted-rows.swift
//  SolaPraise
//
//  Checks that rows written into the wrong columns are found — and that
//  healthy rows are not.
//
//  WHY THIS EXISTS: Google's values:append writes "starting with the first
//  column of the table" it detects, not at column A, and blank rows in the
//  middle of a tab throw that detection off. Once one row landed in column
//  C, every later append followed it. A real team's Songs tab ended up with
//  nine songs whose date sat in the Order column — invisible to every parser,
//  so they vanished from the 콘티 with no error anywhere. Switching account
//  looked like it changed the 순서 only because the reload was the first
//  honest look at the sheet.
//
//  The append is fixed (it now writes an explicit A-anchored range), but
//  rows already damaged stay damaged until somebody notices. This is what
//  notices. The fixture below reproduces the real pattern exactly: healthy
//  rows, a blank row left by a deletion, then a run shifted two columns.
//
//  Run:
//      swiftc -O -o /tmp/shiftcheck \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift \
//          Tools/check-shifted-rows.swift
//      /tmp/shiftcheck
//

import Foundation

@main
struct CheckShiftedRows {

    static let header = ["Date", "Service", "Order", "Title", "YouTubeURL", "Key", "Transpose", "Notes"]

    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { print("       \(detail())"); failures += 1 }
        }

        let rows: [[String]] = [
            header,
            ["2026-09-27", "주일 2부", "1", "Song A", "https://youtu.be/a"],     // 2 healthy
            ["2026-09-27", "주일 2부", "헌신찬양", "Song B", "https://youtu.be/b"], // 3 healthy, non-numeric order
            ["2026-10-04", "", "1", "Song C", "https://youtu.be/c"],            // 4 healthy, empty Service
            [],                                                                  // 5 blank — a deletion
            ["2026-10-18", "", "2", "Song D", "https://youtu.be/d"],            // 6 healthy
            ["", "", "2026-10-18", "", "4", "Song E", "https://youtu.be/e"],    // 7 SHIFTED by 2
            ["", "", "2026-10-18", "", "5", "Song F", "https://youtu.be/f"],    // 8 SHIFTED by 2
            ["", "", "", "Notes only, no date"],                                 // 9 not a song row
            ["", "", "", "", "", "", "", "a stray note"]                        // 10 not a song row
        ]

        let found = TeamSheet.shiftedRows(in: rows)

        check("finds exactly the shifted rows",
              found.map(\.row) == [7, 8], "got \(found.map(\.row))")
        check("measures the shift", Set(found.map(\.shift)) == [2],
              "got \(found.map(\.shift))")

        if let first = found.first {
            check("repaired row has the date in the Date column",
                  first.repaired.first == "2026-10-18", "got \(first.repaired.first ?? "nil")")
            check("repaired row has the order in the Order column",
                  first.repaired.count > 2 && first.repaired[2] == "4",
                  "got \(first.repaired)")
            check("repaired row has the title in the Title column",
                  first.repaired.count > 3 && first.repaired[3] == "Song E",
                  "got \(first.repaired)")
        }

        // The blank row, the non-numeric order and the empty Service column
        // are all normal, and must not be mistaken for damage.
        check("healthy rows are not flagged",
              !found.contains { [2, 3, 4, 6].contains($0.row) })
        check("a blank row is not flagged", !found.contains { $0.row == 5 })
        check("a row with no date anywhere is not flagged",
              !found.contains { [9, 10].contains($0.row) })

        // A clean tab has nothing to report. prefix(6) is the header plus
        // sheet rows 2–6 — all healthy, blank row included.
        let clean = Array(rows.prefix(6))
        check("a clean tab reports nothing", TeamSheet.shiftedRows(in: clean).isEmpty,
              "got \(TeamSheet.shiftedRows(in: clean).map(\.row))")

        print(failures == 0 ? "\nall shifted-row checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
