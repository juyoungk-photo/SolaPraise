//
//  check-room-rule.swift
//  SolaPraise
//
//  Checks whose chart the room keeps when two stands differ: the one
//  corrected last; and on a tie, exactly one of the two takes the other's.
//
//  WHY THIS EXISTS: get it backwards and a stand that was never corrected
//  hands its chart out over the leader's fixes — on every stand at once.
//
//  Run:
//      swiftc -O -o /tmp/room-rule \
//          Sources/Team/RoomRule.swift Tools/check-room-rule.swift
//      /tmp/room-rule
//

import Foundation

@main
struct CheckRoomRule {
    static func main() {
        var failures = 0
        func expect(_ got: Bool, _ want: Bool, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message)") }
        }
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)

        expect(RoomRule.takesTheirs(mine: earlier, theirs: later, me: "a", them: "b"), true, "theirs corrected later: taken")
        expect(RoomRule.takesTheirs(mine: later, theirs: earlier, me: "a", them: "b"), false, "mine corrected later: kept")
        expect(RoomRule.takesTheirs(mine: nil, theirs: earlier, me: "a", them: "b"), true, "never corrected here: theirs taken")
        expect(RoomRule.takesTheirs(mine: earlier, theirs: nil, me: "b", them: "a"), false, "never corrected there: mine kept")

        // A tie: exactly one of the two takes the other's, whoever asks.
        for (mine, theirs) in [(Date?.none, Date?.none), (earlier, earlier)] {
            let a = RoomRule.takesTheirs(mine: mine, theirs: theirs, me: "a", them: "b")
            let b = RoomRule.takesTheirs(mine: theirs, theirs: mine, me: "b", them: "a")
            expect(a != b, true, "a tie settles on one stand's chart")
        }

        if failures == 0 {
            print("all room rule checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
