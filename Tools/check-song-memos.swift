//
//  check-song-memos.swift
//  SolaPraise
//
//  Checks the 곡 메모 tab: a memo found for its song however the 순서
//  spells the title, and written back over its own row.
//
//  WHY THIS EXISTS: a memo found for the wrong song is advice for a song
//  nobody is playing; one written as a second row hides the first, and the
//  two disagree. Neither looks broken. Songs here are made up.
//
//  지난 예배: a service recorded once per song and day — a second press,
//  or the same song in 1부 and 2부, must not add a second line.
//
//  Run:
//      swiftc -O -o /tmp/songmemos \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift \
//          Sources/Feed/SongSearchSuggestions.swift Sources/Feed/PlanSongTitle.swift \
//          Sources/Team/OfferingNote.swift Sources/Team/SongMemos.swift \
//          Tools/check-song-memos.swift
//      /tmp/songmemos
//

import Foundation

@main
struct CheckSongMemos {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }
        let rows: [[String]] = [
            ["곡", "메모", "고친 사람", "고친 때"],
            ["빛의 노래", "인트로 4마디, 마지막 후렴 두 번", "가람", "2026-10-11"],
            ["", "곡 없는 메모"],
            ["새벽 찬송", ""],
            ["다른 노래 (찬송가 123장)", "1, 4절만"],
        ]
        let memos = SongMemos.parse(rows)
        expect(memos.count, 2, "memos with a song and words")
        expect(SongMemos.memo(for: "[예배] 빛의 노래 | 하늘팀 2024", in: memos)?.text,
               "인트로 4마디, 마지막 후렴 두 번", "found by the song, not the video title")
        expect(SongMemos.memo(for: "[찬송가 123장] 다른 노래", in: memos)?.text, "1, 4절만", "a hymn by its number")
        expect(SongMemos.memo(for: "모르는 노래", in: memos) == nil, true, "no memo for another song")
        expect(SongMemos.row(for: "새벽 찬송", in: rows), 4, "a blank memo's row is written over")
        expect(SongMemos.row(for: "빛의 노래 (Live)", in: rows), 2, "the existing row, by song")
        expect(SongMemos.row(for: "처음 노래", in: rows), nil, "a new song gets a new row")
        expect(SongMemos.parse([["Name", "Email"]]).isEmpty, true, "not a memo tab")

        // 지난 예배.
        let day = TeamSheet.dateFormatter.date(from: "2026-10-18")!
        let sung: [SongMemos.Sung] = [
            .init(title: "빛의 노래 | 하늘팀", key: "G", notes: "인트로 4마디"),
            .init(title: "처음 노래", key: nil, notes: "헌금송 · 헌금기도 가람"),
            .init(title: "처음 노래", key: "A", notes: nil),
        ]
        expect(SongMemos.line(day: day, sung[0]), "2026-10-18 · G · 인트로 4마디", "a line: day, key, notes")
        expect(SongMemos.line(day: day, sung[1]), "2026-10-18", "the offering's bookkeeping left out")
        guard let record = SongMemos.record(day: day, songs: sung, in: rows) else {
            print("FAIL: no record"); exit(1)
        }
        expect(record.column, 4, "지난 예배 goes after 고친 때")
        expect(record.needsHeading, true, "the heading is added")
        expect(record.cells, [.init(row: 2, text: "2026-10-18 · G · 인트로 4마디")], "one cell on the song's own row")
        expect(record.newRows, [["처음 노래", "", "", "", "2026-10-18 · A"]], "a new song once, its last line kept")

        var after = rows
        after[0].append("지난 예배")
        after[1].append("2026-10-18 · G · 인트로 4마디\n2026-09-07 · A")
        after.append(["처음 노래", "", "", "", "2026-10-18 · A"])
        expect(SongMemos.isRecorded(day: day, songs: sung, in: after), true, "recorded")
        expect(SongMemos.isRecorded(day: day, songs: sung, in: rows), false, "not yet recorded")
        let again = SongMemos.record(day: day, songs: [sung[0]], in: after)
        expect(again?.needsHeading, false, "the heading is found")
        expect(again?.cells.first?.text, "2026-10-18 · G · 인트로 4마디\n2026-09-07 · A", "a second press changes nothing")
        expect(SongMemos.history(for: "빛의 노래", in: after).count, 2, "history read newest first")
        let long = (1...9).map { "2026-0\($0 < 10 ? "\($0)" : "")-01 · G" }.joined(separator: "\n")
        expect(SongMemos.lines(SongMemos.adding("2026-10-18 · G", to: long)).count, SongMemos.historyKept, "the oldest let go")

        if failures == 0 {
            print("all song memo checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
