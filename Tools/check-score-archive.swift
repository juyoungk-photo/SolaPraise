//
//  check-score-archive.swift
//  SolaPraise
//
//  Checks how 작업실's 팀 악보 gathers the team's attached charts.
//
//  WHY THIS EXISTS: the grouping fails silently. A song split in two by a
//  stray space, or a 콘티 PDF filed as if it were a chart, looks like
//  "that's just what the team uploaded" — nobody reports a chart that is
//  merely in the wrong place.
//
//  Run:
//      swiftc -O -o /tmp/scorearchive \
//          Sources/Team/ScoreArchive.swift Tools/check-score-archive.swift
//      /tmp/scorearchive
//

import Foundation

@main
struct CheckScoreArchive {

    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
            failures += 1
        }
    }

    struct File { let day: Int; let song: String; let name: String }

    static func main() {
        let files = [
            File(day: 1, song: "주님 뜻대로", name: "주님 뜻대로 (G).pdf"),
            File(day: 8, song: "주님뜻대로 ", name: "주님 뜻대로 (A).pdf"),
            File(day: 8, song: "", name: "10월 8일 콘티.pdf"),
            File(day: 5, song: "Way Maker", name: "IMG_2041"),
            File(day: 5, song: "Way Maker", name: "waymaker-guide.m4a"),
            File(day: 3, song: "WAY MAKER", name: "way maker (E).jpg"),
            File(day: 2, song: "은혜", name: "은혜.png"),
        ]
        let entries = ScoreArchive.entries(
            files, date: { Date(timeIntervalSince1970: Double($0.day) * 86_400) },
            song: \.song, name: \.name)

        check("one entry per song, spacing and case ignored",
              entries.map(\.song) == ["주님뜻대로", "Way Maker", "은혜"],
              "got \(entries.map(\.song))")
        check("newest chart first within a song",
              entries.first?.files.map(\.name) == ["주님 뜻대로 (A).pdf", "주님 뜻대로 (G).pdf"],
              "got \(entries.first?.files.map(\.name) ?? [])")
        check("the 콘티 PDF filed on the service is not a song's chart",
              !entries.contains { $0.files.contains { $0.name == "10월 8일 콘티.pdf" } })
        check("a guide recording is not a chart",
              !entries.contains { $0.files.contains { $0.name.hasSuffix(".m4a") } })
        check("a photo with no extension is a chart",
              entries.contains { $0.files.contains { $0.name == "IMG_2041" } })
        check("nothing attached, nothing shown",
              ScoreArchive.entries([File](), date: { _ in Date() }, song: \.song, name: \.name).isEmpty)

        print(failures == 0 ? "\nall score archive checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
