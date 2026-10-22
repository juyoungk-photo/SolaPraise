//
//  MorningAlarm.swift
//  SolaPraise
//
//  An alarm that wakes you with 모닝워십 live, or with a 찬양 playlist.
//
//  HOW IT WAKES: iOS does not let an app start itself at a time, and this
//  app does not play in the background. So the alarm is the system's own —
//  AlarmKit on iOS 26, which rings through silent mode and Focus like the
//  Clock app — and its 「예배 틀기」 button opens the app, which starts
//  playing as it comes up. Before iOS 26 a notification does the same job
//  less loudly: tapping it opens the app and plays.
//
//  The same start is offered to Shortcuts (「아침 예배 틀기」), so someone who
//  keeps their Clock alarm can add an automation — 「When my alarm is
//  stopped」 → this — and get the same morning.
//
//  Settings live on the device: an alarm is personal, not the team's.
//

import Foundation
import SwiftUI
import AppIntents
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

enum MorningAlarm {

    // MARK: - What plays

    enum Content: Equatable {
        /// 코너스톤교회 모닝워십, live when it is on.
        case morningWorship
        /// A playlist, by id, with the title it was chosen under.
        case playlist(id: String, title: String)

        var label: String {
            switch self {
            case .morningWorship: return "모닝워십 라이브"
            case let .playlist(_, title): return title
            }
        }
    }

    /// The channel 모닝워십 streams on — the same one the 말씀 tab carries.
    static let worshipChannelId = "UCr1z2X_zyeC8GMbLv4swMVA"

    // MARK: - Settings (device only)

    private static let defaults = UserDefaults.standard
    private enum Key {
        static let enabled = "morningAlarm.enabled"
        static let hour = "morningAlarm.hour"
        static let minute = "morningAlarm.minute"
        static let weekdays = "morningAlarm.weekdays"
        static let playlistId = "morningAlarm.playlistId"
        static let playlistTitle = "morningAlarm.playlistTitle"
        static let alarmId = "morningAlarm.alarmKitId"
        static let pending = "morningAlarm.pendingStart"
    }

    static var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }
    static var hour: Int {
        get { defaults.object(forKey: Key.hour) as? Int ?? 5 }
        set { defaults.set(newValue, forKey: Key.hour) }
    }
    static var minute: Int {
        get { defaults.object(forKey: Key.minute) as? Int ?? 55 }
        set { defaults.set(newValue, forKey: Key.minute) }
    }
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday. Weekdays by default:
    /// 모닝워십 is a weekday service.
    static var weekdays: Set<Int> {
        get { Set(defaults.array(forKey: Key.weekdays) as? [Int] ?? [2, 3, 4, 5, 6]) }
        set { defaults.set(newValue.sorted(), forKey: Key.weekdays) }
    }
    static var content: Content {
        get {
            guard let id = defaults.string(forKey: Key.playlistId), !id.isEmpty else { return .morningWorship }
            return .playlist(id: id, title: defaults.string(forKey: Key.playlistTitle) ?? "재생목록")
        }
        set {
            switch newValue {
            case .morningWorship:
                defaults.removeObject(forKey: Key.playlistId)
                defaults.removeObject(forKey: Key.playlistTitle)
            case let .playlist(id, title):
                defaults.set(id, forKey: Key.playlistId)
                defaults.set(title, forKey: Key.playlistTitle)
            }
        }
    }

    // MARK: - Starting

    /// Asks the app to start the morning's playback: now if it is running in
    /// front, otherwise as soon as it is. Called from the alarm's button,
    /// the notification, Shortcuts, and 「지금 시험」.
    static func requestStart() {
        defaults.set(Date(), forKey: Key.pending)
        NotificationCenter.default.post(name: .morningAlarmStart, object: nil)
    }

    /// The request, once — and only a recent one: an alarm answered at six
    /// must not start playing when the app is next opened at noon.
    static func takePendingStart(now: Date = Date()) -> Bool {
        guard let asked = defaults.object(forKey: Key.pending) as? Date else { return false }
        defaults.removeObject(forKey: Key.pending)
        return now.timeIntervalSince(asked) < 10 * 60
    }

    // MARK: - Scheduling

    enum ScheduleResult: Equatable {
        case scheduled(usesSystemAlarm: Bool)
        case off
        case notAllowed
        case failed(String)
    }

    /// Replaces whatever was scheduled with the current settings.
    ///
    /// One at a time. The settings screen reschedules on every change, and
    /// turning the alarm on changes three things at once — each call
    /// cancelled the one id it remembered and scheduled its own, so two or
    /// three alarms ended up set where one was asked for, and only the last
    /// could be turned off from here. The rest rang every morning.
    @MainActor
    @discardableResult
    static func reschedule() async -> ScheduleResult {
        let previous = running
        let task = Task { @MainActor () -> ScheduleResult in
            _ = await previous?.value
            return await rescheduleNow()
        }
        running = task
        return await task.value
    }
    @MainActor private static var running: Task<ScheduleResult, Never>?

    private static func rescheduleNow() async -> ScheduleResult {
        await cancelAll()
        guard isEnabled, !weekdays.isEmpty else { return .off }

        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return await scheduleSystemAlarm() }
        #endif
        return await scheduleNotifications()
    }

    /// Every alarm this app has set — not only the one it remembers, so an
    /// alarm left by an earlier version, or by two changes at once, goes too.
    private static func cancelAll() async {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let manager = AlarmManager.shared
            for alarm in (try? manager.alarms) ?? [] { try? manager.cancel(id: alarm.id) }
            if let raw = defaults.string(forKey: Key.alarmId), let id = UUID(uuidString: raw) {
                try? manager.cancel(id: id)
            }
            defaults.removeObject(forKey: Key.alarmId)
        }
        #endif
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: (1...7).map { "morningAlarm.\($0)" })
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private static func scheduleSystemAlarm() async -> ScheduleResult {
        let manager = AlarmManager.shared
        var state = manager.authorizationState
        if state == .notDetermined { state = (try? await manager.requestAuthorization()) ?? .denied }
        guard state == .authorized else { return .notAllowed }

        let play = AlarmButton(text: "예배 틀기", textColor: .white, systemImageName: "play.fill")
        let title: LocalizedStringResource = content == .morningWorship ? "모닝워십" : "아침 찬양"
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: title, secondaryButton: play, secondaryButtonBehavior: .custom)
        } else {
            alert = AlarmPresentation.Alert(
                title: title,
                stopButton: AlarmButton(text: "끄기", textColor: .white, systemImageName: "xmark"),
                secondaryButton: play, secondaryButtonBehavior: .custom)
        }
        let attributes = AlarmAttributes<MorningAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert), tintColor: .accentColor)
        let weekdayList = weekdays.sorted().compactMap(localeWeekday)
        let schedule = Alarm.Schedule.relative(.init(time: .init(hour: hour, minute: minute),
                                                     repeats: .weekly(weekdayList)))
        let id = UUID()
        do {
            _ = try await manager.schedule(id: id, configuration: .alarm(
                schedule: schedule, attributes: attributes,
                secondaryIntent: StartMorningPlaybackIntent(alarmID: id.uuidString)))
            defaults.set(id.uuidString, forKey: Key.alarmId)
            #if DEBUG
            print("[MorningAlarm] scheduled \(schedule) — alarms now: \((try? manager.alarms.count) ?? -1)")
            #endif
            return .scheduled(usesSystemAlarm: true)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @available(iOS 26.0, *)
    private static func localeWeekday(_ calendarWeekday: Int) -> Locale.Weekday? {
        [1: .sunday, 2: .monday, 3: .tuesday, 4: .wednesday,
         5: .thursday, 6: .friday, 7: .saturday][calendarWeekday]
    }
    #endif

    /// Before iOS 26: one repeating notification per chosen weekday.
    private static func scheduleNotifications() async -> ScheduleResult {
        let center = UNUserNotificationCenter.current()
        let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard allowed else { return .notAllowed }
        for weekday in weekdays {
            let note = UNMutableNotificationContent()
            note.title = content == .morningWorship ? "모닝워십" : "아침 찬양"
            note.body = "탭하면 \(content.label)을 틉니다."
            note.sound = .default
            note.interruptionLevel = .timeSensitive
            note.userInfo = ["kind": "morningAlarm"]
            var when = DateComponents()
            when.weekday = weekday
            when.hour = hour
            when.minute = minute
            let request = UNNotificationRequest(
                identifier: "morningAlarm.\(weekday)", content: note,
                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true))
            try? await center.add(request)
        }
        return .scheduled(usesSystemAlarm: false)
    }
}

extension Notification.Name {
    static let morningAlarmStart = Notification.Name("SolaPraise.morningAlarmStart")
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct MorningAlarmMetadata: AlarmMetadata {}
#endif

// MARK: - Intents

/// The alarm's 「예배 틀기」: opens the app, which starts playing.
struct StartMorningPlaybackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "아침 예배 틀기"
    static var description = IntentDescription("모닝워십 라이브, 또는 아침 알람에 정한 찬양을 틉니다.")
    static var openAppWhenRun = true

    /// The alarm that is ringing, when the alarm's own button runs this.
    /// A button with custom behaviour leaves the alarm ringing until it is
    /// told to stop — found in the simulator, where 「예배 틀기」 opened the
    /// app and the alarm went on sounding over the service.
    @Parameter(title: "Alarm")
    var alarmID: String?

    init() {}
    init(alarmID: String) { self.alarmID = alarmID }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let raw = alarmID, let id = UUID(uuidString: raw) {
            try? AlarmManager.shared.stop(id: id)
        }
        #endif
        MorningAlarm.requestStart()
        return .result()
    }
}

/// Offered in Shortcuts, so a Clock alarm can start the same morning
/// through an automation.
struct SolaPraiseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartMorningPlaybackIntent(),
                    phrases: ["\(.applicationName)에서 아침 예배 틀기",
                              "\(.applicationName) 모닝워십 틀기"],
                    shortTitle: "아침 예배 틀기",
                    systemImageName: "sunrise")
    }
}

// MARK: - Notifications (before iOS 26, and in the foreground)

/// Routes a tapped morning notification to playback; shows notifications
/// while the app is open, which iOS otherwise hides.
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.userInfo["kind"] as? String == "morningAlarm" else { return }
        await MainActor.run { MorningAlarm.requestStart() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.userInfo["kind"] as? String == "morningAlarm" {
            // Already open: no need to tap — start now.
            await MainActor.run { MorningAlarm.requestStart() }
        }
        return [.banner, .sound]
    }
}
