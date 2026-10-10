//
//  check-sheet-audit.swift
//  SolaPraise
//
//  One fixture per failure shape 워크플로 점검 must catch.
//
//  WHY THIS EXISTS: each case below is a bug that shipped, or the
//  precondition of one, and every one of them was silent in the app.
//  A clean sheet must come back clean too — an audit that cries wolf on
//  a healthy setup gets ignored, and then it catches nothing.
//  WHEN A NEW KIND OF BUG IS FOUND, ADD ITS SHAPE TO SheetAudit AND A CASE
//  HERE. Addresses are placeholders.
//
//  Run:
//      swiftc -O -o /tmp/auditcheck \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift \
//          Sources/Team/SheetAudit.swift Tools/check-sheet-audit.swift
//      /tmp/auditcheck
//

import Foundation

@main
struct CheckSheetAudit {

    static var failures = 0
    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok { print("       \(detail())"); failures += 1 }
    }

    static let today = TeamSheet.day("2026-10-09")!

    static func url(_ id: String) -> String { "https://www.youtube.com/watch?v=\(id)" }

    static var healthy: SheetAudit.Input {
        SheetAudit.Input(
            schedule: [["Date", "Service", "인도", "반주"],
                       ["2026-10-11", "주일 2부", "주영", "은혜"],
                       ["2026-10-18", "주일 2부", "", ""]],
            songs: [["Date", "Service", "Order", "Title", "YouTubeURL", "Key"],
                    ["2026-10-11", "주일 2부", "1", "Song A", url("AAAAAAAAAAA"), "G"],
                    ["2026-10-11", "주일 2부", "2", "Song B", url("BBBBBBBBBBB"), "D"],
                    ["2026-10-11", "주일 2부", "헌신찬양", "Song C", url("CCCCCCCCCCC"), ""]],
            signups: [["Date", "Role", "MemberEmail", "MemberName", "Status", "UpdatedAt"],
                      ["2026-10-11", "인도", "leader@church.example", "주영", "가능", ""],
                      ["2026-10-11", "반주", "pianist@example.com", "은혜", "", ""]],
            members: [["Name", "Email", "Active"],
                      ["주영", "leader@church.example", "TRUE"],
                      ["은혜", "pianist@example.com", "TRUE"]],
            plan: nil,
            accounts: .init(mainEmail: "youtube@example.com", mainHasYouTube: true,
                            churchEmail: "leader@church.example",
                            churchSheetConfigured: true, churchSheetProblem: nil),
            today: today)
    }

    static func ids(_ input: SheetAudit.Input) -> Set<String> {
        Set(SheetAudit.needsAttention(SheetAudit.run(input)).map(\.id))
    }

    static func main() {
        // A healthy setup reports nothing that needs attention.
        let clean = SheetAudit.run(healthy)
        check("a healthy setup needs no attention",
              SheetAudit.needsAttention(clean).isEmpty,
              "got \(SheetAudit.needsAttention(clean).map(\.id))")
        check("and says the acting account is listed",
              clean.contains { $0.id == "account.actingListed" })

        // ACCOUNTS — the mismatch that shipped: YouTube address not on the
        // roster, church account (which is) never connected.
        var a = healthy
        a.accounts.churchEmail = nil
        check("YouTube-only sign-in not on the roster → connect the church account",
              ids(a).contains("account.connectChurch"), "got \(ids(a))")
        check("…and it offers that fix",
              SheetAudit.run(a).first { $0.id == "account.connectChurch" }?.fix == .connectChurchAccount)

        a = healthy
        a.accounts.churchEmail = "someone-else@church.example"
        check("a connected account that is not on the roster is a problem",
              ids(a).contains("account.actingNotListed"), "got \(ids(a))")

        a = healthy
        a.accounts.mainEmail = nil
        check("no YouTube sign-in is reported", ids(a).contains("account.noMain"))
        a = healthy
        a.accounts.mainHasYouTube = false
        check("a sign-in without the YouTube scope is reported", ids(a).contains("account.noYouTubeScope"))

        a = healthy
        a.accounts.churchSheetProblem = "403"
        check("an unreadable church sheet is reported, not silent",
              ids(a).contains("account.churchSheet"))

        // SONGS — shifted rows (the column-drift bug).
        var s = healthy
        s.songs?.append(["", "", "2026-10-11", "", "3", "Song D", url("DDDDDDDDDDD")])
        check("rows written two columns right are a problem", ids(s).contains("songs.shifted"))
        check("…and not also reported as undated", !ids(s).contains("songs.undated"))

        // Duplicates (the seven-copies bug).
        s = healthy
        s.songs?.append(["2026-10-11", "", "3", "Song A", url("AAAAAAAAAAA"), ""])
        check("the same video twice on a service is reported", ids(s).contains("songs.duplicates"))

        // Order clash.
        s = healthy
        s.songs?.append(["2026-10-11", "", "2", "Song E", url("EEEEEEEEEEE"), ""])
        check("two songs with the same order number are reported", ids(s).contains("songs.orderClash"))

        // A date nothing can read.
        s = healthy
        s.songs?.append(["다음 주일", "", "1", "Song F", url("FFFFFFFFFFF"), ""])
        check("an unreadable date is a problem", ids(s).contains("songs.undated"))

        // Blank rows in the middle — a note, not a warning.
        s = healthy
        s.songs?.insert([], at: 2)
        let blank = SheetAudit.run(s).first { $0.id == "songs.blankRows" }
        check("a blank row between songs is noted", blank?.severity == .note,
              "got \(String(describing: blank?.severity))")

        // SCHEDULE.
        var c = healthy
        c.schedule?.append(["2026-10-11", "주일 2부", "", ""])
        check("the same service twice on one day is reported", ids(c).contains("schedule.repeats"))
        c = healthy
        c.schedule = [["Date", "Service"], ["2026-09-27", "주일 2부"]]
        check("no upcoming service is noted",
              SheetAudit.run(c).contains { $0.id == "schedule.noUpcoming" })

        // SIGNUPS.
        var u = healthy
        u.signups?.append(["2026-10-11", "드럼", "pianist@example.com", "은혜", "X", ""])
        check("an answer the app does not know is reported", ids(u).contains("signups.unknownStatus"))
        u = healthy
        u.signups?.append(["2026-10-11", "드럼", "other-address@example.com", "은혜", "가능", ""])
        check("an answer from an address not on the roster is reported",
              ids(u).contains("signups.notOnRoster"))
        u = healthy
        u.signups?.append(["2026-10-11", "인도", "leader@church.example", "주영", "미정", ""])
        check("two answers for one person and part are reported", ids(u).contains("signups.repeats"))

        // MEMBERS.
        var m = healthy
        m.members?.append(["민수", "minsu at example", "TRUE"])
        check("a roster entry that is not an address is reported", ids(m).contains("members.malformed"))

        // STRUCTURE.
        var t = healthy
        t.signups = nil
        check("a missing Signups tab is a problem", ids(t).contains("structure.missing.Signups"))
        t = healthy
        t.songs?[0] = ["날", "예배", "번호", "노래", "링크"]
        check("unrecognised Songs headers are reported", ids(t).contains("structure.header.Songs"))

        // From outside the app there is no sign-in to judge.
        var live = healthy
        live.checksAccounts = false
        live.accounts = .init()
        check("a sheet-only audit does not report accounts",
              !SheetAudit.run(live).contains { $0.area == "계정" })

        print(failures == 0 ? "\nall sheet audit checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
