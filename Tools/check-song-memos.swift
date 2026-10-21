//
//  check-song-memos.swift
//  SolaPraise
//
//  Checks the 곡 메모 tab: a memo found for its song however the 순서
//  spells the title, and written back over its own row.
//
//  WHY THIS EXISTS: a memo found for the wrong song is advice for a song
//  nobody is playing; one written as a second row hides the first, and the
//  two disagree. Neither looks broken. Songs here are made up.
//
//  Run:
//      swiftc -O -o /tmp/songmemos \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift \
//          Sources/Feed/SongSearchSuggestions.swift Sources/Feed/PlanSongTitle.swift \
//          Sources/Team/SongMemos.swift Tools/check-song-memos.swift
//      /tmp/songmemos
//

import Foundation

@main
struct CheckSongMemos {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }
        let rows: [[String]] = [
            ["곡", "메모", "고친 사람", "고친 때"],
            ["빛의 노래", "인트로 4마디, 마지막 후렴 두 번", "가람", "2026-10-11"],
            ["", "곡 없는 메모"],
            ["새벽 찬송", ""],
            ["다른 노래 (찬송가 123장)", "1, 4절만"],
        ]
        let memos = SongMemos.parse(rows)
        expect(memos.count, 2, "memos with a song and words")
        expect(SongMemos.memo(for: "[예배] 빛의 노래 | 하늘팀 2024", in: memos)?.text,
               "인트로 4마디, 마지막 후렴 두 번", "found by the song, not the video title")
        expect(SongMemos.memo(for: "[찬송가 123장] 다른 노래", in: memos)?.text, "1, 4절만", "a hymn by its number")
        expect(SongMemos.memo(for: "모르는 노래", in: memos) == nil, true, "no memo for another song")
        expect(SongMemos.row(for: "새벽 찬송", in: rows), 4, "a blank memo's row is written over")
        expect(SongMemos.row(for: "빛의 노래 (Live)", in: rows), 2, "the existing row, by song")
        expect(SongMemos.row(for: "처음 노래", in: rows), nil, "a new song gets a new row")
        expect(SongMemos.parse([["Name", "Email"]]).isEmpty, true, "not a memo tab")

        if failures == 0 {
            print("all song memo checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
