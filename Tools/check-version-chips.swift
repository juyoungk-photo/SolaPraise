//
//  check-version-chips.swift
//  SolaPraise
//
//  Checks the short names the stand gives a song's chart versions.
//
//  WHY THIS EXISTS: two chips that read the same are two buttons nobody
//  can tell apart, and a name cut in the wrong place drops exactly the
//  part — the 콘티 version, the key, who put it up — that told them apart.
//  Neither looks broken; the wrong chart just opens.
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
        typealias V = VersionChips.Version

        // As ServicePrepView.songVersions writes them; an upload's
        // generated name says nothing, its key and uploader do.
        expect(VersionChips.names([
            V(label: "콘티 20261018 주일 2부예배 찬양 v2 · 3쪽"),
            V(label: "콘티 20261018 주일 2부예배 찬양 v1 · 2–3쪽"),
            V(label: "악보 20261018-곡-1760000000-AB12.jpg · 10/12 올림", key: "G", by: "주영"),
        ]), ["콘티 v2", "콘티 v1", "악보 G · 주영"], "콘티 versions and an upload")

        // Spellings of a version on a 콘티 people named themselves.
        expect(VersionChips.names([
            V(label: "콘티 1018 찬양 ver.3 · 1쪽"),
            V(label: "콘티 1018 찬양(v4) · 1쪽"),
            V(label: "콘티 1018 찬양_V5 · 1쪽"),
        ]), ["콘티 v3", "콘티 v4", "콘티 v5"], "version spellings")

        // The key in the name wins over the key read; the name's own words
        // stay once the song's title is taken off.
        let song = "주님 곡"
        expect(VersionChips.names([
            V(label: "악보 주님 곡 (A).pdf · 10/17 올림", key: "G", by: "은혜"),
            V(label: "악보 주님 곡.pdf", key: "G"),
            V(label: "악보 주님 곡 리드시트 (G).pdf"),
            V(label: "악보 다른 이름.pdf"),
        ], songs: [song]), ["악보 A · 은혜", "악보 G", "악보 G · 리드시트", "악보 다른 이름"], "key, words, uploader")

        // Alike otherwise: the day, where it differs; then a number.
        expect(VersionChips.names([
            V(label: "악보 a.pdf · 10/12 올림", key: "G", by: "주영"),
            V(label: "악보 a.pdf · 10/15 올림", key: "G", by: "주영"),
        ]), ["악보 G · a · 주영 · 10/12", "악보 G · a · 주영 · 10/15"], "the day separates")
        expect(VersionChips.names([
            V(label: "악보 x.pdf · 10/12 올림"),
            V(label: "악보 x.pdf · 10/12 올림"),
        ]), ["악보 x", "악보 x (2)"], "numbered when nothing else separates")

        // Nothing known: just 악보.
        expect(VersionChips.names([V(label: "악보 20261018-곡-1760000000-AB12.jpg")]), ["악보"], "nothing known")

        // A version with no label: the file's own name, without extension.
        expect(VersionChips.names([V(label: "chart.pdf"), V(label: "chart.pdf")]),
               ["파일 chart", "파일 chart (2)"], "unlabelled")

        if failures == 0 {
            print("all version chip checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
