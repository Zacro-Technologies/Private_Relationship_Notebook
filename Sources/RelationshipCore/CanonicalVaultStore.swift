import Combine
import CoreData
import Foundation

public enum ProfileSnapshotPersistenceError: Error, Equatable, Sendable {
    case cardVersionIdentifierConflict(UUID)
}

public enum CanonicalFactSaveError: LocalizedError, Equatable, Sendable {
    case subjectIsNotActive(UUID)

    public var errorDescription: String? {
        switch self {
        case .subjectIsNotActive:
            String(localized: "This fact was not saved because the person is missing, deleted, or has been merged.")
        }
    }
}

public enum CanonicalDefinitionSaveError: LocalizedError, Equatable, Sendable {
    case duplicateFieldName(String)
    case duplicatePredicateID(String)
    case invalidOptionOwnership
    case duplicateOptionLabel(String)
    case duplicateSavedViewName(String)
    case invalidDefinition(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateFieldName(let name):
            String(localized: "A custom field named “\(name)” already exists. Choose a distinct label.")
        case .duplicatePredicateID:
            String(localized: "This custom field conflicts with an existing stable field identifier.")
        case .invalidOptionOwnership:
            String(localized: "One or more choices belong to a different custom field.")
        case .duplicateOptionLabel(let label):
            String(localized: "The choice “\(label)” appears more than once.")
        case .duplicateSavedViewName(let name):
            String(localized: "A saved view named “\(name)” already exists.")
        case .invalidDefinition(let reason):
            reason
        }
    }
}

@MainActor
public final class CanonicalVaultStore: ObservableObject {
    @Published public private(set) var contexts: [Context] = []
    @Published public private(set) var cohortSchemes: [CohortScheme] = []
    @Published public private(set) var cohorts: [Cohort] = []
    @Published public private(set) var memberships: [MembershipEpisode] = []
    @Published public private(set) var cohortAssignments: [CohortAssignment] = []
    @Published public private(set) var roleDefinitions: [RoleDefinition] = []
    @Published public private(set) var roleAssignments: [RoleAssignment] = []
    @Published public private(set) var education: [EducationEnrollment] = []
    @Published public private(set) var assertions: [AssertionEnvelope] = []
    @Published public private(set) var sources: [SourceArtifact] = []
    @Published public private(set) var artifactUnits: [ArtifactUnit] = []
    @Published public private(set) var portraitMedia: [PortraitMediaAsset] = []
    @Published public private(set) var evidence: [EvidenceSpan] = []
    @Published public private(set) var reminders: [Reminder] = []
    @Published public private(set) var commitments: [Commitment] = []
    @Published public private(set) var savedViews: [SavedView] = []
    @Published public private(set) var attributeDefinitions: [AttributeDefinition] = []
    @Published public private(set) var textImportReviews: [TextImportReview] = []
    @Published public private(set) var profileSnapshots: [ProfileCardSnapshotPayload] = []
    @Published public private(set) var profileSnapshotStates: [ProfileSnapshotLocalState] = []
    @Published public private(set) var personMergeEvents: [PersonMergeEvent] = []
    @Published public private(set) var recentlyDeletedRecords: [DeletedRecordReference] = []
    @Published public private(set) var revision: UInt64 = 0
    @Published public var lastError: String?

    public let records: RecordRepository
    public let mediaPayloads: MediaPayloadRepository
    private let persistence: PersistenceController

    public init(persistence: PersistenceController) {
        self.persistence = persistence
        records = RecordRepository(persistence: persistence)
        mediaPayloads = MediaPayloadRepository(persistence: persistence)
        reload()
    }

    /// A coherent value projection for offline features such as saved-view
    /// nudge pools. This never reads media bytes or crosses a network boundary.
    public var archivePayload: CanonicalArchivePayload {
        CanonicalArchivePayload(
            contexts: contexts,
            cohortSchemes: cohortSchemes,
            cohorts: cohorts,
            memberships: memberships,
            cohortAssignments: cohortAssignments,
            roleDefinitions: roleDefinitions,
            roleAssignments: roleAssignments,
            education: education,
            assertions: assertions,
            sources: sources,
            artifactUnits: artifactUnits,
            portraitMedia: portraitMedia,
            evidence: evidence,
            reminders: reminders,
            commitments: commitments,
            savedViews: savedViews,
            attributeDefinitions: attributeDefinitions,
            textImportReviews: textImportReviews,
            personMergeEvents: personMergeEvents
        )
    }

    public var pendingImportReviewCount: Int {
        textImportReviews.filter(\.isResumable).count
    }

    public var activeSavedViews: [SavedView] {
        savedViews.filter { !$0.isArchived }
    }

    public var activeAttributeDefinitions: [AttributeDefinition] {
        attributeDefinitions.filter { $0.archivedAt == nil }
    }

    public func reload() {
        do {
            try reloadSnapshot()
        } catch {
            lastError = String(localized: "Some structured notebook records could not be loaded. Existing stored data was not changed.")
        }
    }

    private func reloadSnapshot() throws {
        _ = try SynchronizedDeletionMarkerRepository(persistence: persistence).enforce()

        let loadedContexts = try values(Context.self, "context")
        let loadedCohortSchemes = try values(CohortScheme.self, "cohortScheme")
        let loadedCohorts = try values(Cohort.self, "cohort")
        let loadedMemberships = try values(MembershipEpisode.self, "membership")
        let loadedCohortAssignments = try values(CohortAssignment.self, "cohortAssignment")
        let loadedRoleDefinitions = try values(RoleDefinition.self, "roleDefinition")
        let loadedRoleAssignments = try values(RoleAssignment.self, "roleAssignment")
        let loadedEducation = try values(EducationEnrollment.self, "education")
        let loadedAssertions = try values(AssertionEnvelope.self, "assertion")
        let loadedSources = try values(SourceArtifact.self, "source")
        let loadedArtifactUnits = try values(ArtifactUnit.self, "artifactUnit")
        let loadedPortraitMedia = try values(PortraitMediaAsset.self, "portraitMedia")
        let loadedEvidence = try values(EvidenceSpan.self, "evidence")
        let loadedReminders = try values(Reminder.self, "reminder")
        let loadedCommitments = try values(Commitment.self, "commitment")
        let loadedSavedViews = try values(SavedView.self, "savedView")
        let loadedAttributeDefinitions = try values(AttributeDefinition.self, "attributeDefinition")
        let loadedTextImportReviews = try values(TextImportReview.self, "textImportReview")
        let loadedPersonMergeEvents = try values(PersonMergeEvent.self, "personMergeEvent")
        let loadedProfileSnapshots = try records.fetch(
            ProfileCardSnapshotPayload.self,
            kind: "profileSnapshot",
            from: .ownedProfiles
        ).map(\.value)
        let loadedProfileSnapshotStates = try records.fetch(
            ProfileSnapshotLocalState.self,
            kind: "profileSnapshotState",
            from: .ownedProfiles
        ).map(\.value)
        let loadedRecentlyDeletedRecords = try (
            records.deletedRecords() + records.deletedRecords(in: .ownedProfiles)
        ).sorted { $0.deletedAt > $1.deletedAt }

        // Publish a coherent snapshot only after every record family decodes successfully.
        contexts = loadedContexts
        cohortSchemes = loadedCohortSchemes
        cohorts = loadedCohorts
        memberships = loadedMemberships
        cohortAssignments = loadedCohortAssignments
        roleDefinitions = loadedRoleDefinitions
        roleAssignments = loadedRoleAssignments
        education = loadedEducation
        assertions = loadedAssertions
        sources = loadedSources
        artifactUnits = loadedArtifactUnits
        portraitMedia = loadedPortraitMedia
        evidence = loadedEvidence
        reminders = loadedReminders
        commitments = loadedCommitments
        savedViews = loadedSavedViews.sorted(by: Self.savedViewOrder)
        attributeDefinitions = loadedAttributeDefinitions.sorted(by: Self.attributeDefinitionOrder)
        textImportReviews = loadedTextImportReviews
        personMergeEvents = loadedPersonMergeEvents
        profileSnapshots = loadedProfileSnapshots
        profileSnapshotStates = loadedProfileSnapshotStates
        recentlyDeletedRecords = loadedRecentlyDeletedRecords
        revision &+= 1
        lastError = nil
    }

    /// Republishes a coherent value snapshot after CloudKit imports changes
    /// through another managed-object context.
    public func reloadAfterRemoteImport() {
        do {
            try reloadAfterRemoteImportOrThrow()
        } catch {
            lastError = String(localized: "Some structured notebook records could not be loaded. Existing stored data was not changed.")
        }
    }

    /// Throwing variant used by persistent-history checkpointing. A decode or
    /// fetch failure leaves the previous coherent snapshot and token intact.
    public func reloadAfterRemoteImportOrThrow() throws {
        records.refreshAfterRemoteImport()
        try reloadSnapshot()
    }

    /// Refreshes value snapshots and materializes synchronized portrait bytes
    /// into the supplied protected local cache after a CloudKit import event.
    @discardableResult
    public func reloadAfterRemoteImport(
        materializingInto fileStore: PortraitMediaFileStore
    ) async -> PortraitCacheReconciliationResult {
        reloadAfterRemoteImport()
        return await reconcilePortraitCache(using: fileStore)
    }

    @discardableResult
    public func reloadAfterRemoteImportOrThrow(
        materializingInto fileStore: PortraitMediaFileStore
    ) async throws -> PortraitCacheReconciliationResult {
        try reloadAfterRemoteImportOrThrow()
        return await reconcilePortraitCache(using: fileStore)
    }

    public func save(_ value: Context) { save(value, id: value.id, kind: "context") }
    public func save(_ value: CohortScheme) { save(value, id: value.id, kind: "cohortScheme") }
    public func save(_ value: Cohort) { save(value, id: value.id, kind: "cohort") }
    public func save(_ value: MembershipEpisode) { save(value, id: value.id, kind: "membership") }
    public func save(_ value: CohortAssignment) { save(value, id: value.id, kind: "cohortAssignment") }
    public func save(_ value: RoleDefinition) { save(value, id: value.id, kind: "roleDefinition") }
    public func save(_ value: RoleAssignment) { save(value, id: value.id, kind: "roleAssignment") }
    public func save(_ value: EducationEnrollment) { save(value, id: value.id, kind: "education") }
    public func save(_ value: AssertionEnvelope) {
        do {
            try saveFact(value)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "This structured record could not be saved locally.")
        }
    }
    public func save(_ value: SourceArtifact) { save(value, id: value.id, kind: "source") }
    public func save(_ value: ArtifactUnit) { save(value, id: value.id, kind: "artifactUnit") }
    public func save(_ value: PortraitMediaAsset) { save(value, id: value.id, kind: "portraitMedia") }
    public func save(_ value: EvidenceSpan) { save(value, id: value.id, kind: "evidence") }
    public func save(_ value: Reminder) { save(value, id: value.id, kind: "reminder") }
    public func save(_ value: Commitment) { save(value, id: value.id, kind: "commitment") }

    /// Persists a reminder and only returns after the published vault snapshot
    /// reflects the write. Editors use this variant so a failed write never
    /// looks like a successful, dismissed save.
    public func saveReminder(_ value: Reminder) throws {
        try savePlanningRecord(
            value,
            id: value.id,
            kind: "reminder",
            failureMessage: String(localized: "The reminder could not be saved locally. Your changes are still open.")
        )
    }

    /// Persists a commitment and only returns after the published vault
    /// snapshot reflects the write.
    public func saveCommitment(_ value: Commitment) throws {
        try savePlanningRecord(
            value,
            id: value.id,
            kind: "commitment",
            failureMessage: String(localized: "The commitment could not be saved locally. Your changes are still open.")
        )
    }
    public func save(_ value: SavedView) {
        do { try saveSavedView(value) }
        catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
    public func save(_ value: AttributeDefinition) {
        do { try saveAttributeDefinition(value) }
        catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
    public func save(_ value: TextImportReview) { save(value, id: value.source.id, kind: "textImportReview") }
    public func save(_ value: PersonMergeEvent) { save(value, id: value.id, kind: "personMergeEvent") }

    public func clearRetainedOriginalSource(reviewID: UUID) {
        guard var review = textImportReviews.first(where: { $0.id == reviewID }) else { return }
        review.workflow?.retainedSource = nil
        if review.workflow?.sourceRetention == .keepOriginal {
            review.workflow?.sourceRetention = .evidenceExcerptsOnly
            review.source.retentionPolicy = .evidenceExcerptsOnly
        }
        save(review)
    }

    public func clearExtractedSourceText(reviewID: UUID, keepEvidenceExcerpts: Bool = true) {
        guard var review = textImportReviews.first(where: { $0.id == reviewID }) else { return }
        review.source.text = ""
        if var workflow = review.workflow {
            workflow.sourceUnits = workflow.sourceUnits.map { unit in
                var unit = unit
                unit.text = ""
                unit.regions = []
                unit.ocrConfidence = nil
                return unit
            }
            workflow.retainedSource = nil
            workflow.sourceRetention = keepEvidenceExcerpts
                ? .evidenceExcerptsOnly
                : .discardAfterReview
            review.workflow = workflow
        }
        review.source.retentionPolicy = keepEvidenceExcerpts
            ? .evidenceExcerptsOnly
            : .discardAfterReview
        if !keepEvidenceExcerpts {
            review.evidence = review.evidence.map { span in
                var span = span
                span.excerpt = ""
                return span
            }
        }
        save(review)
    }

    /// Keeps an interaction's follow-up and commitment as first-class,
    /// independently editable planning records. Reconciliation is idempotent:
    /// editing the interaction updates its linked records and removing either
    /// field moves the stale record to Recently Deleted.
    @discardableResult
    public func reconcilePlanning(for interaction: Interaction, at date: Date = .now) -> Bool {
        let projection = InteractionPlanningProjection.make(
            for: interaction,
            existingReminders: reminders,
            existingCommitments: commitments,
            now: date
        )
        do {
            if let reminder = projection.reminder {
                try records.upsert(reminder, id: reminder.id, kind: "reminder")
            }
            if let commitment = projection.commitment {
                try records.upsert(commitment, id: commitment.id, kind: "commitment")
            }
            for id in projection.reminderIDsToDelete {
                try records.softDelete(id: id, kind: "reminder", now: date)
            }
            for id in projection.commitmentIDsToDelete {
                try records.softDelete(id: id, kind: "commitment", now: date)
            }
            try reloadSnapshot()
            return true
        } catch {
            lastError = String(localized: "The interaction was saved, but its reminder or commitment could not be updated. Review Planning before relying on it.")
            reload()
            return false
        }
    }

    /// Validates identity state, secret content, and custom-field privacy at
    /// the last model boundary before a canonical fact is persisted.
    public func saveFact(_ value: AssertionEnvelope) throws {
        try validateFactWrite(value)
        try records.upsert(value, id: value.id, kind: "assertion")
        try reloadSnapshot()
    }

    public func validateFactWrite(
        _ value: AssertionEnvelope,
        definition explicitDefinition: AttributeDefinition? = nil
    ) throws {
        try requireActiveFactSubject(value.subjectID)
        let definition = explicitDefinition ?? attributeDefinitions.first {
            $0.predicateID == value.predicateID
        }
        try CanonicalFactWritePolicy.validate(value, definition: definition)
    }

    /// Throwing form used by compound editors that must not continue when the
    /// authoritative field definition itself failed to persist.
    public func saveAttributeDefinition(_ value: AttributeDefinition) throws {
        try validateAttributeDefinition(value)
        try records.upsert(value, id: value.id, kind: "attributeDefinition")
        try reloadSnapshot()
    }

    public func saveSavedView(_ value: SavedView) throws {
        let normalizedName = Self.normalizedIdentity(value.name)
        if savedViews.contains(where: {
            $0.id != value.id && !$0.isArchived &&
                Self.normalizedIdentity($0.name) == normalizedName
        }) {
            throw CanonicalDefinitionSaveError.duplicateSavedViewName(value.name)
        }
        try records.upsert(value, id: value.id, kind: "savedView")
        try reloadSnapshot()
    }

    public func reorderSavedViews(_ orderedIDs: [UUID]) throws {
        let order = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        let updated = savedViews.map { original -> SavedView in
            var value = original
            if let index = order[value.id] { value.displayOrder = index }
            value.modifiedAt = .now
            return value
        }
        try records.upsertAll(updated, kind: "savedView")
        try reloadSnapshot()
    }

    public func reorderAttributeDefinitions(_ orderedIDs: [UUID]) throws {
        let order = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        let updated = attributeDefinitions.map { original -> AttributeDefinition in
            var value = original
            if let index = order[value.id] { value.displayOrder = index }
            value.modifiedAt = .now
            return value
        }
        try records.upsertAll(updated, kind: "attributeDefinition")
        try reloadSnapshot()
    }

    private func validateAttributeDefinition(_ value: AttributeDefinition) throws {
        let label = value.labels.fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            throw CanonicalDefinitionSaveError.invalidDefinition(
                String(localized: "A custom field needs a visible name.")
            )
        }
        if value.cardinality == .multiple && value.valueKind != .multiSelect ||
            value.cardinality == .single && value.valueKind == .multiSelect {
            throw CanonicalDefinitionSaveError.invalidDefinition(
                String(localized: "The field cardinality does not match its value type.")
            )
        }
        if let minimum = value.validation.minimumTextLength,
           let maximum = value.validation.maximumTextLength,
           minimum > maximum {
            throw CanonicalDefinitionSaveError.invalidDefinition(
                String(localized: "Minimum text length cannot exceed maximum text length.")
            )
        }
        if let minimum = value.validation.minimumNumber,
           let maximum = value.validation.maximumNumber,
           minimum > maximum {
            throw CanonicalDefinitionSaveError.invalidDefinition(
                String(localized: "Minimum number cannot exceed maximum number.")
            )
        }
        if let pattern = value.validation.regularExpression, !pattern.isEmpty {
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch {
                throw CanonicalDefinitionSaveError.invalidDefinition(
                    String(localized: "The regular expression is not valid.")
                )
            }
        }
        let normalizedLabel = Self.normalizedIdentity(label)
        if attributeDefinitions.contains(where: {
            $0.id != value.id && $0.archivedAt == nil &&
                Self.normalizedIdentity($0.labels.fallback) == normalizedLabel
        }) {
            throw CanonicalDefinitionSaveError.duplicateFieldName(label)
        }
        if attributeDefinitions.contains(where: {
            $0.id != value.id && $0.predicateID == value.predicateID
        }) {
            throw CanonicalDefinitionSaveError.duplicatePredicateID(value.predicateID)
        }
        let options = value.options ?? []
        if (value.valueKind == .singleSelect || value.valueKind == .multiSelect) &&
            !options.contains(where: { $0.archivedAt == nil }) {
            throw CanonicalDefinitionSaveError.invalidDefinition(
                String(localized: "A selection field needs at least one active choice.")
            )
        }
        guard options.allSatisfy({ $0.definitionID == value.id }) else {
            throw CanonicalDefinitionSaveError.invalidOptionOwnership
        }
        var labels = Set<String>()
        for option in options where option.archivedAt == nil {
            let label = option.label.fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            guard labels.insert(Self.normalizedIdentity(label)).inserted else {
                throw CanonicalDefinitionSaveError.duplicateOptionLabel(label)
            }
        }
    }

    private static func normalizedIdentity(_ value: String) -> String {
        SearchNormalizer.normalize(value)
    }

    private static func savedViewOrder(_ lhs: SavedView, _ rhs: SavedView) -> Bool {
        let left = lhs.displayOrder ?? Int.max
        let right = rhs.displayOrder ?? Int.max
        if left != right { return left < right }
        return lhs.createdAt < rhs.createdAt
    }

    private static func attributeDefinitionOrder(
        _ lhs: AttributeDefinition,
        _ rhs: AttributeDefinition
    ) -> Bool {
        let left = lhs.displayOrder ?? Int.max
        let right = rhs.displayOrder ?? Int.max
        if left != right { return left < right }
        return lhs.createdAt < rhs.createdAt
    }

    public func saveSourceArtifact(_ value: SourceArtifact) throws {
        try records.upsert(value, id: value.id, kind: "source")
        try reloadSnapshot()
    }

    /// Saves portrait metadata and its sanitized binary payload as one
    /// synchronized Vault transaction.
    public func save(_ portrait: SanitizedPortrait) {
        do {
            try mediaPayloads.savePortrait(portrait)
            reload()
        } catch {
            lastError = String(localized: "This structured record could not be saved locally.")
        }
    }

    public func saveProfileSnapshot(_ value: ProfileCardSnapshotPayload) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let canonicalBytes = try encoder.encode(value)
            let validated = try ProfileCardSnapshotSerializer().deserialize(canonicalBytes)
            if let existing = try records.fetch(
                ProfileCardSnapshotPayload.self,
                kind: "profileSnapshot",
                from: .ownedProfiles
            ).first(where: { $0.id == validated.cardVersionID })?.value {
                guard existing == validated else {
                    throw ProfileSnapshotPersistenceError.cardVersionIdentifierConflict(
                        validated.cardVersionID
                    )
                }
                lastError = nil
                return
            }
            try records.upsert(
                validated,
                id: validated.cardVersionID,
                kind: "profileSnapshot",
                in: .ownedProfiles
            )
            reload()
        } catch {
            lastError = String(localized: "The profile-card version could not be saved locally.")
        }
    }

    public func archiveProfileSnapshot(_ value: ProfileCardSnapshotPayload) {
        updateProfileSnapshotState(value.cardVersionID) { $0.archivedAt = .now }
    }

    public func setProfileSnapshotRevoked(_ value: ProfileCardSnapshotPayload, revoked: Bool) {
        updateProfileSnapshotState(value.cardVersionID) {
            $0.isRevokedForFutureSharing = revoked
        }
    }

    public func state(forProfileSnapshotID id: UUID) -> ProfileSnapshotLocalState? {
        profileSnapshotStates.first { $0.cardVersionID == id }
    }

    private func updateProfileSnapshotState(
        _ id: UUID,
        mutation: (inout ProfileSnapshotLocalState) -> Void
    ) {
        do {
            var state = state(forProfileSnapshotID: id)
                ?? ProfileSnapshotLocalState(cardVersionID: id)
            mutation(&state)
            state.modifiedAt = .now
            try records.upsert(
                state,
                id: state.id,
                kind: "profileSnapshotState",
                in: .ownedProfiles
            )
            reload()
        } catch {
            lastError = String(localized: "The profile-card version status could not be updated.")
        }
    }

    /// Re-plans against the current Vault immediately before writing. This
    /// makes repeated imports no-ops and prevents a review screen from
    /// accidentally overwriting assertions that arrived while it was open.
    @discardableResult
    public func importReceivedProfileSnapshot(
        _ reviewedBundle: ReceivedProfileSnapshotImportBundle
    ) throws -> Bool {
        let currentBundle = try ReceivedProfileSnapshotImportPlanner().plan(
            exactPayloadBytes: reviewedBundle.exactPayloadBytes,
            selectedFieldIDs: reviewedBundle.selectedFieldIDs,
            subjectID: reviewedBundle.subjectID,
            existingAssertions: assertions,
            existingDefinitions: attributeDefinitions,
            existingSources: sources,
            originalFilename: reviewedBundle.originalFilename,
            retentionPolicy: reviewedBundle.retentionPolicy,
            importedAt: reviewedBundle.importedAt
        )
        guard currentBundle.hasChanges else { return false }

        try records.upsertReceivedProfileAtomically(
            source: currentBundle.sourceToCreate,
            assertions: currentBundle.assertionsToCreate,
            now: currentBundle.importedAt
        )
        try reloadSnapshot()
        return true
    }

    public func delete<Value: Identifiable>(_ value: Value, kind: String) where Value.ID == UUID {
        do {
            try records.softDelete(id: value.id, kind: kind)
            reload()
        } catch {
            lastError = String(localized: "The record could not be moved to Recently Deleted.")
        }
    }

    public func deleteReminder(_ value: Reminder) throws {
        try deletePlanningRecord(
            id: value.id,
            kind: "reminder",
            failureMessage: String(localized: "The reminder could not be moved to Recently Deleted.")
        )
    }

    public func deleteCommitment(_ value: Commitment) throws {
        try deletePlanningRecord(
            id: value.id,
            kind: "commitment",
            failureMessage: String(localized: "The commitment could not be moved to Recently Deleted.")
        )
    }

    public func restore(_ record: DeletedRecordReference) {
        do {
            try records.restore(
                id: record.recordID,
                kind: record.kind,
                in: record.store
            )
            reload()
        } catch {
            lastError = String(localized: "The record could not be restored from Recently Deleted.")
        }
    }

    /// Soft-deletes portrait metadata and synchronized bytes together.
    public func deletePortrait(_ asset: PortraitMediaAsset) {
        do {
            _ = try mediaPayloads.deletePortrait(asset)
            reload()
        } catch {
            lastError = String(localized: "The record could not be moved to Recently Deleted.")
        }
    }

    public func portraitData(
        for asset: PortraitMediaAsset,
        using fileStore: PortraitMediaFileStore
    ) async throws -> Data {
        try await mediaPayloads.materialize(asset, in: fileStore)
    }

    public func reconcilePortraitCache(
        using fileStore: PortraitMediaFileStore
    ) async -> PortraitCacheReconciliationResult {
        await mediaPayloads.reconcileCache(for: portraitMedia, in: fileStore)
    }

    public func contexts(for personID: UUID) -> [Context] {
        let IDs = Set(memberships(for: personID).map(\.contextID))
        return contexts.filter { IDs.contains($0.id) }
    }

    public func memberships(for personID: UUID) -> [MembershipEpisode] {
        let targetID = resolvedPersonID(personID)
        return memberships.filter { resolvedPersonID($0.personID) == targetID }
    }

    public func education(for personID: UUID) -> [EducationEnrollment] {
        let targetID = resolvedPersonID(personID)
        return education.filter { resolvedPersonID($0.personID) == targetID }
    }

    public func assertions(for personID: UUID) -> [AssertionEnvelope] {
        let targetID = resolvedPersonID(personID)
        return assertions.filter { resolvedPersonID($0.subjectID) == targetID }
    }

    /// Reconciles the quick person editor with the canonical context graph.
    /// Free-text labels are matched across localized names before a new Context
    /// is created, and deselection closes an active membership rather than
    /// erasing its history.
    @discardableResult
    public func reconcileCurrentContexts(
        for personID: UUID,
        selectedContextIDs: Set<UUID>,
        creatingLabels rawLabels: [String] = [],
        at date: Date = .now
    ) throws -> [Context] {
        try requireActiveFactSubject(personID)
        var selectedIDs = selectedContextIDs
        var available = contexts
        var contextsToCreate: [Context] = []

        for rawLabel in rawLabels {
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let key = Self.normalizedIdentity(label)
            if let match = available.first(where: { context in
                ([context.names.fallback] + Array(context.names.localized.values))
                    .contains { Self.normalizedIdentity($0) == key }
            }) {
                selectedIDs.insert(match.id)
                continue
            }
            let context = Context(kind: .other, names: LocalizedText(label))
            contextsToCreate.append(context)
            available.append(context)
            selectedIDs.insert(context.id)
        }

        if !contextsToCreate.isEmpty {
            try records.upsertAll(contextsToCreate, kind: "context", now: date)
        }

        var membershipUpdates: [MembershipEpisode] = []
        let current = memberships.filter { resolvedPersonID($0.personID) == personID }
        let activeContextIDs = Set(current.filter {
            $0.status == .active && $0.isActive(at: date)
        }.map(\.contextID))

        for contextID in selectedIDs.subtracting(activeContextIDs) {
            membershipUpdates.append(MembershipEpisode(
                personID: personID,
                contextID: contextID,
                status: .active,
                createdAt: date,
                modifiedAt: date
            ))
        }

        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let endDate: PartialDate?
        if let year = components.year, let month = components.month, let day = components.day {
            endDate = try PartialDate.day(day, month: month, year: year)
        } else {
            endDate = nil
        }
        for existing in current where
            existing.status == .active && activeContextIDs.subtracting(selectedIDs).contains(existing.contextID) {
            var closed = existing
            closed.status = .completed
            closed.endDate = endDate
            closed.modifiedAt = date
            membershipUpdates.append(closed)
        }

        if !membershipUpdates.isEmpty {
            try records.upsertAll(membershipUpdates, kind: "membership", now: date)
        }
        try reloadSnapshot()
        return available.filter { selectedIDs.contains($0.id) }
            .sorted { $0.names.fallback.localizedStandardCompare($1.names.fallback) == .orderedAscending }
    }

    public func portraits(for personID: UUID) -> [PortraitMediaAsset] {
        let targetID = resolvedPersonID(personID)
        return portraitMedia.filter { resolvedPersonID($0.personID) == targetID }
    }

    public func setPrimaryPortrait(_ portraitID: UUID, for personID: UUID) {
        let current = portraits(for: personID)
        guard current.contains(where: { $0.id == portraitID }) else {
            lastError = String(localized: "The selected portrait no longer exists.")
            return
        }
        let now = Date.now
        let updated = current.map { asset in
            var asset = asset
            asset.isPrimary = asset.id == portraitID
            asset.modifiedAt = now
            return asset
        }
        do {
            try records.upsertAll(updated, kind: "portraitMedia", now: now)
            reload()
        } catch {
            lastError = String(localized: "The primary portrait could not be changed.")
        }
    }

    /// Resolves active merge redirects transitively while refusing to guess
    /// through contradictory or cyclic merge histories.
    public func resolvedPersonID(_ personID: UUID) -> UUID {
        var redirects: [UUID: Set<UUID>] = [:]
        for event in personMergeEvents where event.undoneAt == nil {
            redirects[event.sourcePersonBeforeMerge.id, default: []]
                .insert(event.destinationPersonBeforeMerge.id)
        }

        var visited: Set<UUID> = [personID]
        var currentID = personID
        while let destinations = redirects[currentID] {
            guard destinations.count == 1, let destinationID = destinations.first,
                  visited.insert(destinationID).inserted else {
                return personID
            }
            currentID = destinationID
        }
        return currentID
    }

    private func values<Value: Decodable & Sendable>(_ type: Value.Type, _ kind: String) throws -> [Value] {
        try records.fetch(type, kind: kind).map(\.value)
    }

    private func requireActiveFactSubject(_ personID: UUID) throws {
        let deletionMarkers = SynchronizedDeletionMarkerRepository(persistence: persistence)
        guard try !deletionMarkers.contains(.person(personID)) else {
            throw CanonicalFactSaveError.subjectIsNotActive(personID)
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "PersonEntity")
        request.fetchLimit = 2
        request.predicate = NSPredicate(format: "id == %@", personID as CVarArg)
        let matches = try persistence.container.viewContext.fetch(request)
        guard matches.count == 1,
              matches[0].value(forKey: "deletedAt") as? Date == nil,
              matches[0].value(forKey: "mergedIntoPersonID") as? UUID == nil else {
            throw CanonicalFactSaveError.subjectIsNotActive(personID)
        }
    }

    private func save<Value: Encodable>(_ value: Value, id: UUID, kind: String) {
        do {
            try records.upsert(value, id: id, kind: kind)
            reload()
        } catch {
            lastError = String(localized: "This structured record could not be saved locally.")
        }
    }

    private func savePlanningRecord<Value: Encodable>(
        _ value: Value,
        id: UUID,
        kind: String,
        failureMessage: String
    ) throws {
        do {
            try records.upsert(value, id: id, kind: kind)
            try reloadSnapshot()
        } catch {
            lastError = failureMessage
            throw error
        }
    }

    private func deletePlanningRecord(
        id: UUID,
        kind: String,
        failureMessage: String
    ) throws {
        do {
            try records.softDelete(id: id, kind: kind)
            try reloadSnapshot()
        } catch {
            lastError = failureMessage
            throw error
        }
    }
}
