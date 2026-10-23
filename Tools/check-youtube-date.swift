//
//  check-youtube-date.swift
//  SolaPraise
//
//  Checks that YouTube's dates are read, with and without fractions of a
//  second, to the second they say — and that anything else is not.
//
//  WHY THIS EXISTS: a date read wrong, or not at all, shows only as a feed
//  in the wrong order or videos dropped as undated.
//
//  Run:
//      swiftc -O -o /tmp/youtube-date \
//          Sources/API/YouTubeDate.swift Tools/check-youtube-date.swift
//      /tmp/youtube-date
//

import Foundation

@main
struct CheckYouTubeDate {
    static func main() {
        var failures = 0
        func expect(_ got: Date?, _ want: TimeInterval?, _ message: String) {
            let ok = (got == nil && want == nil)
                || (got != nil && want != nil && abs(got!.timeIntervalSince1970 - want!) < 0.01)
            if !ok { failures += 1; print("FAIL: \(message): \(String(describing: got?.timeIntervalSince1970))") }
        }
        // 2024-07-14T09:30:00Z
        let at: TimeInterval = 1_720_949_400
        expect(YouTubeDate.parse("2024-07-14T09:30:00Z"), at, "whole seconds")
        expect(YouTubeDate.parse("2024-07-14T09:30:00.123Z"), at + 0.123, "with fractions")
        expect(YouTubeDate.parse("2024-07-14T09:30:00.5Z"), at + 0.5, "one digit of fraction")
        expect(YouTubeDate.parse("2024-07-14"), nil, "a day alone is not a time")
        expect(YouTubeDate.parse("어제"), nil, "not a date")

        if failures == 0 {
            print("all youtube date checks passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
