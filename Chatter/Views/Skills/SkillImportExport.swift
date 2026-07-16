import SwiftUI
import UniformTypeIdentifiers

/// Wraps one skill's serialized markdown (`SkillCodec` format) so
/// `fileExporter` can write it as a `<name>.md` file. Import goes through
/// `fileImporter` + `SkillTransfer` directly and doesn't use this type; the
/// whole-pool folder export reuses `OKFBundleDocument`.
struct SkillFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [SkillTransfer.markdownType, .plainText] }
    static var writableContentTypes: [UTType] { [SkillTransfer.markdownType, .plainText] }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
