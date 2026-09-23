//
//  YouTubeRSSClient.swift
//  SolaPraise
//
//  Channel uploads via YouTube's Atom feed:
//    https://www.youtube.com/feeds/videos.xml?channel_id=UC…
//
//  This costs ZERO API quota — it is not a Data API call at all. It returns
//  each channel's ~15 most recent uploads with id, title, publish time and a
//  thumbnail, which is everything the Word feed needs except duration.
//  Durations come later from one batched videos.list (1 unit per 50 videos).
//
//  No auth required: the feed is public.
//

import Foundation

struct RSSVideo {
    let videoId: String
    let channelId: String?
    let title: String
    let authorName: String?
    let published: Date?
    let thumbnailURL: URL?
}

struct RSSFeed {
    let channelTitle: String?
    let videos: [RSSVideo]
}

enum YouTubeRSSError: LocalizedError {
    case badURL
    case http(Int)
    case transport(Error)
    case parse

    var errorDescription: String? {
        switch self {
        case .badURL:          return "That channel id doesn't form a valid feed URL."
        case .http(let code):  return "The channel feed returned HTTP \(code). The channel may be private or removed."
        case .transport(let e): return "Network problem: \(e.localizedDescription)"
        case .parse:           return "The channel feed couldn't be parsed."
        }
    }
}

struct YouTubeRSSClient {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Retries before giving up.
    ///
    /// This endpoint is genuinely flaky: the same channel feed can return 404
    /// or 500 on one request and 200 with a full 15 entries seconds later —
    /// observed repeatedly against known-good channels while their channel
    /// pages returned 200 throughout. Treating the first non-2xx as fatal made
    /// the 말씀 feed report spurious "couldn't refresh" failures.
    private static let maxAttempts = 3

    func fetch(channelId: String) async throws -> RSSFeed {
        guard let url = YouTubeID.rssFeedURL(channelId: channelId) else {
            throw YouTubeRSSError.badURL
        }

        var lastError: Error = YouTubeRSSError.parse

        for attempt in 1...Self.maxAttempts {
            if attempt > 1 {
                // Linear backoff; the endpoint recovers in seconds, not minutes.
                try? await Task.sleep(for: .seconds(Double(attempt - 1) * 1.5))
            }

            var request = URLRequest(url: url)
            // A default URLSession agent appears to attract rate limiting here.
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )

            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    lastError = YouTubeRSSError.http(http.statusCode)
                    continue
                }
                guard let feed = FeedParser().parse(data), !feed.videos.isEmpty else {
                    lastError = YouTubeRSSError.parse
                    continue
                }
                return feed
            } catch {
                lastError = YouTubeRSSError.transport(error)
            }
        }
        throw lastError
    }
}

// MARK: - Parser

/// XMLParser is a push parser, so this accumulates state across delegate
/// callbacks. Namespace processing stays off, so element names arrive
/// qualified ("yt:videoId", "media:thumbnail") exactly as they appear.
private final class FeedParser: NSObject, XMLParserDelegate {

    private var channelTitle: String?
    private var videos: [RSSVideo] = []

    private var inEntry = false
    private var text = ""

    private var curVideoId: String?
    private var curChannelId: String?
    private var curTitle: String?
    private var curAuthor: String?
    private var curPublished: Date?
    private var curThumb: URL?
    private var inAuthor = false

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func parse(_ data: Data) -> RSSFeed? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return RSSFeed(channelTitle: channelTitle, videos: videos)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "entry":
            inEntry = true
            curVideoId = nil; curChannelId = nil; curTitle = nil
            curAuthor = nil; curPublished = nil; curThumb = nil
        case "author":
            inAuthor = true
        case "media:thumbnail":
            if let urlString = attributeDict["url"] { curThumb = URL(string: urlString) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "title":
            // The feed's own <title> precedes any <entry>; inside an entry it
            // is the video title.
            if inEntry { curTitle = value } else if channelTitle == nil { channelTitle = value }
        case "yt:videoId":
            if inEntry { curVideoId = value }
        case "yt:channelId":
            if inEntry { curChannelId = value } 
        case "name":
            if inEntry && inAuthor { curAuthor = value }
        case "author":
            inAuthor = false
        case "published":
            if inEntry { curPublished = Self.formatter.date(from: value) }
        case "entry":
            if let id = curVideoId, let title = curTitle {
                videos.append(RSSVideo(
                    videoId: id,
                    channelId: curChannelId,
                    title: title,
                    authorName: curAuthor,
                    published: curPublished,
                    thumbnailURL: curThumb
                ))
            }
            inEntry = false
        default:
            break
        }
        text = ""
    }
}
