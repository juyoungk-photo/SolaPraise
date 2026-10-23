//
//  CorrectionsTab.swift
//  SolaPraise
//
//  The team sheet's hidden 「교정」 tab: a 콘티 file's page map — which page
//  is which song — one row per file, with which writing it is, who wrote
//  it and when.
//
//  Charts' chord corrections and drawings were kept here too, read every
//  few seconds by every open stand; they now go from stand to stand in the
//  room (RehearsalLink), and to everyone else as a PDF. What a member sets
//  once for the team and everyone opens by stays.
//
//  Pure, so Tools/check-corrections-tab.swift runs it.
//

import Foundation

enum CorrectionsTab {

    static let tab = "교정"
    static let header = ["파일", "곡", "부분", "버전", "교정", "고친 사람", "고친 때"]
    /// The part of a 콘티 file that says which page is which song.
    static let pageMapPart = "pages-map"
    /// A sheet cell holds 50,000 characters; a little room is kept.
    static let largestBody = 49_000

    struct Layout: Equatable {
        let file: Int, song: Int, part: Int, revision: Int, body: Int, by: Int, at: Int
        init?(header: [String]) {
            func at(_ name: String) -> Int? {
                header.firstIndex { $0.trimmingCharacters(in: .whitespaces) == name }
            }
            guard let file = at("파일"), let part = at("부분"), let revision = at("버전"), let body = at("교정")
            else { return nil }
            self.file = file
            self.part = part
            self.revision = revision
            self.body = body
            song = at("곡") ?? 1
            by = at("고친 사람") ?? 5
            self.at = at("고친 때") ?? 6
        }
        static let standard = Layout(header: CorrectionsTab.header)!
    }

    /// One chart's row: where it is and which writing it holds.
    struct Row: Equatable {
        let row: Int
        let revision: Int
    }

    static func key(fileId: String, part: String) -> String { "\(fileId)|\(part)" }

    /// The rows by chart, from three of the tab's columns as read top to
    /// bottom (row 1 the header). A chart written twice by two members in
    /// the same moment has two rows; the lower one is the one kept.
    static func index(files: [String], parts: [String], revisions: [String]) -> [String: Row] {
        var out: [String: Row] = [:]
        for (offset, file) in files.enumerated() where offset > 0 {
            let id = file.trimmingCharacters(in: .whitespaces)
            let part = parts.indices.contains(offset) ? parts[offset].trimmingCharacters(in: .whitespaces) : ""
            guard !id.isEmpty, !part.isEmpty else { continue }
            let revision = revisions.indices.contains(offset) ? Int(revisions[offset].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
            out[key(fileId: id, part: part)] = Row(row: offset + 1, revision: revision)
        }
        return out
    }

    /// How a revision is remembered on a device: 「tab#3」 — apart from the
    /// Drive files of before, remembered by their own id.
    static func token(_ revision: Int) -> String { "tab#\(revision)" }
}
