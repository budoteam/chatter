import SwiftUI
import UniformTypeIdentifiers

/// Wraps a folder tree so `fileExporter` can write it as a plain directory of
/// markdown files (zip is a follow-up — see README): OKF bundles from
/// `KnowledgeTransfer` and the skill pool from `SkillTransfer`. Import goes
/// through `fileImporter` + the transfer enums directly and doesn't use this
/// type.
struct OKFBundleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    static var writableContentTypes: [UTType] { [.folder] }

    /// `nonisolated(unsafe)`: `FileWrapper` is not Sendable, but the document
    /// is built once and only read by the `fileExporter` machinery.
    nonisolated(unsafe) let root: FileWrapper

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
