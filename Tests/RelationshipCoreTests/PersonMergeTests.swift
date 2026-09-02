import Foundation
import Testing
@testable import RelationshipCore

@MainActor
struct PersonMergeTests {
    @Test func mergeRequiresExplicitPairAndCanBeUndoneWithoutLosingInteractions() throws {
        let store = NotebookStore(inMemory: true)
        let source = Person(
            displayName: "田中 愛子",
            aliases: ["Aiko"],
            contexts: ["Scholarship"],
            privateNote: "Source-only note",
            contacts: [.init(kind: .line, value: "aiko")]
        )
        let destination = Person(
            displayName: "Aiko Tanaka",
            aliases: ["Tanaka Aiko"],
            contexts: ["Studio"],
            privateNote: "Destination note"
        )
        store.save(source)
        store.save(destination)
        let interaction = Interaction(personID: source.id, summary: "Met at orientation")
        store.save(interaction)

        let preview = try store.mergePreview(sourceID: source.id, destinationID: destination.id)
        #expect(preview.resultingPerson.aliases.contains("田中 愛子"))
        #expect(preview.resultingPerson.contexts == ["Studio", "Scholarship"])
        #expect(preview.interactionsToMove == 1)
        #expect(preview.warnings.isEmpty == false)

        let event = try store.mergePeople(sourceID: source.id, into: destination.id)
        #expect(store.person(id: source.id)?.mergedIntoPersonID == destination.id)
        #expect(store.interactions.first?.personID == destination.id)
        #expect(store.person(id: destination.id)?.privateNote == "Destination note")

        try store.undoMerge(event)
        #expect(store.person(id: source.id)?.mergedIntoPersonID == nil)
        #expect(store.person(id: source.id)?.privateNote == "Source-only note")
        #expect(store.person(id: destination.id)?.contexts == ["Studio"])
        #expect(store.interactions.first?.personID == source.id)
        #expect(throws: PersonMergeError.alreadyUndone) {
            try store.undoMerge(event)
        }
    }

    @Test func mergeNeverAllowsARecordToMergeIntoItself() {
        let store = NotebookStore(inMemory: true)
        let person = Person(displayName: "Alex")
        store.save(person)
        #expect(throws: PersonMergeError.samePerson) {
            try store.mergePreview(sourceID: person.id, destinationID: person.id)
        }
    }

    @Test func mergeRedirectsImmutableProvenanceAndRestoresMutableReferencesOnUndo() throws {
        let persistence = PersistenceController(inMemory: true)
        let store = NotebookStore(persistence: persistence)
        let canonical = CanonicalVaultStore(persistence: persistence)
        let source = Person(displayName: "Source")
        let destination = Person(displayName: "Destination")
        store.save(source)
        store.save(destination)

        let context = Context(kind: .community, names: .init("Community"))
        let membership = MembershipEpisode(personID: source.id, contextID: context.id)
        let enrollment = EducationEnrollment(personID: source.id, institutionContextID: context.id)
        let assertion = try AssertionEnvelope(
            subjectID: source.id,
            predicateID: "relationship.mentor",
            value: .personReference(source.id)
        )
        let reminder = Reminder(
            subject: .person(source.id),
            title: "Follow up",
            due: .instant(.now, timeZoneIdentifier: nil)
        )
        let commitment = Commitment(
            personIDs: [source.id, destination.id],
            summary: "Send notes",
            owner: .person(source.id)
        )
        let portrait = PortraitMediaAsset(
            personID: source.id,
            sha256: "test-digest",
            byteCount: 4,
            pixelWidth: 1,
            pixelHeight: 1,
            isPrimary: true
        )
        canonical.save(context)
        canonical.save(membership)
        canonical.save(enrollment)
        canonical.save(assertion)
        canonical.save(reminder)
        canonical.save(commitment)
        canonical.save(portrait)

        let interaction = Interaction(
            personID: source.id,
            summary: "Group meeting",
            additionalParticipantIDs: [destination.id]
        )
        store.save(interaction)
        let event = try store.mergePeople(sourceID: source.id, into: destination.id)
        canonical.reload()

        #expect(canonical.resolvedPersonID(source.id) == destination.id)
        #expect(canonical.memberships.first?.personID == source.id)
        #expect(canonical.memberships(for: destination.id).map(\.id) == [membership.id])
        #expect(canonical.education(for: destination.id).map(\.id) == [enrollment.id])
        #expect(canonical.assertions(for: destination.id).map(\.id) == [assertion.id])
        #expect(canonical.contexts(for: destination.id).map(\.id) == [context.id])
        #expect(canonical.portraits(for: destination.id).map(\.id) == [portrait.id])
        #expect(canonical.portraitMedia.first?.personID == source.id)
        #expect(canonical.reminders.first?.subject == .person(destination.id))
        #expect(canonical.commitments.first?.personIDs == [destination.id])
        #expect(canonical.commitments.first?.owner == .person(destination.id))
        #expect(store.interactions.first?.personID == destination.id)
        #expect(store.interactions.first?.additionalParticipantIDs == nil)

        try store.undoMerge(event)
        canonical.reload()

        #expect(canonical.resolvedPersonID(source.id) == source.id)
        #expect(canonical.portraits(for: source.id).map(\.id) == [portrait.id])
        #expect(canonical.reminders.first?.subject == .person(source.id))
        #expect(canonical.commitments.first?.personIDs == [source.id, destination.id])
        #expect(canonical.commitments.first?.owner == .person(source.id))
        #expect(store.interactions.first?.personID == source.id)
        #expect(store.interactions.first?.additionalParticipantIDs == [destination.id])
    }

    @Test func undoRefusesToOverwriteAnInteractionEditedAfterMerge() throws {
        let store = NotebookStore(inMemory: true)
        let source = Person(displayName: "Source")
        let destination = Person(displayName: "Destination")
        store.save(source)
        store.save(destination)
        store.save(Interaction(personID: source.id, summary: "Original"))

        let event = try store.mergePeople(sourceID: source.id, into: destination.id)
        var edited = try #require(store.interactions.first)
        edited.summary = "Edited after merge"
        edited.status = .unknown
        store.save(edited)

        #expect(throws: PersonMergeError.interactionChanged) {
            try store.undoMerge(event)
        }
        #expect(store.interactions.first?.summary == "Edited after merge")
        #expect(store.person(id: source.id)?.mergedIntoPersonID == destination.id)
    }

    @Test func undoRefusesToOverwriteACanonicalRecordEditedAfterMerge() throws {
        let persistence = PersistenceController(inMemory: true)
        let store = NotebookStore(persistence: persistence)
        let canonical = CanonicalVaultStore(persistence: persistence)
        let source = Person(displayName: "Source")
        let destination = Person(displayName: "Destination")
        store.save(source)
        store.save(destination)
        canonical.save(Reminder(
            subject: .person(source.id),
            title: "Original",
            due: .instant(.now, timeZoneIdentifier: nil)
        ))

        let event = try store.mergePeople(sourceID: source.id, into: destination.id)
        canonical.reload()
        var edited = try #require(canonical.reminders.first)
        edited.title = "Edited after merge"
        edited.modifiedAt = .now
        canonical.save(edited)

        #expect(throws: PersonMergeError.canonicalRecordChanged) {
            try store.undoMerge(event)
        }
        canonical.reload()
        #expect(canonical.reminders.first?.title == "Edited after merge")
        #expect(store.person(id: source.id)?.mergedIntoPersonID == destination.id)
    }

    @Test func permanentDeletionUnlinksGroupHistoryAndRemovesCanonicalPersonReferences() throws {
        let persistence = PersistenceController(inMemory: true)
        let store = NotebookStore(persistence: persistence)
        let canonical = CanonicalVaultStore(persistence: persistence)
        let target = Person(displayName: "Delete me")
        let survivor = Person(displayName: "Keep me")
        store.save(target)
        store.save(survivor)

        let promoted = Interaction(
            personID: target.id,
            summary: "Promote survivor",
            additionalParticipantIDs: [survivor.id]
        )
        let secondary = Interaction(
            personID: survivor.id,
            summary: "Remove secondary",
            additionalParticipantIDs: [target.id]
        )
        let unlinked = Interaction(personID: target.id, summary: "Retain unlinked")
        store.save(promoted)
        store.save(secondary)
        store.save(unlinked)

        let context = Context(kind: .community, names: .init("Community"))
        let assertion = try AssertionEnvelope(
            subjectID: target.id,
            predicateID: "person.note",
            value: .text("Private")
        )
        let membership = MembershipEpisode(
            personID: target.id,
            contextID: context.id,
            assertionID: assertion.id
        )
        let cohortAssignment = CohortAssignment(
            membershipEpisodeID: membership.id,
            cohortID: UUID(),
            assertionID: assertion.id
        )
        let roleAssignment = RoleAssignment(
            membershipEpisodeID: membership.id,
            roleLabel: .init("Member"),
            assertionID: assertion.id
        )
        let enrollment = EducationEnrollment(
            personID: target.id,
            institutionContextID: context.id,
            assertionID: assertion.id
        )
        let personReminder = Reminder(
            subject: .person(target.id),
            title: "Person reminder",
            due: .instant(.now, timeZoneIdentifier: nil)
        )
        let assertionReminder = Reminder(
            subject: .assertion(assertion.id),
            title: "Assertion reminder",
            due: .instant(.now, timeZoneIdentifier: nil)
        )
        let commitment = Commitment(
            interactionID: unlinked.id,
            personIDs: [target.id, survivor.id],
            summary: "Shared task",
            owner: .shared([target.id]),
            sourceAssertionID: assertion.id
        )
        let portrait = PortraitMediaAsset(
            personID: target.id,
            sha256: "test-digest",
            byteCount: 4,
            pixelWidth: 1,
            pixelHeight: 1,
            isPrimary: true
        )
        canonical.save(context)
        canonical.save(assertion)
        canonical.save(membership)
        canonical.save(cohortAssignment)
        canonical.save(roleAssignment)
        canonical.save(enrollment)
        canonical.save(personReminder)
        canonical.save(assertionReminder)
        canonical.save(commitment)
        canonical.save(portrait)

        store.permanentlyDelete(target, deleteInteractions: false)
        canonical.reload()

        #expect(store.person(id: target.id) == nil)
        #expect(store.interactions.first(where: { $0.id == promoted.id })?.personID == survivor.id)
        #expect(store.interactions.first(where: { $0.id == promoted.id })?.additionalParticipantIDs == nil)
        #expect(store.interactions.first(where: { $0.id == secondary.id })?.personID == survivor.id)
        #expect(store.interactions.first(where: { $0.id == secondary.id })?.additionalParticipantIDs == nil)
        #expect(store.interactions.first(where: { $0.id == unlinked.id })?.personID == nil)
        #expect(canonical.memberships.isEmpty)
        #expect(canonical.cohortAssignments.isEmpty)
        #expect(canonical.roleAssignments.isEmpty)
        #expect(canonical.education.isEmpty)
        #expect(canonical.assertions.isEmpty)
        #expect(canonical.portraitMedia.isEmpty)
        #expect(canonical.reminders.isEmpty)
        #expect(canonical.commitments.first?.personIDs == [survivor.id])
        #expect(canonical.commitments.first?.owner == .unspecified)
        #expect(canonical.commitments.first?.sourceAssertionID == nil)
        #expect(canonical.commitments.first?.interactionID == unlinked.id)
    }

    @Test func permanentDeletionCanRemoveGroupInteractionsAndDetachCommitments() {
        let persistence = PersistenceController(inMemory: true)
        let store = NotebookStore(persistence: persistence)
        let canonical = CanonicalVaultStore(persistence: persistence)
        let target = Person(displayName: "Delete me")
        let survivor = Person(displayName: "Keep me")
        store.save(target)
        store.save(survivor)
        let interaction = Interaction(
            personID: survivor.id,
            summary: "Shared history",
            additionalParticipantIDs: [target.id]
        )
        store.save(interaction)
        canonical.save(Reminder(
            subject: .interaction(interaction.id),
            title: "Interaction reminder",
            due: .instant(.now, timeZoneIdentifier: nil)
        ))
        canonical.save(Commitment(
            interactionID: interaction.id,
            personIDs: [survivor.id, target.id],
            summary: "Shared task",
            owner: .person(target.id)
        ))

        store.permanentlyDelete(target, deleteInteractions: true)
        canonical.reload()

        #expect(store.interactions.isEmpty)
        #expect(canonical.reminders.isEmpty)
        #expect(canonical.commitments.first?.interactionID == nil)
        #expect(canonical.commitments.first?.personIDs == [survivor.id])
        #expect(canonical.commitments.first?.owner == .unspecified)
    }

    @Test func permanentDeletionRemovesAnExclusiveImportProvenanceGraph() throws {
        let persistence = PersistenceController(inMemory: true)
        let store = NotebookStore(persistence: persistence)
        let canonical = CanonicalVaultStore(persistence: persistence)
        let target = Person(displayName: "Delete me")
        store.save(target)

        let sourceID = UUID()
        let unitID = UUID()
        let evidenceID = UUID()
        let source = SourceArtifact(
            id: sourceID,
            kind: .pastedText,
            sha256: "exclusive-source"
        )
        let unit = ArtifactUnit(id: unitID, sourceID: sourceID, kind: .textBlock, index: 0)
        let evidence = try EvidenceSpan(
            id: evidenceID,
            unitID: unitID,
            textRange: TextEvidenceRange(startUTF16Offset: 0, endUTF16Offset: 9),
            excerptHash: "exclusive-evidence",
            retainedExcerpt: "Delete me"
        )
        let assertion = try AssertionEnvelope(
            subjectID: target.id,
            predicateID: "import.role",
            value: .text("Organizer"),
            sourceID: sourceID,
            evidenceIDs: [evidenceID],
            origin: .imported
        )
        let reviewSource = TextImportSourceArtifact(
            id: sourceID,
            kind: .pastedText,
            text: "Delete me | role: Organizer",
            retentionPolicy: .keepOriginal
        )
        let reviewEvidence = TextEvidenceSpan(
            id: evidenceID,
            sourceID: sourceID,
            lineNumber: 1,
            location: 0,
            length: 9,
            excerpt: "Delete me"
        )
        let review = TextImportReview(
            source: reviewSource,
            evidence: [reviewEvidence],
            candidates: [TextImportCandidate(
                id: target.id,
                sourceID: sourceID,
                proposedDisplayName: target.displayName,
                confidence: 1,
                evidenceIDs: [evidenceID],
                assertions: [TextImportCandidateAssertion(
                    id: UUID(),
                    predicate: .role,
                    value: "Organizer",
                    confidence: 1,
                    evidenceIDs: [evidenceID],
                    isPreselectedForReview: true
                )],
                reviewState: .accepted,
                isPreselectedForReview: true
            )],
            safetyFindings: [],
            parserVersion: "test"
        )
        canonical.save(source)
        canonical.save(unit)
        canonical.save(evidence)
        canonical.save(assertion)
        canonical.save(review)

        store.permanentlyDelete(target, deleteInteractions: true)
        canonical.reload()

        #expect(store.lastError == nil)
        #expect(store.person(id: target.id) == nil)
        #expect(canonical.assertions.isEmpty)
        #expect(canonical.sources.isEmpty)
        #expect(canonical.artifactUnits.isEmpty)
        #expect(canonical.evidence.isEmpty)
        #expect(canonical.textImportReviews.isEmpty)
    }

    @Test func permanentDeletionSanitizesSharedImportProvenanceWithoutDanglingReferences() throws {
        let persistence = PersistenceController(inMemory: true)
        let store = NotebookStore(persistence: persistence)
        let canonical = CanonicalVaultStore(persistence: persistence)
        let target = Person(displayName: "Delete me")
        let survivor = Person(displayName: "Keep me")
        store.save(target)
        store.save(survivor)

        let sourceID = UUID()
        let targetUnitID = UUID()
        let survivorUnitID = UUID()
        let targetEvidenceID = UUID()
        let survivorEvidenceID = UUID()
        let source = SourceArtifact(id: sourceID, kind: .pastedText, sha256: "shared-source")
        let targetUnit = ArtifactUnit(
            id: targetUnitID,
            sourceID: sourceID,
            kind: .textBlock,
            index: 0
        )
        let survivorUnit = ArtifactUnit(
            id: survivorUnitID,
            sourceID: sourceID,
            kind: .textBlock,
            index: 1
        )
        let targetEvidence = try EvidenceSpan(
            id: targetEvidenceID,
            unitID: targetUnitID,
            retainedExcerpt: "Delete me"
        )
        let survivorEvidence = try EvidenceSpan(
            id: survivorEvidenceID,
            unitID: survivorUnitID,
            retainedExcerpt: "Keep me"
        )
        let targetAssertion = try AssertionEnvelope(
            subjectID: target.id,
            predicateID: "import.role",
            value: .text("Organizer"),
            sourceID: sourceID,
            evidenceIDs: [targetEvidenceID],
            origin: .imported
        )
        let survivorAssertion = try AssertionEnvelope(
            subjectID: survivor.id,
            predicateID: "import.role",
            value: .text("Mentor"),
            sourceID: sourceID,
            evidenceIDs: [survivorEvidenceID],
            origin: .imported
        )
        let reviewSource = TextImportSourceArtifact(
            id: sourceID,
            kind: .pastedText,
            text: "Delete me | role: Organizer\nKeep me | role: Mentor",
            retentionPolicy: .keepOriginal
        )
        let targetReviewEvidence = TextEvidenceSpan(
            id: targetEvidenceID,
            sourceID: sourceID,
            lineNumber: 1,
            location: 0,
            length: 9,
            excerpt: "Delete me"
        )
        let survivorReviewEvidence = TextEvidenceSpan(
            id: survivorEvidenceID,
            sourceID: sourceID,
            lineNumber: 2,
            location: 28,
            length: 7,
            excerpt: "Keep me"
        )
        let targetCandidate = TextImportCandidate(
            id: target.id,
            sourceID: sourceID,
            proposedDisplayName: target.displayName,
            confidence: 1,
            evidenceIDs: [targetEvidenceID],
            assertions: [TextImportCandidateAssertion(
                id: UUID(),
                predicate: .role,
                value: "Organizer",
                confidence: 1,
                evidenceIDs: [targetEvidenceID],
                isPreselectedForReview: true
            )],
            possibleDuplicateCandidateIDs: [survivor.id],
            reviewState: .accepted,
            isPreselectedForReview: true
        )
        let survivorCandidate = TextImportCandidate(
            id: survivor.id,
            sourceID: sourceID,
            proposedDisplayName: survivor.displayName,
            confidence: 1,
            evidenceIDs: [survivorEvidenceID],
            assertions: [TextImportCandidateAssertion(
                id: UUID(),
                predicate: .role,
                value: "Mentor",
                confidence: 1,
                evidenceIDs: [survivorEvidenceID],
                isPreselectedForReview: true
            )],
            possibleDuplicateCandidateIDs: [target.id],
            reviewState: .accepted,
            isPreselectedForReview: true
        )
        let review = TextImportReview(
            source: reviewSource,
            evidence: [targetReviewEvidence, survivorReviewEvidence],
            candidates: [targetCandidate, survivorCandidate],
            safetyFindings: [
                TextImportSafetyFinding(
                    id: UUID(),
                    category: .unsupportedField,
                    evidenceID: targetEvidenceID,
                    message: "Target-only finding",
                    blockedFromCandidateOutput: false
                ),
                TextImportSafetyFinding(
                    id: UUID(),
                    category: .unsupportedField,
                    evidenceID: survivorEvidenceID,
                    message: "Survivor finding",
                    blockedFromCandidateOutput: false
                )
            ],
            parserVersion: "test"
        )
        canonical.save(source)
        canonical.save(targetUnit)
        canonical.save(survivorUnit)
        canonical.save(targetEvidence)
        canonical.save(survivorEvidence)
        canonical.save(targetAssertion)
        canonical.save(survivorAssertion)
        canonical.save(review)

        store.permanentlyDelete(target, deleteInteractions: true)
        canonical.reload()

        let sanitizedReview = try #require(canonical.textImportReviews.first)
        let retainedCandidate = try #require(sanitizedReview.candidates.first)
        let sourceIDs = Set(canonical.sources.map(\.id))
        let unitIDs = Set(canonical.artifactUnits.map(\.id))
        let evidenceIDs = Set(canonical.evidence.map(\.id))
        #expect(store.lastError == nil)
        #expect(canonical.assertions.map(\.id) == [survivorAssertion.id])
        #expect(sourceIDs == [sourceID])
        #expect(unitIDs == [survivorUnitID])
        #expect(evidenceIDs == [survivorEvidenceID])
        #expect(sanitizedReview.candidates.map(\.id) == [survivor.id])
        #expect(sanitizedReview.evidence.map(\.id) == [survivorEvidenceID])
        #expect(sanitizedReview.safetyFindings.map(\.evidenceID) == [survivorEvidenceID])
        #expect(retainedCandidate.evidenceIDs == [survivorEvidenceID])
        #expect(retainedCandidate.assertions.first?.evidenceIDs == [survivorEvidenceID])
        #expect(retainedCandidate.possibleDuplicateCandidateIDs.isEmpty)
        #expect(canonical.assertions.allSatisfy { Set($0.evidenceIDs).isSubset(of: evidenceIDs) })
        #expect(canonical.evidence.allSatisfy { unitIDs.contains($0.unitID) })
        #expect(canonical.artifactUnits.allSatisfy { sourceIDs.contains($0.sourceID) })
    }

    @Test func retainedUnlinkedInteractionKeepsItsEvidenceChainAndSanitizesReview() throws {
        let persistence = PersistenceController(inMemory: true)
        let store = NotebookStore(persistence: persistence)
        let canonical = CanonicalVaultStore(persistence: persistence)
        let target = Person(displayName: "Delete me")
        store.save(target)

        let sourceID = UUID()
        let unitID = UUID()
        let evidenceID = UUID()
        let source = SourceArtifact(id: sourceID, kind: .pastedText, sha256: "interaction-source")
        let unit = ArtifactUnit(id: unitID, sourceID: sourceID, kind: .message, index: 0)
        let evidence = try EvidenceSpan(
            id: evidenceID,
            unitID: unitID,
            retainedExcerpt: "Retained interaction evidence"
        )
        let reviewSource = TextImportSourceArtifact(
            id: sourceID,
            kind: .pastedText,
            text: "Retained interaction evidence",
            retentionPolicy: .keepOriginal
        )
        let reviewEvidence = TextEvidenceSpan(
            id: evidenceID,
            sourceID: sourceID,
            lineNumber: 1,
            location: 0,
            length: 29,
            excerpt: "Retained interaction evidence"
        )
        let review = TextImportReview(
            source: reviewSource,
            evidence: [reviewEvidence],
            candidates: [TextImportCandidate(
                id: target.id,
                sourceID: sourceID,
                proposedDisplayName: target.displayName,
                confidence: 1,
                evidenceIDs: [evidenceID],
                assertions: [],
                reviewState: .accepted,
                isPreselectedForReview: true
            )],
            safetyFindings: [],
            parserVersion: "test"
        )
        let interaction = Interaction(
            personID: target.id,
            summary: "Retain this history",
            sourceEvidenceIDs: [evidenceID]
        )
        canonical.save(source)
        canonical.save(unit)
        canonical.save(evidence)
        canonical.save(review)
        store.save(interaction)

        store.permanentlyDelete(target, deleteInteractions: false)
        canonical.reload()

        let retainedInteraction = try #require(store.interactions.first)
        let sanitizedReview = try #require(canonical.textImportReviews.first)
        #expect(store.lastError == nil)
        #expect(retainedInteraction.personID == nil)
        #expect(retainedInteraction.sourceEvidenceIDs == [evidenceID])
        #expect(canonical.sources.map(\.id) == [sourceID])
        #expect(canonical.artifactUnits.map(\.id) == [unitID])
        #expect(canonical.evidence.map(\.id) == [evidenceID])
        #expect(sanitizedReview.candidates.isEmpty)
        #expect(sanitizedReview.evidence.map(\.id) == [evidenceID])
    }
}
