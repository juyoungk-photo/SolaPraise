//
//  ShareFile.swift
//  SolaPraise
//
//  Presents a generated file (the chord-sheet PDF) in the system share sheet.
//  ShareLink needs its item up front; the PDF is only worth rendering once the
//  user actually asks for it, so this is driven by state instead.
//

import SwiftUI
import UIKit

struct ShareableFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
