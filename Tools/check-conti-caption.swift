//
//  check-conti-caption.swift
//  SolaPraise
//
//  Checks the corner line on a 콘티's pages: 「2026/10/18 주일2부 - 1. 곡」.
//
//  WHY THIS EXISTS: the line is printed on every page and handed out. A
//  wrong date, a service shortened into something else, or a song
//  numbered from 0 goes out on paper to the whole team.
//
//  Run:
//      swiftc -O -o /tmp/conticaption \
//          Sources/Team/ContiCaption.swift Tools/check-conti-caption.swift
//      /tmp/conticaption
//

import Foundation

@main
struct CheckContiCaption {
    static func main() {
        var failures = 0
        func expect(_ got: String, _ want: String, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): 「\(got)」") }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 11:30 on a Sunday, local — late enough that UTC is the next day.
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23, minute: 30))!

        expect(ContiCaption.text(date: date, service: "주일 2부예배", order: 1, song: "새 노래", calendar: calendar),
               "2026/10/18 주일2부 - 1. 새 노래", "the format asked for")
        expect(ContiCaption.text(date: date, service: "주일 2부예배", song: "새 노래", calendar: calendar),
               "2026/10/18 주일2부 - 새 노래", "no order")
        expect(ContiCaption.text(date: date, service: "주일 2부예배", calendar: calendar),
               "2026/10/18 주일2부", "no song")

        expect(ContiCaption.serviceName("주일 2부예배"), "주일2부", "예배 off, space before the number off")
        expect(ContiCaption.serviceName("주일예배"), "주일", "예배 off")
        expect(ContiCaption.serviceName("금요 Worship"), "금요 Worship", "other words untouched")
        expect(ContiCaption.serviceName("예배"), "예배", "nothing left is not the answer")
        expect(ContiCaption.serviceName("  팀연습 "), "팀연습", "trimmed")

        if failures == 0 {
            print("all conti caption checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
