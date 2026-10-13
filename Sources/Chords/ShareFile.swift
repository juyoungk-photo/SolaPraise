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

/// The share sheet, presented by whatever is on top.
///
/// The 악보 stand made its PDF and then showed nothing when it was opened
/// from 작업실: a SwiftUI `.sheet` on a full-screen cover inside a tab did
/// not present, though the same stand opened as the app's root did. UIKit
/// asked directly from the topmost controller presents from anywhere — and
/// on iPad anchors its popover, which a bare UIActivityViewController
/// presented there must have.
enum SharePresenter {
    @MainActor
    static func present(_ url: URL, completion: @escaping () -> Void = {}) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController
        else { completion(); return }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }

        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        if let popover = controller.popoverPresentationController {
            let bounds = top.view.bounds
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: bounds.maxX - 48, y: bounds.maxY - 48, width: 1, height: 1)
            popover.permittedArrowDirections = [.down, .right]
        }
        top.present(controller, animated: true)
    }
}
