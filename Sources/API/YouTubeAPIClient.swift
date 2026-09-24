//
//  YouTubeAPIClient.swift
//  SolaPraise
//
//  URLSession wrapper over YouTube Data API v3, following the shape of
//  PraiseTheLord's SheetsAPIClient: bearer token from GoogleAuthManager,
//  cursor pagination, typed error decoding.
//
//  Every call routes through `get(...)` so the QuotaLedger sees the cost
//  before the request leaves — there is no path that spends units silently.
//

import Foundation

@MainActor
final class YouTubeAPIClient {

    private let auth: GoogleAuthManager
    private let quota: QuotaLedger
    private let session: URLSession

    private static let base = URL(string: "https://youtube.googleapis.com/youtube/v3/")!

    /// Guards against a runaway cursor loop on a very large library.
    private static let maxPages = 20

    init(auth: GoogleAuthManager, quota: QuotaLedger, session: URLSession = .shared) {
        self.auth = auth
        self.quota = quota
        self.session = session
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case quotaExhausted
        case searchBudgetSpent
        case notSignedIn
        case http(status: Int, reason: String?, message: String?)
        case transport(Error)
        case decoding(Error)

        var errorDescription: String? {
            switch self {
            case .quotaExhausted:
                return "Today's YouTube API budget is used up. It resets at midnight Pacific."
            case .searchBudgetSpent:
                return "You've used all \(QuotaLedger.dailySearchLimit) searches for today. Your channels and playlists still work — search resets at midnight Pacific."
            case .notSignedIn:
                return "Sign in with Google to continue."
            case .http(let status, let reason, let message):
                if let message { return message }
                return "YouTube API error \(status)\(reason.map { " (\($0))" } ?? "")."
            case .transport(let e):
                return "Network problem: \(e.localizedDescription)"
            case .decoding:
                return "Unexpected response from YouTube."
            }
        }
    }

    // MARK: - Core request

    private func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem],
        cost: QuotaLedger.Cost,
        as type: T.Type = T.self
    ) async throws -> T {
        try await send(path, method: "GET", query: query, body: Optional<Never>.none, cost: cost)
    }

    /// Shared transport. Every call routes through here so the ledger sees the
    /// cost before the request leaves — there is no path that spends silently.
    private func send<T: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        query: [URLQueryItem],
        body: Body?,
        cost: QuotaLedger.Cost,
        as type: T.Type = T.self
    ) async throws -> T {
        let data = try await perform(path, method: method, query: query, body: body, cost: cost)
        if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T { return empty }
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(error) }
    }

    /// A 204 with no body — playlistItems.delete.
    struct EmptyResponse: Decodable {}

    private func perform<Body: Encodable>(
        _ path: String,
        method: String,
        query: [URLQueryItem],
        body: Body?,
        cost: QuotaLedger.Cost
    ) async throws -> Data {

        guard quota.canAfford(cost) else { throw APIError.quotaExhausted }

        guard var comps = URLComponents(
            url: Self.base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw APIError.transport(URLError(.badURL)) }
        comps.queryItems = query
        guard let url = comps.url else { throw APIError.transport(URLError(.badURL)) }

        let token: String
        do { token = try await auth.accessToken() }
        catch { throw APIError.notSignedIn }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { req.httpBody = try JSONEncoder().encode(body) }
            catch { throw APIError.decoding(error) }
        }

        // Charge before the wire, so a burst can't overshoot the ceiling.
        quota.record(cost)

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw APIError.transport(error) }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }

        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? Self.decoder.decode(YTErrorResponse.self, from: data)
            let reason = decoded?.firstReason
            if QuotaLedger.isLimitReason(reason) {
                quota.markExhausted()
                throw APIError.quotaExhausted
            }
            throw APIError.http(
                status: http.statusCode,
                reason: reason,
                message: decoded?.error?.message
            )
        }

        return data
    }

    /// Walks `nextPageToken` until exhausted, charging `cost` per page.
    private func getAllPages<Item: Decodable>(
        _ path: String,
        query: [URLQueryItem],
        cost: QuotaLedger.Cost,
        of: Item.Type = Item.self
    ) async throws -> [Item] {

        var out: [Item] = []
        var token: String?
        var pages = 0

        repeat {
            var q = query
            if let token { q.append(URLQueryItem(name: "pageToken", value: token)) }

            let page: YTListResponse<Item> = try await get(path, query: q, cost: cost)
            out.append(contentsOf: page.items ?? [])
            token = page.nextPageToken
            pages += 1
        } while token != nil && pages < Self.maxPages

        return out
    }

    // MARK: - Playlists (1 unit per page)

    /// Every playlist the signed-in user owns.
    func myPlaylists() async throws -> [YTPlaylist] {
        try await getAllPages(
            "playlists",
            query: [
                .init(name: "part", value: "snippet,contentDetails,status,statistics"),
                .init(name: "mine", value: "true"),
                .init(name: "maxResults", value: "50")
            ],
            cost: .read
        )
    }

    /// Items of one playlist, in playlist order.
    func playlistItems(playlistId: String) async throws -> [YTPlaylistItem] {
        let items: [YTPlaylistItem] = try await getAllPages(
            "playlistItems",
            query: [
                .init(name: "part", value: "snippet,contentDetails"),
                .init(name: "playlistId", value: playlistId),
                .init(name: "maxResults", value: "50")
            ],
            cost: .read
        )
        return items.sorted { $0.position < $1.position }
    }

    // MARK: - Videos (1 unit per 50)

    /// Durations and canonical metadata. Batched 50 at a time — this is the
    /// difference between 1 unit and 50 for a full playlist.
    func videos(ids: [String]) async throws -> [YTVideo] {
        guard !ids.isEmpty else { return [] }
        var out: [YTVideo] = []

        for chunk in stride(from: 0, to: ids.count, by: 50).map({
            Array(ids[$0 ..< min($0 + 50, ids.count)])
        }) {
            let page: YTListResponse<YTVideo> = try await get(
                "videos",
                query: [
                    // `status` carries `embeddable`. Extra parts do not cost
                    // extra quota — videos.list is 1 unit regardless.
                    .init(name: "part", value: "snippet,contentDetails,status,statistics"),
                    .init(name: "id", value: chunk.joined(separator: ",")),
                    .init(name: "maxResults", value: "50")
                ],
                cost: .read
            )
            out.append(contentsOf: page.items ?? [])
        }
        return out
    }

    // MARK: - Channel uploads (1 unit)

    /// A channel's most recent uploads, via the official API.
    ///
    /// This exists because the free RSS endpoint
    /// (`feeds/videos.xml?channel_id=`) is genuinely unreliable — the same URL
    /// returns 200 with 15 entries and then 404 minutes later, with no pattern
    /// and while youtube.com itself is fine. An empty 말씀 feed is worse than
    /// spending a unit.
    ///
    /// Costs 1 unit: every channel's uploads live in a playlist whose id is the
    /// channel id with the `UC` prefix replaced by `UU`, so no channels.list
    /// lookup is needed first.
    func channelUploads(channelId: String, limit: Int = 15) async throws -> [YTPlaylistItem] {
        guard channelId.hasPrefix("UC") else { return [] }
        let uploadsId = "UU" + channelId.dropFirst(2)

        var collected: [YTPlaylistItem] = []
        var pageToken: String?

        while collected.count < limit {
            var query: [URLQueryItem] = [
                .init(name: "part", value: "snippet,contentDetails"),
                .init(name: "playlistId", value: uploadsId),
                .init(name: "maxResults", value: "50")
            ]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }

            let page: YTListResponse<YTPlaylistItem> = try await get(
                "playlistItems", query: query, cost: .read
            )
            collected.append(contentsOf: page.items ?? [])
            guard let next = page.nextPageToken else { break }
            pageToken = next
        }
        return Array(collected.prefix(limit))
    }

    /// Playlists published by a channel (1 unit per 50).
    func channelPlaylists(channelId: String, limit: Int = 200) async throws -> [YTPlaylist] {
        var collected: [YTPlaylist] = []
        var pageToken: String?

        while collected.count < limit {
            var query: [URLQueryItem] = [
                .init(name: "part", value: "snippet,contentDetails,status,statistics"),
                .init(name: "channelId", value: channelId),
                .init(name: "maxResults", value: "50")
            ]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }

            let page: YTListResponse<YTPlaylist> = try await get(
                "playlists", query: query, cost: .read
            )
            collected.append(contentsOf: page.items ?? [])
            guard let next = page.nextPageToken else { break }
            pageToken = next
        }
        return Array(collected.prefix(limit))
    }

    // MARK: - Channels (1 unit)

    /// Resolves a pasted channel reference to a concrete channel.
    /// A `.channelId` costs 1 unit to look up metadata; a `.handle` also
    /// costs 1. Either way it happens once, when the channel is added.
    func channel(for ref: YouTubeID.ChannelRef) async throws -> YTChannel? {
        var query: [URLQueryItem] = [
            .init(name: "part", value: "snippet,contentDetails")
        ]
        switch ref {
        case .channelId(let id):  query.append(.init(name: "id", value: id))
        case .handle(let h):      query.append(.init(name: "forHandle", value: h))
        case .username(let u):    query.append(.init(name: "forUsername", value: u))
        }

        let page: YTListResponse<YTChannel> = try await get(
            "channels", query: query, cost: .read
        )
        return page.items?.first
    }

    // MARK: - Search (100 units — the expensive one)

    /// General YouTube search. Refuses when the self-imposed daily search
    /// budget is gone, with a clear message rather than a raw 403 — seeing
    /// this budget run down is the whole discipline mechanism.
    func search(query: String, channelId: String? = nil,
                maxResults: Int = 24) async throws -> [YTSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard quota.canSearch else { throw APIError.searchBudgetSpent }

        var searchQuery: [URLQueryItem] = [
            .init(name: "part", value: "snippet"),
            .init(name: "q", value: trimmed)
        ]
        if let channelId { searchQuery.append(.init(name: "channelId", value: channelId)) }

        let page: YTListResponse<YTSearchResult> = try await get(
            "search",
            query: searchQuery + [
                .init(name: "type", value: "video"),
                // Only return videos the in-app player can actually play.
                .init(name: "videoEmbeddable", value: "true"),
                .init(name: "maxResults", value: String(min(maxResults, 50))),
                .init(name: "safeSearch", value: "moderate")
            ],
            cost: .search
        )
        return (page.items ?? []).filter { $0.videoId != nil }
    }

    // MARK: - Playlist writes (50 units each)

    func createPlaylist(
        title: String,
        description: String = "",
        privacy: String = "private"
    ) async throws -> YTPlaylist {
        struct Body: Encodable {
            struct Snippet: Encodable { let title: String; let description: String }
            struct Status: Encodable { let privacyStatus: String }
            let snippet: Snippet
            let status: Status
        }
        return try await send(
            "playlists",
            method: "POST",
            query: [.init(name: "part", value: "snippet,status,contentDetails")],
            body: Body(
                snippet: .init(title: title, description: description),
                status: .init(privacyStatus: privacy)
            ),
            cost: .write
        )
    }

    func addVideo(_ videoId: String, to playlistId: String) async throws -> YTPlaylistItem {
        struct Body: Encodable {
            struct Resource: Encodable { let kind = "youtube#video"; let videoId: String }
            struct Snippet: Encodable { let playlistId: String; let resourceId: Resource }
            let snippet: Snippet
        }
        return try await send(
            "playlistItems",
            method: "POST",
            query: [.init(name: "part", value: "snippet,contentDetails")],
            body: Body(snippet: .init(playlistId: playlistId, resourceId: .init(videoId: videoId))),
            cost: .write
        )
    }

    func removePlaylistItem(itemId: String) async throws {
        _ = try await send(
            "playlistItems",
            method: "DELETE",
            query: [.init(name: "id", value: itemId)],
            body: Optional<Never>.none,
            cost: .write,
            as: EmptyResponse.self
        )
    }

    /// Moves one item to `position`. YouTube shifts everything else itself, so
    /// dragging a song in a 30-song list costs 50 units — not 1,500.
    func movePlaylistItem(
        itemId: String,
        playlistId: String,
        videoId: String,
        to position: Int
    ) async throws -> YTPlaylistItem {
        struct Body: Encodable {
            struct Resource: Encodable { let kind = "youtube#video"; let videoId: String }
            struct Snippet: Encodable {
                let playlistId: String
                let resourceId: Resource
                let position: Int
            }
            let id: String
            let snippet: Snippet
        }
        return try await send(
            "playlistItems",
            method: "PUT",
            query: [.init(name: "part", value: "snippet,contentDetails")],
            body: Body(
                id: itemId,
                snippet: .init(
                    playlistId: playlistId,
                    resourceId: .init(videoId: videoId),
                    position: position
                )
            ),
            cost: .write
        )
    }

    // MARK: - Decoding

    /// YouTube emits RFC-3339, sometimes with fractional seconds.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: raw) ?? plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unrecognised date: \(raw)")
            )
        }
        return d
    }()
}
