import Foundation
import SwiftData

/// A knowledge base in the Open Knowledge Format (OKF): a named collection of
/// markdown concept documents that agents can consult during a chat.
/// Maps 1:1 to an OKF bundle directory on import/export.
@Model
final class KnowledgeBundle {
    var id: UUID = UUID()
    /// Display name; also used as the folder name on export.
    var name: String = "New Bundle"
    /// Free-form user note about the bundle (not part of the OKF format).
    var about: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \KnowledgeConcept.bundle)
    var concepts: [KnowledgeConcept]? = []

    init(name: String = "New Bundle", about: String = "") {
        self.id = UUID()
        self.name = name
        self.about = about
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Concepts in stable path order.
    var orderedConcepts: [KnowledgeConcept] {
        (concepts ?? []).sorted { $0.path < $1.path }
    }

    /// Non-reserved concept documents (excludes index/log rows).
    var conceptDocuments: [KnowledgeConcept] {
        orderedConcepts.filter { $0.kind == .concept }
    }

    /// Count of non-reserved documents without the sort `conceptDocuments`
    /// pays — list rows render this on every sidebar refresh.
    var conceptCount: Int {
        (concepts ?? []).lazy.filter { $0.kind == .concept }.count
    }

    func concept(atPath path: String) -> KnowledgeConcept? {
        (concepts ?? []).first { $0.path == path }
    }
}
