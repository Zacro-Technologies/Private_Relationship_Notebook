import Foundation

/// Portable structured records carried by the human-readable JSON export. The container is
/// optional in `NotebookArchive`, so schema-1 exports from early builds remain readable.
public struct CanonicalArchivePayload: Codable, Sendable {
    public var contexts: [Context]
    public var cohortSchemes: [CohortScheme]
    public var cohorts: [Cohort]
    public var memberships: [MembershipEpisode]
    public var cohortAssignments: [CohortAssignment]
    public var roleDefinitions: [RoleDefinition]
    public var roleAssignments: [RoleAssignment]
    public var education: [EducationEnrollment]
    public var assertions: [AssertionEnvelope]
    public var sources: [SourceArtifact]
    /// Optional for backward compatibility with archives created before source units were exported.
    public var artifactUnits: [ArtifactUnit]?
    /// Metadata for sanitized portraits. Private CloudKit mirroring carries the
    /// binary payload separately; portable binary media travels in explicit
    /// media archives, never as base64 inside ordinary JSON.
    public var portraitMedia: [PortraitMediaAsset]?
    public var evidence: [EvidenceSpan]
    public var reminders: [Reminder]
    public var commitments: [Commitment]
    public var savedViews: [SavedView]
    public var attributeDefinitions: [AttributeDefinition]
    public var textImportReviews: [TextImportReview]
    public var personMergeEvents: [PersonMergeEvent]

    public init(
        contexts: [Context] = [],
        cohortSchemes: [CohortScheme] = [],
        cohorts: [Cohort] = [],
        memberships: [MembershipEpisode] = [],
        cohortAssignments: [CohortAssignment] = [],
        roleDefinitions: [RoleDefinition] = [],
        roleAssignments: [RoleAssignment] = [],
        education: [EducationEnrollment] = [],
        assertions: [AssertionEnvelope] = [],
        sources: [SourceArtifact] = [],
        artifactUnits: [ArtifactUnit]? = [],
        portraitMedia: [PortraitMediaAsset]? = [],
        evidence: [EvidenceSpan] = [],
        reminders: [Reminder] = [],
        commitments: [Commitment] = [],
        savedViews: [SavedView] = [],
        attributeDefinitions: [AttributeDefinition] = [],
        textImportReviews: [TextImportReview] = [],
        personMergeEvents: [PersonMergeEvent] = []
    ) {
        self.contexts = contexts
        self.cohortSchemes = cohortSchemes
        self.cohorts = cohorts
        self.memberships = memberships
        self.cohortAssignments = cohortAssignments
        self.roleDefinitions = roleDefinitions
        self.roleAssignments = roleAssignments
        self.education = education
        self.assertions = assertions
        self.sources = sources
        self.artifactUnits = artifactUnits
        self.portraitMedia = portraitMedia
        self.evidence = evidence
        self.reminders = reminders
        self.commitments = commitments
        self.savedViews = savedViews
        self.attributeDefinitions = attributeDefinitions
        self.textImportReviews = textImportReviews
        self.personMergeEvents = personMergeEvents
    }
}

public extension CanonicalArchivePayload {
    /// Returns only the structured rows that the bounded import planner classified as new.
    /// Same-ID conflicts and unchanged rows are deliberately absent so an import transaction
    /// cannot overwrite an existing canonical record behind the preview.
    func selectingNewRecords(
        identifiedBy identities: Set<ArchiveStructuredRecordIdentity>
    ) -> CanonicalArchivePayload {
        func includes(_ family: ArchiveStructuredRecordFamily, _ id: UUID) -> Bool {
            identities.contains(.init(family: family, id: id))
        }

        return CanonicalArchivePayload(
            contexts: contexts.filter { includes(.context, $0.id) },
            cohortSchemes: cohortSchemes.filter { includes(.cohortScheme, $0.id) },
            cohorts: cohorts.filter { includes(.cohort, $0.id) },
            memberships: memberships.filter { includes(.membership, $0.id) },
            cohortAssignments: cohortAssignments.filter { includes(.cohortAssignment, $0.id) },
            roleDefinitions: roleDefinitions.filter { includes(.roleDefinition, $0.id) },
            roleAssignments: roleAssignments.filter { includes(.roleAssignment, $0.id) },
            education: education.filter { includes(.education, $0.id) },
            assertions: assertions.filter { includes(.assertion, $0.id) },
            sources: sources.filter { includes(.source, $0.id) },
            artifactUnits: (artifactUnits ?? []).filter { includes(.artifactUnit, $0.id) },
            // The import planner emits portrait identities only after package bytes are verified.
            // Ordinary JSON inspection therefore continues to select no portrait metadata.
            portraitMedia: (portraitMedia ?? []).filter { includes(.portraitMedia, $0.id) },
            evidence: evidence.filter { includes(.evidence, $0.id) },
            reminders: reminders.filter { includes(.reminder, $0.id) },
            commitments: commitments.filter { includes(.commitment, $0.id) },
            savedViews: savedViews.filter { includes(.savedView, $0.id) },
            attributeDefinitions: attributeDefinitions.filter { includes(.attributeDefinition, $0.id) },
            textImportReviews: textImportReviews.filter { includes(.textImportReview, $0.source.id) },
            personMergeEvents: personMergeEvents.filter { includes(.personMergeEvent, $0.id) }
        )
    }
}
