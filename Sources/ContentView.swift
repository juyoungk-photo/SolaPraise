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
        case home, worship, word, library, studio

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

            if showsStudioTab {
                StudioView()
                    .tabItem { Label("작업실", systemImage: "recordingtape") }
                    .tag(Tab.studio)
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


