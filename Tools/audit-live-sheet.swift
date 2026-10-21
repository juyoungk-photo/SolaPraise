//
//  audit-live-sheet.swift
//  SolaPraise
//
//  Runs 워크플로 점검's sheet checks against the team's real sheet, from
//  the Mac, without the app.
//
//  WHY THIS EXISTS: the in-app audit runs only when somebody opens 예배
//  준비. This answers "is the sheet healthy right now?" from a terminal —
//  before a release, after a teammate reports something odd, or before
//  touching any code that writes to the sheet. Read-only: it downloads
//  the tabs' CSV exports and writes nothing anywhere.
//
//  It reads the sheet id from the gitignored Secrets.xcconfig and needs
//  the sheet to be readable by link. If the sheet's sharing is Restricted
//  it says so and stops; the in-app audit, which signs in, still works.
//  Account checks are skipped — there is no sign-in here to judge.
//
//  Run:
//      swiftc -O -o /tmp/liveaudit \
//          Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift \
//          Sources/Feed/SongSearchSuggestions.swift Sources/Feed/PlanSongTitle.swift \
//          Sources/Team/SongTitleTidy.swift Sources/Team/AvailabilityGrid.swift Sources/Team/SheetAudit.swift \
//          Tools/audit-live-sheet.swift
//      /tmp/liveaudit
//

import Foundation

@main
struct AuditLiveSheet {

    static func main() async {
        guard let sheetId = secret("TEAM_SHEET_ID") else {
            print("TEAM_SHEET_ID not found in Secrets.xcconfig — run from the repository root.")
            exit(2)
        }
        guard let page = await fetch("https://docs.google.com/spreadsheets/d/\(sheetId)/edit"),
              let html = String(data: page, encoding: .utf8) else {
            print("Could not reach the sheet.")
            exit(2)
        }
        let tabs = ["Schedule", "Songs", "Signups", "Members", "Plan", "Attachments"]
        var gids: [String: String] = [:]
        for tab in tabs {
            let pattern = #"\[\d+,0,\\?"(\d+)\\?",\[\{[^\]]*?\\?""# + tab + #"\\?""#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                gids[tab] = String(html[range])
            }
        }
        guard !gids.isEmpty else {
            print("The sheet is not readable by link (sharing is Restricted, or the page changed shape).")
            print("Use 예배 준비 → 워크플로 점검 in the app instead; it signs in.")
            exit(2)
        }

        var rows: [String: [[String]]] = [:]
        for (tab, gid) in gids {
            let url = "https://docs.google.com/spreadsheets/d/\(sheetId)/export?format=csv&gid=\(gid)"
            if let data = await fetch(url), let text = String(data: data, encoding: .utf8),
               !text.hasPrefix("<") {
                // The header wherever it is, as the app reads it.
                rows[tab] = TeamSheet.anchorHeader(csv(text), tab: tab)
            }
        }
        print("Read: " + tabs.map { "\($0) \(rows[$0].map { "\($0.count - 1)" } ?? "—")" }
            .joined(separator: " · "))

        let findings = SheetAudit.run(SheetAudit.Input(
            schedule: rows["Schedule"], songs: rows["Songs"], signups: rows["Signups"],
            members: rows["Members"], plan: rows["Plan"], attachments: rows["Attachments"],
            checksAccounts: false))

        for finding in findings {
            let mark: String
            switch finding.severity {
            case .ok: mark = "ok  "
            case .note: mark = "note"
            case .warning: mark = "WARN"
            case .problem: mark = "FAIL"
            }
            print("\(mark) [\(finding.area)] \(finding.title)")
            if !finding.detail.isEmpty, finding.severity != .ok { print("       \(finding.detail)") }
        }
        let problems = findings.filter { $0.severity == .problem }.count
        let warnings = findings.filter { $0.severity == .warning }.count
        print("\n\(problems) problem(s), \(warnings) warning(s)")
        exit(problems == 0 ? 0 : 1)
    }

    static func secret(_ key: String) -> String? {
        guard let text = try? String(contentsOfFile: "Secrets.xcconfig", encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix(key) {
            let value = line.split(separator: "=", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func fetch(_ address: String) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// RFC 4180: quoted fields, doubled quotes, newlines inside quotes.
    static func csv(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" {
                row.append(field); field = ""
                // Trailing empty cells are what the values API trims too.
                while row.last == "" { row.removeLast() }
                rows.append(row); row = []
            } else if c != "\r" { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
