import Foundation
import Testing
@testable import RelationshipCore

@Test @MainActor func activeArchiveReferencesCanUseAcceptedRecoverableRows() throws {
    let source = PersistenceController(inMemory: true)
    let sourceStore = NotebookStore(persistence: source)
    let sourceRecords = RecordRepository(persistence: source)
    let deletedAt = Date(timeIntervalSince1970: 1_780_000_000)

    var person = Person(displayName: "Recently deleted reference")
    sourceStore.save(person)
    let interaction = Interaction(
        personID: person.id,
        summary: "History retained while person is recoverable"
    )
    sourceStore.save(interaction)
    person.deletedAt = deletedAt
    person.modifiedAt = deletedAt
    sourceStore.save(person)

    let deletedContext = Context(
        kind: .community,
        names: LocalizedText("Recoverable context")
    )
    try sourceRecords.upsert(
        deletedContext,
        id: deletedContext.id,
        kind: "context"
    )
    try sourceRecords.softDelete(
        id: deletedContext.id,
        kind: "context",
        now: deletedAt
    )

    let archive = try sourceStore.exportArchive()
    let sourceState = try sourceStore.exportDurableDeletionState()
    let checkpoint = try RecoverableDeletionCheckpointRepository(
        persistence: source
    ).capture(sourceDurableState: sourceState)

    let destination = PersistenceController(inMemory: true)
    let destinationStore = NotebookStore(persistence: destination)
    let destinationState = try destinationStore.exportDurableDeletionState()
    let destinationRepository = RecoverableDeletionCheckpointRepository(
        persistence: destination
    )
    let destinationCheckpoint = try destinationRepository.capture(
        sourceDurableState: destinationState
    )
    let recoverablePlan = try destinationRepository.planImport(
        checkpoint,
        sourceDurableState: sourceState,
        destinationDurableState: destinationState
    )
    let closure = RecoverableDeletionReferenceClosure(
        destination: destinationCheckpoint,
        sourcePlan: recoverablePlan
    )

    #expect(closure.personIDs == [person.id])
    #expect(closure.canonical.contexts.map(\.id) == [deletedContext.id])

    let review = try ArchiveImportPlanner().inspect(
        ArchiveCodec.encode(archive),
        existingPeople: [],
        existingInteractions: [],
        existingCanonical: closure.merging(into: nil),
        additionalAvailablePersonIDs: closure.personIDs,
        additionalAvailableInteractionIDs: closure.interactionIDs,
        acceptIncomingPersonUpdates: false
    )
    #expect(!review.hasBlockingIssues)
    #expect(review.interactionsToCreate.map(\.id) == [interaction.id])
}
