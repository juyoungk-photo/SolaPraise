//
//  check-chart-delta.swift
//  SolaPraise
//
//  Checks the change a chord fix sends to the devices in the room: only
//  what changed, laid onto another copy — by id, or by place when that
//  device read the chart under other ids.
//
//  WHY THIS EXISTS: a change laid onto the wrong chord shows a teammate a
//  fix in the wrong bar; one not found at all is added a second time, and
//  the stand shows the chord twice. Neither looks like a sync bug.
//
//  Run:
//      swiftc -O -o /tmp/chartdelta \
//          Sources/Team/ChartDelta.swift Tools/check-chart-delta.swift
//      /tmp/chartdelta
//

import Foundation

struct Mark: Identifiable, Equatable, Codable {
    var id: Int
    var text: String
    var x: Double
}

@main
struct CheckChartDelta {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }
        let same: (Mark, Mark) -> Bool = { abs($0.x - $1.x) < 0.02 }
        let old = [[Mark(id: 1, text: "G", x: 0.1), Mark(id: 2, text: "C", x: 0.4)], [Mark(id: 3, text: "D", x: 0.2)]]
        var new = old
        new[0][1].text = "Cmaj7"
        new[1].removeAll()
        new[1].append(Mark(id: 4, text: "Em", x: 0.6))

        guard let delta = ChartDelta.between(old, new) else { print("FAIL: no delta"); exit(1) }
        expect(delta.pages.map(\.index), [0, 1], "only the pages that changed")
        expect(delta.pages[0].changed.map(\.text), ["Cmaj7"], "only the chord that changed")
        expect(delta.pages[1].removed.map(\.id), [3], "the chord taken off, whole")
        expect(delta.pages[1].added.map(\.id), [4], "the chord put on, as new")
        expect(ChartDelta.between(old, old)?.isEmpty, true, "nothing changed, nothing sent")
        expect(ChartDelta<Mark>.between(old, [old[0]]) == nil, true, "another chart: no delta")
        let size = (try? JSONEncoder().encode(delta).count) ?? 0
        expect(size < 400, true, "small enough to send at once (\(size) bytes)")

        // Same ids: exactly the sender's chart.
        expect(delta.applied(to: old, same: same).pages, new, "same ids")
        expect(delta.applied(to: old, same: same).missed, 0, "all found")

        // Another device read it under other ids.
        let theirs = [[Mark(id: 11, text: "G", x: 0.105), Mark(id: 12, text: "C", x: 0.395)], [Mark(id: 13, text: "D", x: 0.2)]]
        let laid = delta.applied(to: theirs, same: same)
        expect(laid.pages[0].map(\.text), ["G", "Cmaj7"], "fixed in place, found by place")
        expect(laid.pages[0].count, 2, "not added a second time")
        expect(laid.pages[1].map(\.text), ["Em"], "the removed one found by place, the added one added")
        expect(laid.missed, 0, "found by place")

        // A copy read differently: what is not found is counted, so the
        // whole chart is asked for instead.
        let other = [[Mark(id: 21, text: "G", x: 0.1)], [Mark(id: 23, text: "D", x: 0.9)]]
        expect(delta.applied(to: other, same: same).missed, 2, "the changed and the removed not found")

        // Applied twice (a message repeated): no change.
        expect(delta.applied(to: delta.applied(to: old, same: same).pages, same: same).pages, new, "applying twice is applying once")

        if failures == 0 {
            print("all chart delta checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
