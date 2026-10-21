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
//  지난 예배: after a service, the key it was played in and what its 순서
//  said, one line per Sunday, newest first — so the tab is also the song's
//  record, read without the app. Written from a button, after a preview.
//
//  Pure, so reading and writing are checked without a network
//  (Tools/check-song-memos.swift).
//

import Foundation

enum SongMemos {

    static let tab = "곡 메모"
    /// For a range: a tab name with a space is quoted in A1 notation.
    static let quotedTab = "'\(tab)'"
    static let header = ["곡", "메모", "고친 사람", "고친 때", historyHeader]
    static let historyHeader = "지난 예배"
    static let historyNames = [historyHeader, "history", "기록"]
    /// Sundays kept per song: enough to see a pattern, short enough to read
    /// in a cell.
    static let historyKept = 8

    struct Memo: Equatable {
        let song: String
        let text: String
        let by: String
        /// 1-based sheet row.
        let row: Int
    }

    struct Layout {
        let song: Int, memo: Int, by: Int?, at: Int?, history: Int?
        init?(header: [String]) {
            guard let song = TeamSheet.column(header, ["곡", "song", "title"]),
                  let memo = TeamSheet.column(header, ["메모", "memo", "note", "notes"]) else { return nil }
            self.song = song
            self.memo = memo
            by = TeamSheet.column(header, ["고친 사람", "by", "작성자"])
            at = TeamSheet.column(header, ["고친 때", "updated", "updatedat"])
            history = TeamSheet.column(header, SongMemos.historyNames)
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

    // MARK: - 지난 예배

    /// What a service sang one song as — its title on the 순서, the key it
    /// was played in, and the 순서's notes for it.
    struct Sung: Equatable {
        let title: String
        let key: String?
        let notes: String?
    }

    /// 「2026-10-18 · G · 인트로 4마디」. The notes lose the offering's
    /// bookkeeping — who prayed is that Sunday's, not the song's.
    static func line(day: Date, _ sung: Sung) -> String {
        let notes = OfferingNote.parse(notes: sung.notes).rest?
            .replacingOccurrences(of: "\n", with: " ")
        return [TeamSheet.dateFormatter.string(from: day), sung.key, notes]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// A history with a line added: newest first, that day's earlier line
    /// replaced rather than kept twice, the oldest let go.
    static func adding(_ line: String, to history: String) -> String {
        let day = String(line.prefix(10))
        let kept = lines(history).filter { !$0.hasPrefix(day) }
        return ([line] + kept).prefix(historyKept).joined(separator: "\n")
    }

    static func lines(_ history: String) -> [String] {
        history.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A song's 지난 예배 lines as the tab holds them, newest first.
    static func history(for song: String, in rows: [[String]]) -> [String] {
        guard let top = rows.first, let layout = Layout(header: top), let column = layout.history,
              let row = row(for: song, in: rows), rows[row - 1].indices.contains(column) else { return [] }
        return lines(rows[row - 1][column])
    }

    /// Whether every song already has a line for that day — the record
    /// was made, and making it again would change nothing.
    static func isRecorded(day: Date, songs: [Sung], in rows: [[String]]) -> Bool {
        let stamp = TeamSheet.dateFormatter.string(from: day)
        return !songs.isEmpty && songs.allSatisfy { sung in
            history(for: sung.title, in: rows).contains { $0.hasPrefix(stamp) }
        }
    }

    /// What recording a service writes: the 지난 예배 heading when the tab
    /// has none, one cell on each song's own row, and a new row for a song
    /// the tab has not met. Nothing else on a row is touched.
    struct Record: Equatable {
        /// The column 지난 예배 is in, 0-based.
        let column: Int
        let needsHeading: Bool
        var cells: [Cell] = []
        var newRows: [[String]] = []
        struct Cell: Equatable { let row: Int; let text: String }
    }

    static func record(day: Date, songs: [Sung], in rows: [[String]]) -> Record? {
        guard let top = rows.first, let layout = Layout(header: top) else { return nil }
        let column = layout.history ?? max(top.count, header.count - 1)
        var plan = Record(column: column, needsHeading: layout.history == nil)
        // Rows as they will be, so a song sung twice that day is one line.
        var sheet = rows
        if plan.needsHeading {
            while sheet[0].count <= column { sheet[0].append("") }
            sheet[0][column] = historyHeader
        }
        for sung in songs {
            let title = PlanSongTitle.forSheet(sung.title).title
            guard !title.isEmpty else { continue }
            let text = line(day: day, sung)
            if let row = row(for: sung.title, in: sheet) {
                var cells = sheet[row - 1]
                while cells.count <= column { cells.append("") }
                cells[column] = adding(text, to: cells[column])
                sheet[row - 1] = cells
                plan.cells.removeAll { $0.row == row }
                if row <= rows.count {
                    plan.cells.append(.init(row: row, text: cells[column]))
                } else if let index = plan.newRows.indices.first(where: { rows.count + 1 + $0 == row }) {
                    plan.newRows[index] = cells
                }
            } else {
                var cells = Array(repeating: "", count: column + 1)
                cells[layout.song] = title
                cells[column] = text
                sheet.append(cells)
                plan.newRows.append(cells)
            }
        }
        return plan
    }
}
