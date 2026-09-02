import CoreData
import CryptoKit
import Foundation

/// The physical Core Data rows whose soft-deleted payloads are intentionally
/// retained during a protected local-to-iCloud migration checkpoint.
public enum RecoverableDeletionEntity: String, Codable, CaseIterable, Hashable, Sendable {
    case person
    case interaction
    case canonicalRecord
    case ownedProfileRecord
    case mediaPayload

    fileprivate var entityName: String {
        switch self {
        case .person: "PersonEntity"
        case .interaction: "InteractionEntity"
        case .canonicalRecord: "CanonicalRecordEntity"
        case .ownedProfileRecord: "ProfileRecordEntity"
        case .mediaPayload: "MediaPayloadEntity"
        }
    }

    fileprivate var storeConfiguration: String {
        self == .ownedProfileRecord
            ? CloudSyncStoreConfiguration.ownedProfiles
            : CloudSyncStoreConfiguration.vault
    }
}

/// Stable physical-row identity. Portrait metadata and bytes have distinct
/// row keys but share one durable deletion target and are planned as a unit.
public struct RecoverableDeletionRowKey: Codable, Hashable, Sendable {
    public var entity: RecoverableDeletionEntity
    public var id: UUID
    public var kind: String?

    public init(entity: RecoverableDeletionEntity, id: UUID, kind: String? = nil) {
        self.entity = entity
        self.id = id
        self.kind = kind
    }

    public var durableDeletionTarget: DurableDeletionTarget {
        switch entity {
        case .person:
            .person(id)
        case .interaction:
            .interaction(id)
        case .canonicalRecord:
            .vaultRecord(id: id, kind: kind ?? "")
        case .ownedProfileRecord:
            .ownedProfileRecord(id: id, kind: kind ?? "")
        case .mediaPayload:
            .vaultRecord(id: id, kind: "portraitMedia")
        }
    }
}

/// Lossless values for the allowlisted Core Data attribute types used by the
/// synchronized stores. Optional nil attributes are represented by absence.
public enum RecoverableDeletionAttributeValue: Codable, Equatable, Sendable {
    case string(String)
    case data(Data)
    case date(Date)
    case uuid(UUID)
    case integer(Int64)
    case boolean(Bool)
    case double(Double)
}

public struct RecoverableDeletionRow: Codable, Equatable, Sendable {
    public var key: RecoverableDeletionRowKey
    public var attributes: [String: RecoverableDeletionAttributeValue]

    public init(
        key: RecoverableDeletionRowKey,
        attributes: [String: RecoverableDeletionAttributeValue]
    ) {
        self.key = key
        self.attributes = attributes
    }
}

/// This payload is deliberately separate from the normal archive. It can
/// contain deleted private values and must remain inside the protected
/// migration checkpoint/recovery files.
public struct RecoverableDeletionCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var rows: [RecoverableDeletionRow]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        rows: [RecoverableDeletionRow] = []
    ) {
        self.schemaVersion = schemaVersion
        self.rows = rows
    }

    public var isEmpty: Bool { rows.isEmpty }
}

public struct RecoverableDeletionProtectedDestinationValue: Codable, Equatable, Sendable {
    public var key: RecoverableDeletionRowKey
    /// One entry per physical row. Multiple entries are retained so a corrupt
    /// duplicate destination can never be silently collapsed or overwritten.
    public var rowFingerprints: [String]

    public init(key: RecoverableDeletionRowKey, rowFingerprints: [String]) {
        self.key = key
        self.rowFingerprints = rowFingerprints
    }
}

/// A create-only plan. Rows sharing a durable target are classified together,
/// preventing a deleted portrait payload from being inserted beside conflicting
/// active portrait metadata (or vice versa).
public struct RecoverableDeletionImportPlan: Codable, Equatable, Sendable {
    public var sourceCheckpointFingerprint: String
    public var sourceDurableStateFingerprint: String
    public var destinationFingerprint: String
    public var destinationDurableStateFingerprint: String
    public var sourceRows: [RecoverableDeletionRow]
    public var rowsToCreate: [RecoverableDeletionRow]
    public var unchangedKeys: Set<RecoverableDeletionRowKey>
    public var conflictingKeys: Set<RecoverableDeletionRowKey>
    public var blockedBySourceDurableDeletionKeys: Set<RecoverableDeletionRowKey>
    public var blockedByDestinationDurableDeletionKeys: Set<RecoverableDeletionRowKey>
    public var protectedDestinationValues: [RecoverableDeletionProtectedDestinationValue]
    public var expectedAbsentKeys: Set<RecoverableDeletionRowKey>

    public var hasRowsToCreate: Bool { !rowsToCreate.isEmpty }
    /// Soft-deleted people that will exist in the destination after this plan.
    /// Migration review can treat these stable IDs as satisfying references
    /// from active interactions and canonical records without making the people
    /// active or exposing their payloads in the normal archive.
    public var acceptedRecoverablePersonKeys: Set<RecoverableDeletionRowKey> {
        Set(rowsToCreate.lazy
            .filter { $0.key.entity == .person }
            .map(\.key))
            .union(unchangedKeys.lazy
                .filter { $0.entity == .person }
            )
    }
    public var acceptedRecoverablePersonIDs: Set<UUID> {
        Set(acceptedRecoverablePersonKeys.map(\.id))
    }
    public var acceptedRecoverablePersonCount: Int {
        acceptedRecoverablePersonIDs.count
    }
    public var requiresAttention: Bool {
        !conflictingKeys.isEmpty ||
            !blockedBySourceDurableDeletionKeys.isEmpty ||
            !blockedByDestinationDurableDeletionKeys.isEmpty
    }
}

/// Pure, non-mutating classification used before a reviewed migration applies
/// deletion controls to its iCloud destination. It projects away the exact
/// destination targets that those controls would remove, then proves that no
/// recoverable source row will become impossible to copy afterward.
public struct RecoverableDeletionImportPreflight: Equatable, Sendable {
    public var sourceRows: [RecoverableDeletionRow]
    public var rowsToCreate: [RecoverableDeletionRow]
    public var unchangedKeys: Set<RecoverableDeletionRowKey>
    public var conflictingKeys: Set<RecoverableDeletionRowKey>
    public var blockedBySourceDurableDeletionKeys: Set<RecoverableDeletionRowKey>
    public var blockedByDestinationDurableDeletionKeys: Set<RecoverableDeletionRowKey>

    public var acceptedSourceRows: [RecoverableDeletionRow] {
        let acceptedKeys = Set(rowsToCreate.map(\.key)).union(unchangedKeys)
        return sourceRows.filter { acceptedKeys.contains($0.key) }
    }

    public var requiresAttention: Bool {
        !conflictingKeys.isEmpty ||
            !blockedBySourceDurableDeletionKeys.isEmpty ||
            !blockedByDestinationDurableDeletionKeys.isEmpty
    }
}

public struct RecoverableDeletionImportVerification: Codable, Equatable, Sendable {
    public var verifiedImportedOrUnchangedKeys: Set<RecoverableDeletionRowKey>
    public var missingOrChangedImportedKeys: Set<RecoverableDeletionRowKey>
    public var modifiedPreexistingKeys: Set<RecoverableDeletionRowKey>
    public var unexpectedlyCreatedKeys: Set<RecoverableDeletionRowKey>

    public init(
        verifiedImportedOrUnchangedKeys: Set<RecoverableDeletionRowKey> = [],
        missingOrChangedImportedKeys: Set<RecoverableDeletionRowKey> = [],
        modifiedPreexistingKeys: Set<RecoverableDeletionRowKey> = [],
        unexpectedlyCreatedKeys: Set<RecoverableDeletionRowKey> = []
    ) {
        self.verifiedImportedOrUnchangedKeys = verifiedImportedOrUnchangedKeys
        self.missingOrChangedImportedKeys = missingOrChangedImportedKeys
        self.modifiedPreexistingKeys = modifiedPreexistingKeys
        self.unexpectedlyCreatedKeys = unexpectedlyCreatedKeys
    }

    public var isVerified: Bool {
        missingOrChangedImportedKeys.isEmpty &&
            modifiedPreexistingKeys.isEmpty &&
            unexpectedlyCreatedKeys.isEmpty
    }
}

public enum RecoverableDeletionCheckpointError: LocalizedError, Equatable, Sendable {
    case unsavedChanges
    case suppliedDurableStateDoesNotMatchStore
    case sourceDurableTargetsNotAppliedToDestination(Set<DurableDeletionTarget>)
    case sourceDurableStateNotAppliedToDestination(Set<UUID>)
    case unsupportedSchemaVersion(Int)
    case duplicateSourceKey(RecoverableDeletionRowKey)
    case invalidRow(RecoverableDeletionRowKey)
    case unsupportedAttribute(entity: RecoverableDeletionEntity, name: String)
    case invalidPersistentRow(entity: RecoverableDeletionEntity)
    case destinationChangedAfterPreview
    case planDoesNotMatchSource
    case destinationContainsPlannedKey(RecoverableDeletionRowKey)
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .sourceDurableStateNotAppliedToDestination,
             .sourceDurableTargetsNotAppliedToDestination:
            String(localized: "One or more local records predate an iCloud whole-vault deletion and cannot be copied without resurrecting deleted data.")
        case .destinationChangedAfterPreview,
             .suppliedDurableStateDoesNotMatchStore,
             .destinationContainsPlannedKey:
            String(localized: "The iCloud destination changed while you were reviewing it. The copy plan was updated; please review it again.")
        case .unsavedChanges,
             .unsupportedSchemaVersion,
             .duplicateSourceKey,
             .invalidRow,
             .unsupportedAttribute,
             .invalidPersistentRow,
             .planDoesNotMatchSource,
             .verificationFailed:
            String(localized: "The protected local-to-iCloud checkpoint is unavailable.")
        }
    }
}

/// Captures and imports recoverable soft-deleted payloads without routing them
/// through normal upsert APIs. Normal upserts intentionally clear `deletedAt`
/// and stamp current wipe epochs, either of which would corrupt this migration.
@MainActor
public final class RecoverableDeletionCheckpointRepository {
    private struct DestinationInventory {
        var rows: [RecoverableDeletionRow]
        var durableState: DurableDeletionState
        var fingerprint: String
    }

    private let persistence: PersistenceController
    private var context: NSManagedObjectContext { persistence.container.viewContext }

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    /// Captures only rows that remain recoverable under the supplied, current
    /// source deletion state. Marker/control rows and stale pre-wipe rows are
    /// never copied into the protected payload.
    public func capture(
        sourceDurableState: DurableDeletionState
    ) throws -> RecoverableDeletionCheckpoint {
        try requireCleanContext()
        try SynchronizedDeletionMarkerRepository.validate(sourceDurableState)
        let actualState = try SynchronizedDeletionMarkerRepository(
            persistence: persistence
        ).durableState()
        guard actualState == sourceDurableState else {
            throw RecoverableDeletionCheckpointError.suppliedDurableStateDoesNotMatchStore
        }

        let candidates = try fetchRows(recoverableOnly: true)
        for row in candidates { try validate(row) }
        let rows = candidates.filter { row in
            !isDurablyDeleted(row, by: sourceDurableState)
        }
        try validateUnique(rows)
        return RecoverableDeletionCheckpoint(rows: sorted(rows))
    }

    /// Plans against the exact current destination. Source deletion controls
    /// must already have been applied marker-first, otherwise importing rows
    /// would temporarily create objects outside their causal wipe generation.
    public func planImport(
        _ checkpoint: RecoverableDeletionCheckpoint,
        sourceDurableState: DurableDeletionState,
        destinationDurableState: DurableDeletionState
    ) throws -> RecoverableDeletionImportPlan {
        let sourceRows = try validatedRows(in: checkpoint)
        try SynchronizedDeletionMarkerRepository.validate(sourceDurableState)
        try SynchronizedDeletionMarkerRepository.validate(destinationDurableState)

        let unappliedTargets = sourceDurableState.targets
            .subtracting(destinationDurableState.targets)
        guard unappliedTargets.isEmpty else {
            throw RecoverableDeletionCheckpointError
                .sourceDurableTargetsNotAppliedToDestination(unappliedTargets)
        }
        let unappliedEpochs = sourceDurableState.wipeEpochIDs
            .subtracting(destinationDurableState.wipeEpochIDs)
        guard unappliedEpochs.isEmpty else {
            throw RecoverableDeletionCheckpointError
                .sourceDurableStateNotAppliedToDestination(unappliedEpochs)
        }

        let inventory = try destinationInventory(
            expectedDurableState: destinationDurableState
        )
        let classification = classify(
            sourceRows: sourceRows,
            destinationRows: inventory.rows,
            sourceDurableState: sourceDurableState,
            destinationDurableState: destinationDurableState
        )
        let destinationRowsByKey = Dictionary(grouping: inventory.rows, by: \.key)

        let protectedValues = destinationRowsByKey.map { key, rows in
            RecoverableDeletionProtectedDestinationValue(
                key: key,
                rowFingerprints: rows.map(Self.fingerprint(of:)).sorted()
            )
        }.sorted { Self.token(for: $0.key) < Self.token(for: $1.key) }

        return RecoverableDeletionImportPlan(
            sourceCheckpointFingerprint: Self.fingerprint(of: checkpoint),
            sourceDurableStateFingerprint: Self.fingerprint(of: sourceDurableState),
            destinationFingerprint: inventory.fingerprint,
            destinationDurableStateFingerprint: Self.fingerprint(of: destinationDurableState),
            sourceRows: sourceRows,
            rowsToCreate: sorted(classification.rowsToCreate),
            unchangedKeys: classification.unchangedKeys,
            conflictingKeys: classification.conflictingKeys,
            blockedBySourceDurableDeletionKeys: classification.blockedBySource,
            blockedByDestinationDurableDeletionKeys: classification.blockedByDestination,
            protectedDestinationValues: protectedValues,
            expectedAbsentKeys: classification.expectedAbsentKeys
        )
    }

    /// Reviews the post-deletion destination without writing it. The supplied
    /// state must include both imported controls and the target markers that
    /// enforcement will create for projected removals.
    public func preflightImport(
        _ checkpoint: RecoverableDeletionCheckpoint,
        sourceDurableState: DurableDeletionState,
        projectedDestinationDurableState: DurableDeletionState,
        removingDestinationTargets: Set<DurableDeletionTarget>
    ) throws -> RecoverableDeletionImportPreflight {
        let sourceRows = try validatedRows(in: checkpoint)
        try SynchronizedDeletionMarkerRepository.validate(sourceDurableState)
        try SynchronizedDeletionMarkerRepository.validate(
            projectedDestinationDurableState
        )
        let destinationRows = try fetchRows(recoverableOnly: false).filter {
            !removingDestinationTargets.contains($0.key.durableDeletionTarget)
        }
        let classification = classify(
            sourceRows: sourceRows,
            destinationRows: destinationRows,
            sourceDurableState: sourceDurableState,
            destinationDurableState: projectedDestinationDurableState
        )
        return RecoverableDeletionImportPreflight(
            sourceRows: sourceRows,
            rowsToCreate: sorted(classification.rowsToCreate),
            unchangedKeys: classification.unchangedKeys,
            conflictingKeys: classification.conflictingKeys,
            blockedBySourceDurableDeletionKeys: classification.blockedBySource,
            blockedByDestinationDurableDeletionKeys: classification.blockedByDestination
        )
    }

    /// Applies only absent physical rows. Source `vaultEpochsData` is written
    /// verbatim after the plan proves it contains every destination wipe epoch;
    /// no normal write helper may launder an older row into the current epoch.
    @discardableResult
    public func apply(
        _ plan: RecoverableDeletionImportPlan,
        sourceDurableState: DurableDeletionState,
        destinationDurableState: DurableDeletionState
    ) throws -> RecoverableDeletionImportVerification {
        try persistence.requireWritable()
        try requireCleanContext()
        let checkpoint = RecoverableDeletionCheckpoint(rows: plan.sourceRows)
        guard Self.fingerprint(of: checkpoint) == plan.sourceCheckpointFingerprint,
              Self.fingerprint(of: sourceDurableState) == plan.sourceDurableStateFingerprint,
              Self.fingerprint(of: destinationDurableState) ==
                plan.destinationDurableStateFingerprint else {
            throw RecoverableDeletionCheckpointError.planDoesNotMatchSource
        }
        _ = try validatedRows(in: checkpoint)

        let inventory = try destinationInventory(
            expectedDurableState: destinationDurableState
        )
        guard inventory.fingerprint == plan.destinationFingerprint else {
            throw RecoverableDeletionCheckpointError.destinationChangedAfterPreview
        }
        let recomputedPlan = try planImport(
            checkpoint,
            sourceDurableState: sourceDurableState,
            destinationDurableState: destinationDurableState
        )
        guard recomputedPlan == plan else {
            throw RecoverableDeletionCheckpointError.planDoesNotMatchSource
        }
        let existingKeys = Set(inventory.rows.map(\.key))
        for row in plan.rowsToCreate where existingKeys.contains(row.key) {
            throw RecoverableDeletionCheckpointError.destinationContainsPlannedKey(row.key)
        }

        do {
            var changedConfigurations = Set<String>()
            for row in plan.rowsToCreate {
                let target = row.key.durableDeletionTarget
                guard !destinationDurableState.targets.contains(target),
                      destinationDurableState.wipeEpochIDs.isSubset(of: epochIDs(in: row)) else {
                    throw RecoverableDeletionCheckpointError.destinationChangedAfterPreview
                }
                let object = NSEntityDescription.insertNewObject(
                    forEntityName: row.key.entity.entityName,
                    into: context
                )
                try apply(row, to: object)
                changedConfigurations.insert(row.key.entity.storeConfiguration)
            }
            if context.hasChanges {
                try context.save()
                postLocalMutationCommitted(
                    source: context,
                    storeConfigurations: changedConfigurations
                )
            }
        } catch {
            context.rollback()
            throw error
        }

        let verification = try verify(plan)
        guard verification.isVerified else {
            throw RecoverableDeletionCheckpointError.verificationFailed
        }
        return verification
    }

    /// Verifies both the imported rows and the stronger no-overwrite promise:
    /// every preexisting row remains byte-for-byte identical and every blocked
    /// or group-conflicting absent key remains absent.
    public func verify(
        _ plan: RecoverableDeletionImportPlan
    ) throws -> RecoverableDeletionImportVerification {
        try requireCleanContext()
        let rows = try fetchRows(recoverableOnly: false)
        let byKey = Dictionary(grouping: rows, by: \.key)
        let sourceByKey = Dictionary(uniqueKeysWithValues: plan.sourceRows.map { ($0.key, $0) })
        let expectedExactKeys = Set(plan.rowsToCreate.map(\.key)).union(plan.unchangedKeys)

        var verified = Set<RecoverableDeletionRowKey>()
        var missingOrChanged = Set<RecoverableDeletionRowKey>()
        for key in expectedExactKeys {
            guard let expected = sourceByKey[key],
                  let actual = byKey[key],
                  actual.count == 1,
                  actual[0] == expected else {
                missingOrChanged.insert(key)
                continue
            }
            verified.insert(key)
        }

        var modifiedPreexisting = Set<RecoverableDeletionRowKey>()
        for protected in plan.protectedDestinationValues {
            let current = (byKey[protected.key] ?? [])
                .map(Self.fingerprint(of:))
                .sorted()
            if current != protected.rowFingerprints {
                modifiedPreexisting.insert(protected.key)
            }
        }

        let unexpectedlyCreated = Set(plan.expectedAbsentKeys.filter {
            byKey[$0] != nil
        })
        return RecoverableDeletionImportVerification(
            verifiedImportedOrUnchangedKeys: verified,
            missingOrChangedImportedKeys: missingOrChanged,
            modifiedPreexistingKeys: modifiedPreexisting,
            unexpectedlyCreatedKeys: unexpectedlyCreated
        )
    }

    private struct RowClassification {
        var rowsToCreate: [RecoverableDeletionRow]
        var unchangedKeys: Set<RecoverableDeletionRowKey>
        var conflictingKeys: Set<RecoverableDeletionRowKey>
        var blockedBySource: Set<RecoverableDeletionRowKey>
        var blockedByDestination: Set<RecoverableDeletionRowKey>
        var expectedAbsentKeys: Set<RecoverableDeletionRowKey>
    }

    private func classify(
        sourceRows: [RecoverableDeletionRow],
        destinationRows: [RecoverableDeletionRow],
        sourceDurableState: DurableDeletionState,
        destinationDurableState: DurableDeletionState
    ) -> RowClassification {
        let destinationRowsByKey = Dictionary(grouping: destinationRows, by: \.key)
        let destinationRowsByTarget = Dictionary(
            grouping: destinationRows,
            by: { $0.key.durableDeletionTarget }
        )
        let sourceRowsByTarget = Dictionary(
            grouping: sourceRows,
            by: { $0.key.durableDeletionTarget }
        )

        var result = RowClassification(
            rowsToCreate: [],
            unchangedKeys: [],
            conflictingKeys: [],
            blockedBySource: [],
            blockedByDestination: [],
            expectedAbsentKeys: []
        )

        for (target, group) in sourceRowsByTarget {
            let groupKeys = Set(group.map(\.key))
            if group.contains(where: { isDurablyDeleted($0, by: sourceDurableState) }) {
                result.blockedBySource.formUnion(groupKeys)
                result.expectedAbsentKeys.formUnion(groupKeys.filter {
                    destinationRowsByKey[$0] == nil
                })
                continue
            }
            if destinationDurableState.targets.contains(target) ||
                group.contains(where: {
                    !destinationDurableState.wipeEpochIDs.isSubset(of: epochIDs(in: $0))
                }) {
                result.blockedByDestination.formUnion(groupKeys)
                result.expectedAbsentKeys.formUnion(groupKeys.filter {
                    destinationRowsByKey[$0] == nil
                })
                continue
            }

            let sourceByKey = Dictionary(uniqueKeysWithValues: group.map { ($0.key, $0) })
            let destinationGroup = destinationRowsByTarget[target] ?? []
            let groupConflicts = destinationGroup.contains { destinationRow in
                guard let sourceRow = sourceByKey[destinationRow.key] else {
                    // Portrait metadata and synchronized bytes are one logical
                    // deletion target and must remain a complete pair.
                    return true
                }
                let matches = destinationRowsByKey[destinationRow.key] ?? []
                return matches.count != 1 || matches[0] != sourceRow
            }

            if groupConflicts {
                result.conflictingKeys.formUnion(groupKeys)
                result.expectedAbsentKeys.formUnion(groupKeys.filter {
                    destinationRowsByKey[$0] == nil
                })
                continue
            }

            for row in group {
                if let existing = destinationRowsByKey[row.key] {
                    if existing.count == 1, existing[0] == row {
                        result.unchangedKeys.insert(row.key)
                    } else {
                        result.conflictingKeys.formUnion(groupKeys)
                    }
                } else {
                    result.rowsToCreate.append(row)
                }
            }
        }
        return result
    }

    private func destinationInventory(
        expectedDurableState: DurableDeletionState
    ) throws -> DestinationInventory {
        try requireCleanContext()
        let repository = SynchronizedDeletionMarkerRepository(persistence: persistence)
        let actualState = try repository.durableState()
        guard actualState == expectedDurableState else {
            throw RecoverableDeletionCheckpointError.suppliedDurableStateDoesNotMatchStore
        }
        let rows = try fetchRows(recoverableOnly: false)
        let fingerprint = Self.fingerprint(
            rows: rows,
            durableState: actualState
        )
        return DestinationInventory(
            rows: rows,
            durableState: actualState,
            fingerprint: fingerprint
        )
    }

    private func fetchRows(recoverableOnly: Bool) throws -> [RecoverableDeletionRow] {
        var rows: [RecoverableDeletionRow] = []
        for entity in RecoverableDeletionEntity.allCases {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity.entityName)
            for object in try context.fetch(request) {
                if entity == .canonicalRecord,
                   SynchronizedDeletionMarkerRepository.isMarker(object) {
                    continue
                }
                let row = try Self.makeRow(from: object, entity: entity)
                let shouldInclude = recoverableOnly
                    ? try isRecoverableSoftDeletion(row)
                    : true
                if shouldInclude {
                    rows.append(row)
                }
            }
        }
        return sorted(rows)
    }

    static func makeRow(
        from object: NSManagedObject,
        entity: RecoverableDeletionEntity
    ) throws -> RecoverableDeletionRow {
        guard let id = object.value(forKey: "id") as? UUID else {
            throw RecoverableDeletionCheckpointError.invalidPersistentRow(entity: entity)
        }
        let kind: String?
        switch entity {
        case .canonicalRecord, .ownedProfileRecord:
            guard let storedKind = object.value(forKey: "kind") as? String,
                  !storedKind.isEmpty else {
                throw RecoverableDeletionCheckpointError.invalidPersistentRow(entity: entity)
            }
            kind = storedKind
        case .person, .interaction, .mediaPayload:
            kind = nil
        }
        let key = RecoverableDeletionRowKey(entity: entity, id: id, kind: kind)
        var attributes: [String: RecoverableDeletionAttributeValue] = [:]
        for (name, description) in object.entity.attributesByName {
            guard let value = object.value(forKey: name) else { continue }
            attributes[name] = try Self.portableValue(
                value,
                description: description,
                entity: entity
            )
        }
        return RecoverableDeletionRow(key: key, attributes: attributes)
    }

    private func validatedRows(
        in checkpoint: RecoverableDeletionCheckpoint
    ) throws -> [RecoverableDeletionRow] {
        guard checkpoint.schemaVersion == RecoverableDeletionCheckpoint.currentSchemaVersion else {
            throw RecoverableDeletionCheckpointError
                .unsupportedSchemaVersion(checkpoint.schemaVersion)
        }
        for row in checkpoint.rows {
            try validate(row)
            guard try isRecoverableSoftDeletion(row) else {
                throw RecoverableDeletionCheckpointError.invalidRow(row.key)
            }
        }
        try validateUnique(checkpoint.rows)
        return sorted(checkpoint.rows)
    }

    private func validate(_ row: RecoverableDeletionRow) throws {
        guard case .uuid(row.key.id) = row.attributes["id"] else {
            throw RecoverableDeletionCheckpointError.invalidRow(row.key)
        }
        switch row.key.entity {
        case .canonicalRecord, .ownedProfileRecord:
            guard let kind = row.key.kind,
                  !kind.isEmpty,
                  case .string(kind) = row.attributes["kind"],
                  case .data = row.attributes["payload"],
                  !SynchronizedDeletionMarkerRepository.isReservedKind(kind) else {
                throw RecoverableDeletionCheckpointError.invalidRow(row.key)
            }
        case .person:
            guard row.key.kind == nil,
                  case .string = row.attributes["displayName"] else {
                throw RecoverableDeletionCheckpointError.invalidRow(row.key)
            }
        case .mediaPayload:
            guard row.key.kind == nil,
                  case .data = row.attributes["payload"],
                  case .string = row.attributes["contentHash"] else {
                throw RecoverableDeletionCheckpointError.invalidRow(row.key)
            }
        case .interaction:
            guard row.key.kind == nil else {
                throw RecoverableDeletionCheckpointError.invalidRow(row.key)
            }
        }

        guard let entity = persistence.container.managedObjectModel.entitiesByName[
            row.key.entity.entityName
        ] else {
            throw RecoverableDeletionCheckpointError.invalidRow(row.key)
        }
        for (name, value) in row.attributes {
            guard let attribute = entity.attributesByName[name] else {
                throw RecoverableDeletionCheckpointError.unsupportedAttribute(
                    entity: row.key.entity,
                    name: name
                )
            }
            guard Self.matches(value, attributeType: attribute.attributeType) else {
                throw RecoverableDeletionCheckpointError.invalidRow(row.key)
            }
        }
        _ = try decodedEpochIDs(in: row)
    }

    private func validateUnique(_ rows: [RecoverableDeletionRow]) throws {
        var keys = Set<RecoverableDeletionRowKey>()
        for row in rows where !keys.insert(row.key).inserted {
            throw RecoverableDeletionCheckpointError.duplicateSourceKey(row.key)
        }
    }

    private func isRecoverableSoftDeletion(_ row: RecoverableDeletionRow) throws -> Bool {
        switch row.key.entity {
        case .person, .canonicalRecord, .ownedProfileRecord, .mediaPayload:
            if case .date = row.attributes["deletedAt"] { return true }
            return false
        case .interaction:
            guard case .data(let details) = row.attributes["detailsData"],
                  let interaction = try? JSONDecoder().decode(Interaction.self, from: details),
                  interaction.id == row.key.id else {
                throw RecoverableDeletionCheckpointError.invalidRow(row.key)
            }
            return interaction.deletedAt != nil
        }
    }

    private func isDurablyDeleted(
        _ row: RecoverableDeletionRow,
        by state: DurableDeletionState
    ) -> Bool {
        let target = row.key.durableDeletionTarget
        if state.targets.contains(target) { return true }
        let epochs = epochIDs(in: row)
        if !state.wipeEpochIDs.isSubset(of: epochs) { return true }
        let memberships = Set(state.generationMemberships.lazy
            .filter { $0.target == target }
            .map(\.wipeEpochID))
        return !state.wipeEpochIDs.isSubset(of: memberships)
    }

    private func decodedEpochIDs(in row: RecoverableDeletionRow) throws -> Set<UUID> {
        guard let value = row.attributes["vaultEpochsData"] else { return [] }
        guard case .data(let data) = value,
              let strings = try? JSONDecoder().decode([String].self, from: data),
              strings.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw RecoverableDeletionCheckpointError.invalidRow(row.key)
        }
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    private func epochIDs(in row: RecoverableDeletionRow) -> Set<UUID> {
        (try? decodedEpochIDs(in: row)) ?? []
    }

    private func apply(_ row: RecoverableDeletionRow, to object: NSManagedObject) throws {
        try validate(row)
        for (name, value) in row.attributes {
            object.setValue(Self.managedValue(value), forKey: name)
        }
    }

    private func requireCleanContext() throws {
        context.processPendingChanges()
        guard !context.hasChanges else {
            throw RecoverableDeletionCheckpointError.unsavedChanges
        }
    }

    private static func portableValue(
        _ value: Any,
        description: NSAttributeDescription,
        entity: RecoverableDeletionEntity
    ) throws -> RecoverableDeletionAttributeValue {
        switch description.attributeType {
        case .stringAttributeType:
            guard let value = value as? String else { break }
            return .string(value)
        case .binaryDataAttributeType:
            guard let value = value as? Data else { break }
            return .data(value)
        case .dateAttributeType:
            guard let value = value as? Date else { break }
            return .date(value)
        case .UUIDAttributeType:
            guard let value = value as? UUID else { break }
            return .uuid(value)
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType:
            guard let value = value as? NSNumber else { break }
            return .integer(value.int64Value)
        case .booleanAttributeType:
            guard let value = value as? NSNumber else { break }
            return .boolean(value.boolValue)
        case .doubleAttributeType, .floatAttributeType, .decimalAttributeType:
            guard let value = value as? NSNumber else { break }
            return .double(value.doubleValue)
        default:
            break
        }
        throw RecoverableDeletionCheckpointError.unsupportedAttribute(
            entity: entity,
            name: description.name
        )
    }

    private static func matches(
        _ value: RecoverableDeletionAttributeValue,
        attributeType: NSAttributeType
    ) -> Bool {
        switch (value, attributeType) {
        case (.string, .stringAttributeType),
             (.data, .binaryDataAttributeType),
             (.date, .dateAttributeType),
             (.uuid, .UUIDAttributeType),
             (.integer, .integer16AttributeType),
             (.integer, .integer32AttributeType),
             (.integer, .integer64AttributeType),
             (.boolean, .booleanAttributeType),
             (.double, .doubleAttributeType),
             (.double, .floatAttributeType),
             (.double, .decimalAttributeType):
            true
        default:
            false
        }
    }

    private static func managedValue(_ value: RecoverableDeletionAttributeValue) -> Any {
        switch value {
        case .string(let value): value
        case .data(let value): value
        case .date(let value): value
        case .uuid(let value): value
        case .integer(let value): NSNumber(value: value)
        case .boolean(let value): NSNumber(value: value)
        case .double(let value): NSNumber(value: value)
        }
    }

    private func sorted(_ rows: [RecoverableDeletionRow]) -> [RecoverableDeletionRow] {
        rows.sorted { Self.token(for: $0.key) < Self.token(for: $1.key) }
    }

    private static func token(for key: RecoverableDeletionRowKey) -> String {
        "\(key.entity.rawValue)|\(key.id.uuidString)|\(key.kind ?? "")"
    }

    private static func targetToken(for target: DurableDeletionTarget) -> String {
        let family: String
        switch target.family {
        case .person:
            family = "person"
        case .interaction:
            family = "interaction"
        case .vaultRecord(let kind):
            family = "vault|\(kind)"
        case .ownedProfileRecord(let kind):
            family = "profile|\(kind)"
        }
        return "\(family)|\(target.id.uuidString)"
    }

    static func fingerprint(of row: RecoverableDeletionRow) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(row)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(of checkpoint: RecoverableDeletionCheckpoint) -> String {
        var normalized = checkpoint
        normalized.rows.sort { token(for: $0.key) < token(for: $1.key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return hash((try? encoder.encode(normalized)) ?? Data())
    }

    private static func fingerprint(of state: DurableDeletionState) -> String {
        var lines = state.targets.map { "delete|\(targetToken(for: $0))" }
        lines.append(contentsOf: state.wipeEpochIDs.map { "epoch|\($0.uuidString)" })
        lines.append(contentsOf: state.generationMemberships.map {
            "member|\(targetToken(for: $0.target))|\($0.wipeEpochID.uuidString)"
        })
        return hash(Data(lines.sorted().joined(separator: "\n").utf8))
    }

    private static func fingerprint(
        rows: [RecoverableDeletionRow],
        durableState: DurableDeletionState
    ) -> String {
        var lines = rows.map {
            "row|\(token(for: $0.key))|\(fingerprint(of: $0))"
        }
        lines.append("state|\(fingerprint(of: durableState))")
        return hash(Data(lines.sorted().joined(separator: "\n").utf8))
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A protected, device-local copy of one physical row that lost an
/// edit-versus-delete race. The row contains only modeled vault attributes;
/// Core Data object identifiers, CloudKit record identifiers, container
/// identifiers, and Apple Account bindings are never part of this envelope.
public struct DeletionConflictDraft: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var capturedAt: Date
    public var contentSHA256: String
    public var row: RecoverableDeletionRow

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        capturedAt: Date,
        contentSHA256: String,
        row: RecoverableDeletionRow
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.capturedAt = capturedAt
        self.contentSHA256 = contentSHA256
        self.row = row
    }

    public var target: DurableDeletionTarget { row.key.durableDeletionTarget }
}

/// Portable export for user-controlled recovery workflows. It deliberately
/// has no account or CloudKit provenance, so moving the file cannot associate
/// a private payload with an Apple Account identifier.
public struct DeletionConflictDraftExport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var drafts: [DeletionConflictDraft]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        drafts: [DeletionConflictDraft]
    ) {
        self.schemaVersion = schemaVersion
        self.drafts = drafts
    }
}

public enum DeletionConflictDraftError: LocalizedError, Equatable, Sendable {
    case unsavedChanges
    case unsupportedSourceEntity(String)
    case forbiddenSynchronizationMetadata(entity: RecoverableDeletionEntity, name: String)
    case unreadableStoredDraft
    case invalidDraft(UUID)
    case unsupportedExportSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .unsavedChanges:
            String(localized: "This change could not be saved locally. Please try again.")
        case .unsupportedSourceEntity,
             .forbiddenSynchronizationMetadata,
             .unreadableStoredDraft,
             .invalidDraft,
             .unsupportedExportSchema:
            String(localized: "Your notebook could not be read. The original data has been left untouched.")
        }
    }
}

/// Stores edit-versus-delete recovery drafts only in `DerivedRecordEntity`,
/// which belongs to the non-mirrored `LocalDerived` configuration.
@MainActor
public final class DeletionConflictDraftRepository {
    static let storageKind = "__relationshipNotebookDeletionConflictDraft.v1"

    private let persistence: PersistenceController
    private var context: NSManagedObjectContext { persistence.container.viewContext }
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    public func list() throws -> [DeletionConflictDraft] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "DerivedRecordEntity")
        request.predicate = NSPredicate(
            format: "kind == %@ AND deletedAt == nil",
            Self.storageKind
        )
        let drafts = try context.fetch(request).map { object -> DeletionConflictDraft in
            guard let storedID = object.value(forKey: "id") as? UUID,
                  let data = object.value(forKey: "payload") as? Data,
                  let draft = try? decoder.decode(DeletionConflictDraft.self, from: data),
                  draft.id == storedID else {
                throw DeletionConflictDraftError.unreadableStoredDraft
            }
            try Self.validate(draft)
            return draft
        }
        return Self.sorted(drafts)
    }

    public func count() throws -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "DerivedRecordEntity")
        request.predicate = NSPredicate(
            format: "kind == %@ AND deletedAt == nil",
            Self.storageKind
        )
        return try context.count(for: request)
    }

    public func export() throws -> Data {
        try encoder.encode(DeletionConflictDraftExport(drafts: list()))
    }

    @discardableResult
    public func remove(id: UUID) throws -> Bool {
        try persistence.requireWritable()
        try requireCleanContext()
        let request = NSFetchRequest<NSManagedObject>(entityName: "DerivedRecordEntity")
        request.predicate = NSPredicate(
            format: "id == %@ AND kind == %@",
            id as CVarArg,
            Self.storageKind
        )
        let objects = try context.fetch(request)
        guard !objects.isEmpty else { return false }
        objects.forEach(context.delete)
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Stages at most one draft for each distinct physical-row payload. The
    /// caller commits this Derived-only phase before deleting synchronized
    /// rows, so a failed local recovery write always prevents data loss.
    @discardableResult
    func stageCapture(
        objects: some Sequence<NSManagedObject>,
        at capturedAt: Date = .now
    ) throws -> Int {
        try persistence.requireWritable()
        try requireCleanContext()

        var rows: [RecoverableDeletionRow] = []
        for object in objects {
            guard let entityName = object.entity.name,
                  let entity = RecoverableDeletionEntity.allCases.first(where: {
                      $0.entityName == entityName
                  }) else {
                throw DeletionConflictDraftError.unsupportedSourceEntity(
                    object.entity.name ?? "unknown"
                )
            }
            if entity == .canonicalRecord,
               SynchronizedDeletionMarkerRepository.isMarker(object) {
                continue
            }
            let row = try RecoverableDeletionCheckpointRepository.makeRow(
                from: object,
                entity: entity
            )
            rows.append(row)
        }
        return try stageCapturePreparedRows(rows, at: capturedAt)
    }

    /// Variant used when a value editor is rejected before Core Data can stage
    /// its attempted Person or Interaction update.
    @discardableResult
    func stageCapture(
        rows: some Sequence<RecoverableDeletionRow>,
        at capturedAt: Date = .now
    ) throws -> Int {
        try persistence.requireWritable()
        try requireCleanContext()
        return try stageCapturePreparedRows(rows, at: capturedAt)
    }

    private func stageCapturePreparedRows(
        _ rows: some Sequence<RecoverableDeletionRow>,
        at capturedAt: Date
    ) throws -> Int {
        let incoming = try rows.map { row -> (RecoverableDeletionRow, String) in
            try Self.validateAttributeNames(in: row)
            return (
                row,
                RecoverableDeletionCheckpointRepository.fingerprint(of: row)
            )
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "DerivedRecordEntity")
        request.predicate = NSPredicate(format: "kind == %@", Self.storageKind)
        let existingDigests = Set(try context.fetch(request).compactMap { object -> String? in
            guard let data = object.value(forKey: "payload") as? Data,
                  let draft = try? decoder.decode(DeletionConflictDraft.self, from: data),
                  (try? Self.validate(draft)) != nil else { return nil }
            return draft.contentSHA256
        })

        var seenDigests = existingDigests
        var insertedCount = 0
        for (row, digest) in incoming where seenDigests.insert(digest).inserted {
            let draft = DeletionConflictDraft(
                capturedAt: capturedAt,
                contentSHA256: digest,
                row: row
            )
            let object = NSEntityDescription.insertNewObject(
                forEntityName: "DerivedRecordEntity",
                into: context
            )
            object.setValue(draft.id, forKey: "id")
            object.setValue(Self.storageKind, forKey: "kind")
            object.setValue(try encoder.encode(draft), forKey: "payload")
            object.setValue(capturedAt, forKey: "createdAt")
            object.setValue(capturedAt, forKey: "modifiedAt")
            object.setValue(nil, forKey: "deletedAt")
            insertedCount += 1
        }
        return insertedCount
    }

    static func isReservedKind(_ kind: String) -> Bool {
        kind == storageKind
    }

    private func requireCleanContext() throws {
        context.processPendingChanges()
        guard !context.hasChanges else {
            throw DeletionConflictDraftError.unsavedChanges
        }
    }

    private static func validate(_ draft: DeletionConflictDraft) throws {
        guard draft.schemaVersion == DeletionConflictDraft.currentSchemaVersion,
              RecoverableDeletionCheckpointRepository.fingerprint(of: draft.row) ==
                draft.contentSHA256,
              case .uuid(draft.row.key.id) = draft.row.attributes["id"] else {
            throw DeletionConflictDraftError.invalidDraft(draft.id)
        }
        switch draft.row.key.entity {
        case .canonicalRecord, .ownedProfileRecord:
            guard let kind = draft.row.key.kind,
                  !SynchronizedDeletionMarkerRepository.isReservedKind(kind),
                  case .string(kind) = draft.row.attributes["kind"] else {
                throw DeletionConflictDraftError.invalidDraft(draft.id)
            }
        case .person, .interaction, .mediaPayload:
            guard draft.row.key.kind == nil else {
                throw DeletionConflictDraftError.invalidDraft(draft.id)
            }
        }
        try validateAttributeNames(in: draft.row)
    }

    private static func validateAttributeNames(in row: RecoverableDeletionRow) throws {
        for name in row.attributes.keys {
            let normalized = name
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            if normalized == "accountbinding" ||
                normalized.hasPrefix("cloudkit") ||
                normalized.hasPrefix("ckrecord") {
                throw DeletionConflictDraftError.forbiddenSynchronizationMetadata(
                    entity: row.key.entity,
                    name: name
                )
            }
        }
    }

    private static func sorted(
        _ drafts: [DeletionConflictDraft]
    ) -> [DeletionConflictDraft] {
        drafts.sorted {
            if $0.capturedAt != $1.capturedAt {
                return $0.capturedAt > $1.capturedAt
            }
            if $0.contentSHA256 != $1.contentSHA256 {
                return $0.contentSHA256 < $1.contentSHA256
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
