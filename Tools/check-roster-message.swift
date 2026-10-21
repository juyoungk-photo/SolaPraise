//
//  check-roster-message.swift
//  SolaPraise
//
//  Checks 배정표 보내기's message, and finding the parts a person is on.
//
//  WHY THIS EXISTS: the message goes to the whole team's chat. A part shown
//  staffed when it is empty, or somebody told they are on a part they are
//  not, is believed — nobody checks a message against the sheet. Names
//  here are made up.
//
//  Run:
//      swiftc -O -o /tmp/rostermessage \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift Sources/Team/RosterMessage.swift \
//          Tools/check-roster-message.swift
//      /tmp/rostermessage
//

import Foundation

@main
struct CheckRosterMessage {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message):\n\(got)") }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 11, minute: 30))!

        let text = RosterMessage.text(day: day, title: "주일2부", time: "11:30 AM",
                                      parts: [("인도", "가람"), ("Keys", ""), ("Vocal", "나래, 다솜")],
                                      pending: ["라온"], link: URL(string: "https://example.com/sheet"),
                                      calendar: calendar)
        expect(text, """
        10/25(일) 주일2부 11:30 AM
        인도 가람 · Keys — · Vocal 나래, 다솜
        아직 비어 있는 파트: Keys
        아직 응답 안 함: 라온
        응답 · 배정은 팀 시트에서: https://example.com/sheet
        """, "the message")

        let full = RosterMessage.text(day: day, title: "주일2부", time: nil, parts: [("인도", "가람")],
                                      pending: [], link: nil, calendar: calendar)
        expect(full, "10/25(일) 주일2부\n인도 가람", "nothing open, nobody pending, no link: no such lines")

        let assignments = [(part: "인도", cell: "김가람"), (part: "Keys", cell: "나래"), (part: "Vocal", cell: "다솜, 가람")]
        expect(RosterMessage.parts(of: "가람", in: assignments, names: TeamSheet.names(inCell:)), ["인도", "Vocal"],
               "a roster name inside a full name, and in a cell of several")
        expect(RosterMessage.parts(of: "라온", in: assignments, names: TeamSheet.names(inCell:)), [String](),
               "not on anything")
        expect(RosterMessage.parts(of: "나", in: [(part: "Keys", cell: "나래")], names: TeamSheet.names(inCell:)), [String](),
               "one letter does not match inside a name")

        expect(["반주", "건반", "인도", "Keys", "Vocal"].map(RosterMessage.withRo), ["반주로", "건반으로", "인도로", "Keys로", "Vocal로"],
               "로 / 으로 by the last sound")
        expect(["드럼", "베이스", "길"].map(RosterMessage.withRo), ["드럼으로", "베이스로", "길로"], "ㄹ takes 로")

        if failures == 0 {
            print("all roster message checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
