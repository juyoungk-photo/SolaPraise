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
//  WHAT IT WRITES: one SEALED cell (SharedListCipher), in a Google Sheet in
//  the church's shared folder whose name contains 「관심 채널」. The folder
//  is shared by link, so the links are never written in the clear: the
//  cell is opened with the church's password, which members enter once.
//  New links are added to what the cell already holds; rows typed by hand
//  stay as they were — and are reported, since those are readable by
//  anyone with the folder link. Unlisted only: public videos reach members
//  through the channel feed anyway, and private ones must never be shared.
//  It runs only for a channel its manager has switched it on for, and only
//  with the password set on this device.
//
//  The sheet is made once, by hand: the app's Drive access (drive.file)
//  reaches only files it created, never a folder someone else made.
//

import Foundation

@MainActor
enum SharedListPublisher {

    enum Outcome: Equatable {
        /// `plainLinks`: links written in the clear elsewhere in the sheet.
        case added(Int, plainLinks: Int)
        case upToDate(plainLinks: Int)
        /// No church password on this device: nothing is written unsealed.
        case needsPassword
        /// The sheet's sealed cell does not open with this device's password.
        case wrongPassword
        case noList
        case listIsNotSheet
        /// This account sees nothing unlisted on the channel.
        case notManager
        case failed(String)

        var message: String {
            switch self {
            case let .added(count, plain):
                return "암호화한 공유 목록에 \(count)개를 추가했습니다. 멤버 앱은 다음 새로고침 때 받습니다." + plainNote(plain)
            case let .upToDate(plain): return "공유 목록이 최신입니다." + plainNote(plain)
            case .needsPassword:
                return "교회 암호를 먼저 정하세요. 목록은 그 암호로 암호화해서만 올라가고, 멤버는 같은 암호로 엽니다."
            case .wrongPassword:
                return "시트의 암호화된 목록이 이 암호로 열리지 않습니다. 처음 정한 교회 암호를 입력하세요."
            case .noList:
                return "교회 공유 폴더(콘티 폴더)에 이름에 「관심 채널」이 들어간 Google 시트를 하나 만들어 주세요. 그 뒤로는 앱이 채웁니다."
            case .listIsNotSheet:
                return "공유 폴더의 「관심 채널」이 Google 문서입니다. 앱이 채우려면 Google 시트여야 합니다."
            case .notManager:
                return "이 계정으로는 이 채널의 일부 공개 영상이 보이지 않습니다. 채널을 관리하는 YouTube 계정으로 로그인해야 합니다."
            case let .failed(message): return "공유 목록에 쓰지 못했습니다: \(message)"
            }
        }

        private func plainNote(_ count: Int) -> String {
            count == 0 ? "" : " 시트에 암호화되지 않은 링크가 \(count)개 있습니다 — 폴더 링크만 있으면 누구나 볼 수 있으니 지우세요."
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

    static func publish(channelId: String, client: YouTubeAPIClient, sheets: SheetsClient,
                        password: String?) async -> Outcome {
        guard let password, !password.isEmpty else { return .needsPassword }
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

            // The sealed cell, wherever it is, and what it holds.
            var sealedAt: (row: Int, column: Int)?
            for (r, row) in rows.enumerated() {
                if let c = row.firstIndex(where: { $0.hasPrefix(SharedListCipher.prefix) }) { sealedAt = (r, c); break }
            }
            var plain = ""
            if let at = sealedAt {
                guard let opened = SharedListCipher.open(rows[at.row][at.column], password: password) else { return .wrongPassword }
                plain = opened
            }
            let present = SharedChannelList.listing(in: plain)
            let plainLinks = SharedChannelList.listing(in: SharedListCipher.split(rows.flatMap { $0 }.joined(separator: "\n")).rest)
            let plainCount = plainLinks.playlists.count + plainLinks.videos.count

            var additions: [String] = []
            for playlist in unlistedPlaylists.sorted(by: { ($0.snippet?.publishedAt ?? .distantPast) < ($1.snippet?.publishedAt ?? .distantPast) })
            where !present.playlists.contains(playlist.id) {
                additions.append(line("재생목록", playlist.title, "https://www.youtube.com/playlist?list=\(playlist.id)",
                                      day(playlist.snippet?.publishedAt)))
            }
            for item in unlistedVideos.sorted(by: { (published($0) ?? .distantPast) < (published($1) ?? .distantPast) }) {
                guard let id = item.videoId, !present.videos.contains(id) else { continue }
                additions.append(line("영상", item.title, "https://www.youtube.com/watch?v=\(id)", day(published(item))))
            }
            guard !additions.isEmpty else { return .upToDate(plainLinks: plainCount) }

            // A cell holds 50,000 characters; sealed text grows by a third.
            // The newest lines are kept.
            var lines = plain.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) + additions
            if lines.count > 400 { lines = Array(lines.suffix(400)) }
            guard let sealed = SharedListCipher.seal(lines.joined(separator: "\n"), password: password) else {
                return .failed("암호화하지 못했습니다.")
            }
            if let at = sealedAt {
                try await sheets.write(sheetId: entry.id,
                                       range: "\(tab)!\(TeamSheet.columnLetter(at.column))\(at.row + 1)", row: [sealed])
            } else {
                let target = rows.count + 1
                try await sheets.write(sheetId: entry.id, range: "\(tab)!A\(target):B\(target)",
                                       row: [sealed, "SolaPraise 관심 채널 — 암호화된 목록입니다. 앱에서 교회 암호로 엽니다."])
            }
            return .added(additions.count, plainLinks: plainCount)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// One entry of the sealed list: tab-separated, the link standing alone.
    private static func line(_ kind: String, _ title: String, _ link: String, _ day: String) -> String {
        let clean = title.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        return [kind, clean, link, day].joined(separator: "\t")
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
