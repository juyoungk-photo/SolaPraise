//
//  ChordEntrySheet.swift
//  SolaPraise
//
//  코드 추가 / 코드 고치기 on the stand: the chord typed, or turned to on
//  three wheels — root, quality, bass. Each follows the other (ChordParts).
//
//  WHY: an alert held only a text field, and a chord typed on a phone is a
//  keyboard switch for 「#」 and, on a Korean keyboard, 「ㅠ」 for 「B」.
//

import SwiftUI

struct ChordEntrySheet: View {
    let title: String
    let message: String
    /// The chord being corrected, or empty when adding.
    let initial: String
    /// When adding: the key shown, so the wheels start on its chord.
    let startRoot: String?
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var parts = ChordParts()
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                TextField("예: G, D/F#, Em7", text: $text)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    // Latin letters: on a Korean keyboard 「B」 types 「ㅠ」.
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .focused($typing)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                    .onSubmit(save)

                HStack(spacing: 0) {
                    wheel("근음", ChordParts.roots, $parts.root, label: ChordParts.display)
                    wheel("종류", ChordParts.qualities, $parts.quality) { $0.isEmpty ? "—" : $0 }
                    wheel("베이스", [""] + ChordParts.roots, $parts.bass) {
                        $0.isEmpty ? "없음" : "/" + ChordParts.display($0)
                    }
                }
                .frame(height: 190)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장", action: save)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            // Typed: the wheels follow once it is a chord they hold.
            .onChange(of: text) { _, typed in
                if let read = ChordParts(typed), read != parts { parts = read }
            }
            // Turned: the text is the wheels' chord.
            .onChange(of: parts) { _, turned in
                if ChordParts(text) != turned { text = turned.text }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if let read = ChordParts(initial) {
                parts = read
                text = initial
            } else if initial.isEmpty {
                // Adding: start on the key's chord, written, so 저장 at
                // once saves what the wheels show.
                parts = ChordParts(root: startRoot.flatMap { ChordParts($0)?.root } ?? "C")
                text = parts.text
            } else {
                text = initial
            }
        }
    }

    private func save() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        onSave(typed)
    }

    /// One wheel, titled. Clipped, so the three wheels side by side do not
    /// take each other's touches.
    private func wheel(_ title: String, _ values: [String], _ selection: Binding<String>,
                       label: @escaping (String) -> String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text(label(value)).font(.title3.weight(.semibold)).tag(value)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .clipped()
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
    }
}
