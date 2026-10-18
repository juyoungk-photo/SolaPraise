//
//  ChartLookup.swift
//  SolaPraise
//
//  The charts already up for a song, wherever it is being played from:
//  attached to it on a 콘티, its pages of a 콘티 file, or kept in 작업실 —
//  from the nearest service that has any.
//
//  WHY: the player's 「이 영상의 악보」 showed only charts the app had made
//  by listening, and a chart the team had uploaded for the very song
//  playing appeared nowhere in the player. The song is found on the
//  services nearest today — upcoming first, then recent — by its video, or
//  by its title when the 콘티 has another upload of it.
//

import Foundation

@MainActor
enum ChartLookup {

    /// Newest first: each chart attached to the song, then its pages of the
    /// newest 콘티 file, then 작업실's. Each opens on the stand in the key
    /// the 순서 gives the song.
    static func charts(videoId: String?, title: String, team: TeamStore,
                       local: LocalScores? = nil) -> [ScoreStandItem] {
        let local = local ?? .shared
        var out: [ScoreStandItem] = []
        var seen = Set<String>()
        func add(_ item: ScoreStandItem) {
            if seen.insert(item.id).inserted { out.append(item) }
        }

        let today = Calendar.current.startOfDay(for: Date())
        let recent = Calendar.current.date(byAdding: .day, value: -60, to: today) ?? today
        let services = team.services.filter { $0.date >= recent }.sorted { a, b in
            // Upcoming first, nearest first; then the past, latest first.
            let aUp = a.date >= today, bUp = b.date >= today
            if aUp != bUp { return aUp }
            return aUp ? a.date < b.date : a.date > b.date
        }
        // The nearest service with charts for the song, and only it: a song
        // sung on four Sundays has its chart attached four times, and the
        // list showed every copy — the same chart, over and over.
        for service in services {
            let songs = team.plan(for: service).filter { $0.kind == .song }
            guard let song = songs.first(where: { videoId != nil && $0.videoId == videoId })
                    ?? songs.first(where: { PlanSongTitle.sameSong($0.title, title) }) else { continue }
            let before = out.count
            for file in team.attachments(for: service, song: song.title).reversed() {
                add(ScoreStandItem(attachment: file, song: song.title, teamKey: song.key))
            }
            if let latest = team.contis(for: service).first {
                let pages = ContiPages.pages(of: latest.fileId, for: song.title)
                if !pages.isEmpty {
                    add(ScoreStandItem(attachment: latest, song: song.title, teamKey: song.key, pages: pages,
                                       versionLabel: "콘티 " + (latest.name as NSString).deletingPathExtension))
                }
            }
            if out.count > before { break }
        }
        for item in local.items where PlanSongTitle.sameSong(item.title, title) {
            add(local.standItem(for: item))
        }
        return out
    }
}
