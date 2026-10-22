//
//  check-corrections-tab.swift
//  SolaPraise
//
//  Checks the hidden 「교정」 tab's index: each chart's row and writing,
//  found from three columns; the header row and blank rows skipped; a
//  chart written twice found at its later row.
//
//  WHY THIS EXISTS: a chart found at the wrong row is written over another
//  chart's corrections, and one not found gets a second row that the next
//  read may not see. Neither looks broken until a fix goes missing.
//
//  Run:
//      swiftc -O -o /tmp/correctionstab \
//          Sources/Team/CorrectionsTab.swift Tools/check-corrections-tab.swift
//      /tmp/correctionstab
//

import Foundation

@main
struct CheckCorrectionsTab {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }
        let files = ["파일", "fileA", "fileB", "", "fileA", "fileC"]
        let parts = ["부분", "all", "pages:0,1", "", "pages:2", "all"]
        let revisions = ["버전", "3", "1", "", "7", "x"]
        let index = CorrectionsTab.index(files: files, parts: parts, revisions: revisions)
        expect(index.count, 4, "every chart part, no header, no blank row")
        expect(index[CorrectionsTab.key(fileId: "fileA", part: "all")], .init(row: 2, revision: 3), "a whole chart")
        expect(index[CorrectionsTab.key(fileId: "fileA", part: "pages:2")], .init(row: 5, revision: 7), "one song of a 콘티 file")
        expect(index[CorrectionsTab.key(fileId: "fileC", part: "all")]?.revision, 0, "a writing that is not a number")

        let twice = CorrectionsTab.index(files: ["파일", "f", "f"], parts: ["부분", "all", "all"], revisions: ["버전", "1", "2"])
        expect(twice[CorrectionsTab.key(fileId: "f", part: "all")], .init(row: 3, revision: 2), "written twice: the later row")

        expect(CorrectionsTab.Layout(header: CorrectionsTab.header), CorrectionsTab.Layout.standard, "the tab's own header")
        expect(CorrectionsTab.Layout(header: ["Name", "Email"]) == nil, true, "not this tab")
        expect(CorrectionsTab.token(4), "tab#4", "remembered as")

        if failures == 0 {
            print("all corrections tab checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
