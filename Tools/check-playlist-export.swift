//
//  check-playlist-export.swift
//  SolaPraise
//
//  Checks PlaylistExport: the steps that make a YouTube playlist into a
//  service's 콘티.
//
//  WHY THIS EXISTS: the steps are writes to the team's real playlist, 50
//  quota units each. A wrong position leaves the set out of order; a step
//  too many spends the day's budget; a missed removal leaves last week's
//  song in. None of it raises an error.
//
//  Run:
//      swiftc -O -o /tmp/playlistexport \
//          Sources/Team/PlaylistExport.swift Tools/check-playlist-export.swift
//      /tmp/playlistexport
//

import Foundation

@main
struct CheckPlaylistExport {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)")
        if !ok {
            let text = detail()
            if !text.isEmpty { print("       \(text)") }
            failures += 1
        }
    }

    /// The playlist after the steps, as YouTube would hold it.
    static func apply(_ steps: [PlaylistExport.Step], to current: [(item: String, video: String)]) -> [String] {
        var list = current
        for step in steps {
            switch step {
            case .remove(let item):
                list.removeAll { $0.item == item }
            case .add(let video, let at):
                list.insert((item: "new-\(video)", video: video), at: min(at, list.count))
            case .move(let item, _, let to):
                guard let from = list.firstIndex(where: { $0.item == item }) else { continue }
                let entry = list.remove(at: from)
                list.insert(entry, at: min(to, list.count))
            }
        }
        return list.map(\.video)
    }

    static func main() {
        let lastWeek = [(item: "i1", video: "a"), (item: "i2", video: "b"), (item: "i3", video: "c")]

        let same = PlaylistExport.plan(current: lastWeek, wanted: ["a", "b", "c"])
        check("a playlist already the 콘티 costs nothing", same.isEmpty, "got \(same)")

        let wanted = ["d", "b", "a", "e"]
        let steps = PlaylistExport.plan(current: lastWeek, wanted: wanted)
        check("the playlist becomes the 콘티, in order",
              apply(steps, to: lastWeek) == wanted, "got \(apply(steps, to: lastWeek)) from \(steps)")
        check("last week's song comes out", steps.contains(.remove(item: "i3")))
        check("only what must change is written: out c, in d and e, b up", steps.count == 4, "got \(steps.count): \(steps)")

        let twice = [(item: "i1", video: "a"), (item: "i2", video: "a"), (item: "i3", video: "b")]
        let deduped = PlaylistExport.plan(current: twice, wanted: ["a", "b"])
        check("a song in twice is left in once", apply(deduped, to: twice) == ["a", "b"], "got \(deduped)")

        check("an empty playlist is filled in order",
              apply(PlaylistExport.plan(current: [], wanted: ["x", "y", "z"]), to: []) == ["x", "y", "z"])
        check("a 콘티 naming a song twice puts it in once",
              apply(PlaylistExport.plan(current: [], wanted: ["x", "y", "x"]), to: []) == ["x", "y"])
        check("an empty 콘티 empties the playlist",
              apply(PlaylistExport.plan(current: lastWeek, wanted: []), to: lastWeek).isEmpty)
        check("cost is 50 a step", PlaylistExport.cost(steps) == steps.count * 50)

        print(failures == 0 ? "\nall playlist export checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
