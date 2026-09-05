//
//  DocumentPicker.swift
//  The same import method mSign uses: a UIKit UIDocumentPickerViewController
//  presented directly, with asCopy: true. iOS hands back a local, fully-readable
//  copy — no security-scoped / iCloud-materialization issues that .fileImporter
//  trips over. A retained proxy keeps the delegate alive during presentation.
//

import UIKit
import UniformTypeIdentifiers

enum DocumentPickerPresenter {
    private static var proxy: Proxy?

    static func pickZip(onPicked: @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            var types: [UTType] = [.zip]
            if let z = UTType("com.pkware.zip-archive") { types.append(z) }
            types.append(.item)   // catch-all so a real zip is never greyed out

            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.allowsMultipleSelection = false

            let p = Proxy(onPicked: onPicked)
            proxy = p
            picker.delegate = p

            guard let top = UIApplication.topMostViewController() else {
                onPicked(nil); proxy = nil; return
            }
            top.present(picker, animated: true)
        }
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

extension UIApplication {
    static func topMostViewController() -> UIViewController? {
        guard
            let scene = shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
