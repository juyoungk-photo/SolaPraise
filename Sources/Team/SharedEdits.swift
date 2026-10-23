//
//  SharedEdits.swift
//  SolaPraise
//
//  A chart's corrections in the standard form — XFDF — as they travel:
//  between the stands in the room (RehearsalLink), in the exports for other
//  PDF apps, and on the team sheet's hidden 「교정」 tab for the one thing
//  kept there, a 콘티 file's page map (which page is which song).
//
//  Charts' chord and lyric corrections are not kept on the sheet: they go
//  from stand to stand in the room, and to everyone else as a PDF.
//
//  A row is a key — 「all」 for a whole chart, the page list for one song's
//  pages of a 콘티 file, 「pages-map」 for which page is which song.
//

import Foundation
import CryptoKit

enum SharedEdits {

    /// Which entry of the map a stand item reads and writes.
    static func key(pages: [Int]?) -> String {
        pages.map { "pages:" + $0.map(String.init).joined(separator: ",") } ?? "all"
    }

    /// One chart's corrections as the 「교정」 tab keeps them, one row each
    /// (CorrectionsTab): its chords, its lyric fixes, and — on the page-map
    /// row of a 콘티 file — which page is which song.
    struct Entry: Codable, Equatable {
        var chords: [[ScoreChord]]? = nil
        var lyrics: [LyricFix]? = nil
        var pages: [String: String]? = nil
        /// One member's drawing, and whose — for the XFDF exports.
        var inks: [XFDF.Ink]? = nil
        var author: String? = nil
    }

}

/// A chart's corrections as the 「교정」 tab holds them: XFDF, the standard
/// form of a PDF's annotations — the chords and lyric fixes as annotations,
/// a 콘티 file's page map as its form fields.
enum CorrectionsBody {

    static func encode(_ entry: SharedEdits.Entry, part: String, pdfPages: [Int], sizes: [CGSize]) -> String? {
        var document = document(entry.chords ?? [], lyrics: entry.lyrics ?? [])
        for (page, song) in entry.pages ?? [:] { document.fields["page.\(page)"] = song }
        // Kept to the sheet's cell: each stroke's points thinned to its shape.
        document.inks = (entry.inks ?? []).map { ink in
            var thin = ink
            thin.points = XFDF.simplify(ink.points)
            return thin
        }
        document.author = entry.author
        return XFDF.encode(document, pdfPages: pdfPages, sizes: sizes)
    }

    static func decode(_ text: String) -> SharedEdits.Entry? {
        guard let document = XFDF.decode(text) else { return nil }
        let pages = Dictionary(uniqueKeysWithValues: document.fields.compactMap { name, song in
            name.hasPrefix("page.") ? (String(name.dropFirst(5)), song) : nil
        })
        return SharedEdits.Entry(chords: document.pages.isEmpty ? nil : document.pages.map { $0.map(chord) },
                                 lyrics: document.lyrics.isEmpty ? nil : document.lyrics.map(lyric),
                                 pages: pages.isEmpty ? nil : pages,
                                 inks: document.inks.isEmpty ? nil : document.inks,
                                 author: document.author)
    }

    static func document(_ pages: [[ScoreChord]], lyrics: [LyricFix] = []) -> XFDF.Document {
        XFDF.Document(pages: pages.enumerated().map { part, chords in chords.map { mark($0, part: part) } },
                      lyrics: lyrics.map { .init(system: $0.system, bar: $0.bar, cell: $0.cell, verse: $0.verse,
                                                 from: $0.from, to: $0.to,
                                                 chord: $0.chord?.uuidString, step: $0.step) })
    }

    static func mark(_ chord: ScoreChord, part: Int) -> XFDF.Mark {
        XFDF.Mark(name: chord.id.uuidString, part: part, box: chord.box, offset: chord.offset,
                  text: chord.original, userAdded: chord.userAdded, corrected: chord.corrected)
    }

    static func chord(_ mark: XFDF.Mark) -> ScoreChord {
        var chord = ScoreChord(original: mark.text, box: mark.box)
        chord.id = id(mark.name)
        chord.offset = mark.offset
        chord.userAdded = mark.userAdded
        chord.corrected = mark.corrected
        return chord
    }

    static func lyric(_ fix: XFDF.Lyric) -> LyricFix {
        LyricFix(system: fix.system, bar: fix.bar, cell: fix.cell, verse: fix.verse, from: fix.from, to: fix.to,
                 chord: fix.chord.map(id), step: fix.step)
    }

    /// The annotation's name as this app's chord id — the same every time
    /// for a name another app gave, so its chords keep one id here.
    static func id(_ name: String) -> UUID {
        if let id = UUID(uuidString: name) { return id }
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
