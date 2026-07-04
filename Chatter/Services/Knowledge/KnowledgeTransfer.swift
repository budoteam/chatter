import Foundation
import SwiftData

/// Maps OKF bundle folders to `KnowledgeBundle`/`KnowledgeConcept` rows and
/// back: folder-walk import with per-file warnings, and a `FileWrapper`
/// export tree for `fileExporter`.
@MainActor
enum KnowledgeTransfer {
    struct ImportReport {
        var bundleName: String = ""
        var imported: Int = 0
        var skipped: Int = 0
        /// What a "skipped" item is, singular — folder import skips
        /// non-markdown files, PDF import skips text-less scans.
        var skippedNoun: String = "non-markdown file"
        var warnings: [String] = []

        var summary: String {
            var text = "Imported \(imported) document\(imported == 1 ? "" : "s") into “\(bundleName)”."
            if skipped > 0 { text += " Skipped \(skipped) \(skippedNoun)\(skipped == 1 ? "" : "s")." }
            return text
        }

        /// Summary plus a capped warning list — the one alert body every
        /// import surface shows.
        var alertText: String {
            var text = summary
            if !warnings.isEmpty {
                text += "\n\nWarnings:\n" + warnings.prefix(8).joined(separator: "\n")
                if warnings.count > 8 {
                    text += "\n(\(warnings.count - 8) more)"
                }
            }
            return text
        }
    }

    enum TransferError: LocalizedError {
        case notReadable(String)

        var errorDescription: String? {
            switch self {
            case .notReadable(let path): return "Could not read folder “\(path)”."
            }
        }
    }

    // MARK: - Import

    /// Walks an OKF bundle folder and creates (or merges into) a bundle.
    /// Per the OKF spec, non-conformance is tolerated: files with missing or
    /// malformed frontmatter import with warnings instead of failing the run.
    static func importBundle(
        from folderURL: URL,
        into context: ModelContext,
        mergingInto existing: KnowledgeBundle? = nil
    ) throws -> ImportReport {
        let scoped = folderURL.startAccessingSecurityScopedResource()
        defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw TransferError.notReadable(folderURL.lastPathComponent)
        }

        var report = ImportReport()
        let bundle = existing ?? KnowledgeBundle(name: folderURL.lastPathComponent)
        report.bundleName = bundle.name

        // Path-keyed lookup so merge-import stays linear instead of scanning
        // the concepts array per file.
        var conceptsByPath: [String: KnowledgeConcept] = [:]
        for concept in bundle.concepts ?? [] {
            conceptsByPath[concept.path] = concept
        }

        let basePath = folderURL.standardizedFileURL.path
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }

            let fullPath = fileURL.standardizedFileURL.path
            guard fullPath.hasPrefix(basePath + "/") else { continue }
            let relativePath = String(fullPath.dropFirst(basePath.count + 1))

            guard relativePath.hasSuffix(".md") else {
                report.skipped += 1
                report.warnings.append("\(relativePath): not markdown, skipped")
                continue
            }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                report.warnings.append("\(relativePath): unreadable as UTF-8, skipped")
                continue
            }

            let doc = OKFCodec.parse(path: relativePath, contents: contents)
            report.warnings.append(contentsOf: doc.warnings)

            let conceptPath = String(relativePath.dropLast(3))  // strip ".md"
            let concept: KnowledgeConcept
            if let existing = conceptsByPath[conceptPath] {
                concept = existing
            } else {
                concept = KnowledgeConcept(path: conceptPath)
                concept.bundle = bundle
                context.insert(concept)
                conceptsByPath[conceptPath] = concept
            }
            apply(doc, to: concept)
            report.imported += 1
        }

        if existing == nil {
            context.insert(bundle)
        }
        bundle.updatedAt = .now
        try? context.save()
        return report
    }

    /// Copies a parsed document's contents onto a concept row.
    static func apply(_ doc: OKFDocument, to concept: KnowledgeConcept) {
        concept.kind = doc.kind
        concept.body = doc.body
        if let fm = doc.frontmatter {
            concept.typeName = fm.type
            concept.title = fm.title
            concept.summary = fm.summary
            concept.resource = fm.resource
            concept.tags = fm.tags
            concept.timestampRaw = fm.timestampRaw
            concept.extraFields = fm.extraFields
        } else {
            concept.typeName = ""
            concept.title = nil
            concept.summary = nil
            concept.resource = nil
            concept.tags = []
            concept.timestampRaw = nil
            concept.extraFields = []
        }
        concept.updatedAt = .now
    }

    /// The codec-level document for a stored concept (export, previews, tools).
    static func document(for concept: KnowledgeConcept) -> OKFDocument {
        switch concept.kind {
        case .index, .log:
            return OKFDocument(
                relativePath: concept.fileName, kind: concept.kind,
                frontmatter: nil, body: concept.body
            )
        case .concept:
            let fm = OKFFrontmatter(
                type: concept.typeName,
                title: concept.title,
                summary: concept.summary,
                resource: concept.resource,
                tags: concept.tags,
                timestampRaw: concept.timestampRaw,
                extraFields: concept.extraFields
            )
            return OKFDocument(
                relativePath: concept.fileName, kind: .concept,
                frontmatter: fm, body: concept.body
            )
        }
    }

    /// The serialized markdown file contents for a stored concept.
    static func serializedContents(for concept: KnowledgeConcept) -> String {
        OKFCodec.serialize(document(for: concept))
    }

    // MARK: - Export

    /// Builds the bundle's folder tree for `fileExporter`. Stored index/log
    /// rows export verbatim; a bundle without a root `index.md` gets one
    /// generated so consumers can progressively disclose the contents.
    static func exportWrapper(for bundle: KnowledgeBundle) -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        for concept in bundle.orderedConcepts {
            add(concept: concept, to: root)
        }
        if bundle.concept(atPath: "index") == nil {
            let index = FileWrapper(
                regularFileWithContents: Data(generatedRootIndex(for: bundle).utf8)
            )
            index.preferredFilename = "index.md"
            root.addFileWrapper(index)
        }
        return root
    }

    private static func add(concept: KnowledgeConcept, to root: FileWrapper) {
        let components = concept.fileName.split(separator: "/").map(String.init)
        guard let fileName = components.last else { return }

        var directory = root
        for folder in components.dropLast() {
            if let existing = directory.fileWrappers?[folder], existing.isDirectory {
                directory = existing
            } else {
                let child = FileWrapper(directoryWithFileWrappers: [:])
                child.preferredFilename = folder
                directory.addFileWrapper(child)
                directory = child
            }
        }

        let contents = serializedContents(for: concept)
        let file = FileWrapper(regularFileWithContents: Data(contents.utf8))
        file.preferredFilename = fileName
        directory.addFileWrapper(file)
    }

    /// A root `index.md` in the spec's listing style: one section per
    /// top-level folder (plus one for root-level concepts), each entry
    /// `* [title](/path.md) - description`.
    static func generatedRootIndex(for bundle: KnowledgeBundle) -> String {
        var sections: [(title: String, entries: [String])] = []
        var sectionIndex: [String: Int] = [:]

        for concept in bundle.conceptDocuments {
            let components = concept.path.split(separator: "/")
            let sectionTitle = components.count > 1 ? String(components[0]) : "Concepts"
            let line = "* [\(concept.displayTitle)](/\(concept.fileName))"
                + (concept.summary.map { $0.isEmpty ? "" : " - \($0)" } ?? "")
            if let i = sectionIndex[sectionTitle] {
                sections[i].entries.append(line)
            } else {
                sectionIndex[sectionTitle] = sections.count
                sections.append((sectionTitle, [line]))
            }
        }

        var text = "# \(bundle.name)\n"
        for section in sections {
            text += "\n## \(section.title)\n\n"
            text += section.entries.joined(separator: "\n") + "\n"
        }
        return text
    }
}
