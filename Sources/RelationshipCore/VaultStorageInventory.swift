import Foundation

public enum VaultStorageCategory: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case people
    case interactions
    case interactionTranscripts
    case interactionDraftPayloads
    case canonicalRecords
    case extractedSourceText
    case retainedOriginalSources
    case evidenceExcerpts
    case pendingImportReviews
    case completedImportReviews
    case portraitPayloads
    case profileSnapshots
    case recentlyDeletedPeople
    case recentlyDeletedStructuredRecords

    public var id: Self { self }
}

public enum VaultStorageExportInclusion: String, Codable, Hashable, Sendable {
    case fullArchive
    case fullArchiveAndMediaPackage
    case metadataOnlyInJSON
    case excludedFromPortableExport
    case dependsOnScope
}

public enum VaultStorageDeletionControl: String, Codable, Hashable, Sendable {
    case none
    case perRecordRecentlyDeleted
    case clearRetainedPayload
    case clearExtractedText
    case transcriptRetention
    case profileVersionArchive
}

public struct VaultStorageInventoryItem: Hashable, Codable, Sendable, Identifiable {
    public var category: VaultStorageCategory
    public var recordCount: Int
    public var byteCount: Int64
    public var retention: String
    public var exportInclusion: VaultStorageExportInclusion
    public var deletionControl: VaultStorageDeletionControl

    public var id: VaultStorageCategory { category }

    public init(
        category: VaultStorageCategory,
        recordCount: Int,
        byteCount: Int64,
        retention: String,
        exportInclusion: VaultStorageExportInclusion,
        deletionControl: VaultStorageDeletionControl
    ) {
        self.category = category
        self.recordCount = max(0, recordCount)
        self.byteCount = max(0, byteCount)
        self.retention = retention
        self.exportInclusion = exportInclusion
        self.deletionControl = deletionControl
    }
}

public struct VaultStorageInventory: Hashable, Codable, Sendable {
    public var generatedAt: Date
    public var items: [VaultStorageInventoryItem]

    public init(generatedAt: Date = .now, items: [VaultStorageInventoryItem]) {
        self.generatedAt = generatedAt
        self.items = items
    }

    public var totalKnownBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
}

public struct VaultStorageInventoryBuilder: Sendable {
    public init() {}

    public func build(
        people: [Person],
        interactions: [Interaction],
        canonical: CanonicalArchivePayload,
        profileSnapshots: [ProfileCardSnapshotPayload],
        recentlyDeletedStructuredCount: Int
    ) -> VaultStorageInventory {
        let activePeople = people.filter { $0.deletedAt == nil }
        let deletedPeople = people.filter { $0.deletedAt != nil }
        let transcripts = interactions.compactMap(\.rawTranscript)
        let drafts = interactions.flatMap { interaction in
            [interaction.generatedDraft, interaction.finalContent, interaction.privateReflection].compactMap { $0 }
        }
        let pendingReviews = canonical.textImportReviews.filter(\.isResumable)
        let completedReviews = canonical.textImportReviews.filter { !$0.isResumable }
        let sourceTextBytes = canonical.textImportReviews.reduce(0) { total, review in
            total + review.source.text.utf8.count
                + (review.workflow?.sourceUnits.reduce(0) { $0 + $1.text.utf8.count } ?? 0)
        }
        let retainedOriginals = canonical.textImportReviews.compactMap { $0.workflow?.retainedSource }
        let retainedOriginalBytes = retainedOriginals.reduce(0) { $0 + $1.data.count }
        let excerptBytes = canonical.textImportReviews.reduce(0) { total, review in
            total + review.evidence.reduce(0) { $0 + $1.excerpt.utf8.count }
        }
        var canonicalRecordCount = 0
        canonicalRecordCount += canonical.contexts.count
        canonicalRecordCount += canonical.cohortSchemes.count
        canonicalRecordCount += canonical.cohorts.count
        canonicalRecordCount += canonical.memberships.count
        canonicalRecordCount += canonical.cohortAssignments.count
        canonicalRecordCount += canonical.roleDefinitions.count
        canonicalRecordCount += canonical.roleAssignments.count
        canonicalRecordCount += canonical.education.count
        canonicalRecordCount += canonical.assertions.count
        canonicalRecordCount += canonical.sources.count
        canonicalRecordCount += canonical.artifactUnits?.count ?? 0
        canonicalRecordCount += canonical.evidence.count
        canonicalRecordCount += canonical.reminders.count
        canonicalRecordCount += canonical.commitments.count
        canonicalRecordCount += canonical.savedViews.count
        canonicalRecordCount += canonical.attributeDefinitions.count
        canonicalRecordCount += canonical.personMergeEvents.count

        return VaultStorageInventory(items: [
            item(.people, activePeople, "Until moved to Recently Deleted", .dependsOnScope, .perRecordRecentlyDeleted),
            item(.interactions, interactions, "Until moved to Recently Deleted", .dependsOnScope, .perRecordRecentlyDeleted),
            textItem(.interactionTranscripts, transcripts, "Per-interaction transcript choice", .dependsOnScope, .transcriptRetention),
            textItem(.interactionDraftPayloads, drafts, "Until cleared or its interaction is deleted", .dependsOnScope, .transcriptRetention),
            VaultStorageInventoryItem(
                category: .canonicalRecords,
                recordCount: canonicalRecordCount,
                byteCount: encodedSize(canonical),
                retention: "Per structured record lifecycle",
                exportInclusion: .dependsOnScope,
                deletionControl: .perRecordRecentlyDeleted
            ),
            VaultStorageInventoryItem(
                category: .extractedSourceText,
                recordCount: canonical.textImportReviews.filter {
                    !$0.source.text.isEmpty || ($0.workflow?.sourceUnits.contains { !$0.text.isEmpty } ?? false)
                }.count,
                byteCount: Int64(sourceTextBytes),
                retention: "Chosen during import; pending drafts retain enough text to resume",
                exportInclusion: .dependsOnScope,
                deletionControl: .clearExtractedText
            ),
            VaultStorageInventoryItem(
                category: .retainedOriginalSources,
                recordCount: retainedOriginals.count,
                byteCount: Int64(retainedOriginalBytes),
                retention: "Only when Keep original is explicitly selected",
                exportInclusion: .fullArchive,
                deletionControl: .clearRetainedPayload
            ),
            VaultStorageInventoryItem(
                category: .evidenceExcerpts,
                recordCount: canonical.textImportReviews.reduce(0) { $0 + $1.evidence.filter { !$0.excerpt.isEmpty }.count },
                byteCount: Int64(excerptBytes),
                retention: "Per imported-source retention choice",
                exportInclusion: .dependsOnScope,
                deletionControl: .clearExtractedText
            ),
            item(.pendingImportReviews, pendingReviews, "Until committed or moved to Recently Deleted", .fullArchive, .perRecordRecentlyDeleted),
            item(.completedImportReviews, completedReviews, "Provenance history", .dependsOnScope, .perRecordRecentlyDeleted),
            VaultStorageInventoryItem(
                category: .portraitPayloads,
                recordCount: canonical.portraitMedia?.count ?? 0,
                byteCount: Int64((canonical.portraitMedia ?? []).reduce(0) { $0 + $1.byteCount }),
                retention: "Protected app storage until portrait metadata is deleted",
                exportInclusion: .fullArchiveAndMediaPackage,
                deletionControl: .perRecordRecentlyDeleted
            ),
            item(.profileSnapshots, profileSnapshots, "Immutable saved versions until archived or deleted", .fullArchive, .profileVersionArchive),
            item(.recentlyDeletedPeople, deletedPeople, "Recoverable until permanent deletion", .excludedFromPortableExport, .perRecordRecentlyDeleted),
            VaultStorageInventoryItem(
                category: .recentlyDeletedStructuredRecords,
                recordCount: recentlyDeletedStructuredCount,
                byteCount: 0,
                retention: "Recoverable until permanent deletion",
                exportInclusion: .excludedFromPortableExport,
                deletionControl: .perRecordRecentlyDeleted
            )
        ])
    }

    private func item<Value: Encodable>(
        _ category: VaultStorageCategory,
        _ values: [Value],
        _ retention: String,
        _ export: VaultStorageExportInclusion,
        _ deletion: VaultStorageDeletionControl
    ) -> VaultStorageInventoryItem {
        VaultStorageInventoryItem(
            category: category,
            recordCount: values.count,
            byteCount: encodedSize(values),
            retention: retention,
            exportInclusion: export,
            deletionControl: deletion
        )
    }

    private func textItem(
        _ category: VaultStorageCategory,
        _ values: [String],
        _ retention: String,
        _ export: VaultStorageExportInclusion,
        _ deletion: VaultStorageDeletionControl
    ) -> VaultStorageInventoryItem {
        VaultStorageInventoryItem(
            category: category,
            recordCount: values.count,
            byteCount: Int64(values.reduce(0) { $0 + $1.utf8.count }),
            retention: retention,
            exportInclusion: export,
            deletionControl: deletion
        )
    }

    private func encodedSize<Value: Encodable>(_ value: Value) -> Int64 {
        Int64((try? JSONEncoder().encode(value).count) ?? 0)
    }
}
