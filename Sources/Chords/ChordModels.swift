//
//  Models.swift
//  PraiseTheLord
//
//  Core value types used everywhere in the app.
//  Kept intentionally small and testable.
//

import Foundation

// MARK: - Chord quality

/// The "shape" of a chord (major / minor, plus room to grow).
enum ChordQuality: String, Codable, CaseIterable, Identifiable {
    case major        = ""
    case minor        = "m"
    case dominant7    = "7"
    case major7       = "maj7"
    case minor7       = "m7"
    // Added for SolaPraise: contemporary worship leans on these constantly,
    // and PraiseTheLord had no templates for them despite its README.
    case sus2         = "sus2"
    case sus4         = "sus4"
    case add9         = "add9"
    // Tensions. Contemporary worship leans on these constantly, and a chart
    // that flattens them to triads loses most of the harmonic colour.
    case major9       = "maj9"
    case minor9       = "m9"
    case dominant9    = "9"
    case dominant7sus4 = "7sus4"
    case sixth        = "6"
    case minor6       = "m6"
    case diminished   = "dim"
    case augmented    = "aug"

    var id: String { rawValue }
}

// MARK: - Chord

/// A chord expressed as (root pitch-class, quality).
/// root = 0 is C, 1 is C#, ... 11 is B.
struct Chord: Codable, Equatable, Identifiable, Hashable {
    var root: Int          // 0..11
    var quality: ChordQuality
    /// Pitch class of the bass note when it differs from the root — i.e. a
    /// slash chord such as G/B. `nil` means root position. BassDetector could
    /// always compute this; Chord simply had nowhere to put it.
    var bass: Int? = nil

    var id: String { "\(root)-\(quality.rawValue)-\(bass.map(String.init) ?? "r")" }

    // MARK: - Display

    static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flatNames  = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    /// e.g. "G", "Am", "F#m7", "G/B".
    func symbol(useFlats: Bool = false) -> String {
        let names = useFlats ? Chord.flatNames : Chord.sharpNames
        var out = names[root] + quality.rawValue
        if let bass, bass != root {
            out += "/" + names[bass]
        }
        return out
    }

    /// Move this chord up/down N semitones; quality and slash bass preserved.
    func transposed(by semitones: Int) -> Chord {
        let shift = { (pc: Int) in ((pc + semitones) % 12 + 12) % 12 }
        return Chord(root: shift(root), quality: quality, bass: bass.map(shift))
    }
}

// MARK: - DetectedChord (what the engine emits)

struct DetectedChord: Identifiable, Equatable {
    let id = UUID()
    let chord: Chord
    let timestamp: TimeInterval   // seconds since session start
    let confidence: Double        // 0..1 cosine similarity
}

// MARK: - Session

/// A single "analyze a song" session. v1 uses in-memory storage; wire to
/// Core Data later for persistence.
struct Session: Identifiable, Codable {
    let id: UUID
    var title: String
    var youTubeURL: URL?
    var detectedKey: String?       // e.g. "G major"
    var createdAt: Date
    var chords: [SessionChord]     // flattened, persistable form

    init(id: UUID = UUID(),
         title: String = "Untitled",
         youTubeURL: URL? = nil,
         detectedKey: String? = nil,
         createdAt: Date = Date(),
         chords: [SessionChord] = []) {
        self.id = id
        self.title = title
        self.youTubeURL = youTubeURL
        self.detectedKey = detectedKey
        self.createdAt = createdAt
        self.chords = chords
    }
}

/// Persistable row: chord + when it was detected.
struct SessionChord: Codable, Identifiable, Equatable {
    let id: UUID
    let root: Int
    let quality: ChordQuality
    /// Slash-chord bass. Optional so sessions saved before this existed still
    /// decode; without it, a detected G/B flattened back to a plain G on the
    /// round trip into the chord sheet.
    var bass: Int?
    let timestamp: TimeInterval

    init(id: UUID = UUID(), chord: Chord, timestamp: TimeInterval) {
        self.id = id
        self.root = chord.root
        self.quality = chord.quality
        self.bass = chord.bass
        self.timestamp = timestamp
    }

    var asChord: Chord { Chord(root: root, quality: quality, bass: bass) }
}

#if DEBUG
extension Session {
    /// Sample detection output: a common worship progression with a slash
    /// chord and a sus4, exercising the vocabulary added for SolaPraise.
    static var debugSample: Session {
        Session(
            title: "주 은혜임을",
            detectedKey: "G major",
            chords: [
                // 절 1  — G  G/B  C  Dsus4
                SessionChord(chord: Chord(root: 7, quality: .major), timestamp: 0),
                SessionChord(chord: Chord(root: 7, quality: .major, bass: 11), timestamp: 4),
                SessionChord(chord: Chord(root: 0, quality: .major), timestamp: 8),
                SessionChord(chord: Chord(root: 2, quality: .sus4), timestamp: 12),
                // 후렴 — Em7 Cmaj7 G D7
                SessionChord(chord: Chord(root: 4, quality: .minor7), timestamp: 16),
                SessionChord(chord: Chord(root: 0, quality: .major7), timestamp: 20),
                SessionChord(chord: Chord(root: 7, quality: .major), timestamp: 24),
                SessionChord(chord: Chord(root: 2, quality: .dominant7), timestamp: 28),
                // 절 2 — same progression as 절 1
                SessionChord(chord: Chord(root: 7, quality: .major), timestamp: 32),
                SessionChord(chord: Chord(root: 7, quality: .major, bass: 11), timestamp: 36),
                SessionChord(chord: Chord(root: 0, quality: .major), timestamp: 40),
                SessionChord(chord: Chord(root: 2, quality: .sus4), timestamp: 44),
                // 후렴 again
                SessionChord(chord: Chord(root: 4, quality: .minor7), timestamp: 48),
                SessionChord(chord: Chord(root: 0, quality: .major7), timestamp: 52),
                SessionChord(chord: Chord(root: 7, quality: .major), timestamp: 56),
                SessionChord(chord: Chord(root: 2, quality: .dominant7), timestamp: 60),
                // 브릿지 — new material
                SessionChord(chord: Chord(root: 9, quality: .minor), timestamp: 64),
                SessionChord(chord: Chord(root: 4, quality: .sus2), timestamp: 68),
                SessionChord(chord: Chord(root: 0, quality: .major), timestamp: 72),
                SessionChord(chord: Chord(root: 2, quality: .major), timestamp: 76),
            ]
        )
    }
}
#endif
