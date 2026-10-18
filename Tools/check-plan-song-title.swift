//
//  check-plan-song-title.swift
//  SolaPraise
//
//  Checks PlanSongTitle on the kinds of titles a 순서 song arrives with.
//
//  WHY THIS EXISTS: a line read wrongly shows the team's name as the song,
//  or drops the hymn number a congregation finds the hymn by. Neither
//  raises an error; the 순서 just reads wrong on Sunday.
//
//  Run:
//      swiftc -O -o /tmp/planttitle \
//          Sources/Feed/SongSearchSuggestions.swift Sources/Feed/PlanSongTitle.swift \
//          Tools/check-plan-song-title.swift
//      /tmp/planttitle
//

import Foundation

@main
struct CheckPlanSongTitle {
    static var failures = 0

    static func check(_ name: String, _ got: PlanSongTitle.Parts, title: String, hymn: Int? = nil, meta: [String]) {
        let ok = got.title == title && got.hymn == hymn && got.meta == meta
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok { print("       got 「\(got.title)」 \(got.hymn.map(String.init) ?? "-") \(got.meta)"); failures += 1 }
    }

    static func main() {
        check("hymn: the song first, the number kept, the team and year after",
              PlanSongTitle.split("[찬송가 288장] 예수를 나의 구주 삼고 | 마커스워십 2019 Official"),
              title: "예수를 나의 구주 삼고", hymn: 288, meta: ["마커스워십", "2019"])
        check("song | singer",
              PlanSongTitle.split("은혜 | 손경민"), title: "은혜", meta: ["손경민"])
        check("an English title beside the Korean is not meta",
              PlanSongTitle.split("주님 뜻대로 살기로 했네 No Turning Back | 더라이트 워십 Live"),
              title: "주님 뜻대로 살기로 했네", meta: ["더라이트 워십 Live"])
        check("a team tag in brackets",
              PlanSongTitle.split("[어노인팅] 십자가의 전달자 (2021)"),
              title: "십자가의 전달자", meta: ["어노인팅", "2021"])
        check("a year beside the song is kept",
              PlanSongTitle.split("나의 영혼이 잠잠히 2023"), title: "나의 영혼이 잠잠히", meta: ["2023"])
        check("typed by hand: as it is",
              PlanSongTitle.split("나의 영혼이 잠잠히"), title: "나의 영혼이 잠잠히", meta: [])
        check("the channel names the team when the title does not",
              PlanSongTitle.split("선하신 목자", channel: "마커스워십"), title: "선하신 목자", meta: ["마커스워십"])
        check("not twice when the title already does",
              PlanSongTitle.split("선하신 목자 | 마커스워십", channel: "마커스워십"),
              title: "선하신 목자", meta: ["마커스워십"])
        check("a hymn number alone in the title",
              PlanSongTitle.split("찬송가 384장 나의 갈 길 다 가도록"),
              title: "나의 갈 길 다 가도록", hymn: 384, meta: [])

        // Readings to choose from when the split took a series or an
        // album for the song (made-up titles).
        func candidates(_ name: String, _ got: [String], first: String, includes: [String], excludes: [String]) {
            let ok = got.first == first && includes.allSatisfy(got.contains) && !excludes.contains(where: got.contains)
                && Set(got).count == got.count
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { print("       got \(got)"); failures += 1 }
        }
        let series = "새벽 기도회 시리즈 | 빛의 노래 | 하늘팀 2024"
        candidates("a series first: the song is another part, and the title as it came is last",
                   PlanSongTitle.candidates(series, channel: "하늘팀"),
                   first: PlanSongTitle.split(series, channel: "하늘팀").title,
                   includes: ["새벽 기도회 시리즈", "빛의 노래", series], excludes: ["하늘팀", "2024"])
        candidates("an album in brackets is offered too",
                   PlanSongTitle.candidates("[봄의 앨범] 빛의 노래 (Official MV)"),
                   first: PlanSongTitle.split("[봄의 앨범] 빛의 노래 (Official MV)").title,
                   includes: ["봄의 앨범", "빛의 노래"], excludes: ["Official MV"])
        candidates("a writer's credit is not offered as a song",
                   PlanSongTitle.candidates("빛의 노래 (홍길동 사,곡) - 하늘팀 #3 \"작은 고백\""),
                   first: PlanSongTitle.split("빛의 노래 (홍길동 사,곡) - 하늘팀 #3 \"작은 고백\"").title,
                   includes: ["빛의 노래"], excludes: ["홍길동 사,곡"])
        candidates("a title already tidy: itself, once",
                   PlanSongTitle.candidates("빛의 노래"), first: "빛의 노래", includes: [], excludes: [])

        print(failures == 0 ? "\nall plan song title checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
