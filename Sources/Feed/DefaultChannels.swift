//
//  DefaultChannels.swift
//  SolaPraise
//
//  The channels the app starts with.
//
//  Their UC… ids are baked in rather than resolved at runtime, which means
//  adding them costs ZERO quota and works with no Google account at all —
//  the feeds are plain RSS. Resolving a @handle would need channels.list and
//  therefore a signed-in user.
//

import Foundation
import SwiftData

struct SuggestedChannel: Identifiable, Hashable {
    let channelId: String
    let title: String
    let handle: String
    let purpose: Purpose
    let isPinned: Bool

    var id: String { channelId }
}

enum DefaultChannels {

    /// Verified against each channel's own page, which advertises exactly
    /// these ids in its RSS link.
    static let all: [SuggestedChannel] = [
        // ── 말씀 ──────────────────────────────────────────────
        SuggestedChannel(channelId: "UCr1z2X_zyeC8GMbLv4swMVA",
                         title: "⛪ 코너스톤교회", handle: "@c3sfbay",
                         purpose: .word, isPinned: true),
        SuggestedChannel(channelId: "UCroCQn7T3UZsE8N5oyaIP1w",
                         title: "성서유니온 (매일성경)", handle: "@scriptureunionKR",
                         purpose: .word, isPinned: false),
        SuggestedChannel(channelId: "UCISl2wEDnzYeg-k_kElfN4Q",
                         title: "공동체성경읽기", handle: "@PRS",
                         purpose: .word, isPinned: false),
        SuggestedChannel(channelId: "UCKKIJZpEm8lF_RCVXMHVIVA",
                         title: "말씀PT", handle: "@english_bible",
                         purpose: .word, isPinned: false),

        // ── 찬양 ──────────────────────────────────────────────
        SuggestedChannel(channelId: "UCrnxDS-QclED-ej-MFxr8tA",
                         title: "MARKERS WORSHIP", handle: "@MarkersWorship",
                         purpose: .worship, isPinned: true),
        SuggestedChannel(channelId: "UCCJMY5J7tSmopE6kuRNs1Zw",
                         title: "아이자야씩스티원", handle: "@i6tyone",
                         purpose: .worship, isPinned: false),
        SuggestedChannel(channelId: "UCmDCtLeqOzF7_uf_UXoNiYA",
                         title: "F.I.A WORSHIP", handle: "@FIAWORSHIP",
                         purpose: .worship, isPinned: false),
        SuggestedChannel(channelId: "UCqZ6R9Js2HG-6ZNP71soeUg",
                         title: "어노인팅", handle: "@anointingworship",
                         purpose: .worship, isPinned: false),

        // ── 교제 ──────────────────────────────────────────────
        SuggestedChannel(channelId: "UCkgmi4DRdECaM2N_ErJANPw",
                         title: "코너스톤TV", handle: "@c3sfbay-tv",
                         purpose: .fellowship, isPinned: false)
    ]

    /// The channel whose psalm readings pair with the 시편 screen.
    static let psalmAudioChannelId = "UCISl2wEDnzYeg-k_kElfN4Q"   // 공동체성경읽기

    /// Seeds the defaults on first run only. Never re-adds a channel the user
    /// has deleted, because it only fires when the list is completely empty.
    @MainActor
    static func seedIfEmpty(context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Channel>())) ?? []
        guard existing.isEmpty else { return }

        for (index, suggestion) in all.enumerated() {
            context.insert(Channel(
                youtubeChannelId: suggestion.channelId,
                title: suggestion.title,
                handle: suggestion.handle,
                purpose: suggestion.purpose,
                sortOrder: index,
                isPinned: suggestion.isPinned
            ))
        }
        try? context.save()
    }
}
