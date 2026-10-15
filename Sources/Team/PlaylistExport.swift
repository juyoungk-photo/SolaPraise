//
//  PlaylistExport.swift
//  SolaPraise
//
//  A service's 콘티, written out to a YouTube playlist — the other way from
//  「재생목록에서 찬양 채우기」.
//
//  The playlist is made to BE the 콘티: the same songs in the same order.
//  Songs no longer in it come out, songs missing go in where they belong,
//  and the rest are moved into place. Each step is a write YouTube charges
//  50 units for, so the plan is the fewest: a song already where it should
//  be costs nothing.
//
//  Pure Foundation: Tools/check-playlist-export.swift runs it.
//

import Foundation

enum PlaylistExport {

    enum Step: Equatable {
        case remove(item: String)
        case add(video: String, at: Int)
        case move(item: String, video: String, to: Int)
    }

    /// `current`: the playlist as it is, in order — each item's id and its
    /// video. `wanted`: the 콘티's videos in order.
    static func plan(current: [(item: String, video: String)], wanted: [String]) -> [Step] {
        var order: [String] = []
        for video in wanted where !order.contains(video) { order.append(video) }
        let keep = Set(order)

        var steps: [Step] = []
        var list: [(item: String, video: String)] = []
        var seen = Set<String>()
        // Out first — songs not on the 콘티, and a second copy of one that is.
        for entry in current {
            if keep.contains(entry.video), seen.insert(entry.video).inserted {
                list.append(entry)
            } else {
                steps.append(.remove(item: entry.item))
            }
        }
        // Then each song into its place, as YouTube will see the list then.
        for (position, video) in order.enumerated() {
            if let at = list.firstIndex(where: { $0.video == video }) {
                guard at != position else { continue }
                let entry = list.remove(at: at)
                list.insert(entry, at: position)
                steps.append(.move(item: entry.item, video: video, to: position))
            } else {
                list.insert((item: "", video: video), at: position)
                steps.append(.add(video: video, at: position))
            }
        }
        return steps
    }

    /// YouTube's charge for the plan, in quota units.
    static func cost(_ steps: [Step]) -> Int { steps.count * 50 }
}
