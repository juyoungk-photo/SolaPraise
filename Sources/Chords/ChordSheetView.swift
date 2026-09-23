//
//  ChordSheetView.swift
//  PraiseTheLord
//
//  Displays a saved session's chords as a lead-sheet-style chord chart,
//  with transpose +/- semitone controls and a share button.
//

import SwiftUI

struct ChordSheetView: View {
    let session: Session

    @State private var semitoneShift: Int = 0
    @State private var useFlats: Bool = false
    @State private var pdf: ShareableFile?

    private var transposedChords: [Chord] {
        session.chords.map { $0.asChord.transposed(by: semitoneShift) }
    }

    private var transposedKey: String? {
        // Transpose the detected key label (e.g., "G major" -> "A major" for +2).
        guard let raw = session.detectedKey else { return nil }
        let parts = raw.split(separator: " ")
        guard parts.count == 2,
              let root = Chord.sharpNames.firstIndex(of: String(parts[0]))
                ?? Chord.flatNames.firstIndex(of: String(parts[0]))
        else { return raw }
        let newRoot = ((root + semitoneShift) % 12 + 12) % 12
        let name = (useFlats ? Chord.flatNames : Chord.sharpNames)[newRoot]
        return "\(name) \(parts[1])"
    }

    var body: some View {
        VStack(spacing: 0) {
            transposeBar
            Divider()
            chordGrid
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: exportText()) {
                        Label("텍스트로 공유", systemImage: "doc.plaintext")
                    }
                    Button {
                        if let url = ChordSheetPDF.export(
                            session: session,
                            semitoneShift: semitoneShift,
                            useFlats: useFlats
                        ) {
                            pdf = ShareableFile(url: url)
                        }
                    } label: {
                        Label("악보 PDF로 공유", systemImage: "doc.richtext")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $pdf) { file in
            ActivityView(url: file.url)
        }
    }

    // MARK: - Transpose bar

    private var transposeBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Key:")
                    .foregroundStyle(.secondary)
                Text(transposedKey ?? "—").bold()
                Spacer()
                Text(semitoneShift == 0
                     ? "Original"
                     : (semitoneShift > 0 ? "+\(semitoneShift)" : "\(semitoneShift)"))
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    semitoneShift = max(-11, semitoneShift - 1)
                } label: {
                    Image(systemName: "minus.circle.fill").font(.title)
                }

                Button {
                    semitoneShift = 0
                } label: {
                    Text("Reset").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    semitoneShift = min(11, semitoneShift + 1)
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title)
                }

                Toggle("♭", isOn: $useFlats)
                    .toggleStyle(.button)
                    .fixedSize()
            }
        }
        .padding()
    }

    // MARK: - Chord grid

    private var chordGrid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                      spacing: 10) {
                ForEach(Array(transposedChords.enumerated()), id: \.offset) { idx, chord in
                    VStack(spacing: 2) {
                        Text(chord.symbol(useFlats: useFlats))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text(timeString(session.chords[idx].timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
    }

    // MARK: - Helpers

    private func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Plain-text export for ShareLink (email, Messages, Notes, etc.).
    private func exportText() -> String {
        var out = "\(session.title)\n"
        if let k = transposedKey { out += "Key: \(k)\n" }
        if semitoneShift != 0 {
            out += "Transposed \(semitoneShift > 0 ? "+" : "")\(semitoneShift) semitones\n"
        }
        out += "\n"
        let syms = transposedChords.map { $0.symbol(useFlats: useFlats) }
        // Group into lines of 4 chords each, separated by " | ".
        for row in stride(from: 0, to: syms.count, by: 4) {
            let chunk = syms[row..<min(row + 4, syms.count)]
            out += "| " + chunk.joined(separator: "  |  ") + "  |\n"
        }
        return out
    }
}

#Preview {
    NavigationStack {
        ChordSheetView(session: Session(
            title: "How Great Is Our God",
            detectedKey: "G major",
            chords: [
                SessionChord(chord: Chord(root: 7, quality: .major), timestamp: 0),
                SessionChord(chord: Chord(root: 2, quality: .major), timestamp: 4),
                SessionChord(chord: Chord(root: 4, quality: .minor), timestamp: 8),
                SessionChord(chord: Chord(root: 0, quality: .major), timestamp: 12),
                SessionChord(chord: Chord(root: 7, quality: .major), timestamp: 16),
                SessionChord(chord: Chord(root: 2, quality: .major), timestamp: 20),
                SessionChord(chord: Chord(root: 4, quality: .minor), timestamp: 24),
                SessionChord(chord: Chord(root: 0, quality: .major), timestamp: 28),
            ]
        ))
    }
}
