//
//  check-church-sheet.swift
//  SolaPraise
//
//  Exercises ChurchSheet.notes against the shapes a church office actually
//  produces.
//
//  WHY THIS EXISTS: this parser fails SILENTLY. It matches columns by header
//  text, and when no header matches it returns an empty dictionary — which
//  looks exactly like "the office has not filled anything in yet". Nothing in
//  the app can tell those apart, so a renamed column, a reordered tab or a
//  date typed the American way would quietly remove 설교제목 and 헌신찬양 from
//  every service and nobody would see an error.
//
//  The sheet is also somebody else's document. It will be rearranged without
//  warning and without telling the team, so tolerance is the feature and this
//  is where it is demonstrated.
//
//  Run:
//      swiftc -O -o /tmp/churchcheck \
//          Sources/Team/TeamSheet.swift \
//          Sources/Team/ChurchSheet.swift \
//          Tools/check-church-sheet.swift
//      /tmp/churchcheck
//
//  Expected: "all church sheet cases correct".
//

import Foundation

@main
struct CheckChurchSheet {

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// One expected note: date, sermon, dedication. nil means "absent".
    private typealias Want = (date: String, sermon: String?, song: String?)

    private struct Case {
        let name: String
        let rows: [[String]]
        let want: [Want]
    }

    private static let cases: [Case] = [
        Case(name: "spaced headers, extra columns, trailing blanks",
             rows: [
                ["날짜", "인도자", "설교 제목", "본문", "헌신 찬양", "비고"],
                ["2026-10-11", "김집사", "기브아의 비극", "삿 19", "주 은혜임을", ""],
                ["2026-10-18", "이집사", "", "", "", ""],
                ["10/25/2026", "박집사", "다시 세우시는 하나님", "삿 21", "", "저녁"]
             ],
             want: [("2026-10-11", "기브아의 비극", "주 은혜임을"),
                    ("2026-10-25", "다시 세우시는 하나님", nil)]),

        Case(name: "no spaces, columns reordered, American dates",
             rows: [
                ["주일", "헌신찬양", "설교제목"],
                ["11/1/2026", "은혜 아니면", "오직 은혜로"],
                ["11/8/2026", "", "믿음의 경주"]
             ],
             want: [("2026-11-01", "오직 은혜로", "은혜 아니면"),
                    ("2026-11-08", "믿음의 경주", nil)]),

        Case(name: "yearless date with weekday, spacer rows",
             rows: [
                ["Date", "말씀 제목", "헌신"],
                ["", "", ""],
                ["Nov 15 Sun", "함께 걷는 길", "내 영혼의 그윽히"],
                ["— 11월 —", "", ""]
             ],
             want: [("2026-11-15", "함께 걷는 길", "내 영혼의 그윽히")]),

        Case(name: "sermon column only",
             rows: [["날짜", "설교"], ["2026-12-06", "대림절 첫째 주"]],
             want: [("2026-12-06", "대림절 첫째 주", nil)]),

        // 설교제목 must win over the bare 설교 when a sheet carries both.
        Case(name: "both 설교 and 설교제목 present",
             rows: [["날짜", "설교", "설교제목"],
                    ["2026-12-13", "박목사", "기다리는 사람들"]],
             want: [("2026-12-13", "기다리는 사람들", nil)]),

        // Must come back EMPTY rather than wrong.
        Case(name: "no date column", rows: [["설교제목", "헌신찬양"], ["A", "B"]], want: []),
        Case(name: "neither field present",
             rows: [["날짜", "인도자"], ["2026-10-11", "김집사"]], want: []),
        Case(name: "empty sheet", rows: [], want: []),
        Case(name: "header only", rows: [["날짜", "설교제목", "헌신찬양"]], want: [])
    ]

    static func main() {
        var failures = 0

        for test in cases {
            let got = ChurchSheet.notes(from: test.rows)
            var problems: [String] = []

            if got.count != test.want.count {
                problems.append("expected \(test.want.count) note(s), got \(got.count)")
            }
            for want in test.want {
                guard let date = day.date(from: want.date),
                      let note = got[Calendar.current.startOfDay(for: date)] else {
                    problems.append("missing \(want.date)")
                    continue
                }
                if note.sermonTitle != want.sermon {
                    problems.append("\(want.date) 설교: want \(want.sermon ?? "nil"), got \(note.sermonTitle ?? "nil")")
                }
                if note.dedicationSong != want.song {
                    problems.append("\(want.date) 헌신: want \(want.song ?? "nil"), got \(note.dedicationSong ?? "nil")")
                }
            }

            failures += problems.count
            print("\(problems.isEmpty ? "ok  " : "FAIL") \(test.name)")
            problems.forEach { print("       \($0)") }
        }

        print(failures == 0
              ? "\nall church sheet cases correct"
              : "\n\(failures) problem(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
