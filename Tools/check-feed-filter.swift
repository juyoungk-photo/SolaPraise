//
//  check-feed-filter.swift
//  SolaPraise
//
//  Checks FeedFilter: what a feed's 「next」 and a 찬양 search show.
//
//  WHY THIS EXISTS: a filter fails silently. Too wide, and a sermon or a
//  team's only upload of a song simply never appears; nothing reports what
//  was left out.
//
//  Run:
//      swiftc -O -o /tmp/feedfilter \
//          Sources/Feed/SongSearchSuggestions.swift Sources/Feed/PlanSongTitle.swift \
//          Sources/Player/FeedFilter.swift Tools/check-feed-filter.swift
//      /tmp/feedfilter
//

import Foundation

@main
struct CheckFeedFilter {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok { print("       \(detail())"); failures += 1 }
    }

    typealias Item = FeedFilter.Item

    static func main() {
        let song = Item(id: "full", title: "새 노래 (팀버전) / NEW SONG", seconds: 300, channel: "어느 팀")
        let short = Item(id: "short", title: "새 노래 / NEW SONG / #shorts - 어느 팀", seconds: 58, channel: "어느 팀")
        let other = Item(id: "other", title: "다른 곡", seconds: 280, channel: "어느 팀")
        let notice = Item(id: "notice", title: "수련회 신청 안내", seconds: 90, channel: "어느 팀")
        let lone = Item(id: "lone", title: "혼자인 노래 #shorts", seconds: 45, channel: "어느 팀")

        let ids = { (items: [Item]) in items.map(\.id) }

        check("a notice is left out", !ids(FeedFilter.arrange([other, notice], skippingNotices: true,
                                                                preferringOriginals: true)).contains("notice"))
        check("a trailer is left out, in English too",
              FeedFilter.isNotice("수련회 예고편") && FeedFilter.isNotice("Conference TEASER"))
        check("a sermon is not a notice", !FeedFilter.isNotice("주일예배 설교"))
        check("a Short with its original in the list is not shown twice",
              ids(FeedFilter.arrange([short, other, song], skippingNotices: true, preferringOriginals: true))
                == ["other", "full"])
        check("a Short whose original is elsewhere is shown as the original",
              ids(FeedFilter.arrange([short, other], pool: [song], skippingNotices: true, preferringOriginals: true))
                == ["full", "other"])
        check("a Short with no original is kept, never dropped",
              ids(FeedFilter.arrange([lone, other], skippingNotices: true, preferringOriginals: true))
                == ["lone", "other"])
        check("another channel's upload is not taken for the original",
              FeedFilter.original(of: short, among: [Item(id: "x", title: song.title, seconds: 300, channel: "다른 팀")]) == nil)
        check("the video picked by hand plays as it is",
              ids(FeedFilter.arrange([short, other], pool: [song], keeping: "short",
                                     skippingNotices: true, preferringOriginals: true)) == ["short", "other"])
        check("both switched off: everything as it came",
              ids(FeedFilter.arrange([short, notice, other], pool: [song],
                                     skippingNotices: false, preferringOriginals: false)) == ["short", "notice", "other"])
        check("a 「#shorts」 title of unknown length is a Short",
              FeedFilter.isShort(Item(id: "a", title: "곡 #Shorts", seconds: nil, channel: nil)))
        check("a song over a minute is not",
              !FeedFilter.isShort(Item(id: "b", title: "곡", seconds: 75, channel: nil)))

        print(failures == 0 ? "\nall feed filter checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
