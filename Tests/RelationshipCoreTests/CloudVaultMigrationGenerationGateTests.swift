import Foundation
import Testing
@testable import RelationshipCore

@Test @MainActor func destinationOnlyWipeEpochBlocksPreWipeSourceTarget() throws {
    let person = Person(displayName: "Source")
    let destinationEpoch = UUID()

    let result = try CloudVaultMigrationGenerationGate.classify(
        archive: NotebookArchive(people: [person], interactions: []),
        sourceDeletionState: .init(),
        destinationDeletionState: .init(wipeEpochIDs: [destinationEpoch])
    )

    let target = DurableDeletionTarget.person(person.id)
    #expect(result.requiredWipeEpochIDs == [destinationEpoch])
    #expect(result.activeTargets == [target])
    #expect(result.conflicts == [
        CloudVaultMigrationGenerationConflict(
            target: target,
            missingWipeEpochIDs: [destinationEpoch]
        )
    ])
    #expect(!result.isCompatible)
}

@Test @MainActor func epochSharedBySourceAndDestinationSurvivesGenerationGate() throws {
    let person = Person(displayName: "Current generation")
    let sharedEpoch = UUID()
    let target = DurableDeletionTarget.person(person.id)
    let membership = DurableVaultGenerationMembership(
        target: target,
        wipeEpochID: sharedEpoch
    )

    let result = try CloudVaultMigrationGenerationGate.classify(
        archive: NotebookArchive(people: [person], interactions: []),
        sourceDeletionState: .init(
            wipeEpochIDs: [sharedEpoch],
            generationMemberships: [membership]
        ),
        destinationDeletionState: .init(wipeEpochIDs: [sharedEpoch])
    )

    #expect(result.requiredWipeEpochIDs == [sharedEpoch])
    #expect(result.conflicts.isEmpty)
    #expect(result.isCompatible)
}

@Test @MainActor func sourceAndDestinationWipesRequireMembershipInBothEpochs() throws {
    let interaction = Interaction(personID: nil, summary: "Source-generation value")
    let sourceEpoch = UUID()
    let destinationEpoch = UUID()
    let target = DurableDeletionTarget.interaction(interaction.id)

    let result = try CloudVaultMigrationGenerationGate.classify(
        archive: NotebookArchive(people: [], interactions: [interaction]),
        sourceDeletionState: .init(
            wipeEpochIDs: [sourceEpoch],
            generationMemberships: [
                DurableVaultGenerationMembership(
                    target: target,
                    wipeEpochID: sourceEpoch
                )
            ]
        ),
        destinationDeletionState: .init(wipeEpochIDs: [destinationEpoch])
    )

    #expect(result.requiredWipeEpochIDs == [sourceEpoch, destinationEpoch])
    #expect(result.conflicts == [
        CloudVaultMigrationGenerationConflict(
            target: target,
            missingWipeEpochIDs: [destinationEpoch]
        )
    ])
}

@Test @MainActor func archiveTargetsUseExactPersistentKindsAndPhysicalMediaIdentity() throws {
    let expectedCanonicalKinds: [(ArchiveStructuredRecordFamily, String)] = [
        (.context, "context"),
        (.cohortScheme, "cohortScheme"),
        (.cohort, "cohort"),
        (.membership, "membership"),
        (.cohortAssignment, "cohortAssignment"),
        (.roleDefinition, "roleDefinition"),
        (.roleAssignment, "roleAssignment"),
        (.education, "education"),
        (.assertion, "assertion"),
        (.source, "source"),
        (.artifactUnit, "artifactUnit"),
        (.portraitMedia, "portraitMedia"),
        (.evidence, "evidence"),
        (.reminder, "reminder"),
        (.commitment, "commitment"),
        (.savedView, "savedView"),
        (.attributeDefinition, "attributeDefinition"),
        (.textImportReview, "textImportReview"),
        (.personMergeEvent, "personMergeEvent"),
    ]

    for (family, kind) in expectedCanonicalKinds {
        let id = UUID()
        #expect(
            CloudVaultMigrationGenerationGate.durableTarget(
                for: .init(family: family, id: id)
            ) == .vaultRecord(id: id, kind: kind)
        )
    }

    let profileID = UUID()
    #expect(
        CloudVaultMigrationGenerationGate.durableTarget(
            for: .init(family: .profileSnapshot, id: profileID)
        ) == .ownedProfileRecord(id: profileID, kind: "profileSnapshot")
    )

    let activePerson = Person(displayName: "Active")
    var deletedPerson = Person(displayName: "Deleted")
    deletedPerson.deletedAt = .now
    let activeInteraction = Interaction(personID: activePerson.id, summary: "Active")
    let deletedInteraction = Interaction(
        personID: activePerson.id,
        summary: "Deleted",
        deletedAt: .now
    )
    let context = Context(kind: .community, names: .init("Context"))
    let portrait = PortraitMediaAsset(
        personID: activePerson.id,
        sha256: "portrait-hash",
        byteCount: 12,
        pixelWidth: 2,
        pixelHeight: 2,
        isPrimary: true
    )
    let profile = ProfileCardSnapshotPayload(
        publicationID: UUID(),
        cardVersionID: profileID,
        cardVersion: 1,
        publishedAt: .now,
        advisoryExpiresAt: nil,
        retentionIntent: .recipientMayRetain,
        fields: []
    )
    let archive = NotebookArchive(
        people: [activePerson, deletedPerson],
        interactions: [activeInteraction, deletedInteraction],
        canonical: .init(contexts: [context], portraitMedia: [portrait]),
        ownedProfileSnapshots: [profile],
        preservedExtensions: ["future.value": .boolean(true)]
    )

    let result = try CloudVaultMigrationGenerationGate.classify(
        archive: archive,
        sourceDeletionState: .init(),
        destinationDeletionState: .init()
    )

    #expect(result.activeTargets == [
        .person(activePerson.id),
        .interaction(activeInteraction.id),
        .vaultRecord(id: context.id, kind: "context"),
        // Portrait metadata and MediaPayloadEntity bytes share this one target.
        .vaultRecord(id: portrait.id, kind: "portraitMedia"),
        .ownedProfileRecord(id: profileID, kind: "profileSnapshot"),
        .vaultRecord(
            id: UUID(uuidString: "2d1e33be-2f0b-4e9f-a69e-78b0d8351ad8")!,
            kind: "archiveExtensions"
        ),
    ])
    #expect(result.conflicts.isEmpty)
}

@Test @MainActor func malformedDurableStatesAreRejectedBeforeClassification() throws {
    let person = Person(displayName: "Invalid checkpoint")
    let unknownEpoch = UUID()

    #expect(throws: DurableDeletionStateError.self) {
        _ = try CloudVaultMigrationGenerationGate.classify(
            archive: NotebookArchive(people: [person], interactions: []),
            sourceDeletionState: .init(
                generationMemberships: [
                    .init(target: .person(person.id), wipeEpochID: unknownEpoch)
                ]
            ),
            destinationDeletionState: .init()
        )
    }

    #expect(throws: DurableDeletionStateError.self) {
        _ = try CloudVaultMigrationGenerationGate.classify(
            archive: NotebookArchive(people: [person], interactions: []),
            sourceDeletionState: .init(),
            destinationDeletionState: .init(
                generationMemberships: [
                    .init(target: .person(person.id), wipeEpochID: unknownEpoch)
                ]
            )
        )
    }
}
