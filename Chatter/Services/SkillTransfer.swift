import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Maps skills to single markdown files (`SkillCodec` format) and back:
/// per-skill and whole-pool export as `FileWrapper`s for `fileExporter`, and
/// an import that accepts any mix of folders and `.md` files. Import matches
/// by skill name — a name that already exists in the pool is updated in place
/// so `Agent.skillIDs` references stay intact.
@MainActor
enum SkillTransfer {
    /// iOS 17 / macOS 14 have no built-in `UTType.markdown`.
    nonisolated static let markdownType: UTType =
        UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText

    struct ImportReport {
        var created = 0
        var updated = 0
        var skipped = 0
        var warnings: [String] = []

        var summary: String {
            let total = created + updated
            var text = "Imported \(total) skill\(total == 1 ? "" : "s")"
            if total > 0 {
                text += " (\(created) new, \(updated) updated)"
            }
            text += "."
            if skipped > 0 {
                text += " Skipped \(skipped) file\(skipped == 1 ? "" : "s")."
            }
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

    // MARK: - Export

    static func serializedContents(for skill: Skill) -> String {
        SkillCodec.serialize(name: skill.name, summary: skill.summary, content: skill.content)
    }

    static func fileName(for skill: Skill) -> String {
        "\(skill.name).md"
    }

    /// Flat folder of `<name>.md` files for `fileExporter`.
    static func exportWrapper(for skills: [Skill]) -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        for skill in skills {
            let file = FileWrapper(regularFileWithContents: Data(serializedContents(for: skill).utf8))
            file.preferredFilename = fileName(for: skill)
            root.addFileWrapper(file)
        }
        return root
    }

    // MARK: - Import

    /// One file found during the import walk, in discovery order, so the
    /// apply phase rebuilds the report with the exact warning order the old
    /// synchronous import produced.
    enum ParsedEntry: Sendable {
        /// Not markdown or unreadable: counts as skipped.
        case skipped(warning: String)
        /// A folder URL that could not be walked: warning only.
        case folderWarning(String)
        /// Parsed markdown; `stem` is the file name minus ".md".
        case parsed(fileName: String, stem: String, skill: SkillCodec.ParsedSkill)
    }

    /// Off-actor result of walking and parsing the import URLs.
    struct ParsedSkillBatch: Sendable {
        var entries: [ParsedEntry] = []
    }

    /// Off-actor parse phase: URL walk, file I/O, and `SkillCodec.parse`
    /// only — no SwiftData. `nonisolated async` so awaiting it from the main
    /// actor runs the body on the cooperative pool. Slugifying stays in the
    /// apply phase because `SkillToolProvider.slugify` is main-actor isolated.
    nonisolated static func parseSkills(from urls: [URL]) async -> ParsedSkillBatch {
        scan(urls)
    }

    /// Main-actor apply phase: turns parsed files into skill rows. Import
    /// matches by skill name — a name that already exists in the pool is
    /// updated in place so `Agent.skillIDs` references stay intact.
    static func applyImport(_ parsed: ParsedSkillBatch, into context: ModelContext) -> ImportReport {
        var report = ImportReport()

        // The pool is the global name address space — one upfront fetch, then
        // a case-insensitive name lookup so batch-internal duplicates update
        // instead of violating pool uniqueness.
        let all = (try? context.fetch(FetchDescriptor<Skill>())) ?? []
        var skillsByName: [String: Skill] = [:]
        for skill in all {
            skillsByName[skill.name.lowercased()] = skill
        }

        for entry in parsed.entries {
            switch entry {
            case .skipped(let warning):
                report.skipped += 1
                report.warnings.append(warning)
            case .folderWarning(let warning):
                report.warnings.append(warning)
            case .parsed(let fileName, let stem, let parsedSkill):
                report.warnings.append(contentsOf: parsedSkill.warnings)

                let name = SkillToolProvider.slugify(parsedSkill.name ?? stem)
                guard !name.isEmpty else {
                    report.skipped += 1
                    report.warnings.append("\(fileName): no usable skill name, skipped")
                    continue
                }

                if let existing = skillsByName[name.lowercased()] {
                    // A re-imported file without `description:` parses to an
                    // empty summary — keep the existing one instead of wiping
                    // it. Content is always replaced.
                    if !parsedSkill.summary.isEmpty {
                        existing.summary = parsedSkill.summary
                    }
                    existing.content = parsedSkill.content
                    existing.updatedAt = Date()
                    report.updated += 1
                } else {
                    let skill = Skill(name: name, summary: parsedSkill.summary, content: parsedSkill.content)
                    context.insert(skill)
                    skillsByName[name.lowercased()] = skill
                    report.created += 1
                }
            }
        }

        context.saveOrLog()
        return report
    }

    /// Imports skills from any mix of folder URLs (walked recursively) and
    /// single `.md` file URLs, as one `fileImporter` with
    /// `allowsMultipleSelection` delivers them. Malformed files import with
    /// warnings instead of failing the run. Synchronous wrapper kept for
    /// callers that are not async (tests); the UI uses `parseSkills` +
    /// `applyImport` to keep I/O off the main actor.
    static func importSkills(from urls: [URL], into context: ModelContext) -> ImportReport {
        applyImport(scan(urls), into: context)
    }

    /// Synchronous worker shared by the async parse phase and the sync
    /// wrapper. Holds each URL's security-scoped access for its walk.
    nonisolated private static func scan(_ urls: [URL]) -> ParsedSkillBatch {
        var batch = ParsedSkillBatch()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    batch.entries.append(.folderWarning("\(url.lastPathComponent): folder not readable, skipped"))
                    continue
                }
                for case let fileURL as URL in enumerator {
                    guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    else { continue }
                    batch.entries.append(scanFile(fileURL))
                }
            } else {
                batch.entries.append(scanFile(url))
            }
        }
        return batch
    }

    /// Reads and parses one candidate file; non-markdown and unreadable
    /// files come back as skipped entries.
    nonisolated private static func scanFile(_ fileURL: URL) -> ParsedEntry {
        let fileName = fileURL.lastPathComponent
        guard fileName.lowercased().hasSuffix(".md") else {
            return .skipped(warning: "\(fileName): not markdown, skipped")
        }
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return .skipped(warning: "\(fileName): unreadable as UTF-8, skipped")
        }

        let parsed = SkillCodec.parse(fileName: fileName, contents: contents)
        return .parsed(
            fileName: fileName,
            stem: String(fileName.dropLast(3)),  // strip ".md"
            skill: parsed
        )
    }
}
