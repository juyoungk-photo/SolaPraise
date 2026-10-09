//
//  SolaPraiseApp.swift
//  SolaPraise
//
//  App entry: SwiftData container + Google sign-in gate.
//  Structure follows PraiseTheLordApp.swift.
//

import SwiftUI
import SwiftData

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@main
struct SolaPraiseApp: App {

    @StateObject private var auth = GoogleAuthManager()
    @StateObject private var quota = QuotaLedger()
    @StateObject private var daily = DailyReading()
    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.system.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    private let container: ModelContainer = {
        do {
            return try ModelContainer(
                for: Schema(SolaPraiseSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
        } catch {
            // A corrupt store shouldn't brick the app — fall back to memory so
            // the user can still sign in and use the (server-backed) library.
            print("SwiftData container failed, falling back to in-memory: \(error)")
            return try! ModelContainer(
                for: Schema(SolaPraiseSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
    }()

    /// App level on purpose: an analysis must survive the screen that
    /// started it, so you can go and listen to something while it runs.
    @StateObject private var analyzer = AudioFileAnalyzer()

    /// App level so a song survives leaving the screen that started it.
    @StateObject private var playerHost = PlayerHost()
    @StateObject private var team = TeamStore()
    @StateObject private var planning = PlanningAuth()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must happen during launch, before the scene is active.
        BackgroundRefresh.register(container: container)
        #if DEBUG
        if DebugHarness.drainQuota {
            MainActor.assumeIsolated { QuotaLedger().debugDrain() }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(auth)
                .environmentObject(quota)
                .environmentObject(daily)
                .environmentObject(analyzer)
                .environmentObject(playerHost)
                .environmentObject(team)
                .environmentObject(planning)
                .preferredColorScheme(appearance.colorScheme)
                .onOpenURL { url in
                    #if canImport(GoogleSignIn)
                    GIDSignIn.sharedInstance.handle(url)
                    #endif
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                BackgroundRefresh.schedule()
                // Re-arm on the way out so a changed time or a cleared
                // system queue is picked up without needing Settings.
                Task { await ReadingNotifications.schedule() }
            }
        }
    }

    /// Sign-in gate. In DEBUG a launch argument can open the player directly,
    /// which is how the end-screen interception gets verified without an
    /// account or a tap — see DebugHarness.
    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if DebugHarness.apiCheck {
            ApiCheckView()
        } else if DebugHarness.showLeadSheet {
            DebugLeadSheetContainer()
        } else if DebugHarness.showChordSheet {
            NavigationStack { ChordSheetView(session: .debugSample) }
        } else if let path = DebugHarness.scorePath {
            ScoreStandView(items: [ScoreStandItem(
                attachment: Attachment(date: Date(), song: "Debug score",
                                       name: (path as NSString).lastPathComponent,
                                       fileId: path, url: URL(fileURLWithPath: path),
                                       addedBy: ""),
                song: "Debug score",
                teamKey: DebugHarness.scoreTeamKey)])
        } else if let debugId = DebugHarness.videoId {
            WatchScreen()
                .task {
                    playerHost.play(queue: [
                        PlayableVideo(id: debugId, title: "Debug playback")
                    ])
                }
        } else if DebugHarness.bypassAuth {
            DebugSeedContainer()
        } else {
            gatedView
        }
        #else
        gatedView
        #endif
    }

    @ViewBuilder
    private var gatedView: some View {
        if auth.isRestoring {
            LaunchPlaceholder()
        } else if auth.isSignedIn || auth.isBrowsingWithoutAccount {
            ContentView()
        } else {
            SignInView()
        }
    }
}

/// Shown for the moment `restorePreviousSignIn` takes, so the app doesn't
/// flash the sign-in screen at an already-signed-in user.
private struct LaunchPlaceholder: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            ProgressView()
        }
    }
}
