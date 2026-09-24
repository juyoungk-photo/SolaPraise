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

    /// Run a read-only API self-check and print the result:
    /// -uiTestApiCheck
    static var apiCheck: Bool { args.contains("-uiTestApiCheck") }

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

/// Read-only verification that the signed-in API path actually works.
///
/// Exercises exactly the calls the Library depends on and reports the quota
/// consumed, so a wrong call (a 100-unit search where a 1-unit read belongs)
/// shows up immediately. Makes no writes — nothing in the account changes.
struct ApiCheckView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger
    @State private var lines: [String] = ["실행 중…"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .task { await run() }
    }

    private func run() async {
        var out: [String] = []
        func log(_ s: String) { out.append(s); lines = out; print("[SolaPraise] CHECK \(s)") }

        // restorePreviousSignIn is async; checking immediately reports a
        // false negative.
        var waited = 0
        while auth.isRestoring && waited < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        log("restored after \(waited * 100)ms")
        log("signedIn=\(auth.isSignedIn) email=\(auth.email ?? "-")")
        guard auth.isSignedIn else { log("로그인 필요 — 중단"); return }

        let before = quota.unitsUsed
        log("quota before: \(before)")

        let client = AppServices.client(auth: auth, quota: quota)

        do {
            let playlists = try await client.myPlaylists()
            log("playlists.list → \(playlists.count)개  (+\(quota.unitsUsed - before) units)")
            for p in playlists.prefix(6) {
                log("   • \(p.title) — \(p.itemCount)곡 [\(p.privacy.label)]")
            }

            if let first = playlists.first {
                let mark = quota.unitsUsed
                let items = try await client.playlistItems(playlistId: first.id)
                log("playlistItems.list → \(items.count)곡  (+\(quota.unitsUsed - mark) units)")
                if let song = items.first { log("   첫 곡: \(song.title.prefix(40))") }
            }
        } catch {
            log("실패: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }

        // Why does the 시편 듣기 card say "아직 없음"? Either the channel's
        // psalm readings were never cached, or they exist under a title the
        // matcher does not recognise. Report enough to tell them apart.
        let psalmId = DefaultChannels.psalmAudioChannelId
        let all = (try? context.fetch(FetchDescriptor<CachedVideo>())) ?? []
        let fromChannel = all.filter { $0.channelId == psalmId }
        log("공동체성경읽기 캐시: \(fromChannel.count)개 (전체 \(all.count))")

        let psalmTitled = fromChannel.filter { $0.title.contains("시편") }
        log("제목에 '시편' 포함: \(psalmTitled.count)개")
        for v in psalmTitled.prefix(8) { log("   · \(v.title.prefix(42))") }

        // The psalm readings are older than any sane upload walk, so the
        // channel's own playlists are the right index into them.
        let pls = (try? context.fetch(FetchDescriptor<CachedPlaylist>())) ?? []
        let channelPls = pls.filter { $0.channelId == psalmId }
        log("공동체성경읽기 재생목록: \(channelPls.count)개")
        for pl in channelPls.prefix(25) {
            log("   ▸ \(pl.title.prefix(40)) (\(pl.itemCount))")
        }

        for n in [72, 73, 74] {
            let pattern = "시편\\s*\(n)\\s*[편장]"
            let hit = fromChannel.first { $0.title.range(of: pattern, options: .regularExpression) != nil }
            log("   시편 \(n)편 → \(hit.map { String($0.title.prefix(34)) } ?? "없음")")
        }

        log("quota after: \(quota.unitsUsed)  (총 +\(quota.unitsUsed - before))")
        log("검색 남음: \(quota.searchesRemaining)/\(QuotaLedger.dailySearchLimit)")
    }
}
