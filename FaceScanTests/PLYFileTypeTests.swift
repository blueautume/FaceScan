import UniformTypeIdentifiers
import XCTest
@testable import FaceScan

final class PLYFileTypeTests: XCTestCase {
    func testAppDeclaresPLYAsAnImportedViewableDocument() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let declarations = try XCTUnwrap(info["UTImportedTypeDeclarations"] as? [[String: Any]])
        let ply = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == PLYFileType.identifier })
        let conforms = try XCTUnwrap(ply["UTTypeConformsTo"] as? [String])
        XCTAssertTrue(conforms.contains(UTType.data.identifier))
        XCTAssertTrue(conforms.contains(UTType.content.identifier))
        XCTAssertTrue(conforms.contains(UTType.threeDContent.identifier))

        let tags = try XCTUnwrap(ply["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["ply"])
        XCTAssertEqual(tags["public.mime-type"] as? String, "application/x-ply")

        let documents = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let viewer = try XCTUnwrap(documents.first {
            ($0["LSItemContentTypes"] as? [String])?.contains(PLYFileType.identifier) == true
        })
        let supportedTypes = try XCTUnwrap(viewer["LSItemContentTypes"] as? [String])
        XCTAssertTrue(supportedTypes.contains("public.polygon-file-format"))
        XCTAssertTrue(supportedTypes.contains(PLYFileType.type.identifier))
        XCTAssertEqual(viewer["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(viewer["LSHandlerRank"] as? String, "Default")
        XCTAssertEqual(info["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)
        XCTAssertEqual(info["UIFileSharingEnabled"] as? Bool, true)
    }

    func testPLYTypeMatchesItsDeclaredTagsAndContentConformance() {
        XCTAssertTrue(["public.polygon-file-format", PLYFileType.identifier].contains(PLYFileType.type.identifier))
        XCTAssertEqual(PLYFileType.type.preferredFilenameExtension, "ply")
        XCTAssertTrue(PLYFileType.type.conforms(to: .data))
        XCTAssertTrue(PLYFileType.type.conforms(to: .threeDContent))
    }
}
