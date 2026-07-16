import XCTest
import SwiftData
@testable import Chatter

/// Export tree building and folder/file import, including the update-on-name-
/// match conflict path that keeps `Agent.skillIDs` references intact.
@MainActor
final class SkillTransferTests: XCTestCase {
    // ModelContext does not retain its container; a local would deallocate on
    // return and the first insert would trap inside SwiftData.
    private var container: ModelContainer?
    private var tempDir: URL?

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Agent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        self.container = container
        return container.mainContext
    }

    /// Writes files into a fresh temp folder and returns its URL.
    private func makeFolder(files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillTransferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        for (name, contents) in files {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: - Export

    func testExportWrapperContainsOneParseableFilePerSkill() {
        let skills = [
            Skill(name: "alpha", summary: "first", content: "do a"),
            Skill(name: "beta", summary: "second", content: "do b"),
        ]
        let root = SkillTransfer.exportWrapper(for: skills)
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(Set((root.fileWrappers ?? [:]).keys), ["alpha.md", "beta.md"])

        let data = root.fileWrappers?["alpha.md"]?.regularFileContents
        let parsed = SkillCodec.parse(
            fileName: "alpha.md",
            contents: String(data: data ?? Data(), encoding: .utf8) ?? ""
        )
        XCTAssertEqual(parsed.name, "alpha")
        XCTAssertEqual(parsed.summary, "first")
        XCTAssertEqual(parsed.content, "do a")
    }

    // MARK: - Import

    func testImportCreatesSkillsFromFolder() throws {
        let context = try makeContext()
        let folder = try makeFolder(files: [
            "alpha.md": SkillCodec.serialize(name: "alpha", summary: "first", content: "do a"),
            "readme.txt": "not a skill",
        ])

        let report = SkillTransfer.importSkills(from: [folder], into: context)
        XCTAssertEqual(report.created, 1)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.summary, "Imported 1 skill (1 new, 0 updated). Skipped 1 file.")

        let skills = try context.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(skills.map(\.name), ["alpha"])
        XCTAssertEqual(skills.first?.summary, "first")
        XCTAssertEqual(skills.first?.content, "do a")
    }

    func testImportSingleFileWithoutFrontmatterUsesFileNameStem() throws {
        let context = try makeContext()
        let folder = try makeFolder(files: ["Weekly Report.md": "just instructions"])
        let file = folder.appendingPathComponent("Weekly Report.md")

        let report = SkillTransfer.importSkills(from: [file], into: context)
        XCTAssertEqual(report.created, 1)
        XCTAssertEqual(report.warnings.count, 1)

        let skills = try context.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(skills.first?.name, "weekly-report")
        XCTAssertEqual(skills.first?.content, "just instructions")
    }

    func testImportUpdatesExistingSkillOnNameMatch() throws {
        let context = try makeContext()
        let existing = Skill(name: "alpha", summary: "old", content: "old body")
        context.insert(existing)
        let agent = Agent()
        agent.skillIDs = [existing.id]
        context.insert(agent)
        try context.save()
        let originalID = existing.id
        let originalUpdatedAt = existing.updatedAt

        let folder = try makeFolder(files: [
            // Case-insensitive match against the stored name.
            "Alpha.md": SkillCodec.serialize(name: "Alpha", summary: "new", content: "new body"),
        ])
        let report = SkillTransfer.importSkills(from: [folder], into: context)
        XCTAssertEqual(report.created, 0)
        XCTAssertEqual(report.updated, 1)

        let skills = try context.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills.first?.id, originalID)
        XCTAssertEqual(skills.first?.summary, "new")
        XCTAssertEqual(skills.first?.content, "new body")
        XCTAssertGreaterThanOrEqual(skills.first?.updatedAt ?? .distantPast, originalUpdatedAt)
        // The agent's reference still resolves to the updated skill.
        XCTAssertEqual(agent.skillIDs, [originalID])
    }

    func testDuplicateNameWithinOneBatchUpdatesInsteadOfDuplicating() throws {
        let context = try makeContext()
        let folderA = try makeFolder(files: [
            "alpha.md": SkillCodec.serialize(name: "alpha", summary: "first", content: "a"),
        ])
        let folderB = folderA.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        try SkillCodec.serialize(name: "alpha", summary: "second", content: "b")
            .write(to: folderB.appendingPathComponent("alpha-again.md"), atomically: true, encoding: .utf8)

        let report = SkillTransfer.importSkills(from: [folderA], into: context)
        XCTAssertEqual(report.created, 1)
        XCTAssertEqual(report.updated, 1)
        let skills = try context.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(skills.count, 1)
    }

    func testImportSkipsFileWithNoUsableName() throws {
        let context = try makeContext()
        let folder = try makeFolder(files: ["!!!.md": "body only"])

        let report = SkillTransfer.importSkills(from: [folder], into: context)
        XCTAssertEqual(report.created, 0)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
    }
}
