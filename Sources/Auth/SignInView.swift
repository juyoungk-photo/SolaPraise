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
                        Text(isWorking ? "Signing in…" : "Sign in with Google")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)

                Button("로그인 없이 둘러보기") {
                    auth.continueWithoutAccount()
                }
                .font(.subheadline)

                Text("시편과 말씀 피드는 로그인 없이 바로 쓸 수 있습니다.\n플레이리스트와 검색에만 Google 계정이 필요합니다.")
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
