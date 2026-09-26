//
//  APIBibleClient.swift
//  SolaPraise
//
//  Bible text from API.Bible (American Bible Society).
//
//  WHY THIS EXISTS: the app bundles 개역한글 — public domain since 2012 — and
//  nothing else, because every other translation is somebody's property.
//  Rather than negotiating with each rights holder, API.Bible aggregates
//  dozens of them behind one key, so which translations are available is a
//  property of the reader's own key rather than of this code.
//
//  WHAT IT CANNOT GET YOU: 새번역 and 개역개정 belong to 대한성서공회, who
//  license directly and do not publish a developer API. No aggregator can
//  hand those over on their behalf. NIV is in the catalogue but excluded from
//  commercial use, so it is usable in a personal build and a blocker for a
//  distributed one.
//

import Foundation

actor APIBibleClient {

    struct Version: Identifiable, Codable, Hashable {
        let id: String
        let abbreviation: String
        let name: String
        let language: String

        var label: String { "\(abbreviation) · \(name)" }
    }

    enum ClientError: LocalizedError {
        case missingKey
        case http(Int)
        case empty
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "API.Bible 키가 없습니다. 설정에서 입력해 주세요."
            case .http(401), .http(403):
                return "이 번역본에 대한 권한이 없습니다. 키의 플랜을 확인해 주세요."
            case .http(let code):
                return "API.Bible 오류 (\(code))"
            case .empty:
                return "본문을 찾지 못했습니다."
            case .transport(let error):
                return error.localizedDescription
            }
        }
    }

    private let session: URLSession
    private let keyProvider: @Sendable () -> String?
    private var passageCache: [String: [BibleVerse]] = [:]

    init(session: URLSession = .shared,
         keyProvider: @escaping @Sendable () -> String? = { ReadingSettings.apiBibleKey }) {
        self.session = session
        self.keyProvider = keyProvider
    }

    /// Everything the key is entitled to, which is the only honest way to
    /// present the choice — a hardcoded list would offer translations the
    /// reader's plan may not include.
    func versions() async throws -> [Version] {
        struct Response: Decodable {
            struct Item: Decodable {
                let id: String
                let abbreviation: String?
                let abbreviationLocal: String?
                let name: String?
                let nameLocal: String?
                struct Language: Decodable { let id: String?; let name: String? }
                let language: Language?
            }
            let data: [Item]?
        }

        let data = try await get(URL(string: "https://api.scripture.api.bible/v1/bibles")!)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.data ?? []).map {
            Version(
                id: $0.id,
                abbreviation: $0.abbreviationLocal ?? $0.abbreviation ?? "?",
                name: $0.nameLocal ?? $0.name ?? "Untitled",
                language: $0.language?.name ?? $0.language?.id ?? ""
            )
        }
        .sorted { ($0.language, $0.abbreviation) < ($1.language, $1.abbreviation) }
    }

    /// A passage in ESV-style reference syntax ("Judges 9:46-57").
    ///
    /// API.Bible's search endpoint accepts a plain reference and resolves it
    /// itself, which avoids this app having to know each translation's own
    /// book id scheme.
    func passage(_ query: String, versionId: String) async throws -> [BibleVerse] {
        let cacheKey = "\(versionId)|\(query)"
        if let cached = passageCache[cacheKey] { return cached }

        var comps = URLComponents(
            string: "https://api.scripture.api.bible/v1/bibles/\(versionId)/search"
        )!
        comps.queryItems = [
            .init(name: "query", value: query),
            .init(name: "limit", value: "200")
        ]

        struct Response: Decodable {
            struct Data: Decodable {
                struct Passage: Decodable { let content: String? }
                struct Verse: Decodable { let reference: String?; let text: String? }
                let passages: [Passage]?
                let verses: [Verse]?
            }
            let data: Data?
        }

        let data = try await get(comps.url!)
        let decoded = try JSONDecoder().decode(Response.self, from: data)

        var verses: [BibleVerse] = []
        if let text = decoded.data?.passages?.first?.content, !text.isEmpty {
            verses = Self.parse(Self.stripHTML(text))
        } else if let list = decoded.data?.verses, !list.isEmpty {
            verses = list.enumerated().compactMap { index, item in
                guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                let number = item.reference.flatMap {
                    Int($0.split(separator: ":").last?.filter(\.isNumber) ?? "")
                }
                return BibleVerse(number: number ?? index + 1, text: text)
            }
        }
        guard !verses.isEmpty else { throw ClientError.empty }

        // Rights holders cap how much may be stored. Keep this small and
        // drop the lot rather than tracking per-translation ceilings.
        if passageCache.values.reduce(0, { $0 + $1.count }) + verses.count > 400 {
            passageCache.removeAll()
        }
        passageCache[cacheKey] = verses
        return verses
    }

    // MARK: - Transport

    private func get(_ url: URL) async throws -> Data {
        guard let key = keyProvider(), !key.isEmpty else { throw ClientError.missingKey }

        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "api-key")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw ClientError.transport(error) }

        guard let http = response as? HTTPURLResponse else { throw ClientError.empty }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode)
        }
        return data
    }

    // MARK: - Text

    /// API.Bible returns HTML for passages. Verse numbers ride in
    /// `<span class="v">…</span>`, which becomes a bare number in the text —
    /// the same shape the ESV parser already reads.
    static func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "<span[^>]*class=\"v\"[^>]*>(\\d+)</span>",
            with: " [$1] ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#8217;", with: "'")
        return text.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
    }

    static func parse(_ text: String) -> [BibleVerse] {
        guard let regex = try? NSRegularExpression(
            pattern: "\\[(\\d+)\\]\\s*([^\\[]+)"
        ) else { return [] }

        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard let number = Int(ns.substring(with: match.range(at: 1))) else { return nil }
                let body = ns.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                return BibleVerse(number: number, text: body)
            }
    }
}
