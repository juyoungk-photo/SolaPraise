//
//  TeamSnapshot.swift
//  SolaPraise
//
//  The team sheet as last read, kept on the device: when the sheet cannot
//  be read — no internet in the sanctuary, the app reopened by iOS mid
//  service — the services, the 순서 and the charts' list are there still,
//  said to be as of when they were read.
//
//  WHY: everything the 예배 준비 screen and the stand show came from a
//  read of the sheet, held in memory only. An app closed by iOS and
//  opened again without a connection had no services at all, and so no
//  way to the charts — though the charts themselves were on the device.
//
//  The tables as read, not parsed: parsed again on the way in, by the
//  same code, so a snapshot can never disagree with a read.
//

import Foundation

struct TeamSnapshot: Codable {
    var schedule: [[String]]
    var roles: [[String]]
    var songs: [[String]]
    var signups: [[String]]
    var plan: [[String]]
    var members: [[String]]?
    var grid: [[String]]?
    var memos: [[String]]?
    var titles: [String]?
    var attachments: [[String]]?
    var contiFiles: [ContiFile] = []
    var sheetId: String
    var savedAt: Date

    struct ContiFile: Codable {
        let id: String
        let name: String
        let modified: Date?
    }

    private static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("team-snapshot.json")
    }

    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The last read of this sheet; nil for another sheet or none.
    static func load(sheetId: String) -> TeamSnapshot? {
        guard let url, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TeamSnapshot.self, from: data),
              snapshot.sheetId == sheetId else { return nil }
        return snapshot
    }
}
