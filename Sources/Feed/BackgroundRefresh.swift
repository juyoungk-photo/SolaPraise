//
//  BackgroundRefresh.swift
//  SolaPraise
//
//  Pulls the Atom feeds on a daily background schedule so the morning's QT is
//  already waiting rather than loading while you stand there.
//
//  This deliberately runs WITHOUT the API client. RSS needs no auth and costs
//  no quota, so a background wake can never spend units or trip an expired
//  token — durations simply fill in on the next foreground refresh.
//

import Foundation
import BackgroundTasks
import SwiftData

enum BackgroundRefresh {

    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let taskIdentifier = "com.juyoungkim.solapraise.refresh"

    /// Register before the app finishes launching, or BGTaskScheduler traps.
    static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask, container: container)
        }
    }

    /// Ask for a wake around 5am local. iOS treats this as the *earliest*
    /// time and decides the rest based on usage patterns, so this is a hint,
    /// never a guarantee.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = nextEarlyMorning()
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator and unentitled builds throw here; not worth surfacing.
            #if DEBUG
            print("[SolaPraise] background refresh not scheduled: \(error)")
            #endif
        }
    }

    private static func handle(_ task: BGAppRefreshTask, container: ModelContainer) {
        // Always queue the next one first — a run that returns without
        // rescheduling silently ends the daily cycle.
        schedule()

        let work = Task { @MainActor in
            let context = ModelContext(container)
            let store = FeedStore()
            await store.refresh(purpose: nil, context: context, client: nil)
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private static func nextEarlyMorning(hour: Int = 5) -> Date {
        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = 0

        guard let candidate = calendar.date(from: components) else {
            return now.addingTimeInterval(6 * 3600)
        }
        return candidate > now
            ? candidate
            : calendar.date(byAdding: .day, value: 1, to: candidate) ?? now.addingTimeInterval(24 * 3600)
    }
}
