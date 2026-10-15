//
//  check-lyric-check.swift
//  SolaPraise
//
//  Checks LyricCheck: the 코드표's lyrics against a description's.
//
//  WHY THIS EXISTS: a check that cries wolf on a correct line is ignored,
//  and one that passes a misread line is worse than none. The lines here
//  are made up for the test.
//
//  Run:
//      swiftc -O -o /tmp/lyriccheck \
//          Sources/Chords/LyricCheck.swift Tools/check-lyric-check.swift
//      /tmp/lyriccheck
//

import Foundation

@main
struct CheckLyricCheck {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok { print("       \(detail())"); failures += 1 }
    }

    static func syllables(_ text: String) -> [String] { text.map(String.init).filter { $0 != " " } }

    static func main() {
        let description = ["아침 햇살 비추는 날", "주님 손을 잡고 걸으며", "노래하네 노래하네"]

        let right = LyricCheck.compare(lines: [syllables("주님손을잡고걸으며")], referenceLines: description)[0]
        check("a line as printed agrees", right.agrees, "\(right)")

        let misread = LyricCheck.compare(lines: [syllables("주님손을잡고걸으묘")], referenceLines: description)[0]
        check("a misread syllable is marked, and only it", misread.differs == [8], "\(misread)")
        check("with the description's text beside it", misread.reference == "주님손을잡고걸으며", "\(misread)")

        let dropped = LyricCheck.compare(lines: [syllables("아침햇비추는날")], referenceLines: description)[0]
        check("a dropped syllable is marked where it went missing", dropped.found && !dropped.differs.isEmpty, "\(dropped)")

        let other = LyricCheck.compare(lines: [syllables("전혀다른가사한줄입니다")], referenceLines: description)[0]
        check("a line the description does not have is not found", !other.found, "\(other)")

        let empty = LyricCheck.compare(lines: [syllables("주님손을")], referenceLines: [])[0]
        check("no description: nothing found, nothing marked", !empty.found && empty.differs.isEmpty)

        print(failures == 0 ? "\nall lyric check checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
