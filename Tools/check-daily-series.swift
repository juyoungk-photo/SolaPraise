//
//  check-daily-series.swift
//  SolaPraise
//
//  Checks which 말씀 videos form a daily series, and the order 이어 듣기
//  plays them in.
//
//  WHY THIS EXISTS: the failure is quiet — the wrong episode next, or a
//  sermon pulled into a QT run — and only shows up mid-listen.
//
//  Run:
//      swiftc -O -o /tmp/dailyseries \
//          Sources/Feed/EpisodeDate.swift Sources/Feed/DailySeries.swift Tools/check-daily-series.swift
//      /tmp/dailyseries
//

import Foundation

@main
struct CheckDailySeries {

    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
            failures += 1
        }
    }

    struct Video { let id: String; let title: String; let channel: String }

    static func main() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 10
        let now = Calendar.current.date(from: parts)!
        let church = "교회", su = "성서유니온"
        let videos = [
            Video(id: "m9", title: "[모닝워십] 금, 10.9.2026 자기 소견에 옳은대로 사는 삶 (사사기 19:22-30)", channel: church),
            Video(id: "m8", title: "[모닝워십] 목, 10.8.2026 위선을 이기는 사랑 (사사기 19:11-21)", channel: church),
            Video(id: "m7", title: "[모닝워십] 수, 10.7.2026 항상 진실케 (사사기 19:1-10)", channel: church),
            Video(id: "m6", title: "[모닝워십] 화, 10.6.2026 내가 만든 신들과 제사장 (사사기 18:21-31)", channel: church),
            Video(id: "s4", title: "10/04/2026 마음은 원이로되 (수 24:14-31) 교회-목사", channel: church),
            Video(id: "q11", title: "「2026년 10월 11일 | 매일성경」 이스라엘의 내전 [사사기 20:8-28]", channel: su),
            Video(id: "q10", title: "「2026년 10월 10일 | 매일성경」 조작된 정의 [사사기 20:1-7]", channel: su),
            Video(id: "k1", title: "유아 매일성경 「큐티아이」 2026년 11월 요절송 _이사야 40장 31절", channel: su),
        ]
        func run(_ id: String, _ direction: DailySeries.Direction) -> (ids: [String], start: Int)? {
            let current = videos.first { $0.id == id }!
            return DailySeries.queue(for: current, among: videos, direction: direction,
                                     title: \.title, channel: \.channel, id: \.id, now: now)
                .map { ($0.videos.map(\.id), $0.start) }
        }

        let back = run("m8", .previous)
        check("모닝워십 전날로: newest first, from the one playing",
              back?.ids == ["m9", "m8", "m7", "m6"] && back?.start == 1, "got \(String(describing: back))")
        let forward = run("m8", .next)
        check("모닝워십 다음날로: oldest first, from the one playing",
              forward?.ids == ["m6", "m7", "m8", "m9"] && forward?.start == 2, "got \(String(describing: forward))")
        check("a Sunday sermon is not a 모닝워십 episode", !(back?.ids.contains("s4") ?? true))
        let qt = run("q10", .next)
        check("매일성경 runs on to the next day", qt?.ids == ["q10", "q11"] && qt?.start == 0, "got \(String(describing: qt))")
        check("a monthly 요절송 is no daily episode", run("k1", .next) == nil)
        check("off is off", run("m8", .off) == nil)
        check("a video with no series is played alone", run("s4", .previous) == nil)

        // Two videos claim one day: the regular episode, and a talk show
        // posted later whose title also names the day and the passage.
        let day = [
            "토크쇼 EP38 26년10월14일(수) 사사기 21:13-25",
            "「2026년 10월 14일 | 매일성경」 오늘의 제목 [사사기 21:13-25]",
            "「2026년 10월 13일 | 매일성경」 어제의 제목 [사사기 21:1-12]",
            "「2026년 10월 12일 | 매일성경」 그제의 제목 [사사기 20:29-48]",
        ]
        let picked = DailySeries.regularFirst(Array(day.prefix(2)), among: day, title: { $0 }).first
        check("of two videos for one day, the regular series' episode", picked == day[1], "got \(picked ?? "nil")")
        check("one candidate is kept as it is",
              DailySeries.regularFirst([day[0]], among: day, title: { $0 }) == [day[0]])

        print(failures == 0 ? "\nall daily series checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
