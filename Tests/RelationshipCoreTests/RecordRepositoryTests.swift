import Foundation
import Testing
@testable import RelationshipCore

private struct ExampleRecord: Codable, Equatable, Sendable {
    let title: String
}

private struct IncompatibleRecord: Codable, Equatable, Sendable {
    let count: Int
}

@Test @MainActor func recordRepositorySeparatesStoresAndSupportsRecovery() throws {
    let persistence = PersistenceController(inMemory: true)
    let repository = RecordRepository(persistence: persistence)
    let vaultID = UUID()
    let profileID = UUID()

    try repository.upsert(ExampleRecord(title: "Private"), id: vaultID, kind: "example", in: .vault)
    try repository.upsert(ExampleRecord(title: "Shared"), id: profileID, kind: "example", in: .ownedProfiles)

    #expect(try repository.fetch(ExampleRecord.self, kind: "example", from: .vault).map(\.value.title) == ["Private"])
    #expect(try repository.fetch(ExampleRecord.self, kind: "example", from: .ownedProfiles).map(\.value.title) == ["Shared"])

    try repository.softDelete(id: vaultID, kind: "example")
    #expect(try repository.fetch(ExampleRecord.self, kind: "example", from: .vault).isEmpty)
    #expect(try repository.fetch(ExampleRecord.self, kind: "example", from: .vault, includeDeleted: true).first?.deletedAt != nil)
    let deleted = try repository.deletedRecords()
    #expect(deleted.count == 1)
    #expect(deleted.first?.recordID == vaultID)
    #expect(deleted.first?.kind == "example")

    try repository.restore(id: vaultID, kind: "example")
    #expect(try repository.fetch(ExampleRecord.self, kind: "example", from: .vault).count == 1)
    #expect(try repository.deletedRecords().isEmpty)
}

@Test @MainActor func recordRepositoryReportsDecodeFailuresInsteadOfDroppingRecords() throws {
    let persistence = PersistenceController(inMemory: true)
    let repository = RecordRepository(persistence: persistence)
    try repository.upsert(ExampleRecord(title: "Preserve me"), id: UUID(), kind: "strict")

    #expect(throws: RecordRepositoryError.self) {
        try repository.fetch(IncompatibleRecord.self, kind: "strict")
    }
}
