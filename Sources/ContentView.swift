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
    @EnvironmentObject private var planning: PlanningAuth

    /// Recomputed as the roster loads and as sign-in changes, so the tab
    /// appears without a relaunch.
    private var teamAccess: TeamAccess.State {
        // Shown while the scope is missing too, so the tab is where the fix
        // is rather than vanishing and leaving nowhere to grant it.
        TeamAccess.evaluate(
            sheetId: TeamSheetSource.current,
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

    /// The tabs that exist right now, in order. The `TabView` and the
    /// iPad's own bar both read this, so the two cannot drift apart —
    /// a bar listing a tab that is not there would select nothing.
    private var tabItems: [TabItem] {
        var items: [TabItem] = [
            TabItem(tag: .home, title: "홈", symbol: "square.grid.2x2"),
            TabItem(tag: .worship, title: "찬양", symbol: "music.note"),
            TabItem(tag: .word, title: "말씀", symbol: "book.closed"),
            TabItem(tag: .library, title: "보관함", symbol: "list.bullet.rectangle")
        ]
        if teamAccess != .unconfigured, teamAccess != .signInRequired {
            items.append(TabItem(tag: .team, title: "예배",
                                 symbol: "calendar.badge.clock"))
        }
        if showsStudioTab {
            items.append(TabItem(tag: .studio, title: "작업실",
                                 symbol: "recordingtape"))
        }
        return items
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

            // Shown whenever a sheet is configured and somebody is signed
            // in — including when that person is NOT on the roster.
            //
            // Hiding it for a non-member was a dead end: the only way to get
            // onto the roster is through this tab, so anyone left off it had
            // no route back in, and the tab simply being absent explained
            // nothing. It appears and says why instead.
            if teamAccess != .unconfigured, teamAccess != .signInRequired {
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
        // Beneath the player on purpose: the expanded player covers the
        // whole stage, bar included, and the docked one ends exactly where
        // this bar begins.
        .overlay(alignment: .bottom) {
            if AppLayout.usesCustomTabBar {
                BottomTabBar(selection: $selection, items: tabItems)
            }
        }
        .overlay { PlayerStage(host: playerHost) }
        // 음원 찾기 can be opened from four places, none of them 작업실. When
        // it hands over a file, this is what takes you to where it is
        // analysed — on iPhone 작업실 lives inside 보관함, so that is the tab.
        .onChange(of: StudioInbox.shared.wantsStudio) { _, wants in
            guard wants else { return }
            selection = showsStudioTab ? .studio : .library
            StudioInbox.shared.wantsStudio = false
        }
        // The roster has to be read before the tab can be decided, and the
        // sheet is the only place it lives.
        .task {
            team.configure(auth: auth, planning: planning)
            // Without the scope the roster cannot be read, and hammering the
            // API for 403s would only hide the real problem.
            guard auth.canUseSheets,
                  let sheetId = TeamSheetSource.current,
                  team.services.isEmpty else { return }
            await team.load(sheetId: sheetId)
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
            #if DEBUG
            if let id = DebugHarness.dockVideoId {
                playerHost.play(queue: [PlayableVideo(id: id, title: "Debug playback",
                                                      channelTitle: "Debug")])
                playerHost.minimize()
            }
            #endif
        }
    }
}


