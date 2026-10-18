//
//  LyricEditSheet.swift
//  SolaPraise
//
//  가사 고치기: one 코드표 line, syllable by syllable, each verse its own
//  row, with the chord over the syllable it starts on.
//
//  WHY SYLLABLE BY SYLLABLE: the 코드표 hangs each chord on a syllable. A
//  line retyped whole would have to be cut back into syllables and could
//  land the chords on the wrong ones; a box per syllable cannot. A box can
//  be cleared (a stray mark read as a syllable) or hold two (one missed).
//

import SwiftUI

struct LyricEditSheet: View {
    let line: ScoreChart.System
    /// The chord as shown — transposed, spelled — by id.
    let chord: (UUID) -> String?
    let onSave: (ScoreChart.System) -> Void
    let onCancel: () -> Void

    @State private var edited: ScoreChart.System?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let edited {
                        ForEach(0..<max(1, edited.verses), id: \.self) { verse in
                            VStack(alignment: .leading, spacing: 6) {
                                if edited.verses > 1 {
                                    Text("\(verse + 1)번째 줄").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                ChipFlow(spacing: 4, lineSpacing: 8) {
                                    ForEach(places(edited), id: \.self) { place in
                                        if place.cell < 0 {
                                            // Between bars.
                                            Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1, height: 44)
                                        } else {
                                            syllableField(place, verse: verse)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text("틀린 글자만 고치세요. 칸마다 한 음절이고, 위의 코드는 그 음절에서 시작합니다. 잘못 읽은 칸은 비우고, 빠진 음절은 옆 칸에 함께 적으세요. 이 기기에만 저장됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("가사 고치기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { if let edited { onSave(edited) } }
                        .disabled(edited == line)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { if edited == nil { edited = line } }
    }

    private struct Place: Hashable { let bar: Int; let cell: Int }

    /// Every note of the line in order, a bar mark (cell -1) between bars.
    private func places(_ system: ScoreChart.System) -> [Place] {
        var out: [Place] = []
        for (b, bar) in system.bars.enumerated() {
            if b > 0 { out.append(Place(bar: b, cell: -1)) }
            out += bar.cells.indices.map { Place(bar: b, cell: $0) }
        }
        return out
    }

    private func syllableField(_ place: Place, verse: Int) -> some View {
        let cell = edited?.bars[place.bar].cells[place.cell]
        return VStack(spacing: 2) {
            Text(cell?.chord.flatMap(chord) ?? " ")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .fixedSize()
            TextField("·", text: binding(place, verse: verse))
                .font(.body)
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .fixedSize()
                .frame(minWidth: 30, minHeight: 30)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground)))
        }
    }

    private func binding(_ place: Place, verse: Int) -> Binding<String> {
        Binding {
            guard let syllables = edited?.bars[place.bar].cells[place.cell].syllables,
                  syllables.indices.contains(verse) else { return "" }
            return syllables[verse]
        } set: { text in
            guard var line = edited else { return }
            var cell = line.bars[place.bar].cells[place.cell]
            while cell.syllables.count <= verse { cell.syllables.append("") }
            cell.syllables[verse] = text.trimmingCharacters(in: .whitespaces)
            line.bars[place.bar].cells[place.cell] = cell
            edited = line
        }
    }
}
