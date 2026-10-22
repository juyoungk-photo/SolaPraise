//
//  MorningWorshipPick.swift
//  SolaPraise
//
//  What the morning alarm plays for 모닝워십, given what the channel has now.
//
//  WHY A RULE OF ITS OWN: the alarm goes off a few minutes before the
//  service, so at the moment it fires there is usually nothing live yet —
//  the stream is scheduled, or not even that. Playing "the newest video"
//  then means yesterday's service at full volume, which is not what anyone
//  set an alarm for. So: the live stream if there is one; otherwise wait for
//  it, checking again; and only once waiting has gone on longer than a
//  service ever starts late, the most recent 모닝워십 — said as such.
//
//  Pure, so Tools/check-morning-alarm.swift runs it without the app.
//

import Foundation

enum MorningWorshipPick {

    struct Candidate: Equatable {
        let id: String
        let title: String
        /// YouTube's liveBroadcastContent: "live", "upcoming" or "none".
        let broadcast: String
        let publishedAt: Date?
    }

    enum Decision: Equatable {
        /// On air: play it.
        case live(String)
        /// Nothing on air yet: look again shortly.
        case wait
        /// Waited long enough: play the most recent service.
        case recent(String)
        /// Nothing to play at all.
        case nothing
    }

    /// How long to keep looking for the stream before settling for the
    /// latest recording. Services start on the minute; twenty covers an
    /// alarm set a little early and a stream that starts a little late.
    static let longestWait: TimeInterval = 20 * 60

    /// Waiting is for the morning: before this hour the stream may not
    /// even be scheduled yet.
    static let morningEnds = 12

    static func decide(_ candidates: [Candidate], waitingSince: Date, now: Date = Date(),
                       calendar: Calendar = .current) -> Decision {
        if let live = candidates.first(where: { $0.broadcast == "live" }) { return .live(live.id) }
        // Wait only when there is a service to wait for: one scheduled, or
        // a morning whose service is not up yet. Otherwise — an alarm tried
        // in the evening, a Saturday, a service already over — waiting
        // twenty minutes for a stream that is not coming looked like an
        // alarm that did nothing.
        let scheduled = candidates.contains { $0.broadcast == "upcoming" }
        let todayIsUp = candidates.contains { video in
            video.broadcast == "none" && DailySeries.key(of: video.title) == "모닝워십"
                && EpisodeDate.inTitle(video.title, now: now).map { calendar.isDate($0, inSameDayAs: now) } == true
        }
        let isMorning = calendar.component(.hour, from: now) < morningEnds
        let worthWaiting = scheduled || (isMorning && !todayIsUp)
        if worthWaiting, now.timeIntervalSince(waitingSince) < longestWait { return .wait }
        return recent(in: candidates, now: now).map(Decision.recent) ?? .nothing
    }

    /// The latest finished 모닝워십, by the day in its title; failing that,
    /// the latest finished video. Never one that has not happened yet.
    static func recent(in candidates: [Candidate], now: Date = Date()) -> String? {
        let finished = candidates.filter { $0.broadcast == "none" }
        let services = finished.compactMap { video -> (Candidate, Date)? in
            guard DailySeries.key(of: video.title) == "모닝워십",
                  let day = EpisodeDate.inTitle(video.title, now: now) else { return nil }
            return (video, day)
        }
        if let newest = services.max(by: { $0.1 < $1.1 }) { return newest.0.id }
        return finished.max(by: { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) })?.id
    }
}
