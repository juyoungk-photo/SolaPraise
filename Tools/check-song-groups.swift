//
//  check-song-groups.swift
//  SolaPraise
//
//  Checks search results gathered by song: the same song under its
//  different packagings is one group, other songs are not swallowed by it,
//  and the order given is kept. Titles here are made up.
//
//  WHY THIS EXISTS: a version folded under the wrong song is a version
//  nobody finds; two songs merged hides one of them. Neither looks broken.
//
//  Run:
//      swiftc -O -o /tmp/songgroups \
//          Sources/Feed/SongSearchSuggestions.swift Sources/Feed/PlanSongTitle.swift \
//          Sources/Feed/SongGroups.swift Tools/check-song-groups.swift
//      /tmp/songgroups
//

import Foundation

@main
struct CheckSongGroups {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }
        let titles = [
            "빛의 노래 | 하늘팀 2024",
            "[LIVE] 빛의 노래 - 하늘팀 예배",
            "새벽을 깨우리 | 바다워십",
            "빛의 노래 (Official MV)",
            "[찬송가 123장] 다른 노래",
            "다른 노래 | 피아노",
            "빛의 노래 + 새벽을 깨우리 | 메들리",
            "새벽을 깨우리 Wake the Dawn | 들꽃팀",
            "찬송가 123장 다른 노래의 옛 이름",
        ]
        let groups = SongGroups.group(titles, title: { $0 })
        expect(groups.map(\.items.count), [3, 2, 3, 1], "versions folded under their song")
        expect(groups[1].items.last, "새벽을 깨우리 Wake the Dawn | 들꽃팀", "the English name after the Korean")
        expect(groups[2].items.last, "찬송가 123장 다른 노래의 옛 이름", "one hymn, two wordings")
        expect(groups.first?.items, ["빛의 노래 | 하늘팀 2024", "[LIVE] 빛의 노래 - 하늘팀 예배", "빛의 노래 (Official MV)"],
               "in the order given")
        expect(groups[1].song, "새벽을 깨우리", "the song, not the title")
        expect(groups.last?.items.count, 1, "a medley is its own")
        expect(SongGroups.group([String](), title: { $0 }).isEmpty, true, "nothing in, nothing out")

        if failures == 0 {
            print("all song group checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
