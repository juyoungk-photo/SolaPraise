//
//  LyricFixes.swift
//  SolaPraise
//
//  Lyrics corrected by hand on the 코드표, kept apart from the reading.
//
//  WHY: the reader misreads a syllable now and then, and the 코드표 is read
//  again whenever a chord is moved or added. A correction written into the
//  reading would be lost with it. So each one is kept as where it is —
//  by the chord it follows and how many notes after (the same on every
//  device), and by line, bar, note and verse — and what it replaced, and
//  laid over every
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
    /// The chord the syllable comes after, and how many notes after it —
    /// before it, when negative: a staff's first words come before its
    /// first chord. The place by the music rather than by the line, bar
    /// and note numbers of one device's reading, which another device —
    /// splitting the page into lines or bars a little differently — counts
    /// differently. Chords are one reading across the team (RehearsalLink,
    /// the 교정 tab), so their ids are the same everywhere. Nil for a fix
    /// kept before this.
    var chord: UUID? = nil
    var step: Int? = nil

    func samePlace(_ other: LyricFix) -> Bool {
        if let chord, let step, let theirs = other.chord, let their = other.step {
            return chord == theirs && step == their && verse == other.verse
        }
        return system == other.system && bar == other.bar && cell == other.cell && verse == other.verse
    }
}

enum LyricFixes {

    /// The reading with the corrections laid over it.
    static func apply(_ fixes: [LyricFix], to systems: [ScoreChart.System]) -> [ScoreChart.System] {
        var out = systems
        for fix in fixes {
            // By the music first; by the numbers where that finds nothing.
            let places = [place(of: fix, in: out), numbered(fix, in: out)].compactMap { $0 }
            for (s, b, c) in places {
                var cell = out[s].bars[b].cells[c]
                let current = cell.syllables.indices.contains(fix.verse) ? cell.syllables[fix.verse] : ""
                // Only where the same misread is still there.
                guard current == fix.from else { continue }
                while cell.syllables.count <= fix.verse { cell.syllables.append("") }
                cell.syllables[fix.verse] = fix.to
                out[s].bars[b].cells[c] = cell
                break
            }
        }
        return out
    }

    private static func numbered(_ fix: LyricFix, in systems: [ScoreChart.System]) -> (Int, Int, Int)? {
        guard systems.indices.contains(fix.system),
              systems[fix.system].bars.indices.contains(fix.bar),
              systems[fix.system].bars[fix.bar].cells.indices.contains(fix.cell) else { return nil }
        return (fix.system, fix.bar, fix.cell)
    }

    /// Every note of a staff in order, with its bar and place in the bar.
    private static func notes(_ system: ScoreChart.System) -> [(bar: Int, cell: Int, chord: UUID?)] {
        system.bars.enumerated().flatMap { b, bar in bar.cells.enumerated().map { (b, $0.offset, $0.element.chord) } }
    }

    /// Where a fix's chord-and-step is in this reading, on whichever staff
    /// that chord is now.
    private static func place(of fix: LyricFix, in systems: [ScoreChart.System]) -> (Int, Int, Int)? {
        guard let chord = fix.chord, let step = fix.step else { return nil }
        for (s, system) in systems.enumerated() {
            let all = notes(system)
            guard let at = all.firstIndex(where: { $0.chord == chord }), all.indices.contains(at + step) else { continue }
            return (s, all[at + step].bar, all[at + step].cell)
        }
        return nil
    }

    /// A note's place by the music: the chord before it on its staff and
    /// how many notes after — or the first chord after it, for the words
    /// before a staff's first chord.
    static func anchor(system: ScoreChart.System, bar: Int, cell: Int) -> (chord: UUID, step: Int)? {
        let all = notes(system)
        guard let here = all.firstIndex(where: { $0.bar == bar && $0.cell == cell }) else { return nil }
        if let before = all[...here].lastIndex(where: { $0.chord != nil }), let chord = all[before].chord {
            return (chord, here - before)
        }
        if let after = all[here...].firstIndex(where: { $0.chord != nil }), let chord = all[after].chord {
            return (chord, here - after)
        }
        return nil
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
                    let anchor = anchor(system: shown, bar: b, cell: c)
                    let place = LyricFix(system: index, bar: b, cell: c, verse: verse, from: was, to: now,
                                         chord: anchor?.chord, step: anchor?.step)
                    let read = fixes.first(where: { $0.samePlace(place) })?.from ?? was
                    fixes.removeAll { $0.samePlace(place) }
                    if read != now {
                        fixes.append(LyricFix(system: index, bar: b, cell: c, verse: verse, from: read, to: now,
                                              chord: anchor?.chord, step: anchor?.step))
                    }
                }
            }
        }
        return fixes
    }
}
