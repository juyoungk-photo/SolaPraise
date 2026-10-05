//
//  TeamSampleData.swift
//  SolaPraise
//
//  Sample roster and schedule, for looking at 예배 without a sheet.
//
//  DEBUG only, and deliberately shaped like the real thing: a run of Sundays
//  with a Friday and a rehearsal among them, some weeks fully answered, some
//  with 인도 missing, some with nobody having answered at all. A screen that
//  only ever gets looked at in its happy state is a screen whose awkward
//  states ship unseen.
//

#if DEBUG
import Foundation

enum TeamSampleData {

    @MainActor
    static func install(into store: TeamStore) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        func sunday(after weeks: Int) -> Date {
            let base = calendar.nextDate(
                after: today.addingTimeInterval(-86_400),
                matching: DateComponents(weekday: 1),
                matchingPolicy: .nextTime
            ) ?? today
            return calendar.date(byAdding: .weekOfYear, value: weeks, to: base) ?? base
        }

        let roles = ["인도", "반주", "건반", "드럼", "베이스", "보컬"]
            .enumerated()
            .map { TeamRole(name: $0.element, order: Double($0.offset)) }

        var services: [TeamService] = []
        for week in 0 ..< 6 {
            let day = sunday(after: week)
            services.append(TeamService(
                date: day,
                title: "주일 2부예배",
                time: "오전 11:30",
                location: "본당",
                notes: week == 0 ? "새가족 환영 주일입니다." : nil,
                assignments: week == 1 ? ["반주": "김은혜"] : [:]
            ))
            if week == 1 {
                services.append(TeamService(
                    date: calendar.date(byAdding: .day, value: -2, to: day) ?? day,
                    title: "금요 Worship",
                    time: "오후 7:30",
                    location: "소예배실",
                    notes: nil,
                    assignments: [:]
                ))
            }
            if week == 2 {
                services.append(TeamService(
                    date: calendar.date(byAdding: .day, value: -1, to: day) ?? day,
                    title: "팀연습",
                    time: "오전 9:30",
                    location: "본당",
                    notes: nil,
                    assignments: [:]
                ))
            }
        }
        services.sort { $0.date < $1.date }

        let people = [
            ("주영", "juyoung@example.com"),
            ("은혜", "eunhye@example.com"),
            ("민수", "minsu@example.com"),
            ("지혜", "jihye@example.com"),
            ("성훈", "sunghoon@example.com")
        ]

        var signups: [Date: [TeamSignup]] = [:]
        for (index, service) in services.enumerated() {
            let day = calendar.startOfDay(for: service.date)
            switch index % 3 {
            case 0:
                // Fully answered, both key parts taken.
                signups[day] = [
                    TeamSignup(role: "인도", email: people[0].1, name: people[0].0,
                               statusRaw: "available", row: 2 + index * 5),
                    TeamSignup(role: "반주", email: people[1].1, name: people[1].0,
                               statusRaw: "available", row: 3 + index * 5),
                    TeamSignup(role: "드럼", email: people[2].1, name: people[2].0,
                               statusRaw: "available", row: 4 + index * 5),
                    TeamSignup(role: "보컬", email: people[3].1, name: people[3].0,
                               statusRaw: "declined", row: 5 + index * 5)
                ]
            case 1:
                // 인도 missing — the state the row exists to shout about.
                signups[day] = [
                    TeamSignup(role: "베이스", email: people[2].1, name: people[2].0,
                               statusRaw: "available", row: 2 + index * 5),
                    TeamSignup(role: "보컬", email: people[4].1, name: people[4].0,
                               statusRaw: "away", row: 3 + index * 5)
                ]
            default:
                signups[day] = []
            }
        }

        func watch(_ id: String) -> URL? { YouTubeID.watchURL(id) }
        let plan = [
            PlanItem(order: 1, kind: .announcement, title: "환영과 광고", minutes: 3,
                     person: nil, key: nil, url: nil, notes: nil, row: 2),
            PlanItem(order: 2, kind: .song, title: "주의 약속하신 말씀 위에 서",
                     minutes: 6, person: "주영", key: "G",
                     url: watch("EwY1Z6_6H3I"), notes: nil, row: 3),
            PlanItem(order: 3, kind: .song, title: "나의 믿음 주께 있네",
                     minutes: 5, person: "주영", key: "D",
                     url: watch("Xsnhus5FkKw"), notes: "1절만", row: 4),
            PlanItem(order: 4, kind: .prayer, title: "대표기도", minutes: 4,
                     person: "민수", key: nil, url: nil, notes: nil, row: 5),
            PlanItem(order: 5, kind: .sermon, title: "설교", minutes: 35,
                     person: "박요셉 목사", key: nil, url: nil, notes: nil, row: 6),
            PlanItem(order: 6, kind: .song, title: "주님 뜻대로 살기로 했네",
                     minutes: 4, person: "은혜", key: "A",
                     url: watch("0FM4gDmnPrk"), notes: nil, row: 7)
        ]

        var plans: [Date: [PlanItem]] = [:]
        for service in services.prefix(3) where !service.isRehearsal {
            plans[calendar.startOfDay(for: service.date)] = plan
        }

        store.installSample(
            services: services,
            roles: roles,
            signups: signups,
            plans: plans,
            members: Set(people.map { $0.1.lowercased() })
        )
    }
}
#endif
