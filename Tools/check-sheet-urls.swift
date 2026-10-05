#!/usr/bin/env swift
//
//  check-sheet-urls.swift
//  SolaPraise
//
//  Checks the URLs SheetsClient builds for the Sheets API.
//
//  WHY THIS EXISTS: two bugs in a row lived here, both invisible at the call
//  site and both producing a working-looking app.
//
//  The first was double encoding — a range run through addingPercentEncoding
//  and then through appendingPathComponent, so "Signups!A9:F9" went out as
//  "Signups!A9%253AF9". Reads never carry a colon, so the sheet loaded
//  perfectly and nothing could ever be saved.
//
//  The second was the fix for the first: building the path by hand onto a
//  base that already ends in a slash, producing "/v4/spreadsheets//<id>/..."
//  and a 400 on every read.
//
//  Both would have been caught by looking at the finished string once. Run:
//      swift Tools/check-sheet-urls.swift
//

import Foundation

let base = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/")!

func trimmedRoot(_ path: String) -> String {
    path.hasSuffix("/") ? String(path.dropLast()) : path
}

func valuesURL(sheetId: String, suffix: String) -> URL? {
    guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
    else { return nil }
    comps.path = trimmedRoot(comps.path) + "/\(sheetId)/values/\(suffix)"
    return comps.url
}

let root = "https://sheets.googleapis.com/v4/spreadsheets/SID/values"
let cases: [(name: String, got: String?, want: String)] = [
    ("read a tab",      valuesURL(sheetId: "SID", suffix: "Signups")?.absoluteString,
                        "\(root)/Signups"),
    ("write a row",     valuesURL(sheetId: "SID", suffix: "Signups!A9:F9")?.absoluteString,
                        "\(root)/Signups!A9:F9"),
    ("read a header",   valuesURL(sheetId: "SID", suffix: "Plan!1:1")?.absoluteString,
                        "\(root)/Plan!1:1"),
    ("append to a tab", valuesURL(sheetId: "SID", suffix: "Signups:append")?.absoluteString,
                        "\(root)/Signups:append")
]

var failures = 0
for test in cases {
    let got = test.got ?? "<nil>"
    let ok = got == test.want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(test.name)")
    if !ok {
        print("       want: \(test.want)")
        print("       got : \(got)")
    }
    // The two shapes that have actually shipped broken.
    if got.contains("%") { print("       !! percent-encoded: \(got)"); failures += 1 }
    if got.contains("values//") || got.contains("spreadsheets//") {
        print("       !! double slash: \(got)"); failures += 1
    }
}

print(failures == 0 ? "\nall sheet URLs correct" : "\n\(failures) problem(s)")
exit(failures == 0 ? 0 : 1)
