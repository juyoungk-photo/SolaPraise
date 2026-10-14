//
//  check-playlist-years.swift
//  SolaPraise
//
//  Checks PlaylistYears against the kinds of titles church channels use.
//
//  WHY THIS EXISTS: a year read wrongly files a service under the wrong
//  chip, and a chip that hides a service looks like the service was never
//  posted. Neither raises an error.
//
//  Run:
//      swiftc -O -o /tmp/pycheck \
//          Sources/Library/PlaylistYears.swift Tools/check-playlist-years.swift
//      /tmp/pycheck
//

import Foundation

@main
struct CheckPlaylistYears {
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ year: Int) -> Date { calendar.date(from: DateComponents(year: year, month: 6, day: 1))! }

        check("a title that is a year", PlaylistYears.yearOnly("2026") == 2026)
        check("with 년 and spaces", PlaylistYears.yearOnly(" 2025 년 ") == 2025)
        check("a service title is not a year playlist", PlaylistYears.yearOnly("2025 성탄 예배") == nil)

        check("the year in a title", PlaylistYears.yearInTitle("2025 성탄 예배") == 2025)
        check("in the middle", PlaylistYears.yearInTitle("주일예배 2024.12.29") == 2024)
        check("not inside a longer number", PlaylistYears.yearInTitle("영상 20250105") == nil)
        check("not a hymn number", PlaylistYears.yearInTitle("찬송가 202장") == nil)

        check("the title's year over the date it was made",
              PlaylistYears.year(title: "2024 송구영신", publishedAt: date(2025), calendar: calendar) == 2024)
        check("else the date it was made",
              PlaylistYears.year(title: "부활절 예배", publishedAt: date(2023), calendar: calendar) == 2023)
        check("neither: no year",
              PlaylistYears.year(title: "부활절 예배", publishedAt: nil, calendar: calendar) == nil)

        let chips = PlaylistYears.chips([
            ("2026", date(2026)), ("부활절 예배", date(2026)), ("2025 성탄 예배", date(2026)), ("수련회", date(2024)),
        ], calendar: calendar)
        check("chips, newest first", chips == [2026, 2025, 2024], "got \(chips)")
        check("one year and no year playlist: no chips",
              PlaylistYears.chips([("부활절", date(2026)), ("성탄", date(2026))], calendar: calendar).isEmpty)
        check("a year playlist alone still makes a chip",
              PlaylistYears.chips([("2026", date(2026)), ("성탄", date(2026))], calendar: calendar) == [2026])

        if failures == 0 { print("all playlist year checks passed") } else { print("\(failures) failure(s)"); exit(1) }
    }
}
