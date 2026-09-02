import Foundation
import Testing
@testable import RelationshipCore

private let receivedPublicationID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
private let receivedSubjectID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
private let receivedNameFieldID = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
private let receivedContactFieldID = UUID(uuidString: "40000000-0000-4000-8000-000000000004")!

private func makeReceivedSnapshot(
    version: Int = 1,
    cardVersionID: UUID = UUID(),
    name: String = "Aiko"
) throws -> SerializedProfileCardSnapshot {
    try ProfileCardSnapshotSerializer().serialize(ProfileCardSnapshotDraft(
        publicationID: receivedPublicationID,
        cardVersionID: cardVersionID,
        cardVersion: version,
        publishedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(version)),
        advisoryExpiresAt: Date(timeIntervalSince1970: 1_900_000_000),
        retentionIntent: .askRecipientToDeleteAfterExpiry,
        fields: [
            ProfileSnapshotFieldDraft(
                id: receivedNameFieldID,
                key: ShareableProfileFieldKey.preferredName.rawValue,
                value: .text(name),
                audience: .friends
            ),
            ProfileSnapshotFieldDraft(
                id: receivedContactFieldID,
                key: ShareableProfileFieldKey.contactMethod.rawValue,
                value: .contact(channel: .email, value: "aiko@example.com", label: "School"),
                audience: .professional
            )
        ]
    ))
}

@Test func receivedProfilePlannerValidatesExactBytesAndSelectedFields() throws {
    let document = try makeReceivedSnapshot()
    var object = try #require(
        JSONSerialization.jsonObject(with: document.data) as? [String: Any]
    )
    object["private_notes"] = "must never import"
    let tamperedBytes = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ProfileCardSnapshotError.unexpectedPayloadKey("private_notes")) {
        _ = try ReceivedProfileSnapshotImportPlanner().inspect(
            exactPayloadBytes: tamperedBytes
        )
    }

    let bundle = try ReceivedProfileSnapshotImportPlanner().plan(
        exactPayloadBytes: document.data,
        selectedFieldIDs: [receivedNameFieldID, receivedContactFieldID],
        subjectID: receivedSubjectID,
        originalFilename: "aiko.relationship-profile.json",
        importedAt: Date(timeIntervalSince1970: 1_850_000_000)
    )
    #expect(bundle.assertionsToCreate.count == 2)
    #expect(bundle.assertionsToCreate.allSatisfy { $0.subjectID == receivedSubjectID })
    #expect(bundle.assertionsToCreate.allSatisfy { $0.origin == .remoteSelf })
    #expect(bundle.assertionsToCreate.allSatisfy { $0.usePolicy.ai == .deny })
    #expect(bundle.assertionsToCreate.allSatisfy { $0.sourceID == bundle.sourceToCreate?.id })

    let digest = ServiceDigest.sha256Hex(document.data)
    let name = try #require(bundle.assertionsToCreate.first {
        $0.remoteSelfProfileProvenance?.fieldID == receivedNameFieldID
    })
    #expect(name.value == .text("Aiko"))
    #expect(name.remoteSelfProfileProvenance?.publicationID == receivedPublicationID)
    #expect(name.remoteSelfProfileProvenance?.exactPayloadSHA256 == digest)
    #expect(name.remoteSelfProfileProvenance?.fieldAudience == .friends)
    #expect(name.remoteSelfProfileProvenance?.retentionIntent == .askRecipientToDeleteAfterExpiry)
    #expect(name.remoteSelfProfileProvenance?.advisoryExpiresAt != nil)

    let contact = try #require(bundle.assertionsToCreate.first {
        $0.remoteSelfProfileProvenance?.fieldID == receivedContactFieldID
    })
    #expect(contact.value == .text("School · email · aiko@example.com"))
}

@Test func receivedProfilePlannerIsIdempotentForExactReimport() throws {
    let document = try makeReceivedSnapshot()
    let planner = ReceivedProfileSnapshotImportPlanner()
    let first = try planner.plan(
        exactPayloadBytes: document.data,
        selectedFieldIDs: [receivedNameFieldID],
        subjectID: receivedSubjectID,
        importedAt: Date(timeIntervalSince1970: 1_850_000_000)
    )
    let second = try planner.plan(
        exactPayloadBytes: document.data,
        selectedFieldIDs: [receivedNameFieldID],
        subjectID: receivedSubjectID,
        existingAssertions: first.assertionsToCreate,
        existingSources: [try #require(first.sourceToCreate)],
        importedAt: Date(timeIntervalSince1970: 1_950_000_000)
    )

    #expect(!second.hasChanges)
    #expect(second.sourceToCreate == nil)
    #expect(second.assertionsToCreate.isEmpty)
    #expect(second.alreadyImportedFieldIDs == [receivedNameFieldID])
}

@Test func laterReceivedProfileVersionSupersedesOnlySamePublicationAndField() throws {
    let planner = ReceivedProfileSnapshotImportPlanner()
    let firstDocument = try makeReceivedSnapshot(
        version: 1,
        cardVersionID: UUID(uuidString: "50000000-0000-4000-8000-000000000005")!
    )
    let first = try planner.plan(
        exactPayloadBytes: firstDocument.data,
        selectedFieldIDs: [receivedNameFieldID],
        subjectID: receivedSubjectID
    )
    let prior = try #require(first.assertionsToCreate.first)
    let manual = try AssertionEnvelope(
        subjectID: receivedSubjectID,
        predicateID: prior.predicateID,
        value: .text("Manual name")
    )
    let otherPublication = try AssertionEnvelope(
        subjectID: receivedSubjectID,
        predicateID: prior.predicateID,
        value: .text("Other publication"),
        sourceID: UUID(),
        origin: .remoteSelf,
        remoteSelfProfileProvenance: RemoteSelfProfileProvenance(
            publicationID: UUID(),
            cardVersionID: UUID(),
            cardVersion: 99,
            publishedAt: .now,
            fieldID: receivedNameFieldID,
            fieldKey: .preferredName,
            fieldAudience: .anyRecipient,
            exactPayloadSHA256: String(repeating: "a", count: 64),
            authorshipIsUnverified: true,
            advisoryExpiresAt: nil,
            retentionIntent: .recipientMayRetain
        )
    )
    let secondDocument = try makeReceivedSnapshot(
        version: 2,
        cardVersionID: UUID(uuidString: "60000000-0000-4000-8000-000000000006")!,
        name: "Aiko Tanaka"
    )
    let second = try planner.plan(
        exactPayloadBytes: secondDocument.data,
        selectedFieldIDs: [receivedNameFieldID],
        subjectID: receivedSubjectID,
        existingAssertions: [manual, otherPublication, prior],
        existingSources: [try #require(first.sourceToCreate)]
    )

    #expect(try #require(second.assertionsToCreate.first).supersedesID == prior.id)
}

@Test @MainActor func canonicalStoreCommitsReceivedProfileIdempotentlyAndKeepsVersionsImmutable() throws {
    let persistence = PersistenceController(inMemory: true)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let document = try makeReceivedSnapshot()
    let bundle = try ReceivedProfileSnapshotImportPlanner().plan(
        exactPayloadBytes: document.data,
        selectedFieldIDs: [receivedNameFieldID],
        subjectID: receivedSubjectID
    )

    #expect(try canonical.importReceivedProfileSnapshot(bundle))
    #expect(canonical.assertions.count == 1)
    #expect(canonical.sources.count == 1)
    #expect(try !canonical.importReceivedProfileSnapshot(bundle))
    #expect(canonical.assertions.count == 1)

    canonical.saveProfileSnapshot(document.payload)
    var conflicting = document.payload
    conflicting.fields[0].value = .text("Changed in place")
    canonical.saveProfileSnapshot(conflicting)
    #expect(canonical.lastError != nil)
    #expect(canonical.profileSnapshots == [document.payload])
}

@Test @MainActor func receivedProfileAndNewPersonCommitAtomically() throws {
    let persistence = PersistenceController(inMemory: true)
    let notebook = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let document = try makeReceivedSnapshot()
    let person = Person(id: receivedSubjectID, displayName: "Aiko")
    let bundle = try ReceivedProfileSnapshotImportPlanner().plan(
        exactPayloadBytes: document.data,
        selectedFieldIDs: [receivedNameFieldID, receivedContactFieldID],
        subjectID: person.id
    )

    #expect(try notebook.commitReceivedProfileSnapshot(bundle, creating: person))
    canonical.reload()
    #expect(notebook.person(id: person.id) == person)
    #expect(canonical.sources.count == 1)
    #expect(canonical.assertions.count == 2)

    #expect(try !notebook.commitReceivedProfileSnapshot(bundle))
    canonical.reload()
    #expect(canonical.sources.count == 1)
    #expect(canonical.assertions.count == 2)
}

@Test @MainActor func receivedProfilePortraitMetadataAndBytesCommitAtomically() throws {
    let persistence = PersistenceController(inMemory: true)
    let notebook = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let document = try makeReceivedSnapshot()
    let person = Person(id: receivedSubjectID, displayName: "Aiko")
    let bundle = try ReceivedProfileSnapshotImportPlanner().plan(
        exactPayloadBytes: document.data,
        selectedFieldIDs: [receivedNameFieldID],
        subjectID: person.id
    )
    let portraitBytes = Data("sanitized-profile-portrait".utf8)
    let portraitAsset = PortraitMediaAsset(
        personID: person.id,
        sha256: ServiceDigest.sha256Hex(portraitBytes),
        byteCount: Int64(portraitBytes.count),
        pixelWidth: 1,
        pixelHeight: 1,
        isPrimary: true
    )

    #expect(try notebook.commitReceivedProfileSnapshot(
        bundle,
        creating: person,
        portrait: SanitizedPortrait(asset: portraitAsset, data: portraitBytes)
    ))
    canonical.reload()
    let savedPortrait = try #require(canonical.portraits(for: person.id).first)
    #expect(savedPortrait.id == portraitAsset.id)
    #expect(savedPortrait.personID == person.id)
    #expect(savedPortrait.sha256 == portraitAsset.sha256)
    #expect(savedPortrait.byteCount == portraitAsset.byteCount)
    #expect(savedPortrait.metadataWasStripped)
    #expect(try canonical.mediaPayloads.synchronizedData(for: savedPortrait) == portraitBytes)
}

@Test @MainActor func receivedProfileFailureRollsBackEveryStagedRecord() throws {
    let persistence = PersistenceController(inMemory: true)
    let notebook = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let document = try makeReceivedSnapshot()
    let person = Person(id: receivedSubjectID, displayName: "Aiko")
    let bundle = try ReceivedProfileSnapshotImportPlanner().plan(
        exactPayloadBytes: document.data,
        selectedFieldIDs: [receivedNameFieldID],
        subjectID: person.id
    )

    let markers = SynchronizedDeletionMarkerRepository(persistence: persistence)
    _ = try markers.mark([.person(person.id)])
    try persistence.container.viewContext.save()

    #expect(throws: SynchronizedDeletionMarkerError.self) {
        try notebook.commitReceivedProfileSnapshot(bundle, creating: person)
    }
    canonical.reload()
    #expect(notebook.person(id: person.id) == nil)
    #expect(canonical.sources.isEmpty)
    #expect(canonical.assertions.isEmpty)
}

@Test @MainActor func canonicalReceivedProfileCommitRollsBackSourceWhenAnAssertionFails() throws {
    let persistence = PersistenceController(inMemory: true)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let document = try makeReceivedSnapshot()
    let bundle = try ReceivedProfileSnapshotImportPlanner().plan(
        exactPayloadBytes: document.data,
        selectedFieldIDs: [receivedNameFieldID],
        subjectID: receivedSubjectID
    )
    let assertionID = try #require(bundle.assertionsToCreate.first?.id)
    let markers = SynchronizedDeletionMarkerRepository(persistence: persistence)
    _ = try markers.mark([.vaultRecord(id: assertionID, kind: "assertion")])
    try persistence.container.viewContext.save()

    #expect(throws: SynchronizedDeletionMarkerError.self) {
        try canonical.importReceivedProfileSnapshot(bundle)
    }
    #expect(
        try canonical.records.fetch(SourceArtifact.self, kind: "source").isEmpty
    )
    #expect(
        try canonical.records.fetch(AssertionEnvelope.self, kind: "assertion").isEmpty
    )
}

@Test func assertionEnvelopeDecodesWithoutRemoteProfileProvenance() throws {
    let assertion = try AssertionEnvelope(
        subjectID: receivedSubjectID,
        predicateID: "person.note",
        value: .text("Legacy")
    )
    let decoded = try JSONDecoder().decode(
        AssertionEnvelope.self,
        from: JSONEncoder().encode(assertion)
    )
    #expect(decoded.remoteSelfProfileProvenance == nil)
}
