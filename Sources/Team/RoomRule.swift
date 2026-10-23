//
//  RoomRule.swift
//  SolaPraise
//
//  Two stands in the room with different charts of one song: whose the
//  room keeps.
//
//  WHY: corrections are kept on the stand that made them and travel only
//  stand to stand. A stand that comes in with an older copy — or none
//  corrected at all — must take the room's, never hand its own out over
//  it. The one corrected last is the room's; corrected at the same moment,
//  or never, the stands settle on one by their ids, so they end on one.
//
//  Pure, so Tools/check-room-rule.swift runs it.
//

import Foundation

enum RoomRule {
    /// Whether this stand takes the other's chart.
    static func takesTheirs(mine: Date?, theirs: Date?, me: String, them: String) -> Bool {
        let mine = mine ?? .distantPast, theirs = theirs ?? .distantPast
        return theirs > mine || (theirs == mine && me > them)
    }
}
