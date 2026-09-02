import Foundation

/// An active checkpoint target that cannot safely be inserted after the
/// destination's wipe controls are imported.
public struct CloudVaultMigrationGenerationConflict: Codable, Hashable, Sendable {
    public var target: DurableDeletionTarget
    public var missingWipeEpochIDs: Set<UUID>

    public init(
        target: DurableDeletionTarget,
        missingWipeEpochIDs: Set<UUID>
    ) {
        self.target = target
        self.missingWipeEpochIDs = missingWipeEpochIDs
    }
}

/// Pure data returned by the local-to-iCloud generation compatibility gate.
/// A migration must not copy archive values while `conflicts` is nonempty:
/// doing so would either revive pre-wipe data or cause the destination's
/// durable deletion reconciler to remove the copied value immediately.
public struct CloudVaultMigrationGenerationClassification: Codable, Equatable, Sendable {
    public var requiredWipeEpochIDs: Set<UUID>
    public var activeTargets: Set<DurableDeletionTarget>
    public var conflicts: Set<CloudVaultMigrationGenerationConflict>

    public init(
        requiredWipeEpochIDs: Set<UUID>,
        activeTargets: Set<DurableDeletionTarget>,
        conflicts: Set<CloudVaultMigrationGenerationConflict>
    ) {
        self.requiredWipeEpochIDs = requiredWipeEpochIDs
        self.activeTargets = activeTargets
        self.conflicts = conflicts
    }

    public var isCompatible: Bool { conflicts.isEmpty }
}

/// Classifies whether every active value in a protected migration checkpoint
/// belongs to every wipe generation that will exist after source and
/// destination deletion state are combined.
public enum CloudVaultMigrationGenerationGate: Sendable {
    /// The extensions dictionary is stored as one fixed canonical record.
    static let archiveExtensionsRecordID = UUID(
        uuidString: "2d1e33be-2f0b-4e9f-a69e-78b0d8351ad8"
    )!

    @MainActor
    public static func classify(
        archive: NotebookArchive,
        sourceDeletionState: DurableDeletionState,
        destinationDeletionState: DurableDeletionState
    ) throws -> CloudVaultMigrationGenerationClassification {
        // This rejects malformed checkpoint state, active values explicitly
        // marked deleted, and values that predate a source-side wipe.
        try NotebookStore.validateDurableDeletionState(
            sourceDeletionState,
            for: archive
        )
        // No destination archive is needed for this focused gate, but its
        // payload-free state must still obey the durable-state invariants.
        try SynchronizedDeletionMarkerRepository.validate(destinationDeletionState)

        let requiredEpochIDs = sourceDeletionState.wipeEpochIDs
            .union(destinationDeletionState.wipeEpochIDs)
        let activeTargets = activeTargets(in: archive)

        var membershipsByTarget: [DurableDeletionTarget: Set<UUID>] = [:]
        for membership in sourceDeletionState.generationMemberships {
            membershipsByTarget[membership.target, default: []]
                .insert(membership.wipeEpochID)
        }

        let conflicts: Set<CloudVaultMigrationGenerationConflict> = Set(
            activeTargets.compactMap { target -> CloudVaultMigrationGenerationConflict? in
                let missing = requiredEpochIDs.subtracting(
                    membershipsByTarget[target, default: []]
                )
                guard !missing.isEmpty else { return nil }
                return CloudVaultMigrationGenerationConflict(
                    target: target,
                    missingWipeEpochIDs: missing
                )
            }
        )

        return CloudVaultMigrationGenerationClassification(
            requiredWipeEpochIDs: requiredEpochIDs,
            activeTargets: activeTargets,
            conflicts: conflicts
        )
    }

    static func activeTargets(in archive: NotebookArchive) -> Set<DurableDeletionTarget> {
        var targets = Set(archive.people.lazy.filter { $0.deletedAt == nil }.map {
            DurableDeletionTarget.person($0.id)
        })
        targets.formUnion(archive.interactions.lazy.filter { $0.deletedAt == nil }.map {
            DurableDeletionTarget.interaction($0.id)
        })
        targets.formUnion(
            (archive.canonical?.structuredRecordIdentities ?? []).compactMap(
                durableTarget(for:)
            )
        )
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

    /// Portrait metadata and its MediaPayloadEntity bytes intentionally map to
    /// the same target. Durable state exports the intersection of the epochs
    /// stamped on both physical rows, so one membership proves both survived.
    static func durableTarget(
        for identity: ArchiveStructuredRecordIdentity
    ) -> DurableDeletionTarget? {
        switch identity.family {
        case .context:
            .vaultRecord(id: identity.id, kind: "context")
        case .cohortScheme:
            .vaultRecord(id: identity.id, kind: "cohortScheme")
        case .cohort:
            .vaultRecord(id: identity.id, kind: "cohort")
        case .membership:
            .vaultRecord(id: identity.id, kind: "membership")
        case .cohortAssignment:
            .vaultRecord(id: identity.id, kind: "cohortAssignment")
        case .roleDefinition:
            .vaultRecord(id: identity.id, kind: "roleDefinition")
        case .roleAssignment:
            .vaultRecord(id: identity.id, kind: "roleAssignment")
        case .education:
            .vaultRecord(id: identity.id, kind: "education")
        case .assertion:
            .vaultRecord(id: identity.id, kind: "assertion")
        case .source:
            .vaultRecord(id: identity.id, kind: "source")
        case .artifactUnit:
            .vaultRecord(id: identity.id, kind: "artifactUnit")
        case .portraitMedia:
            .vaultRecord(id: identity.id, kind: "portraitMedia")
        case .evidence:
            .vaultRecord(id: identity.id, kind: "evidence")
        case .reminder:
            .vaultRecord(id: identity.id, kind: "reminder")
        case .commitment:
            .vaultRecord(id: identity.id, kind: "commitment")
        case .savedView:
            .vaultRecord(id: identity.id, kind: "savedView")
        case .attributeDefinition:
            .vaultRecord(id: identity.id, kind: "attributeDefinition")
        case .textImportReview:
            .vaultRecord(id: identity.id, kind: "textImportReview")
        case .personMergeEvent:
            .vaultRecord(id: identity.id, kind: "personMergeEvent")
        case .profileSnapshot:
            .ownedProfileRecord(id: identity.id, kind: "profileSnapshot")
        }
    }
}
