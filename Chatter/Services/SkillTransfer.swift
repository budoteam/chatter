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

    /// Imports skills from any mix of folder URLs (walked recursively) and
    /// single `.md` file URLs, as one `fileImporter` with
    /// `allowsMultipleSelection` delivers them. Malformed files import with
    /// warnings instead of failing the run.
    static func importSkills(from urls: [URL], into context: ModelContext) -> ImportReport {
        var report = ImportReport()

        // The pool is the global name address space — one upfront fetch, then
        // a case-insensitive name lookup so batch-internal duplicates update
        // instead of violating pool uniqueness.
        let all = (try? context.fetch(FetchDescriptor<Skill>())) ?? []
        var skillsByName: [String: Skill] = [:]
        for skill in all {
            skillsByName[skill.name.lowercased()] = skill
        }

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
                    report.warnings.append("\(url.lastPathComponent): folder not readable, skipped")
                    continue
                }
                for case let fileURL as URL in enumerator {
                    guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    else { continue }
                    importFile(at: fileURL, into: context, pool: &skillsByName, report: &report)
                }
            } else {
                importFile(at: url, into: context, pool: &skillsByName, report: &report)
            }
        }

        try? context.save()
        return report
    }

    private static func importFile(
        at fileURL: URL,
        into context: ModelContext,
        pool skillsByName: inout [String: Skill],
        report: inout ImportReport
    ) {
        let fileName = fileURL.lastPathComponent
        guard fileName.lowercased().hasSuffix(".md") else {
            report.skipped += 1
            report.warnings.append("\(fileName): not markdown, skipped")
            return
        }
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            report.skipped += 1
            report.warnings.append("\(fileName): unreadable as UTF-8, skipped")
            return
        }

        let parsed = SkillCodec.parse(fileName: fileName, contents: contents)
        report.warnings.append(contentsOf: parsed.warnings)

        let stem = String(fileName.dropLast(3))  // strip ".md"
        let name = SkillToolProvider.slugify(parsed.name ?? stem)
        guard !name.isEmpty else {
            report.skipped += 1
            report.warnings.append("\(fileName): no usable skill name, skipped")
            return
        }

        if let existing = skillsByName[name.lowercased()] {
            existing.summary = parsed.summary
            existing.content = parsed.content
            existing.updatedAt = Date()
            report.updated += 1
        } else {
            let skill = Skill(name: name, summary: parsed.summary, content: parsed.content)
            context.insert(skill)
            skillsByName[name.lowercased()] = skill
            report.created += 1
        }
    }
}
