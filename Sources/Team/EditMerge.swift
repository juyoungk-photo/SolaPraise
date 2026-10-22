//
//  EditMerge.swift
//  SolaPraise
//
//  Two members' corrections to one chart, put together: what each changed
//  since the version they both had, kept — not the whole chart of whoever
//  shared last.
//
//  WHY: in practice two people fix a chart at once — the leader the bridge,
//  the keys player the intro. Sharing used to upload the sharer's whole
//  chart, so the second to share erased the first's fixes without a word,
//  and the first saw their correction come back wrong a minute later.
//
//  Three-way, by id: `base` is the version this device last had from the
//  team (or sent to it), `local` this device's now, `remote` the team's
//  now. Everything the team has stays, then every chord this device
//  changed, added or took off since `base` is changed, added or taken off
//  in it. Where both changed one chord, this device's — the one sharing —
//  wins. With no base (never received or sent), local wins outright.
//
//  Generic and Foundation-only, so Tools/check-edit-merge.swift runs it.
//

import Foundation

enum EditMerge {

    static func pages<C: Identifiable & Equatable>(base: [[C]]?, local: [[C]], remote: [[C]]?) -> [[C]] {
        guard let remote, let base, remote.count == local.count, base.count == local.count else { return local }
        return local.indices.map { page(base: base[$0], local: local[$0], remote: remote[$0]) }
    }

    static func page<C: Identifiable & Equatable>(base: [C], local: [C], remote: [C]) -> [C] {
        let before = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mine = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out = remote
        // Taken off here: off there too, unless the team changed it since.
        for old in base where mine[old.id] == nil {
            if let index = out.firstIndex(where: { $0.id == old.id }), out[index] == old {
                out.remove(at: index)
            }
        }
        // Changed or added here.
        for chord in local where before[chord.id] != chord {
            if let index = out.firstIndex(where: { $0.id == chord.id }) {
                out[index] = chord
            } else {
                out.append(chord)
            }
        }
        return out
    }

    /// Corrections kept as a list by place (lyric fixes): the same rule,
    /// with `same` saying when two are about one place.
    static func list<T: Equatable>(base: [T]?, local: [T], remote: [T]?, same: (T, T) -> Bool) -> [T] {
        guard let remote else { return local }
        let base = base ?? []
        var out = remote
        for old in base where !local.contains(where: { same($0, old) }) {
            if let index = out.firstIndex(where: { same($0, old) }), out[index] == old { out.remove(at: index) }
        }
        for fix in local where !base.contains(fix) {
            if let index = out.firstIndex(where: { same($0, fix) }) { out[index] = fix } else { out.append(fix) }
        }
        return out
    }
}
