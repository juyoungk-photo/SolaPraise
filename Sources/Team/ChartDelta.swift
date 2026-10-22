//
//  ChartDelta.swift
//  SolaPraise
//
//  What changed on a chart since it was last sent — the chords changed or
//  added, the chords taken off — and that change laid onto another
//  device's copy. A few hundred bytes, sent the moment a chord is fixed.
//
//  WHY: in rehearsal the person fixing the bridge and the people reading it
//  look at it at the same moment. Sending the whole chart through Drive
//  and the sheet took seconds on each side; a change is small enough to go
//  straight to the devices in the room (RehearsalLink) and be on their
//  stands before the next bar.
//
//  Matched by id, and failing that by place: two devices that read a chart
//  each on their own gave its chords different ids, and the same printed
//  chord is the one at the same spot (`same`).
//
//  Generic and Foundation-only, so Tools/check-chart-delta.swift runs it.
//

import Foundation

struct ChartDelta<C: Identifiable & Equatable & Codable>: Codable where C.ID: Codable {
    struct Page: Codable {
        var index: Int
        /// Changed, as they are now.
        var changed: [C]
        /// New on the chart.
        var added: [C] = []
        /// Taken off, as they were — whole, so a device with other ids
        /// can find them by place.
        var removed: [C]
    }

    var pages: [Page]

    var isEmpty: Bool { pages.allSatisfy { $0.changed.isEmpty && $0.added.isEmpty && $0.removed.isEmpty } }

    /// From `old` to `new`; nil when they are not the same chart (a
    /// different number of pages).
    static func between(_ old: [[C]], _ new: [[C]]) -> ChartDelta? {
        guard old.count == new.count else { return nil }
        var pages: [Page] = []
        for index in new.indices {
            let before = Dictionary(old[index].map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let now = Set(new[index].map(\.id))
            let changed = new[index].filter { before[$0.id] != nil && before[$0.id] != $0 }
            let added = new[index].filter { before[$0.id] == nil }
            let removed = old[index].filter { !now.contains($0.id) }
            if !changed.isEmpty || !removed.isEmpty || !added.isEmpty {
                pages.append(Page(index: index, changed: changed, added: added, removed: removed))
            }
        }
        return ChartDelta(pages: pages)
    }

    /// `pages` with the change laid on, and how many of the chords it
    /// changes or takes off were not found here — then this copy is not the
    /// sender's, and is better replaced by it than patched (RehearsalLink
    /// asks for the whole chart). `same` says when a chord here is the
    /// sender's: the same id, or the same printed chord read here under
    /// another.
    func applied(to pages: [[C]], same: (C, C) -> Bool) -> (pages: [[C]], missed: Int) {
        var out = pages
        var missed = 0
        for page in self.pages where out.indices.contains(page.index) {
            var chords = out[page.index]
            func find(_ chord: C) -> Int? {
                chords.firstIndex(where: { $0.id == chord.id }) ?? chords.firstIndex(where: { same($0, chord) })
            }
            for gone in page.removed {
                if let at = find(gone) { chords.remove(at: at) } else { missed += 1 }
            }
            for chord in page.changed {
                if let at = find(chord) { chords[at] = chord } else { chords.append(chord); missed += 1 }
            }
            for chord in page.added {
                if let at = chords.firstIndex(where: { $0.id == chord.id }) { chords[at] = chord } else { chords.append(chord) }
            }
            out[page.index] = chords
        }
        return (out, missed)
    }
}
