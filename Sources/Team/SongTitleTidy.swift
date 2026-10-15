//
//  SongTitleTidy.swift
//  SolaPraise
//
//  The Songs and Attachments tabs, from video titles to song titles.
//
//  WHY: a song went onto the sheet with the title of the video it was
//  taken from — 「[4k] 곡 (Solo. 이름) - 팀 | ep.3 장소」 — so the Title
//  column read as a list of uploads, and every chart attached to it was
//  filed under the same mouthful, file name included. This works out, cell
//  by cell, what the tidied sheet holds: Title the song (with its hymn
//  number), 참고버전 the recording (PlanSongTitle.forSheet), and each
//  attachment's Song and Name to match.
//
//  Cells only — never a whole row — so nothing else in a row is touched.
//  A title already tidy is left alone, and 참고버전 is only filled, never
//  overwritten. Pure Foundation: Tools/check-song-title-tidy.swift runs it.
//

import Foundation

enum SongTitleTidy {

    struct Cell: Equatable {
        /// 1-based sheet row and 0-based column.
        let row: Int
        let column: Int
        let value: String
    }

    struct Plan: Equatable {
        var songs: [Cell] = []
        var attachments: [Cell] = []
        /// Songs whose title changes — for the audit's count.
        var titles = 0
        var isEmpty: Bool { songs.isEmpty && attachments.isEmpty }
    }

    /// `songs` and `attachments` as read, header first, the header on the
    /// sheet's first row. `channels`: video id → channel title, which tells
    /// a team from a song (「주사평 | 곡」); without it the title alone is
    /// read.
    static func plan(songs: [[String]], attachments: [[String]]?,
                     channels: [String: String] = [:]) -> Plan {
        var plan = Plan()
        var renamed: [String: String] = [:]

        if let header = songs.first,
           let titleColumn = TeamSheet.column(header, ["title", "곡", "곡명", "찬양"]) {
            let urlColumn = TeamSheet.column(header, ["youtubeurl", "url", "link", "링크", "영상"])
            let referenceColumn = TeamSheet.column(header, TeamSheet.referenceColumnNames)
            for (offset, row) in songs.enumerated() where offset > 0 {
                func cell(_ index: Int?) -> String {
                    guard let index, row.indices.contains(index) else { return "" }
                    return row[index].trimmingCharacters(in: .whitespaces)
                }
                let raw = cell(titleColumn)
                guard !raw.isEmpty else { continue }
                let video = TeamSheet.videoKey(cell(urlColumn))
                let tidy = PlanSongTitle.forSheet(raw, channel: video.flatMap { channels[$0] })
                if tidy.title != raw {
                    plan.songs.append(Cell(row: offset + 1, column: titleColumn, value: tidy.title))
                    plan.titles += 1
                    renamed[raw] = tidy.title
                }
                if let referenceColumn, !tidy.reference.isEmpty, cell(referenceColumn).isEmpty {
                    plan.songs.append(Cell(row: offset + 1, column: referenceColumn, value: tidy.reference))
                }
            }
        }

        if let rows = attachments, let header = rows.first,
           let songColumn = TeamSheet.column(header, ["song", "곡", "찬양"]) {
            let nameColumn = TeamSheet.column(header, ["name", "이름", "파일"])
            for (offset, row) in rows.enumerated() where offset > 0 {
                guard row.indices.contains(songColumn) else { continue }
                let raw = row[songColumn].trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty else { continue }
                // As the Songs tab renamed it, so the two still agree.
                let title = renamed[raw] ?? PlanSongTitle.forSheet(raw).title
                guard title != raw else { continue }
                plan.attachments.append(Cell(row: offset + 1, column: songColumn, value: title))
                // The file name was built from the long title, spaces as _.
                if let nameColumn, row.indices.contains(nameColumn) {
                    let name = row[nameColumn]
                    let long = raw.replacingOccurrences(of: " ", with: "_")
                    if name.contains(long) {
                        plan.attachments.append(Cell(
                            row: offset + 1, column: nameColumn,
                            value: name.replacingOccurrences(of: long, with: title.replacingOccurrences(of: " ", with: "_"))))
                    }
                }
            }
        }
        return plan
    }

    /// Where the Songs tab's columns should go: Key and Transpose straight
    /// after Title, then 참고버전. Nil when 참고버전 is already there — the
    /// layout is the team's from then on — or there is no Title column.
    struct Layout: Equatable {
        /// Key…Transpose to move to just after Title, as a column range.
        var move: Range<Int>?
        /// Where 참고버전 goes, counted after the move.
        var insertReferenceAt: Int
    }

    static func layout(header: [String]) -> Layout? {
        guard TeamSheet.column(header, TeamSheet.referenceColumnNames) == nil,
              let title = TeamSheet.column(header, ["title", "곡", "곡명", "찬양"]) else { return nil }
        let key = TeamSheet.column(header, ["key", "키", "원키", "원곡키"])
        let transpose = TeamSheet.column(header, ["transpose", "연주키", "조옮김"])
        // Only the pair as the app writes it — Key then Transpose, to the
        // right of Title with something between. Anything else is the
        // team's own arrangement and is not moved.
        if let key, let transpose, transpose == key + 1, key > title + 1 {
            return Layout(move: key..<(transpose + 1), insertReferenceAt: title + 3)
        }
        let after = [title, key, transpose].compactMap { $0 }.max() ?? title
        return Layout(move: nil, insertReferenceAt: after + 1)
    }
}
