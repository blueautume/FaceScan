import UIKit
import XCTest
@testable import FaceScan

@MainActor
final class DocumentExportPickerTests: XCTestCase {
    func testSuccessfulExportCompletesOnceEvenIfPickerSendsAnotherEvent() throws {
        var results: [Bool] = []
        let coordinator = DocumentExportPicker.Coordinator { results.append($0) }
        let source = try makeExportSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = UIDocumentPickerViewController(forExporting: [source], asCopy: true)

        coordinator.documentPicker(controller, didPickDocumentsAt: [URL(fileURLWithPath: "/chosen/model.ply")])
        coordinator.documentPickerWasCancelled(controller)
        coordinator.documentPicker(controller, didPickDocumentsAt: [URL(fileURLWithPath: "/chosen/another.ply")])

        XCTAssertEqual(results, [true])
    }

    func testCancellationCompletesOnce() throws {
        var results: [Bool] = []
        let coordinator = DocumentExportPicker.Coordinator { results.append($0) }
        let source = try makeExportSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = UIDocumentPickerViewController(forExporting: [source], asCopy: true)

        coordinator.documentPickerWasCancelled(controller)
        coordinator.documentPickerWasCancelled(controller)
        coordinator.documentPicker(controller, didPickDocumentsAt: [URL(fileURLWithPath: "/chosen/model.ply")])

        XCTAssertEqual(results, [false])
    }

    func testEmptySelectionIsNotReportedAsSuccessfulExport() throws {
        var result: Bool?
        let coordinator = DocumentExportPicker.Coordinator { result = $0 }
        let source = try makeExportSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = UIDocumentPickerViewController(forExporting: [source], asCopy: true)

        coordinator.documentPicker(controller, didPickDocumentsAt: [])

        XCTAssertEqual(result, false)
    }

    private func makeExportSource() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanPickerTests-\(UUID().uuidString).ply")
        try Data("ply\nformat ascii 1.0\nelement vertex 0\nend_header\n".utf8).write(to: url)
        return url
    }
}
