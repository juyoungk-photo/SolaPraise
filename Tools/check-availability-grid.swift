//
//  check-availability-grid.swift
//  SolaPraise
//
//  Checks the 응답 tab: answers read from the right cells, the right cell
//  found to write back to, and the grid built from what is known.
//
//  WHY THIS EXISTS: an answer read from the wrong column is somebody else's
//  answer; one written to the wrong row is a Sunday nobody asked about. A
//  blank cell read as 가능 fills the schedule with people who never said a
//  word. None of these fail loudly — the 응답 just reads wrong. Names here
//  are made up.
//
//  Run:
//      swiftc -O -o /tmp/availgrid \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift Sources/Team/AvailabilityGrid.swift \
//          Tools/check-availability-grid.swift
//      /tmp/availgrid
//

import Foundation

@main
struct CheckAvailabilityGrid {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }
        let day = { (text: String) in Calendar.current.startOfDay(for: TeamSheet.day(text)!) }

        let rows: [[String]] = [
            ["예배", "날짜", "가람", "나래", "다솜"],
            ["주일2부", "2026-10-25", "가능", "", "어려움"],
            ["주일2부", "Nov 1 Sun", "미정", "자리비움"],          // a short row, a date as the sheet shows it
            ["팀연습", "2026-11-01", "", "가능", "모름"],          // same day, another service; a word not known
            ["", "", "가능"],                                       // no date: not a service
        ]

        // Read.
        let answers = AvailabilityGrid.answers(rows)
        expect(answers.count, 5, "five answers: blanks, unknown words and undated rows are none")
        expect(answers.first { $0.name == "다솜" && $0.day == day("2026-10-25") }?.status, "declined", "어려움 → declined")
        expect(answers.first { $0.name == "나래" && $0.service == "주일2부" }?.status, "away", "자리비움 → away")
        expect(answers.contains { $0.name == "나래" && $0.day == day("2026-10-25") }, false, "a blank cell is no answer")
        expect(answers.contains { $0.name == "다솜" && $0.service == "팀연습" }, false, "an unknown word is no answer")
        expect(answers.first { $0.name == "가람" && $0.status == "maybe" }.map { [$0.row, $0.column] }, [3, 2],
               "row and column to write back to")

        // Where to write.
        expect(AvailabilityGrid.row(for: day("2026-10-25"), service: "주일 2부예배", in: rows), 2, "by day")
        expect(AvailabilityGrid.row(for: day("2026-11-01"), service: "팀연습", in: rows), 4, "same day: by service")
        expect(AvailabilityGrid.row(for: day("2026-11-01"), service: "주일 2부예배", in: rows), 3,
               "same day: by service, spelled differently")
        expect(AvailabilityGrid.row(for: day("2026-11-08"), service: "주일2부", in: rows), nil, "no row yet")
        expect(AvailabilityGrid.Layout(header: rows[0])?.column(for: "다솜 "), 4, "member column by name")
        expect(AvailabilityGrid.Layout(header: ["Name", "Email"]) == nil, true, "not a grid without a date column")

        // Built from what is known, and read back the same.
        let built = AvailabilityGrid.build(
            services: [(day("2026-10-25"), "주일2부"), (day("2026-11-01"), "주일2부")],
            members: ["가람", "나래"],
            answers: [day("2026-10-25"): ["가람": "available", "나래": "maybe"]])
        expect(built, [["예배", "날짜", "가람", "나래"],
                       ["주일2부", "2026-10-25", "가능", "미정"],
                       ["주일2부", "2026-11-01", "", ""]], "built grid")
        expect(AvailabilityGrid.answers(built).map(\.status), ["available", "maybe"], "built grid reads back")

        // Rows still to make: a service Schedule has and the grid does not.
        let schedule = [(day("2026-10-18"), "주일2부"), (day("2026-10-25"), "주일 2부예배"),
                        (day("2026-11-01"), "팀연습"), (day("2026-11-08"), "주일2부")]
        expect(AvailabilityGrid.missingServices(schedule, in: rows, from: day("2026-10-20")).map(\.title),
               ["주일2부"], "only 11/8 is missing (10/18 is before the start)")
        expect(AvailabilityGrid.missingServices([(day("2026-11-01"), "금요기도")], in: rows,
                                                from: day("2026-10-20")).count, 1,
               "another service on a day the grid has is still missing")

        // One name per part.
        expect(["피아노", "A.G.", "BASS", "DRUM", "VOCAL", "인도자", "건반", "보컬2", "반주"].map(AvailabilityGrid.unifiedPart),
               ["건반", "기타", "베이스", "드럼", "보컬", "인도", nil, nil, nil], "part names unified")

        // The dropdown covers members' columns, and the four words are coloured.
        let requests = AvailabilityGrid.formatRequests(gid: 7, members: 3, rows: 5)
        expect(requests.filter { $0["addConditionalFormatRule"] != nil }.count, 4, "four colours")
        expect(requests.contains { $0["setDataValidation"] != nil }, true, "a dropdown")

        if failures == 0 {
            print("all availability grid checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
