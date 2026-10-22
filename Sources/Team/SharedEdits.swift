//
//  SharedEdits.swift
//  SolaPraise
//
//  The team's hand corrections to a chart's chords — kept on the team
//  sheet's hidden 「교정」 tab (CorrectionsTab); before that, in Drive files
//  named in each chart's Edits cell, which are still read until moved.
//
//  WHY: one person fixes a misread chord, and every other member's stand
//  still showed the misreading — corrections lived on the device that made
//  them. Now they go to a small JSON file in Drive, its id written in the
//  chart's Edits cell on the Attachments tab; any member opening the chart
//  takes them up — and a chart already open takes them up within seconds
//  (ScoreStandModel.watchTeam). Two members' fixes are put together, not
//  the last one's whole chart over the other's (EditMerge), and a member's
//  own unshared edits are never overwritten by someone else's.
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
        /// Key → that chart's 코드표 lyrics corrected by hand (LyricFixes).
        /// Optional: files shared before lyrics were shared have none.
        var lyrics: [String: [LyricFix]]? = nil
    }

    /// One chart's corrections as the 「교정」 tab keeps them, one row each
    /// (CorrectionsTab): its chords, its lyric fixes, and — on the page-map
    /// row of a 콘티 file — which page is which song.
    struct Entry: Codable, Equatable {
        var chords: [[ScoreChord]]? = nil
        var lyrics: [LyricFix]? = nil
        var pages: [String: String]? = nil
    }

    /// A chart's part of a Drive file from before the tab, as an entry.
    static func entry(from file: File, part: String) -> Entry? {
        if part == CorrectionsTab.pageMapPart { return file.pages.map { Entry(pages: $0) } }
        guard file.charts[part] != nil || file.lyrics?[part] != nil else { return nil }
        return Entry(chords: file.charts[part], lyrics: file.lyrics?[part])
    }

    /// The shared file, or nil when there is none or it cannot be read.
    /// Shared by link like every attachment, so no account is needed.
    /// `cell` is the Edits cell as written (EditsToken): the file, and which
    /// writing of it.
    static func fetch(_ cell: String?) async -> File? {
        guard let token = EditsToken(cell),
              let url = URL(string: "https://drive.google.com/uc?export=download&id=\(token.fileId)&v=\(token.revision)")
        else { return nil }
        // Never from a cache: a file written over keeps its address.
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    /// This account's own corrections file for each chart (by the chart's
    /// file id) and its last writing: written over rather than made anew.
    /// Kept per device and account; a file another account made is never
    /// written over.
    static func mine(for chart: String, account: String) -> EditsToken? {
        let all = UserDefaults.standard.dictionary(forKey: mineKey) as? [String: String] ?? [:]
        return EditsToken(all["\(account)|\(chart)"])
    }

    static func setMine(_ token: EditsToken?, for chart: String, account: String) {
        var all = UserDefaults.standard.dictionary(forKey: mineKey) as? [String: String] ?? [:]
        all["\(account)|\(chart)"] = token?.cell
        UserDefaults.standard.set(all, forKey: mineKey)
    }

    private static let mineKey = "sharedEdits.mine"
}
