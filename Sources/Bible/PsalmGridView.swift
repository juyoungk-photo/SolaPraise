//
//  PsalmGridView.swift
//  SolaPraise
//
//  All 150 psalms at a glance, colour-coded by read state, so any chapter is
//  one tap away instead of buried behind repeated ← →.
//

import SwiftUI

struct PsalmGridView: View {
    @EnvironmentObject private var daily: DailyReading
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(1...Psalms.chapterCount, id: \.self) { chapter in
                            Button {
                                daily.setChapter(chapter)
                                dismiss()
                            } label: {
                                cell(chapter)
                            }
                            .buttonStyle(.plain)
                            .id(chapter)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)

                    legend
                }
                .safeAreaInset(edge: .top) {
                    progressHeader
                        .background(.bar)
                }
                .onAppear { proxy.scrollTo(daily.chapter, anchor: .center) }
            }
            .navigationTitle("시편")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }

    // MARK: - Cell

    private func cell(_ chapter: Int) -> some View {
        let state = state(for: chapter)
        return Text("\(chapter)")
            .font(.system(.footnote, design: .rounded).weight(state == .current ? .bold : .medium))
            .monospacedDigit()
            .foregroundStyle(state.foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(state.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if state == .current {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
    }

    private func state(for chapter: Int) -> CellState {
        if chapter == daily.chapter { return .current }
        return daily.readChapters.contains(chapter) ? .read : .unread
    }

    private enum CellState {
        case read, unread, current

        var background: Color {
            switch self {
            case .read:    return .green.opacity(0.22)
            case .unread:  return Color(.secondarySystemBackground)
            case .current: return .accentColor.opacity(0.18)
            }
        }
        var foreground: Color {
            switch self {
            case .read:    return .green
            case .unread:  return .secondary
            case .current: return .accentColor
            }
        }
    }

    // MARK: - Header & legend

    private var progressHeader: some View {
        let readCount = daily.readChapters.count
        let fraction = Double(readCount) / Double(Psalms.chapterCount)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("150편 중 \(readCount)편 읽음")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction)
                .tint(.green)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(color: .accentColor, label: "오늘")
            legendItem(color: .green, label: "읽음")
            legendItem(color: .secondary, label: "안 읽음")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.bottom, 20)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.28))
                .frame(width: 14, height: 14)
            Text(label)
        }
    }
}
