import SwiftUI
import UniformTypeIdentifiers

/// Wraps a `KnowledgeTransfer` folder tree so `fileExporter` can write an OKF
/// bundle as a plain directory of markdown files (zip is a follow-up — see
/// README). Import goes through `fileImporter` + `KnowledgeTransfer` directly
/// and doesn't use this type.
struct OKFBundleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    static var writableContentTypes: [UTType] { [.folder] }

    let root: FileWrapper

    init(root: FileWrapper) {
        self.root = root
    }

    init(configuration: ReadConfiguration) throws {
        root = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        root
    }
}
