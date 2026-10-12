//
//  ContiPages.swift
//  SolaPraise
//
//  A 콘티 file uploaded whole — every song's chart in one PDF, or a stack
//  of photos — split back onto the 순서: which page is which song.
//
//  Worked out once per file on this device, by reading each page's title
//  (ScoreRecognition.titleLines) and matching it to the service's songs
//  (ScorePageMatcher), and kept: a file id is a file's contents, so the
//  answer never goes stale. Nothing is written to the sheet or Drive.
//

import Foundation
import UIKit

enum ContiPages {

    private static let key = "conti.pages.v2"  // v2: the 순서-order fallback; older guesses are worked out again

    /// Page index → song title, as last worked out for this file.
    static func cached(_ fileId: String) -> [Int: String]? {
        guard let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]],
              let pages = all[fileId] else { return nil }
        return Dictionary(uniqueKeysWithValues: pages.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    /// How many pages the file has, so the pages no song took can be shown.
    static func pageCount(_ fileId: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: key + ".count") as? [String: Int])?[fileId]
    }

    private static func store(_ pages: [Int: String], count: Int, for fileId: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]]) ?? [:]
        all[fileId] = Dictionary(uniqueKeysWithValues: pages.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(all, forKey: key)
        var counts = (UserDefaults.standard.dictionary(forKey: key + ".count") as? [String: Int]) ?? [:]
        counts[fileId] = count
        UserDefaults.standard.set(counts, forKey: key + ".count")
    }

    /// The app's own 「콘티 PDF 만들기」 output, which is already in order and
    /// is not split again.
    static func isBuilt(_ attachment: Attachment) -> Bool {
        attachment.name.hasSuffix("-콘티.pdf")
    }

    /// Works the pages out for a file, reading it if needed. Nil when the
    /// file cannot be read.
    /// Pages set by hand — here, or by a teammate and shared — which win
    /// over anything worked out.
    static func setManual(_ pages: [Int: String], for fileId: String, count: Int) {
        // "" marks a page that is no song; it is stored as unplaced.
        store(pages.filter { !$0.value.isEmpty }, count: count, for: fileId)
        var manual = Set(UserDefaults.standard.stringArray(forKey: key + ".manual") ?? [])
        manual.insert(fileId)
        UserDefaults.standard.set(Array(manual), forKey: key + ".manual")
    }

    static func isManual(_ fileId: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key + ".manual") ?? []).contains(fileId)
    }

    @discardableResult
    static func compute(for attachment: Attachment, songs: [String]) async -> [Int: String]? {
        // Someone on the team set the pages by hand: that is the answer.
        if let shared = await SharedEdits.fetch(attachment.editsFileId)?.pages {
            let pages = Dictionary(uniqueKeysWithValues: shared.compactMap { k, v in Int(k).map { ($0, v) } })
            setManual(pages, for: attachment.fileId, count: max(pageCount(attachment.fileId) ?? 0, (pages.keys.max() ?? -1) + 1))
            return pages.filter { !$0.value.isEmpty }
        }
        if let known = cached(attachment.fileId) { return known }
        let data: Data
        if let kept = ScoreFileCache.load(attachment.fileId) {
            data = kept
        } else {
            guard let (bytes, _) = try? await URLSession.shared.data(from: attachment.url.directDownload)
            else { return nil }
            data = bytes
        }
        guard let read = await ScoreTransposer.read(data: data, recognise: false) else { return nil }
        ScoreFileCache.save(data, for: attachment.fileId)
        let images = read.pages.compactMap { $0.image.cgImage }
        let titles = await Task.detached(priority: .userInitiated) {
            images.map(ScoreRecognition.titleLines(in:))
        }.value
        let pages = ScorePageMatcher.assign(pageTitles: titles, songs: songs)
        store(pages, count: titles.count, for: attachment.fileId)
        return pages
    }

    /// Pages runs as the stand shows them: each song's pages, in order.
    static func pages(of fileId: String, for song: String) -> [Int] {
        (cached(fileId) ?? [:]).filter { $0.value == song }.map(\.key).sorted()
    }
}
