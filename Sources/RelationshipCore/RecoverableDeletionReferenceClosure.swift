import Foundation

/// Reference-only view of recoverable soft-deleted rows. It lets the normal
/// archive planner validate active records that still point at Recently
/// Deleted values without making those values active or exposing them in the
/// human-readable archive.
public struct RecoverableDeletionReferenceClosure: Sendable {
    public var personIDs: Set<UUID>
    public var interactionIDs: Set<UUID>
    public var canonical: CanonicalArchivePayload

    public init(
        destination: RecoverableDeletionCheckpoint,
        sourcePlan: RecoverableDeletionImportPlan?
    ) {
        let acceptedSourceKeys = Set(sourcePlan?.rowsToCreate.map(\.key) ?? [])
            .union(sourcePlan?.unchangedKeys ?? [])
        let acceptedSourceRows = (sourcePlan?.sourceRows ?? []).filter {
            acceptedSourceKeys.contains($0.key)
        }
        self.init(
            destination: destination,
            acceptedSourceRows: acceptedSourceRows
        )
    }

    public init(
        destination: RecoverableDeletionCheckpoint,
        acceptedSourceRows: [RecoverableDeletionRow]
    ) {
        var rowsByKey = Dictionary(uniqueKeysWithValues: destination.rows.map {
            ($0.key, $0)
        })
        for row in acceptedSourceRows {
            rowsByKey[row.key] = row
        }

        let rows = Array(rowsByKey.values)
        personIDs = Set(rows.lazy
            .filter { $0.key.entity == .person }
            .map(\.key.id))
        interactionIDs = Set(rows.lazy
            .filter { $0.key.entity == .interaction }
            .map(\.key.id))

        var payload = CanonicalArchivePayload()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for row in rows where row.key.entity == .canonicalRecord {
            guard case .data(let data) = row.attributes["payload"] else { continue }
            switch row.key.kind {
            case "context":
                if let value = try? decoder.decode(Context.self, from: data) {
                    payload.contexts.append(value)
                }
            case "cohortScheme":
                if let value = try? decoder.decode(CohortScheme.self, from: data) {
                    payload.cohortSchemes.append(value)
                }
            case "cohort":
                if let value = try? decoder.decode(Cohort.self, from: data) {
                    payload.cohorts.append(value)
                }
            case "membership":
                if let value = try? decoder.decode(MembershipEpisode.self, from: data) {
                    payload.memberships.append(value)
                }
            case "cohortAssignment":
                if let value = try? decoder.decode(CohortAssignment.self, from: data) {
                    payload.cohortAssignments.append(value)
                }
            case "roleDefinition":
                if let value = try? decoder.decode(RoleDefinition.self, from: data) {
                    payload.roleDefinitions.append(value)
                }
            case "roleAssignment":
                if let value = try? decoder.decode(RoleAssignment.self, from: data) {
                    payload.roleAssignments.append(value)
                }
            case "education":
                if let value = try? decoder.decode(EducationEnrollment.self, from: data) {
                    payload.education.append(value)
                }
            case "assertion":
                if let value = try? decoder.decode(AssertionEnvelope.self, from: data) {
                    payload.assertions.append(value)
                }
            case "source":
                if let value = try? decoder.decode(SourceArtifact.self, from: data) {
                    payload.sources.append(value)
                }
            case "artifactUnit":
                if let value = try? decoder.decode(ArtifactUnit.self, from: data) {
                    payload.artifactUnits?.append(value)
                }
            case "portraitMedia":
                if let value = try? decoder.decode(PortraitMediaAsset.self, from: data) {
                    payload.portraitMedia?.append(value)
                }
            case "evidence":
                if let value = try? decoder.decode(EvidenceSpan.self, from: data) {
                    payload.evidence.append(value)
                }
            case "reminder":
                if let value = try? decoder.decode(Reminder.self, from: data) {
                    payload.reminders.append(value)
                }
            case "commitment":
                if let value = try? decoder.decode(Commitment.self, from: data) {
                    payload.commitments.append(value)
                }
            case "savedView":
                if let value = try? decoder.decode(SavedView.self, from: data) {
                    payload.savedViews.append(value)
                }
            case "attributeDefinition":
                if let value = try? decoder.decode(AttributeDefinition.self, from: data) {
                    payload.attributeDefinitions.append(value)
                }
            case "textImportReview":
                if let value = try? decoder.decode(TextImportReview.self, from: data) {
                    payload.textImportReviews.append(value)
                }
            case "personMergeEvent":
                if let value = try? decoder.decode(PersonMergeEvent.self, from: data) {
                    payload.personMergeEvents.append(value)
                }
            default:
                continue
            }
        }
        canonical = payload
    }

    public func merging(
        into active: CanonicalArchivePayload?
    ) -> CanonicalArchivePayload {
        let active = active ?? CanonicalArchivePayload()
        return CanonicalArchivePayload(
            contexts: active.contexts + canonical.contexts,
            cohortSchemes: active.cohortSchemes + canonical.cohortSchemes,
            cohorts: active.cohorts + canonical.cohorts,
            memberships: active.memberships + canonical.memberships,
            cohortAssignments: active.cohortAssignments + canonical.cohortAssignments,
            roleDefinitions: active.roleDefinitions + canonical.roleDefinitions,
            roleAssignments: active.roleAssignments + canonical.roleAssignments,
            education: active.education + canonical.education,
            assertions: active.assertions + canonical.assertions,
            sources: active.sources + canonical.sources,
            artifactUnits: (active.artifactUnits ?? []) + (canonical.artifactUnits ?? []),
            portraitMedia: (active.portraitMedia ?? []) + (canonical.portraitMedia ?? []),
            evidence: active.evidence + canonical.evidence,
            reminders: active.reminders + canonical.reminders,
            commitments: active.commitments + canonical.commitments,
            savedViews: active.savedViews + canonical.savedViews,
            attributeDefinitions: active.attributeDefinitions + canonical.attributeDefinitions,
            textImportReviews: active.textImportReviews + canonical.textImportReviews,
            personMergeEvents: active.personMergeEvents + canonical.personMergeEvents
        )
    }
}
