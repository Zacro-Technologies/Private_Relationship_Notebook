import Foundation
import Testing
@testable import RelationshipCore

@Test func textImportReviewLifecycleRoundTripsCompleteResumeState() throws {
    let targetID = UUID()
    let portraitPersonID = UUID()
    let portraitConfirmedAt = Date(timeIntervalSince1970: 75)
    let aiReturnedAt = Date(timeIntervalSince1970: 80)
    let source = TextImportSourceArtifact(kind: .plainTextFile, originalFilename: "people.txt", text: "Mina")
    var review = try DeterministicTextImportPipeline().extract(from: source)
    let candidate = try #require(review.candidates.first)
    review.workflow = TextImportWorkflowState(
        lifecycle: .pending,
        savedAt: Date(timeIntervalSince1970: 100),
        sourceArtifactKind: .other,
        sourceRetention: .keepOriginal,
        candidateDecisions: [TextImportCandidateDecisionSnapshot(
            candidateID: candidate.id,
            displayName: "Mina S.",
            disposition: .addToExisting,
            targetPersonID: targetID,
            selectedAssertionIDs: Set(candidate.assertions.map(\.id))
        )],
        sourceUnits: [.init(
            id: UUID(),
            index: 0,
            text: "Mina",
            usedOCR: true,
            ocrConfidence: 0.83
        )],
        retainedSource: RetainedTextImportSource(
            contentType: "text/plain",
            filename: "people.txt",
            sha256: ServiceDigest.sha256Hex(Data("Mina".utf8)),
            data: Data("Mina".utf8)
        ),
        conversation: .init(
            shouldCreateInteraction: true,
            occurredAt: Date(timeIntervalSince1970: 50),
            transcriptRetention: .fullTranscript
        ),
        portrait: .init(
            shouldProposeFirstImageAsPortrait: true,
            confirmedPersonID: portraitPersonID,
            confirmedAt: portraitConfirmedAt
        ),
        aiProposal: .init(
            originSourceSHA256: String(repeating: "a", count: 64),
            modelOutputSHA256: String(repeating: "b", count: 64),
            returnedAt: aiReturnedAt,
            providerDisclosure: "Configured Shortcut returned this proposal."
        )
    )

    let decoded = try JSONDecoder().decode(
        TextImportReview.self,
        from: JSONEncoder().encode(review)
    )
    #expect(decoded.isResumable)
    #expect(decoded.workflow?.candidateDecisions.first?.targetPersonID == targetID)
    #expect(decoded.workflow?.retainedSource?.data == Data("Mina".utf8))
    #expect(decoded.workflow?.conversation?.shouldCreateInteraction == true)
    #expect(decoded.workflow?.portrait?.confirmedPersonID == portraitPersonID)
    #expect(decoded.workflow?.portrait?.confirmedAt == portraitConfirmedAt)
    #expect(decoded.workflow?.aiProposal?.originSourceSHA256 == String(repeating: "a", count: 64))
    #expect(decoded.workflow?.aiProposal?.modelOutputSHA256 == String(repeating: "b", count: 64))
    #expect(decoded.workflow?.aiProposal?.returnedAt == aiReturnedAt)
}

@Test func legacyTextImportReviewIsCompletedRatherThanPhantomPending() throws {
    let source = TextImportSourceArtifact(kind: .pastedText, text: "Kai")
    let review = try DeterministicTextImportPipeline().extract(from: source)
    let decoded = try JSONDecoder().decode(
        TextImportReview.self,
        from: JSONEncoder().encode(review)
    )
    #expect(decoded.workflow == nil)
    #expect(!decoded.isResumable)
}

@Test func archiveReviewAppliesOnlyExplicitPersonFields() throws {
    let id = UUID()
    var existing = Person(id: id, displayName: "Ari", role: "Designer", privateNote: "keep me")
    existing.modifiedAt = Date(timeIntervalSince1970: 10)
    var incoming = existing
    incoming.role = "Researcher"
    incoming.privateNote = "incoming private note"
    incoming.modifiedAt = Date(timeIntervalSince1970: 20)
    let update = ArchivePersonUpdate(existing: existing, incoming: incoming, direction: .incomingIsNewer)
    let plan = ArchiveImportPlan(
        archiveSHA256: "digest",
        idempotencyKey: UUID(),
        schemaVersion: 1,
        exportedAt: .now,
        peopleToCreate: [],
        personUpdates: [update],
        unchangedPersonIDs: [],
        interactionsToCreate: [],
        interactionConflicts: [],
        unchangedInteractionIDs: [],
        issues: []
    )
    var selection = ArchiveImportReviewSelection.proposed(plan: plan, existingPeople: [existing])
    selection.selectedPersonUpdateFields[id] = [.role]

    let result = try ArchiveImportReviewEngine().review(
        archive: NotebookArchive(people: [incoming], interactions: []),
        plan: plan,
        existingPeople: [existing],
        selection: selection,
        reviewedAt: Date(timeIntervalSince1970: 30)
    )
    let person = try #require(result.archive.people.first)
    #expect(person.role == "Researcher")
    #expect(person.privateNote == "keep me")
    #expect(person.modifiedAt == Date(timeIntervalSince1970: 30))
}

@Test func archiveReviewRequiresExplicitSameNameDecision() throws {
    let existing = Person(displayName: "Ren")
    let incoming = Person(displayName: "Ｒｅｎ")
    let plan = ArchiveImportPlan(
        archiveSHA256: "digest",
        idempotencyKey: UUID(),
        schemaVersion: 1,
        exportedAt: .now,
        peopleToCreate: [incoming],
        personUpdates: [],
        unchangedPersonIDs: [],
        interactionsToCreate: [],
        interactionConflicts: [],
        unchangedInteractionIDs: [],
        issues: []
    )
    let selection = ArchiveImportReviewSelection.proposed(plan: plan, existingPeople: [existing])
    #expect(selection.unresolvedSameNamePersonIDs == [incoming.id])
    #expect(throws: ArchiveImportReviewError.self) {
        _ = try ArchiveImportReviewEngine().review(
            archive: NotebookArchive(people: [incoming], interactions: []),
            plan: plan,
            existingPeople: [existing],
            selection: selection
        )
    }
}

@Test func embeddedPortraitBytesAreChecksumBoundToExactProfilePayload() throws {
    let data = Data("sanitized-jpeg".utf8)
    let digest = ServiceDigest.sha256Hex(data)
    let fieldID = UUID()
    let mediaID = UUID()
    let draft = ProfileCardSnapshotDraft(
        cardVersion: 1,
        fields: [ProfileSnapshotFieldDraft(
            id: fieldID,
            key: ShareableProfileFieldKey.portrait.rawValue,
            value: .sanitizedMedia(
                mediaID: mediaID,
                contentType: "image/jpeg",
                sha256: digest,
                byteCount: data.count,
                metadataStripped: true
            )
        )],
        embeddedMedia: [ProfileSnapshotEmbeddedMedia(
            fieldID: fieldID,
            mediaID: mediaID,
            contentType: "image/jpeg",
            sha256: digest,
            data: data
        )]
    )
    let serialized = try ProfileCardSnapshotSerializer().serialize(draft)
    #expect(serialized.payload.embeddedMedia?.first?.data == data)

    var tampered = serialized.payload
    tampered.embeddedMedia?[0].data = Data("different".utf8)
    #expect(throws: ProfileCardSnapshotError.self) {
        _ = try ProfileCardSnapshotSerializer().canonicalBytes(for: tampered)
    }
}

@Test func profileQRCodeRoundTripsExactBytesAndRejectsOversizePayload() throws {
    let bytes = Data("{\"profile\":true}".utf8)
    let codec = ProfileSnapshotQRCodeCodec(maximumPayloadBytes: 100)
    #expect(try codec.exactPayloadBytes(from: codec.message(for: bytes)) == bytes)
    #expect(throws: ProfileSnapshotQRCodeError.payloadTooLarge) {
        _ = try ProfileSnapshotQRCodeCodec(maximumPayloadBytes: 2).message(for: bytes)
    }
}

@Test func typedStorageInventorySeparatesSensitivePayloadFamilies() throws {
    let source = TextImportSourceArtifact(kind: .pastedText, text: "source text")
    var review = try DeterministicTextImportPipeline().extract(from: source)
    review.workflow = TextImportWorkflowState(
        lifecycle: .pending,
        sourceArtifactKind: .pastedText,
        sourceRetention: .keepOriginal,
        candidateDecisions: [],
        retainedSource: .init(
            contentType: "text/plain",
            filename: nil,
            sha256: ServiceDigest.sha256Hex(Data("source text".utf8)),
            data: Data("source text".utf8)
        )
    )
    let interaction = Interaction(
        personID: nil,
        transcriptRetention: .fullTranscript,
        rawTranscript: "private transcript"
    )
    let inventory = VaultStorageInventoryBuilder().build(
        people: [],
        interactions: [interaction],
        canonical: CanonicalArchivePayload(textImportReviews: [review]),
        profileSnapshots: [],
        recentlyDeletedStructuredCount: 3
    )
    #expect(inventory.items.first { $0.category == .pendingImportReviews }?.recordCount == 1)
    #expect(inventory.items.first { $0.category == .retainedOriginalSources }?.byteCount == 11)
    #expect(inventory.items.first { $0.category == .interactionTranscripts }?.recordCount == 1)
    #expect(inventory.items.first { $0.category == .recentlyDeletedStructuredRecords }?.recordCount == 3)
}
