import SwiftUI
import UniformTypeIdentifiers

struct StorageInventoryView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @State private var exportDocument: NotebookDocument?
    @State private var isExporting = false
    @State private var errorMessage: String?

    private var inventory: VaultStorageInventory {
        VaultStorageInventoryBuilder().build(
            people: store.people,
            interactions: store.interactions,
            canonical: canonical.archivePayload,
            profileSnapshots: canonical.profileSnapshots,
            recentlyDeletedStructuredCount: canonical.recentlyDeletedRecords.count
        )
    }

    var body: some View {
        List {
            Section {
                LabeledContent(
                    "Known payload size",
                    value: ByteCountFormatter.string(fromByteCount: inventory.totalKnownBytes, countStyle: .file)
                )
                Text("Sizes are the encoded payload bytes Keepsake can attribute to a type. Core Data and filesystem overhead are intentionally not guessed.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Button("Export typed inventory…") { exportInventory() }
            }

            ForEach(inventory.items) { item in
                Section(storageCategoryTitle(item.category)) {
                    LabeledContent("Records", value: "\(item.recordCount)")
                    LabeledContent(
                        "Payload size",
                        value: item.byteCount == 0
                            ? String(localized: "None or not separately measurable")
                            : ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
                    )
                    LabeledContent("Retention", value: item.retention)
                    LabeledContent("Portable export", value: storageExportTitle(item.exportInclusion))
                    LabeledContent("Deletion control", value: storageDeletionTitle(item.deletionControl))
                }
            }

            if !canonical.textImportReviews.isEmpty {
                Section("Imported source controls") {
                    ForEach(canonical.textImportReviews.sorted {
                        ($0.workflow?.savedAt ?? $0.source.importedAt) > ($1.workflow?.savedAt ?? $1.source.importedAt)
                    }) { review in
                        DisclosureGroup(review.source.originalFilename ?? String(localized: "Pasted text")) {
                            LabeledContent("Lifecycle", value: review.isResumable ? String(localized: "Pending") : String(localized: "Completed"))
                            if let retained = review.workflow?.retainedSource {
                                LabeledContent(
                                    "Exact original",
                                    value: ByteCountFormatter.string(fromByteCount: Int64(retained.data.count), countStyle: .file)
                                )
                                Button("Remove retained original", role: .destructive) {
                                    canonical.clearRetainedOriginalSource(reviewID: review.id)
                                }
                                .disabled(review.isResumable)
                            }
                            let hasExtractedText = !review.source.text.isEmpty
                                || (review.workflow?.sourceUnits.contains { !$0.text.isEmpty } ?? false)
                            if hasExtractedText {
                                Button("Remove complete extracted text", role: .destructive) {
                                    canonical.clearExtractedSourceText(reviewID: review.id)
                                }
                                .disabled(review.isResumable)
                            }
                            if review.isResumable {
                                Text("A pending review keeps the complete state needed to resume. Commit it or move it to Recently Deleted before clearing its source payload.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Button("Move review to Recently Deleted", role: .destructive) {
                                canonical.delete(review, kind: "textImportReview")
                            }
                        }
                    }
                }
            }

            let contentInteractions = store.interactions.filter {
                $0.rawTranscript != nil || $0.generatedDraft != nil || $0.finalContent != nil || $0.privateReflection != nil
            }
            if !contentInteractions.isEmpty {
                Section("Transcript and draft controls") {
                    ForEach(contentInteractions) { interaction in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(interaction.channel.isEmpty ? interaction.kind.localizedTitle : interaction.channel)
                                .font(.headline)
                            Text(interaction.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                            Button("Clear transcript and draft payloads", role: .destructive) {
                                clearContent(interaction)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Storage Inventory")
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Keepsake-Storage-Inventory.json"
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            exportDocument = nil
        }
        .alert("Storage inventory needs attention", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func clearContent(_ interaction: Interaction) {
        var updated = interaction
        updated.rawTranscript = nil
        updated.generatedDraft = nil
        updated.finalContent = nil
        updated.privateReflection = nil
        updated.summary = ""
        updated.commitment = ""
        updated.transcriptRetention = .metadataOnly
        _ = store.save(updated)
    }

    private func exportInventory() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            exportDocument = NotebookDocument(data: try encoder.encode(inventory))
            isExporting = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private func storageCategoryTitle(_ category: VaultStorageCategory) -> String {
    switch category {
    case .people: String(localized: "People")
    case .interactions: String(localized: "Interactions")
    case .interactionTranscripts: String(localized: "Retained transcripts")
    case .interactionDraftPayloads: String(localized: "Drafts, final content, and reflections")
    case .canonicalRecords: String(localized: "Structured facts, planning, and provenance")
    case .extractedSourceText: String(localized: "Extracted source text")
    case .retainedOriginalSources: String(localized: "Retained original source files")
    case .evidenceExcerpts: String(localized: "Evidence excerpts")
    case .pendingImportReviews: String(localized: "Pending import reviews")
    case .completedImportReviews: String(localized: "Completed import review history")
    case .portraitPayloads: String(localized: "Portrait image payloads")
    case .profileSnapshots: String(localized: "Saved profile-card versions")
    case .recentlyDeletedPeople: String(localized: "Recently deleted people")
    case .recentlyDeletedStructuredRecords: String(localized: "Recently deleted structured records")
    }
}

private func storageExportTitle(_ value: VaultStorageExportInclusion) -> String {
    switch value {
    case .fullArchive: String(localized: "Included in a full archive")
    case .fullArchiveAndMediaPackage: String(localized: "Metadata in JSON; bytes in media/encrypted archive")
    case .metadataOnlyInJSON: String(localized: "Metadata only in JSON")
    case .excludedFromPortableExport: String(localized: "Excluded")
    case .dependsOnScope: String(localized: "Depends on selected export scope")
    }
}

private func storageDeletionTitle(_ value: VaultStorageDeletionControl) -> String {
    switch value {
    case .none: String(localized: "No direct control")
    case .perRecordRecentlyDeleted: String(localized: "Per record / Recently Deleted")
    case .clearRetainedPayload: String(localized: "Remove retained original")
    case .clearExtractedText: String(localized: "Remove complete text or excerpts")
    case .transcriptRetention: String(localized: "Per interaction retention")
    case .profileVersionArchive: String(localized: "Archive saved version")
    }
}
