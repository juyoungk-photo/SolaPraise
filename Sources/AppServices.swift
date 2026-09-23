//
//  AppServices.swift
//  SolaPraise
//
//  Builds the API client from the two environment objects. Views take this
//  rather than constructing a client each time, so quota accounting stays
//  centralised on one ledger instance.
//

import SwiftUI

@MainActor
enum AppServices {
    static func client(auth: GoogleAuthManager, quota: QuotaLedger) -> YouTubeAPIClient {
        YouTubeAPIClient(auth: auth, quota: quota)
    }
}

/// Small helper so every view surfaces API failures the same way.
@MainActor
final class LoadState<Value>: ObservableObject {
    @Published var value: Value?
    @Published var isLoading = false
    @Published var errorMessage: String?

    func run(_ work: @escaping () async throws -> Value) async {
        isLoading = true
        errorMessage = nil
        do {
            value = try await work()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        isLoading = false
    }
}
