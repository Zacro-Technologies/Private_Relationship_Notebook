import CoreData
import Foundation
import Testing
@testable import RelationshipCore

private struct RecoverableDeletionTestPayload: Codable, Equatable {
    var privateValue: String
}

@Test @MainActor func recoverableDeletionCheckpointCapturesEverySynchronizedSoftDeletedEntity() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let records = RecordRepository(persistence: persistence)
    let deletedAt = Date(timeIntervalSince1970: 1_760_000_000)

    var person = Person(displayName: "Deleted private person", privateNote: "preserve")
    store.save(person)

    let interaction = Interaction(
        personID: person.id,
        summary: "Deleted private interaction",
        deletedAt: deletedAt
    )
    store.save(interaction)
    person.deletedAt = deletedAt
    person.modifiedAt = deletedAt
    store.save(person)

    let canonicalID = UUID()
    try records.upsert(
        RecoverableDeletionTestPayload(privateValue: "canonical"),
        id: canonicalID,
        kind: "recoverableTest"
    )
    try records.softDelete(id: canonicalID, kind: "recoverableTest", now: deletedAt)

    let profileID = UUID()
    try records.upsert(
        RecoverableDeletionTestPayload(privateValue: "profile"),
        id: profileID,
        kind: "recoverableProfile",
        in: .ownedProfiles
    )
    try records.softDelete(
        id: profileID,
        kind: "recoverableProfile",
        in: .ownedProfiles,
        now: deletedAt
    )

    let mediaID = UUID()
    try insertRecoverableRawRecord(
        persistence: persistence,
        entityName: "MediaPayloadEntity",
        id: mediaID,
        payload: Data("private portrait bytes".utf8),
        deletedAt: deletedAt
    )
    try insertRecoverableRawRecord(
        persistence: persistence,
        entityName: "CanonicalRecordEntity",
        id: UUID(),
        kind: SynchronizedDeletionMarkerRepository.markerKindPrefix + "person",
        payload: Data("must not enter checkpoint".utf8),
        deletedAt: deletedAt
    )

    let state = try SynchronizedDeletionMarkerRepository(persistence: persistence).durableState()
    let checkpoint = try RecoverableDeletionCheckpointRepository(persistence: persistence)
        .capture(sourceDurableState: state)

    #expect(checkpoint.rows.count == 5)
    #expect(Set(checkpoint.rows.map(\.key.entity)) == Set(RecoverableDeletionEntity.allCases))
    #expect(checkpoint.rows.allSatisfy { row in
        guard row.key.entity == .canonicalRecord else { return true }
        return row.key.kind == "recoverableTest"
    })

    let encoded = try JSONEncoder().encode(checkpoint)
    let decoded = try JSONDecoder().decode(RecoverableDeletionCheckpoint.self, from: encoded)
    #expect(decoded == checkpoint)
}

@Test @MainActor func recoverableDeletionImportIsCreateOnlyAndVerifiesExactRows() throws {
    let source = PersistenceController(inMemory: true)
    let sourceStore = NotebookStore(persistence: source)
    let deletedAt = Date(timeIntervalSince1970: 1_761_000_000)
    var person = Person(
        displayName: "Recoverable",
        privateNote: "encrypted private payload"
    )
    person.deletedAt = deletedAt
    person.modifiedAt = deletedAt
    sourceStore.save(person)
    let sourceState = try SynchronizedDeletionMarkerRepository(
        persistence: source
    ).durableState()
    let sourceRepository = RecoverableDeletionCheckpointRepository(persistence: source)
    let checkpoint = try sourceRepository.capture(sourceDurableState: sourceState)

    let destination = PersistenceController(inMemory: true)
    let destinationRepository = RecoverableDeletionCheckpointRepository(
        persistence: destination
    )
    let destinationState = try SynchronizedDeletionMarkerRepository(
        persistence: destination
    ).durableState()
    let plan = try destinationRepository.planImport(
        checkpoint,
        sourceDurableState: sourceState,
        destinationDurableState: destinationState
    )

    #expect(plan.rowsToCreate.map(\.key.id) == [person.id])
    #expect(plan.acceptedRecoverablePersonKeys == [plan.rowsToCreate[0].key])
    #expect(plan.acceptedRecoverablePersonIDs == [person.id])
    #expect(plan.acceptedRecoverablePersonCount == 1)
    #expect(plan.conflictingKeys.isEmpty)
    #expect(plan.blockedByDestinationDurableDeletionKeys.isEmpty)
    let verification = try destinationRepository.apply(
        plan,
        sourceDurableState: sourceState,
        destinationDurableState: destinationState
    )
    #expect(verification.isVerified)
    #expect(verification.verifiedImportedOrUnchangedKeys == [plan.rowsToCreate[0].key])

    let afterState = try SynchronizedDeletionMarkerRepository(
        persistence: destination
    ).durableState()
    let retryPlan = try destinationRepository.planImport(
        checkpoint,
        sourceDurableState: sourceState,
        destinationDurableState: afterState
    )
    #expect(retryPlan.rowsToCreate.isEmpty)
    #expect(retryPlan.unchangedKeys == [plan.rowsToCreate[0].key])

    let request = NSFetchRequest<NSManagedObject>(entityName: "PersonEntity")
    let imported = try #require(destination.container.viewContext.fetch(request).first)
    #expect(imported.value(forKey: "privateNote") as? String == "encrypted private payload")
    #expect(imported.value(forKey: "deletedAt") as? Date == deletedAt)
}

@Test @MainActor func recoverableDeletionImportNeverOverwritesSameStableKey() throws {
    let id = UUID()
    let deletedAt = Date(timeIntervalSince1970: 1_762_000_000)
    let source = PersistenceController(inMemory: true)
    try insertRecoverableRawRecord(
        persistence: source,
        entityName: "CanonicalRecordEntity",
        id: id,
        kind: "recoverableTest",
        payload: Data("source deleted value".utf8),
        deletedAt: deletedAt
    )
    let sourceState = try SynchronizedDeletionMarkerRepository(persistence: source).durableState()
    let checkpoint = try RecoverableDeletionCheckpointRepository(persistence: source)
        .capture(sourceDurableState: sourceState)

    let destination = PersistenceController(inMemory: true)
    try insertRecoverableRawRecord(
        persistence: destination,
        entityName: "CanonicalRecordEntity",
        id: id,
        kind: "recoverableTest",
        payload: Data("destination active value".utf8),
        deletedAt: nil
    )
    let destinationState = try SynchronizedDeletionMarkerRepository(
        persistence: destination
    ).durableState()
    let repository = RecoverableDeletionCheckpointRepository(persistence: destination)
    let plan = try repository.planImport(
        checkpoint,
        sourceDurableState: sourceState,
        destinationDurableState: destinationState
    )

    #expect(plan.rowsToCreate.isEmpty)
    #expect(plan.conflictingKeys == [checkpoint.rows[0].key])
    #expect(try repository.apply(
        plan,
        sourceDurableState: sourceState,
        destinationDurableState: destinationState
    ).isVerified)

    let request = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
    request.predicate = NSPredicate(format: "id == %@ AND kind == %@", id as CVarArg, "recoverableTest")
    let row = try #require(destination.container.viewContext.fetch(request).first)
    #expect(row.value(forKey: "payload") as? Data == Data("destination active value".utf8))
    #expect(row.value(forKey: "deletedAt") == nil)
}

@Test @MainActor func recoverableDeletionImportBlocksRowsMissingDestinationWipeEpoch() throws {
    let id = UUID()
    let deletedAt = Date(timeIntervalSince1970: 1_763_000_000)
    let source = PersistenceController(inMemory: true)
    try insertRecoverableRawRecord(
        persistence: source,
        entityName: "PersonEntity",
        id: id,
        deletedAt: deletedAt
    )
    let sourceState = try SynchronizedDeletionMarkerRepository(persistence: source).durableState()
    let checkpoint = try RecoverableDeletionCheckpointRepository(persistence: source)
        .capture(sourceDurableState: sourceState)

    let destination = PersistenceController(inMemory: true)
    let epoch = UUID()
    let destinationMarkers = SynchronizedDeletionMarkerRepository(persistence: destination)
    _ = try destinationMarkers.stage(DurableDeletionState(wipeEpochIDs: [epoch]))
    try destination.container.viewContext.save()
    let destinationState = try destinationMarkers.durableState()
    let repository = RecoverableDeletionCheckpointRepository(persistence: destination)
    let plan = try repository.planImport(
        checkpoint,
        sourceDurableState: sourceState,
        destinationDurableState: destinationState
    )

    #expect(plan.rowsToCreate.isEmpty)
    #expect(plan.blockedByDestinationDurableDeletionKeys == [checkpoint.rows[0].key])
    #expect(plan.expectedAbsentKeys == [checkpoint.rows[0].key])
    #expect(try repository.apply(
        plan,
        sourceDurableState: sourceState,
        destinationDurableState: destinationState
    ).isVerified)

    let people = try destination.container.viewContext.fetch(
        NSFetchRequest<NSManagedObject>(entityName: "PersonEntity")
    )
    #expect(people.isEmpty)
}

@Test @MainActor func recoverableDeletionImportBlocksExplicitDestinationDeletionMarker() throws {
    let id = UUID()
    let deletedAt = Date(timeIntervalSince1970: 1_763_500_000)
    let source = PersistenceController(inMemory: true)
    try insertRecoverableRawRecord(
        persistence: source,
        entityName: "CanonicalRecordEntity",
        id: id,
        kind: "recoverableTest",
        payload: Data("must remain deleted".utf8),
        deletedAt: deletedAt
    )
    let sourceState = try SynchronizedDeletionMarkerRepository(persistence: source).durableState()
    let checkpoint = try RecoverableDeletionCheckpointRepository(persistence: source)
        .capture(sourceDurableState: sourceState)

    let destination = PersistenceController(inMemory: true)
    let target = DurableDeletionTarget.vaultRecord(id: id, kind: "recoverableTest")
    let markers = SynchronizedDeletionMarkerRepository(persistence: destination)
    _ = try markers.stage(DurableDeletionState(targets: [target]))
    try destination.container.viewContext.save()
    let destinationState = try markers.durableState()
    let repository = RecoverableDeletionCheckpointRepository(persistence: destination)
    let plan = try repository.planImport(
        checkpoint,
        sourceDurableState: sourceState,
        destinationDurableState: destinationState
    )

    #expect(plan.rowsToCreate.isEmpty)
    #expect(plan.blockedByDestinationDurableDeletionKeys == [checkpoint.rows[0].key])
    #expect(try repository.apply(
        plan,
        sourceDurableState: sourceState,
        destinationDurableState: destinationState
    ).isVerified)
    let request = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
    request.predicate = NSPredicate(format: "kind == %@", "recoverableTest")
    #expect(try destination.container.viewContext.fetch(request).isEmpty)
}

@Test @MainActor func recoverableDeletionPlanRequiresSourceControlsAppliedMarkerFirst() throws {
    let sourceState = DurableDeletionState(
        targets: [.person(UUID())],
        wipeEpochIDs: [UUID()]
    )
    let destination = PersistenceController(inMemory: true)
    let destinationState = try SynchronizedDeletionMarkerRepository(
        persistence: destination
    ).durableState()
    let repository = RecoverableDeletionCheckpointRepository(persistence: destination)

    #expect(throws: RecoverableDeletionCheckpointError.self) {
        try repository.planImport(
            RecoverableDeletionCheckpoint(),
            sourceDurableState: sourceState,
            destinationDurableState: destinationState
        )
    }
    #expect(!(RecoverableDeletionCheckpointError
        .sourceDurableStateNotAppliedToDestination(sourceState.wipeEpochIDs)
        .localizedDescription.isEmpty))
}

@Test @MainActor func recoverableDeletionPreflightFindsPostControlBlockerBeforeMutation() throws {
    let source = PersistenceController(inMemory: true)
    let sourceStore = NotebookStore(persistence: source)
    var person = Person(displayName: "Recoverable before destination wipe")
    person.deletedAt = Date(timeIntervalSince1970: 1_763_750_000)
    person.modifiedAt = person.deletedAt!
    #expect(sourceStore.save(person))
    let unrelatedDeletion = DurableDeletionTarget.interaction(UUID())
    let sourceMarkers = SynchronizedDeletionMarkerRepository(persistence: source)
    _ = try sourceMarkers.stage(DurableDeletionState(targets: [unrelatedDeletion]))
    try source.container.viewContext.save()
    let sourceState = try sourceMarkers.durableState()
    let checkpoint = try RecoverableDeletionCheckpointRepository(persistence: source)
        .capture(sourceDurableState: sourceState)

    let destination = PersistenceController(inMemory: true)
    let destinationMarkers = SynchronizedDeletionMarkerRepository(persistence: destination)
    let destinationEpoch = UUID()
    _ = try destinationMarkers.stage(DurableDeletionState(
        wipeEpochIDs: [destinationEpoch]
    ))
    try destination.container.viewContext.save()
    let destinationState = try destinationMarkers.durableState()
    let projectedState = DurableDeletionState(
        targets: destinationState.targets.union(sourceState.targets),
        wipeEpochIDs: destinationState.wipeEpochIDs.union(sourceState.wipeEpochIDs)
    )
    let repository = RecoverableDeletionCheckpointRepository(persistence: destination)

    let preflight = try repository.preflightImport(
        checkpoint,
        sourceDurableState: sourceState,
        projectedDestinationDurableState: projectedState,
        removingDestinationTargets: []
    )

    #expect(preflight.rowsToCreate.isEmpty)
    #expect(preflight.blockedByDestinationDurableDeletionKeys == [checkpoint.rows[0].key])
    #expect(preflight.requiresAttention)
    #expect(throws: RecoverableDeletionCheckpointError.self) {
        try repository.planImport(
            checkpoint,
            sourceDurableState: sourceState,
            destinationDurableState: destinationState
        )
    }
    #expect(try destinationMarkers.targets().isEmpty)
}

@Test @MainActor func captureExcludesSoftDeletedRowsPredatingSourceWipeEpoch() throws {
    let source = PersistenceController(inMemory: true)
    try insertRecoverableRawRecord(
        persistence: source,
        entityName: "PersonEntity",
        id: UUID(),
        deletedAt: Date(timeIntervalSince1970: 1_764_000_000)
    )
    let markers = SynchronizedDeletionMarkerRepository(persistence: source)
    _ = try markers.stage(DurableDeletionState(wipeEpochIDs: [UUID()]))
    try source.container.viewContext.save()
    let sourceState = try markers.durableState()

    let checkpoint = try RecoverableDeletionCheckpointRepository(persistence: source)
        .capture(sourceDurableState: sourceState)
    #expect(checkpoint.isEmpty)
}

@Test @MainActor func portraitMetadataConflictPreventsPartialDeletedPayloadImport() throws {
    let id = UUID()
    let deletedAt = Date(timeIntervalSince1970: 1_765_000_000)
    let source = PersistenceController(inMemory: true)
    try insertRecoverableRawRecord(
        persistence: source,
        entityName: "CanonicalRecordEntity",
        id: id,
        kind: "portraitMedia",
        payload: Data("deleted metadata".utf8),
        deletedAt: deletedAt
    )
    try insertRecoverableRawRecord(
        persistence: source,
        entityName: "MediaPayloadEntity",
        id: id,
        payload: Data("deleted bytes".utf8),
        deletedAt: deletedAt
    )
    let sourceState = try SynchronizedDeletionMarkerRepository(persistence: source).durableState()
    let checkpoint = try RecoverableDeletionCheckpointRepository(persistence: source)
        .capture(sourceDurableState: sourceState)

    let destination = PersistenceController(inMemory: true)
    try insertRecoverableRawRecord(
        persistence: destination,
        entityName: "CanonicalRecordEntity",
        id: id,
        kind: "portraitMedia",
        payload: Data("active destination metadata".utf8),
        deletedAt: nil
    )
    let destinationState = try SynchronizedDeletionMarkerRepository(
        persistence: destination
    ).durableState()
    let repository = RecoverableDeletionCheckpointRepository(persistence: destination)
    let plan = try repository.planImport(
        checkpoint,
        sourceDurableState: sourceState,
        destinationDurableState: destinationState
    )

    #expect(plan.rowsToCreate.isEmpty)
    #expect(plan.conflictingKeys == Set(checkpoint.rows.map(\.key)))
    #expect(try repository.apply(
        plan,
        sourceDurableState: sourceState,
        destinationDurableState: destinationState
    ).isVerified)
    let payloads = try destination.container.viewContext.fetch(
        NSFetchRequest<NSManagedObject>(entityName: "MediaPayloadEntity")
    )
    #expect(payloads.isEmpty)
}

@MainActor
private func insertRecoverableRawRecord(
    persistence: PersistenceController,
    entityName: String,
    id: UUID,
    kind: String? = nil,
    payload: Data = Data(),
    deletedAt: Date?
) throws {
    let context = persistence.container.viewContext
    let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
    object.setValue(id, forKey: "id")
    if object.entity.attributesByName["kind"] != nil {
        object.setValue(kind ?? InteractionKind.message.rawValue, forKey: "kind")
    }
    if object.entity.attributesByName["payload"] != nil {
        object.setValue(payload, forKey: "payload")
    }
    if object.entity.attributesByName["contentHash"] != nil {
        object.setValue("test-hash", forKey: "contentHash")
    }
    if object.entity.attributesByName["displayName"] != nil {
        object.setValue("Deleted person", forKey: "displayName")
    }
    if object.entity.attributesByName["createdAt"] != nil {
        object.setValue(deletedAt ?? .now, forKey: "createdAt")
    }
    if object.entity.attributesByName["modifiedAt"] != nil {
        object.setValue(deletedAt ?? .now, forKey: "modifiedAt")
    }
    if object.entity.attributesByName["deletedAt"] != nil {
        object.setValue(deletedAt, forKey: "deletedAt")
    }
    try context.save()
}
