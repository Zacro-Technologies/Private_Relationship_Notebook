import Foundation
import Testing
@testable import RelationshipCore

@MainActor
struct CanonicalFactWritePolicyTests {
    @Test func factPayloadCredentialDetectionRunsAtTheStoreBoundary() throws {
        let persistence = PersistenceController(inMemory: true)
        let notebook = NotebookStore(persistence: persistence)
        let canonical = CanonicalVaultStore(persistence: persistence)
        let person = Person(displayName: "Aiko")
        #expect(notebook.save(person))

        let assertion = try AssertionEnvelope(
            subjectID: person.id,
            predicateID: "custom.wifiDetails",
            value: .text("password: hunter2"),
            sensitivity: .highlySensitive,
            usePolicy: .restrictive
        )

        #expect(throws: CanonicalFactPolicyViolation.credentialLikeValue) {
            try canonical.saveFact(assertion)
        }
        #expect(canonical.assertions.isEmpty)
    }

    @Test func customFieldDefaultsAreAnAuthoritativeMaximumForFactWrites() throws {
        let persistence = PersistenceController(inMemory: true)
        let notebook = NotebookStore(persistence: persistence)
        let canonical = CanonicalVaultStore(persistence: persistence)
        let person = Person(displayName: "Mina")
        #expect(notebook.save(person))

        let definition = AttributeDefinition(
            predicateID: "custom.privateContext",
            labels: LocalizedText("Private context"),
            valueKind: .text,
            defaultSensitivity: .sensitive,
            defaultUsePolicy: .restrictive,
            capabilities: .init()
        )
        try canonical.saveAttributeDefinition(definition)

        let underclassified = try AssertionEnvelope(
            subjectID: person.id,
            predicateID: definition.predicateID,
            value: .text("Met through the alumni group"),
            sensitivity: .private,
            usePolicy: .restrictive
        )
        #expect(throws: CanonicalFactPolicyViolation.sensitivityBelowDefinitionDefault(
            predicateID: definition.predicateID
        )) {
            try canonical.saveFact(underclassified)
        }

        let overbroad = try AssertionEnvelope(
            subjectID: person.id,
            predicateID: definition.predicateID,
            value: .text("Met through the alumni group"),
            sensitivity: .sensitive,
            usePolicy: .init(search: .include)
        )
        #expect(throws: CanonicalFactPolicyViolation.usePolicyExceedsDefinition(
            predicateID: definition.predicateID
        )) {
            try canonical.saveFact(overbroad)
        }

        let allowed = try AssertionEnvelope(
            subjectID: person.id,
            predicateID: definition.predicateID,
            value: .text("Met through the alumni group"),
            sensitivity: .highlySensitive,
            usePolicy: .restrictive
        )
        try canonical.saveFact(allowed)
        #expect(canonical.assertions.map(\.id) == [allowed.id])
    }

    @Test func factWritesRejectMissingDeletedAndMergedSubjects() throws {
        let persistence = PersistenceController(inMemory: true)
        let notebook = NotebookStore(persistence: persistence)
        let canonical = CanonicalVaultStore(persistence: persistence)

        let missingID = UUID()
        let missing = try ordinaryAssertion(subjectID: missingID)
        #expect(throws: CanonicalFactSaveError.subjectIsNotActive(missingID)) {
            try canonical.saveFact(missing)
        }

        let deleted = Person(displayName: "Deleted")
        #expect(notebook.save(deleted))
        notebook.moveToRecentlyDeleted(deleted)
        let deletedAssertion = try ordinaryAssertion(subjectID: deleted.id)
        #expect(throws: CanonicalFactSaveError.subjectIsNotActive(deleted.id)) {
            try canonical.saveFact(deletedAssertion)
        }

        let source = Person(displayName: "Merged source")
        let destination = Person(displayName: "Survivor")
        #expect(notebook.save(source))
        #expect(notebook.save(destination))
        _ = try notebook.mergePeople(sourceID: source.id, into: destination.id)
        let mergedAssertion = try ordinaryAssertion(subjectID: source.id)
        #expect(throws: CanonicalFactSaveError.subjectIsNotActive(source.id)) {
            try canonical.saveFact(mergedAssertion)
        }

        let survivorAssertion = try ordinaryAssertion(subjectID: destination.id)
        try canonical.saveFact(survivorAssertion)
        #expect(canonical.assertions.map(\.id) == [survivorAssertion.id])
    }

    private func ordinaryAssertion(subjectID: UUID) throws -> AssertionEnvelope {
        try AssertionEnvelope(
            subjectID: subjectID,
            predicateID: "relationship.context",
            value: .text("Community organizer"),
            sensitivity: .private,
            usePolicy: .restrictive
        )
    }
}
