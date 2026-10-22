//
//  AccountRole.swift
//  SolaPraise
//
//  The three Google sign-ins, each named once, with what it is for and
//  which account to pick — said on every button that asks for one.
//
//  WHY: the same second account was 「플래닝 계정」 in one place, 「다른
//  계정으로 시트 연결」 in another, 「다른 계정·드라이브 권한 연결」 and
//  「추가 연결」 in two more, and every button said only 「Google 로그인」.
//  Google's own screen then lists every account on the phone and asks
//  which — with nothing to say which one this step wants, or what it will
//  be used for. A person signed the YouTube account into the sheet, or
//  the church account into YouTube, and found out later.
//

import SwiftUI

enum AccountRole {
    /// The main sign-in: the person's own YouTube.
    case youtube
    /// The team sheet and its Drive folder (PlanningAuth).
    case church
    /// The church's 교제 channel, read-only (ChannelManagerAuth).
    case channelManager

    var name: String {
        switch self {
        case .youtube:        return "YouTube 계정"
        case .church:         return "교회 계정"
        case .channelManager: return "채널 관리 계정"
        }
    }

    /// What it is used for, in one line.
    var purpose: String {
        switch self {
        case .youtube:
            return "내 재생목록 보기·편집, 콘티를 재생목록으로 내보내기, 예배 찬양 보관"
        case .church:
            return "팀 시트에 응답·배정·순서·곡 메모 쓰기, 악보·콘티 PDF를 드라이브에 올리기"
        case .channelManager:
            return "관리하는 교제 채널의 일부 공개 예배를 멤버에게 공유 (읽기만)"
        }
    }

    /// Which account to choose on Google's screen.
    var pick: String {
        switch self {
        case .youtube:
            return "재생목록이 있는 내 개인 계정을 고르세요."
        case .church:
            return "팀 시트를 편집할 수 있는 계정을 고르세요. YouTube 계정은 그대로 둡니다."
        case .channelManager:
            return "그 채널을 관리하는 계정(브랜드 채널이면 그 채널)을 고르세요."
        }
    }

    var signInLabel: String {
        switch self {
        case .youtube:        return "YouTube 계정으로 로그인"
        case .church:         return "교회 계정 연결"
        case .channelManager: return "채널 관리 계정 연결"
        }
    }

    var symbol: String {
        switch self {
        case .youtube:        return "play.rectangle"
        case .church:         return "person.2.badge.key"
        case .channelManager: return "person.badge.key"
        }
    }
}

/// A sign-in button that says, before it is pressed, which account and
/// what for.
struct AccountSignInButton: View {
    let role: AccountRole
    var prominent = false
    let action: () async -> Void

    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if prominent {
                    button.buttonStyle(.borderedProminent)
                } else {
                    button.buttonStyle(.bordered)
                }
            }
            .disabled(working)
            Text(role.purpose)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(role.pick)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var button: some View {
        Button {
            working = true
            Task {
                await action()
                working = false
            }
        } label: {
            HStack(spacing: 6) {
                if working { ProgressView().controlSize(.small) } else { Image(systemName: role.symbol) }
                Text(role.signInLabel)
            }
        }
    }
}
