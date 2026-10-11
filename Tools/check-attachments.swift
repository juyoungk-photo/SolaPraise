//
//  check-attachments.swift
//  SolaPraise
//
//  Checks how the same file uploaded twice is recognised on the
//  Attachments tab.
//
//  WHY THIS EXISTS: a duplicate is silent — two identical charts on the
//  stand, two files in Drive — and a wrong match is worse: a different
//  chart refused as "already uploaded".
//
//  Run:
//      swiftc -O -o /tmp/attachmentscheck \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift Tools/check-attachments.swift
//      /tmp/attachmentscheck
//

import Foundation

@main
struct CheckAttachments {

    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
            failures += 1
        }
    }

    static func main() {
        let sunday = TeamSheet.day("2026-10-18")!
        let rows: [[String]] = [
            ["Date", "Song", "Name", "FileId", "URL", "AddedBy", "AddedAt", "Hash"],
            ["2026-10-18", "은혜", "은혜.pdf", "f1", "https://x/f1", "a", "", "aaa111"],
            ["2026-10-18", "", "콘티.pdf", "f2", "https://x/f2", "a", "", "bbb222"],
            ["2026-10-11", "은혜", "은혜-지난주.pdf", "f3", "https://x/f3", "a", "", "ccc333"],
            ["2026-10-18", "주님 뜻대로", "old.pdf", "f4", "https://x/f4", "a", ""],
        ]
        func dup(_ song: String, _ hash: String, _ date: Date = sunday) -> String? {
            TeamSheet.Attachments.duplicate(in: rows, date: date, song: song, hash: hash)
        }
        check("the same file on the same song of the same service is a duplicate", dup("은혜", "aaa111") == "은혜.pdf")
        check("…with the song's name spaced differently", dup(" 은혜 ", "aaa111") == "은혜.pdf")
        check("a different file on that song is not", dup("은혜", "zzz999") == nil)
        check("the same file on another song is not", dup("주님 뜻대로", "aaa111") == nil)
        check("the same file on another service is not", dup("은혜", "ccc333") == nil)
        check("the service's own 콘티 file, again, is", dup("", "bbb222") == "콘티.pdf")
        check("a row from before fingerprints never matches", dup("주님 뜻대로", "") == nil)
        let old = [Array(rows[0].prefix(7)), Array(rows[1].prefix(7))]
        check("a tab with no Hash column finds nothing",
              TeamSheet.Attachments.duplicate(in: old, date: sunday, song: "은혜", hash: "aaa111") == nil)
        check("the header written for a new tab has the Hash column",
              TeamSheet.Attachments.header.last == "Hash" && TeamSheet.Attachments.width == TeamSheet.Attachments.header.count)

        print(failures == 0 ? "\nall attachment checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
