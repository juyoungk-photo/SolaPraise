//
//  SharedChannelList.swift
//  SolaPraise
//
//  The church's list of unlisted playlists, read from its shared folder so
//  every member's 관심 채널 has them without signing in or pasting links.
//
//  WHY: the church's fellowship channel publishes nothing publicly — every
//  service is 일부 공개. YouTube lists unlisted videos only to an account
//  that manages the channel, so a member's app found an empty page. An
//  unlisted PLAYLIST can be read by anyone who has its id, but each member
//  had to be handed each link. The ids now live in one place the app can
//  read without an account: a Google Doc (or Sheet, or .txt) whose name
//  contains 「관심 채널」, in the church's shared Drive folder — the same
//  folder 콘티 already come from. Whoever looks after the channel pastes a
//  playlist link there once; every member's app picks it up on the next
//  refresh.
//
//  The document is read as plain text and only YouTube playlist links are
//  taken from it, so it can hold notes and headings as people like. Invite
//  links lose their 「jct」 token: only the id is kept.
//

import Foundation

enum SharedChannelList {

    /// A shared folder entry is the list when its name contains this.
    static let marker = "관심 채널"

    /// The playlist ids the list names, in order, each once.
    static func playlistIds(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[?&]list=([A-Za-z0-9_-]{10,})"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let id = String(text[range])
            // Watch Later and Liked are per-account, not anything to share.
            guard id != "WL", !id.hasPrefix("LL"), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// Where the entry's text can be read without an account, by the kind
    /// of file it is. Google's own formats export; anything else downloads.
    static func exportURLs(id: String, link: String?) -> [URL] {
        let doc = "https://docs.google.com/document/d/\(id)/export?format=txt"
        let sheet = "https://docs.google.com/spreadsheets/d/\(id)/export?format=csv"
        let file = "https://drive.google.com/uc?export=download&id=\(id)"
        let order: [String]
        switch link {
        case let link? where link.contains("/document/"): order = [doc]
        case let link? where link.contains("/spreadsheets/"): order = [sheet]
        case let link? where link.contains("/file/"): order = [file]
        default: order = [doc, sheet, file]
        }
        return order.compactMap(URL.init(string:))
    }

    /// The ids the church's list names; nil when there is no list or it
    /// could not be read — never an empty list for a failed read, because
    /// an empty list removes what it used to name.
    static func fetch(folderId: String) async -> [String]? {
        guard let url = URL(string: "https://drive.google.com/embeddedfolderview?id=\(folderId)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        let entries = ContiFolder.entries(inFolderPage: html)
        guard let list = entries.first(where: { $0.name.replacingOccurrences(of: " ", with: "")
            .contains(marker.replacingOccurrences(of: " ", with: "")) }) else { return nil }
        for url in exportURLs(id: list.id, link: list.link) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8),
                  // A sign-in page is a 200 too.
                  !text.lowercased().contains("<html") else { continue }
            return playlistIds(in: text)
        }
        return nil
    }
}
