//
//  HomeCardModels.swift
//  SolaPraise
//
//  The home screen is a user-owned list of cards, not a fixed layout.
//  Each card points at one concrete thing — today's psalm, a specific
//  channel's newest upload, a specific playlist, or search — so the first
//  screen stays exactly as short as the user wants it.
//

import Foundation
import SwiftData

enum HomeCardKind: String, Codable, CaseIterable, Identifiable {
    case reading      // 시편 — today's psalm
    case channel      // newest upload from one whitelisted channel
    case playlist     // one YouTube playlist, tap to play
    case search       // jump to search
    case psalmAudio   // 공동체성경읽기's reading of today's psalm, for the car
    // ── User-made cards ──────────────────────────────────────
    case video        // one pasted YouTube link, tap to play
    case topic        // a saved search term, tap to run it

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .reading:  return "text.book.closed"
        case .channel:  return "play.rectangle"
        case .playlist: return "music.note.list"
        case .search:     return "magnifyingglass"
        case .psalmAudio: return "headphones"
        case .video:      return "play.circle"
        case .topic:      return "text.magnifyingglass"
        }
    }

    /// Reading gets the hero slot; the rest sit two-up.
    var isWide: Bool {
        switch self {
        case .reading, .search: return true
        case .channel, .playlist, .psalmAudio, .video, .topic: return false
        }
    }
}

@Model
final class HomeCard {
    var kindRaw: String
    /// Channel id (UC…), playlist id, video id, or a search term.
    /// Nil for reading and search.
    var targetId: String?
    /// Display name captured at add time, so a playlist card can render
    /// before (or without) a network round trip.
    var title: String
    var sortOrder: Int
    var addedAt: Date

    init(kind: HomeCardKind, targetId: String? = nil, title: String, sortOrder: Int = 0) {
        self.kindRaw = kind.rawValue
        self.targetId = targetId
        self.title = title
        self.sortOrder = sortOrder
        self.addedAt = Date()
    }

    var kind: HomeCardKind {
        get { HomeCardKind(rawValue: kindRaw) ?? .channel }
        set { kindRaw = newValue.rawValue }
    }

    /// Identity for dedupe: one card per target, plus one each of the
    /// singleton kinds.
    var dedupeKey: String { "\(kindRaw)-\(targetId ?? "-")" }
}
