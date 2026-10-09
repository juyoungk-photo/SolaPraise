//
//  check-duplicate-songs.swift
//  SolaPraise
//
//  Checks that a song entered more than once on a service is found, that
//  the first copy is the one kept, and that the service is renumbered.
//
//  WHY THIS EXISTS: the fixture is the shape a real Songs tab took — one
//  video seven times on one Sunday, Order cells 4, 5, 4, 5, 4, 6, 7 —
//  because each add happened while the earlier copies were invisible. The
//  tidy-up clears rows in a shared document, so what it would clear has to
//  be checkable without touching one. Titles are placeholders.
//
//  Run:
//      swiftc -O -o /tmp/dupcheck \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift \
//          Tools/check-duplicate-songs.swift
//      /tmp/dupcheck
//

import Foundation

@main
struct CheckDuplicateSongs {

    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { print("       \(detail())"); failures += 1 }
        }

        func url(_ id: String) -> String { "https://www.youtube.com/watch?v=\(id)" }
        let a = "AAAAAAAAAAA", b = "BBBBBBBBBBB", c = "CCCCCCCCCCC",
            d = "DDDDDDDDDDD", e = "EEEEEEEEEEE", f = "FFFFFFFFFFF"

        let rows: [[String]] = [
            ["Date", "Service", "Order", "Title", "YouTubeURL", "Key", "Transpose", "Notes"],
            ["2026-09-27", "주일 2부", "1", "Song A", url(a)],            // 2
            ["2026-09-27", "주일 2부", "헌금찬양"],                          // 3 label, no title
            ["2026-10-04", "", "1", "Song A", url(a)],                    // 4 same video, other date: fine
            [],                                                           // 5 blank
            ["2026-10-18", "", "2", "Song B", url(b)],                    // 6
            ["2026-10-18", "", "3", "Song C", url(c)],                    // 7
            ["2026-10-18", "", "4", "Song D v1", url(d)],                 // 8
            ["2026-10-18", "", "5", "Song D v2", url(e)],                 // 9 another version: kept
            ["2026-10-18", "", "6", "Song F", url(f)],                    // 10 first F: kept
            ["2026-10-18", "", "4", "Song F", url(f)],                    // 11 dup
            ["2026-10-18", "", "5", "Song F", url(f)],                    // 12 dup
            ["2026-10-18", "", "4", "Song F", "https://youtu.be/\(f)"],   // 13 dup, other link shape
            ["2026-10-18", "", "7", "No link", ""],                       // 14
            ["2026-10-18", "", "8", "no  LINK", ""],                      // 15 dup by title
        ]

        let found = TeamSheet.duplicateSongRows(in: rows)
        check("finds exactly the repeated copies", found.rows == [11, 12, 13, 15],
              "got \(found.rows)")
        check("the same video on another date is not a duplicate",
              !found.rows.contains(4))
        check("another version of the same song is not a duplicate",
              !found.rows.contains(9))

        // After clearing 11–13 and 15, 10/18 holds orders 2,3,4,5,6,7 at
        // rows 6,7,8,9,10,14 — renumbered 1…6.
        let renumbered = Dictionary(uniqueKeysWithValues: found.renumber.map { ($0.row, $0.order) })
        check("the affected service runs 1…n again",
              renumbered == [6: 1, 7: 2, 8: 3, 9: 4, 10: 5, 14: 6], "got \(renumbered)")
        check("a service with no duplicates is not renumbered",
              !found.renumber.contains { [2, 4].contains($0.row) })

        let clean = Array(rows.prefix(10))
        check("a tab with no repeats reports nothing",
              TeamSheet.duplicateSongRows(in: clean).isEmpty,
              "got \(TeamSheet.duplicateSongRows(in: clean).rows)")

        check("video id from watch, youtu.be and shorts links",
              TeamSheet.videoKey(url(a)) == a
                && TeamSheet.videoKey("https://youtu.be/\(b)?t=3") == b
                && TeamSheet.videoKey("https://www.youtube.com/shorts/\(c)") == c)

        print(failures == 0 ? "\nall duplicate-song checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
