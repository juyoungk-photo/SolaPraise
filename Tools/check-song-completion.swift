//
//  check-song-completion.swift
//  SolaPraise
//
//  Checks 찬양 검색's completions: a title found while it is still being
//  typed, letter by letter inside a syllable, with or without spaces, by
//  initials — and the team's songs before a video's.
//
//  WHY THIS EXISTS: a completion that does not come looks exactly like a
//  song the app does not know. Titles here are made up.
//
//  Run:
//      swiftc -O -o /tmp/songcompletion \
//          Sources/Feed/SongCompletion.swift Tools/check-song-completion.swift
//      /tmp/songcompletion
//

import Foundation

@main
struct CheckSongCompletion {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }
        let pool: [SongCompletion.Candidate] = [
            .init(text: "빛의 노래", source: .video),
            .init(text: "빛의 노래", source: .team, detail: "10/18 · G", weight: 3),
            .init(text: "새벽을 깨우리", source: .video),
            .init(text: "주 경외함으로", source: .chosen),
            .init(text: "가라 너희는", source: .history, weight: 5),
            .init(text: "과수원 길", source: .video),
            .init(text: "닭 우는 새벽", source: .video),
            .init(text: "Way Maker", source: .video),
            .init(text: "나의 노래", source: .video),
        ]
        func first(_ query: String) -> String? { SongCompletion.suggest(query, from: pool).first?.text }

        expect(first("빛의 노"), "빛의 노래", "a finished word")
        expect(first("빛ㅇ"), "빛의 노래", "a syllable half typed")
        expect(SongCompletion.suggest("빛", from: pool).first?.source, .team, "the team's own first")
        expect(SongCompletion.suggest("빛", from: pool).count, 1, "one song, not one per source")
        expect(SongCompletion.suggest("빛", from: pool).first?.detail, "10/18 · G", "with when it was sung")
        expect(first("주경외하"), "주 경외함으로", "without spaces, mid-syllable")
        expect(first("갈"), "가라 너희는", "a final that becomes the next syllable's first")
        expect(first("고"), "과수원 길", "a compound vowel on its way")
        expect(first("달"), "닭 우는 새벽", "a compound final on its way")
        expect(first("ㅈㄱㅇㅎ"), "주 경외함으로", "by initials")
        expect(first("way m"), "Way Maker", "Latin, any case")
        expect(first("maker"), "Way Maker", "from a later word")
        expect(first("깨우"), "새벽을 깨우리", "a later word, Korean")
        expect(SongCompletion.suggest("노래", from: pool).map(\.text), ["빛의 노래", "나의 노래"], "inside a title, team first")
        expect(SongCompletion.suggest("ㄴ", from: pool).isEmpty, true, "one initial is too little")
        expect(SongCompletion.suggest("  ", from: pool).isEmpty, true, "nothing typed")
        expect(SongCompletion.suggest("빛의 노래", from: pool).isEmpty, true, "what is typed is not suggested back")
        expect(SongCompletion.matches("주경외함", title: "[찬양] 주 경외함으로 | 하늘팀"), true, "the feed's search too")
        expect(SongCompletion.matches("ㅂㅇ", title: "빛의 노래"), true, "the feed by initials")
        expect(SongCompletion.matches("파도", title: "빛의 노래"), false, "no match")

        if failures == 0 {
            print("all song completion checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
