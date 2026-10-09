//
//  check-song-structure.swift
//  SolaPraise
//
//  Checks SongStructure against chord streams shaped like real detection
//  output, not like a tidy chart.
//
//  WHY THIS EXISTS: the first version of the detector found no repeats at
//  all on real songs — every section got its own letter and 곡의 흐름 showed
//  six differently-coloured blocks for a two-part song. Nothing crashed and
//  nothing logged; it simply produced confident nonsense. The three causes
//  are all invisible from a tidy test:
//
//    1. Seventeen chord qualities, and `history` appends on ANY change — so
//       one sustained G arrives as G, Gmaj7, G6, Gadd9, G.
//    2. Chunking counts EVENTS, so one spurious event shifts every boundary
//       after it and a perfectly repeated chorus never lines up twice.
//    3. A 0.3-second flicker weighed as much as a four-bar chord.
//
//  So every case here feeds the flicker in deliberately. A suite of clean
//  four-chord phrases would have passed against the broken code.
//
//  Run:
//      swiftc -O -o /tmp/sscheck \
//          Sources/Chords/ChordModels.swift \
//          Sources/Chords/SongStructure.swift \
//          Tools/check-song-structure.swift
//      /tmp/sscheck
//

import Foundation

@main
struct CheckSongStructure {

    /// Builds a chord stream the way the detector reports one.
    struct Builder {
        var out: [SessionChord] = []
        var t: TimeInterval = 0

        /// A chord held for `bars` bars, optionally flickering to another
        /// quality partway through — which is what really comes out.
        mutating func play(_ root: Int, _ q: ChordQuality,
                           bars: Double = 1, flickerTo: ChordQuality? = nil) {
            let dur = bars * 2.0
            guard let f = flickerTo else {
                out.append(SessionChord(chord: Chord(root: root, quality: q), timestamp: t))
                t += dur
                return
            }
            out.append(SessionChord(chord: Chord(root: root, quality: q), timestamp: t))
            t += dur * 0.45
            out.append(SessionChord(chord: Chord(root: root, quality: f), timestamp: t))
            t += dur * 0.10
            out.append(SessionChord(chord: Chord(root: root, quality: q), timestamp: t))
            t += dur * 0.45
        }
    }

    // G D Em Am  /  C G F D — four-chord phrases that do not share a seam.
    static func verse(_ b: inout Builder) {
        b.play(7, .major, flickerTo: .major7); b.play(2, .major)
        b.play(4, .minor); b.play(9, .minor)
    }
    static func chorus(_ b: inout Builder) {
        b.play(0, .major); b.play(7, .major, flickerTo: .sixth)
        b.play(5, .major); b.play(2, .major)
    }
    static func bridge(_ b: inout Builder) {
        b.play(9, .minor); b.play(5, .major); b.play(0, .major); b.play(7, .major)
    }

    static func main() {
        var failures = 0

        // The shape nearly every worship song has.
        var song = Builder()
        for _ in 0..<2 { verse(&song); chorus(&song) }
        bridge(&song); chorus(&song)
        let result = SongStructure.analyse(chords: song.out)
        let letters = result.sections.map(\.patternKey).joined()
        let labels = result.sections.map(\.label)

        check(&failures, "A B A B C B recovered from flicker",
              letters == "ABABCB", "got \(letters)")
        check(&failures, "the repeated verse is 절, not a new section",
              labels.filter { $0.hasPrefix("절") }.count == 2, "got \(labels)")
        check(&failures, "the chorus is named 후렴",
              labels.filter { $0 == "후렴" }.count == 3, "got \(labels)")
        check(&failures, "flicker was dropped",
              result.quality.dropped > 0 && result.quality.events < result.quality.rawEvents,
              "raw \(result.quality.rawEvents), kept \(result.quality.events)")
        check(&failures, "most of the song is in a repeated part",
              result.quality.repeatedShare >= 0.7,
              "repeated \(result.quality.repeatedShare)")

        // One chord genuinely misheard in a repeat must not split the section.
        var slip = Builder()
        verse(&slip); chorus(&slip); verse(&slip)
        slip.play(0, .major); slip.play(7, .major); slip.play(5, .major); slip.play(3, .major)
        bridge(&slip); chorus(&slip)
        let slipped = SongStructure.analyse(chords: slip.out)
        check(&failures, "one wrong chord still matches its section",
              slipped.sections.map(\.patternKey).joined() == "ABABCB",
              "got \(slipped.sections.map(\.patternKey).joined())")

        // Input too thin to say anything must SAY so rather than invent.
        var thin = Builder()
        verse(&thin)
        let thinResult = SongStructure.analyse(chords: thin.out)
        check(&failures, "a single verse reports no repetition",
              thinResult.quality.findings.contains(.noRepetition),
              "findings \(thinResult.quality.findings)")
        check(&failures, "a single verse is not trustworthy",
              !thinResult.quality.isTrustworthy, "it claimed to be")

        var junk = Builder()
        for i in 0..<40 { junk.play((i * 5) % 12, .major, bars: 0.12) }
        let junkResult = SongStructure.analyse(chords: junk.out)
        check(&failures, "pure flicker is reported as too few chords",
              junkResult.quality.findings.contains(.tooFewChords),
              "findings \(junkResult.quality.findings)")

        // Determinism: dictionary order is randomised per process, and the
        // chorus pick once changed between launches for the same song.
        let again = SongStructure.analyse(chords: song.out)
        check(&failures, "same input, same labels",
              again.sections.map(\.label) == labels, "labels moved")

        print(failures == 0
              ? "\nall song structure checks passed"
              : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    static func check(_ failures: inout Int, _ name: String,
                      _ ok: Bool, _ detail: @autoclosure () -> String) {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok { print("       \(detail())"); failures += 1 }
    }
}
