//
//  SheetTidy.swift
//  SolaPraise
//
//  Making the team sheet readable at a glance, without touching its data.
//
//  The sheet is the team's own document, edited by hand in a browser, and
//  the app reads it by header text. So this changes only how it LOOKS:
//
//  - every known tab's header row frozen, bold and shaded, columns sized
//    to what they hold;
//  - rows dated this week tinted, so the service being prepared stands out
//    from a year of history;
//  - rows dated in the past greyed;
//  - on Signups, each answer coloured by what it means — 가능 green,
//    미정 yellow, 어려움 red, 자리비움 grey — the same colours the app uses.
//
//  No value is written, no row or column added, moved or removed. Tabs the
//  app does not know are left alone entirely.
//
//  Safe to press twice. Freezing and header styling simply restate
//  themselves; a colour rule is added only when a rule with the same
//  formula is not already on that tab — otherwise every press would stack
//  another copy, and the sheet's rule list would fill with duplicates
//  nobody can tell apart.
//
//  Pure Foundation, so the request list can be checked without a network:
//  Tools/check-sheet-tidy.swift.
//

import Foundation

enum SheetTidy {

    /// What the app knows about one tab before tidying it.
    struct Tab {
        let gid: Int
        let title: String
        let header: [String]
        let columnCount: Int
        let frozenRows: Int
        /// Formulas of the conditional-format rules already on the tab.
        let existingFormulas: Set<String>
    }

    /// The tabs worth tidying, by the names the app reads.
    static let knownTabs: Set<String> = [
        TeamSheet.scheduleTab, TeamSheet.rolesTab, TeamSheet.songsTab,
        TeamSheet.signupsTab, TeamSheet.membersTab, TeamSheet.planTab,
        TeamSheet.liveTab, TeamSheet.attachmentsTab
    ]

    /// Tabs whose rows are dated, and so get this-week and past colouring.
    static let datedTabs: Set<String> = [
        TeamSheet.scheduleTab, TeamSheet.songsTab, TeamSheet.signupsTab,
        TeamSheet.planTab, TeamSheet.attachmentsTab
    ]

    struct Colour { let red: Double, green: Double, blue: Double }
    static let headerShade   = Colour(red: 0.92, green: 0.93, blue: 0.96)
    static let thisWeekShade = Colour(red: 1.00, green: 0.96, blue: 0.80)
    static let pastText      = Colour(red: 0.60, green: 0.60, blue: 0.60)
    static let available     = Colour(red: 0.85, green: 0.95, blue: 0.85)
    static let maybe         = Colour(red: 1.00, green: 0.95, blue: 0.75)
    static let declined      = Colour(red: 0.98, green: 0.85, blue: 0.85)
    static let away          = Colour(red: 0.91, green: 0.91, blue: 0.91)

    /// The batchUpdate requests for these tabs, as JSON objects.
    static func requests(for tabs: [Tab]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for tab in tabs where knownTabs.contains(tab.title) {
            let width = max(tab.columnCount, tab.header.count, 1)

            if tab.frozenRows < 1 {
                out.append(["updateSheetProperties": [
                    "properties": ["sheetId": tab.gid,
                                   "gridProperties": ["frozenRowCount": 1]],
                    "fields": "gridProperties.frozenRowCount"
                ]])
            }

            out.append(["repeatCell": [
                "range": range(tab.gid, rows: 0..<1, columns: 0..<width),
                "cell": ["userEnteredFormat": [
                    "textFormat": ["bold": true],
                    "backgroundColor": json(headerShade)
                ]],
                "fields": "userEnteredFormat(textFormat.bold,backgroundColor)"
            ]])

            out.append(["autoResizeDimensions": ["dimensions": [
                "sheetId": tab.gid, "dimension": "COLUMNS",
                "startIndex": 0, "endIndex": width
            ]]])

            var rules: [(formula: String, format: [String: Any])] = []

            if datedTabs.contains(tab.title) {
                let date = column(TeamSheet.column(tab.header, ["date", "날짜"]) ?? 0)
                // N() is 0 for text, so a hand-typed date Sheets did not
                // recognise is left uncoloured rather than compared as text.
                rules.append((
                    "=AND(N($\(date)2)>0,$\(date)2>=TODAY(),$\(date)2<TODAY()+7)",
                    ["backgroundColor": json(thisWeekShade)]))
                rules.append((
                    "=AND(N($\(date)2)>0,$\(date)2<TODAY())",
                    ["textFormat": ["foregroundColor": json(pastText)]]))
            }

            if tab.title == TeamSheet.signupsTab {
                let status = column(TeamSheet.column(tab.header, ["status", "상태", "응답"]) ?? 4)
                // Spelled the ways SignupStatus reads them.
                rules.append((anyOf(status, ["declined", "불가", "어려움"]),
                               ["backgroundColor": json(declined)]))
                rules.append((anyOf(status, ["away", "자리비움", "부재"]),
                               ["backgroundColor": json(away)]))
                rules.append((anyOf(status, ["maybe", "미정", "아마", "tentative"]),
                               ["backgroundColor": json(maybe)]))
                rules.append((anyOf(status, ["available", "가능"]),
                               ["backgroundColor": json(available)]))
            }

            for rule in rules where !tab.existingFormulas.contains(rule.formula) {
                out.append(["addConditionalFormatRule": [
                    "index": 0,
                    "rule": [
                        "ranges": [range(tab.gid, fromRow: 1, columns: 0..<width)],
                        "booleanRule": [
                            "condition": ["type": "CUSTOM_FORMULA",
                                          "values": [["userEnteredValue": rule.formula]]],
                            "format": rule.format
                        ]
                    ]
                ]])
            }
        }
        return out
    }

    // MARK: - Pieces

    /// "A" … "Z", "AA" …
    static func column(_ index: Int) -> String { TeamSheet.columnLetter(index) }

    private static func anyOf(_ column: String, _ words: [String]) -> String {
        let tests = words.map { "LOWER(TRIM($\(column)2))=\"\($0.lowercased())\"" }
        return "=OR(\(tests.joined(separator: ",")))"
    }

    private static func json(_ c: Colour) -> [String: Double] {
        ["red": c.red, "green": c.green, "blue": c.blue]
    }

    /// A grid range.
    private static func range(_ gid: Int, rows: Range<Int>, columns: Range<Int>) -> [String: Any] {
        ["sheetId": gid,
         "startRowIndex": rows.lowerBound, "endRowIndex": rows.upperBound,
         "startColumnIndex": columns.lowerBound, "endColumnIndex": columns.upperBound]
    }

    /// From a row to the end of the sheet, so rows the team adds next
    /// month are coloured too.
    private static func range(_ gid: Int, fromRow start: Int, columns: Range<Int>) -> [String: Any] {
        ["sheetId": gid, "startRowIndex": start,
         "startColumnIndex": columns.lowerBound, "endColumnIndex": columns.upperBound]
    }
}
