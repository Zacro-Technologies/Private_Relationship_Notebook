import Foundation
import Testing
@testable import RelationshipCore

@Test func interactionRetentionPolicyIsEnforcedAtPersistenceBoundary() {
    let personID = UUID()
    let exact = Interaction(
        personID: personID,
        summary: "Short recap",
        commitment: "Follow up",
        finalContent: "Exact final message",
        transcriptRetention: .fullTranscript,
        rawTranscript: "Imported exact transcript",
        contentFidelity: .exactFromUserImport
    ).normalizedForRetention()

    #expect(exact.rawTranscript == "Imported exact transcript")
    #expect(exact.finalContent == "Exact final message")
    #expect(exact.effectiveContentFidelity == .exactFromUserImport)

    let summarized = Interaction(
        personID: personID,
        summary: "Short recap",
        commitment: "Follow up",
        finalContent: "Must not survive",
        transcriptRetention: .summaryAndCommitments,
        rawTranscript: "Must not survive",
        contentFidelity: .exactFromUserImport
    ).normalizedForRetention()

    #expect(summarized.rawTranscript == nil)
    #expect(summarized.finalContent == nil)
    #expect(summarized.contentFidelity == .summaryOnly)

    let metadataOnly = Interaction(
        personID: personID,
        summary: "Must not survive",
        commitment: "Must not survive",
        finalContent: "Must not survive",
        transcriptRetention: .metadataOnly,
        rawTranscript: "Must not survive",
        contentFidelity: .exactFromUserImport
    ).normalizedForRetention()

    #expect(metadataOnly.summary.isEmpty)
    #expect(metadataOnly.commitment.isEmpty)
    #expect(metadataOnly.rawTranscript == nil)
    #expect(metadataOnly.finalContent == nil)
    #expect(metadataOnly.contentFidelity == nil)
}

@Test func interactionParticipantNormalizationRemovesPrimaryAndDuplicates() {
    let primaryID = UUID()
    let additionalID = UUID()
    let normalized = Interaction(
        personID: primaryID,
        additionalParticipantIDs: [primaryID, additionalID, additionalID]
    ).normalizedForRetention()

    #expect(normalized.additionalParticipantIDs == [additionalID])
}

@MainActor
@Test func futureInteractionIsRejectedWithoutChangingRecency() {
    let store = NotebookStore(inMemory: true)
    let person = Person(displayName: "Ari")
    #expect(store.save(person))

    #expect(!store.save(Interaction(
        personID: person.id,
        occurredAt: Date.now.addingTimeInterval(3_600),
        status: .confirmed
    )))
    #expect(store.interactions.isEmpty)
    #expect(store.person(id: person.id)?.lastInteractionAt == nil)
    #expect(store.lastError != nil)
}

@MainActor
@Test func communicationEvidenceDrivesTruthfulStatusAndContactDate() throws {
    let store = NotebookStore(inMemory: true)
    let person = Person(displayName: "Ari")
    store.save(person)

    let start = Date(timeIntervalSince1970: 10_000_000)
    var ledger = CommunicationEvidenceLedger(
        channel: .messages,
        capabilities: [.canPrefillRecipient, .canPrefillText, .usesExternalDestination],
        suggestedAt: start
    )
    ledger = try ledger.applying(CommunicationEvidenceEvent(
        state: .composerOpened,
        occurredAt: start.addingTimeInterval(1),
        evidenceKind: .applicationObservation
    ))

    let interactionID = UUID()
    store.save(Interaction(
        id: interactionID,
        personID: person.id,
        occurredAt: start,
        status: .confirmed,
        generatedDraft: "Editable draft",
        transcriptRetention: .metadataOnly,
        communicationEvidence: ledger
    ))

    #expect(store.interactions.first?.status == .composerOpened)
    #expect(store.person(id: person.id)?.lastInteractionAt == nil)
    #expect(store.interactions.first?.effectiveContentFidelity == .finalContentUnknown)

    ledger = try ledger.applying(CommunicationEvidenceEvent(
        state: .userConfirmedSent,
        occurredAt: start.addingTimeInterval(2),
        evidenceKind: .userConfirmation
    ))
    store.save(Interaction(
        id: interactionID,
        personID: person.id,
        occurredAt: start,
        status: .composerOpened,
        generatedDraft: "Editable draft",
        transcriptRetention: .metadataOnly,
        communicationEvidence: ledger
    ))

    #expect(store.interactions.first?.status == .userConfirmedSent)
    #expect(store.person(id: person.id)?.lastInteractionAt == start)
    #expect(store.interactions.first?.finalContent == nil)
}

@Test func interactionDecodingRemainsCompatibleWithOlderArchives() throws {
    let original = Interaction(
        personID: UUID(),
        occurredAt: Date(timeIntervalSinceReferenceDate: 1234),
        summary: "Legacy archive"
    )
    let encoded = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    [
        "approximateDate", "direction", "rawTranscript", "contentFidelity",
        "communicationEvidence"
    ].forEach { object.removeValue(forKey: $0) }
    let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

    let decoded = try JSONDecoder().decode(Interaction.self, from: legacyData)
    #expect(decoded.id == original.id)
    #expect(decoded.summary == "Legacy archive")
    #expect(decoded.approximateDate == nil)
    #expect(decoded.direction == nil)
    #expect(decoded.communicationEvidence == nil)
}
