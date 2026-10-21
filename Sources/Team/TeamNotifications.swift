//
//  TeamNotifications.swift
//  SolaPraise
//
//  배정 · 응답 알림: told without opening the app — when the leader puts you
//  on a part, and when a service this week is still waiting on your answer.
//
//  WHY: the in-app line at the top of 예배 준비 only helps someone who opens
//  예배 준비. Most of the team opens it when asked to. The early-morning
//  background refresh reads the team sheet now and then and says what is
//  new, once each — local notifications, no server.
//
//  Best effort by nature: iOS decides when a background refresh runs, and
//  a refresh after the app was quit may not have the team sheet's sign-in
//  ready. Nothing here is the only way to learn anything.
//

import Foundation
import UserNotifications

@MainActor
enum TeamNotifications {

    static let enabledKey = "team.notifications"
    private static let notifiedKey = "team.notifiedAssignments"
    private static let remindedKey = "team.remindedAnswers"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The assignment keys already said — in the app or by a notification —
    /// so each is said once.
    static func markNotified(_ keys: [String]) {
        var set = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        set.formUnion(keys)
        UserDefaults.standard.set(Array(set.suffix(300)), forKey: notifiedKey)
    }

    /// Reads what the team store holds now and notifies what is new.
    static func check(team: TeamStore, email: String?) async {
        guard enabled, let email, let me = team.rosterName(for: email) else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        let notified = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        for entry in team.assignments(of: me) where !notified.contains(entry.key) {
            let content = UNMutableNotificationContent()
            content.title = RosterMessage.day(entry.service.date) + " " + entry.service.title
            content.body = RosterMessage.withRo(entry.parts.joined(separator: ", ")) + " 배정되었습니다."
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "assign-" + entry.key, content: content, trigger: nil))
            markNotified([entry.key])
        }

        // This week's services not yet answered — once each.
        var reminded = Set(UserDefaults.standard.stringArray(forKey: remindedKey) ?? [])
        let soon = Calendar.current.date(byAdding: .day, value: 6, to: Date()) ?? Date()
        for service in team.services where !service.isPast && service.date <= soon && !reminded.contains(service.id) {
            guard !team.hasAnswered(service, email: email, name: me) else { continue }
            let content = UNMutableNotificationContent()
            content.title = RosterMessage.day(service.date) + " " + service.title
            content.body = "아직 응답하지 않았습니다 — 가능 · 미정 · 어려움을 알려 주세요."
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "answer-" + service.id, content: content, trigger: nil))
            reminded.insert(service.id)
        }
        UserDefaults.standard.set(Array(reminded.suffix(100)), forKey: remindedKey)
    }
}
