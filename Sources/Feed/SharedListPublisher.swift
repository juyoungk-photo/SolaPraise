//
//  SharedListPublisher.swift
//  SolaPraise
//
//  Keeps the church's shared 관심 채널 list current from the one app that
//  can see what is on it: the app of whoever manages the channel.
//
//  WHY: the fellowship channel's services are 일부 공개. YouTube lists them
//  to an account that manages the channel and to nobody else, so every
//  member's app depends on someone writing them down — and a list written by
//  hand is a week behind by Sunday. The manager's app already sees the new
//  service the moment it is uploaded; this adds it to the list, and every
//  member's app reads it from there (SharedChannelList).
//
//  WHAT IT WRITES: only rows, only to a Google Sheet in the church's shared
//  folder whose name contains 「관심 채널」, and only links the sheet does
//  not already hold — appended at the bottom, so anything typed there by
//  hand stays as it was. Unlisted only: public videos reach members
//  through the channel feed anyway, and private ones must never be shared.
//  It runs only for a channel its manager has switched it on for.
//
//  The sheet is made once, by hand: the app's Drive access (drive.file)
//  reaches only files it created, never a folder someone else made.
//

import Foundation

@MainActor
enum SharedListPublisher {

    enum Outcome: Equatable {
        case added(Int)
        case upToDate
        case noList
        case listIsNotSheet
        /// This account sees nothing unlisted on the channel.
        case notManager
        case failed(String)

        var message: String {
            switch self {
            case let .added(count): return "공유 목록에 \(count)개를 추가했습니다. 멤버 앱은 다음 새로고침 때 받습니다."
            case .upToDate: return "공유 목록이 최신입니다."
            case .noList:
                return "교회 공유 폴더(콘티 폴더)에 이름에 「관심 채널」이 들어간 Google 시트를 하나 만들어 주세요. 그 뒤로는 앱이 채웁니다."
            case .listIsNotSheet:
                return "공유 폴더의 「관심 채널」이 Google 문서입니다. 앱이 채우려면 Google 시트여야 합니다."
            case .notManager:
                return "이 계정으로는 이 채널의 일부 공개 영상이 보이지 않습니다. 채널을 관리하는 YouTube 계정으로 로그인해야 합니다."
            case let .failed(message): return "공유 목록에 쓰지 못했습니다: \(message)"
            }
        }
    }

    // MARK: - Switched on, per channel (device only)

    static func isOn(for channelId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "sharedList.publish.\(channelId)")
    }

    static func set(_ on: Bool, for channelId: String) {
        UserDefaults.standard.set(on, forKey: "sharedList.publish.\(channelId)")
    }

    static var channelsSwitchedOn: [String] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("sharedList.publish.") && UserDefaults.standard.bool(forKey: $0) }
            .map { String($0.dropFirst("sharedList.publish.".count)) }
    }

    /// At most hourly per channel when run in the background of a launch.
    static func isDue(_ channelId: String, now: Date = Date()) -> Bool {
        let key = "sharedList.lastPublish.\(channelId)"
        guard let last = UserDefaults.standard.object(forKey: key) as? Date else { return true }
        return now.timeIntervalSince(last) > 3600
    }

    // MARK: - Publishing

    static func publish(channelId: String, client: YouTubeAPIClient, sheets: SheetsClient) async -> Outcome {
        UserDefaults.standard.set(Date(), forKey: "sharedList.lastPublish.\(channelId)")
        guard let folderId = ContiFolder.folderId,
              let entry = await SharedChannelList.locate(folderId: folderId) else { return .noList }
        guard SharedChannelList.isSheet(entry) else { return .listIsNotSheet }

        // What this account can see that members cannot.
        var playlists = (try? await client.channelPlaylists(channelId: channelId)) ?? []
        if let mine = try? await client.myChannels(), mine.contains(where: { $0.id == channelId }),
           let own = try? await client.myPlaylists() {
            for playlist in own where !playlists.contains(where: { $0.id == playlist.id }) { playlists.append(playlist) }
        }
        let unlistedPlaylists = playlists.filter { $0.status?.privacyStatus == "unlisted" }
        let uploads = (try? await client.channelUploads(channelId: channelId, limit: 30)) ?? []
        let unlistedVideos = uploads.filter { $0.status?.privacyStatus == "unlisted" }
        guard !unlistedPlaylists.isEmpty || !unlistedVideos.isEmpty else { return .notManager }

        do {
            guard let tab = try await sheets.tabTitles(sheetId: entry.id).first else { return .failed("시트에 탭이 없습니다.") }
            let rows = try await sheets.read(sheetId: entry.id, range: tab)
            let present = SharedChannelList.listing(in: rows.flatMap { $0 }.joined(separator: "\n"))

            var additions: [[String]] = []
            for playlist in unlistedPlaylists.sorted(by: { ($0.snippet?.publishedAt ?? .distantPast) < ($1.snippet?.publishedAt ?? .distantPast) })
            where !present.playlists.contains(playlist.id) {
                additions.append(["재생목록", playlist.title, "https://www.youtube.com/playlist?list=\(playlist.id)",
                                  day(playlist.snippet?.publishedAt)])
            }
            for item in unlistedVideos.sorted(by: { (published($0) ?? .distantPast) < (published($1) ?? .distantPast) }) {
                guard let id = item.videoId, !present.videos.contains(id) else { continue }
                additions.append(["영상", item.title, "https://www.youtube.com/watch?v=\(id)", day(published(item))])
            }
            guard !additions.isEmpty else { return .upToDate }
            if rows.isEmpty {
                try await sheets.append(sheetId: entry.id, tab: tab, row: ["종류", "제목", "링크", "날짜"])
            }
            for row in additions { try await sheets.append(sheetId: entry.id, tab: tab, row: row) }
            return .added(additions.count)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private static func published(_ item: YTPlaylistItem) -> Date? { item.contentDetails?.videoPublishedAt }

    private static func day(_ date: Date?) -> String {
        guard let date else { return "" }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }
}
