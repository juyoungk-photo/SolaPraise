//
//  LyricFixes.swift
//  SolaPraise
//
//  Lyrics corrected by hand on the 코드표, kept apart from the reading.
//
//  WHY: the reader misreads a syllable now and then, and the 코드표 is read
//  again whenever a chord is moved or added. A correction written into the
//  reading would be lost with it. So each one is kept as where it is —
//  line, bar, note, verse — and what it replaced, and laid over every
//  reading again; only where the same misread is still there, so a
//  reading that now gets it right, or lines up differently, is left alone
//  (Tools/check-lyric-fixes.swift).
//

import Foundation

struct LyricFix: Codable, Equatable {
    let system: Int
    let bar: Int
    let cell: Int
    let verse: Int
    /// As read.
    let from: String
    /// As corrected.
    let to: String

    func samePlace(_ other: LyricFix) -> Bool {
        system == other.system && bar == other.bar && cell == other.cell && verse == other.verse
    }
}

enum LyricFixes {

    /// The reading with the corrections laid over it.
    static func apply(_ fixes: [LyricFix], to systems: [ScoreChart.System]) -> [ScoreChart.System] {
        var out = systems
        for fix in fixes {
            guard out.indices.contains(fix.system),
                  out[fix.system].bars.indices.contains(fix.bar),
                  out[fix.system].bars[fix.bar].cells.indices.contains(fix.cell) else { continue }
            var cell = out[fix.system].bars[fix.bar].cells[fix.cell]
            let current = cell.syllables.indices.contains(fix.verse) ? cell.syllables[fix.verse] : ""
            guard current == fix.from else { continue }
            while cell.syllables.count <= fix.verse { cell.syllables.append("") }
            cell.syllables[fix.verse] = fix.to
            out[fix.system].bars[fix.bar].cells[fix.cell] = cell
        }
        return out
    }

    /// The corrections after a line was edited: `shown` as it was on
    /// screen (corrections already laid over it), `edited` as it was saved.
    /// A place corrected before keeps what was first read there, and a
    /// correction put back to what was read goes.
    static func merge(_ existing: [LyricFix], system index: Int,
                      shown: ScoreChart.System, edited: ScoreChart.System) -> [LyricFix] {
        var fixes = existing
        for (b, bar) in edited.bars.enumerated() where shown.bars.indices.contains(b) {
            for (c, cell) in bar.cells.enumerated() where shown.bars[b].cells.indices.contains(c) {
                let before = shown.bars[b].cells[c].syllables
                for verse in 0..<max(before.count, cell.syllables.count) {
                    let was = before.indices.contains(verse) ? before[verse] : ""
                    let now = cell.syllables.indices.contains(verse) ? cell.syllables[verse] : ""
                    guard was != now else { continue }
                    let place = LyricFix(system: index, bar: b, cell: c, verse: verse, from: was, to: now)
                    let read = fixes.first(where: { $0.samePlace(place) })?.from ?? was
                    fixes.removeAll { $0.samePlace(place) }
                    if read != now {
                        fixes.append(LyricFix(system: index, bar: b, cell: c, verse: verse, from: read, to: now))
                    }
                }
            }
        }
        return fixes
    }
}
