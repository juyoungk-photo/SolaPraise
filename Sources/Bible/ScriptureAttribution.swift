//
//  ScriptureAttribution.swift
//  SolaPraise
//
//  The copyright notice each translation requires, wherever its text is shown.
//
//  Crossway's terms are specific: every page displaying ESV text carries the
//  standard notice AND a link to www.esv.org. Not a footnote on one screen —
//  every page. The app was showing it on the reading screen and not on the
//  passage panel under the player, which is the same text on another page.
//
//  One view, so a new screen that displays scripture cannot forget.
//

import SwiftUI

struct ScriptureAttribution: View {
    let translation: BibleTranslation

    var body: some View {
        Group {
            switch translation {
            case .esv:
                // A link, because the licence asks for one rather than for
                // the words "esv.org" in plain text.
                Text(translation.attribution) + Text(" · ")
                    + Text(.init("[www.esv.org](https://www.esv.org)"))
            case .krv, .extra:
                Text(translation.attribution)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .tint(.secondary)
    }
}
