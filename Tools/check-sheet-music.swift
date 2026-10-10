//
//  check-sheet-music.swift
//  SolaPraise
//
//  Checks that each song's 악보 menu is shaped by the song.
//
//  WHY THIS EXISTS: the menu offered every store for every song — an
//  어노인팅 song was sent to the 마커스 store — and searched the raw upload
//  title. The menu is built from guesses about a title, which fail quietly.
//
//  Run:
//      swiftc -O -o /tmp/sheetmusiccheck \
//          Sources/Feed/SongSearchSuggestions.swift Sources/Chords/SheetMusicSources.swift \
//          Tools/check-sheet-music.swift
//      /tmp/sheetmusiccheck
//

import Foundation

@main
struct CheckSheetMusic {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { print("       \(detail())"); failures += 1 }
        }
        func decoded(_ url: URL?) -> String { url?.absoluteString.removingPercentEncoding ?? "" }

        let anointing = SheetMusicSources.plan(title: "날 찾으신 주의 은혜 | ANOINTING CLIP", channel: "ANOINTING")
        check("an 어노인팅 song gets the 어노인팅 store", anointing.publisher?.name == "어노인팅")
        check("…and never the 마커스 store",
              !decoded(anointing.url(for: anointing.publisher!.store)).contains("markers"))
        check("the search is the clean title plus the team",
              decoded(anointing.searchURL).contains("날 찾으신 주의 은혜 어노인팅 악보")
                && !decoded(anointing.searchURL).contains("CLIP"),
              "got \(decoded(anointing.searchURL))")

        let markers = SheetMusicSources.plan(
            title: "임재 Come Holy Spirit - 마커스워십 Live Clip | A Key", channel: "MARKERS WORSHIP")
        check("a 마커스 song gets the 마커스 store", markers.publisher?.name == "마커스")
        check("its song is 임재", markers.song == "임재", "got \(markers.song)")

        let hymn = SheetMusicSources.plan(title: "찬송가 543장 어려운 일 당할 때 | 새벽기도 때 듣는 피아노 찬송가",
                                          channel: "ALL THAT HYMNㅣ올댓힘")
        check("a hymn search carries its number",
              decoded(hymn.searchURL).contains("어려운 일 당할 때 새찬송가 543장 악보"),
              "got \(decoded(hymn.searchURL))")
        check("a hymn channel is no store", hymn.publisher == nil)

        let other = SheetMusicSources.plan(title: "주 오실 그날 | 2026 Born Zeal", channel: "아이자야씩스티원 Isaiah6tyOne")
        check("a team without a known store gets searches only", other.publisher == nil)
        check("…which still name the song", other.song == "주 오실 그날", "got \(other.song)")

        // The English catalogues search the English title when there is one.
        check("English title beside the Korean",
              SheetMusicSources.englishTitle(in: "주님 뜻대로 살기로 했네 No Turning Back | 더라이트 워십 Live") == "No Turning Back",
              "got \(SheetMusicSources.englishTitle(in: "주님 뜻대로 살기로 했네 No Turning Back | 더라이트 워십 Live") ?? "nil")")
        check("English title after a slash",
              SheetMusicSources.englishTitle(in: "주님께 영광 높이 드리세 / GLORY TO THE LORD MOST HIGH - 피아워십") == "GLORY TO THE LORD MOST HIGH")
        check("「Live Clip」 is not a title",
              SheetMusicSources.englishTitle(in: "날 찾으신 주의 은혜 | ANOINTING CLIP") == nil)
        let select = SheetMusicSources.plan(title: "주님 뜻대로 살기로 했네 No Turning Back | 더라이트 워십 Live", channel: nil)
        check("SongSelect is searched with the English title",
              decoded(select.url(for: SheetMusicSources.stores[0])) == "https://songselect.ccli.com/search/results?search=No Turning Back",
              "got \(decoded(select.url(for: SheetMusicSources.stores[0])))")
        check("…and with the Korean one when there is none",
              decoded(anointing.url(for: SheetMusicSources.stores[0])).hasSuffix("search=날 찾으신 주의 은혜"))

        print(failures == 0 ? "\nall sheet music checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
