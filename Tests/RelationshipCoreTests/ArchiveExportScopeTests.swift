import Foundation
import Testing
@testable import RelationshipCore

@Test func savedViewExportResolverUsesTheReviewedArchivedScope() async throws {
    let active = Person(displayName: "Active")
    var archived = Person(displayName: "Archived")
    archived.isArchived = true
    var deleted = Person(displayName: "Deleted")
    deleted.deletedAt = Date(timeIntervalSince1970: 10)
    let view = SavedView(
        name: "Everyone",
        filter: .condition(.init(field: LocalSearchPersonField.name, operator: .exists))
    )
    let resolver = SavedViewExportScopeResolver()

    let visibleIDs = try await resolver.personIDs(
        in: view,
        people: [active, archived, deleted],
        canonical: CanonicalArchivePayload(),
        includeArchived: false,
        localeIdentifier: "en_US",
        referenceDate: Date(timeIntervalSince1970: 20)
    )
    #expect(visibleIDs == Set([active.id]))

    let expandedIDs = try await resolver.personIDs(
        in: view,
        people: [active, archived, deleted],
        canonical: CanonicalArchivePayload(),
        includeArchived: true,
        localeIdentifier: "en_US",
        referenceDate: Date(timeIntervalSince1970: 20)
    )
    #expect(expandedIDs == Set([active.id, archived.id]))
}

@Test func scopedArchiveExcludesUnrelatedPeopleAndRawSharedSourceText() throws {
    let selected = Person(displayName: "Selected")
    let unrelated = Person(displayName: "Unrelated")
    let context = Context(kind: .community, names: LocalizedText("Shared community"))
    let selectedMembership = MembershipEpisode(personID: selected.id, contextID: context.id)
    let unrelatedMembership = MembershipEpisode(personID: unrelated.id, contextID: context.id)

    let source = SourceArtifact(kind: .pastedText, sha256: "source-hash")
    let unit = ArtifactUnit(sourceID: source.id, kind: .textBlock, index: 0)
    let selectedEvidence = try EvidenceSpan(
        unitID: unit.id,
        textRange: TextEvidenceRange(startUTF16Offset: 0, endUTF16Offset: 8),
        retainedExcerpt: "Selected"
    )
    let unrelatedEvidence = try EvidenceSpan(
        unitID: unit.id,
        textRange: TextEvidenceRange(startUTF16Offset: 9, endUTF16Offset: 18),
        retainedExcerpt: "Unrelated"
    )
    let selectedAssertion = try AssertionEnvelope(
        subjectID: selected.id,
        predicateID: "import.role",
        value: .text("Organizer"),
        sourceID: source.id,
        evidenceIDs: [selectedEvidence.id],
        origin: .imported
    )
    let unrelatedAssertion = try AssertionEnvelope(
        subjectID: unrelated.id,
        predicateID: "import.role",
        value: .text("Treasurer"),
        sourceID: source.id,
        evidenceIDs: [unrelatedEvidence.id],
        origin: .imported
    )

    let reviewSource = TextImportSourceArtifact(
        id: source.id,
        kind: .pastedText,
        text: "Selected | role: Organizer\nUnrelated | role: Treasurer"
    )
    let review = TextImportReview(
        source: reviewSource,
        evidence: [
            TextEvidenceSpan(
                id: selectedEvidence.id,
                sourceID: source.id,
                lineNumber: 1,
                location: 0,
                length: 8,
                excerpt: "Selected"
            ),
            TextEvidenceSpan(
                id: unrelatedEvidence.id,
                sourceID: source.id,
                lineNumber: 2,
                location: 27,
                length: 9,
                excerpt: "Unrelated"
            )
        ],
        candidates: [
            TextImportCandidate(
                id: selected.id,
                sourceID: source.id,
                proposedDisplayName: selected.displayName,
                confidence: 1,
                evidenceIDs: [selectedEvidence.id],
                assertions: [TextImportCandidateAssertion(
                    id: selectedAssertion.id,
                    predicate: .role,
                    value: "Organizer",
                    confidence: 1,
                    evidenceIDs: [selectedEvidence.id],
                    isPreselectedForReview: true
                )],
                isPreselectedForReview: true
            ),
            TextImportCandidate(
                id: unrelated.id,
                sourceID: source.id,
                proposedDisplayName: unrelated.displayName,
                confidence: 1,
                evidenceIDs: [unrelatedEvidence.id],
                assertions: [TextImportCandidateAssertion(
                    id: unrelatedAssertion.id,
                    predicate: .role,
                    value: "Treasurer",
                    confidence: 1,
                    evidenceIDs: [unrelatedEvidence.id],
                    isPreselectedForReview: true
                )],
                isPreselectedForReview: true
            )
        ],
        safetyFindings: [],
        parserVersion: "test"
    )

    let selectedOnlyInteraction = Interaction(personID: selected.id, summary: "Selected only")
    let mixedInteraction = Interaction(
        personID: selected.id,
        summary: "Mixed group",
        additionalParticipantIDs: [unrelated.id]
    )
    let archive = NotebookArchive(
        people: [selected, unrelated],
        interactions: [selectedOnlyInteraction, mixedInteraction],
        canonical: CanonicalArchivePayload(
            contexts: [context],
            memberships: [selectedMembership, unrelatedMembership],
            assertions: [selectedAssertion, unrelatedAssertion],
            sources: [source],
            artifactUnits: [unit],
            evidence: [selectedEvidence, unrelatedEvidence],
            textImportReviews: [review]
        ),
        preservedExtensions: ["future.private": .string("must not leak")]
    )

    let scoped = try NotebookArchiveSlicer().slice(
        archive,
        to: .selectedPeople([selected.id])
    )

    #expect(scoped.people.map(\.id) == [selected.id])
    #expect(scoped.interactions.map(\.id) == [selectedOnlyInteraction.id])
    #expect(scoped.canonical?.memberships.map(\.id) == [selectedMembership.id])
    #expect(scoped.canonical?.assertions.map(\.id) == [selectedAssertion.id])
    #expect(scoped.canonical?.evidence.map(\.id) == [selectedEvidence.id])
    #expect(scoped.canonical?.textImportReviews.first?.source.text == "")
    #expect(scoped.canonical?.textImportReviews.first?.candidates.map(\.id) == [selected.id])
    #expect(scoped.ownedProfileSnapshots?.isEmpty == true)
    #expect(scoped.preservedExtensions == nil)
}

@Test func selfProfileScopeContainsNoRelationshipGraph() throws {
    let snapshot = try ProfileCardSnapshotSerializer().serialize(ProfileCardSnapshotDraft(
        cardVersion: 1,
        fields: [ProfileSnapshotFieldDraft(
            key: ShareableProfileFieldKey.preferredName.rawValue,
            value: .text("Owner")
        )]
    )).payload
    let archive = NotebookArchive(
        people: [Person(displayName: "Private person")],
        interactions: [Interaction(personID: UUID(), summary: "Private")],
        canonical: CanonicalArchivePayload(contexts: [
            Context(kind: .community, names: LocalizedText("Private context"))
        ]),
        ownedProfileSnapshots: [snapshot]
    )

    let scoped = try NotebookArchiveSlicer().slice(archive, to: .selfProfilesOnly)
    #expect(scoped.people.isEmpty)
    #expect(scoped.interactions.isEmpty)
    #expect(scoped.canonical?.contexts.isEmpty == true)
    #expect(scoped.ownedProfileSnapshots?.map(\.cardVersionID) == [snapshot.cardVersionID])
}
