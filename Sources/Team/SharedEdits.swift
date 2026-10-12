//
//  SharedEdits.swift
//  SolaPraise
//
//  The team's hand corrections to a chart's chords, shared through Drive.
//
//  WHY: one person fixes a misread chord, and every other member's stand
//  still showed the misreading — corrections lived on the device that made
//  them. Now they go to a small JSON file in Drive, its id written in the
//  chart's Edits cell on the Attachments tab; any member opening the chart
//  takes them up. Last one shared wins, and a member's own unshared edits
//  are never overwritten by someone else's.
//
//  The file is a map from a key — 「all」 for a whole chart, the page list
//  for one song's pages of a 콘티 file — to that chart's pages of chords.
//

import Foundation

enum SharedEdits {

    /// Which entry of the map a stand item reads and writes.
    static func key(pages: [Int]?) -> String {
        pages.map { "pages:" + $0.map(String.init).joined(separator: ",") } ?? "all"
    }

    /// What one attachment's shared file holds.
    struct File: Codable {
        /// Key (see `key(pages:)`) → that chart's pages of chords.
        var charts: [String: [[ScoreChord]]] = [:]
        /// For a 콘티 file: page index → the song it is, as someone set it
        /// by hand; "" for a page that is no song.
        var pages: [String: String]? = nil
    }

    /// The shared file, or nil when there is none or it cannot be read.
    /// Shared by link like every attachment, so no account is needed.
    static func fetch(_ fileId: String?) async -> File? {
        guard let fileId,
              let url = URL(string: "https://drive.google.com/uc?export=download&id=\(fileId)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }
}
