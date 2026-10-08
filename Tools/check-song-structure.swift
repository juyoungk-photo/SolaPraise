//
//  check-song-structure.swift
//  SolaPraise
//
//  Checks that SongStructure.detect labels a song the SAME way every run.
//
//  WHY THIS EXISTS: the chorus was picked with `max` over a dictionary of
//  progression counts. Swift seeds dictionary hashing per process, so when
//  two progressions tied — which is the ordinary case, not an edge case,
//  since in A-B-A-B-C the verse and the chorus both occur twice — the winner
//  changed between launches. The same recording came back as
//  「절 1 · 후렴 · 절 2 · 후렴」 one time and 「후렴 · 섹션 B · 후렴 · 섹션 B」
//  the next, and because each run looks perfectly reasonable on its own,
//  nothing about it reads as a bug until you happen to analyse the same song
//  twice. Twelve runs of the old code gave two different answers, 8 to 4.
//
//  A single run proves nothing here. Run it several times:
//
//      swiftc -O -o /tmp/structcheck \
//          Sources/Chords/ChordModels.swift \
//          Sources/Chords/SongStructure.swift \
//          Tools/check-song-structure.swift
//      for i in $(seq 12); do /tmp/structcheck; done | sort | uniq -c
//
//  Expected: one line, twelve times.
//
//      12 A:절 1 | B:후렴 | A:절 2 | B:후렴 | C:섹션 C
//
//  Two or more distinct lines means the tie-break has come undone again.
//

import Foundation

@main
struct CheckSongStructure {

    private static func chord(_ root: Int, _ quality: ChordQuality,
                              at time: TimeInterval) -> SessionChord {
        SessionChord(chord: Chord(root: root, quality: quality), timestamp: time)
    }

    /// The shape that breaks it: verse and chorus each twice, then a bridge.
    ///   G G/B C Dsus4 | Em7 Cmaj7 G D7 | G G/B C Dsus4 | Em7 Cmaj7 G D7 | Am Esus2 C D
    private static let progression: [(root: Int, quality: ChordQuality)] = [
        (7, .major), (7, .major), (0, .major), (2, .sus4),
        (4, .minor7), (0, .major7), (7, .major), (2, .dominant7),
        (7, .major), (7, .major), (0, .major), (2, .sus4),
        (4, .minor7), (0, .major7), (7, .major), (2, .dominant7),
        (9, .minor), (4, .sus2), (0, .major), (2, .major)
    ]

    static func main() {
        let chords = progression.enumerated().map { index, step in
            chord(step.root, step.quality, at: TimeInterval(index) * 4)
        }

        let sections = SongStructure.detect(chords: chords)
        print(sections.map { "\($0.patternKey):\($0.label)" }.joined(separator: " | "))

        // The chorus must be the part the verse leads to, not the opening.
        if let chorus = sections.first(where: { $0.label == "후렴" }), chorus.startIndex == 0 {
            FileHandle.standardError.write(
                Data("warning: the opening phrase was labelled 후렴\n".utf8))
        }
    }
}
