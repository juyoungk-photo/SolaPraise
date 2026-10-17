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
    @EnvironmentObject private var quota: QuotaLedger
    @EnvironmentObject private var channelManager: ChannelManagerAuth

    /// Recomputed as the roster loads and as sign-in changes, so the tab
    /// appears without a relaunch.
    private var teamAccess: TeamAccess.State {
        #if DEBUG
        if DebugHarness.seedTeam {
            return .member(email: "juyoung@example.com", name: "주영")
        }
        #endif
        // Shown while the scope is missing too, so the tab is where the fix
        // is rather than vanishing and leaving nowhere to grant it.
        //
        // Judged by the account that ACTS on the sheet — the church account
        // when one is connected — exactly as ServicePrepView judges it. This
        // used the YouTube sign-in alone, so somebody who connected only a
        // church account had no 예배 tab at all, while the screen behind it
        // would have let them in.
        return TeamAccess.evaluate(
            sheetId: TeamSheetSource.current,
            email: team.actingEmail(auth: auth, planning: planning),
            displayName: planning.isSignedIn ? planning.email : auth.displayName,
            roster: team.memberEmails
        )
    }
    @Environment(\.modelContext) private var modelContext
    @State private var selection: Tab = Tab.defaultForNow()
    @State private var showDailyGate = false

    /// 작업실 is a tab of its own wherever it fits, and then 보관함 does not
    /// list it again. For everyone, signed in or not: its 악보 — import,
    /// read, transpose, share as PDF — needs no account and no team, and
    /// without 예배 it was the only way to a chart at all. (Its audio tools
    /// stay DevGate-only, inside it.)
    ///
    /// iPad: always — there is room, and it is where a musician reads a
    /// chart. iPhone: when the bar stays at five; with 예배 too it would be
    /// six, and iOS folds a sixth tab into 「더 보기」, hiding 보관함 behind
    /// it. Then, and only then, 작업실 stays inside 보관함.
    private var showsStudioTab: Bool {
        UIDevice.current.userInterfaceIdiom == .pad || !showsTeamTab
    }

    private var showsTeamTab: Bool {
        teamAccess != .unconfigured && teamAccess != .signInRequired
    }

    /// The tabs that exist right now, in order. The `TabView` and the
    /// iPad's own bar both read this, so the two cannot drift apart —
    /// a bar listing a tab that is not there would select nothing.
    private var tabItems: [TabItem] {
        // 홈 › 말씀 › 찬양 › 예배 › 작업실 › 보관함: what is used each day
        // first, the archive last.
        var items: [TabItem] = [
            TabItem(tag: .home, title: "홈", symbol: "square.grid.2x2"),
            TabItem(tag: .word, title: "말씀", symbol: "book.closed"),
            TabItem(tag: .worship, title: "찬양", symbol: "music.note")
        ]
        if showsTeamTab {
            items.append(TabItem(tag: .team, title: "예배",
                                 symbol: "calendar.badge.clock"))
        }
        if showsStudioTab {
            items.append(TabItem(tag: .studio, title: "작업실",
                                 symbol: "recordingtape"))
        }
        items.append(TabItem(tag: .library, title: "보관함", symbol: "list.bullet.rectangle"))
        return items
    }

    /// The tab choice, seeing a tab pressed again too: pressing the tab
    /// already shown while the player covers it means 「show me this page」 —
    /// the player goes to PiP. A change of tab is handled by onChange below;
    /// the same tab changes nothing, so it was never noticed.
    private var tabSelection: Binding<Tab> {
        Binding(get: { selection }, set: { new in
            if new == selection, playerHost.mode == .full { playerHost.dock(orClose: true) }
            selection = new
        })
    }

    @ViewBuilder
    private func screen(for tab: Tab) -> some View {
        switch tab {
        case .home:    HomeView(selection: $selection)
        case .word:    WordFeedView()
        case .worship: WorshipFeedView()
        case .library: PlaylistLibraryView(showsStudio: !showsStudioTab)
        // 예배 is shown whenever a sheet is configured and somebody is signed
        // in — including when that person is NOT on the roster. Hiding it for
        // a non-member was a dead end: the only way onto the roster is
        // through this tab, so anyone left off it had no route back in, and
        // the tab simply being absent explained nothing. tabItems decides
        // whether it is listed at all; it appears and says why instead.
        case .team:    ServicePrepView()
        case .studio:  StudioView()
        }
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
            case "team":    return .team
            case "studio":  return .studio
            default: break
            }
            #endif
            return .home
        }
    }

    var body: some View {
        // Built FROM tabItems, which the iPad's own bar also reads.
        //
        // These were two separate lists, and they drifted: 말씀 was moved
        // before 찬양 in tabItems, so the iPad showed the new order while the
        // iPhone — whose system bar renders the TabView's own order — kept
        // the old one. The same edit had to be made twice and was made once.
        // One list now decides which tabs exist, what they are called, and
        // what order they come in, on both devices.
        TabView(selection: tabSelection) {
            ForEach(tabItems) { item in
                screen(for: item.tag)
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item.tag)
            }
        }
        // The player lives here, above the tabs and in one place in the view
        // tree, so a song keeps playing while you move between them and the
        // web view is never re-parented.
        // Beneath the player on purpose: the expanded player covers the
        // whole stage, bar included, and the docked one ends exactly where
        // this bar begins.
        .overlay { PlayerStage(host: playerHost) }
        // The bar sits ABOVE the player on iPad, and under it on iPhone.
        //
        // A phone playing a video has nothing else to offer, so the expanded
        // player taking the whole screen is right there. An iPad does: the
        // player is a window on a large screen, and burying the only way out
        // of it meant a 재생목록 that filled everything with no visible way
        // back to 예배 준비. Keeping the bar reachable also makes switching
        // tabs mean something — see onChange below, where it docks.
        .overlay(alignment: .bottom) {
            if AppLayout.usesCustomTabBar {
                BottomTabBar(selection: tabSelection, items: tabItems)
            }
        }
        // Leaving for another tab docks the player rather than closing it.
        //
        // The song keeps playing and the bar keeps it one tap away, which is
        // what pressing a different tab while something is playing means:
        // "show me that", not "stop this".
        .onChange(of: selection) { _, _ in
            guard AppLayout.usesCustomTabBar, playerHost.mode == .full else { return }
            // A tab chosen while the player covers it: PiP, or closed — never
            // left over the tab.
            playerHost.dock(orClose: true)
        }
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
        // The channel manager's app keeps the members' 관심 채널 list
        // current: new unlisted services go up without anyone pasting links.
        .task(id: auth.isSignedIn || channelManager.isSignedIn) {
            guard auth.isSignedIn || channelManager.isSignedIn else { return }
            let usePlanning = planning.isSignedIn
            let sheets = SheetsClient { [auth, planning] in
                usePlanning ? try await planning.token() : try await auth.accessToken()
            }
            for channelId in SharedListPublisher.channelsSwitchedOn where SharedListPublisher.isDue(channelId) {
                let outcome = await SharedListPublisher.publish(
                    channelId: channelId,
                    client: SharedListPublisher.client(auth: auth, quota: quota, manager: channelManager), sheets: sheets,
                    password: SharedChannelList.password)
                #if DEBUG
                print("[SharedList] publish \(channelId.prefix(6))… → \(outcome)")
                #endif
            }
        }
        .task {
            team.configure(auth: auth, planning: planning)
            // Without the scope the roster cannot be read, and hammering the
            // API for 403s would only hide the real problem.
            guard auth.canUseSheets,
                  let sheetId = TeamSheetSource.current,
                  team.services.isEmpty else { return }
            await team.load(sheetId: sheetId)
            // The other half of a shared 콘티: one person writes the
            // playlist into the Schedule tab, and every other member's app
            // puts it on their 홈 and 찬양 tab from here.
            SharedPlaylistSync.run(services: team.sharedPlaylists, context: modelContext)
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
            #if DEBUG
            if DebugHarness.seedTeam { TeamSampleData.install(into: team) }
            #endif
            daily.advanceIfNewDay()
            if daily.isGateOwed { showDailyGate = true }
            #if DEBUG
            if let id = DebugHarness.dockVideoId {
                // -uiTestDockTitle "…": a real title, so 찬양's rows (악보,
                // search suggestions) have something to work from.
                let title = DebugHarness.args.firstIndex(of: "-uiTestDockTitle")
                    .flatMap { DebugHarness.args.indices.contains($0 + 1) ? DebugHarness.args[$0 + 1] : nil }
                playerHost.play(queue: [PlayableVideo(id: id, title: title ?? "Debug playback",
                                                      channelTitle: title == nil ? "Debug" : "MARKERS WORSHIP")],
                                purpose: title == nil ? nil : .worship)
                if let seconds = DebugHarness.sleepSeconds { playerHost.setSleepTimer(after: TimeInterval(seconds)) }
            }
            #endif
        }
    }
}


