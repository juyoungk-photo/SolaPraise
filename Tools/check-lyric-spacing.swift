//
//  check-lyric-spacing.swift
//  SolaPraise
//
//  Checks the word spacing put back into lyrics read off a score, and the
//  correction of syllables recognition confuses.
//
//  WHY THIS EXISTS: a lead sheet prints one syllable per note with no word
//  spacing. Wrong spacing reads as a different sentence to the singer —
//  「귀하신만 왕의」 — and nothing reports it. The lines below are written
//  for this check, not taken from any song.
//
//  Run:
//      swiftc -O -o /tmp/lyricspacing \
//          Sources/Chords/LyricSpacing.swift Tools/check-lyric-spacing.swift
//      /tmp/lyricspacing
//

import Foundation

@main
struct CheckLyricSpacing {

    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
            failures += 1
        }
    }

    static func spaced(_ line: String) -> String {
        LyricSpacing.space(line.map(String.init)).text
    }

    static func main() {
        let cases: [(String, String, String)] = [
            ("주님의은혜를찬양하며영원히경배하리", "주님의 은혜를 찬양하며 영원히 경배하리",
             "particles and endings close words"),
            ("거룩하신만왕의왕께나아가", "거룩하신 만왕의 왕께 나아가",
             "an ending that describes the next word closes the word"),
            ("나의평생주님만을따르리라", "나의 평생 주님만을 따르리라", "particle chains: 만을"),
            ("어린양되신주를사랑합니다", "어린양 되신 주를 사랑합니다", "되다 is a word of its own"),
            ("어려운때에도기도로나아가", "어려운 때에도 기도로 나아가",
             "no ending after a particle — 때에도 기도로, not 때에도기도로"),
            ("세상끝날까지주를의지할것뿐일세", "세상 끝날까지 주를 의지할 것뿐일세", "뿐 takes an ending"),
        ]
        for (input, expected, name) in cases {
            let got = spaced(input)
            check(name, got == expected, "got 「\(got)」")
        }

        // Recognition's confusions, put right only where it makes words.
        check("묘 read for 며 is corrected", spaced("찬양하묘경배하리") == "찬양하며 경배하리",
              "got 「\(spaced("찬양하묘경배하리"))」")
        check("추 read for 주 is corrected", spaced("나의추님") == "나의 주님", "got 「\(spaced("나의추님"))」")
        check("사람 before 하 is 사랑", spaced("사람하며따르리") == "사랑하며 따르리",
              "got 「\(spaced("사람하며따르리"))」")
        check("a stray 힣 is dropped", spaced("귀하힣신주") == "귀하신 주", "got 「\(spaced("귀하힣신주"))」")
        check("a reading that is already Korean is left alone", spaced("사람의아들") == "사람의 아들",
              "got 「\(spaced("사람의아들"))」")

        // Syllables stay aligned with the notes: one in, one out, unless a
        // stray stroke was dropped.
        let result = LyricSpacing.space("찬양하며경배".map(String.init))
        check("one syllable out per syllable in", result.syllables.count == 6 && result.startsWord.count == 6)
        let stray = LyricSpacing.space("귀하힣신".map(String.init))
        check("a dropped stray keeps its place, as nothing",
              stray.syllables == ["귀", "하", "", "신"] && stray.text == "귀하신", "got \(stray.syllables)")
        check("non-Korean passes through as its own word",
              LyricSpacing.space(["Ha", "le", "lu", "jah"]).startsWord == [true, true, true, true])

        print(failures == 0 ? "\nall lyric spacing checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
