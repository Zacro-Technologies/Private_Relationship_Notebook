import Combine
import CoreData
import CryptoKit
import Foundation

@MainActor
public final class NotebookStore: ObservableObject {
    private static let archiveExtensionsRecordID = UUID(
        uuidString: "2d1e33be-2f0b-4e9f-a69e-78b0d8351ad8"
    )!
    public static let exampleDataSetID = UUID(
        uuidString: "9afec688-83aa-4f31-8db2-b3552a75ec85"
    )!
    @Published public private(set) var people: [Person] = []
    @Published public private(set) var interactions: [Interaction] = []
    @Published public private(set) var recentlyDeletedInteractions: [Interaction] = []
    @Published public private(set) var revision: UInt64 = 0
    @Published public var lastError: String?

    private let persistence: PersistenceController
    private var context: NSManagedObjectContext { persistence.container.viewContext }
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()
    private let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let canonicalDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(persistence: PersistenceController) {
        self.persistence = persistence
        reload()
    }

    /// Vault-scoped location for rebuildable, local-only search state.
    public var localSearchIndexURL: URL? {
        persistence.storeRootURL?
            .appendingPathComponent("DerivedSearch", isDirectory: true)
            .appendingPathComponent("people-index-v\(LocalSearchIndexFormat.currentVersion).json")
    }

    /// Used only by the deletion planner's isolated in-memory simulation. It
    /// must not reconcile cloned control rows before the reviewed roots are
    /// staged deliberately.
    private init(persistence: PersistenceController, withoutInitialReload: Bool) {
        self.persistence = persistence
    }

    public convenience init(inMemory: Bool = false) {
        self.init(persistence: PersistenceController(inMemory: inMemory))
    }

    public func reload() {
        do {
            try reloadSnapshot()
        } catch {
            lastError = String(localized: "Your notebook could not be read. The original data has been left untouched.")
        }
    }

    /// Republishes value snapshots after CloudKit imports changes through a
    /// background context. Unsaved local edits are never discarded.
    public func reloadAfterRemoteImport() {
        do {
            try reloadAfterRemoteImportOrThrow()
        } catch {
            lastError = String(localized: "Your notebook could not be read. The original data has been left untouched.")
        }
    }

    /// Throwing variant used by persistent-history checkpointing. The caller
    /// must not advance a history token unless this coherent refresh succeeds.
    public func reloadAfterRemoteImportOrThrow() throws {
        context.processPendingChanges()
        if !context.hasChanges {
            context.refreshAllObjects()
        }
        try reloadSnapshot()
    }

    private func reloadSnapshot() throws {
        try enforceDurableDeletionState()

        try loadValueSnapshotsWithoutEnforcement()
        lastError = nil
    }

    private func loadValueSnapshotsWithoutEnforcement() throws {

        let personRequest = NSFetchRequest<NSManagedObject>(entityName: "PersonEntity")
        personRequest.sortDescriptors = [NSSortDescriptor(key: "modifiedAt", ascending: false)]
        let loadedPeople = try context.fetch(personRequest).compactMap(decodePerson)

        let interactionRequest = NSFetchRequest<NSManagedObject>(entityName: "InteractionEntity")
        interactionRequest.sortDescriptors = [NSSortDescriptor(key: "occurredAt", ascending: false)]
        let decodedInteractions = try context.fetch(interactionRequest).compactMap(decodeInteraction)
        let loadedInteractions = decodedInteractions.filter { $0.deletedAt == nil }

        people = loadedPeople
        interactions = loadedInteractions
        recentlyDeletedInteractions = decodedInteractions.filter { $0.deletedAt != nil }
        revision &+= 1
    }

    /// Re-enforces both target deletion and reference redaction. A person
    /// marker is permanent, so any retained interaction or canonical row that
    /// arrives later is unlinked or deleted again before snapshots publish.
    private func enforceDurableDeletionState(captureConflicts: Bool = true) throws {
        context.processPendingChanges()
        guard !context.hasChanges else {
            throw SynchronizedDeletionMarkerError.unsavedChangesPreventReconciliation
        }
        let state = DurableDeletionState()
        let preview = try makeDurableDeletionApplicationPreview(state, plannedAt: .now)
        guard !preview.physicalMutations.isEmpty else { return }

        let deletionMarkers = SynchronizedDeletionMarkerRepository(persistence: persistence)
        if try deletionMarkers.mark(preview.targetsToDelete, at: preview.plannedAt) {
            do {
                try context.save()
                postLocalMutationCommitted(
                    source: context,
                    at: preview.plannedAt,
                    storeConfigurations: [CloudSyncStoreConfiguration.vault]
                )
            } catch {
                context.rollback()
                throw error
            }
        }

        let baseline = try physicalRowSnapshots(in: context)
        if captureConflicts {
            let deletedRows = Set(preview.physicalMutations.lazy
                .filter { $0.action == .delete }
                .map(\.row))
            let losingObjects = baseline.compactMap {
                deletedRows.contains($0.row) ? $0.object : nil
            }
            let drafts = DeletionConflictDraftRepository(persistence: persistence)
            if try drafts.stageCapture(objects: losingObjects) > 0 {
                do {
                    try context.save()
                } catch {
                    context.rollback()
                    throw error
                }
            }
        }

        _ = try stageDurableDeletionMutationClosure(
            directTargets: try durableDeletionRoots(applying: state),
            at: preview.plannedAt
        )
        context.processPendingChanges()
        let stagedMutations = physicalMutations(from: baseline)
        guard stagedMutations == preview.physicalMutations else {
            #if DEBUG
            Self.logDeletionPlanDifference(
                expected: preview.physicalMutations,
                actual: stagedMutations
            )
            #endif
            context.rollback()
            throw DurableDeletionStateError.mutationPlanMismatch
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        postLocalMutationCommitted(
            source: context,
            at: preview.plannedAt,
            storeConfigurations: synchronizedStoreConfigurations(
                for: preview.physicalMutations
            )
        )
        guard try nonControlPayloadFingerprint(in: context) ==
                preview.postApplicationFingerprint else {
            throw DurableDeletionStateError.applicationVerificationFailed
        }
    }

    public func person(id: UUID) -> Person? { people.first { $0.id == id } }

    @discardableResult
    public func save(_ person: Person) -> Bool {
        let person = person.normalizedForPersistence()
        do {
            try persistence.requireWritable()
            if person.isSelf,
               person.deletedAt == nil,
               person.mergedIntoPersonID == nil {
                for existing in people where existing.id != person.id && existing.isSelf {
                    var cleared = existing
                    cleared.isSelfIdentity = false
                    cleared.modifiedAt = .now
                    let existingObject = try object(entityName: "PersonEntity", id: cleared.id)
                    encode(cleared, into: existingObject)
                }
            }
            let object = try object(entityName: "PersonEntity", id: person.id)
            encode(person, into: object)
            try context.save()
            postLocalMutationCommitted(
                source: context,
                storeConfigurations: [CloudSyncStoreConfiguration.vault]
            )
            reload()
            return true
        } catch let error as SynchronizedDeletionMarkerError {
            context.rollback()
            if Self.rejectedTarget(in: error) == .person(person.id) {
                do {
                    try captureRejectedEdit(person)
                    lastError = String(localized: "This edit was not saved because the record was deleted on another device. A local copy is available in Deletion Conflict Recovery.")
                } catch {
                    lastError = String(localized: "This edit was not saved because the record was deleted on another device, and its local recovery copy could not be preserved.")
                }
            } else {
                lastError = String(localized: "This change could not be saved locally. Please try again.")
            }
            return false
        } catch {
            context.rollback()
            lastError = String(localized: "This change could not be saved locally. Please try again.")
            return false
        }
    }

    public func archive(_ person: Person) {
        var copy = person
        copy.isArchived = true
        copy.modifiedAt = .now
        save(copy)
    }

    public func restore(_ person: Person) {
        var copy = person
        copy.isArchived = false
        copy.modifiedAt = .now
        save(copy)
    }

    public func moveToRecentlyDeleted(_ person: Person) {
        var copy = person
        copy.deletedAt = .now
        copy.isArchived = false
        copy.modifiedAt = .now
        save(copy)
    }

    public func restoreDeleted(_ person: Person) {
        guard person.mergedIntoPersonID == nil else {
            lastError = String(localized: "This record belongs to a confirmed merge. Use Merge Recovery so both records and interaction links are restored together.")
            return
        }
        var copy = person
        copy.deletedAt = nil
        copy.modifiedAt = .now
        save(copy)
    }

    public func permanentlyDelete(_ person: Person, deleteInteractions: Bool) {
        do {
            try persistence.requireWritable()
            context.processPendingChanges()
            guard !context.hasChanges else {
                throw SynchronizedDeletionMarkerError.unsavedChangesPreventReconciliation
            }
            let deletionDate = Date.now
            let plannedTargets = try stagePermanentDeletion(
                rootPersonID: person.id,
                deleteInteractions: deleteInteractions,
                at: deletionDate
            )
            context.processPendingChanges()
            context.rollback()

            // Commit payload-free controls by themselves. No target or
            // reference edit can reach CloudKit before this transaction.
            let deletionMarkers = SynchronizedDeletionMarkerRepository(
                persistence: persistence
            )
            if try deletionMarkers.mark(plannedTargets, at: deletionDate) {
                try context.save()
                postLocalMutationCommitted(
                    source: context,
                    at: deletionDate,
                    storeConfigurations: [CloudSyncStoreConfiguration.vault]
                )
            }

            // Reapply the deterministic mutation only after the marker commit.
            // This explicit user deletion never routes through conflict-draft
            // capture; drafts are reserved for losing remote/offline edits.
            let committedTargets = try stagePermanentDeletion(
                rootPersonID: person.id,
                deleteInteractions: deleteInteractions,
                at: deletionDate
            )
            guard committedTargets == plannedTargets else {
                context.rollback()
                throw PersonMergeError.canonicalRecordChanged
            }
            try context.save()
            postLocalMutationCommitted(
                source: context,
                at: deletionDate,
                storeConfigurations: [CloudSyncStoreConfiguration.vault]
            )
            reload()
        } catch {
            context.rollback()
            lastError = String(localized: "The record was not permanently deleted. Your existing data is unchanged.")
        }
    }

    public func deleteEntireVault() {
        do {
            try persistence.requireWritable()
            let deletionMarkers = SynchronizedDeletionMarkerRepository(persistence: persistence)
            _ = try deletionMarkers.beginWholeVaultDeletion()
            _ = try deletionMarkers.enforce(captureConflicts: false)

            let derivedRequest = NSFetchRequest<NSManagedObject>(entityName: "DerivedRecordEntity")
            let derivedObjects = try context.fetch(derivedRequest)
            if !derivedObjects.isEmpty {
                derivedObjects.forEach(context.delete)
                try context.save()
            }
            reload()
        } catch {
            context.rollback()
            lastError = String(localized: "The vault was not deleted. Your existing data is unchanged.")
        }
    }

    @discardableResult
    public func save(_ interaction: Interaction) -> Bool {
        let persistedInteraction = interaction.normalizedForRetention()
        guard persistedInteraction.occurredAt <= Date.now.addingTimeInterval(5) else {
            lastError = String(localized: "An interaction cannot be dated in the future. Record scheduled contact as a reminder instead.")
            return false
        }
        do {
            try persistence.requireWritable()
            let previousInteraction = interactions.first { $0.id == persistedInteraction.id }
            let participantIDs = stableUniqueIDs(
                [persistedInteraction.personID].compactMap { $0 }
                    + (persistedInteraction.additionalParticipantIDs ?? [])
            )
            guard try participantIDs.allSatisfy({ try isActiveInteractionParticipant($0) }) else {
                do {
                    try captureRejectedEdit(persistedInteraction)
                    lastError = String(localized: "This edit was not saved because the record was deleted on another device. A local copy is available in Deletion Conflict Recovery.")
                } catch {
                    lastError = String(localized: "This edit was not saved because the record was deleted on another device, and its local recovery copy could not be preserved.")
                }
                return false
            }
            let interactionObject = try object(entityName: "InteractionEntity", id: persistedInteraction.id)
            encode(persistedInteraction, into: interactionObject)
            let affectedParticipantIDs = stableUniqueIDs(
                participantIDs + ([previousInteraction?.personID].compactMap { $0 })
                    + (previousInteraction?.additionalParticipantIDs ?? [])
            )
            try recomputeLastInteractionDates(for: affectedParticipantIDs)
            try context.save()
            postLocalMutationCommitted(
                source: context,
                storeConfigurations: [CloudSyncStoreConfiguration.vault]
            )
            reload()
            return true
        } catch let error as SynchronizedDeletionMarkerError {
            context.rollback()
            if Self.rejectedTarget(in: error) == .interaction(persistedInteraction.id) {
                do {
                    try captureRejectedEdit(persistedInteraction)
                    lastError = String(localized: "This edit was not saved because the record was deleted on another device. A local copy is available in Deletion Conflict Recovery.")
                } catch {
                    lastError = String(localized: "This edit was not saved because the record was deleted on another device, and its local recovery copy could not be preserved.")
                }
            } else {
                lastError = String(localized: "The interaction could not be saved locally. Please try again.")
            }
            return false
        } catch {
            context.rollback()
            lastError = String(localized: "The interaction could not be saved locally. Please try again.")
            return false
        }
    }

    /// Soft-deletes an interaction while preserving its encrypted payload and
    /// correction history. Derived contact recency is recomputed so deleting a
    /// mistaken record cannot continue to make a relationship look recent.
    @discardableResult
    public func moveToRecentlyDeleted(_ interaction: Interaction, at date: Date = .now) -> Bool {
        var copy = interaction
        copy.deletedAt = date
        return save(copy)
    }

    @discardableResult
    public func restoreDeleted(_ interaction: Interaction) -> Bool {
        var copy = interaction
        copy.deletedAt = nil
        return save(copy)
    }

    private func isActiveInteractionParticipant(_ id: UUID) throws -> Bool {
        let deletionMarkers = SynchronizedDeletionMarkerRepository(persistence: persistence)
        guard try !deletionMarkers.contains(.person(id)) else { return false }
        let request = NSFetchRequest<NSManagedObject>(entityName: "PersonEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let matchingPeople = try context.fetch(request)
        guard matchingPeople.count == 1 else { return false }
        return matchingPeople[0].value(forKey: "deletedAt") as? Date == nil
    }

    public func importArchive(_ archive: NotebookArchive) {
        do {
            try commitImportedArchive(archive)
        } catch {
            lastError = String(localized: "Nothing was imported because the reviewed archive could not be committed.")
        }
    }

    /// Commits a reviewed received-profile import and its optional new Person
    /// in one Core Data transaction. The exact received bytes are re-planned
    /// against the current canonical state immediately before staging writes.
    /// Any validation or persistence failure rolls back the Person, source,
    /// and every assertion together.
    @discardableResult
    public func commitReceivedProfileSnapshot(
        _ reviewedBundle: ReceivedProfileSnapshotImportBundle,
        creating newPerson: Person? = nil,
        portrait: SanitizedPortrait? = nil
    ) throws -> Bool {
        var changed = false
        do {
            try persistence.requireWritable()
            context.processPendingChanges()
            guard !context.hasChanges else {
                throw ReceivedProfileSnapshotImportCommitError.pendingNotebookChanges
            }

            if let newPerson {
                guard newPerson.id == reviewedBundle.subjectID else {
                    throw ReceivedProfileSnapshotImportCommitError.subjectMismatch
                }
                guard newPerson.deletedAt == nil,
                      newPerson.mergedIntoPersonID == nil,
                      !newPerson.isArchived else {
                    throw ReceivedProfileSnapshotImportCommitError.newPersonMustBeActive
                }
                let request = NSFetchRequest<NSManagedObject>(entityName: "PersonEntity")
                request.fetchLimit = 1
                request.predicate = NSPredicate(format: "id == %@", newPerson.id as CVarArg)
                guard try context.fetch(request).isEmpty else {
                    throw ReceivedProfileSnapshotImportCommitError.newPersonAlreadyExists
                }
            } else {
                guard try isActiveInteractionParticipant(reviewedBundle.subjectID) else {
                    throw ReceivedProfileSnapshotImportCommitError.destinationPersonUnavailable
                }
            }
            if let portrait {
                guard portrait.asset.personID == reviewedBundle.subjectID else {
                    throw ReceivedProfileSnapshotImportCommitError.subjectMismatch
                }
            }

            let repository = RecordRepository(persistence: persistence)
            let currentBundle = try ReceivedProfileSnapshotImportPlanner().plan(
                exactPayloadBytes: reviewedBundle.exactPayloadBytes,
                selectedFieldIDs: reviewedBundle.selectedFieldIDs,
                subjectID: reviewedBundle.subjectID,
                existingAssertions: repository.fetch(
                    AssertionEnvelope.self,
                    kind: "assertion"
                ).map(\.value),
                existingDefinitions: repository.fetch(
                    AttributeDefinition.self,
                    kind: "attributeDefinition"
                ).map(\.value),
                existingSources: repository.fetch(
                    SourceArtifact.self,
                    kind: "source"
                ).map(\.value),
                originalFilename: reviewedBundle.originalFilename,
                retentionPolicy: reviewedBundle.retentionPolicy,
                importedAt: reviewedBundle.importedAt
            )

            changed = newPerson != nil || currentBundle.hasChanges || portrait != nil
            guard changed else { return false }

            // Stage canonical records first so a later Person validation or
            // write failure exercises the same all-or-nothing rollback path.
            if let source = currentBundle.sourceToCreate {
                try encodeRecords([source], kind: "source")
            }
            try encodeRecords(currentBundle.assertionsToCreate, kind: "assertion")
            if let newPerson {
                let object = try object(entityName: "PersonEntity", id: newPerson.id)
                encode(newPerson, into: object)
            }
            if let portrait {
                try encodeRecords([portrait.asset], kind: "portraitMedia")
                try MediaPayloadRepository(persistence: persistence)
                    .stagePayloadUpsert(portrait)
            }

            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        postLocalMutationCommitted(
            source: context,
            storeConfigurations: [CloudSyncStoreConfiguration.vault]
        )
        reload()
        return changed
    }

    /// Commits an already inspected and user-reviewed archive as one Core Data
    /// transaction. Media-package callers use the throwing form so they can
    /// roll back staged files if metadata persistence fails.
    public func commitImportedArchive(
        _ archive: NotebookArchive,
        mediaPayloads: [UUID: Data] = [:]
    ) throws {
        do {
            try persistence.requireWritable()
            let tombstoneConflicts = try migrationTombstones().conflicts(with: archive)
            guard tombstoneConflicts.isEmpty else {
                throw ArchiveImportCommitError.destinationContainsTombstones(
                    tombstoneConflicts
                )
            }
            var resultingPeople = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
            for incoming in archive.people { resultingPeople[incoming.id] = incoming }
            let activeSelfIDs = resultingPeople.values.filter {
                $0.isSelf && $0.deletedAt == nil && $0.mergedIntoPersonID == nil
            }.map(\.id).sorted { $0.uuidString < $1.uuidString }
            guard activeSelfIDs.count <= 1 else {
                throw ArchiveImportCommitError.multipleActiveSelfIdentities(activeSelfIDs)
            }
            for person in archive.people {
                let object = try object(entityName: "PersonEntity", id: person.id)
                encode(person, into: object)
            }
            for interaction in archive.interactions {
                let object = try object(entityName: "InteractionEntity", id: interaction.id)
                encode(interaction.normalizedForRetention(), into: object)
            }
            if let payload = archive.canonical {
                try encodeRecords(payload.contexts, kind: "context")
                try encodeRecords(payload.cohortSchemes, kind: "cohortScheme")
                try encodeRecords(payload.cohorts, kind: "cohort")
                try encodeRecords(payload.memberships, kind: "membership")
                try encodeRecords(payload.cohortAssignments, kind: "cohortAssignment")
                try encodeRecords(payload.roleDefinitions, kind: "roleDefinition")
                try encodeRecords(payload.roleAssignments, kind: "roleAssignment")
                try encodeRecords(payload.education, kind: "education")
                try encodeRecords(payload.assertions, kind: "assertion")
                try encodeRecords(payload.sources, kind: "source")
                try encodeRecords(payload.artifactUnits ?? [], kind: "artifactUnit")
                try encodeRecords(payload.portraitMedia ?? [], kind: "portraitMedia")
                if !mediaPayloads.isEmpty {
                    let mediaRepository = MediaPayloadRepository(persistence: persistence)
                    for asset in payload.portraitMedia ?? [] {
                        guard let data = mediaPayloads[asset.id] else {
                            throw PortraitMediaError.integrityMismatch
                        }
                        try mediaRepository.stagePayloadUpsert(
                            SanitizedPortrait(asset: asset, data: data)
                        )
                    }
                }
                try encodeRecords(payload.evidence, kind: "evidence")
                try encodeRecords(payload.reminders, kind: "reminder")
                try encodeRecords(payload.commitments, kind: "commitment")
                try encodeRecords(payload.savedViews, kind: "savedView")
                try encodeRecords(payload.attributeDefinitions, kind: "attributeDefinition")
                try encodeRecords(payload.textImportReviews, id: \.source.id, kind: "textImportReview")
                try encodeRecords(payload.personMergeEvents, kind: "personMergeEvent")
            }
            if let snapshots = archive.ownedProfileSnapshots {
                try encodeRecords(
                    snapshots,
                    id: \.cardVersionID,
                    kind: "profileSnapshot",
                    entityName: "ProfileRecordEntity"
                )
            }
            if let incomingExtensions = archive.preservedExtensions,
               !incomingExtensions.isEmpty {
                let repository = RecordRepository(persistence: persistence)
                var mergedExtensions = try repository.fetch(
                    [String: JSONValue].self,
                    kind: "archiveExtensions"
                ).first?.value ?? [:]
                // An import never overwrites a future field already retained by
                // this vault. New keys remain portable on the next full export.
                for (key, value) in incomingExtensions where mergedExtensions[key] == nil {
                    mergedExtensions[key] = value
                }
                let object = try recordObject(
                    entityName: "CanonicalRecordEntity",
                    id: Self.archiveExtensionsRecordID,
                    kind: "archiveExtensions"
                )
                object.setValue(Self.archiveExtensionsRecordID, forKey: "id")
                object.setValue("archiveExtensions", forKey: "kind")
                object.setValue(try canonicalEncoder.encode(mergedExtensions), forKey: "payload")
                object.setValue(Date.now, forKey: "modifiedAt")
                object.setValue(nil, forKey: "deletedAt")
                if object.value(forKey: "createdAt") == nil {
                    object.setValue(Date.now, forKey: "createdAt")
                }
            }
            try context.save()
            var changedConfigurations = Set([CloudSyncStoreConfiguration.vault])
            if archive.ownedProfileSnapshots?.isEmpty == false {
                changedConfigurations.insert(CloudSyncStoreConfiguration.ownedProfiles)
            }
            postLocalMutationCommitted(
                source: context,
                storeConfigurations: changedConfigurations
            )
            reload()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func mergePreview(sourceID: UUID, destinationID: UUID) throws -> PersonMergePreview {
        guard sourceID != destinationID else { throw PersonMergeError.samePerson }
        guard let source = person(id: sourceID), let destination = person(id: destinationID) else {
            throw PersonMergeError.missingPerson
        }
        guard source.mergedIntoPersonID == nil, destination.mergedIntoPersonID == nil,
              source.deletedAt == nil, destination.deletedAt == nil else {
            throw PersonMergeError.alreadyMerged
        }
        return PersonMergePlanner.preview(
            source: source,
            destination: destination,
            interactions: interactions
        )
    }

    /// Merges only after an explicit preview. The source remains as a recoverable tombstone and
    /// the event contains complete pre-merge snapshots so undo cannot silently discard data.
    @discardableResult
    public func mergePeople(sourceID: UUID, into destinationID: UUID) throws -> PersonMergeEvent {
        try persistence.requireWritable()
        let preview = try mergePreview(sourceID: sourceID, destinationID: destinationID)
        let affectedInteractionRecords = try interactionRecordsForMutation().filter { _, interaction in
            interaction.personID == sourceID ||
                (interaction.additionalParticipantIDs?.contains(sourceID) ?? false)
        }
        var seenInteractionIDs = Set<UUID>()
        guard affectedInteractionRecords.allSatisfy({ seenInteractionIDs.insert($0.1.id).inserted }) else {
            throw PersonMergeError.interactionChanged
        }
        let affectedInteractions = affectedInteractionRecords.map(\.1)
        let mergedAt = Date.now
        var destination = preview.resultingPerson
        destination.modifiedAt = mergedAt
        var source = preview.source
        source.mergedIntoPersonID = destinationID
        source.deletedAt = mergedAt
        source.isArchived = false
        source.neverSuggest = true
        source.modifiedAt = mergedAt

        let movedInteractions = affectedInteractions.map {
            retargetInteraction($0, from: sourceID, to: destinationID)
        }

        do {
            let destinationObject = try object(entityName: "PersonEntity", id: destination.id)
            encode(destination, into: destinationObject)

            let sourceObject = try object(entityName: "PersonEntity", id: source.id)
            encode(source, into: sourceObject)

            var interactionMutations: [PersonMergeInteractionMutation] = []
            for ((interactionObject, original), moved) in zip(affectedInteractionRecords, movedInteractions) {
                encode(moved, into: interactionObject)
                interactionMutations.append(PersonMergeInteractionMutation(
                    id: moved.id,
                    beforePayload: try encoder.encode(original),
                    afterPayload: try encoder.encode(moved)
                ))
            }

            let canonicalMutations = try retargetMutableCanonicalReferences(
                from: sourceID,
                to: destinationID,
                at: mergedAt
            )
            let recoverySnapshot = PersonMergeRecoverySnapshot(
                sourcePersonBeforePayload: try encoder.encode(preview.source),
                destinationPersonBeforePayload: try encoder.encode(preview.destination),
                sourcePersonAfterPayload: try encoder.encode(source),
                destinationPersonAfterPayload: try encoder.encode(destination),
                interactionMutations: interactionMutations,
                canonicalMutations: canonicalMutations
            )
            let event = PersonMergeEvent(
                sourcePersonBeforeMerge: preview.source,
                destinationPersonBeforeMerge: preview.destination,
                interactionsBeforeMerge: affectedInteractions,
                mergedAt: mergedAt,
                recoverySnapshot: recoverySnapshot
            )
            let eventObject = try recordObject(
                entityName: "CanonicalRecordEntity",
                id: event.id,
                kind: "personMergeEvent"
            )
            eventObject.setValue(event.id, forKey: "id")
            eventObject.setValue("personMergeEvent", forKey: "kind")
            eventObject.setValue(try canonicalEncoder.encode(event), forKey: "payload")
            eventObject.setValue(mergedAt, forKey: "createdAt")
            eventObject.setValue(mergedAt, forKey: "modifiedAt")
            eventObject.setValue(nil, forKey: "deletedAt")

            try context.save()
            postLocalMutationCommitted(
                source: context,
                storeConfigurations: [CloudSyncStoreConfiguration.vault]
            )
            reload()
            return event
        } catch let error as PersonMergeError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw PersonMergeError.saveFailed
        }
    }

    public func undoMerge(_ requestedEvent: PersonMergeEvent) throws {
        try persistence.requireWritable()
        let storedEventObject = try uniqueCanonicalObject(
            id: requestedEvent.id,
            kind: "personMergeEvent"
        )
        guard let storedPayload = storedEventObject.value(forKey: "payload") as? Data,
              let event = try? canonicalDecoder.decode(PersonMergeEvent.self, from: storedPayload),
              event.id == requestedEvent.id else {
            throw PersonMergeError.canonicalRecordChanged
        }
        guard event.undoneAt == nil else { throw PersonMergeError.alreadyUndone }
        guard Date.now < event.recoveryExpiresAt else { throw PersonMergeError.recoveryExpired }
        guard let snapshot = event.recoverySnapshot else {
            throw PersonMergeError.recoverySnapshotUnavailable
        }
        guard let currentDestination = person(id: event.destinationPersonBeforeMerge.id),
              let currentSource = person(id: event.sourcePersonBeforeMerge.id) else {
            throw PersonMergeError.missingPerson
        }
        guard currentSource.mergedIntoPersonID == currentDestination.id else {
            throw PersonMergeError.destinationChanged
        }

        // An interaction edit can legitimately recompute the destination's
        // derived last-contact fields. Diagnose that primary conflict before
        // comparing the person snapshots so recovery explains exactly which
        // user-authored record blocks the undo.
        for mutation in snapshot.interactionMutations {
            guard let current = interactions.first(where: { $0.id == mutation.id }),
                  try encoder.encode(current) == mutation.afterPayload else {
                throw PersonMergeError.interactionChanged
            }
        }
        guard try encoder.encode(currentSource) == snapshot.sourcePersonAfterPayload,
              try encoder.encode(currentDestination) == snapshot.destinationPersonAfterPayload else {
            throw PersonMergeError.destinationChanged
        }
        for mutation in snapshot.canonicalMutations {
            let object = try uniqueCanonicalObject(id: mutation.id, kind: mutation.kind)
            guard object.value(forKey: "payload") as? Data == mutation.afterPayload,
                  referenceDateInterval(object.value(forKey: "modifiedAt") as? Date)
                    == mutation.afterModifiedAtReferenceDate,
                  referenceDateInterval(object.value(forKey: "deletedAt") as? Date)
                    == mutation.afterDeletedAtReferenceDate else {
                throw PersonMergeError.canonicalRecordChanged
            }
        }

        do {
            let sourceBefore = try decoder.decode(Person.self, from: snapshot.sourcePersonBeforePayload)
            let destinationBefore = try decoder.decode(Person.self, from: snapshot.destinationPersonBeforePayload)
            let sourceObject = try object(entityName: "PersonEntity", id: event.sourcePersonBeforeMerge.id)
            encode(sourceBefore, into: sourceObject)
            let destinationObject = try object(entityName: "PersonEntity", id: event.destinationPersonBeforeMerge.id)
            encode(destinationBefore, into: destinationObject)
            for mutation in snapshot.interactionMutations {
                let interaction = try decoder.decode(Interaction.self, from: mutation.beforePayload)
                let interactionObject = try object(entityName: "InteractionEntity", id: interaction.id)
                encode(interaction, into: interactionObject)
            }
            for mutation in snapshot.canonicalMutations {
                let object = try uniqueCanonicalObject(id: mutation.id, kind: mutation.kind)
                object.setValue(mutation.beforePayload, forKey: "payload")
                object.setValue(
                    mutation.beforeModifiedAtReferenceDate.map(Date.init(timeIntervalSinceReferenceDate:)),
                    forKey: "modifiedAt"
                )
                object.setValue(
                    mutation.beforeDeletedAtReferenceDate.map(Date.init(timeIntervalSinceReferenceDate:)),
                    forKey: "deletedAt"
                )
            }

            var updatedEvent = event
            updatedEvent.undoneAt = .now
            let eventObject = try uniqueCanonicalObject(id: event.id, kind: "personMergeEvent")
            eventObject.setValue(try canonicalEncoder.encode(updatedEvent), forKey: "payload")
            eventObject.setValue(updatedEvent.undoneAt, forKey: "modifiedAt")
            try context.save()
            postLocalMutationCommitted(
                source: context,
                storeConfigurations: [CloudSyncStoreConfiguration.vault]
            )
            reload()
        } catch {
            context.rollback()
            throw PersonMergeError.saveFailed
        }
    }

    public func exportArchive() throws -> NotebookArchive {
        let records = RecordRepository(persistence: persistence)
        let payload = CanonicalArchivePayload(
            contexts: try records.fetch(Context.self, kind: "context").map(\.value),
            cohortSchemes: try records.fetch(CohortScheme.self, kind: "cohortScheme").map(\.value),
            cohorts: try records.fetch(Cohort.self, kind: "cohort").map(\.value),
            memberships: try records.fetch(MembershipEpisode.self, kind: "membership").map(\.value),
            cohortAssignments: try records.fetch(CohortAssignment.self, kind: "cohortAssignment").map(\.value),
            roleDefinitions: try records.fetch(RoleDefinition.self, kind: "roleDefinition").map(\.value),
            roleAssignments: try records.fetch(RoleAssignment.self, kind: "roleAssignment").map(\.value),
            education: try records.fetch(EducationEnrollment.self, kind: "education").map(\.value),
            assertions: try records.fetch(AssertionEnvelope.self, kind: "assertion").map(\.value),
            sources: try records.fetch(SourceArtifact.self, kind: "source").map(\.value),
            artifactUnits: try records.fetch(ArtifactUnit.self, kind: "artifactUnit").map(\.value),
            portraitMedia: try records.fetch(PortraitMediaAsset.self, kind: "portraitMedia").map(\.value),
            evidence: try records.fetch(EvidenceSpan.self, kind: "evidence").map(\.value),
            reminders: try records.fetch(Reminder.self, kind: "reminder").map(\.value),
            commitments: try records.fetch(Commitment.self, kind: "commitment").map(\.value),
            savedViews: try records.fetch(SavedView.self, kind: "savedView").map(\.value),
            attributeDefinitions: try records.fetch(AttributeDefinition.self, kind: "attributeDefinition").map(\.value),
            textImportReviews: try records.fetch(TextImportReview.self, kind: "textImportReview").map(\.value),
            personMergeEvents: try records.fetch(PersonMergeEvent.self, kind: "personMergeEvent").map(\.value)
        )
        let snapshots = try records.fetch(
            ProfileCardSnapshotPayload.self,
            kind: "profileSnapshot",
            from: .ownedProfiles
        ).map(\.value)
        let preservedExtensions = try records.fetch(
            [String: JSONValue].self,
            kind: "archiveExtensions"
        ).first?.value
        return NotebookArchive(
            people: people.filter { $0.deletedAt == nil },
            interactions: interactions.filter { $0.deletedAt == nil },
            canonical: payload,
            ownedProfileSnapshots: snapshots,
            preservedExtensions: preservedExtensions?.isEmpty == false
                ? preservedExtensions
                : nil
        )
    }

    /// Returns active destination values for normal comparison and a separate,
    /// payload-free tombstone inventory for migration conflict review.
    public func inspectMigrationDestination() throws -> ArchiveMigrationDestination {
        ArchiveMigrationDestination(
            archive: try exportArchive(),
            tombstones: try migrationTombstones()
        )
    }

    /// Exports only stable identifiers and wipe-generation metadata. No
    /// deleted record payload is included.
    public func exportDurableDeletionState() throws -> DurableDeletionState {
        let state = try SynchronizedDeletionMarkerRepository(
            persistence: persistence
        ).durableState()
        try Self.validateDurableDeletionState(state, for: exportArchive())
        return state
    }

    /// Device-local recovery copies created when an offline payload loses to
    /// a synchronized permanent deletion. They are excluded from the normal
    /// notebook archive and every CloudKit-backed persistent store.
    public func deletionConflictDrafts() throws -> [DeletionConflictDraft] {
        try DeletionConflictDraftRepository(persistence: persistence).list()
    }

    public func deletionConflictDraftCount() throws -> Int {
        try DeletionConflictDraftRepository(persistence: persistence).count()
    }

    public func exportDeletionConflictDrafts() throws -> Data {
        try DeletionConflictDraftRepository(persistence: persistence).export()
    }

    @discardableResult
    public func removeDeletionConflictDraft(id: UUID) throws -> Bool {
        try DeletionConflictDraftRepository(persistence: persistence).remove(id: id)
    }

    /// Non-mutating review of the complete physical mutation closure. The
    /// destination is cloned into an isolated in-memory store; cascades and
    /// redactions are simulated there, never in the live context.
    public func previewApplyingDurableDeletionState(
        _ state: DurableDeletionState
    ) throws -> DurableDeletionApplicationPreview {
        try makeDurableDeletionApplicationPreview(state, plannedAt: .now)
    }

    /// Applies a previously reviewed state marker-first. A changed destination
    /// invalidates the preview before any control or target is mutated.
    public func applyDurableDeletionState(
        _ state: DurableDeletionState,
        expectedPreview: DurableDeletionApplicationPreview
    ) throws {
        try persistence.requireWritable()
        context.processPendingChanges()
        guard !context.hasChanges else {
            throw SynchronizedDeletionMarkerError.unsavedChangesPreventReconciliation
        }
        let currentPreview = try makeDurableDeletionApplicationPreview(
            state,
            plannedAt: expectedPreview.plannedAt
        )
        guard currentPreview == expectedPreview else {
            throw DurableDeletionStateError.destinationChangedAfterPreview
        }
        let deletionMarkers = SynchronizedDeletionMarkerRepository(persistence: persistence)
        var markerState = state
        markerState.targets.formUnion(expectedPreview.targetsToDelete)
        if try deletionMarkers.stage(markerState, at: expectedPreview.plannedAt) {
            do {
                try context.save()
                postLocalMutationCommitted(
                    source: context,
                    at: expectedPreview.plannedAt,
                    storeConfigurations: [CloudSyncStoreConfiguration.vault]
                )
            } catch {
                context.rollback()
                throw error
            }
        }
        let baseline = try physicalRowSnapshots(in: context)
        _ = try stageDurableDeletionMutationClosure(
            directTargets: durableDeletionRoots(applying: state),
            at: expectedPreview.plannedAt
        )
        context.processPendingChanges()
        let stagedMutations = physicalMutations(from: baseline)
        guard stagedMutations == expectedPreview.physicalMutations else {
            context.rollback()
            throw DurableDeletionStateError.mutationPlanMismatch
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        postLocalMutationCommitted(
            source: context,
            at: expectedPreview.plannedAt,
            storeConfigurations: synchronizedStoreConfigurations(
                for: expectedPreview.physicalMutations
            )
        )
        guard try nonControlPayloadFingerprint(in: context) ==
                expectedPreview.postApplicationFingerprint else {
            throw DurableDeletionStateError.applicationVerificationFailed
        }
        try reloadSnapshot()
    }

    private struct DurablePhysicalSnapshot {
        var object: NSManagedObject
        var row: DurableDeletionPhysicalRow
        var fingerprint: String
        var target: DurableDeletionTarget?
    }

    private func makeDurableDeletionApplicationPreview(
        _ state: DurableDeletionState,
        plannedAt: Date
    ) throws -> DurableDeletionApplicationPreview {
        let markerRepository = SynchronizedDeletionMarkerRepository(
            persistence: persistence
        )
        let identityPreview = try markerRepository.preview(applying: state)
        let directTargets = try markerRepository.targets()
            .union(state.targets)
            .union(identityPreview.targetsToDelete)

        let scratchPersistence = PersistenceController(inMemory: true)
        try cloneSynchronizedRows(
            from: context,
            to: scratchPersistence.container.viewContext
        )
        let scratchStore = NotebookStore(
            persistence: scratchPersistence,
            withoutInitialReload: true
        )
        try scratchStore.loadValueSnapshotsWithoutEnforcement()
        let baseline = try scratchStore.physicalRowSnapshots(
            in: scratchPersistence.container.viewContext
        )
        _ = try scratchStore.stageDurableDeletionMutationClosure(
            directTargets: directTargets,
            at: plannedAt
        )
        scratchPersistence.container.viewContext.processPendingChanges()
        let mutations = scratchStore.physicalMutations(from: baseline)
        let deletedRows = Set(mutations.lazy.filter { $0.action == .delete }.map(\.row))
        let targetsToDelete = Set(baseline.compactMap { snapshot in
            deletedRows.contains(snapshot.row) ? snapshot.target : nil
        })
        try scratchPersistence.container.viewContext.save()
        try scratchStore.loadValueSnapshotsWithoutEnforcement()
        var projectedArchive = try scratchStore.exportArchive()
        projectedArchive.exportedAt = plannedAt

        return DurableDeletionApplicationPreview(
            stateFingerprint: identityPreview.stateFingerprint,
            destinationFingerprint: try synchronizedDestinationFingerprint(in: context),
            targetsToDelete: targetsToDelete,
            plannedAt: plannedAt,
            physicalMutations: mutations,
            postApplicationFingerprint: try scratchStore.nonControlPayloadFingerprint(
                in: scratchPersistence.container.viewContext
            ),
            projectedArchiveData: try ArchiveCodec.encode(projectedArchive)
        )
    }

    private func durableDeletionRoots(
        applying state: DurableDeletionState
    ) throws -> Set<DurableDeletionTarget> {
        let markerRepository = SynchronizedDeletionMarkerRepository(
            persistence: persistence
        )
        return try markerRepository.targets()
            .union(state.targets)
            .union(markerRepository.preview(applying: state).targetsToDelete)
    }

    private func cloneSynchronizedRows(
        from source: NSManagedObjectContext,
        to destination: NSManagedObjectContext
    ) throws {
        for entityName in Self.synchronizedEntityNames {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            let objects = try source.fetch(request).sorted {
                Self.physicalSortToken(for: $0) < Self.physicalSortToken(for: $1)
            }
            for sourceObject in objects {
                let clone = NSEntityDescription.insertNewObject(
                    forEntityName: entityName,
                    into: destination
                )
                for attributeName in sourceObject.entity.attributesByName.keys {
                    clone.setValue(sourceObject.value(forKey: attributeName), forKey: attributeName)
                }
            }
        }
        try destination.save()
    }

    private func physicalRowSnapshots(
        in managedContext: NSManagedObjectContext
    ) throws -> [DurablePhysicalSnapshot] {
        var unnumbered: [(object: NSManagedObject, id: UUID, kind: String?, fingerprint: String)] = []
        for entityName in Self.synchronizedEntityNames {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            for object in try managedContext.fetch(request)
                where !SynchronizedDeletionMarkerRepository.isMarker(object) {
                guard let id = object.value(forKey: "id") as? UUID else { continue }
                unnumbered.append((
                    object,
                    id,
                    Self.storedKind(for: object),
                    Self.physicalFingerprint(for: object)
                ))
            }
        }
        unnumbered.sort { lhs, rhs in
            let left = Self.physicalSortToken(
                entityName: lhs.object.entity.name ?? "",
                id: lhs.id,
                kind: lhs.kind,
                fingerprint: lhs.fingerprint,
                tieBreaker: lhs.object.objectID.uriRepresentation().absoluteString
            )
            let right = Self.physicalSortToken(
                entityName: rhs.object.entity.name ?? "",
                id: rhs.id,
                kind: rhs.kind,
                fingerprint: rhs.fingerprint,
                tieBreaker: rhs.object.objectID.uriRepresentation().absoluteString
            )
            return left < right
        }

        var nextOrdinal: [String: Int] = [:]
        return unnumbered.map { value in
            let entityName = value.object.entity.name ?? ""
            let group = "\(entityName)|\(value.id.uuidString)|\(value.kind ?? "")"
            let ordinal = nextOrdinal[group, default: 0]
            nextOrdinal[group] = ordinal + 1
            return DurablePhysicalSnapshot(
                object: value.object,
                row: DurableDeletionPhysicalRow(
                    entityName: entityName,
                    id: value.id,
                    kind: value.kind,
                    ordinal: ordinal
                ),
                fingerprint: value.fingerprint,
                target: Self.durableTarget(for: value.object)
            )
        }
    }

    private func physicalMutations(
        from baseline: [DurablePhysicalSnapshot]
    ) -> [DurableDeletionPhysicalMutation] {
        baseline.compactMap { snapshot in
            if snapshot.object.isDeleted {
                return DurableDeletionPhysicalMutation(
                    row: snapshot.row,
                    action: .delete,
                    beforeFingerprint: snapshot.fingerprint
                )
            }
            let after = Self.physicalFingerprint(for: snapshot.object)
            guard after != snapshot.fingerprint else { return nil }
            return DurableDeletionPhysicalMutation(
                row: snapshot.row,
                action: .redact,
                beforeFingerprint: snapshot.fingerprint,
                afterFingerprint: after
            )
        }.sorted { Self.mutationSortToken($0) < Self.mutationSortToken($1) }
    }

    private func synchronizedDestinationFingerprint(
        in managedContext: NSManagedObjectContext
    ) throws -> String {
        var lines: [String] = []
        for entityName in Self.synchronizedEntityNames {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            lines.append(contentsOf: try managedContext.fetch(request).map { object in
                "\(Self.physicalSortToken(for: object))|\(Self.physicalFingerprint(for: object))"
            })
        }
        return Self.sha256(lines.sorted().joined(separator: "\n"))
    }

    private func nonControlPayloadFingerprint(
        in managedContext: NSManagedObjectContext
    ) throws -> String {
        let snapshots = try physicalRowSnapshots(in: managedContext)
        return Self.sha256(snapshots.map {
            "\($0.row.entityName)|\($0.row.id.uuidString)|\($0.row.kind ?? "")|\($0.row.ordinal)|\($0.fingerprint)"
        }.joined(separator: "\n"))
    }

    private func synchronizedStoreConfigurations(
        for mutations: [DurableDeletionPhysicalMutation]
    ) -> Set<String> {
        var result = Set<String>()
        for mutation in mutations {
            if mutation.row.entityName == "ProfileRecordEntity" {
                result.insert(CloudSyncStoreConfiguration.ownedProfiles)
            } else {
                result.insert(CloudSyncStoreConfiguration.vault)
            }
        }
        return result
    }

    private static let synchronizedEntityNames = [
        "PersonEntity",
        "InteractionEntity",
        "CanonicalRecordEntity",
        "ProfileRecordEntity",
        "MediaPayloadEntity",
    ]

    private static func durableTarget(for object: NSManagedObject) -> DurableDeletionTarget? {
        guard let id = object.value(forKey: "id") as? UUID else { return nil }
        switch object.entity.name {
        case "PersonEntity":
            return .person(id)
        case "InteractionEntity":
            return .interaction(id)
        case "CanonicalRecordEntity":
            guard let kind = object.value(forKey: "kind") as? String,
                  !SynchronizedDeletionMarkerRepository.isReservedKind(kind) else { return nil }
            return .vaultRecord(id: id, kind: kind)
        case "MediaPayloadEntity":
            return .vaultRecord(id: id, kind: "portraitMedia")
        case "ProfileRecordEntity":
            guard let kind = object.value(forKey: "kind") as? String else { return nil }
            return .ownedProfileRecord(id: id, kind: kind)
        default:
            return nil
        }
    }

    private static func physicalSortToken(for object: NSManagedObject) -> String {
        physicalSortToken(
            entityName: object.entity.name ?? "",
            id: object.value(forKey: "id") as? UUID ?? UUID(
                uuidString: "00000000-0000-0000-0000-000000000000"
            )!,
            kind: storedKind(for: object),
            fingerprint: "",
            tieBreaker: ""
        )
    }

    private static func physicalSortToken(
        entityName: String,
        id: UUID,
        kind: String?,
        fingerprint: String,
        tieBreaker: String
    ) -> String {
        [entityName, id.uuidString, kind ?? "", fingerprint, tieBreaker]
            .joined(separator: "|")
    }

    private static func mutationSortToken(
        _ mutation: DurableDeletionPhysicalMutation
    ) -> String {
        [
            mutation.row.entityName,
            mutation.row.id.uuidString,
            mutation.row.kind ?? "",
            String(mutation.row.ordinal),
            mutation.action.rawValue,
        ].joined(separator: "|")
    }

    private static func logDeletionPlanDifference(
        expected: [DurableDeletionPhysicalMutation],
        actual: [DurableDeletionPhysicalMutation]
    ) {
        func token(_ mutation: DurableDeletionPhysicalMutation) -> String {
            "\(mutationSortToken(mutation))|\(mutation.beforeFingerprint)|\(mutation.afterFingerprint ?? "deleted")"
        }
        let expectedTokens = expected.map(token)
        let actualTokens = actual.map(token)
        print("durable_deletion_expected=\(expectedTokens)")
        print("durable_deletion_actual=\(actualTokens)")
    }

    private static func storedKind(for object: NSManagedObject) -> String? {
        guard object.entity.attributesByName["kind"] != nil else { return nil }
        return object.value(forKey: "kind") as? String
    }

    private static func physicalFingerprint(for object: NSManagedObject) -> String {
        let attributes = object.entity.attributesByName.keys.sorted().map { name -> String in
            let value = object.value(forKey: name)
            return "\(name)=\(stableAttributeToken(value))"
        }
        return sha256(attributes.joined(separator: "\n"))
    }

    private static func stableAttributeToken(_ value: Any?) -> String {
        guard let value else { return "nil" }
        switch value {
        case let data as Data:
            return "data:" + data.base64EncodedString()
        case let date as Date:
            return "date:" + String(date.timeIntervalSinceReferenceDate.bitPattern)
        case let uuid as UUID:
            return "uuid:" + uuid.uuidString
        case let string as String:
            return "string:" + Data(string.utf8).base64EncodedString()
        case let number as NSNumber:
            return "number:\(String(cString: number.objCType)):\(number.stringValue)"
        default:
            return "other:" + String(describing: value)
        }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func validateDurableDeletionState(
        _ state: DurableDeletionState,
        for archive: NotebookArchive
    ) throws {
        try SynchronizedDeletionMarkerRepository.validate(state)
        let activeTargets = durableTargets(in: archive)
        let conflicts = activeTargets.intersection(state.targets)
        guard conflicts.isEmpty else {
            throw DurableDeletionStateError.activeArchiveConflictsWithDeletion(conflicts)
        }
        guard !state.wipeEpochIDs.isEmpty else { return }
        var coveredEpochsByTarget: [DurableDeletionTarget: Set<UUID>] = [:]
        for membership in state.generationMemberships {
            coveredEpochsByTarget[membership.target, default: []]
                .insert(membership.wipeEpochID)
        }
        let missing = Set(activeTargets.filter {
            !state.wipeEpochIDs.isSubset(of: coveredEpochsByTarget[$0] ?? [])
        })
        guard missing.isEmpty else {
            throw DurableDeletionStateError.activeArchiveMissingGenerationMembership(missing)
        }
    }

    private static func durableTargets(in archive: NotebookArchive) -> Set<DurableDeletionTarget> {
        var targets = Set(archive.people.lazy.filter { $0.deletedAt == nil }.map {
            DurableDeletionTarget.person($0.id)
        })
        targets.formUnion(archive.interactions.lazy.filter { $0.deletedAt == nil }.map {
            DurableDeletionTarget.interaction($0.id)
        })
        for identity in archive.canonical?.structuredRecordIdentities ?? [] {
            guard let kind = storedKind(for: identity.family) else { continue }
            targets.insert(.vaultRecord(id: identity.id, kind: kind))
        }
        targets.formUnion((archive.ownedProfileSnapshots ?? []).map {
            .ownedProfileRecord(id: $0.cardVersionID, kind: "profileSnapshot")
        })
        if archive.preservedExtensions?.isEmpty == false {
            targets.insert(.vaultRecord(
                id: archiveExtensionsRecordID,
                kind: "archiveExtensions"
            ))
        }
        return targets
    }

    private static func storedKind(
        for family: ArchiveStructuredRecordFamily
    ) -> String? {
        switch family {
        case .context: "context"
        case .cohortScheme: "cohortScheme"
        case .cohort: "cohort"
        case .membership: "membership"
        case .cohortAssignment: "cohortAssignment"
        case .roleDefinition: "roleDefinition"
        case .roleAssignment: "roleAssignment"
        case .education: "education"
        case .assertion: "assertion"
        case .source: "source"
        case .artifactUnit: "artifactUnit"
        case .portraitMedia: "portraitMedia"
        case .evidence: "evidence"
        case .reminder: "reminder"
        case .commitment: "commitment"
        case .savedView: "savedView"
        case .attributeDefinition: "attributeDefinition"
        case .textImportReview: "textImportReview"
        case .personMergeEvent: "personMergeEvent"
        case .profileSnapshot: nil
        }
    }

    private func migrationTombstones() throws -> ArchiveTombstoneInventory {
        let personRequest = NSFetchRequest<NSManagedObject>(entityName: "PersonEntity")
        personRequest.predicate = NSPredicate(format: "deletedAt != nil")
        let personIDs = Set(try context.fetch(personRequest).compactMap {
            $0.value(forKey: "id") as? UUID
        })

        // Interaction tombstones are additive payload fields because the
        // existing CloudKit model intentionally has no interaction deletion
        // column. Normal snapshots filter these decoded values out.
        let interactionRequest = NSFetchRequest<NSManagedObject>(entityName: "InteractionEntity")
        let interactionIDs: Set<UUID> = Set(try context.fetch(interactionRequest).compactMap { object in
            guard let interaction = decodeInteraction(object),
                  interaction.deletedAt != nil else { return nil }
            return interaction.id
        })

        var structuredRecordIDs: Set<ArchiveStructuredRecordIdentity> = []
        let canonicalRequest = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
        canonicalRequest.predicate = NSPredicate(format: "deletedAt != nil")
        for object in try context.fetch(canonicalRequest) {
            guard let id = object.value(forKey: "id") as? UUID,
                  let kind = object.value(forKey: "kind") as? String,
                  let family = Self.structuredFamily(forStoredKind: kind) else { continue }
            structuredRecordIDs.insert(.init(family: family, id: id))
        }

        let profileRequest = NSFetchRequest<NSManagedObject>(entityName: "ProfileRecordEntity")
        profileRequest.predicate = NSPredicate(format: "deletedAt != nil")
        for object in try context.fetch(profileRequest) {
            guard let id = object.value(forKey: "id") as? UUID,
                  object.value(forKey: "kind") as? String == "profileSnapshot" else { continue }
            structuredRecordIDs.insert(.init(family: .profileSnapshot, id: id))
        }

        // Either half of a deleted portrait is sufficient to prevent an
        // archive import from reviving the pair behind the review plan.
        let mediaRequest = NSFetchRequest<NSManagedObject>(entityName: "MediaPayloadEntity")
        mediaRequest.predicate = NSPredicate(format: "deletedAt != nil")
        for object in try context.fetch(mediaRequest) {
            guard let id = object.value(forKey: "id") as? UUID else { continue }
            structuredRecordIDs.insert(.init(family: .portraitMedia, id: id))
        }

        var durablePersonIDs = personIDs
        var durableInteractionIDs = interactionIDs
        for target in try SynchronizedDeletionMarkerRepository(persistence: persistence).targets() {
            switch target.family {
            case .person:
                durablePersonIDs.insert(target.id)
            case .interaction:
                durableInteractionIDs.insert(target.id)
            case .vaultRecord(let kind):
                if let family = Self.structuredFamily(forStoredKind: kind) {
                    structuredRecordIDs.insert(.init(family: family, id: target.id))
                }
            case .ownedProfileRecord(let kind):
                if kind == "profileSnapshot" {
                    structuredRecordIDs.insert(.init(family: .profileSnapshot, id: target.id))
                }
            }
        }

        return ArchiveTombstoneInventory(
            personIDs: durablePersonIDs,
            interactionIDs: durableInteractionIDs,
            structuredRecordIDs: structuredRecordIDs
        )
    }

    private static func structuredFamily(
        forStoredKind kind: String
    ) -> ArchiveStructuredRecordFamily? {
        switch kind {
        case "context": .context
        case "cohortScheme": .cohortScheme
        case "cohort": .cohort
        case "membership": .membership
        case "cohortAssignment": .cohortAssignment
        case "roleDefinition": .roleDefinition
        case "roleAssignment": .roleAssignment
        case "education": .education
        case "assertion": .assertion
        case "source": .source
        case "artifactUnit": .artifactUnit
        case "portraitMedia": .portraitMedia
        case "evidence": .evidence
        case "reminder": .reminder
        case "commitment": .commitment
        case "savedView": .savedView
        case "attributeDefinition": .attributeDefinition
        case "textImportReview": .textImportReview
        case "personMergeEvent": .personMergeEvent
        default: nil
        }
    }

    public func exportData(scope: NotebookArchiveExportScope = .fullVault) throws -> Data {
        let archive = try NotebookArchiveSlicer().slice(exportArchive(), to: scope)
        return try ArchiveCodec.encode(archive)
    }

    public func seedExamples() {
        guard people.isEmpty else { return }
        let calendar = Calendar(identifier: .gregorian)
        let now = Date.now
        let examples = [
            Person(
                displayName: "Aiko Tanaka",
                pronunciation: "たなか あいこ",
                aliases: ["田中 愛子"],
                contexts: [String(localized: "Kizuna Scholarship · 8th cohort")],
                role: String(localized: "Community organizer"),
                tags: [String(localized: "Tokyo"), String(localized: "Japanese")],
                mentionableContext: String(localized: "She recently started organizing monthly alumni lunches."),
                circle: .community,
                contacts: [.init(kind: .line, value: "aiko_t")],
                cadenceDays: 60,
                priority: 3,
                lastInteractionAt: calendar.date(byAdding: .day, value: -88, to: now),
                sampleDataSetID: Self.exampleDataSetID
            ),
            Person(
                displayName: "Maya Chen",
                contexts: ["Northstar Studio"],
                role: String(localized: "Product designer"),
                tags: [String(localized: "Work"), String(localized: "English")],
                mentionableContext: String(localized: "Ask how the community workshop went."),
                circle: .friends,
                contacts: [.init(kind: .messages, value: "+81 90 0000 0000")],
                cadenceDays: 45,
                priority: 2,
                lastInteractionAt: calendar.date(byAdding: .day, value: -52, to: now),
                sampleDataSetID: Self.exampleDataSetID
            ),
            Person(
                displayName: "Kenji Sato",
                pronunciation: "さとう けんじ",
                aliases: ["佐藤 健司", "Sato Kenji"],
                contexts: [String(localized: "Waseda University"), String(localized: "Photography Club")],
                role: String(localized: "Alumnus"),
                tags: [String(localized: "Photography"), String(localized: "Tokyo")],
                privateNote: String(localized: "Private recall only: met near the west gate."),
                mentionableContext: String(localized: "He was preparing a small street-photography exhibition."),
                circle: .acquaintance,
                contacts: [.init(kind: .instagram, value: "@kenji.frames")],
                cadenceDays: 120,
                priority: 1,
                lastInteractionAt: calendar.date(byAdding: .day, value: -143, to: now),
                sampleDataSetID: Self.exampleDataSetID
            )
        ]
        examples.forEach { _ = save($0) }
    }

    /// Moves every seeded example to the same recoverable bin used by an
    /// ordinary person deletion. Matching is marker-based, never name-based.
    @discardableResult
    public func removeAllExamples() -> Int {
        let examples = people.filter { $0.sampleDataSetID == Self.exampleDataSetID && $0.deletedAt == nil }
        guard !examples.isEmpty else { return 0 }
        do {
            try persistence.requireWritable()
            let now = Date.now
            for example in examples {
                let object = try object(entityName: "PersonEntity", id: example.id)
                var copy = example
                copy.deletedAt = now
                copy.isArchived = false
                copy.modifiedAt = now
                encode(copy, into: object)
            }
            try context.save()
            postLocalMutationCommitted(
                source: context,
                at: now,
                storeConfigurations: [CloudSyncStoreConfiguration.vault]
            )
            reload()
            return examples.count
        } catch {
            context.rollback()
            lastError = String(localized: "The example people could not be removed. Existing data is unchanged.")
            return 0
        }
    }

    private func personIDsForPermanentDeletion(rootID: UUID) throws -> Set<UUID> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "PersonEntity")
        let storedPeople = try context.fetch(request)
        var result: Set<UUID> = [rootID]
        var changed = true
        while changed {
            changed = false
            for object in storedPeople {
                guard let id = object.value(forKey: "id") as? UUID,
                      let destinationID = object.value(forKey: "mergedIntoPersonID") as? UUID,
                      result.contains(destinationID) else { continue }
                changed = result.insert(id).inserted || changed
            }
        }
        return result
    }

    /// Stages the complete physical/reference mutation without saving it and
    /// returns the durable targets for every row that would be removed.
    private func stagePermanentDeletion(
        rootPersonID: UUID,
        deleteInteractions: Bool,
        at deletionDate: Date
    ) throws -> Set<SynchronizedDeletionTarget> {
        let deletedPersonIDs = try personIDsForPermanentDeletion(rootID: rootPersonID)
        var deletedInteractionIDs = Set<UUID>()
        let interactionRecords = try interactionRecordsForMutation()
        for (interactionObject, interaction) in interactionRecords
            where interactionReferences(interaction, personIDs: deletedPersonIDs) {
            if deleteInteractions {
                deletedInteractionIDs.insert(interaction.id)
                context.delete(interactionObject)
            } else {
                var unlinked = interaction
                var remainingAdditional = stableUniqueIDs(
                    (unlinked.additionalParticipantIDs ?? []).filter {
                        !deletedPersonIDs.contains($0)
                    }
                )
                if unlinked.personID.map(deletedPersonIDs.contains) == true {
                    unlinked.personID = remainingAdditional.first
                    if unlinked.personID != nil { remainingAdditional.removeFirst() }
                }
                if let primary = unlinked.personID {
                    remainingAdditional.removeAll { $0 == primary }
                }
                unlinked.additionalParticipantIDs = remainingAdditional.isEmpty
                    ? nil
                    : remainingAdditional
                encode(unlinked, into: interactionObject)
            }
        }
        let deletedInteractionEvidenceIDs = Set(interactionRecords
            .filter { deletedInteractionIDs.contains($0.1.id) }
            .flatMap { $0.1.sourceEvidenceIDs ?? [] })
        let retainedInteractionEvidenceIDs = Set(interactionRecords
            .filter { !deletedInteractionIDs.contains($0.1.id) }
            .flatMap { $0.1.sourceEvidenceIDs ?? [] })

        try removeCanonicalReferences(
            to: deletedPersonIDs,
            deletedInteractionIDs: deletedInteractionIDs,
            deletedInteractionEvidenceIDs: deletedInteractionEvidenceIDs,
            retainedInteractionEvidenceIDs: retainedInteractionEvidenceIDs,
            at: deletionDate
        )

        let personRequest = NSFetchRequest<NSManagedObject>(entityName: "PersonEntity")
        personRequest.predicate = NSPredicate(format: "id IN %@", Array(deletedPersonIDs))
        try context.fetch(personRequest).forEach(context.delete)
        context.processPendingChanges()

        var targets = Set(deletedPersonIDs.map {
            SynchronizedDeletionTarget.person($0)
        })
        targets.formUnion(deletedInteractionIDs.map {
            SynchronizedDeletionTarget.interaction($0)
        })
        targets.formUnion(SynchronizedDeletionMarkerRepository.targets(
            forDeletedObjects: Array(context.deletedObjects)
        ))
        return targets
    }

    /// Stages the deterministic mutation closure for synchronized deletion
    /// controls. Direct people retain unrelated interaction history by
    /// redacting participant links; directly targeted interactions are
    /// removed. Canonical roots cascade through referential dependants.
    @discardableResult
    private func stageDurableDeletionMutationClosure(
        directTargets: Set<DurableDeletionTarget>,
        at deletionDate: Date
    ) throws -> Set<DurableDeletionTarget> {
        let directPersonIDs = Set(directTargets.compactMap { target -> UUID? in
            if case .person = target.family { return target.id }
            return nil
        })
        var deletedPersonIDs = Set<UUID>()
        for personID in directPersonIDs {
            deletedPersonIDs.formUnion(
                try personIDsForPermanentDeletion(rootID: personID)
            )
        }
        let deletedInteractionIDs = Set(directTargets.compactMap { target -> UUID? in
            if case .interaction = target.family { return target.id }
            return nil
        })
        let directVaultTargets = Set(directTargets.compactMap { target -> DurableDeletionTarget? in
            if case .vaultRecord = target.family { return target }
            return nil
        })

        let interactionRecords = try interactionRecordsForMutation()
        let deletedInteractionEvidenceIDs = Set(interactionRecords
            .filter { deletedInteractionIDs.contains($0.1.id) }
            .flatMap { $0.1.sourceEvidenceIDs ?? [] })
        let retainedInteractionEvidenceIDs = Set(interactionRecords
            .filter { !deletedInteractionIDs.contains($0.1.id) }
            .flatMap { $0.1.sourceEvidenceIDs ?? [] })

        for (object, interactionBefore) in interactionRecords {
            if deletedInteractionIDs.contains(interactionBefore.id) {
                context.delete(object)
                continue
            }
            guard interactionReferences(
                interactionBefore,
                personIDs: deletedPersonIDs
            ) else { continue }
            var interactionAfter = interactionBefore
            var additional = stableUniqueIDs(
                (interactionAfter.additionalParticipantIDs ?? []).filter {
                    !deletedPersonIDs.contains($0)
                }
            )
            if interactionAfter.personID.map(deletedPersonIDs.contains) == true {
                interactionAfter.personID = additional.first
                if interactionAfter.personID != nil { additional.removeFirst() }
            }
            if let primary = interactionAfter.personID {
                additional.removeAll { $0 == primary }
            }
            interactionAfter.additionalParticipantIDs = additional.isEmpty ? nil : additional
            encode(interactionAfter, into: object)
        }

        try removeCanonicalReferences(
            to: deletedPersonIDs,
            deletedInteractionIDs: deletedInteractionIDs,
            deletedInteractionEvidenceIDs: deletedInteractionEvidenceIDs,
            retainedInteractionEvidenceIDs: retainedInteractionEvidenceIDs,
            directVaultTargets: directVaultTargets,
            at: deletionDate
        )

        var expandedDirectTargets = directTargets
        expandedDirectTargets.formUnion(deletedPersonIDs.map(DurableDeletionTarget.person))
        for entityName in Self.synchronizedEntityNames {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            for object in try context.fetch(request) {
                guard let target = Self.durableTarget(for: object),
                      expandedDirectTargets.contains(target) else { continue }
                context.delete(object)
            }
        }
        context.processPendingChanges()
        return SynchronizedDeletionMarkerRepository.targets(
            forDeletedObjects: Array(context.deletedObjects)
        )
    }

    private func interactionReferences(_ interaction: Interaction, personIDs: Set<UUID>) -> Bool {
        interaction.personID.map(personIDs.contains) == true ||
            (interaction.additionalParticipantIDs?.contains(where: personIDs.contains) ?? false)
    }

    private func interactionRecordsForMutation() throws -> [(NSManagedObject, Interaction)] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "InteractionEntity")
        return try context.fetch(request).map { object in
            guard let objectID = object.value(forKey: "id") as? UUID else {
                throw PersonMergeError.interactionChanged
            }
            if let details = object.value(forKey: "detailsData") as? Data {
                let storedPersonID = object.value(forKey: "personID") as? UUID
                guard let interaction = try? decoder.decode(Interaction.self, from: details),
                      interaction.id == objectID,
                      interaction.personID == storedPersonID else {
                    throw PersonMergeError.interactionChanged
                }
                return (object, interaction)
            }
            return (
                object,
                Interaction(
                    id: objectID,
                    personID: object.value(forKey: "personID") as? UUID,
                    occurredAt: object.value(forKey: "occurredAt") as? Date ?? .now,
                    kind: InteractionKind(rawValue: object.value(forKey: "kind") as? String ?? "") ?? .message,
                    channel: object.value(forKey: "channel") as? String ?? "",
                    status: InteractionStatus(rawValue: object.value(forKey: "status") as? String ?? "") ?? .unknown,
                    summary: object.value(forKey: "summary") as? String ?? "",
                    commitment: object.value(forKey: "commitment") as? String ?? "",
                    followUpAt: object.value(forKey: "followUpAt") as? Date
                )
            )
        }
    }

    private func stableUniqueIDs(_ values: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0).inserted }
    }

    private func recomputeLastInteractionDates(for participantIDs: [UUID]) throws {
        guard !participantIDs.isEmpty else { return }
        let targetIDs = Set(participantIDs)
        let request = NSFetchRequest<NSManagedObject>(entityName: "InteractionEntity")
        let contactDates = try context.fetch(request).compactMap(decodeInteraction).reduce(
            into: [UUID: Date](),
            { result, interaction in
                guard interaction.deletedAt == nil, interaction.status.confirmsContact else { return }
                let interactionParticipantIDs = stableUniqueIDs(
                    [interaction.personID].compactMap { $0 }
                        + (interaction.additionalParticipantIDs ?? [])
                )
                for participantID in interactionParticipantIDs where targetIDs.contains(participantID) {
                    result[participantID] = max(
                        result[participantID] ?? .distantPast,
                        interaction.occurredAt
                    )
                }
            }
        )
        for participantID in participantIDs {
            guard var participant = person(id: participantID) else { continue }
            let recalculated = contactDates[participantID]
            guard participant.lastInteractionAt != recalculated else { continue }
            participant.lastInteractionAt = recalculated
            participant.modifiedAt = .now
            let personObject = try object(entityName: "PersonEntity", id: participant.id)
            encode(participant, into: personObject)
        }
    }

    private func retargetInteraction(
        _ interaction: Interaction,
        from sourceID: UUID,
        to destinationID: UUID
    ) -> Interaction {
        var result = interaction
        if result.personID == sourceID { result.personID = destinationID }
        var additional = (result.additionalParticipantIDs ?? []).map {
            $0 == sourceID ? destinationID : $0
        }
        additional = stableUniqueIDs(additional)
        if let primary = result.personID {
            additional.removeAll { $0 == primary }
        }
        result.additionalParticipantIDs = additional.isEmpty ? nil : additional
        return result
    }

    private func retargetMutableCanonicalReferences(
        from sourceID: UUID,
        to destinationID: UUID,
        at date: Date
    ) throws -> [PersonMergeCanonicalMutation] {
        var mutations: [PersonMergeCanonicalMutation] = []
        var seenReminderIDs = Set<UUID>()
        for (object, reminderBefore) in try canonicalRecords(Reminder.self, kind: "reminder") {
            guard seenReminderIDs.insert(reminderBefore.id).inserted else {
                throw PersonMergeError.canonicalRecordChanged
            }
            guard case let .person(personID) = reminderBefore.subject,
                  personID == sourceID else { continue }
            var reminderAfter = reminderBefore
            reminderAfter.subject = .person(destinationID)
            reminderAfter.modifiedAt = date
            mutations.append(try canonicalMutation(
                object: object,
                id: reminderAfter.id,
                kind: "reminder",
                afterPayload: canonicalEncoder.encode(reminderAfter),
                modifiedAt: date
            ))
        }

        var seenCommitmentIDs = Set<UUID>()
        for (object, commitmentBefore) in try canonicalRecords(Commitment.self, kind: "commitment") {
            guard seenCommitmentIDs.insert(commitmentBefore.id).inserted else {
                throw PersonMergeError.canonicalRecordChanged
            }
            var personIDs = commitmentBefore.personIDs
            if personIDs.contains(sourceID) {
                personIDs = stableUniqueIDs(personIDs.map { $0 == sourceID ? destinationID : $0 })
            }
            var owner = commitmentBefore.owner
            switch owner {
            case let .person(personID) where personID == sourceID:
                owner = .person(destinationID)
            case let .shared(ids) where ids.contains(sourceID):
                owner = .shared(stableUniqueIDs(ids.map { $0 == sourceID ? destinationID : $0 }))
            default:
                break
            }
            guard personIDs != commitmentBefore.personIDs || owner != commitmentBefore.owner else {
                continue
            }
            let commitmentAfter = Commitment(
                id: commitmentBefore.id,
                interactionID: commitmentBefore.interactionID,
                personIDs: personIDs,
                summary: commitmentBefore.summary,
                owner: owner,
                due: commitmentBefore.due,
                sourceAssertionID: commitmentBefore.sourceAssertionID,
                createdAt: commitmentBefore.createdAt,
                modifiedAt: date,
                schemaRevision: commitmentBefore.schemaRevision
            )
            mutations.append(try canonicalMutation(
                object: object,
                id: commitmentAfter.id,
                kind: "commitment",
                afterPayload: canonicalEncoder.encode(commitmentAfter),
                modifiedAt: date
            ))
        }
        return mutations
    }

    private func canonicalMutation(
        object: NSManagedObject,
        id: UUID,
        kind: String,
        afterPayload: Data,
        modifiedAt: Date
    ) throws -> PersonMergeCanonicalMutation {
        guard let beforePayload = object.value(forKey: "payload") as? Data else {
            throw PersonMergeError.canonicalRecordChanged
        }
        let beforeModifiedAt = object.value(forKey: "modifiedAt") as? Date
        let beforeDeletedAt = object.value(forKey: "deletedAt") as? Date
        object.setValue(afterPayload, forKey: "payload")
        object.setValue(modifiedAt, forKey: "modifiedAt")
        return PersonMergeCanonicalMutation(
            id: id,
            kind: kind,
            beforePayload: beforePayload,
            afterPayload: afterPayload,
            beforeModifiedAtReferenceDate: referenceDateInterval(beforeModifiedAt),
            beforeDeletedAtReferenceDate: referenceDateInterval(beforeDeletedAt),
            afterModifiedAtReferenceDate: referenceDateInterval(modifiedAt),
            afterDeletedAtReferenceDate: referenceDateInterval(beforeDeletedAt)
        )
    }

    private func removeCanonicalReferences(
        to personIDs: Set<UUID>,
        deletedInteractionIDs: Set<UUID>,
        deletedInteractionEvidenceIDs: Set<UUID>,
        retainedInteractionEvidenceIDs: Set<UUID>,
        directVaultTargets: Set<DurableDeletionTarget> = [],
        at date: Date
    ) throws {
        var directIDsByKind: [String: Set<UUID>] = [:]
        for target in directVaultTargets {
            guard case .vaultRecord(let kind) = target.family else { continue }
            directIDsByKind[kind, default: []].insert(target.id)
        }

        let contexts = try canonicalRecords(Context.self, kind: "context")
        var deletedContextIDs = directIDsByKind["context"] ?? []
        var addedContext = true
        while addedContext {
            addedContext = false
            for (_, contextValue) in contexts {
                guard contextValue.parentContextID.map(deletedContextIDs.contains) == true else {
                    continue
                }
                addedContext = deletedContextIDs.insert(contextValue.id).inserted || addedContext
            }
        }
        let cohortSchemes = try canonicalRecords(CohortScheme.self, kind: "cohortScheme")
        var deletedCohortSchemeIDs = directIDsByKind["cohortScheme"] ?? []
        deletedCohortSchemeIDs.formUnion(cohortSchemes.compactMap { _, scheme in
            deletedContextIDs.contains(scheme.contextID) ? scheme.id : nil
        })
        let cohorts = try canonicalRecords(Cohort.self, kind: "cohort")
        var deletedCohortIDs = directIDsByKind["cohort"] ?? []
        deletedCohortIDs.formUnion(cohorts.compactMap { _, cohort in
            deletedCohortSchemeIDs.contains(cohort.schemeID) ? cohort.id : nil
        })
        let roleDefinitions = try canonicalRecords(RoleDefinition.self, kind: "roleDefinition")
        var deletedRoleDefinitionIDs = directIDsByKind["roleDefinition"] ?? []
        deletedRoleDefinitionIDs.formUnion(roleDefinitions.compactMap { _, role in
            deletedContextIDs.contains(role.contextID) ? role.id : nil
        })

        let sourceRecords = try canonicalRecords(SourceArtifact.self, kind: "source")
        let unitRecords = try canonicalRecords(ArtifactUnit.self, kind: "artifactUnit")
        let evidenceRecords = try canonicalRecords(EvidenceSpan.self, kind: "evidence")
        let deletedSourceIDs = directIDsByKind["source"] ?? []
        var directlyDeletedUnitIDs = directIDsByKind["artifactUnit"] ?? []
        directlyDeletedUnitIDs.formUnion(unitRecords.compactMap { _, unit in
            deletedSourceIDs.contains(unit.sourceID) ? unit.id : nil
        })
        var directlyDeletedEvidenceIDs = directIDsByKind["evidence"] ?? []
        directlyDeletedEvidenceIDs.formUnion(evidenceRecords.compactMap { _, evidence in
            directlyDeletedUnitIDs.contains(evidence.unitID) ? evidence.id : nil
        })

        let assertions = try canonicalRecords(AssertionEnvelope.self, kind: "assertion")
        var deletedAssertionIDs = directIDsByKind["assertion"] ?? []
        let deletedCanonicalSubjectIDs = deletedContextIDs
            .union(deletedCohortSchemeIDs)
            .union(deletedCohortIDs)
            .union(deletedRoleDefinitionIDs)
        deletedAssertionIDs.formUnion(assertions.compactMap { _, assertion in
            if personIDs.contains(assertion.subjectID) { return assertion.id }
            if deletedCanonicalSubjectIDs.contains(assertion.subjectID) { return assertion.id }
            if case let .personReference(personID) = assertion.value,
               personIDs.contains(personID) { return assertion.id }
            if assertion.sourceID.map(deletedSourceIDs.contains) == true { return assertion.id }
            if !Set(assertion.evidenceIDs).intersection(directlyDeletedEvidenceIDs).isEmpty {
                return assertion.id
            }
            return nil
        })
        var addedAssertion = true
        while addedAssertion {
            addedAssertion = false
            for (_, assertion) in assertions {
                guard let predecessorID = assertion.supersedesID,
                      deletedAssertionIDs.contains(predecessorID) else { continue }
                addedAssertion = deletedAssertionIDs.insert(assertion.id).inserted || addedAssertion
            }
        }

        try removeImportProvenanceReferences(
            assertions: assertions.map(\.1),
            deletedAssertionIDs: deletedAssertionIDs,
            deletedPersonIDs: personIDs,
            deletedInteractionEvidenceIDs: deletedInteractionEvidenceIDs
                .union(directlyDeletedEvidenceIDs),
            retainedInteractionEvidenceIDs: retainedInteractionEvidenceIDs,
            at: date
        )
        for (object, evidence) in evidenceRecords
            where directlyDeletedEvidenceIDs.contains(evidence.id) {
            context.delete(object)
        }
        for (object, unit) in unitRecords where directlyDeletedUnitIDs.contains(unit.id) {
            context.delete(object)
        }
        for (object, source) in sourceRecords where deletedSourceIDs.contains(source.id) {
            context.delete(object)
        }
        for (object, review) in try canonicalRecords(
            TextImportReview.self,
            id: \.source.id,
            kind: "textImportReview"
        ) where deletedSourceIDs.contains(review.source.id) {
            context.delete(object)
        }

        let memberships = try canonicalRecords(MembershipEpisode.self, kind: "membership")
        var deletedMembershipIDs = directIDsByKind["membership"] ?? []
        deletedMembershipIDs.formUnion(memberships.compactMap { _, membership in
            personIDs.contains(membership.personID) ||
                deletedContextIDs.contains(membership.contextID) ||
                membership.assertionID.map(deletedAssertionIDs.contains) == true
                ? membership.id : nil
        })
        let cohortAssignments = try canonicalRecords(CohortAssignment.self, kind: "cohortAssignment")
        let roleAssignments = try canonicalRecords(RoleAssignment.self, kind: "roleAssignment")
        let education = try canonicalRecords(EducationEnrollment.self, kind: "education")

        let deletedCohortAssignmentIDs = (directIDsByKind["cohortAssignment"] ?? [])
            .union(cohortAssignments.compactMap { _, assignment in
                deletedMembershipIDs.contains(assignment.membershipEpisodeID) ||
                    deletedCohortIDs.contains(assignment.cohortID) ||
                    assignment.assertionID.map(deletedAssertionIDs.contains) == true
                    ? assignment.id : nil
            })
        let deletedRoleAssignmentIDs = (directIDsByKind["roleAssignment"] ?? [])
            .union(roleAssignments.compactMap { _, assignment in
                deletedMembershipIDs.contains(assignment.membershipEpisodeID) ||
                    assignment.roleDefinitionID.map(deletedRoleDefinitionIDs.contains) == true ||
                    assignment.assertionID.map(deletedAssertionIDs.contains) == true
                    ? assignment.id : nil
            })
        let deletedEducationIDs = (directIDsByKind["education"] ?? [])
            .union(education.compactMap { _, enrollment in
                personIDs.contains(enrollment.personID) ||
                    deletedContextIDs.contains(enrollment.institutionContextID) ||
                    enrollment.assertionID.map(deletedAssertionIDs.contains) == true
                    ? enrollment.id : nil
            })

        for (object, value) in contexts where deletedContextIDs.contains(value.id) {
            context.delete(object)
        }
        for (object, value) in cohortSchemes where deletedCohortSchemeIDs.contains(value.id) {
            context.delete(object)
        }
        for (object, value) in cohorts where deletedCohortIDs.contains(value.id) {
            context.delete(object)
        }
        for (object, value) in roleDefinitions where deletedRoleDefinitionIDs.contains(value.id) {
            context.delete(object)
        }

        for (object, assertion) in assertions where deletedAssertionIDs.contains(assertion.id) {
            context.delete(object)
        }
        for (object, membership) in memberships where deletedMembershipIDs.contains(membership.id) {
            context.delete(object)
        }
        for (object, assignment) in cohortAssignments where
            deletedCohortAssignmentIDs.contains(assignment.id) {
            context.delete(object)
        }
        for (object, assignment) in roleAssignments where
            deletedRoleAssignmentIDs.contains(assignment.id) {
            context.delete(object)
        }
        for (object, enrollment) in education where
            deletedEducationIDs.contains(enrollment.id) {
            context.delete(object)
        }
        let directPortraitIDs = directIDsByKind["portraitMedia"] ?? []
        let portraitsToDelete = try canonicalRecords(PortraitMediaAsset.self, kind: "portraitMedia")
            .filter { personIDs.contains($0.1.personID) || directPortraitIDs.contains($0.1.id) }
        let portraitIDsToDelete = Set(portraitsToDelete.map { $0.1.id })
        for (object, _) in portraitsToDelete {
            context.delete(object)
        }
        if !portraitIDsToDelete.isEmpty {
            let payloadRequest = NSFetchRequest<NSManagedObject>(entityName: "MediaPayloadEntity")
            payloadRequest.predicate = NSPredicate(
                format: "id IN %@",
                Array(portraitIDsToDelete)
            )
            try context.fetch(payloadRequest).forEach(context.delete)
        }

        for (object, reminder) in try canonicalRecords(Reminder.self, kind: "reminder") {
            var shouldDelete = (directIDsByKind["reminder"] ?? []).contains(reminder.id)
            switch reminder.subject {
            case let .person(personID):
                shouldDelete = shouldDelete || personIDs.contains(personID)
            case let .interaction(interactionID):
                shouldDelete = shouldDelete || deletedInteractionIDs.contains(interactionID)
            case let .assertion(assertionID):
                shouldDelete = shouldDelete || deletedAssertionIDs.contains(assertionID)
            case let .context(contextID):
                shouldDelete = shouldDelete || deletedContextIDs.contains(contextID)
            case let .commitment(commitmentID):
                shouldDelete = shouldDelete ||
                    (directIDsByKind["commitment"] ?? []).contains(commitmentID)
            }
            if shouldDelete { context.delete(object) }
        }

        for (object, commitmentBefore) in try canonicalRecords(Commitment.self, kind: "commitment") {
            let filteredPersonIDs = commitmentBefore.personIDs.filter { !personIDs.contains($0) }
            var owner = commitmentBefore.owner
            switch owner {
            case let .person(personID) where personIDs.contains(personID):
                owner = .unspecified
            case let .shared(ownerIDs) where ownerIDs.contains(where: personIDs.contains):
                let filtered = stableUniqueIDs(ownerIDs.filter { !personIDs.contains($0) })
                owner = filtered.isEmpty ? .unspecified : .shared(filtered)
            default:
                break
            }
            let interactionID = commitmentBefore.interactionID.flatMap {
                deletedInteractionIDs.contains($0) ? nil : $0
            }
            let sourceAssertionID = commitmentBefore.sourceAssertionID.flatMap {
                deletedAssertionIDs.contains($0) ? nil : $0
            }
            guard filteredPersonIDs != commitmentBefore.personIDs ||
                    owner != commitmentBefore.owner ||
                    interactionID != commitmentBefore.interactionID ||
                    sourceAssertionID != commitmentBefore.sourceAssertionID else { continue }
            let commitmentAfter = Commitment(
                id: commitmentBefore.id,
                interactionID: interactionID,
                personIDs: filteredPersonIDs,
                summary: commitmentBefore.summary,
                owner: owner,
                due: commitmentBefore.due,
                sourceAssertionID: sourceAssertionID,
                createdAt: commitmentBefore.createdAt,
                modifiedAt: date,
                schemaRevision: commitmentBefore.schemaRevision
            )
            object.setValue(try canonicalEncoder.encode(commitmentAfter), forKey: "payload")
            object.setValue(date, forKey: "modifiedAt")
        }

        for (object, event) in try canonicalRecords(PersonMergeEvent.self, kind: "personMergeEvent")
            where (directIDsByKind["personMergeEvent"] ?? []).contains(event.id) ||
                personIDs.contains(event.sourcePersonBeforeMerge.id) ||
                personIDs.contains(event.destinationPersonBeforeMerge.id) {
            context.delete(object)
        }
    }

    private func removeImportProvenanceReferences(
        assertions: [AssertionEnvelope],
        deletedAssertionIDs: Set<UUID>,
        deletedPersonIDs: Set<UUID>,
        deletedInteractionEvidenceIDs: Set<UUID>,
        retainedInteractionEvidenceIDs: Set<UUID>,
        at date: Date
    ) throws {
        let sourceRecords = try canonicalRecords(SourceArtifact.self, kind: "source")
        let unitRecords = try canonicalRecords(ArtifactUnit.self, kind: "artifactUnit")
        let evidenceRecords = try canonicalRecords(EvidenceSpan.self, kind: "evidence")
        let reviewRecords = try canonicalRecords(
            TextImportReview.self,
            id: \.source.id,
            kind: "textImportReview"
        )

        var unitsByID: [UUID: ArtifactUnit] = [:]
        for (_, unit) in unitRecords {
            guard unitsByID.updateValue(unit, forKey: unit.id) == nil else {
                throw PersonMergeError.canonicalRecordChanged
            }
        }
        var evidenceByID: [UUID: EvidenceSpan] = [:]
        for (_, evidence) in evidenceRecords {
            guard evidenceByID.updateValue(evidence, forKey: evidence.id) == nil else {
                throw PersonMergeError.canonicalRecordChanged
            }
        }

        func sourceIDs(for evidenceIDs: Set<UUID>) -> Set<UUID> {
            Set(evidenceIDs.compactMap { evidenceID in
                guard let unitID = evidenceByID[evidenceID]?.unitID else { return nil }
                return unitsByID[unitID]?.sourceID
            })
        }

        let survivingAssertions = assertions.filter { !deletedAssertionIDs.contains($0.id) }
        let deletedAssertions = assertions.filter { deletedAssertionIDs.contains($0.id) }
        let survivingAssertionEvidenceIDs = Set(survivingAssertions.flatMap(\.evidenceIDs))
        let deletedAssertionEvidenceIDs = Set(deletedAssertions.flatMap(\.evidenceIDs))
        let protectedDependencyEvidenceIDs = survivingAssertionEvidenceIDs
            .union(retainedInteractionEvidenceIDs)
        let removedDependencyEvidenceIDs = deletedAssertionEvidenceIDs
            .union(deletedInteractionEvidenceIDs)
        let deletedOnlyEvidenceIDs = removedDependencyEvidenceIDs
            .subtracting(protectedDependencyEvidenceIDs)
        let personRequest = NSFetchRequest<NSManagedObject>(entityName: "PersonEntity")
        let survivingPersonIDs = Set(try context.fetch(personRequest).compactMap { object in
            guard let person = decodePerson(object), person.deletedAt == nil else { return nil }
            return person.id
        }).subtracting(deletedPersonIDs)

        var protectedSourceIDs = Set(survivingAssertions.compactMap(\.sourceID))
            .union(sourceIDs(for: retainedInteractionEvidenceIDs))
        var affectedSourceIDs = Set(deletedAssertions.compactMap(\.sourceID))
            .union(sourceIDs(for: removedDependencyEvidenceIDs))
        var retainedReviewEvidenceIDs = Set<UUID>()
        var removedReviewEvidenceIDs = Set<UUID>()
        var reviewUpdates: [(object: NSManagedObject, value: TextImportReview?)] = []

        for (object, reviewBefore) in reviewRecords {
            let sourceID = reviewBefore.source.id
            let directDeletedCandidateIDs = Set(reviewBefore.candidates.compactMap { candidate in
                deletedPersonIDs.contains(candidate.id) ? candidate.id : nil
            })
            let sourceWasAlreadyAffected = affectedSourceIDs.contains(sourceID)
            guard sourceWasAlreadyAffected || !directDeletedCandidateIDs.isEmpty else { continue }

            let reviewEvidenceIDs = Set(reviewBefore.evidence.map(\.id))
            var candidates = reviewBefore.candidates.filter { candidate in
                if directDeletedCandidateIDs.contains(candidate.id) { return false }
                if survivingPersonIDs.contains(candidate.id) { return true }
                let assertionEvidenceIDs = Set(candidate.assertions.flatMap(\.evidenceIDs))
                return assertionEvidenceIDs.intersection(deletedOnlyEvidenceIDs).isEmpty ||
                    !assertionEvidenceIDs.intersection(protectedDependencyEvidenceIDs).isEmpty
            }
            let retainedCandidateIDs = Set(candidates.map(\.id))
            if retainedCandidateIDs.count != reviewBefore.candidates.count {
                affectedSourceIDs.insert(sourceID)
            }

            candidates = candidates.map { candidateBefore in
                var candidate = candidateBefore
                candidate.possibleDuplicateCandidateIDs = candidate.possibleDuplicateCandidateIDs.filter(
                    retainedCandidateIDs.contains
                )
                candidate.evidenceIDs = candidate.evidenceIDs.filter {
                    reviewEvidenceIDs.contains($0) && !deletedOnlyEvidenceIDs.contains($0)
                }
                candidate.assertions = candidate.assertions.compactMap { assertionBefore in
                    let retainedIDs = assertionBefore.evidenceIDs.filter {
                        reviewEvidenceIDs.contains($0) && !deletedOnlyEvidenceIDs.contains($0)
                    }
                    if !assertionBefore.evidenceIDs.isEmpty && retainedIDs.isEmpty {
                        return nil
                    }
                    var assertion = assertionBefore
                    assertion.evidenceIDs = retainedIDs
                    return assertion
                }
                return candidate
            }

            let candidateEvidenceIDs = Set(candidates.flatMap { candidate in
                candidate.evidenceIDs + candidate.assertions.flatMap(\.evidenceIDs)
            })
            let safetyFindings = reviewBefore.safetyFindings.filter {
                reviewEvidenceIDs.contains($0.evidenceID) && !deletedOnlyEvidenceIDs.contains($0.evidenceID)
            }
            let requiredReviewEvidenceIDs = candidateEvidenceIDs
                .union(safetyFindings.map(\.evidenceID))
                .union(protectedDependencyEvidenceIDs)
            let retainedEvidence = reviewBefore.evidence.filter {
                requiredReviewEvidenceIDs.contains($0.id)
            }
            let retainedEvidenceIDs = Set(retainedEvidence.map(\.id))
            retainedReviewEvidenceIDs.formUnion(retainedEvidenceIDs)
            removedReviewEvidenceIDs.formUnion(reviewEvidenceIDs.subtracting(retainedEvidenceIDs))

            var reviewAfter = reviewBefore
            reviewAfter.candidates = candidates
            reviewAfter.evidence = retainedEvidence
            reviewAfter.safetyFindings = safetyFindings.filter {
                retainedEvidenceIDs.contains($0.evidenceID)
            }

            let sourceHasSurvivingDependency = protectedSourceIDs.contains(sourceID)
            let reviewHasRetainedContent = !reviewAfter.candidates.isEmpty ||
                !reviewAfter.safetyFindings.isEmpty
            if sourceHasSurvivingDependency || reviewHasRetainedContent {
                protectedSourceIDs.insert(sourceID)
                if reviewAfter != reviewBefore {
                    reviewUpdates.append((object, reviewAfter))
                }
            } else {
                reviewUpdates.append((object, nil))
            }
        }

        protectedSourceIDs.formUnion(sourceIDs(for: retainedReviewEvidenceIDs))
        let deletedSourceIDs = affectedSourceIDs.subtracting(protectedSourceIDs)
        let protectedEvidenceIDs = protectedDependencyEvidenceIDs.union(retainedReviewEvidenceIDs)
        var deletedEvidenceIDs = Set<UUID>()
        for (object, evidence) in evidenceRecords {
            let sourceID = unitsByID[evidence.unitID]?.sourceID
            let sourceIsDeleted = sourceID.map(deletedSourceIDs.contains) == true
            let evidenceIsExclusivelyRemoved = removedDependencyEvidenceIDs.contains(evidence.id) ||
                removedReviewEvidenceIDs.contains(evidence.id)
            if sourceIsDeleted || (evidenceIsExclusivelyRemoved && !protectedEvidenceIDs.contains(evidence.id)) {
                deletedEvidenceIDs.insert(evidence.id)
                context.delete(object)
            }
        }

        let deletedEvidenceUnitIDs = Set(deletedEvidenceIDs.compactMap { evidenceByID[$0]?.unitID })
        let survivingEvidenceUnitIDs = Set(evidenceRecords.compactMap { _, evidence in
            deletedEvidenceIDs.contains(evidence.id) ? nil : evidence.unitID
        })
        for (object, unit) in unitRecords where
            deletedSourceIDs.contains(unit.sourceID) ||
                (deletedEvidenceUnitIDs.contains(unit.id) && !survivingEvidenceUnitIDs.contains(unit.id)) {
            context.delete(object)
        }
        for (object, source) in sourceRecords where deletedSourceIDs.contains(source.id) {
            context.delete(object)
        }
        for update in reviewUpdates {
            let sourceID = update.value?.source.id ?? (update.object.value(forKey: "id") as? UUID)
            guard let sourceID else { throw PersonMergeError.canonicalRecordChanged }
            if deletedSourceIDs.contains(sourceID) || update.value == nil {
                context.delete(update.object)
            } else if let review = update.value {
                update.object.setValue(try canonicalEncoder.encode(review), forKey: "payload")
                update.object.setValue(date, forKey: "modifiedAt")
            }
        }
    }

    private func canonicalRecords<Value: Decodable & Identifiable>(
        _ type: Value.Type,
        kind: String
    ) throws -> [(NSManagedObject, Value)] where Value.ID == UUID {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
        request.predicate = NSPredicate(format: "kind == %@", kind)
        return try context.fetch(request).map { object in
            guard let id = object.value(forKey: "id") as? UUID,
                  let payload = object.value(forKey: "payload") as? Data,
                  let value = try? canonicalDecoder.decode(type, from: payload),
                  value.id == id else {
                throw PersonMergeError.canonicalRecordChanged
            }
            return (object, value)
        }
    }

    private func canonicalRecords<Value: Decodable>(
        _ type: Value.Type,
        id: KeyPath<Value, UUID>,
        kind: String
    ) throws -> [(NSManagedObject, Value)] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
        request.predicate = NSPredicate(format: "kind == %@", kind)
        return try context.fetch(request).map { object in
            guard let objectID = object.value(forKey: "id") as? UUID,
                  let payload = object.value(forKey: "payload") as? Data,
                  let value = try? canonicalDecoder.decode(type, from: payload),
                  value[keyPath: id] == objectID else {
                throw PersonMergeError.canonicalRecordChanged
            }
            return (object, value)
        }
    }

    private func uniqueCanonicalObject(id: UUID, kind: String) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
        request.predicate = NSPredicate(format: "id == %@ AND kind == %@", id as CVarArg, kind)
        let objects = try context.fetch(request)
        guard objects.count == 1 else { throw PersonMergeError.canonicalRecordChanged }
        return objects[0]
    }

    private func referenceDateInterval(_ date: Date?) -> TimeInterval? {
        date?.timeIntervalSinceReferenceDate
    }

    private static func rejectedTarget(
        in error: SynchronizedDeletionMarkerError
    ) -> SynchronizedDeletionTarget? {
        switch error {
        case .targetWasPermanentlyDeleted(let target),
             .targetPredatesCurrentVaultGeneration(let target):
            target
        case .reservedSynchronizationKind,
             .invalidDurableDeletionState,
             .unsavedChangesPreventReconciliation:
            nil
        }
    }

    private func captureRejectedEdit(_ person: Person) throws {
        let object = try detachedObject(entityName: "PersonEntity")
        encode(person, into: object)
        try captureRejectedEdit(object, entity: .person)
    }

    private func captureRejectedEdit(_ interaction: Interaction) throws {
        let object = try detachedObject(entityName: "InteractionEntity")
        encode(interaction, into: object)
        try captureRejectedEdit(object, entity: .interaction)
    }

    private func captureRejectedEdit(
        _ object: NSManagedObject,
        entity: RecoverableDeletionEntity
    ) throws {
        let row = try RecoverableDeletionCheckpointRepository.makeRow(
            from: object,
            entity: entity
        )
        let repository = DeletionConflictDraftRepository(persistence: persistence)
        guard try repository.stageCapture(rows: [row]) > 0 else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func detachedObject(entityName: String) throws -> NSManagedObject {
        guard let entity = persistence.container.managedObjectModel.entitiesByName[entityName] else {
            throw DeletionConflictDraftError.unsupportedSourceEntity(entityName)
        }
        return NSManagedObject(entity: entity, insertInto: nil)
    }

    private func object(entityName: String, id: UUID) throws -> NSManagedObject {
        let deletionMarkers = SynchronizedDeletionMarkerRepository(persistence: persistence)
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let existing = try context.fetch(request).first
        let target: SynchronizedDeletionTarget?
        switch entityName {
        case "PersonEntity":
            target = .person(id)
        case "InteractionEntity":
            target = .interaction(id)
        default:
            target = nil
        }
        let preparation = try target.map {
            try deletionMarkers.writePreparation(
                for: $0,
                existingObjects: existing.map { [$0] } ?? []
            )
        }
        let object = existing ?? NSEntityDescription.insertNewObject(
            forEntityName: entityName,
            into: context
        )
        if let preparation {
            _ = try deletionMarkers.stamp(preparation, on: [object])
        }
        return object
    }

    private func encodeRecords<Value: Encodable & Identifiable>(
        _ values: [Value],
        kind: String,
        entityName: String = "CanonicalRecordEntity"
    ) throws where Value.ID == UUID {
        try encodeRecords(values, id: \.id, kind: kind, entityName: entityName)
    }

    private func encodeRecords<Value: Encodable>(
        _ values: [Value],
        id: KeyPath<Value, UUID>,
        kind: String,
        entityName: String = "CanonicalRecordEntity"
    ) throws {
        for value in values {
            let recordID = value[keyPath: id]
            let object = try recordObject(entityName: entityName, id: recordID, kind: kind)
            let now = Date.now
            if object.value(forKey: "createdAt") == nil { object.setValue(now, forKey: "createdAt") }
            object.setValue(recordID, forKey: "id")
            object.setValue(kind, forKey: "kind")
            object.setValue(try canonicalEncoder.encode(value), forKey: "payload")
            object.setValue(now, forKey: "modifiedAt")
            object.setValue(nil, forKey: "deletedAt")
        }
    }

    private func recordObject(entityName: String, id: UUID, kind: String) throws -> NSManagedObject {
        let deletionMarkers = SynchronizedDeletionMarkerRepository(persistence: persistence)
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@ AND kind == %@", id as CVarArg, kind)
        let existing = try context.fetch(request).first
        let target: SynchronizedDeletionTarget?
        switch entityName {
        case "CanonicalRecordEntity":
            target = .vaultRecord(id: id, kind: kind)
        case "ProfileRecordEntity":
            target = .ownedProfileRecord(id: id, kind: kind)
        default:
            target = nil
        }
        let preparation = try target.map {
            try deletionMarkers.writePreparation(
                for: $0,
                existingObjects: existing.map { [$0] } ?? []
            )
        }
        let object = existing ?? NSEntityDescription.insertNewObject(
            forEntityName: entityName,
            into: context
        )
        if let preparation {
            _ = try deletionMarkers.stamp(preparation, on: [object])
        }
        return object
    }

    private func encode(_ person: Person, into object: NSManagedObject) {
        object.setValue(person.id, forKey: "id")
        object.setValue(person.displayName, forKey: "displayName")
        object.setValue(person.pronunciation, forKey: "pronunciation")
        object.setValue(try? encoder.encode(person.aliases), forKey: "aliasesData")
        object.setValue(try? encoder.encode(person.nameVariants ?? []), forKey: "nameVariantsData")
        object.setValue(try? encoder.encode(person.contexts), forKey: "contextsData")
        object.setValue(person.role, forKey: "role")
        object.setValue(try? encoder.encode(person.tags), forKey: "tagsData")
        object.setValue(person.privateNote, forKey: "privateNote")
        object.setValue(person.mentionableContext, forKey: "mentionableContext")
        object.setValue(person.circle.rawValue, forKey: "circle")
        object.setValue(try? encoder.encode(person.contacts), forKey: "contactsData")
        if object.entity.attributesByName["relationshipPreferencesData"] != nil {
            let preferences = PersistedPersonRelationshipPreferences(
                recipientTimeZoneIdentifier: person.recipientTimeZoneIdentifier,
                communicationPreferences: person.communicationPreferences,
                linkedContactIdentifier: person.linkedContactIdentifier
            )
            object.setValue(
                try? encoder.encode(preferences),
                forKey: "relationshipPreferencesData"
            )
        }
        object.setValue(person.cadenceDays, forKey: "cadenceDays")
        object.setValue(person.priority, forKey: "priority")
        object.setValue(person.createdAt, forKey: "createdAt")
        object.setValue(person.modifiedAt, forKey: "modifiedAt")
        object.setValue(person.lastInteractionAt, forKey: "lastInteractionAt")
        object.setValue(person.snoozedUntil, forKey: "snoozedUntil")
        object.setValue(person.isArchived, forKey: "isArchived")
        object.setValue(person.neverSuggest, forKey: "neverSuggest")
        object.setValue(person.doNotContact, forKey: "doNotContact")
        object.setValue(person.deletedAt, forKey: "deletedAt")
        object.setValue(person.mergedIntoPersonID, forKey: "mergedIntoPersonID")
        object.setValue(person.isSelf, forKey: "isSelfIdentity")
        object.setValue(person.sampleDataSetID, forKey: "sampleDataSetID")
    }

    private func decodePerson(_ object: NSManagedObject) -> Person? {
        guard let id = object.value(forKey: "id") as? UUID,
              let displayName = object.value(forKey: "displayName") as? String else { return nil }
        let relationshipPreferences = decodeRelationshipPreferences(from: object)
        return Person(
            id: id,
            displayName: displayName,
            pronunciation: object.value(forKey: "pronunciation") as? String ?? "",
            aliases: decodeStrings(from: object.value(forKey: "aliasesData")),
            contexts: decodeStrings(from: object.value(forKey: "contextsData")),
            role: object.value(forKey: "role") as? String ?? "",
            tags: decodeStrings(from: object.value(forKey: "tagsData")),
            privateNote: object.value(forKey: "privateNote") as? String ?? "",
            mentionableContext: object.value(forKey: "mentionableContext") as? String ?? "",
            circle: RelationshipCircle(rawValue: object.value(forKey: "circle") as? String ?? "") ?? .acquaintance,
            contacts: decodeContacts(from: object.value(forKey: "contactsData")),
            recipientTimeZoneIdentifier: relationshipPreferences?.recipientTimeZoneIdentifier,
            communicationPreferences: relationshipPreferences?.communicationPreferences,
            linkedContactIdentifier: relationshipPreferences?.linkedContactIdentifier,
            cadenceDays: object.value(forKey: "cadenceDays") as? Int ?? 90,
            priority: object.value(forKey: "priority") as? Int ?? 2,
            createdAt: object.value(forKey: "createdAt") as? Date ?? .now,
            modifiedAt: object.value(forKey: "modifiedAt") as? Date ?? .now,
            lastInteractionAt: object.value(forKey: "lastInteractionAt") as? Date,
            snoozedUntil: object.value(forKey: "snoozedUntil") as? Date,
            isArchived: object.value(forKey: "isArchived") as? Bool ?? false,
            neverSuggest: object.value(forKey: "neverSuggest") as? Bool ?? false,
            doNotContact: object.value(forKey: "doNotContact") as? Bool ?? false,
            deletedAt: object.value(forKey: "deletedAt") as? Date,
            mergedIntoPersonID: object.value(forKey: "mergedIntoPersonID") as? UUID,
            nameVariants: decodeNameVariants(from: object.value(forKey: "nameVariantsData")),
            isSelf: object.value(forKey: "isSelfIdentity") as? Bool ?? false,
            sampleDataSetID: object.value(forKey: "sampleDataSetID") as? UUID
        )
    }

    private func decodeNameVariants(from value: Any?) -> [PersonNameVariant]? {
        guard let data = value as? Data,
              let variants = try? decoder.decode([PersonNameVariant].self, from: data),
              !variants.isEmpty else { return nil }
        return variants
    }

    private func encode(_ interaction: Interaction, into object: NSManagedObject) {
        object.setValue(interaction.id, forKey: "id")
        object.setValue(interaction.personID, forKey: "personID")
        object.setValue(interaction.occurredAt, forKey: "occurredAt")
        object.setValue(interaction.kind.rawValue, forKey: "kind")
        object.setValue(interaction.channel, forKey: "channel")
        object.setValue(interaction.status.rawValue, forKey: "status")
        object.setValue(interaction.summary, forKey: "summary")
        object.setValue(interaction.commitment, forKey: "commitment")
        object.setValue(interaction.followUpAt, forKey: "followUpAt")
        object.setValue(try? encoder.encode(interaction), forKey: "detailsData")
    }

    private func decodeInteraction(_ object: NSManagedObject) -> Interaction? {
        if let data = object.value(forKey: "detailsData") as? Data,
           let value = try? decoder.decode(Interaction.self, from: data) {
            return value
        }
        guard let id = object.value(forKey: "id") as? UUID else { return nil }
        return Interaction(
            id: id,
            personID: object.value(forKey: "personID") as? UUID,
            occurredAt: object.value(forKey: "occurredAt") as? Date ?? .now,
            kind: InteractionKind(rawValue: object.value(forKey: "kind") as? String ?? "") ?? .message,
            channel: object.value(forKey: "channel") as? String ?? "",
            status: InteractionStatus(rawValue: object.value(forKey: "status") as? String ?? "") ?? .unknown,
            summary: object.value(forKey: "summary") as? String ?? "",
            commitment: object.value(forKey: "commitment") as? String ?? "",
            followUpAt: object.value(forKey: "followUpAt") as? Date
        )
    }

    private func decodeStrings(from value: Any?) -> [String] {
        guard let data = value as? Data else { return [] }
        return (try? decoder.decode([String].self, from: data)) ?? []
    }

    private func decodeContacts(from value: Any?) -> [ContactMethod] {
        guard let data = value as? Data else { return [] }
        return (try? decoder.decode([ContactMethod].self, from: data)) ?? []
    }

    private func decodeRelationshipPreferences(
        from object: NSManagedObject
    ) -> PersistedPersonRelationshipPreferences? {
        guard object.entity.attributesByName["relationshipPreferencesData"] != nil,
              let data = object.value(forKey: "relationshipPreferencesData") as? Data else {
            return nil
        }
        return try? decoder.decode(PersistedPersonRelationshipPreferences.self, from: data)
    }
}

private struct PersistedPersonRelationshipPreferences: Codable {
    var recipientTimeZoneIdentifier: String?
    var communicationPreferences: String?
    var linkedContactIdentifier: String?
}
