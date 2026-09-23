//
//  DebugHarness.swift
//  SolaPraise
//
//  DEBUG-only launch-argument entry point into WatchScreen, so the end-screen
//  interception can be verified without a signed-in account or a tap:
//
//    xcrun simctl launch <udid> com.juyoungkim.solapraise \
//        -uiTestVideoId dQw4w9WgXcQ -uiTestSeekToEnd YES
//
//  `-uiTestSeekToEnd` jumps to (duration - 3s) once the player reports ready,
//  so the video reaches a real ENDED event a few seconds later and the overlay
//  path is exercised end-to-end rather than simulated.
//

import Foundation

#if DEBUG
enum DebugHarness {
    private static var args: [String] { ProcessInfo.processInfo.arguments }

    /// Video id to open straight into, bypassing the sign-in gate.
    static var videoId: String? {
        guard let i = args.firstIndex(of: "-uiTestVideoId"), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        return value.hasPrefix("-") ? nil : value
    }

    static var seeksToEnd: Bool {
        args.contains("-uiTestSeekToEnd")
    }

    /// Seconds of playback left after the debug seek.
    static let tailSeconds: Double = 3

    /// Skip the Google sign-in gate. The Word feed needs no auth at all —
    /// its data comes from the free Atom feeds — so it can be exercised
    /// without credentials.
    static var bypassAuth: Bool { args.contains("-uiTestBypassAuth") }

    /// Re-arm the once-a-day reading gate so it can be screenshotted:
    /// -uiTestForceGate
    static var forceReadingGate: Bool { args.contains("-uiTestForceGate") }

    /// Show a sample lead sheet with derived sections: -uiTestLeadSheet
    static var showLeadSheet: Bool { args.contains("-uiTestLeadSheet") }

    /// Show a sample chord sheet, so 악보 rendering and PDF export can be
    /// verified without a microphone: -uiTestChordSheet
    static var showChordSheet: Bool { args.contains("-uiTestChordSheet") }

    /// Open the home search sheet on launch: -uiTestShowSearch
    static var showHomeSearch: Bool { args.contains("-uiTestShowSearch") }

    /// Open the psalm grid on launch: -uiTestShowPsalmGrid
    static var showPsalmGrid: Bool { args.contains("-uiTestShowPsalmGrid") }

    /// Mark psalms 1…n as read so the colour coding is visible:
    /// -uiTestSeedRead 37
    static var seedReadThrough: Int? {
        guard let i = args.firstIndex(of: "-uiTestSeedRead"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    /// Mark today's reading gate as already seen: -uiTestSkipGate
    static var skipReadingGate: Bool { args.contains("-uiTestSkipGate") }

    /// Force the reading translation: -uiTestTranslation krv | esv
    static var translation: String? {
        guard let i = args.firstIndex(of: "-uiTestTranslation"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Jump straight to a psalm: -uiTestPsalm 23
    static var psalm: Int? {
        guard let i = args.firstIndex(of: "-uiTestPsalm"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    /// Spend the whole search budget at launch, to verify the refusal path:
    /// -uiTestDrainQuota
    static var drainQuota: Bool { args.contains("-uiTestDrainQuota") }

    /// Seed a saved topic search: -uiTestSeedTopic "찬양 피아노"
    static var seedTopic: String? {
        guard let i = args.firstIndex(of: "-uiTestSeedTopic"), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        return value.hasPrefix("-") ? nil : value
    }

    /// Override the per-channel cap, so the finite-feed end marker can be
    /// screenshotted without scrolling: -uiTestPerChannelCap 1
    static var perChannelCap: Int? {
        guard let i = args.firstIndex(of: "-uiTestPerChannelCap"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    /// Force the initial tab: -uiTestTab word | worship | library
    static var initialTab: String? {
        guard let i = args.firstIndex(of: "-uiTestTab"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Comma-separated UC… channel ids to seed into the Word whitelist:
    ///   -uiTestSeedChannels UC_x5XG1OV2P6uZZ5FSM9Ttw,UCBR8-60-B28hp2BmDPdntcQ
    static var seedChannels: [String] {
        guard let i = args.firstIndex(of: "-uiTestSeedChannels"), i + 1 < args.count else { return [] }
        return args[i + 1]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

import SwiftUI
import SwiftData

/// Wraps ContentView and seeds debug channels before it renders.
struct DebugSeedContainer: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ContentView()
            .task { seed() }
    }

    private func seed() {
        let existing = (try? modelContext.fetch(FetchDescriptor<Channel>())) ?? []
        let known = Set(existing.map(\.youtubeChannelId))

        if let topic = DebugHarness.seedTopic {
            let topics = (try? modelContext.fetch(FetchDescriptor<TopicSearch>())) ?? []
            if !topics.contains(where: { $0.label == topic }) {
                modelContext.insert(TopicSearch(label: topic, query: topic, purpose: .worship))
            }
        }

        for (index, id) in DebugHarness.seedChannels.enumerated() where !known.contains(id) {
            modelContext.insert(Channel(
                youtubeChannelId: id,
                title: "Loading…",          // the Atom feed supplies the real name
                purpose: .word,
                sortOrder: index,
                isPinned: index == 0
            ))
        }
        try? modelContext.save()
    }
}
#endif

/// Builds a SavedSong from the sample session so the lead sheet, section
/// detection and PDF export can be checked without a microphone.
struct DebugLeadSheetContainer: View {
    @Environment(\.modelContext) private var modelContext
    @State private var song: SavedSong?

    var body: some View {
        NavigationStack {
            if let song {
                LeadSheetView(song: song)
            } else {
                ProgressView().task { build() }
            }
        }
    }

    private func build() {
        let session = Session.debugSample
        let made = SavedSong(
            session: session,
            sections: SongStructure.detect(chords: session.chords)
        )
        modelContext.insert(made)
        try? modelContext.save()
        song = made
    }
}
