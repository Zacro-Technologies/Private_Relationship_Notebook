import CoreData
import CryptoKit
import Foundation

public struct DurableDeletionTarget: Codable, Hashable, Sendable {
    public enum Family: Codable, Hashable, Sendable {
        case person
        case interaction
        case vaultRecord(kind: String)
        case ownedProfileRecord(kind: String)
    }

    public var family: Family
    public var id: UUID

    public init(family: Family, id: UUID) {
        self.family = family
        self.id = id
    }

    public static func person(_ id: UUID) -> Self {
        Self(family: .person, id: id)
    }

    public static func interaction(_ id: UUID) -> Self {
        Self(family: .interaction, id: id)
    }

    public static func vaultRecord(id: UUID, kind: String) -> Self {
        Self(family: .vaultRecord(kind: kind), id: id)
    }

    public static func ownedProfileRecord(id: UUID, kind: String) -> Self {
        Self(family: .ownedProfileRecord(kind: kind), id: id)
    }
}

typealias SynchronizedDeletionTarget = DurableDeletionTarget

public struct DurableVaultGenerationMembership: Codable, Hashable, Sendable {
    public var target: DurableDeletionTarget
    public var wipeEpochID: UUID

    public init(target: DurableDeletionTarget, wipeEpochID: UUID) {
        self.target = target
        self.wipeEpochID = wipeEpochID
    }
}

/// Payload-free synchronized deletion state suitable for a protected local-to-
/// cloud checkpoint. Applying it never restores record payloads; it persists
/// control markers first and then idempotently enforces deletion.
public struct DurableDeletionState: Codable, Equatable, Sendable {
    public var targets: Set<DurableDeletionTarget>
    public var wipeEpochIDs: Set<UUID>
    public var generationMemberships: Set<DurableVaultGenerationMembership>

    public init(
        targets: Set<DurableDeletionTarget> = [],
        wipeEpochIDs: Set<UUID> = [],
        generationMemberships: Set<DurableVaultGenerationMembership> = []
    ) {
        self.targets = targets
        self.wipeEpochIDs = wipeEpochIDs
        self.generationMemberships = generationMemberships
    }
}

/// Stable identity for one physical Core Data row affected by a reviewed
/// deletion application. `ordinal` disambiguates duplicate rows without
/// exposing an implementation-specific object URI.
public struct DurableDeletionPhysicalRow: Codable, Hashable, Sendable {
    public var entityName: String
    public var id: UUID
    public var kind: String?
    public var ordinal: Int

    public init(entityName: String, id: UUID, kind: String? = nil, ordinal: Int = 0) {
        self.entityName = entityName
        self.id = id
        self.kind = kind
        self.ordinal = ordinal
    }
}

/// A payload-free compare-and-swap receipt for one physical mutation. The
/// fingerprints cover every persisted attribute, including externally stored
/// portrait bytes, while keeping those private values out of the review model.
public struct DurableDeletionPhysicalMutation: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Hashable, Sendable {
        case delete
        case redact
    }

    public var row: DurableDeletionPhysicalRow
    public var action: Action
    public var beforeFingerprint: String
    public var afterFingerprint: String?

    public init(
        row: DurableDeletionPhysicalRow,
        action: Action,
        beforeFingerprint: String,
        afterFingerprint: String? = nil
    ) {
        self.row = row
        self.action = action
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
    }
}

public struct DurableDeletionApplicationPreview: Codable, Equatable, Sendable {
    public var stateFingerprint: String
    public var destinationFingerprint: String
    public var targetsToDelete: Set<DurableDeletionTarget>
    /// Fixed timestamp used by deterministic redactions in this plan.
    public var plannedAt: Date
    /// Exact delete/redaction receipt for every physical destination row.
    public var physicalMutations: [DurableDeletionPhysicalMutation]
    /// Fingerprint of all non-control synchronized rows after the plan.
    public var postApplicationFingerprint: String
    /// Canonical archive projection after every cascade and redaction. This is
    /// intentionally archive-formatted so migration review does not need to
    /// approximate the closure from logical target IDs.
    public var projectedArchiveData: Data

    public init(
        stateFingerprint: String,
        destinationFingerprint: String,
        targetsToDelete: Set<DurableDeletionTarget>,
        plannedAt: Date = .distantPast,
        physicalMutations: [DurableDeletionPhysicalMutation] = [],
        postApplicationFingerprint: String = "",
        projectedArchiveData: Data = Data()
    ) {
        self.stateFingerprint = stateFingerprint
        self.destinationFingerprint = destinationFingerprint
        self.targetsToDelete = targetsToDelete
        self.plannedAt = plannedAt
        self.physicalMutations = physicalMutations
        self.postApplicationFingerprint = postApplicationFingerprint
        self.projectedArchiveData = projectedArchiveData
    }

    public var physicalDeleteCount: Int {
        physicalMutations.lazy.filter { $0.action == .delete }.count
    }

    public var physicalRedactionCount: Int {
        physicalMutations.lazy.filter { $0.action == .redact }.count
    }

    public func projectedArchive() throws -> NotebookArchive {
        try ArchiveCodec.decode(projectedArchiveData)
    }

    public static func == (
        lhs: DurableDeletionApplicationPreview,
        rhs: DurableDeletionApplicationPreview
    ) -> Bool {
        // The physical post-state fingerprint commits to every projected
        // payload. Archive array order is presentation-only and may differ for
        // equal Core Data sort keys, so raw export byte order is not part of
        // the compare-and-swap identity.
        lhs.stateFingerprint == rhs.stateFingerprint &&
            lhs.destinationFingerprint == rhs.destinationFingerprint &&
            lhs.targetsToDelete == rhs.targetsToDelete &&
            lhs.plannedAt == rhs.plannedAt &&
            lhs.physicalMutations == rhs.physicalMutations &&
            lhs.postApplicationFingerprint == rhs.postApplicationFingerprint
    }
}

public enum DurableDeletionStateError: Error, Equatable, Sendable {
    case invalidState
    case activeArchiveConflictsWithDeletion(Set<DurableDeletionTarget>)
    case activeArchiveMissingGenerationMembership(Set<DurableDeletionTarget>)
    case destinationChangedAfterPreview
    case mutationPlanMismatch
    case applicationVerificationFailed
}

enum SynchronizedDeletionMarkerError: Error, Equatable, Sendable {
    case targetWasPermanentlyDeleted(SynchronizedDeletionTarget)
    case targetPredatesCurrentVaultGeneration(SynchronizedDeletionTarget)
    case reservedSynchronizationKind(String)
    case invalidDurableDeletionState
    case unsavedChangesPreventReconciliation
}

/// Stores deletion intent independently from Core Data's short-lived object
/// tombstones. The marker is itself a CloudKit-mirrored canonical record, but
/// contains no deleted record payload: its reserved kind encodes only the
/// target family and its UUID is the target's stable identifier.
@MainActor
final class SynchronizedDeletionMarkerRepository {
    static let markerKindPrefix = "__relationshipNotebookDeletionMarker.v1."
    static let wipeEpochKind = "__relationshipNotebookVaultWipeEpoch.v1"

    private let persistence: PersistenceController
    private let context: NSManagedObjectContext

    init(persistence: PersistenceController) {
        self.persistence = persistence
        context = persistence.container.viewContext
    }

    func requireUnmarked(_ target: SynchronizedDeletionTarget) throws {
        guard try !contains(target) else {
            throw SynchronizedDeletionMarkerError.targetWasPermanentlyDeleted(target)
        }
    }

    func contains(_ target: SynchronizedDeletionTarget) throws -> Bool {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
        request.fetchLimit = 1
        request.predicate = NSPredicate(
            format: "id == %@ AND kind == %@ AND deletedAt == nil",
            target.id as CVarArg,
            Self.markerKind(for: target)
        )
        return try context.fetch(request).first != nil
    }

    @discardableResult
    func mark(
        _ targets: Set<SynchronizedDeletionTarget>,
        at date: Date = .now
    ) throws -> Bool {
        var changed = false
        for target in targets {
            changed = try stageControlRecord(
                id: target.id,
                kind: Self.markerKind(for: target),
                at: date
            ) || changed
        }
        return changed
    }

    @discardableResult
    func markPermanentlyDeleted(
        objects: some Sequence<NSManagedObject>,
        at date: Date = .now
    ) throws -> Bool {
        try mark(Self.targets(forDeletedObjects: objects), at: date)
    }

    static func targets(
        forDeletedObjects objects: some Sequence<NSManagedObject>
    ) -> Set<SynchronizedDeletionTarget> {
        Set(objects.compactMap(Self.target(forDeletedObject:)))
    }

    func targets() throws -> Set<SynchronizedDeletionTarget> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
        request.predicate = NSPredicate(
            format: "kind BEGINSWITH %@ AND deletedAt == nil",
            Self.markerKindPrefix
        )
        return Set(try context.fetch(request).compactMap { marker in
            guard let id = marker.value(forKey: "id") as? UUID,
                  let kind = marker.value(forKey: "kind") as? String else { return nil }
            return Self.target(forMarkerKind: kind, id: id)
        })
    }

    func wipeEpochIDs() throws -> Set<UUID> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
        request.predicate = NSPredicate(
            format: "kind == %@ AND deletedAt == nil",
            Self.wipeEpochKind
        )
        return Set(try context.fetch(request).compactMap {
            $0.value(forKey: "id") as? UUID
        })
    }

    func generationMemberships() throws -> Set<DurableVaultGenerationMembership> {
        var epochIntersectionByTarget: [SynchronizedDeletionTarget: Set<UUID>] = [:]
        for object in try synchronizedTargetObjects() {
            guard let target = Self.target(forDeletedObject: object) else { continue }
            let objectEpochs = Self.epochs(on: object)
            if let accumulated = epochIntersectionByTarget[target] {
                epochIntersectionByTarget[target] = accumulated.intersection(objectEpochs)
            } else {
                epochIntersectionByTarget[target] = objectEpochs
            }
        }
        return Set(epochIntersectionByTarget.flatMap { target, epochIDs in
            epochIDs.map {
                DurableVaultGenerationMembership(target: target, wipeEpochID: $0)
            }
        })
    }

    func durableState() throws -> DurableDeletionState {
        DurableDeletionState(
            targets: try targets(),
            wipeEpochIDs: try wipeEpochIDs(),
            generationMemberships: try generationMemberships()
        )
    }

    func preview(
        applying state: DurableDeletionState
    ) throws -> DurableDeletionApplicationPreview {
        try Self.validate(state)
        let combinedTargets = try targets().union(state.targets)
        let combinedEpochs = try wipeEpochIDs().union(state.wipeEpochIDs)
        let objects = try synchronizedTargetObjects()
        let targetsToDelete = Set(objects.compactMap { object -> SynchronizedDeletionTarget? in
            guard let target = Self.target(forDeletedObject: object) else { return nil }
            if combinedTargets.contains(target) { return target }
            guard !combinedEpochs.isEmpty,
                  !combinedEpochs.isSubset(of: Self.epochs(on: object)) else { return nil }
            return target
        })
        return DurableDeletionApplicationPreview(
            stateFingerprint: Self.fingerprint(of: state),
            destinationFingerprint: try destinationFingerprint(),
            targetsToDelete: targetsToDelete
        )
    }

    static func validate(_ state: DurableDeletionState) throws {
        guard state.generationMemberships.allSatisfy({ membership in
            state.wipeEpochIDs.contains(membership.wipeEpochID) &&
                !isReservedTarget(membership.target)
        }), state.targets.allSatisfy({ !isReservedTarget($0) }) else {
            throw DurableDeletionStateError.invalidState
        }
    }

    /// Stages payload-free control records only. Callers persist this Vault
    /// phase before changing a target in another persistent store.
    @discardableResult
    func stage(_ state: DurableDeletionState, at date: Date = .now) throws -> Bool {
        try Self.validate(state)
        var changed = try mark(state.targets, at: date)
        for epochID in state.wipeEpochIDs {
            changed = try stageControlRecord(
                id: epochID,
                kind: Self.wipeEpochKind,
                at: date
            ) || changed
        }
        return changed
    }

    /// Starts a new causal wipe generation. Every existing synchronized object
    /// receives an individual deletion marker in the same marker-only Vault
    /// commit; later arrivals without membership in this epoch are marked and
    /// removed by `enforce()`.
    @discardableResult
    func beginWholeVaultDeletion(at date: Date = .now) throws -> UUID {
        try persistence.requireWritable()
        guard !context.hasChanges else {
            throw SynchronizedDeletionMarkerError.unsavedChangesPreventReconciliation
        }
        let epochID = UUID()
        let objects = try synchronizedTargetObjects()
        _ = try markPermanentlyDeleted(objects: objects, at: date)
        _ = try stageControlRecord(id: epochID, kind: Self.wipeEpochKind, at: date)
        try context.save()
        postLocalMutationCommitted(
            source: context,
            at: date,
            storeConfigurations: [CloudSyncStoreConfiguration.vault]
        )
        return epochID
    }

    struct WritePreparation: Sendable {
        var target: SynchronizedDeletionTarget
        var requiredEpochIDs: Set<UUID>
    }

    /// A target already present without membership in every observed wipe
    /// epoch is stale and cannot be laundered into the current generation by a
    /// normal update. A genuinely new target receives empty membership control
    /// records for all currently observed epochs.
    func writePreparation(
        for target: SynchronizedDeletionTarget,
        existingObjects: [NSManagedObject]
    ) throws -> WritePreparation {
        try requireUnmarked(target)
        let epochs = try wipeEpochIDs()
        if existingObjects.contains(where: { !epochs.isSubset(of: Self.epochs(on: $0)) }) {
            throw SynchronizedDeletionMarkerError
                .targetPredatesCurrentVaultGeneration(target)
        }
        return WritePreparation(target: target, requiredEpochIDs: epochs)
    }

    @discardableResult
    func stamp(
        _ preparation: WritePreparation,
        on objects: some Sequence<NSManagedObject>
    ) throws -> Bool {
        var changed = false
        let data = try Self.encodeEpochs(preparation.requiredEpochIDs)
        for object in objects where object.value(forKey: "vaultEpochsData") as? Data != data {
            object.setValue(data, forKey: "vaultEpochsData")
            changed = true
        }
        return changed
    }

    /// Re-applies durable deletion intent after CloudKit imports. If another
    /// device uploaded a stale active value, this transaction deletes it again
    /// while retaining the marker, so edit-vs-delete converges to deletion.
    @discardableResult
    func enforce(captureConflicts: Bool = true) throws -> Set<String> {
        try persistence.requireWritable()
        guard !context.hasChanges else {
            throw SynchronizedDeletionMarkerError.unsavedChangesPreventReconciliation
        }

        let deletionTargets = try targets()
        let epochs = try wipeEpochIDs()
        let objects = try synchronizedTargetObjects()
        let staleTargets = Set(objects.compactMap { object -> SynchronizedDeletionTarget? in
            guard let target = Self.target(forDeletedObject: object) else { return nil }
            if deletionTargets.contains(target) { return target }
            guard !epochs.isEmpty,
                  !epochs.isSubset(of: Self.epochs(on: object)) else { return nil }
            return target
        })
        let staleObjects = objects.filter { object in
            guard let target = Self.target(forDeletedObject: object) else { return false }
            return staleTargets.contains(target)
        }
        guard !staleObjects.isEmpty else { return [] }

        // Phase 1: make deletion intent durable in the Vault store before any
        // target row is removed, including targets that live in OwnedProfiles.
        if try mark(staleTargets) {
            do {
                try context.save()
                postLocalMutationCommitted(
                    source: context,
                    storeConfigurations: [CloudSyncStoreConfiguration.vault]
                )
            } catch {
                context.rollback()
                throw error
            }
        }

        // Phase 2: preserve every distinct losing physical-row value in the
        // local-only Derived store. This commit must succeed before either
        // mirrored target store is changed. Intentional, reviewed destructive
        // workflows opt out explicitly via `captureConflicts: false`.
        if captureConflicts {
            let drafts = DeletionConflictDraftRepository(persistence: persistence)
            if try drafts.stageCapture(objects: staleObjects) > 0 {
                do {
                    try context.save()
                } catch {
                    context.rollback()
                    throw error
                }
            }
        }

        var changedConfigurations = Set<String>()
        let vaultObjects = staleObjects.filter {
            $0.entity.name != "ProfileRecordEntity"
        }
        if !vaultObjects.isEmpty {
            vaultObjects.forEach(context.delete)
            do {
                try context.save()
                changedConfigurations.insert(CloudSyncStoreConfiguration.vault)
                postLocalMutationCommitted(
                    source: context,
                    storeConfigurations: [CloudSyncStoreConfiguration.vault]
                )
            } catch {
                context.rollback()
                throw error
            }
        }

        let profileObjects = staleObjects.filter {
            $0.entity.name == "ProfileRecordEntity"
        }
        if !profileObjects.isEmpty {
            profileObjects.forEach(context.delete)
            do {
                try context.save()
                changedConfigurations.insert(CloudSyncStoreConfiguration.ownedProfiles)
                postLocalMutationCommitted(
                    source: context,
                    storeConfigurations: [CloudSyncStoreConfiguration.ownedProfiles]
                )
            } catch {
                context.rollback()
                throw error
            }
        }
        return changedConfigurations
    }

    static func isMarker(_ object: NSManagedObject) -> Bool {
        guard object.entity.name == "CanonicalRecordEntity",
              let kind = object.value(forKey: "kind") as? String else { return false }
        return isReservedKind(kind)
    }

    static func isReservedKind(_ kind: String) -> Bool {
        kind.hasPrefix(markerKindPrefix) ||
            kind == wipeEpochKind
    }

    private static func isReservedTarget(_ target: SynchronizedDeletionTarget) -> Bool {
        switch target.family {
        case .vaultRecord(let kind), .ownedProfileRecord(let kind):
            isReservedKind(kind)
        case .person, .interaction:
            false
        }
    }

    static func markerKind(for target: SynchronizedDeletionTarget) -> String {
        markerKindPrefix + familyToken(for: target)
    }

    private static func familyToken(for target: SynchronizedDeletionTarget) -> String {
        switch target.family {
        case .person:
            return "person"
        case .interaction:
            return "interaction"
        case .vaultRecord(let kind):
            return "vaultRecord." + encoded(kind)
        case .ownedProfileRecord(let kind):
            return "ownedProfileRecord." + encoded(kind)
        }
    }

    private static func target(
        forMarkerKind markerKind: String,
        id: UUID
    ) -> SynchronizedDeletionTarget? {
        guard markerKind.hasPrefix(markerKindPrefix) else { return nil }
        return target(forFamilyToken: String(markerKind.dropFirst(markerKindPrefix.count)), id: id)
    }

    private static func target(
        forFamilyToken family: String,
        id: UUID
    ) -> SynchronizedDeletionTarget? {
        if family == "person" { return .person(id) }
        if family == "interaction" { return .interaction(id) }
        let vaultPrefix = "vaultRecord."
        if family.hasPrefix(vaultPrefix),
           let kind = decoded(String(family.dropFirst(vaultPrefix.count))) {
            return .vaultRecord(id: id, kind: kind)
        }
        let profilesPrefix = "ownedProfileRecord."
        if family.hasPrefix(profilesPrefix),
           let kind = decoded(String(family.dropFirst(profilesPrefix.count))) {
            return .ownedProfileRecord(id: id, kind: kind)
        }
        return nil
    }

    private static func target(forDeletedObject object: NSManagedObject) -> SynchronizedDeletionTarget? {
        guard let id = object.value(forKey: "id") as? UUID else { return nil }
        switch object.entity.name {
        case "PersonEntity":
            return .person(id)
        case "InteractionEntity":
            return .interaction(id)
        case "CanonicalRecordEntity":
            guard let kind = object.value(forKey: "kind") as? String,
                  !isReservedKind(kind) else { return nil }
            return .vaultRecord(id: id, kind: kind)
        case "ProfileRecordEntity":
            guard let kind = object.value(forKey: "kind") as? String else { return nil }
            return .ownedProfileRecord(id: id, kind: kind)
        case "MediaPayloadEntity":
            return .vaultRecord(id: id, kind: "portraitMedia")
        default:
            return nil
        }
    }

    private func synchronizedTargetObjects() throws -> [NSManagedObject] {
        var result: [NSManagedObject] = []
        for entityName in [
            "PersonEntity",
            "InteractionEntity",
            "CanonicalRecordEntity",
            "ProfileRecordEntity",
            "MediaPayloadEntity",
        ] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            let objects = try context.fetch(request)
            result.append(contentsOf: objects.filter { !Self.isMarker($0) })
        }
        return result
    }

    private func destinationFingerprint() throws -> String {
        var lines = try synchronizedTargetObjects().compactMap { object -> String? in
            guard let target = Self.target(forDeletedObject: object) else { return nil }
            let epochs = Self.epochs(on: object).map(\.uuidString).sorted().joined(separator: ",")
            return "target|\(object.entity.name ?? "unknown")|\(Self.stableToken(for: target))|\(epochs)"
        }
        let controlRequest = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
        let controls = try context.fetch(controlRequest).filter(Self.isMarker)
        lines.append(contentsOf: controls.compactMap { object in
            guard let id = object.value(forKey: "id") as? UUID,
                  let kind = object.value(forKey: "kind") as? String else { return nil }
            return "control|\(kind)|\(id.uuidString)"
        })
        return Self.hash(lines.sorted())
    }

    private static func fingerprint(of state: DurableDeletionState) -> String {
        var lines = state.targets.map { "delete|\(stableToken(for: $0))" }
        lines.append(contentsOf: state.wipeEpochIDs.map { "epoch|\($0.uuidString)" })
        lines.append(contentsOf: state.generationMemberships.map {
            "member|\(stableToken(for: $0.target))|\($0.wipeEpochID.uuidString)"
        })
        return hash(lines.sorted())
    }

    private static func stableToken(for target: SynchronizedDeletionTarget) -> String {
        familyToken(for: target) + "|" + target.id.uuidString
    }

    private static func hash(_ lines: [String]) -> String {
        SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func stageControlRecord(id: UUID, kind: String, at date: Date) throws -> Bool {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
        request.predicate = NSPredicate(
            format: "id == %@ AND kind == %@",
            id as CVarArg,
            kind
        )
        var controls = try context.fetch(request)
        if controls.isEmpty {
            controls = [NSEntityDescription.insertNewObject(
                forEntityName: "CanonicalRecordEntity",
                into: context
            )]
        }
        var changed = false
        for control in controls {
            let needsUpdate = control.value(forKey: "id") as? UUID != id ||
                control.value(forKey: "kind") as? String != kind ||
                control.value(forKey: "payload") as? Data != Data() ||
                control.value(forKey: "createdAt") as? Date == nil ||
                control.value(forKey: "deletedAt") as? Date != nil
            guard needsUpdate else { continue }
            control.setValue(id, forKey: "id")
            control.setValue(kind, forKey: "kind")
            control.setValue(Data(), forKey: "payload")
            if control.value(forKey: "createdAt") == nil {
                control.setValue(date, forKey: "createdAt")
            }
            control.setValue(date, forKey: "modifiedAt")
            control.setValue(nil, forKey: "deletedAt")
            changed = true
        }
        return changed
    }

    private static func epochs(on object: NSManagedObject) -> Set<UUID> {
        guard let data = object.value(forKey: "vaultEpochsData") as? Data,
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values.compactMap(UUID.init(uuidString:)))
    }

    private static func encodeEpochs(_ epochs: Set<UUID>) throws -> Data {
        try JSONEncoder().encode(epochs.map(\.uuidString).sorted())
    }

    private static func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func decoded(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Stable identifiers that are intentionally deleted in the destination vault.
/// The migration inspector exposes IDs only so deleted private payloads never
/// leak into a normal archive or migration preview.
public struct ArchiveTombstoneInventory: Equatable, Sendable {
    public var personIDs: Set<UUID>
    public var interactionIDs: Set<UUID>
    public var structuredRecordIDs: Set<ArchiveStructuredRecordIdentity>

    public init(
        personIDs: Set<UUID> = [],
        interactionIDs: Set<UUID> = [],
        structuredRecordIDs: Set<ArchiveStructuredRecordIdentity> = []
    ) {
        self.personIDs = personIDs
        self.interactionIDs = interactionIDs
        self.structuredRecordIDs = structuredRecordIDs
    }

    public var isEmpty: Bool {
        personIDs.isEmpty && interactionIDs.isEmpty && structuredRecordIDs.isEmpty
    }

    func conflicts(with archive: NotebookArchive) -> ArchiveTombstoneInventory {
        let activePersonIDs = Set(archive.people.lazy.filter { $0.deletedAt == nil }.map(\.id))
        let activeInteractionIDs = Set(
            archive.interactions.lazy.filter { $0.deletedAt == nil }.map(\.id)
        )
        var incomingStructuredIDs = archive.canonical?.structuredRecordIdentities ?? []
        incomingStructuredIDs.formUnion(
            (archive.ownedProfileSnapshots ?? []).map {
                ArchiveStructuredRecordIdentity(
                    family: .profileSnapshot,
                    id: $0.cardVersionID
                )
            }
        )
        return ArchiveTombstoneInventory(
            personIDs: personIDs.intersection(activePersonIDs),
            interactionIDs: interactionIDs.intersection(activeInteractionIDs),
            structuredRecordIDs: structuredRecordIDs.intersection(incomingStructuredIDs)
        )
    }
}

/// The active destination archive used for normal stable-ID comparison plus a
/// payload-free deletion inventory used only by reviewed migration planning.
public struct ArchiveMigrationDestination: Sendable {
    public var archive: NotebookArchive
    public var tombstones: ArchiveTombstoneInventory

    public init(archive: NotebookArchive, tombstones: ArchiveTombstoneInventory) {
        self.archive = archive
        self.tombstones = tombstones
    }
}

public enum ArchiveImportCommitError: LocalizedError, Equatable, Sendable {
    case destinationContainsTombstones(ArchiveTombstoneInventory)
    case multipleActiveSelfIdentities([UUID])

    public var errorDescription: String? {
        switch self {
        case .destinationContainsTombstones:
            String(localized: "One or more incoming records were deleted in this notebook. They were not restored; review the edit-versus-delete conflict first.")
        case .multipleActiveSelfIdentities:
            String(localized: "This reviewed import would leave more than one active Me identity. Choose one Self record before importing; nothing was changed.")
        }
    }
}

extension CanonicalArchivePayload {
    var structuredRecordIdentities: Set<ArchiveStructuredRecordIdentity> {
        var identities: Set<ArchiveStructuredRecordIdentity> = []
        func insert(_ family: ArchiveStructuredRecordFamily, _ ids: some Sequence<UUID>) {
            identities.formUnion(ids.map {
                ArchiveStructuredRecordIdentity(family: family, id: $0)
            })
        }

        insert(.context, contexts.map(\.id))
        insert(.cohortScheme, cohortSchemes.map(\.id))
        insert(.cohort, cohorts.map(\.id))
        insert(.membership, memberships.map(\.id))
        insert(.cohortAssignment, cohortAssignments.map(\.id))
        insert(.roleDefinition, roleDefinitions.map(\.id))
        insert(.roleAssignment, roleAssignments.map(\.id))
        insert(.education, education.map(\.id))
        insert(.assertion, assertions.map(\.id))
        insert(.source, sources.map(\.id))
        insert(.artifactUnit, (artifactUnits ?? []).map(\.id))
        insert(.portraitMedia, (portraitMedia ?? []).map(\.id))
        insert(.evidence, evidence.map(\.id))
        insert(.reminder, reminders.map(\.id))
        insert(.commitment, commitments.map(\.id))
        insert(.savedView, savedViews.map(\.id))
        insert(.attributeDefinition, attributeDefinitions.map(\.id))
        insert(.textImportReview, textImportReviews.map(\.source.id))
        insert(.personMergeEvent, personMergeEvents.map(\.id))
        return identities
    }
}
