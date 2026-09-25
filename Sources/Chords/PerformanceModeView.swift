//
//  PerformanceModeView.swift
//  SolaPraise
//
//  The music stand. Full screen, dark, large type, screen kept awake.
//
//  Ported from PraiseTheLord, but the chart is rebuilt. The original laid out
//  every chord in the song as one flat grid, which works for a hand-entered
//  chart of a dozen chords and not at all for a detected one of several
//  hundred — you would be reading a wall of symbols with no idea where the
//  chorus started. SolaPraise already derives sections and holds lyrics
//  against them, so the chart is grouped the way a musician reads it.
//

import SwiftUI
import SwiftData
import UIKit

struct PerformanceModeView: View {
    let songs: [SavedSong]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var index: Int
    @State private var useFlats = false
    @State private var showsLyrics = true
    /// Reading distance varies — a stand at arm's length and a keyboard at
    /// two metres want different sizes, and it is remembered per device.
    @AppStorage("performance.chordScale") private var scale: Double = 1.0

    init(songs: [SavedSong], startAt: Int = 0) {
        self.songs = songs
        _index = State(initialValue: max(0, min(startAt, songs.count - 1)))
    }

    private var song: SavedSong? {
        songs.indices.contains(index) ? songs[index] : nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let song {
                VStack(spacing: 0) {
                    header(song)
                    chart(song)
                    controls(song)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .foregroundStyle(.white)
            } else {
                Text("악보가 없습니다").foregroundStyle(.white)
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(18)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        // A set runs forty minutes and nobody is touching the screen during
        // it. Letting it sleep mid-song is the one unforgivable failure.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    if value.translation.width < -60 { go(1) }
                    else if value.translation.width > 60 { go(-1) }
                }
        )
        // Arrow keys, for an iPad on a stand with a keyboard or a page turner
        // pedal pretending to be one.
        .focusable()
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.space) { go(1); return .handled }
    }

    // MARK: - Header

    private func header(_ song: SavedSong) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(song.title)
                .font(.system(size: 30, weight: .bold))
                .lineLimit(2)

            Spacer(minLength: 8)

            if let key = transposedKey(song) {
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    if song.keyIsPublished {
                        Text("공식")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.25), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
            }

            if songs.count > 1 {
                Text("\(index + 1)/\(songs.count)")
                    .font(.system(size: 20, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.trailing, 48)   // clear of the close button
        .padding(.bottom, 14)
    }

    // MARK: - Chart

    private func chart(_ song: SavedSong) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                let sections = song.sections
                if sections.isEmpty {
                    progression(chords(of: song, from: 0, to: song.chords.count - 1))
                } else {
                    // Columns where there is width. A stand wants the whole
                    // song visible; scrolling mid-song is the thing a paper
                    // chart never makes you do.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 320), spacing: 32)],
                        alignment: .leading,
                        spacing: 26
                    ) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.label)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))

                            progression(
                                chords(of: song, from: section.startIndex, to: section.endIndex)
                            )

                            if showsLyrics, !section.lyrics.isEmpty {
                                Text(section.lyrics)
                                    .font(.system(size: 20 * scale * 0.55, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 20)
        }
    }

    private func progression(_ list: [Chord]) -> some View {
        FlowRow(spacing: 10) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, chord in
                Text(chord.symbol(useFlats: useFlats))
                    .font(.system(size: 34 * scale, weight: .bold, design: .rounded))
                    .padding(.horizontal, 14 * scale)
                    .padding(.vertical, 8 * scale)
                    .background(Color.white.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// Consecutive repeats are collapsed. Detection already emits on change,
    /// but a slice that begins mid-chord and a re-detected section can still
    /// leave a run of identical symbols, which reads as an error rather than
    /// as "hold it".
    private func chords(of song: SavedSong, from start: Int, to end: Int) -> [Chord] {
        let all = song.chords
        guard !all.isEmpty else { return [] }
        let lower = max(0, min(start, all.count - 1))
        let upper = max(lower, min(end, all.count - 1))

        var out: [Chord] = []
        for entry in all[lower...upper] {
            let chord = entry.asChord.transposed(by: song.semitoneShift)
            if chord != out.last { out.append(chord) }
        }
        return out
    }

    // MARK: - Controls

    private func controls(_ song: SavedSong) -> some View {
        HStack(spacing: 14) {
            Button { go(-1) } label: { arrow("chevron.left") }
                .disabled(index == 0)

            Divider().frame(height: 28).overlay(Color.white.opacity(0.25))

            Button { transpose(song, -1) } label: { pill("−") }
            Text(song.semitoneShift == 0 ? "원키"
                 : (song.semitoneShift > 0 ? "+\(song.semitoneShift)" : "\(song.semitoneShift)"))
                .font(.system(size: 17, weight: .medium).monospacedDigit())
                .frame(minWidth: 54)
            Button { transpose(song, 1) } label: { pill("+") }

            Button { useFlats.toggle() } label: {
                pill("♭", active: useFlats)
            }

            Divider().frame(height: 28).overlay(Color.white.opacity(0.25))

            Button { scale = max(0.6, scale - 0.1) } label: { pill("A", small: true) }
            Button { scale = min(2.0, scale + 0.1) } label: { pill("A") }

            if song.hasLyrics {
                Button { showsLyrics.toggle() } label: {
                    pill("가사", active: showsLyrics, wide: true)
                }
            }

            Spacer(minLength: 0)

            Button { go(1) } label: { arrow("chevron.right") }
                .disabled(index >= songs.count - 1)
        }
        .foregroundStyle(.white)
        .padding(.top, 12)
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 46, height: 40)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func pill(_ label: String, active: Bool = false,
                      small: Bool = false, wide: Bool = false) -> some View {
        Text(label)
            .font(.system(size: small ? 14 : 19, weight: .semibold))
            .frame(width: wide ? 58 : 40, height: 40)
            .background(active ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    private func go(_ delta: Int) {
        let target = index + delta
        guard songs.indices.contains(target) else { return }
        withAnimation(.easeOut(duration: 0.18)) { index = target }
    }

    private func transpose(_ song: SavedSong, _ delta: Int) {
        song.semitoneShift = max(-11, min(11, song.semitoneShift + delta))
        try? modelContext.save()
    }

    private func transposedKey(_ song: SavedSong) -> String? {
        guard let raw = song.keyLabel else { return nil }
        let parts = raw.split(separator: " ")
        guard let first = parts.first else { return raw }

        var name = String(first)
        var suffix = parts.count > 1 ? " " + parts.dropFirst().joined(separator: " ") : ""
        if parts.count == 1, name.count > 1, name.hasSuffix("m") {
            name = String(name.dropLast())
            suffix = "m"
        }
        guard let root = Chord.sharpNames.firstIndex(of: name)
                ?? Chord.flatNames.firstIndex(of: name)
        else { return raw }

        let shifted = ((root + song.semitoneShift) % 12 + 12) % 12
        return (useFlats ? Chord.flatNames : Chord.sharpNames)[shifted] + suffix
    }
}
