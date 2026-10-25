//
//  check-offering-note.swift
//  SolaPraise
//
//  Checks how a 헌금송 is read from, and written to, a song's Notes cell.
//
//  WHY THIS EXISTS: the Notes cell is the team's own, holding 「1절만」 and
//  whatever else a leader typed. Marking a song must not lose those words,
//  unmarking must not leave the mark behind, and a prayer read wrongly
//  prints the wrong name on the chart handed to the whole team.
//
//  Run:
//      swiftc -O -o /tmp/offeringnote \
//          Sources/Team/OfferingNote.swift Tools/check-offering-note.swift
//      /tmp/offeringnote
//

import Foundation

@main
struct CheckOfferingNote {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ message: String) {
            if got != want { failures += 1; print("FAIL: \(message): \(got)") }
        }
        typealias P = OfferingNote.Parsed

        // Read.
        expect(OfferingNote.parse(notes: "헌금송 · 헌금기도: 홍길동 형제님"),
               P(isOffering: true, prayer: "홍길동 형제님", rest: nil), "as written by the app")
        expect(OfferingNote.parse(notes: "1절만 · 헌금송 · 헌금기도: 홍길동 형제님"),
               P(isOffering: true, prayer: "홍길동 형제님", rest: "1절만"), "other notes kept")
        expect(OfferingNote.parse(notes: "헌금기도 홍길동 집사님, 2절 반복"),
               P(isOffering: true, prayer: "홍길동 집사님", rest: "2절 반복"), "typed by hand, no colon")
        expect(OfferingNote.parse(notes: "헌금찬양"), P(isOffering: true, prayer: nil, rest: nil), "the team's word")
        expect(OfferingNote.parse(notes: "헌금 찬양"), P(isOffering: true, prayer: nil, rest: nil), "헌금 찬양, spaced")
        expect(OfferingNote.parse(notes: "헌금찬양 · 헌금기도: 홍길동 형제님"),
               P(isOffering: true, prayer: "홍길동 형제님", rest: nil), "헌금찬양 with who prays")
        // 헌신찬양 is the response after the sermon: not the offering song.
        expect(OfferingNote.parse(notes: "헌신찬양").isOffering, false, "헌신찬양 is not the offering song")
        expect(OfferingNote.parse(notes: "1절만", orderLabel: "헌신 찬양").isOffering, false, "nor 헌신 찬양 in the Order column")
        expect(DedicationNote.isDedication(notes: "헌신찬양"), true, "헌신찬양, as written")
        expect(DedicationNote.isDedication(notes: nil, orderLabel: "헌신 찬양"), true, "헌신 찬양 in the Order column, spaced")
        expect(DedicationNote.isDedication(notes: "헌금찬양 · 헌금기도: 홍길동 형제님"), false, "the offering song is not it")
        expect(OfferingNote.parse(notes: "1절만", orderLabel: "헌금찬양"),
               P(isOffering: true, prayer: nil, rest: "1절만"), "marked in the Order column")
        expect(OfferingNote.parse(notes: "1절만", orderLabel: "3"), P(isOffering: false, prayer: nil, rest: "1절만"), "a plain song")
        expect(OfferingNote.parse(notes: nil), P(isOffering: false, prayer: nil, rest: nil), "no notes")

        // Written, and read back.
        expect(OfferingNote.notes(isOffering: true, prayer: "홍길동 형제님", rest: "1절만"),
               "헌금송 · 헌금기도: 홍길동 형제님 · 1절만", "marked")
        expect(OfferingNote.notes(isOffering: true, prayer: "  ", rest: nil), "헌금송", "no prayer yet")
        expect(OfferingNote.notes(isOffering: false, prayer: "홍길동 형제님", rest: "1절만"), "1절만", "unmarked: the rest only")
        expect(OfferingNote.notes(isOffering: false, prayer: nil, rest: nil), nil, "unmarked, nothing else: empty")
        for notes in ["1절만 · 헌금송 · 헌금기도: 홍길동 형제님", "헌금기도 홍길동 집사님, 2절 반복", "헌금찬양"] {
            let read = OfferingNote.parse(notes: notes)
            let written = OfferingNote.notes(isOffering: read.isOffering, prayer: read.prayer, rest: read.rest)
            expect(OfferingNote.parse(notes: written), read, "round trip of 「\(notes)」")
        }

        if failures == 0 {
            print("all offering note checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
