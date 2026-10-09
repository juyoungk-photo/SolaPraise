//
//  check-sheet-tidy.swift
//  SolaPraise
//
//  Checks the formatting requests 「시트 보기 좋게 정리」 sends.
//
//  WHY THIS EXISTS: this writes to a document the whole team shares, and
//  its two ways of going wrong are both quiet. A rule added on every press
//  fills the sheet's rule list with copies nobody can tell apart; a rule
//  aimed at the wrong column colours a column of names by whether they
//  happen to read "가능". Neither throws. And the one thing it must never
//  do — write a value — would be invisible in a screenshot until somebody's
//  data was gone.
//
//  Run:
//      swiftc -O -o /tmp/tidycheck \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift \
//          Tools/check-sheet-tidy.swift
//      /tmp/tidycheck
//

import Foundation

@main
struct CheckSheetTidy {

    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { print("       \(detail())"); failures += 1 }
        }

        // Signups with its status in column F — not the default E — to
        // prove the column is read from the header, not assumed.
        let signups = SheetTidy.Tab(
            gid: 11, title: "Signups",
            header: ["Date", "Role", "MemberEmail", "MemberName", "UpdatedAt", "Status"],
            columnCount: 26, frozenRows: 0, existingFormulas: [])
        let schedule = SheetTidy.Tab(
            gid: 12, title: "Schedule",
            header: ["날짜", "예배", "Notes", "인도자"],
            columnCount: 10, frozenRows: 1, existingFormulas: [])
        let members = SheetTidy.Tab(
            gid: 13, title: "Members", header: ["Email", "Name", "Active"],
            columnCount: 5, frozenRows: 0, existingFormulas: [])
        let stranger = SheetTidy.Tab(
            gid: 14, title: "교회 재정", header: ["항목", "금액"],
            columnCount: 5, frozenRows: 0, existingFormulas: [])

        let first = SheetTidy.requests(for: [signups, schedule, members, stranger])
        let kinds = first.compactMap { $0.keys.first }

        // Never a value write: only formatting request kinds.
        let allowed: Set<String> = ["updateSheetProperties", "repeatCell",
                                    "autoResizeDimensions", "addConditionalFormatRule"]
        check("only formatting requests, never a value write",
              Set(kinds).isSubset(of: allowed), "got \(Set(kinds))")

        func sheetIds(_ requests: [[String: Any]]) -> Set<Int> {
            Set(requests.compactMap { request -> Int? in
                let body = request.values.first as? [String: Any]
                if let range = body?["range"] as? [String: Any] { return range["sheetId"] as? Int }
                if let dims = body?["dimensions"] as? [String: Any] { return dims["sheetId"] as? Int }
                if let props = body?["properties"] as? [String: Any] { return props["sheetId"] as? Int }
                if let rule = body?["rule"] as? [String: Any],
                   let ranges = rule["ranges"] as? [[String: Any]] { return ranges.first?["sheetId"] as? Int }
                return nil
            })
        }
        check("a tab the app does not know is left alone", !sheetIds(first).contains(14))

        let freezes = first.filter { $0["updateSheetProperties"] != nil }
        check("freezes only the tabs not already frozen", freezes.count == 2,
              "got \(freezes.count)")

        func formulas(_ requests: [[String: Any]]) -> [String] {
            requests.compactMap { request in
                guard let add = request["addConditionalFormatRule"] as? [String: Any],
                      let rule = add["rule"] as? [String: Any],
                      let boolean = rule["booleanRule"] as? [String: Any],
                      let condition = boolean["condition"] as? [String: Any],
                      let values = condition["values"] as? [[String: Any]] else { return nil }
                return values.first?["userEnteredValue"] as? String
            }
        }
        let added = formulas(first)
        check("status colours read the Status column found in the header (F)",
              added.contains { $0.contains("$F2") && $0.contains("어려움") }
                && !added.contains { $0.contains("$E2") && $0.contains("어려움") },
              "got \(added.filter { $0.contains("어려움") })")
        check("the Korean 날짜 header is found for the date rules",
              added.contains { $0.contains("$A2>=TODAY()") })
        check("Members gets no date or status colouring",
              !formulas(first.filter { sheetIds([$0]) == [13] }).contains { !$0.isEmpty })
        check("four status colours and two date rules on Signups, two on Schedule",
              added.count == 8, "got \(added.count): \(added)")

        // Pressing it again: the sheet now holds those rules.
        let after = [signups, schedule].map { tab in
            SheetTidy.Tab(gid: tab.gid, title: tab.title, header: tab.header,
                          columnCount: tab.columnCount, frozenRows: 1,
                          existingFormulas: Set(added))
        }
        let second = SheetTidy.requests(for: after)
        check("a second press adds no rule", formulas(second).isEmpty,
              "got \(formulas(second))")
        check("a second press does not re-freeze", second.allSatisfy { $0["updateSheetProperties"] == nil })

        // It must survive JSON encoding, which is how it is sent.
        check("the requests encode as JSON",
              (try? JSONSerialization.data(withJSONObject: ["requests": first])) != nil)

        print(failures == 0 ? "\nall sheet tidy checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
