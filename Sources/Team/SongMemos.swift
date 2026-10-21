//
//  SongMemos.swift
//  SolaPraise
//
//  곡 메모: what the team knows about a song — the intro, the ending, which
//  bridge is repeated, the key it suits — kept on the sheet's 곡 메모 tab,
//  one row per song, and found again every time the song comes round.
//
//  WHY: a 순서's Notes cell belongs to one Sunday. 「인트로 4마디, 2절 후
//  간주 없이」 written there was gone the next time the song was sung, and
//  the team worked it out again. On its own tab, by song, it builds up —
//  and it is a tab a member reads and edits without the app.
//
//  Pure, so reading and writing are checked without a network
//  (Tools/check-song-memos.swift).
//

import Foundation

enum SongMemos {

    static let tab = "곡 메모"
    static let header = ["곡", "메모", "고친 사람", "고친 때"]

    struct Memo: Equatable {
        let song: String
        let text: String
        let by: String
        /// 1-based sheet row.
        let row: Int
    }

    struct Layout {
        let song: Int, memo: Int, by: Int?, at: Int?
        init?(header: [String]) {
            guard let song = TeamSheet.column(header, ["곡", "song", "title"]),
                  let memo = TeamSheet.column(header, ["메모", "memo", "note", "notes"]) else { return nil }
            self.song = song
            self.memo = memo
            by = TeamSheet.column(header, ["고친 사람", "by", "작성자"])
            at = TeamSheet.column(header, ["고친 때", "updated", "updatedat"])
        }
    }

    /// Every memo with words in it.
    static func parse(_ rows: [[String]]) -> [Memo] {
        guard let top = rows.first, let layout = Layout(header: top) else { return [] }
        return rows.enumerated().compactMap { offset, row in
            guard offset > 0 else { return nil }
            func cell(_ i: Int?) -> String {
                guard let i, row.indices.contains(i) else { return "" }
                return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let song = cell(layout.song), text = cell(layout.memo)
            guard !song.isEmpty, !text.isEmpty else { return nil }
            return Memo(song: song, text: text, by: cell(layout.by), row: offset + 1)
        }
    }

    /// The memo for a song, however its title is spelled on the 순서 —
    /// 「[찬송가 546장] 곡 | 팀」 and 「곡」 are one song.
    static func memo(for song: String, in memos: [Memo]) -> Memo? {
        memos.last { PlanSongTitle.sameSong($0.song, song) }
    }

    /// The 1-based row a song's memo is on (blank memos included), to
    /// write over rather than add a second one.
    static func row(for song: String, in rows: [[String]]) -> Int? {
        guard let top = rows.first, let layout = Layout(header: top) else { return nil }
        let match = rows.indices.last { offset in
            offset > 0 && rows[offset].indices.contains(layout.song)
                && PlanSongTitle.sameSong(rows[offset][layout.song].trimmingCharacters(in: .whitespaces), song)
        }
        return match.map { $0 + 1 }
    }
}
