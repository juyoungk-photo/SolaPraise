//
//  EditsToken.swift
//  SolaPraise
//
//  What a chart's Edits cell holds: the Drive file its corrections are in,
//  and which writing of that file — 「1AbC…#4」.
//
//  WHY THE NUMBER: each member's corrections to a chart are one file in
//  their Drive, written over each time rather than made anew. A new file
//  per fix changed the cell's id, which is how the others knew to look;
//  written over, the id stays, so the number after it is what changes.
//  A cell from before — an id alone — is writing 0.
//
//  Pure, so Tools/check-edits-token.swift runs it.
//

import Foundation

struct EditsToken: Equatable {
    let fileId: String
    let revision: Int

    init(fileId: String, revision: Int) {
        self.fileId = fileId
        self.revision = revision
    }

    /// The cell as read; nil when it is empty.
    init?(_ cell: String?) {
        let text = (cell ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: "#", maxSplits: 1).map(String.init)
        guard let id = parts.first, !id.isEmpty else { return nil }
        fileId = id
        revision = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    }

    /// As written in the cell.
    var cell: String { "\(fileId)#\(revision)" }

    /// The next writing of the same file.
    var next: EditsToken { EditsToken(fileId: fileId, revision: revision + 1) }
}
