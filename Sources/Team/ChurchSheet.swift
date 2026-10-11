//
//  ChurchSheet.swift
//  SolaPraise
//
//  The church's own information sheet — read-only, and only two columns of it.
//
//  WHY A SECOND SHEET: the worship team's planning sheet is the team's. The
//  church keeps a separate document that the office fills in, and two of its
//  columns answer questions the team asks every week: what is the sermon
//  about, and is there a 헌신찬양. Copying those across by hand is how they go
//  stale. So the app reads them where they are written.
//
//  Deliberately narrow. This pulls two fields for upcoming services and
//  nothing else: the church sheet belongs to the office, its shape will
//  change without warning, and an integration that depends on all of it would
//  break every time someone adds a column. Everything here is matched by
//  header text and skipped when absent.
//
//  NEVER WRITTEN TO. The team sheet is the team's to edit; this one is read.
//
//  ── TAB "찬양/설교" ───────────────────────────────────────────
//  A date column, a 헌신찬양 column, a 설교제목 column, in any order, under
//  any of the spellings below, alongside however many other columns the
//  office keeps there.
//

import Foundation

/// What the church sheet says about one service.
struct ChurchNote: Equatable {
    let date: Date
    /// nil when the cell is empty — "not filled in yet" is the normal state
    /// for a service three weeks out, and it has to read differently from
    /// "there is no 헌신찬양 this week".
    var dedicationSong: String?
    var sermonTitle: String?
    /// The passage preached: its own 본문 column, or read out of the
    /// 설교제목 cell — 「기브아의 비극 (삿 19:1-30)」.
    var passage: String? = nil
    /// Who preaches: a 설교자 column, a bare 설교 column beside 설교제목
    /// holding a name, or a name with its title in the cell — 「박요셉 목사」.
    var preacher: String? = nil

    var isEmpty: Bool { dedicationSong == nil && sermonTitle == nil && passage == nil && preacher == nil }
}

enum ChurchSheet {

    /// The tab holding the two columns. A slash in a tab name is the reason
    /// `SheetsClient.read` needs an A1-quoted, pre-encoded range — see
    /// `quotedRange`.
    static let tab = "찬양/설교"

    /// Accepted header spellings, lowercased.
    ///
    /// Matched by *containment*, not equality: the office writes "설교 제목",
    /// "설교제목", "말씀 제목" and "설교 (제목)" in different months, and a
    /// column that has to be renamed to suit the app is a column that will
    /// not be.
    private static let dateNames = ["날짜", "일자", "date", "주일"]
    private static let dedicationNames = ["헌신찬양", "헌신 찬양", "헌신"]
    private static let sermonNames = ["설교제목", "설교 제목", "설교", "말씀제목", "말씀 제목"]
    private static let passageNames = ["성경본문", "성경 본문", "말씀본문", "본문"]
    private static let preacherNames = ["설교자", "설교 자", "강사", "말씀 전하실", "preacher"]

    /// A1 notation for the whole tab, quoted because the name has a slash in
    /// it, and percent-encoded here rather than later.
    ///
    /// This is the trap this project has already paid for twice. The range
    /// goes into a URL *path*, and "찬양/설교" carries a slash, which a path
    /// treats as a segment boundary — so an unencoded range asks for a sheet
    /// called 찬양 inside a collection called 설교, and Sheets answers 400.
    /// Encoding it here and handing the result to the pre-encoded path means
    /// it is escaped exactly once. Tools/check-sheet-urls.swift covers it.
    static var encodedRange: String? {
        "'\(tab)'".addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    }

    /// Rows of the tab into notes, keyed by day.
    ///
    /// A row with no readable date, or with both cells empty, is dropped: the
    /// sheet has heading rows, blank spacers and months typed ahead with
    /// nothing in them yet, and none of those are a service.
    static func notes(from rows: [[String]]) -> [Date: ChurchNote] {
        // The header is the first row, near the top, that names a date
        // column and one of ours — not necessarily row 1: an office sheet
        // often opens with a title or a note above it.
        guard let headerIndex = rows.prefix(15).firstIndex(where: { row in
            column(row, matching: dateNames) != nil
                && (column(row, matching: dedicationNames) != nil || column(row, matching: sermonNames) != nil)
        }) else { return [:] }
        let header = rows[headerIndex]

        guard let dateColumn = column(header, matching: dateNames) else { return [:] }
        let dedicationColumn = column(header, matching: dedicationNames)
        let preacherColumn = column(header, matching: preacherNames)
        let passageColumn = column(header, matching: passageNames)
        // 「설교」 is contained in 「설교자」: the title column is never the
        // preacher's.
        let sermonColumn = column(header, matching: sermonNames, excluding: [preacherColumn, passageColumn])
        // A bare 「설교」 column beside 「설교제목」 holds who preaches.
        let bareSermonColumn = column(header, matching: ["설교"], exactly: true,
                                      excluding: [sermonColumn, preacherColumn, passageColumn])
        guard dedicationColumn != nil || sermonColumn != nil else { return [:] }

        var result: [Date: ChurchNote] = [:]
        for row in rows.dropFirst(headerIndex + 1) {
            guard let raw = row[safe: dateColumn],
                  let date = TeamSheet.day(raw) else { continue }

            let cell = sermonColumn.flatMap { row[safe: $0] }.nonEmpty
            let parts: (title: String?, passage: String?, preacher: String?) = cell.map(sermonParts) ?? (nil, nil, nil)
            let bare = bareSermonColumn.flatMap { row[safe: $0] }.nonEmpty
            let note = ChurchNote(
                date: date,
                dedicationSong: dedicationColumn.flatMap { row[safe: $0] }.nonEmpty,
                sermonTitle: parts.title,
                passage: passageColumn.flatMap { row[safe: $0] }.nonEmpty ?? parts.passage,
                preacher: preacherColumn.flatMap { row[safe: $0] }.nonEmpty ?? parts.preacher
                    ?? bare.flatMap { sermonParts($0).preacher ?? (looksLikeName($0) ? $0 : nil) }
            )
            guard !note.isEmpty else { continue }

            // Keyed by day, so a service row and a practice row on the same
            // date do not produce two entries. Later rows win, which is what
            // a correction typed underneath an earlier line should do.
            result[Calendar.current.startOfDay(for: date)] = note
        }
        return result
    }

    /// Containment rather than equality — see the note on the name lists.
    ///
    /// Longest candidate first, so "설교제목" is preferred over the bare
    /// "설교" when a sheet happens to carry both.
    private static func column(_ header: [String], matching names: [String], exactly: Bool = false,
                               excluding taken: [Int?] = []) -> Int? {
        let cells = header.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "")
                .lowercased()
        }
        let skip = Set(taken.compactMap { $0 })
        for name in names.sorted(by: { $0.count > $1.count }) {
            let needle = name.replacingOccurrences(of: " ", with: "").lowercased()
            if let index = cells.indices.first(where: {
                !skip.contains($0) && (exactly ? cells[$0] == needle : cells[$0].contains(needle))
            }) { return index }
        }
        return nil
    }

    // MARK: - The 설교제목 cell

    private static let titles = "목사|전도사|강도사|선교사|교수|장로|사모|집사|형제|자매|박사"

    /// The title, the passage and the preacher out of one cell, as the office
    /// writes it: 「기브아의 비극 (삿 19:1-30) 박요셉 목사」, 「마음은 원이로되 /
    /// 수 24:14-31」, 「믿음의 경주 - 히브리서 12장」. What is neither passage
    /// nor name is the title.
    static func sermonParts(_ text: String) -> (title: String?, passage: String?, preacher: String?) {
        var rest = text
        var preacher: String?
        if let range = rest.range(of: #"([가-힣]{2,4})\s*(?:"# + titles + #")(?:님)?"#, options: .regularExpression) {
            preacher = String(rest[range]).replacingOccurrences(of: "님$", with: "", options: .regularExpression)
            rest.removeSubrange(range)
        }
        var passage: String?
        let reference = #"[가-힣]{1,7}\s?\d{1,3}\s*(?::\s*\d{1,3}(?:\s*[-~–]\s*\d{1,3}(?::\d{1,3})?)?|[장편](?:\s*\d{1,3}\s*(?:[-~–]\s*\d{1,3}\s*)?절)?)"#
        if let range = rest.range(of: reference, options: .regularExpression) {
            passage = String(rest[range]).trimmingCharacters(in: .whitespaces)
            rest.removeSubrange(range)
        }
        let title = rest
            .replacingOccurrences(of: #"\(\s*\)|\[\s*\]|「\s*」"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "|/-–—·,:()[]「」\"'")))
        return (title.isEmpty ? nil : title, passage, preacher)
    }

    /// 「박목사」, 「김철수」: a short Korean name, with or without a title.
    private static func looksLikeName(_ text: String) -> Bool {
        text.range(of: #"^[가-힣]{2,4}(?:"# + titles + #")?(?:님)?$"#, options: .regularExpression) != nil
    }
}

// MARK: - Small helpers

private extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Optional where Wrapped == String {
    /// Trimmed, or nil when there is nothing in it.
    var nonEmpty: String? {
        guard let text = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
