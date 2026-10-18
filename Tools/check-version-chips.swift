//
//  check-version-chips.swift
//  SolaPraise
//
//  Checks the short names the stand gives a song's chart versions.
//
//  WHY THIS EXISTS: two chips that read the same are two buttons nobody
//  can tell apart, and a name cut in the wrong place drops exactly the
//  part — the 콘티 version, the day — that told them apart. Neither looks
//  broken; the wrong chart just opens.
//
//  Run:
//      swiftc -O -o /tmp/versionchips \
//          Sources/Team/VersionChips.swift Tools/check-version-chips.swift
//      /tmp/versionchips
//

import Foundation

@main
struct CheckVersionChips {
    static func main() {
        var failures = 0
        func expect(_ got: [String], _ want: [String], _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }

        // As ServicePrepView.songVersions writes them.
        expect(VersionChips.names([
            "콘티 20261018 주일 2부예배 찬양 v2 · 3쪽",
            "콘티 20261018 주일 2부예배 찬양 v1 · 2–3쪽",
            "악보 20261018-곡-1760000000-AB12.jpg · 10/12 올림",
        ]), ["콘티 v2", "콘티 v1", "악보 10/12"], "콘티 versions and an upload")

        // Spellings of a version on a 콘티 people named themselves.
        expect(VersionChips.names([
            "콘티 1018 찬양 ver.3 · 1쪽",
            "콘티 1018 찬양(v4) · 1쪽",
            "콘티 1018 찬양_V5 · 1쪽",
        ]), ["콘티 v3", "콘티 v4", "콘티 v5"], "version spellings")

        // No version in the name; two uploads the same day; no date at all.
        expect(VersionChips.names([
            "콘티 1018 찬양 · 2쪽",
            "악보 a.pdf · 10/12 올림",
            "악보 b.pdf · 10/12 올림",
            "악보 리드시트 원본 스캔본 최종.pdf",
        ]), ["콘티", "악보 10/12", "악보 10/12 (2)", "악보 리드시트 원본 스캔…"], "fallbacks and duplicates")

        // Named after the song: the title is not repeated; the key in the
        // name is shown, dated or not.
        let song = "주님 곡"
        expect(VersionChips.names([
            "악보 주님 곡 (A).pdf · 10/17 올림",
            "악보 주님 곡.pdf",
            "악보 주님 곡 (F#m).pdf",
            "악보 다른 이름.pdf",
            "악보 주님 곡 리드시트 (G).pdf",
        ], songs: [song]), ["악보 10/17 (A)", "악보", "악보 (F#m)", "악보 다른 이름", "악보 리드시트 (G)"],
           "named after the song")

        // A version with no label: the file's own name, without extension.
        expect(VersionChips.names(["chart.pdf", "chart.pdf"]), ["chart", "chart (2)"], "unlabelled")

        if failures == 0 {
            print("all version chip checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
