import UniformTypeIdentifiers

enum PLYFileType {
    // Newer systems resolve PLY to public.polygon-file-format. Retain an
    // imported declaration for systems without that canonical file type.
    static let identifier = "top.furby.facescan.ply"
    static let type = UTType(filenameExtension: "ply", conformingTo: .threeDContent)
        ?? UTType(importedAs: identifier, conformingTo: .threeDContent)
}
