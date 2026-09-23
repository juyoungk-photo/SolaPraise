//
//  ESVClient.swift
//  SolaPraise
//
//  Crossway's official ESV API (api.esv.org), used under a free
//  non-commercial key.
//
//  THE STORAGE CAP IS A LICENCE TERM, NOT A PERFORMANCE CHOICE.
//  Crossway allow storing at most 500 verses, or half a book, whichever is
//  less. Psalms has 2,461 verses, so the ceiling is 500 — which is why ESV is
//  fetched per chapter and the cache below evicts to stay under it. Bundling
//  ESV the way 개역한글 is bundled would breach the terms outright.
//

import Foundation

actor ESVClient {

    /// Crossway's ceiling. Do not raise this.
    static let maxCachedVerses = 500

    private let keyProvider: @Sendable () -> String?
    private let session: URLSession

    /// chapter → verses, with insertion order tracked for eviction.
    private var cache: [Int: [BibleVerse]] = [:]
    private var insertionOrder: [Int] = []

    init(keyProvider: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.keyProvider = keyProvider
        self.session = session
    }

    enum ESVError: LocalizedError {
        case missingKey
        case http(Int)
        case transport(Error)
        case empty

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Add your free ESV API key in Settings to read in English. Register at api.esv.org."
            case .http(let code):
                return code == 401
                    ? "That ESV API key was rejected. Check it in Settings."
                    : "The ESV API returned an error (\(code))."
            case .transport(let e):
                return "Network problem: \(e.localizedDescription)"
            case .empty:
                return "The ESV API returned no text for that psalm."
            }
        }
    }

    func chapter(_ number: Int) async throws -> [BibleVerse] {
        if let cached = cache[number] { return cached }

        guard let key = keyProvider(), !key.isEmpty else { throw ESVError.missingKey }

        var comps = URLComponents(string: "https://api.esv.org/v3/passage/text/")!
        comps.queryItems = [
            .init(name: "q", value: "Psalm \(number)"),
            .init(name: "include-passage-references", value: "false"),
            .init(name: "include-verse-numbers", value: "true"),
            .init(name: "include-first-verse-numbers", value: "true"),
            .init(name: "include-footnotes", value: "false"),
            .init(name: "include-headings", value: "false"),
            .init(name: "include-short-copyright", value: "false"),
            .init(name: "include-passage-horizontal-lines", value: "false"),
            .init(name: "include-heading-horizontal-lines", value: "false"),
            .init(name: "indent-paragraphs", value: "0"),
            .init(name: "indent-poetry", value: "false")
        ]

        var req = URLRequest(url: comps.url!)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw ESVError.transport(error) }

        guard let http = response as? HTTPURLResponse else { throw ESVError.empty }
        guard (200..<300).contains(http.statusCode) else { throw ESVError.http(http.statusCode) }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let passage = decoded.passages?.first, !passage.isEmpty else { throw ESVError.empty }

        let verses = Self.parse(passage)
        guard !verses.isEmpty else { throw ESVError.empty }

        store(number, verses)
        return verses
    }

    /// Keeps the cache under Crossway's 500-verse ceiling by evicting the
    /// oldest chapters until the newcomer fits.
    private func store(_ number: Int, _ verses: [BibleVerse]) {
        cache[number] = verses
        insertionOrder.removeAll { $0 == number }
        insertionOrder.append(number)

        while totalCachedVerses > Self.maxCachedVerses, let oldest = insertionOrder.first {
            cache.removeValue(forKey: oldest)
            insertionOrder.removeFirst()
        }
    }

    private var totalCachedVerses: Int {
        cache.values.reduce(0) { $0 + $1.count }
    }

    /// The text endpoint returns one string with verse numbers in brackets:
    /// "[1] Blessed is the man… [2] but his delight…"
    static func parse(_ passage: String) -> [BibleVerse] {
        var verses: [BibleVerse] = []
        let pattern = #"\[(\d+)\]\s*([^\[]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let ns = passage as NSString
        for match in regex.matches(in: passage, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 3,
                  let number = Int(ns.substring(with: match.range(at: 1))) else { continue }
            let text = ns.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                verses.append(BibleVerse(number: number, text: text))
            }
        }
        return verses
    }

    private struct Response: Decodable {
        let passages: [String]?
    }
}
