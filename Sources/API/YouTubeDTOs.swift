//
//  YouTubeDTOs.swift
//  SolaPraise
//
//  Codable mirrors of the YouTube Data API v3 JSON we actually consume.
//  Deliberately partial — only the fields the app renders are decoded.
//

import Foundation

// MARK: - Envelope

struct YTListResponse<Item: Decodable>: Decodable {
    let items: [Item]?
    let nextPageToken: String?
    let pageInfo: PageInfo?

    struct PageInfo: Decodable {
        let totalResults: Int?
        let resultsPerPage: Int?
    }
}

// MARK: - Thumbnails

struct YTThumbnails: Decodable, Hashable {
    let `default`: YTThumbnail?
    let medium: YTThumbnail?
    let high: YTThumbnail?
    let standard: YTThumbnail?
    let maxres: YTThumbnail?

    /// Best available, preferring a mid-size image so grids stay light.
    var best: URL? {
        (medium ?? high ?? standard ?? maxres ?? `default`)?.url
    }
}

struct YTThumbnail: Decodable, Hashable {
    let url: URL?
    let width: Int?
    let height: Int?
}

// MARK: - Playlist

struct YTPlaylist: Decodable, Identifiable, Hashable {
    let id: String
    let snippet: Snippet?
    let contentDetails: ContentDetails?
    let status: Status?

    struct Snippet: Decodable, Hashable {
        let title: String?
        let description: String?
        let publishedAt: Date?
        let thumbnails: YTThumbnails?
    }
    struct ContentDetails: Decodable, Hashable { let itemCount: Int? }
    struct Status: Decodable, Hashable { let privacyStatus: String? }

    var title: String { snippet?.title ?? "Untitled playlist" }
    var itemCount: Int { contentDetails?.itemCount ?? 0 }
    var thumbnailURL: URL? { snippet?.thumbnails?.best }
    var privacy: Privacy { Privacy(raw: status?.privacyStatus) }

    static func == (l: YTPlaylist, r: YTPlaylist) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    enum Privacy: String {
        case `public`, unlisted, `private`, unknown

        init(raw: String?) {
            self = Privacy(rawValue: raw ?? "") ?? .unknown
        }
        var symbolName: String {
            switch self {
            case .public:   return "globe"
            case .unlisted: return "link"
            case .private:  return "lock"
            case .unknown:  return "questionmark.circle"
            }
        }
        var label: String {
            switch self {
            case .public:   return "Public"
            case .unlisted: return "Unlisted"
            case .private:  return "Private"
            case .unknown:  return "Unknown"
            }
        }
    }
}

// MARK: - Playlist item

struct YTPlaylistItem: Decodable, Identifiable, Hashable {
    /// The *playlist item* id — this is what update/delete address, not the video id.
    let id: String
    let snippet: Snippet?
    let contentDetails: ContentDetails?

    struct Snippet: Decodable, Hashable {
        let title: String?
        let description: String?
        let position: Int?
        let playlistId: String?
        let videoOwnerChannelTitle: String?
        let videoOwnerChannelId: String?
        let thumbnails: YTThumbnails?
        let resourceId: ResourceId?

        struct ResourceId: Decodable, Hashable { let videoId: String? }
    }
    struct ContentDetails: Decodable, Hashable {
        let videoId: String?
        let videoPublishedAt: Date?
    }

    var videoId: String? { contentDetails?.videoId ?? snippet?.resourceId?.videoId }
    var title: String { snippet?.title ?? "Untitled" }
    var channelTitle: String? { snippet?.videoOwnerChannelTitle }
    var channelId: String? { snippet?.videoOwnerChannelId }
    var descriptionText: String? { snippet?.description }
    var position: Int { snippet?.position ?? 0 }
    var thumbnailURL: URL? { snippet?.thumbnails?.best }

    /// Deleted or private videos still occupy a slot but render as placeholders.
    var isUnavailable: Bool {
        let t = title.lowercased()
        return t == "deleted video" || t == "private video"
    }

    static func == (l: YTPlaylistItem, r: YTPlaylistItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Video (for durations)

struct YTVideo: Decodable, Identifiable {
    let id: String
    let snippet: Snippet?
    let contentDetails: ContentDetails?
    let status: Status?
    let statistics: Statistics?

    struct Statistics: Decodable { let viewCount: String? }

    /// `embeddable` is the rights holder's switch. A great many worship and
    /// CCM uploads have it off, and when it is off the IFrame player cannot
    /// play the video at all — it returns error 101/150/152. Knowing this in
    /// advance is the difference between a dead end and an honest hand-off.
    struct Status: Decodable { let embeddable: Bool?; let privacyStatus: String? }

    struct Snippet: Decodable {
        let title: String?
        /// Worship channels publish their set list, timestamps and keys here.
        let description: String?
        let channelId: String?
        let channelTitle: String?
        let publishedAt: Date?
        let thumbnails: YTThumbnails?
        /// "live", "upcoming" or "none". Already in the snippet the batched
        /// videos.list fetches, so knowing it costs nothing extra.
        let liveBroadcastContent: String?
    }
    struct ContentDetails: Decodable { let duration: String? }

    /// Broadcasting right now.
    var isLiveNow: Bool { snippet?.liveBroadcastContent == "live" }

    var durationSeconds: Int? {
        contentDetails?.duration.flatMap(ISO8601Duration.seconds(from:))
    }

    /// Defaults to true when absent, so a missing field never hides a video
    /// that would actually have played.
    var isEmbeddable: Bool { status?.embeddable ?? true }
    var viewCount: Int? { statistics?.viewCount.flatMap(Int.init) }
}

// MARK: - Channel

struct YTChannel: Decodable, Identifiable {
    let id: String
    let snippet: Snippet?
    let contentDetails: ContentDetails?

    struct Snippet: Decodable {
        let title: String?
        let description: String?
        let customUrl: String?
        let thumbnails: YTThumbnails?
    }
    struct ContentDetails: Decodable {
        let relatedPlaylists: RelatedPlaylists?
        struct RelatedPlaylists: Decodable { let uploads: String? }
    }

    var title: String { snippet?.title ?? "Unknown channel" }
    var thumbnailURL: URL? { snippet?.thumbnails?.best }
    var handle: String? { snippet?.customUrl }
}

// MARK: - Search result

struct YTSearchResult: Decodable, Identifiable {
    let id: ResultID
    let snippet: Snippet?

    struct ResultID: Decodable, Hashable { let kind: String?; let videoId: String? }
    struct Snippet: Decodable {
        let title: String?
        let channelTitle: String?
        let channelId: String?
        let publishedAt: Date?
        let thumbnails: YTThumbnails?
    }

    var videoId: String? { id.videoId }
    var title: String { snippet?.title ?? "Untitled" }
}

// MARK: - API error envelope

struct YTErrorResponse: Decodable {
    let error: APIError?

    struct APIError: Decodable {
        let code: Int?
        let message: String?
        let errors: [Detail]?
        struct Detail: Decodable {
            let reason: String?
            let message: String?
            let domain: String?
        }
    }

    /// First machine-readable reason, e.g. "quotaExceeded".
    var firstReason: String? { error?.errors?.first?.reason }
}

// MARK: - ISO-8601 duration

enum ISO8601Duration {
    /// Parses YouTube's `PT4M13S` / `P1DT2H3M4S` duration form into seconds.
    /// Returns nil for the live-stream sentinel `P0D` and anything unparseable.
    static func seconds(from iso: String) -> Int? {
        guard iso.hasPrefix("P") else { return nil }
        var days = 0, hours = 0, minutes = 0, secs = 0
        var number = ""
        var inTime = false

        for ch in iso.dropFirst() {
            switch ch {
            case "T":
                inTime = true
                number = ""
            case "0"..."9":
                number.append(ch)
            case "D":
                days = Int(number) ?? 0; number = ""
            case "H":
                hours = Int(number) ?? 0; number = ""
            case "M":
                if inTime { minutes = Int(number) ?? 0 }   // months outside T — ignored
                number = ""
            case "S":
                secs = Int(number) ?? 0; number = ""
            default:
                number = ""
            }
        }
        let total = days * 86_400 + hours * 3_600 + minutes * 60 + secs
        return total > 0 ? total : nil
    }

    /// "3:42" or "1:02:11"
    static func format(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
