import UIKit
import UniformTypeIdentifiers

/// اختيار الملفات والمجلدات عبر UIKit مباشرة.
/// (fileImporter حق SwiftUI كان يعلّق ولا يسكّر بعد الضغط على Open)
final class DocPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = DocPicker()
    private var completion: (([URL]) -> Void)?

    func present(folder: Bool, completion: @escaping ([URL]) -> Void) {
        self.completion = completion
        let types: [UTType] = folder ? [.folder] : [.item]
        let p = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        p.allowsMultipleSelection = !folder
        p.delegate = self
        top()?.present(p, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let c = completion
        completion = nil
        c?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion = nil
    }

    private func top() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var vc = scene?.keyWindow?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}
