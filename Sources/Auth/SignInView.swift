//
//  SignInView.swift
//  SolaPraise
//
//  Sign-in gate. Adapted from PraiseTheLord's SignInView with the
//  "paste your sheet link" onboarding removed — SolaPraise needs only
//  the Google account.
//

import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)

                Text("SolaPraise")
                    .font(.largeTitle.bold())

                Text("Your worship music and your daily Word —\nwithout the rabbit hole.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 14) {
                Button {
                    Task {
                        isWorking = true
                        await auth.signIn()
                        isWorking = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "person.crop.circle")
                        }
                        Text(isWorking ? "로그인 중…" : AccountRole.youtube.signInLabel)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)

                // Which account, and what for, before Google asks which.
                VStack(spacing: 2) {
                    Text(AccountRole.youtube.purpose)
                    Text(AccountRole.youtube.pick)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                Button("로그인 없이 둘러보기") {
                    auth.continueWithoutAccount()
                }
                .font(.subheadline)

                Text(AppSecrets.hasYouTubeAPIKey
                     ? "찬양·말씀 피드, 검색, 시편과 성경 읽기, 코드 감지까지 로그인 없이 쓸 수 있습니다.\n팀 시트와 악보 올리기는 나중에 설정에서 교회 계정으로 따로 연결합니다."
                     : "시편과 말씀 읽기는 로그인 없이 바로 쓸 수 있습니다.\n영상과 재생목록에는 Google 계정이 필요합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let err = auth.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .padding()
    }
}
