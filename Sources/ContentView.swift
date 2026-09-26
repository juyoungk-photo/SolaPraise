//
//  ContentView.swift
//  SolaPraise
//
//  Four tabs: 홈 · 찬양 · 말씀 · 보관함.
//
//  Home is the curated first screen and the default — everything on it was
//  put there deliberately by the user. There is no algorithmic feed anywhere
//  in the app. 시편 has no tab of its own because a home card covers it.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var daily: DailyReading
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var playerHost: PlayerHost
    @EnvironmentObject private var team: TeamStore

    /// Recomputed as the roster loads and as sign-in changes, so the tab
    /// appears without a relaunch.
    private var teamAccess: TeamAccess.State {
        TeamAccess.evaluate(
            sheetId: ReadingSettings.teamSheetId,
            email: auth.email,
            displayName: auth.displayName,
            roster: team.memberEmails
        )
    }
    @Environment(\.modelContext) private var modelContext
    @State private var selection: Tab = Tab.defaultForNow()
    @State private var showDailyGate = false

    /// iPad gets 작업실 as its own tab — there is room, it is where an
    /// interface gets plugged in, and it is where a musician would actually
    /// read a chart. iPhone keeps it inside 보관함 rather than pushing the tab
    /// bar to five items.
    private var showsStudioTab: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    enum Tab: Hashable {
        case home, worship, word, library, studio, team

        static func defaultForNow(_ date: Date = Date()) -> Tab {
            #if DEBUG
            switch DebugHarness.initialTab {
            case "home":    return .home
            case "word":    return .word
            case "worship": return .worship
            case "library": return .library
            default: break
            }
            #endif
            return .home
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeView(selection: $selection)
                .tabItem { Label("홈", systemImage: "square.grid.2x2") }
                .tag(Tab.home)

            WorshipFeedView()
                .tabItem { Label("찬양", systemImage: "music.note") }
                .tag(Tab.worship)

            WordFeedView()
                .tabItem { Label("말씀", systemImage: "book.closed") }
                .tag(Tab.word)

            PlaylistLibraryView()
                .tabItem { Label("보관함", systemImage: "list.bullet.rectangle") }
                .tag(Tab.library)

            // Members only, and only once a sheet is configured. Appears
            // when the signed-in address is on the Members tab.
            if teamAccess.isMember {
                ServicePrepView()
                    .tabItem { Label("예배", systemImage: "calendar.badge.clock") }
                    .tag(Tab.team)
            }

            if showsStudioTab {
                StudioView()
                    .tabItem { Label("작업실", systemImage: "recordingtape") }
                    .tag(Tab.studio)
            }
        }
        // The player lives here, above the tabs and in one place in the view
        // tree, so a song keeps playing while you move between them and the
        // web view is never re-parented.
        // Reserve the docked player's height inside every tab, so the feed
        // scrolls clear of it instead of ending underneath it. The overlay
        // below still does the drawing; this only buys the space.
        .safeAreaInset(edge: .bottom) {
            if playerHost.mode == .mini {
                Color.clear
                    .frame(height: PlayerStage.miniBarHeight)
                    .allowsHitTesting(false)
            }
        }
        .overlay { PlayerStage(host: playerHost) }
        // The roster has to be read before the tab can be decided, and the
        // sheet is the only place it lives.
        .task {
            team.configure(auth: auth)
            if let sheetId = ReadingSettings.teamSheetId, team.services.isEmpty {
                await team.load(sheetId: sheetId)
            }
        }
        // The once-a-day gate: today's psalm comes up before anything else,
        // and only once — dismissing it leaves the normal tabs alone.
        .fullScreenCover(isPresented: $showDailyGate) {
            ReadingView {
                daily.markGateShown()
                showDailyGate = false
            }
        }
        .task {
            DefaultChannels.seedIfEmpty(context: modelContext)
            daily.advanceIfNewDay()
            if daily.isGateOwed { showDailyGate = true }
        }
    }
}


