//
//  SavedSong.swift
//  SolaPraise
//
//  A detected song kept for later: its chords, its derived structure, and any
//  lyrics typed in. Persisted so lyrics are entered once rather than every
//  time the song comes round in a set.
//

import Foundation
import SwiftData

@Model
final class SavedSong {
    var title: String
    var videoId: String?
    var detectedKey: String?
    var createdAt: Date
    var ccliNumber: String?
    var semitoneShift: Int

    /// Chords and sections are stored as JSON rather than as relationships —
    /// they are always read and written as a whole, and keeping them opaque
    /// avoids a SwiftData migration every time the chord vocabulary grows.
    var chordsData: Data
    var sectionsData: Data

    init(session: Session, sections: [SongSection], videoId: String? = nil) {
        self.title = session.title
        self.videoId = videoId
        self.detectedKey = session.detectedKey
        self.createdAt = session.createdAt
        self.semitoneShift = 0
        self.chordsData = (try? JSONEncoder().encode(session.chords)) ?? Data()
        self.sectionsData = (try? JSONEncoder().encode(sections)) ?? Data()
    }

    var chords: [SessionChord] {
        get { (try? JSONDecoder().decode([SessionChord].self, from: chordsData)) ?? [] }
        set { chordsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var sections: [SongSection] {
        get { (try? JSONDecoder().decode([SongSection].self, from: sectionsData)) ?? [] }
        set { sectionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var asSession: Session {
        Session(
            title: title,
            youTubeURL: videoId.flatMap(YouTubeID.watchURL),
            detectedKey: detectedKey,
            createdAt: createdAt,
            chords: chords
        )
    }

    var hasLyrics: Bool { sections.contains { !$0.lyrics.isEmpty } }
}
