//
//  ReadingNotifications.swift
//  SolaPraise
//
//  A single repeating local notification each morning suggesting the next
//  psalm. Local, not push — no server, and it fires even offline.
//

import Foundation
import UserNotifications

enum ReadingNotifications {

    static let identifier = "focustube.dailyPsalm"

    /// Asks once. Returns whether we may post notifications.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Replaces any existing reminder with one at the configured time.
    static func schedule(hour: Int = ReadingSettings.notifyHour,
                         minute: Int = ReadingSettings.notifyMinute) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard ReadingSettings.notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "오늘의 시편"
        // The chapter is computed at fire time by the daily advance, so the
        // body stays deliberately general rather than baking in a number that
        // would go stale the moment you read ahead.
        content.body = "오늘 읽을 시편이 준비되었습니다."
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        try? await center.add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    static func pendingCount() async -> Int {
        await UNUserNotificationCenter.current().pendingNotificationRequests().count
    }
}
