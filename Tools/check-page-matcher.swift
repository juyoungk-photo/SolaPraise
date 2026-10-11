//
//  check-page-matcher.swift
//  SolaPraise
//
//  Checks how a 콘티 file's pages are placed on the 순서's songs.
//
//  WHY THIS EXISTS: a page on the wrong song is a chart on the stand for a
//  song nobody is playing, and looks like the app working.
//
//  Run:
//      swiftc -O -o /tmp/pagematcher \
//          Sources/Chords/ScorePageMatcher.swift Tools/check-page-matcher.swift
//      /tmp/pagematcher
//

import Foundation

@main
struct CheckPageMatcher {

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
        let songs = ["주 예수 내 산 소망", "거룩하신 전능의 주", "어려운 일 당할 때", "주님 뜻대로 살기로 했네"]
        let pages: [[String]] = [
            ["콘티 10월 12일", "주일 2부예배"],                       // a cover
            ["주 예수 나의 산 소망", "FIA_Ver.", "♩= 68"],          // one syllable off
            ["You are Holy 거룩하신 전능의주", "Mark Imboden"],       // English first, no space
            ["", "1.주 님 앞에"],                                    // page 2 of the same chart
            ["어려운 일 당할 때", "(찬송가 543장)", "KaMU"],
            ["은혜 아니면", "주사평"],                                 // a song not in this 순서
            ["", "2. 생명 있을"],                                    // ...and its second page
        ]
        let placed = ScorePageMatcher.assign(pageTitles: pages, songs: songs)
        check("a cover page is no song", placed[0] == nil, "got \(placed[0] ?? "-")")
        check("a title a syllable off still matches", placed[1] == "주 예수 내 산 소망", "got \(placed[1] ?? "-")")
        check("an English title in front, a space missing", placed[2] == "거룩하신 전능의 주", "got \(placed[2] ?? "-")")
        check("a page with no title continues the song before", placed[3] == "거룩하신 전능의 주", "got \(placed[3] ?? "-")")
        check("a hymn by its title", placed[4] == "어려운 일 당할 때", "got \(placed[4] ?? "-")")
        check("a song not in the 순서 is left unplaced", placed[5] == nil, "got \(placed[5] ?? "-")")
        check("…and so is its second page", placed[6] == nil, "got \(placed[6] ?? "-")")
        check("a song with no page gets none", !placed.values.contains("주님 뜻대로 살기로 했네"))

        print(failures == 0 ? "\nall page matcher checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
