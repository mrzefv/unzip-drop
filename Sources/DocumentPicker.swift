//
//  DocumentPicker.swift
//  The same import method mSign uses: a UIKit UIDocumentPickerViewController
//  presented directly, with asCopy: true. iOS hands back a local, fully-readable
//  copy — no security-scoped / iCloud issues that .fileImporter trips over.
//  MainActor-isolated throughout (no cross-thread closures to trip concurrency).
//

import UIKit
import UniformTypeIdentifiers

@MainActor
enum DocumentPickerPresenter {
    private static var proxy: Proxy?

    static func pickZip(onPicked: @escaping (URL?) -> Void) {
        var types: [UTType] = [.zip]
        if let z = UTType("com.pkware.zip-archive") { types.append(z) }
        types.append(.item)   // catch-all so a real zip is never greyed out

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false

        let p = Proxy(onPicked: onPicked)
        proxy = p
        picker.delegate = p

        guard let top = topMostViewController() else { onPicked(nil); proxy = nil; return }
        top.present(picker, animated: true)
    }

    private static func topMostViewController() -> UIViewController? {
        guard
            let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    final class Proxy: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL?) -> Void
        init(onPicked: @escaping (URL?) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPicked(urls.first)
            DocumentPickerPresenter.proxy = nil
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPicked(nil)
            DocumentPickerPresenter.proxy = nil
        }
    }
}
