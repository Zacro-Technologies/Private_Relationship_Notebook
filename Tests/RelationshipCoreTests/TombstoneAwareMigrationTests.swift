import CryptoKit
import CoreData
import Foundation
import Testing
@testable import RelationshipCore

private final class PermanentDeletionCommitProbe: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var markerCount: Int
        var personCount: Int
    }

    private let personID: UUID
    private let markerKind: String
    private let lock = NSLock()
    private var storage: [Snapshot] = []

    init(personID: UUID, markerKind: String) {
        self.personID = personID
        self.markerKind = markerKind
    }

    var snapshots: [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ notification: Notification) {
        guard let context = notification.object as? NSManagedObjectContext else { return }
        let snapshot: Snapshot? = context.performAndWait {
            let markerRequest = NSFetchRequest<NSFetchRequestResult>(
                entityName: "CanonicalRecordEntity"
            )
            markerRequest.predicate = NSPredicate(
                format: "id == %@ AND kind == %@ AND deletedAt == nil",
                personID as CVarArg,
                markerKind
            )
            let personRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PersonEntity")
            personRequest.predicate = NSPredicate(format: "id == %@", personID as CVarArg)
            guard let markerCount = try? context.count(for: markerRequest),
                  let personCount = try? context.count(for: personRequest) else { return nil }
            return Snapshot(markerCount: markerCount, personCount: personCount)
        }
        guard let snapshot else { return }
        lock.lock()
        storage.append(snapshot)
        lock.unlock()
    }
}

@Test @MainActor func migrationDestinationInspectionSeparatesPayloadFreeTombstones() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let instant = Date(timeIntervalSince1970: 1_720_000_000)

    let activePerson = Person(displayName: "Active person")
    var deletedPerson = Person(displayName: "Deleted person")
    deletedPerson.deletedAt = instant
    deletedPerson.modifiedAt = instant
    store.save(activePerson)
    store.save(deletedPerson)

    let activeInteraction = Interaction(personID: activePerson.id, summary: "Active interaction")
    let deletedInteraction = Interaction(
        personID: nil,
        summary: "Deleted interaction payload must stay private",
        deletedAt: instant
    )
    store.save(activeInteraction)
    store.save(deletedInteraction)

    let activeContext = Context(kind: .project, names: LocalizedText("Active context"))
    let deletedContext = Context(kind: .community, names: LocalizedText("Deleted context"))
    canonical.save(activeContext)
    canonical.save(deletedContext)
    canonical.delete(deletedContext, kind: "context")

    let deletedPortrait = makeMigrationPortrait(personID: deletedPerson.id)
    canonical.save(deletedPortrait)
    canonical.deletePortrait(deletedPortrait.asset)

    let deletedProfile = makeMigrationProfileSnapshot()
    canonical.saveProfileSnapshot(deletedProfile)
    try canonical.records.softDelete(
        id: deletedProfile.cardVersionID,
        kind: "profileSnapshot",
        in: .ownedProfiles,
        now: instant
    )

    let inspection = try store.inspectMigrationDestination()
    let normalExport = try store.exportArchive()

    #expect(inspection.archive.people.map(\.id) == [activePerson.id])
    #expect(inspection.archive.interactions.map(\.id) == [activeInteraction.id])
    #expect(inspection.archive.canonical?.contexts.map(\.id) == [activeContext.id])
    #expect(inspection.archive.canonical?.portraitMedia?.isEmpty == true)
    #expect(inspection.archive.ownedProfileSnapshots?.isEmpty == true)
    #expect(normalExport.people.map(\.id) == [activePerson.id])
    #expect(normalExport.interactions.map(\.id) == [activeInteraction.id])

    #expect(inspection.tombstones.personIDs == [deletedPerson.id])
    #expect(inspection.tombstones.interactionIDs == [deletedInteraction.id])
    #expect(inspection.tombstones.structuredRecordIDs == [
        ArchiveStructuredRecordIdentity(family: .context, id: deletedContext.id),
        ArchiveStructuredRecordIdentity(family: .portraitMedia, id: deletedPortrait.asset.id),
        ArchiveStructuredRecordIdentity(family: .profileSnapshot, id: deletedProfile.cardVersionID),
    ])
}

@Test @MainActor func reviewedMigrationBlocksEveryActiveRowWhoseDestinationIsTombstoned() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let deletedAt = Date(timeIntervalSince1970: 1_730_000_000)
    let incomingAt = deletedAt.addingTimeInterval(600)

    var destinationPerson = Person(displayName: "Destination deletion")
    destinationPerson.deletedAt = deletedAt
    destinationPerson.modifiedAt = deletedAt
    store.save(destinationPerson)

    let destinationInteraction = Interaction(
        personID: nil,
        summary: "Destination deletion",
        deletedAt: deletedAt
    )
    store.save(destinationInteraction)

    let destinationContext = Context(
        kind: .community,
        names: LocalizedText("Destination deletion")
    )
    canonical.save(destinationContext)
    canonical.delete(destinationContext, kind: "context")

    let destinationPortrait = makeMigrationPortrait(
        id: UUID(),
        personID: destinationPerson.id,
        modifiedAt: deletedAt
    )
    canonical.save(destinationPortrait)
    canonical.deletePortrait(destinationPortrait.asset)

    let destinationProfile = makeMigrationProfileSnapshot(publishedAt: deletedAt)
    canonical.saveProfileSnapshot(destinationProfile)
    try canonical.records.softDelete(
        id: destinationProfile.cardVersionID,
        kind: "profileSnapshot",
        in: .ownedProfiles,
        now: deletedAt
    )

    let destination = try store.inspectMigrationDestination()
    var incomingPerson = Person(
        id: destinationPerson.id,
        displayName: "Incoming active edit",
        modifiedAt: incomingAt
    )
    incomingPerson.deletedAt = nil
    let incomingInteraction = Interaction(
        id: destinationInteraction.id,
        personID: nil,
        occurredAt: incomingAt,
        summary: "Incoming active edit"
    )
    let incomingContext = Context(
        id: destinationContext.id,
        kind: .community,
        names: LocalizedText("Incoming active edit"),
        createdAt: incomingAt,
        modifiedAt: incomingAt
    )
    var incomingPortraitAsset = destinationPortrait.asset
    incomingPortraitAsset.modifiedAt = incomingAt
    let incomingProfile = makeMigrationProfileSnapshot(
        publicationID: destinationProfile.publicationID,
        cardVersionID: destinationProfile.cardVersionID,
        publishedAt: incomingAt
    )
    let incomingArchive = NotebookArchive(
        people: [incomingPerson],
        interactions: [incomingInteraction],
        canonical: CanonicalArchivePayload(
            contexts: [incomingContext],
            portraitMedia: [incomingPortraitAsset]
        ),
        ownedProfileSnapshots: [incomingProfile]
    )

    let plan = try ArchiveImportPlanner().inspect(
        ArchiveCodec.encode(incomingArchive),
        existingPeople: destination.archive.people,
        existingInteractions: destination.archive.interactions,
        existingCanonical: destination.archive.canonical,
        existingOwnedProfileSnapshots: destination.archive.ownedProfileSnapshots ?? [],
        verifiedPortraitMediaIDs: [incomingPortraitAsset.id],
        existingTombstones: destination.tombstones
    )
    let reviewed = plan.reviewedArchive(from: incomingArchive)

    #expect(plan.hasBlockingIssues)
    #expect(plan.issues.filter { $0.code == .editDeleteConflict }.count == 5)
    #expect(plan.tombstoneConflicts == destination.tombstones)
    #expect(plan.peopleToCreate.isEmpty)
    #expect(plan.personUpdates.isEmpty)
    #expect(plan.interactionsToCreate.isEmpty)
    #expect(Set(plan.structuredRecordConflicts) == destination.tombstones.structuredRecordIDs)
    #expect(reviewed.people.isEmpty)
    #expect(reviewed.interactions.isEmpty)
    #expect(reviewed.canonical?.contexts.isEmpty == true)
    #expect(reviewed.canonical?.portraitMedia?.isEmpty == true)
    #expect(reviewed.ownedProfileSnapshots?.isEmpty == true)

    do {
        try store.commitImportedArchive(
            incomingArchive,
            mediaPayloads: [incomingPortraitAsset.id: destinationPortrait.data]
        )
        Issue.record("A raw commit must not bypass a destination deletion tombstone")
    } catch let error as ArchiveImportCommitError {
        guard case .destinationContainsTombstones(let conflicts) = error else {
            Issue.record("Unexpected archive commit error: \(error)")
            return
        }
        #expect(conflicts == destination.tombstones)
    }

    let afterRejectedCommit = try store.inspectMigrationDestination()
    #expect(afterRejectedCommit.tombstones == destination.tombstones)
    #expect(afterRejectedCommit.archive.people.isEmpty)
    #expect(afterRejectedCommit.archive.interactions.isEmpty)
    #expect(afterRejectedCommit.archive.canonical?.contexts.isEmpty == true)
    #expect(afterRejectedCommit.archive.canonical?.portraitMedia?.isEmpty == true)
    #expect(afterRejectedCommit.archive.ownedProfileSnapshots?.isEmpty == true)

    // Even if a caller ignores the blocking issue, the reviewed projection has
    // removed every resurrection and is safe to commit as a no-op.
    try store.commitImportedArchive(reviewed)
    #expect(try store.inspectMigrationDestination().tombstones == destination.tombstones)
}

@Test @MainActor func permanentDeletionCreatesPayloadFreeMarkersAndBlocksNormalResurrection() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let person = Person(displayName: "Permanently deleted")
    let interaction = Interaction(personID: person.id, summary: "Private deleted interaction")
    let portrait = makeMigrationPortrait(personID: person.id)
    store.save(person)
    store.save(interaction)
    canonical.save(portrait)

    store.permanentlyDelete(person, deleteInteractions: true)

    let destination = try store.inspectMigrationDestination()
    #expect(destination.tombstones.personIDs == [person.id])
    #expect(destination.tombstones.interactionIDs == [interaction.id])
    #expect(destination.tombstones.structuredRecordIDs.contains(.init(
        family: .portraitMedia,
        id: portrait.asset.id
    )))

    let markerRequest = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
    markerRequest.predicate = NSPredicate(
        format: "kind BEGINSWITH %@",
        SynchronizedDeletionMarkerRepository.markerKindPrefix
    )
    let markers = try persistence.container.viewContext.fetch(markerRequest)
    #expect(markers.count == 3)
    #expect(markers.allSatisfy { $0.value(forKey: "payload") as? Data == Data() })
    #expect(markers.allSatisfy { $0.value(forKey: "deletedAt") == nil })

    store.save(person)
    #expect(store.person(id: person.id) == nil)
    store.save(interaction)
    #expect(store.interactions.allSatisfy { $0.id != interaction.id })
    #expect(throws: SynchronizedDeletionMarkerError.self) {
        try canonical.records.upsert(
            portrait.asset,
            id: portrait.asset.id,
            kind: "portraitMedia"
        )
    }
    #expect(throws: SynchronizedDeletionMarkerError.self) {
        try canonical.mediaPayloads.savePortrait(portrait)
    }
}

@Test @MainActor func permanentDeletionCommitsMarkerBeforePhysicalRemoval() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let person = Person(displayName: "Marker first")
    #expect(store.save(person))

    let probe = PermanentDeletionCommitProbe(
        personID: person.id,
        markerKind: SynchronizedDeletionMarkerRepository.markerKind(for: .person(person.id))
    )
    let token = NotificationCenter.default.addObserver(
        forName: .relationshipNotebookLocalMutationCommitted,
        object: persistence.container.viewContext,
        queue: nil
    ) { notification in
        probe.record(notification)
    }
    defer { NotificationCenter.default.removeObserver(token) }

    store.permanentlyDelete(person, deleteInteractions: false)

    #expect(probe.snapshots == [
        .init(markerCount: 1, personCount: 1),
        .init(markerCount: 1, personCount: 0),
    ])
    #expect(store.person(id: person.id) == nil)
    #expect(try store.deletionConflictDraftCount() == 0)
}

@Test @MainActor func purgeMakesSoftDeletionDurableButSoftRestoreStillWorksBeforePurge() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let records = RecordRepository(persistence: persistence)
    let context = Context(kind: .community, names: LocalizedText("Restorable first"))
    let profile = makeMigrationProfileSnapshot()
    let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)

    try records.upsert(context, id: context.id, kind: "context")
    try records.softDelete(id: context.id, kind: "context", now: deletedAt)
    try records.restore(id: context.id, kind: "context", now: deletedAt.addingTimeInterval(1))
    #expect(try records.fetch(Context.self, kind: "context").map(\.id) == [context.id])

    try records.softDelete(id: context.id, kind: "context", now: deletedAt)
    try records.upsert(
        profile,
        id: profile.cardVersionID,
        kind: "profileSnapshot",
        in: .ownedProfiles,
        now: deletedAt
    )
    try records.softDelete(
        id: profile.cardVersionID,
        kind: "profileSnapshot",
        in: .ownedProfiles,
        now: deletedAt
    )
    let cutoff = deletedAt.addingTimeInterval(60)
    #expect(try records.purgeDeleted(before: cutoff) == 1)
    #expect(try records.purgeDeleted(before: cutoff, in: .ownedProfiles) == 1)

    let tombstones = try store.inspectMigrationDestination().tombstones
    #expect(tombstones.structuredRecordIDs.contains(.init(family: .context, id: context.id)))
    #expect(tombstones.structuredRecordIDs.contains(.init(
        family: .profileSnapshot,
        id: profile.cardVersionID
    )))
    #expect(throws: SynchronizedDeletionMarkerError.self) {
        try records.upsert(context, id: context.id, kind: "context")
    }
    #expect(throws: SynchronizedDeletionMarkerError.self) {
        try records.upsert(
            profile,
            id: profile.cardVersionID,
            kind: "profileSnapshot",
            in: .ownedProfiles
        )
    }
}

@Test @MainActor func deleteEntireVaultRetainsDurableMarkersAndIsIdempotent() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let person = Person(displayName: "Erase all")
    let interaction = Interaction(personID: person.id, summary: "Erase all")
    let context = Context(kind: .project, names: LocalizedText("Erase all"))
    let profile = makeMigrationProfileSnapshot()
    store.save(person)
    store.save(interaction)
    canonical.save(context)
    canonical.saveProfileSnapshot(profile)

    store.deleteEntireVault()
    let first = try store.inspectMigrationDestination().tombstones
    #expect(try store.deletionConflictDraftCount() == 0)
    #expect(first.personIDs == [person.id])
    #expect(first.interactionIDs == [interaction.id])
    #expect(first.structuredRecordIDs.contains(.init(family: .context, id: context.id)))
    #expect(first.structuredRecordIDs.contains(.init(
        family: .profileSnapshot,
        id: profile.cardVersionID
    )))

    let markerCount = try durableMarkerCount(in: persistence.container.viewContext)
    store.deleteEntireVault()
    #expect(try durableMarkerCount(in: persistence.container.viewContext) == markerCount)
    #expect(try store.inspectMigrationDestination().tombstones == first)
}

@Test @MainActor func importedStaleValuesAreDeletedAgainWhileDurableMarkersSurvive() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let records = canonical.records
    let person = Person(displayName: "Remote stale person")
    let interaction = Interaction(personID: person.id, summary: "Remote stale interaction")
    let contextValue = Context(kind: .community, names: LocalizedText("Remote stale context"))
    let portrait = makeMigrationPortrait(personID: person.id)
    let profile = makeMigrationProfileSnapshot()
    let deletedAt = Date(timeIntervalSince1970: 1_710_000_000)

    store.save(person)
    store.save(interaction)
    canonical.save(portrait)
    store.permanentlyDelete(person, deleteInteractions: true)
    try records.upsert(contextValue, id: contextValue.id, kind: "context", now: deletedAt)
    try records.softDelete(id: contextValue.id, kind: "context", now: deletedAt)
    _ = try records.purgeDeleted(before: deletedAt.addingTimeInterval(1))
    try records.upsert(
        profile,
        id: profile.cardVersionID,
        kind: "profileSnapshot",
        in: .ownedProfiles,
        now: deletedAt
    )
    try records.softDelete(
        id: profile.cardVersionID,
        kind: "profileSnapshot",
        in: .ownedProfiles,
        now: deletedAt
    )
    _ = try records.purgeDeleted(
        before: deletedAt.addingTimeInterval(1),
        in: .ownedProfiles
    )
    let markerCount = try durableMarkerCount(in: persistence.container.viewContext)

    let remoteContext = persistence.container.newBackgroundContext()
    try remoteContext.performAndWait {
        let personObject = NSEntityDescription.insertNewObject(
            forEntityName: "PersonEntity",
            into: remoteContext
        )
        personObject.setValue(person.id, forKey: "id")
        personObject.setValue(person.displayName, forKey: "displayName")
        personObject.setValue(person.createdAt, forKey: "createdAt")
        personObject.setValue(Date.now, forKey: "modifiedAt")

        let interactionObject = NSEntityDescription.insertNewObject(
            forEntityName: "InteractionEntity",
            into: remoteContext
        )
        interactionObject.setValue(interaction.id, forKey: "id")
        interactionObject.setValue(interaction.personID, forKey: "personID")
        interactionObject.setValue(interaction.occurredAt, forKey: "occurredAt")
        interactionObject.setValue(interaction.kind.rawValue, forKey: "kind")
        interactionObject.setValue(interaction.status.rawValue, forKey: "status")
        interactionObject.setValue(try JSONEncoder().encode(interaction), forKey: "detailsData")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try insertRemoteRecord(
            entityName: "CanonicalRecordEntity",
            id: contextValue.id,
            kind: "context",
            payload: encoder.encode(contextValue),
            into: remoteContext
        )
        try insertRemoteRecord(
            entityName: "CanonicalRecordEntity",
            id: portrait.asset.id,
            kind: "portraitMedia",
            payload: encoder.encode(portrait.asset),
            into: remoteContext
        )
        let payloadObject = NSEntityDescription.insertNewObject(
            forEntityName: "MediaPayloadEntity",
            into: remoteContext
        )
        payloadObject.setValue(portrait.asset.id, forKey: "id")
        payloadObject.setValue(portrait.data, forKey: "payload")
        payloadObject.setValue(portrait.asset.sha256, forKey: "contentHash")
        payloadObject.setValue(Date.now, forKey: "createdAt")
        payloadObject.setValue(Date.now, forKey: "modifiedAt")
        try insertRemoteRecord(
            entityName: "ProfileRecordEntity",
            id: profile.cardVersionID,
            kind: "profileSnapshot",
            payload: encoder.encode(profile),
            into: remoteContext
        )
        try remoteContext.save()
    }

    try store.reloadAfterRemoteImportOrThrow()
    try canonical.reloadAfterRemoteImportOrThrow()

    #expect(try entityCount("PersonEntity", id: person.id, in: persistence.container.viewContext) == 0)
    #expect(try entityCount("InteractionEntity", id: interaction.id, in: persistence.container.viewContext) == 0)
    #expect(try recordCount(
        "CanonicalRecordEntity",
        id: contextValue.id,
        kind: "context",
        in: persistence.container.viewContext
    ) == 0)
    #expect(try recordCount(
        "CanonicalRecordEntity",
        id: portrait.asset.id,
        kind: "portraitMedia",
        in: persistence.container.viewContext
    ) == 0)
    #expect(try entityCount(
        "MediaPayloadEntity",
        id: portrait.asset.id,
        in: persistence.container.viewContext
    ) == 0)
    #expect(try recordCount(
        "ProfileRecordEntity",
        id: profile.cardVersionID,
        kind: "profileSnapshot",
        in: persistence.container.viewContext
    ) == 0)
    #expect(try durableMarkerCount(in: persistence.container.viewContext) == markerCount)

    let drafts = try store.deletionConflictDrafts()
    #expect(drafts.count == 6)
    #expect(Set(drafts.map(\.row.key.entity)) == Set(RecoverableDeletionEntity.allCases))
    #expect(drafts.allSatisfy { $0.contentSHA256.count == 64 })

    let personDraft = try #require(drafts.first {
        $0.row.key.entity == .person && $0.row.key.id == person.id
    })
    #expect(personDraft.target == .person(person.id))
    #expect(personDraft.row.attributes["displayName"] == .string(person.displayName))

    let payloadDraft = try #require(drafts.first {
        $0.row.key.entity == .mediaPayload && $0.row.key.id == portrait.asset.id
    })
    #expect(payloadDraft.row.attributes["payload"] == .data(portrait.data))

    let exported = try JSONDecoder().decode(
        DeletionConflictDraftExport.self,
        from: store.exportDeletionConflictDrafts()
    )
    #expect(exported.schemaVersion == DeletionConflictDraftExport.currentSchemaVersion)
    #expect(exported.drafts == drafts)
}

@Test @MainActor func repeatedIdenticalStaleImportIsIdempotentButDistinctEditIsRetained() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let personID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_720_000_000)
    let firstModifiedAt = createdAt.addingTimeInterval(10)
    let markers = SynchronizedDeletionMarkerRepository(persistence: persistence)
    _ = try markers.mark([.person(personID)])
    try persistence.container.viewContext.save()

    try insertStalePersonRow(
        id: personID,
        displayName: "Offline edit one",
        createdAt: createdAt,
        modifiedAt: firstModifiedAt,
        persistence: persistence
    )
    try store.reloadAfterRemoteImportOrThrow()
    let firstDraft = try #require(store.deletionConflictDrafts().first)
    #expect(try store.deletionConflictDraftCount() == 1)

    try insertStalePersonRow(
        id: personID,
        displayName: "Offline edit one",
        createdAt: createdAt,
        modifiedAt: firstModifiedAt,
        persistence: persistence
    )
    try store.reloadAfterRemoteImportOrThrow()
    #expect(try store.deletionConflictDraftCount() == 1)
    #expect(try store.deletionConflictDrafts().first?.id == firstDraft.id)

    try insertStalePersonRow(
        id: personID,
        displayName: "Offline edit two",
        createdAt: createdAt,
        modifiedAt: firstModifiedAt.addingTimeInterval(10),
        persistence: persistence
    )
    try store.reloadAfterRemoteImportOrThrow()
    let drafts = try store.deletionConflictDrafts()
    #expect(drafts.count == 2)
    #expect(Set(drafts.compactMap { draft -> String? in
        guard case .string(let name) = draft.row.attributes["displayName"] else { return nil }
        return name
    }) == ["Offline edit one", "Offline edit two"])

    #expect(try store.removeDeletionConflictDraft(id: firstDraft.id))
    #expect(try store.deletionConflictDraftCount() == 1)
    #expect(try !store.removeDeletionConflictDraft(id: firstDraft.id))
}

@Test @MainActor func preWipeOfflineEditCreatesLocalRecoveryDraft() throws {
    let persistence = PersistenceController(inMemory: true)
    let epochID = UUID()
    let markers = SynchronizedDeletionMarkerRepository(persistence: persistence)
    _ = try markers.stage(DurableDeletionState(wipeEpochIDs: [epochID]))
    try persistence.container.viewContext.save()

    let personID = UUID()
    try insertStalePersonRow(
        id: personID,
        displayName: "Created before observing the wipe",
        createdAt: Date(timeIntervalSince1970: 1_730_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_730_000_100),
        persistence: persistence
    )
    let store = NotebookStore(persistence: persistence)

    #expect(store.person(id: personID) == nil)
    let draft = try #require(store.deletionConflictDrafts().first)
    #expect(draft.target == .person(personID))
    #expect(draft.row.attributes["vaultEpochsData"] == nil)
    #expect(try markers.targets().contains(.person(personID)))
}

@Test @MainActor func openValueEditorsPreserveAttemptsRejectedByRemoteDeletion() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let person = Person(displayName: "Original", privateNote: "Original person value")
    let interaction = Interaction(personID: person.id, summary: "Original interaction value")
    #expect(store.save(person))
    #expect(store.save(interaction))

    var editedPerson = person
    editedPerson.privateNote = "Unsaved offline person edit"
    editedPerson.modifiedAt = person.modifiedAt.addingTimeInterval(60)
    var editedInteraction = interaction
    editedInteraction.summary = "Unsaved offline interaction edit"

    let markers = SynchronizedDeletionMarkerRepository(persistence: persistence)
    _ = try markers.mark([.person(person.id), .interaction(interaction.id)])
    try persistence.container.viewContext.save()

    #expect(!store.save(editedPerson))
    #expect(!store.save(editedInteraction))
    #expect(!store.save(editedPerson))
    #expect(store.lastError?.contains("Deletion Conflict Recovery") == true)

    let drafts = try store.deletionConflictDrafts()
    #expect(drafts.count == 2)
    let personDraft = try #require(drafts.first { $0.target == .person(person.id) })
    #expect(personDraft.row.attributes["privateNote"] == .string(editedPerson.privateNote))
    let interactionDraft = try #require(drafts.first {
        $0.target == .interaction(interaction.id)
    })
    #expect(interactionDraft.row.attributes["summary"] == .string(editedInteraction.summary))
    guard case .data(let encodedInteraction) = interactionDraft.row.attributes["detailsData"] else {
        Issue.record("The rejected Interaction payload was not preserved losslessly")
        return
    }
    #expect(
        try JSONDecoder().decode(Interaction.self, from: encodedInteraction) ==
            editedInteraction.normalizedForRetention()
    )
}

@Test @MainActor func reviewedDeletionApplicationDoesNotCreateRecoveryDrafts() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let person = Person(displayName: "Reviewed destination deletion")
    store.save(person)

    let state = DurableDeletionState(targets: [.person(person.id)])
    let preview = try store.previewApplyingDurableDeletionState(state)
    #expect(preview.targetsToDelete == [.person(person.id)])
    try store.applyDurableDeletionState(state, expectedPreview: preview)

    #expect(store.person(id: person.id) == nil)
    #expect(try store.deletionConflictDraftCount() == 0)
}

@Test @MainActor func deletionPreviewPlansEveryPortraitRowAndReferenceRedaction() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let deletedPerson = Person(displayName: "Delete with complete closure")
    let retainedPerson = Person(displayName: "Retained participant")
    #expect(store.save(deletedPerson))
    #expect(store.save(retainedPerson))
    let interaction = Interaction(
        personID: deletedPerson.id,
        summary: "Retain after unlink",
        additionalParticipantIDs: [retainedPerson.id]
    )
    #expect(store.save(interaction))
    let portrait = makeMigrationPortrait(personID: deletedPerson.id)
    canonical.save(portrait)
    let reminder = Reminder(
        subject: .person(deletedPerson.id),
        title: "Must be deleted",
        due: .instant(.now, timeZoneIdentifier: nil)
    )
    canonical.save(reminder)
    let commitment = Commitment(
        interactionID: interaction.id,
        personIDs: [deletedPerson.id, retainedPerson.id],
        summary: "Must be redacted",
        owner: .person(deletedPerson.id)
    )
    canonical.save(commitment)

    let state = DurableDeletionState(targets: [.person(deletedPerson.id)])
    let preview = try store.previewApplyingDurableDeletionState(state)
    let deletedEntities = preview.physicalMutations
        .filter { $0.action == .delete }
        .map(\.row.entityName)
    let redactedRows = preview.physicalMutations.filter { $0.action == .redact }
    #expect(deletedEntities.contains("PersonEntity"))
    #expect(deletedEntities.contains("CanonicalRecordEntity"))
    #expect(deletedEntities.contains("MediaPayloadEntity"))
    #expect(redactedRows.contains {
        $0.row.entityName == "InteractionEntity" && $0.row.id == interaction.id
    })
    #expect(redactedRows.contains {
        $0.row.kind == "commitment" && $0.row.id == commitment.id
    })
    #expect(preview.targetsToDelete.contains(.vaultRecord(
        id: portrait.asset.id,
        kind: "portraitMedia"
    )))
    #expect(preview.physicalDeleteCount > preview.targetsToDelete.count)

    let projection = try preview.projectedArchive()
    #expect(!projection.people.contains { $0.id == deletedPerson.id })
    let projectedInteraction = try #require(
        projection.interactions.first { $0.id == interaction.id }
    )
    #expect(projectedInteraction.personID == retainedPerson.id)
    #expect(projectedInteraction.additionalParticipantIDs == nil)
    #expect(projection.canonical?.portraitMedia?.isEmpty == true)
    #expect(projection.canonical?.reminders.isEmpty == true)
    let projectedCommitment = try #require(projection.canonical?.commitments.first)
    #expect(projectedCommitment.personIDs == [retainedPerson.id])
    #expect(projectedCommitment.owner == .unspecified)

    try store.applyDurableDeletionState(state, expectedPreview: preview)
    #expect(store.person(id: deletedPerson.id) == nil)
    #expect(try recordCount(
        "CanonicalRecordEntity",
        id: portrait.asset.id,
        kind: "portraitMedia",
        in: persistence.container.viewContext
    ) == 0)
    #expect(try entityCount(
        "MediaPayloadEntity",
        id: portrait.asset.id,
        in: persistence.container.viewContext
    ) == 0)
}

@Test @MainActor func directCanonicalContextDeletionPlansItsCompleteDependencyCascade() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let person = Person(displayName: "Retained member")
    #expect(store.save(person))
    let contextValue = Context(kind: .community, names: LocalizedText("Root"))
    let child = Context(
        parentContextID: contextValue.id,
        kind: .project,
        names: LocalizedText("Child")
    )
    let scheme = CohortScheme(
        contextID: child.id,
        kind: .namedIntake,
        name: LocalizedText("Scheme"),
        orderingMethod: .unordered
    )
    let cohort = Cohort(schemeID: scheme.id, labels: LocalizedText("Cohort"))
    let membership = MembershipEpisode(
        personID: person.id,
        contextID: child.id
    )
    let assignment = CohortAssignment(
        membershipEpisodeID: membership.id,
        cohortID: cohort.id
    )
    canonical.save(contextValue)
    canonical.save(child)
    canonical.save(scheme)
    canonical.save(cohort)
    canonical.save(membership)
    canonical.save(assignment)

    let state = DurableDeletionState(targets: [
        .vaultRecord(id: contextValue.id, kind: "context"),
    ])
    let preview = try store.previewApplyingDurableDeletionState(state)
    let deletedCanonicalIDs = Set(preview.physicalMutations.compactMap { mutation -> UUID? in
        mutation.action == .delete && mutation.row.entityName == "CanonicalRecordEntity"
            ? mutation.row.id
            : nil
    })
    #expect(deletedCanonicalIDs.isSuperset(of: [
        contextValue.id,
        child.id,
        scheme.id,
        cohort.id,
        membership.id,
        assignment.id,
    ]))
    let projection = try preview.projectedArchive()
    #expect(projection.canonical?.contexts.isEmpty == true)
    #expect(projection.canonical?.cohortSchemes.isEmpty == true)
    #expect(projection.canonical?.cohorts.isEmpty == true)
    #expect(projection.canonical?.memberships.isEmpty == true)
    #expect(projection.canonical?.cohortAssignments.isEmpty == true)

    try store.applyDurableDeletionState(state, expectedPreview: preview)
    let after = try store.exportArchive()
    #expect(after.canonical?.contexts.isEmpty == true)
    #expect(after.canonical?.cohortAssignments.isEmpty == true)
}

@Test @MainActor func initialStoreReconciliationEnforcesAnExistingDeletionMarker() throws {
    let persistence = PersistenceController(inMemory: true)
    let person = Person(displayName: "Stale at launch")
    let context = persistence.container.viewContext
    _ = try SynchronizedDeletionMarkerRepository(persistence: persistence).mark([.person(person.id)])
    let object = NSEntityDescription.insertNewObject(forEntityName: "PersonEntity", into: context)
    object.setValue(person.id, forKey: "id")
    object.setValue(person.displayName, forKey: "displayName")
    object.setValue(person.createdAt, forKey: "createdAt")
    object.setValue(person.modifiedAt, forKey: "modifiedAt")
    try context.save()

    let store = NotebookStore(persistence: persistence)

    #expect(store.person(id: person.id) == nil)
    #expect(try entityCount("PersonEntity", id: person.id, in: context) == 0)
    #expect(try durableMarkerCount(in: context) == 1)
}

@Test @MainActor func importedInteractionDeletionMarkerRedactsCanonicalReferences() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let person = Person(displayName: "Keep participant")
    let interaction = Interaction(personID: person.id, summary: "Deleted remotely")
    store.save(person)
    store.save(interaction)
    canonical.save(Reminder(
        subject: .interaction(interaction.id),
        title: "Must not dangle",
        due: .instant(.now, timeZoneIdentifier: nil)
    ))
    canonical.save(Commitment(
        interactionID: interaction.id,
        personIDs: [person.id],
        summary: "Retain without deleted interaction"
    ))

    let markers = SynchronizedDeletionMarkerRepository(persistence: persistence)
    _ = try markers.mark([.interaction(interaction.id)])
    try persistence.container.viewContext.save()

    try store.reloadAfterRemoteImportOrThrow()
    try canonical.reloadAfterRemoteImportOrThrow()

    #expect(store.interactions.allSatisfy { $0.id != interaction.id })
    #expect(canonical.reminders.isEmpty)
    #expect(canonical.commitments.first?.interactionID == nil)
}

@MainActor
private func durableMarkerCount(in context: NSManagedObjectContext) throws -> Int {
    let request = NSFetchRequest<NSFetchRequestResult>(entityName: "CanonicalRecordEntity")
    request.predicate = NSPredicate(
        format: "kind BEGINSWITH %@",
        SynchronizedDeletionMarkerRepository.markerKindPrefix
    )
    return try context.count(for: request)
}

@MainActor
private func entityCount(
    _ entityName: String,
    id: UUID,
    in context: NSManagedObjectContext
) throws -> Int {
    let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
    request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
    return try context.count(for: request)
}

@MainActor
private func recordCount(
    _ entityName: String,
    id: UUID,
    kind: String,
    in context: NSManagedObjectContext
) throws -> Int {
    let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
    request.predicate = NSPredicate(
        format: "id == %@ AND kind == %@",
        id as CVarArg,
        kind
    )
    return try context.count(for: request)
}

@MainActor
private func insertStalePersonRow(
    id: UUID,
    displayName: String,
    createdAt: Date,
    modifiedAt: Date,
    persistence: PersistenceController
) throws {
    let remoteContext = persistence.container.newBackgroundContext()
    try remoteContext.performAndWait {
        let object = NSEntityDescription.insertNewObject(
            forEntityName: "PersonEntity",
            into: remoteContext
        )
        object.setValue(id, forKey: "id")
        object.setValue(displayName, forKey: "displayName")
        object.setValue(createdAt, forKey: "createdAt")
        object.setValue(modifiedAt, forKey: "modifiedAt")
        try remoteContext.save()
    }
}

private func insertRemoteRecord(
    entityName: String,
    id: UUID,
    kind: String,
    payload: Data,
    into context: NSManagedObjectContext
) throws {
    let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
    object.setValue(id, forKey: "id")
    object.setValue(kind, forKey: "kind")
    object.setValue(payload, forKey: "payload")
    object.setValue(Date.now, forKey: "createdAt")
    object.setValue(Date.now, forKey: "modifiedAt")
}

private func makeMigrationPortrait(
    id: UUID = UUID(),
    personID: UUID,
    modifiedAt: Date = .now
) -> SanitizedPortrait {
    let data = Data("migration portrait bytes".utf8)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return SanitizedPortrait(
        asset: PortraitMediaAsset(
            id: id,
            personID: personID,
            sha256: hash,
            byteCount: Int64(data.count),
            pixelWidth: 2,
            pixelHeight: 2,
            isPrimary: true,
            modifiedAt: modifiedAt
        ),
        data: data
    )
}

private func makeMigrationProfileSnapshot(
    publicationID: UUID = UUID(),
    cardVersionID: UUID = UUID(),
    publishedAt: Date = .now
) -> ProfileCardSnapshotPayload {
    ProfileCardSnapshotPayload(
        publicationID: publicationID,
        cardVersionID: cardVersionID,
        cardVersion: 1,
        publishedAt: publishedAt,
        advisoryExpiresAt: nil,
        retentionIntent: .recipientMayRetain,
        fields: [
            ProfileCardSnapshotField(
                id: ServiceDigest.deterministicUUID(
                    seed: "migration-profile-field:\(cardVersionID.uuidString)"
                ),
                key: .preferredName,
                value: .text("Migration profile"),
                audience: .anyRecipient
            )
        ]
    )
}
