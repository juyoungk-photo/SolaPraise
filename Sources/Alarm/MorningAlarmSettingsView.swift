//
//  MorningAlarmSettingsView.swift
//  SolaPraise
//
//  Setting the morning alarm: when, which days, and what plays.
//

import SwiftUI
import SwiftData

struct MorningAlarmSettingsView: View {
    @EnvironmentObject private var morning: MorningPlayback
    @EnvironmentObject private var host: PlayerHost
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var quota: QuotaLedger

    @Query(sort: [SortDescriptor(\CachedPlaylist.title)]) private var playlists: [CachedPlaylist]

    @State private var isOn = MorningAlarm.isEnabled
    @State private var time: Date = {
        Calendar.current.date(from: DateComponents(hour: MorningAlarm.hour, minute: MorningAlarm.minute)) ?? Date()
    }()
    @State private var weekdays = MorningAlarm.weekdays
    @State private var content = MorningAlarm.content
    @State private var status: String?
    @State private var statusIsProblem = false

    var body: some View {
        Form {
            Section {
                Toggle("아침 알람", isOn: $isOn)
                if isOn {
                    DatePicker("시간", selection: $time, displayedComponents: .hourAndMinute)
                    weekdayPicker
                }
            } footer: {
                if let status {
                    Text(status).foregroundStyle(statusIsProblem ? Color.orange : Color.secondary)
                }
            }

            Section {
                Picker("틀 것", selection: contentChoice) {
                    Text("모닝워십 라이브").tag("worship")
                    ForEach(worshipPlaylists) { playlist in
                        Text(playlist.title).tag(playlist.playlistId)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("알람이 울리면")
            } footer: {
                Text(contentExplanation)
            }

            Section {
                Button {
                    MorningAlarm.content = content
                    morning.start(host: host, client: AppServices.client(auth: auth, quota: quota))
                } label: {
                    Label("지금 틀어 보기", systemImage: "play.circle")
                }
            } footer: {
                Text("알람이 울리면 「예배 틀기」를 누르세요. 앱이 열리며 바로 재생합니다. 잠겨 있으면 Face ID로 연 뒤 재생합니다. "
                     + "시계 앱 알람을 그대로 쓰려면, 단축어 앱 › 자동화 › 「알람」(알람이 중단될 때)에 「아침 예배 틀기」를 넣으세요.")
            }

            Section {
                Label("밤에는 플레이어의 「취침」 버튼으로 10분~1시간 뒤, 또는 지금 영상이 끝나면 재생을 멈출 수 있습니다.",
                      systemImage: "moon.zzz")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("취침")
            }
        }
        .navigationTitle("아침 알람")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        // -uiTestMorningEnable: turn it on as the toggle would.
        .task {
            if DebugHarness.args.contains("-uiTestMorningEnable") { isOn = true }
            if DebugHarness.args.contains("-uiTestMorningOff") { isOn = false }
            // -uiTestMorningSoon: ring at the start of the next minute but one,
            // every day, so the whole alarm can be watched end to end.
            if DebugHarness.args.contains("-uiTestMorningSoon") {
                weekdays = Set(1...7)
                time = Calendar.current.date(bySetting: .second, value: 0, of: Date().addingTimeInterval(120)) ?? time
                isOn = true
            }
        }
        #endif
        .onChange(of: isOn) { _, _ in apply() }
        .onChange(of: time) { _, _ in apply() }
        .onChange(of: weekdays) { _, _ in apply() }
        .onChange(of: content) { _, _ in apply() }
    }

    // MARK: - Pieces

    /// 일 월 화 수 목 금 토, as toggles.
    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            ForEach(Self.weekOrder, id: \.self) { day in
                let on = weekdays.contains(day)
                Button {
                    if on { weekdays.remove(day) } else { weekdays.insert(day) }
                } label: {
                    Text(Self.dayName(day))
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(on ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }

    static let weekOrder = [2, 3, 4, 5, 6, 7, 1]   // 월 … 일
    static func dayName(_ weekday: Int) -> String {
        ["", "일", "월", "화", "수", "목", "금", "토"][weekday]
    }

    /// 찬양 playlists first; the rest after.
    private var worshipPlaylists: [CachedPlaylist] {
        let worship = playlists.filter { $0.purposeRaw == Purpose.worship.rawValue }
        return worship.isEmpty ? playlists : worship
    }

    private var contentChoice: Binding<String> {
        Binding {
            if case let .playlist(id, _) = content { return id }
            return "worship"
        } set: { tag in
            if tag == "worship" { content = .morningWorship; return }
            let title = playlists.first { $0.playlistId == tag }?.title ?? "재생목록"
            content = .playlist(id: tag, title: title)
        }
    }

    private var contentExplanation: String {
        switch content {
        case .morningWorship:
            return "코너스톤교회 모닝워십을 라이브로 틉니다. 아직 시작 전이면 시작될 때까지 기다렸다가 틀고, "
                + "\(Int(MorningWorshipPick.longestWait / 60))분이 지나도 시작하지 않으면(주말 등) 가장 최근 모닝워십을 틉니다."
        case .playlist:
            return "이 재생목록을 처음부터 틉니다."
        }
    }

    // MARK: - Applying

    private func apply() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        MorningAlarm.isEnabled = isOn
        MorningAlarm.hour = parts.hour ?? 6
        MorningAlarm.minute = parts.minute ?? 0
        MorningAlarm.weekdays = weekdays
        MorningAlarm.content = content
        Task {
            let result = await MorningAlarm.reschedule()
            #if DEBUG
            print("[MorningAlarm] reschedule → \(result)")
            #endif
            switch result {
            case .off:
                status = weekdays.isEmpty && isOn ? "요일을 하나 이상 고르세요." : nil
                statusIsProblem = weekdays.isEmpty && isOn
            case let .scheduled(system):
                status = Self.summary() + (system ? " · 무음 모드에서도 울립니다." : " · 알림으로 알려 드립니다.")
                statusIsProblem = false
            case .notAllowed:
                status = "알람 권한이 없습니다. 설정 앱 › SolaPraise에서 알람(또는 알림)을 허용하세요."
                statusIsProblem = true
            case let .failed(message):
                status = "알람을 설정하지 못했습니다: \(message)"
                statusIsProblem = true
            }
        }
    }

    /// 「평일 오전 5:55」 / 「월·수·금 오전 6:00」 / 「매일 …」.
    static func summary() -> String {
        let days = MorningAlarm.weekdays
        let dayText: String
        if days.count == 7 { dayText = "매일" }
        else if days == [2, 3, 4, 5, 6] { dayText = "평일" }
        else if days == [1, 7] { dayText = "주말" }
        else { dayText = weekOrder.filter(days.contains).map(dayName).joined(separator: "·") }
        let time = Calendar.current.date(from: DateComponents(hour: MorningAlarm.hour, minute: MorningAlarm.minute))
            .map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return "\(dayText) \(time)"
    }
}
