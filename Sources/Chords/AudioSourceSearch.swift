//
//  AudioSourceSearch.swift
//  SolaPraise
//
//  Finding the actual recording, not a search box pointed at one.
//
//  WHAT WAS WRONG BEFORE: every entry under 음원 찾기 was a Google query with
//  a `site:` filter glued on. It never checked the song existed, never knew
//  which recording it had found, and left you to do the searching it claimed
//  to have done. For a feature whose whole job is "get me this file", that is
//  a link to a search box.
//
//  The iTunes Search API answers properly: no key, no quota worth counting,
//  and it returns the track — artist, album, release, length, price, artwork,
//  a 30-second preview to confirm it is the right recording, and a URL that
//  opens the store page where the file is bought.
//
//  IT SEARCHES THE US STORE, DELIBERATELY. The Korean store returns nothing
//  for any of these songs — not because the catalogue is thin but because
//  Apple does not sell music downloads in Korea at all, so the KR storefront
//  has no purchasable tracks to return. Verified against the live API: 어노인팅,
//  마커스 and 아이자야씩스티원 titles all come back empty on KR and correct on
//  US, with prices. The team's own songs are there; the storefront that
//  claims to be theirs is the one that cannot sell them.
//
//  Searching does not get anybody the audio. Buying does. That is why the
//  result rows lead to a store page rather than to a player, and why the
//  30-second preview is for recognising a recording and nothing else — the
//  analyser needs the file the purchase produces.
//

import Foundation

enum AudioSourceSearch {

    struct Track: Identifiable, Hashable {
        let id: Int
        let title: String
        let artist: String
        let album: String?
        let artwork: URL?
        /// The store page where this is bought.
        let storeURL: URL?
        /// Apple's 30-second clip, for telling two recordings apart.
        let previewURL: URL?
        let price: Double?
        let currency: String?
        let durationMillis: Int?
        let releasedAt: Date?
        let genre: String?

        var durationText: String? {
            guard let durationMillis else { return nil }
            let total = durationMillis / 1000
            return String(format: "%d:%02d", total / 60, total % 60)
        }

        var priceText: String? {
            guard let price, price > 0 else { return nil }
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency ?? "USD"
            return formatter.string(from: NSNumber(value: price))
        }
    }

    private struct Response: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let trackId: Int?
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let artworkUrl100: String?
            let trackViewUrl: String?
            let previewUrl: String?
            let trackPrice: Double?
            let currency: String?
            let trackTimeMillis: Int?
            let releaseDate: String?
            let primaryGenreName: String?
        }
    }

    /// A worship title carries decoration a store does not index: the
    /// uploader's brackets, a date, "LIVE", the channel's own name. Stripping
    /// it is the difference between finding the song and finding nothing.
    static func query(from title: String) -> String {
        var text = SheetMusicSources.clean(title)
        for pattern in [
            "\\[[^\\]]*\\]",            // [토요예배], [4k]
            "\\([^)]*\\)",              // (가사 포함), (Live)
            "\\|.*$",                   // everything after the first pipe
            "#\\S+",                    // #주를기다려
            "\\b\\d{1,2}[./]\\d{1,2}([./]\\d{2,4})?\\b"
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ",
                                             options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ",
                                         options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func search(_ term: String, limit: Int = 20) async throws -> [Track] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: trimmed),
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: String(limit)),
            // See the note above: KR sells no downloads.
            .init(name: "country", value: "US")
        ]
        guard let url = comps.url else { return [] }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let released = ISO8601DateFormatter()
        return decoded.results.compactMap { item in
            guard let id = item.trackId, let name = item.trackName else { return nil }
            return Track(
                id: id,
                title: name,
                artist: item.artistName ?? "",
                album: item.collectionName,
                // 100px is what the API offers; asking for 300 costs nothing
                // and stops the row looking soft on a retina screen.
                artwork: item.artworkUrl100
                    .map { $0.replacingOccurrences(of: "100x100bb", with: "300x300bb") }
                    .flatMap(URL.init(string:)),
                storeURL: item.trackViewUrl.flatMap(URL.init(string:)),
                previewURL: item.previewUrl.flatMap(URL.init(string:)),
                price: item.trackPrice,
                currency: item.currency,
                durationMillis: item.trackTimeMillis,
                releasedAt: item.releaseDate.flatMap { released.date(from: $0) },
                genre: item.primaryGenreName
            )
        }
    }
}
