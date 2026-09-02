import Foundation

public enum NotebookArchiveExportScope: Hashable, Sendable {
    case fullVault
    case selectedPeople(Set<UUID>)
    case selfProfilesOnly
}

public enum NotebookArchiveSlicingError: LocalizedError, Equatable, Sendable {
    case selectedPersonMissing(UUID)

    public var errorDescription: String? {
        switch self {
        case .selectedPersonMissing:
            String(localized: "A selected person is no longer available for export.")
        }
    }
}

/// Resolves the exact visible archived-record scope of a saved view before a
/// person-scoped export is sliced. Keeping this in the core prevents an export
/// surface from silently substituting a broader query than People search.
public struct SavedViewExportScopeResolver: Sendable {
    public init() {}

    public func personIDs(
        in savedView: SavedView,
        people: [Person],
        canonical: CanonicalArchivePayload,
        includeArchived: Bool,
        localeIdentifier: String = Locale.current.identifier,
        referenceDate: Date = .now
    ) async throws -> Set<UUID> {
        let search = LocalSearch(schema: .localSearchPerson(
            customAttributes: canonical.attributeDefinitions
        ))
        let documents = CanonicalLocalSearchProjection().documents(
            people: people,
            canonical: canonical,
            localeIdentifier: localeIdentifier
        )
        _ = try await search.rebuild(
            from: CollectionLocalSearchRebuildSource(documents: documents),
            batchSize: 500
        )

        var result = Set<UUID>()
        var cursor: LocalSearchCursor?
        repeat {
            let page = try await search.search(
                savedView: savedView,
                includeArchived: includeArchived,
                referenceDate: referenceDate,
                localeIdentifier: localeIdentifier,
                page: LocalSearchPageRequest(limit: 500, cursor: cursor)
            )
            result.formUnion(page.hits.map(\.personID))
            cursor = page.nextCursor
        } while cursor != nil
        return result
    }
}

/// Produces a privacy-minimized, referentially closed archive for a requested
/// export scope. Partial exports deliberately omit mixed-participant
/// interactions, raw source bodies, saved views, merge-recovery payloads, and
/// unrelated owned-profile snapshots.
public struct NotebookArchiveSlicer: Sendable {
    public init() {}

    public func slice(
        _ archive: NotebookArchive,
        to scope: NotebookArchiveExportScope
    ) throws -> NotebookArchive {
        switch scope {
        case .fullVault:
            return archive
        case .selfProfilesOnly:
            return NotebookArchive(
                schemaVersion: archive.schemaVersion,
                exportedAt: archive.exportedAt,
                people: [],
                interactions: [],
                canonical: CanonicalArchivePayload(),
                ownedProfileSnapshots: archive.ownedProfileSnapshots ?? []
            )
        case .selectedPeople(let selectedIDs):
            let availableIDs = Set(archive.people.map(\.id))
            if let missing = selectedIDs.subtracting(availableIDs).first {
                throw NotebookArchiveSlicingError.selectedPersonMissing(missing)
            }
            return selectedPeopleArchive(archive, selectedIDs: selectedIDs)
        }
    }

    private func selectedPeopleArchive(
        _ archive: NotebookArchive,
        selectedIDs: Set<UUID>
    ) -> NotebookArchive {
        let people = archive.people.filter { selectedIDs.contains($0.id) }
        let interactions = archive.interactions.filter { interaction in
            let participants = Set(
                [interaction.personID].compactMap { $0 }
                    + (interaction.additionalParticipantIDs ?? [])
            )
            return !participants.isEmpty
                && participants.isSubset(of: selectedIDs)
                && !participants.isDisjoint(with: selectedIDs)
        }
        let interactionIDs = Set(interactions.map(\.id))
        let payload = selectedCanonicalPayload(
            archive.canonical ?? CanonicalArchivePayload(),
            selectedPersonIDs: selectedIDs,
            selectedInteractionIDs: interactionIDs,
            interactionEvidenceIDs: Set(interactions.flatMap { $0.sourceEvidenceIDs ?? [] })
        )
        return NotebookArchive(
            schemaVersion: archive.schemaVersion,
            exportedAt: archive.exportedAt,
            people: people,
            interactions: interactions,
            canonical: payload,
            ownedProfileSnapshots: [],
            preservedExtensions: nil
        )
    }

    private func selectedCanonicalPayload(
        _ payload: CanonicalArchivePayload,
        selectedPersonIDs: Set<UUID>,
        selectedInteractionIDs: Set<UUID>,
        interactionEvidenceIDs: Set<UUID>
    ) -> CanonicalArchivePayload {
        let memberships = payload.memberships.filter { selectedPersonIDs.contains($0.personID) }
        let membershipIDs = Set(memberships.map(\.id))
        let assignments = payload.cohortAssignments.filter { membershipIDs.contains($0.membershipEpisodeID) }
        let roleAssignments = payload.roleAssignments.filter { membershipIDs.contains($0.membershipEpisodeID) }
        let education = payload.education.filter { selectedPersonIDs.contains($0.personID) }
        let portraits = (payload.portraitMedia ?? []).filter { selectedPersonIDs.contains($0.personID) }
        let portraitIDs = Set(portraits.map(\.id))

        let allAssertionByID = Dictionary(
            payload.assertions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var assertions = payload.assertions.filter { assertion in
            guard selectedPersonIDs.contains(assertion.subjectID) else { return false }
            switch assertion.value {
            case .personReference(let id): return selectedPersonIDs.contains(id)
            case .mediaReference(let id): return portraitIDs.contains(id)
            default: return true
            }
        }
        // Never leave a supersession reference dangling in a partial export.
        var changed = true
        while changed {
            let IDs = Set(assertions.map(\.id))
            let filtered = assertions.filter { assertion in
                guard let priorID = assertion.supersedesID,
                      allAssertionByID[priorID] != nil else { return true }
                return IDs.contains(priorID)
            }
            changed = filtered.count != assertions.count
            assertions = filtered
        }
        let assertionIDs = Set(assertions.map(\.id))

        let commitments = payload.commitments.filter { commitment in
            let peopleAreSafe = Set(commitment.personIDs).isSubset(of: selectedPersonIDs)
            let hasScopedAnchor = !Set(commitment.personIDs).isDisjoint(with: selectedPersonIDs)
                || commitment.interactionID.map(selectedInteractionIDs.contains) == true
            guard peopleAreSafe, hasScopedAnchor else { return false }
            if let interactionID = commitment.interactionID,
               !selectedInteractionIDs.contains(interactionID) { return false }
            if let assertionID = commitment.sourceAssertionID,
               !assertionIDs.contains(assertionID) { return false }
            switch commitment.owner {
            case .person(let id): return selectedPersonIDs.contains(id)
            case .shared(let IDs): return Set(IDs).isSubset(of: selectedPersonIDs)
            case .notebookOwner, .unspecified: return true
            }
        }
        let commitmentIDs = Set(commitments.map(\.id))

        let assertionContextIDs = Set(assertions.compactMap { assertion -> UUID? in
            if case .contextReference(let id) = assertion.value { return id }
            return nil
        })
        var contextIDs = Set(memberships.map(\.contextID))
            .union(education.map(\.institutionContextID))
            .union(assertionContextIDs)

        let contextByID = Dictionary(
            payload.contexts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var addedParent = true
        while addedParent {
            addedParent = false
            for contextID in Array(contextIDs) {
                if let parentID = contextByID[contextID]?.parentContextID {
                    addedParent = contextIDs.insert(parentID).inserted || addedParent
                }
            }
        }

        let cohortIDs = Set(assignments.map(\.cohortID))
        let cohorts = payload.cohorts.filter { cohortIDs.contains($0.id) }
        let schemeIDs = Set(cohorts.map(\.schemeID))
        let schemes = payload.cohortSchemes.filter { schemeIDs.contains($0.id) }
        contextIDs.formUnion(schemes.map(\.contextID))

        let roleDefinitionIDs = Set(roleAssignments.compactMap(\.roleDefinitionID))
        let roleDefinitions = payload.roleDefinitions.filter { roleDefinitionIDs.contains($0.id) }
        contextIDs.formUnion(roleDefinitions.map(\.contextID))

        // Context parents introduced by a scheme or role also need closure.
        addedParent = true
        while addedParent {
            addedParent = false
            for contextID in Array(contextIDs) {
                if let parentID = contextByID[contextID]?.parentContextID {
                    addedParent = contextIDs.insert(parentID).inserted || addedParent
                }
            }
        }
        let contexts = payload.contexts.filter { contextIDs.contains($0.id) }

        let selectedEvidenceIDs = Set(assertions.flatMap(\.evidenceIDs)).union(interactionEvidenceIDs)
        let evidence = payload.evidence.filter { selectedEvidenceIDs.contains($0.id) }
        let unitIDs = Set(evidence.map(\.unitID))
        let artifactUnits = (payload.artifactUnits ?? []).filter { unitIDs.contains($0.id) }
        let sourceIDs = Set(assertions.compactMap(\.sourceID)).union(artifactUnits.map(\.sourceID))
        let sources = payload.sources.compactMap { source -> SourceArtifact? in
            guard sourceIDs.contains(source.id) else { return nil }
            var sanitized = source
            if let mediaID = sanitized.mediaID, !portraitIDs.contains(mediaID) {
                sanitized.mediaID = nil
            }
            return sanitized
        }

        let reviews = payload.textImportReviews.compactMap { review -> TextImportReview? in
            guard sourceIDs.contains(review.source.id) else { return nil }
            var sanitized = review
            let selectedCandidates = review.candidates.compactMap { candidate -> TextImportCandidate? in
                var candidate = candidate
                candidate.assertions = candidate.assertions.filter { assertionIDs.contains($0.id) }
                guard selectedPersonIDs.contains(candidate.id) || !candidate.assertions.isEmpty else {
                    return nil
                }
                candidate.evidenceIDs = candidate.evidenceIDs.filter(selectedEvidenceIDs.contains)
                candidate.possibleDuplicateCandidateIDs = candidate.possibleDuplicateCandidateIDs
                    .filter(selectedPersonIDs.contains)
                return candidate
            }
            sanitized.candidates = selectedCandidates
            sanitized.source.text = ""
            sanitized.source.retentionPolicy = .evidenceExcerptsOnly
            sanitized.evidence = review.evidence.filter { selectedEvidenceIDs.contains($0.id) }
            let reviewEvidenceIDs = Set(sanitized.evidence.map(\.id))
            sanitized.safetyFindings = review.safetyFindings.filter {
                reviewEvidenceIDs.contains($0.evidenceID)
            }
            return sanitized
        }

        let reminders = payload.reminders.filter { reminder in
            switch reminder.subject {
            case .person(let id): selectedPersonIDs.contains(id)
            case .context(let id): contextIDs.contains(id)
            case .interaction(let id): selectedInteractionIDs.contains(id)
            case .assertion(let id): assertionIDs.contains(id)
            case .commitment(let id): commitmentIDs.contains(id)
            }
        }
        let predicateIDs = Set(assertions.map(\.predicateID))
        let definitions = payload.attributeDefinitions.filter { predicateIDs.contains($0.predicateID) }
        let mergeEvents = payload.personMergeEvents.filter {
            selectedPersonIDs.contains($0.sourcePersonBeforeMerge.id)
                && selectedPersonIDs.contains($0.destinationPersonBeforeMerge.id)
        }

        return CanonicalArchivePayload(
            contexts: contexts,
            cohortSchemes: schemes,
            cohorts: cohorts,
            memberships: memberships,
            cohortAssignments: assignments,
            roleDefinitions: roleDefinitions,
            roleAssignments: roleAssignments,
            education: education,
            assertions: assertions,
            sources: sources,
            artifactUnits: artifactUnits,
            portraitMedia: portraits,
            evidence: evidence,
            reminders: reminders,
            commitments: commitments,
            savedViews: [],
            attributeDefinitions: definitions,
            textImportReviews: reviews,
            personMergeEvents: mergeEvents
        )
    }
}
