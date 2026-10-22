//
//  check-edits-token.swift
//  SolaPraise
//
//  Checks the Edits cell: a file and which writing of it, read back as
//  written, and a cell from before (an id alone) still read.
//
//  WHY THIS EXISTS: a cell misread is corrections fetched from nowhere —
//  the chart quietly shows its uncorrected chords, which looks like a
//  teammate's fix never arrived.
//
//  Run:
//      swiftc -O -o /tmp/editstoken \
//          Sources/Team/EditsToken.swift Tools/check-edits-token.swift
//      /tmp/editstoken
//

import Foundation

@main
struct CheckEditsToken {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }
        let token = EditsToken(fileId: "abcDEF_123-x", revision: 4)
        expect(token.cell, "abcDEF_123-x#4", "written")
        expect(EditsToken(token.cell), token, "read back")
        expect(EditsToken(" abcDEF_123-x ")?.revision, 0, "an id alone, from before")
        expect(EditsToken(" abcDEF_123-x ")?.fileId, "abcDEF_123-x", "its id")
        expect(EditsToken(""), nil, "empty")
        expect(EditsToken(nil), nil, "no cell")
        expect(EditsToken("abc#x")?.revision, 0, "a number that is not one")
        expect(token.next.cell, "abcDEF_123-x#5", "written over: the same file, the next writing")
        expect(EditsToken(token.cell) == EditsToken(token.next.cell), false, "a writing over is a change")

        if failures == 0 {
            print("all edits token checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
