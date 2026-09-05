//
//  DocumentPicker.swift
//  mSign-style UIKit document picker (asCopy: true → local, readable copies).
//  pickZip: single archive.  pickFiles: any files, multi-select (for importing
//  files into the working tree).
//

import UIKit
import UniformTypeIdentifiers

@MainActor
enum DocumentPickerPresenter {
    private static var proxy: Proxy?

    static func pickZip(onPicked: @escaping (URL?) -> Void) {
        var types: [UTType] = [.zip]
        if let z = UTType("com.pkware.zip-archive") { types.append(z) }
        types.append(.item)
        present(types: types, multiple: false) { urls in onPicked(urls.first) }
    }

    static func pickFiles(onPicked: @escaping ([URL]) -> Void) {
        present(types: [.item], multiple: true, onPicked: onPicked)
    }

    private static func present(types: [UTType], multiple: Bool, onPicked: @escaping ([URL]) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = multiple
        let p = Proxy(onPicked: onPicked)
        proxy = p
        picker.delegate = p
        guard let top = topMostViewController() else { onPicked([]); proxy = nil; return }
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
        let onPicked: ([URL]) -> Void
        init(onPicked: @escaping ([URL]) -> Void) { self.onPicked = onPicked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPicked(urls); DocumentPickerPresenter.proxy = nil
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPicked([]); DocumentPickerPresenter.proxy = nil
        }
    }
}
