import SwiftUI
import UIKit

/// Copies a staging file to the destination selected by the user in Files.
/// The caller retains the staging file until completion or sheet dismissal.
struct DocumentExportPicker: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        picker.directoryURL = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var completion: ((Bool) -> Void)?

        init(completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            finish(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(false)
        }

        private func finish(_ exported: Bool) {
            // Clear first because completion may itself dismiss the sheet.
            let callback = completion
            completion = nil
            callback?(exported)
        }
    }
}
