//
//  check-song-suggestions.swift
//  SolaPraise
//
//  Checks what the player suggests searching next.
//
//  WHY THIS EXISTS: every part of this is a heuristic over text that teams
//  format however they like, and each part fails quietly. A title cleaned
//  too little searches for one upload instead of the song. A credit line
//  taken for a lyric suggests searching "Vocal 김은혜". A hook found where
//  there is none invents a confession the song does not make. None of these
//  throws; they just make the suggestions useless.
//
//  The main case is the one the feature was described with: 「어려운 일 당할
//  때」, whose hook is 「예수 의지합니다」 and whose first line is its title.
//
//  Run:
//      swiftc -O -o /tmp/suggestcheck \
//          Sources/Feed/SongSearchSuggestions.swift Tools/check-song-suggestions.swift
//      /tmp/suggestcheck
//

import Foundation

@main
struct CheckSongSuggestions {

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
        // A description shaped like a real worship upload: credits, a link,
        // a set list, then the lyrics with the chorus repeated.
        let description = """
        찬송가 543장 어려운 일 당할 때 (통일 342장)
        Vocal 김은혜 · Piano 박주영
        작사: Arthur Simpson / 편곡: 피아워십
        https://www.instagram.com/fiaworship
        #찬송가 #어려운일당할때

        00:00 어려운 일 당할 때
        03:12 기도

        어려운 일 당할 때
        나의 믿음 적으나
        의지하는 내 주님
        더욱 의지합니다
        예수 의지합니다
        예수 의지합니다
        어려운 일 당할 때
        예수 의지합니다
        """

        let title = "어려운 일 당할 때 (피아버전) / SIMPLY TRUSTING EVERY DAY (FIA.Ver) - 피아워십"
        let suggestions = SongSearchSuggestions.make(title: title, description: description)
        let byKind = Dictionary(grouping: suggestions, by: \.kind)
        print("suggested:", suggestions.map { "\($0.caption)=\($0.query)" })

        check("title is cleaned to the song's name",
              byKind[.title]?.first?.query == "어려운 일 당할 때",
              "got \(byKind[.title]?.first?.query ?? "nil")")
        check("the hymn number is found",
              byKind[.hymn]?.first?.query == "찬송가 543장",
              "got \(byKind[.hymn]?.first?.query ?? "nil")")
        check("the hook is the repeated line",
              byKind[.hook]?.first?.query == "예수 의지합니다",
              "got \(byKind[.hook]?.first?.query ?? "nil")")
        check("the first line is dropped because it IS the title",
              byKind[.firstLine] == nil,
              "got \(byKind[.firstLine]?.first?.query ?? "nil")")
        check("no credit line is taken for a lyric",
              !suggestions.contains { $0.query.contains("Vocal") || $0.query.contains("작사") })
        check("no two suggestions search the same thing",
              Set(suggestions.map { SongSearchSuggestions.normalised($0.query) }).count
              == suggestions.count)

        // Title cleaning on its own, across the shapes uploads take.
        let titles: [(String, String)] = [
            ("주님 뜻대로 살기로 했네 No Turning Back | 더라이트 워십 Live", "주님 뜻대로 살기로 했네"),
            ("[4k] 나의 믿음 주께 있네 (Solo. 범키) - 피아워십", "나의 믿음 주께 있네"),
            ("주의 약속하신 말씀 위에 서 Standing On The Promises", "주의 약속하신 말씀 위에 서"),
            ("【MV】 은혜", "은혜")
        ]
        for (raw, want) in titles {
            let got = SongSearchSuggestions.clean(raw)
            check("clean: \(want)", got == want, "got \"\(got)\"")
        }

        // Scripture, and the bare "N장" that is NOT a hymn.
        check("a psalm is found",
              ScriptureReferenceText.passage(in: "오늘의 말씀 시편 23편 묵상") == "시편 23편",
              "got \(ScriptureReferenceText.passage(in: "오늘의 말씀 시편 23편 묵상") ?? "nil")")
        check("a verse range is found",
              ScriptureReferenceText.passage(in: "본문: 요한복음 3:16") == "요한복음 3:16",
              "got \(ScriptureReferenceText.passage(in: "본문: 요한복음 3:16") ?? "nil")")
        check("시편 23장 is a chapter, not hymn 23",
              SongSearchSuggestions.hymnNumber(in: "시편 23장 낭독") == nil,
              "got \(SongSearchSuggestions.hymnNumber(in: "시편 23장 낭독").map(String.init) ?? "nil")")

        // THE CASE THAT SHIPPED BROKEN: English role, then a Korean name.
        // Every one of these contains Hangul, and 「Lyrics 김작사」 was offered
        // as the song's first line. Names here are placeholders.
        let credits = """
        Lyrics 김작사
        Music 김작곡
        Worship Leader 박인도, 이찬양
        Vocals 최보컬, 정보컬
        Piano 한건반
        B.Guitar 윤베이스 ( https://www.youtube.com/@example )
        Color graded by 오영상
        Mixed by 서믹스 @Studio
        Arrangement by 예시워십
        Location 예시교회 (서울)
        Special Thanks to 후원자들
        *목요 예배 영상은 매주 목요일에 업로드 됩니다.
        """
        let fromCredits = SongSearchSuggestions.lyricLines(in: credits)
        check("a credit block yields no lyric lines",
              fromCredits.isEmpty, "got \(fromCredits)")
        let creditSuggestions = SongSearchSuggestions.make(
            title: "주님께 영광 높이 드리세 / GLORY TO THE LORD MOST HIGH - 예시워십",
            description: credits)
        check("credits never become 첫소절 or 중심 가사",
              !creditSuggestions.contains { $0.kind == .firstLine || $0.kind == .hook },
              "got \(creditSuggestions.map { "\($0.caption)=\($0.query)" })")

        // THE SECOND CASE THAT SHIPPED BROKEN: once credits were caught, a
        // contact line became the 첫소절. It has Hangul and is not a credit.
        let contact = """
        Location 예시교회
        *사역 및 후원 문의
        ☎️032-000-0000 (오전 9시  - 오후 6시)
        📞010-0000-0000 (오전 9시  - 오후 6시)
        매주 목요일 저녁에 업로드 됩니다
        """
        let fromContact = SongSearchSuggestions.make(title: "은혜 | 예시", description: contact)
        check("a contact block yields no 첫소절 or 중심 가사",
              !fromContact.contains { $0.kind == .firstLine || $0.kind == .hook },
              "got \(fromContact.map { "\($0.caption)=\($0.query)" })")
        check("a phone line is never a lyric",
              !SongSearchSuggestions.lyricLines(in: contact).contains { $0.contains("오전") })
        check("one stray Korean sentence is not a lyric block",
              SongSearchSuggestions.lyricBlock(in: contact).isEmpty,
              "got \(SongSearchSuggestions.lyricBlock(in: contact))")

        // And a real lyric block, with no title collision, does give 첫소절.
        let verse = """
        크신 주께 영광돌리세
        날 위해 십자가 지신 주
        그 사랑 끝이 없도다
        """
        let withVerse = SongSearchSuggestions.make(title: "영광의 찬송 | 예시", description: verse)
        check("a genuine lyric block gives its first line",
              withVerse.first { $0.kind == .firstLine }?.query == "크신 주께 영광돌리세",
              "got \(withVerse.map { "\($0.caption)=\($0.query)" })")

        // A song with no lyrics in its description offers what it has and
        // invents nothing.
        let bare = SongSearchSuggestions.make(title: "은혜 | 손경민", description: "Live at 2026")
        check("no lyrics → no hook and no first line",
              !bare.contains { $0.kind == .hook || $0.kind == .firstLine },
              "got \(bare.map(\.caption))")
        check("no lyrics → still offers the title",
              bare.first?.query == "은혜", "got \(bare.first?.query ?? "nil")")

        print(failures == 0 ? "\nall suggestion checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
