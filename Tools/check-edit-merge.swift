//
//  check-edit-merge.swift
//  SolaPraise
//
//  Checks two members' chart corrections put together: both kept when
//  they fixed different chords, the sharer's when they fixed the same
//  one, a chord taken off staying off, and nothing lost without a base.
//
//  WHY THIS EXISTS: a merge that drops a fix looks like a fix that never
//  happened — the person who made it sees the old chord come back and
//  assumes they mis-tapped.
//
//  Run:
//      swiftc -O -o /tmp/editmerge \
//          Sources/Team/EditMerge.swift Tools/check-edit-merge.swift
//      /tmp/editmerge
//

import Foundation

struct Chord: Identifiable, Equatable {
    let id: Int
    var text: String
}

@main
struct CheckEditMerge {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }
        let base = [[Chord(id: 1, text: "G"), Chord(id: 2, text: "C"), Chord(id: 3, text: "D")]]

        // Leader fixed 1, keys player fixed 3: both kept.
        var local = base; local[0][0].text = "G/B"
        var remote = base; remote[0][2].text = "Dsus4"
        expect(EditMerge.pages(base: base, local: local, remote: remote).map { $0.map(\.text) },
               [["G/B", "C", "Dsus4"]], "fixes to different chords both kept")

        // Both fixed 2: the one sharing wins.
        local = base; local[0][1].text = "Cmaj7"
        remote = base; remote[0][1].text = "C2"
        expect(EditMerge.pages(base: base, local: local, remote: remote)[0][1].text, "Cmaj7", "the sharer's on the same chord")

        // Taken off here, unchanged there: off.
        local = [[base[0][0], base[0][2]]]
        expect(EditMerge.pages(base: base, local: local, remote: base)[0].map(\.id), [1, 3], "a removal stays")
        // Taken off here, but the team corrected it since: theirs stays.
        remote = base; remote[0][1].text = "Am"
        expect(EditMerge.pages(base: base, local: local, remote: remote)[0].map(\.text), ["G", "Am", "D"],
               "a chord the team just fixed is not taken off")

        // Added here, another added there: both.
        local = base; local[0].append(Chord(id: 9, text: "E"))
        remote = base; remote[0].append(Chord(id: 8, text: "F"))
        expect(Set(EditMerge.pages(base: base, local: local, remote: remote)[0].map(\.id)), [1, 2, 3, 8, 9], "both additions")

        // No base, or a different shape: this device's chart.
        expect(EditMerge.pages(base: nil, local: local, remote: remote)[0].map(\.id), local[0].map(\.id), "no base: local")
        expect(EditMerge.pages(base: base, local: local, remote: nil)[0].map(\.id), local[0].map(\.id), "nothing shared yet: local")

        // Lists by place.
        let same: (String, String) -> Bool = { $0.prefix(1) == $1.prefix(1) }
        expect(EditMerge.list(base: ["a1"], local: ["a1", "b2"], remote: ["a1", "d4"], same: same).sorted(),
               ["a1", "b2", "d4"], "lyric fixes from both")
        expect(EditMerge.list(base: ["a1"], local: ["a2"], remote: ["a1"], same: same), ["a2"], "a lyric fix changed")

        if failures == 0 {
            print("all edit merge checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
