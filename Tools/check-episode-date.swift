//
//  check-episode-date.swift
//  SolaPraise
//
//  Checks EpisodeDate against titles these channels actually publish.
//
//  WHY THIS EXISTS: the parser decides which day an episode belongs to, and
//  it is wrong in two directions that both look like nothing is broken. Miss
//  a date and the app silently falls back to upload order, which is the bug
//  this was written to fix. Invent one — read 「찬송가 32장」 or 「26.10.01」
//  inside a verse range as a date — and the home screen confidently shows
//  the wrong day's reading. Neither raises an error.
//
//  Run:
//      swiftc -O -o /tmp/edcheck \
//          Sources/Feed/EpisodeDate.swift Tools/check-episode-date.swift
//      /tmp/edcheck
//
//  "now" is pinned so the plausibility window is stable.
//

import Foundation

@main
struct CheckEpisodeDate {
    static func main() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 8))!
        let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

        let cases: [(String, String?)] = [
            ("「2026년 10월 9일 | 매일성경」 기브아의 비극 [사사기 19:22-30]", "2026-10-09"),
            ("[모닝워십] 수, 10.7.2026 항상 진실케, 내 맘을", "2026-10-07"),
            ("2026_1001 | 어노인팅목요예배 | 인도_ 소병찬", "2026-10-01"),
            ("2026-10-06 | 예수전도단 화요모임", "2026-10-06"),
            ("피아워십 목요예배(26.10.01) I 설교: 이동선목사", "2026-10-01"),
            ("10월 9일 매일성경 | 기브아의 비극", "2026-10-09"),
            // Must NOT be read as dates.
            ("찬송가 32장 만유의 주재 | 발걸음 가벼운 가을 찬송", nil),
            ("어려운 일 당할 때 + 마음이 상한 자를", nil),
            ("주님께 영광 높이 드리세 / GLORY TO THE LORD", nil),
            ("2027 FIC Winter Camp - Teaser", nil),
            ("사사기 19:22-30 묵상", nil),
        ]

        var bad = 0
        for (title, want) in cases {
            let got = EpisodeDate.inTitle(title, now: now).map { fmt.string(from: $0) }
            let ok = got == want
            if !ok { bad += 1 }
            print("\(ok ? "ok  " : "FAIL") \(want ?? "(none)")  <- \(title.prefix(46))")
            if !ok { print("       got: \(got ?? "(none)")") }
        }
        print(bad == 0 ? "\nall \(cases.count) title dates correct" : "\n\(bad) wrong")
        exit(bad == 0 ? 0 : 1)
    }
}
