//
//  SearchHistory.swift
//  SolaPraise
//
//  Recent searches, per search box.
//
//  UserDefaults rather than SwiftData: this is a short, disposable list of
//  strings that never needs querying, relating or syncing, and putting it in
//  the model container would mean a migration for something you can clear with
//  one button.
//

import SwiftUI

@MainActor
final class SearchHistory: ObservableObject {
    /// One store per scope, shared by every view that names that scope — so
    /// the Worship field and the home sheet each keep their own list, but two
    /// instances of the same screen stay in step.
    private static var stores: [String: SearchHistory] = [:]

    static func shared(_ scope: String) -> SearchHistory {
        if let existing = stores[scope] { return existing }
        let store = SearchHistory(scope: scope)
        stores[scope] = store
        return store
    }

    static let limit = 12

    @Published private(set) var entries: [String] = []

    private let key: String

    private init(scope: String) {
        key = "search.history.\(scope)"
        entries = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Case-insensitive de-duplication that keeps the newest spelling: search
    /// "시편" then "시편 " and you want one entry, not two.
    func record(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }

        var next = entries.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        next.insert(query, at: 0)
        entries = Array(next.prefix(Self.limit))
        persist()
    }

    func remove(_ query: String) {
        entries.removeAll { $0 == query }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(entries, forKey: key)
    }
}

// MARK: - Chips

/// Recent searches as a wrapping row of chips, for the search boxes that are
/// plain `TextField`s rather than `.searchable`.
struct SearchHistoryChips: View {
    @ObservedObject var history: SearchHistory
    let onSelect: (String) -> Void

    var body: some View {
        if !history.entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("최근 검색")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("지우기") { history.clear() }
                        .font(.caption)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(history.entries, id: \.self) { query in
                            Button { onSelect(query) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.caption2)
                                    Text(query).font(.caption)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("삭제", systemImage: "trash", role: .destructive) {
                                    history.remove(query)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
}
