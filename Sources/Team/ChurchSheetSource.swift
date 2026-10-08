//
//  ChurchSheetSource.swift
//  SolaPraise
//
//  Which church sheet this device reads, and the link to open it.
//
//  Split from ChurchSheet so the parser there depends on nothing but
//  Foundation — it can be compiled and run on its own, which is what
//  Tools/check-church-sheet.swift does. A header-matching parser fails by
//  returning an empty result, not by crashing, so it is exactly the kind that
//  has to be exercised outside the app.
//

import Foundation

enum ChurchSheetSource {
    /// A sheet typed in on this device wins over the build's, the same way
    /// the team sheet works.
    static var current: String? {
        if let local = ReadingSettings.churchSheetId, !local.isEmpty { return local }
        return AppSecrets.churchSheetId
    }

    /// The document itself, for the "시트 열기" link.
    static var url: URL? {
        current.flatMap { URL(string: "https://docs.google.com/spreadsheets/d/\($0)/edit") }
    }
}
