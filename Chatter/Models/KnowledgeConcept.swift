import Foundation
import SwiftData

/// What role a stored markdown file plays in an OKF bundle.
enum KnowledgeDocKind: String, Codable, CaseIterable {
    /// A regular concept document with YAML frontmatter.
    case concept
    /// A reserved `index.md` directory listing (no frontmatter).
    case index
    /// A reserved `log.md` change history (no frontmatter).
    case log

    /// The OKF reserved-filename rule, shared by the codec and the editor:
    /// `index.md` and `log.md` (at any directory level) are reserved.
    static func forFileName(_ fileName: String) -> KnowledgeDocKind {
        switch fileName {
        case "index.md": return .index
        case "log.md": return .log
        default: return .concept
        }
    }
}

/// A verbatim-preserved frontmatter key the app doesn't model, so foreign
/// bundles round-trip losslessly. `rawBlock` holds the exact YAML line(s)
/// for the key, including nested/multiline content.
struct OKFExtraField: Codable, Hashable {
    var key: String
    var rawBlock: String
}

/// One markdown file of an OKF bundle. Frontmatter fields are stored typed
/// for the known OKF keys; unknown keys are kept verbatim in
/// `extraFrontmatterJSON` so import → export round-trips losslessly.
@Model
final class KnowledgeConcept {
    var id: UUID = UUID()
    /// Bundle-relative path WITHOUT the ".md" suffix — the OKF concept ID,
    /// e.g. "tables/users". Reserved files use "index", "guides/index", "log".
    var path: String = ""
    var kindRaw: String = KnowledgeDocKind.concept.rawValue

    // MARK: OKF frontmatter (concept kind only; empty for index/log)

    /// The required OKF `type` field.
    var typeName: String = "note"
    var title: String?
    /// The OKF `description` field (renamed: `description` collides with NSObject).
    var summary: String?
    /// The OKF `resource` URI, stored verbatim.
    var resource: String?
    var tags: [String] = []
    /// The OKF `timestamp` value kept as its verbatim ISO 8601 string, so
    /// export never reformats a date it didn't write.
    var timestampRaw: String?
    /// JSON-encoded `[OKFExtraField]`: unknown/custom frontmatter keys in
    /// original order, each as its verbatim YAML block.
    var extraFrontmatterJSON: String = "[]"

    /// Markdown body after the closing `---` (whole file for index/log).
    var body: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var bundle: KnowledgeBundle?

    init(
        path: String = "",
        kind: KnowledgeDocKind = .concept,
        typeName: String = "note",
        title: String? = nil,
        summary: String? = nil,
        resource: String? = nil,
        tags: [String] = [],
        timestampRaw: String? = nil,
        body: String = ""
    ) {
        self.id = UUID()
        self.path = path
        self.kindRaw = kind.rawValue
        self.typeName = typeName
        self.title = title
        self.summary = summary
        self.resource = resource
        self.tags = tags
        self.timestampRaw = timestampRaw
        self.body = body
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var kind: KnowledgeDocKind {
        get { KnowledgeDocKind(rawValue: kindRaw) ?? .concept }
        set { kindRaw = newValue.rawValue }
    }

    var extraFields: [OKFExtraField] {
        get {
            guard let data = extraFrontmatterJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([OKFExtraField].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else {
                extraFrontmatterJSON = "[]"
                return
            }
            extraFrontmatterJSON = json
        }
    }

    // ISO8601DateFormatter is thread-safe; cache instead of per-access allocation.
    private static let isoFormatter = ISO8601DateFormatter()
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The current time in the exact format the app writes to `timestamp`.
    static func currentTimestampString() -> String {
        isoFormatter.string(from: .now)
    }

    /// Parsed `timestamp`, when the stored string is valid ISO 8601.
    var timestamp: Date? {
        guard let raw = timestampRaw else { return nil }
        return Self.isoFractionalFormatter.date(from: raw) ?? Self.isoFormatter.date(from: raw)
    }

    /// Display name: frontmatter title, else the last path component.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The file name this row maps to on export, e.g. "tables/users.md".
    var fileName: String { path + ".md" }
}
