//
//  YouTubeID.swift
//  SolaPraise
//
//  Video-ID parsing ported verbatim from
//  PraiseTheLord/Sources/YouTubePlayerView.swift, extended with channel-URL
//  parsing so Settings can accept a pasted channel link or @handle.
//

import Foundation

enum YouTubeID {

    // MARK: - Video IDs

    /// Extracts the 11-char video ID from a variety of YouTube URL formats:
    ///   https://www.youtube.com/watch?v=XXXX
    ///   https://youtu.be/XXXX
    ///   https://www.youtube.com/embed/XXXX
    ///   https://www.youtube.com/shorts/XXXX
    ///   https://m.youtube.com/watch?v=XXXX
    /// A bare 11-character ID is also accepted and returned as-is.
    static func parse(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Already a bare ID?
        if isBareVideoID(trimmed) { return trimmed }

        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased() else { return nil }

        if host.contains("youtu.be") {
            return url.pathComponents.dropFirst().first
        }
        if host.contains("youtube.com") {
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
                return v
            }
            // /embed/XXX, /shorts/XXX, /live/XXX
            let segs = url.pathComponents
            if let idx = segs.firstIndex(where: { $0 == "embed" || $0 == "shorts" || $0 == "live" }),
               idx + 1 < segs.count {
                return segs[idx + 1]
            }
        }
        return nil
    }

    private static func isBareVideoID(_ s: String) -> Bool {
        s.count == 11 && s.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    // MARK: - Playlist IDs

    /// Extracts a playlist ID from a `?list=` URL, or accepts a bare ID.
    static func parsePlaylist(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("PL") || trimmed.hasPrefix("UU") || trimmed.hasPrefix("LL") {
            if !trimmed.contains("/") { return trimmed }
        }
        guard let url = URL(string: trimmed),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "list" })?.value
    }

    /// True when a pasted playlist link is a collaboration invite.
    ///
    /// YouTube marks those with a `jct` token. The token is the invite — it
    /// is what lets the person opening it join as a collaborator — so a link
    /// carrying one is worth keeping whole rather than reducing to an id.
    static func isCollaborationInvite(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        return comps.queryItems?.contains { $0.name == "jct" } ?? false
    }

    // MARK: - Channel references

    /// What a pasted channel string resolved to. A `.handle` still needs one
    /// `channels.list?forHandle=` call (1 unit) to become a UC… id; a
    /// `.channelId` is usable immediately and costs nothing.
    enum ChannelRef: Equatable {
        case channelId(String)   // UC…
        case handle(String)      // without the leading "@"
        case username(String)    // legacy /user/NAME
    }

    /// Parses a channel URL or handle:
    ///   https://www.youtube.com/channel/UCxxxx  → .channelId
    ///   https://www.youtube.com/@handle         → .handle
    ///   https://www.youtube.com/c/CustomName    → .handle (best effort)
    ///   https://www.youtube.com/user/LegacyName → .username
    ///   @handle  /  UCxxxx                      → bare forms
    static func parseChannel(_ raw: String) -> ChannelRef? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Bare forms first.
        if trimmed.hasPrefix("@") {
            return .handle(String(trimmed.dropFirst()))
        }
        if trimmed.hasPrefix("UC"), trimmed.count == 24, !trimmed.contains("/") {
            return .channelId(trimmed)
        }

        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host.contains("youtube.com") else { return nil }

        let segs = url.pathComponents.filter { $0 != "/" }
        guard let first = segs.first else { return nil }

        if first == "channel", segs.count > 1 {
            return .channelId(segs[1])
        }
        if first.hasPrefix("@") {
            return .handle(String(first.dropFirst()))
        }
        if first == "c", segs.count > 1 {
            return .handle(segs[1])
        }
        if first == "user", segs.count > 1 {
            return .username(segs[1])
        }
        return nil
    }

    // MARK: - Convenience URLs

    static func watchURL(_ videoId: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoId)")
    }

    static func playlistURL(_ playlistId: String) -> URL? {
        URL(string: "https://www.youtube.com/playlist?list=\(playlistId)")
    }

    /// Zero-quota uploads feed for a channel.
    static func rssFeedURL(channelId: String) -> URL? {
        URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)")
    }
}
