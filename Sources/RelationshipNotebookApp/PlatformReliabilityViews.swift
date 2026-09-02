import SwiftUI
import UniformTypeIdentifiers

enum InboundDocumentSource: String, Sendable {
    case openURL
    case dragAndDrop
    case shareExtension
}

struct InboundDocumentRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let source: InboundDocumentSource

    init(id: UUID = UUID(), url: URL, source: InboundDocumentSource) {
        self.id = id
        self.url = url
        self.source = source
    }
}

/// Queues only file URLs and never reads them while onboarding or App Lock is
/// covering the notebook. AdaptiveRootView takes one item after authentication.
@MainActor
final class InboundDocumentCoordinator: ObservableObject {
    @Published private(set) var pending: [InboundDocumentRequest] = []
    @Published private var routedProfileURLs: [URL] = []
    @Published private var routedArchiveURLs: [URL] = []

    static let shareAppGroupIdentifier = "group.com.zacrotech.RelationshipNotebook"
    private static let sharedInboxDirectoryName = "KeepsakeSharedCaptures"
    private static let localInboxDirectoryName = "KeepsakeInboundCaptures"

    var pendingCount: Int { pending.count }
    var routedProfileCount: Int { routedProfileURLs.count }
    var routedArchiveCount: Int { routedArchiveURLs.count }

    func enqueue(_ url: URL, source: InboundDocumentSource) {
        guard url.isFileURL else { return }
        let standardized = url.standardizedFileURL
        guard !pending.contains(where: { $0.url.standardizedFileURL == standardized }) else {
            return
        }
        pending.append(.init(url: standardized, source: source))
    }

    func enqueue(_ URLs: [URL], source: InboundDocumentSource) {
        URLs.forEach { enqueue($0, source: source) }
    }

    func takeNext() -> InboundDocumentRequest? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    /// Called only from the unlocked metadata review after the user chooses a
    /// destination. The destination starts and stops security-scoped access
    /// around its transactional inspection; staging itself never reads data.
    func stageReviewedProfileURL(_ url: URL) {
        let url = url.standardizedFileURL
        guard url.isFileURL, !routedProfileURLs.contains(url) else { return }
        routedProfileURLs.append(url)
    }

    func stageReviewedArchiveURL(_ url: URL) {
        let url = url.standardizedFileURL
        guard url.isFileURL, !routedArchiveURLs.contains(url) else { return }
        routedArchiveURLs.append(url)
    }

    func takeRoutedProfileURL() -> URL? {
        guard !routedProfileURLs.isEmpty else { return nil }
        return routedProfileURLs.removeFirst()
    }

    func takeRoutedArchiveURL() -> URL? {
        guard !routedArchiveURLs.isEmpty else { return nil }
        return routedArchiveURLs.removeFirst()
    }

    /// Moves Share Extension payloads out of the shared container only after
    /// the unlocked app explicitly asks for the next review. A share never
    /// creates a notebook record and never bypasses onboarding or App Lock.
    func stagePendingShareExtensionItems() throws {
        #if os(iOS)
        let fileManager = FileManager.default
        guard let groupRoot = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.shareAppGroupIdentifier
        ) else {
            throw SharedCaptureInboxError.appGroupUnavailable
        }
        let inbox = groupRoot.appendingPathComponent(
            Self.sharedInboxDirectoryName,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: inbox.path) else { return }
        let requestDirectories = try fileManager.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard !requestDirectories.isEmpty else { return }

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let localInbox = applicationSupport.appendingPathComponent(
            Self.localInboxDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: localInbox,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        for requestDirectory in requestDirectories {
            guard (try requestDirectory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                continue
            }
            let manifestURL = requestDirectory.appendingPathComponent("manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                let values = try requestDirectory.resourceValues(forKeys: [.creationDateKey])
                if let createdAt = values.creationDate,
                   createdAt < Date.now.addingTimeInterval(-86_400) {
                    try fileManager.removeItem(at: requestDirectory)
                }
                continue
            }
            let manifest = try JSONDecoder().decode(
                SharedCaptureManifest.self,
                from: Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            )
            guard manifest.version == 1, manifest.files.count <= 20 else {
                throw SharedCaptureInboxError.invalidManifest
            }

            var stagedURLs: [URL] = []
            for entry in manifest.files {
                let safeName = URL(fileURLWithPath: entry.filename).lastPathComponent
                guard safeName == entry.filename, !safeName.isEmpty else {
                    throw SharedCaptureInboxError.invalidManifest
                }
                let source = requestDirectory.appendingPathComponent(safeName)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw SharedCaptureInboxError.missingSharedFile(safeName)
                }
                let destination = localInbox.appendingPathComponent(
                    "\(manifest.id.uuidString)-\(safeName)"
                )
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.copyItem(at: source, to: destination)
                    try fileManager.setAttributes(
                        [.protectionKey: FileProtectionType.complete],
                        ofItemAtPath: destination.path
                    )
                }
                stagedURLs.append(destination)
            }
            stagedURLs.forEach { enqueue($0, source: .shareExtension) }
            try fileManager.removeItem(at: requestDirectory)
        }
        #endif
    }
}

private struct SharedCaptureManifest: Codable {
    struct FileEntry: Codable {
        let filename: String
        let contentType: String
    }

    let version: Int
    let id: UUID
    let createdAt: Date
    let files: [FileEntry]
}

private enum SharedCaptureInboxError: LocalizedError {
    case appGroupUnavailable
    case invalidManifest
    case missingSharedFile(String)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            String(localized: "Keepsake’s private Share inbox is unavailable in this build.")
        case .invalidManifest:
            String(localized: "A shared item had an invalid or unsupported manifest.")
        case .missingSharedFile(let filename):
            String(localized: "The shared file \(filename) is no longer available. Share it again from the source app.")
        }
    }
}

struct InboundDocumentReviewView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @EnvironmentObject private var inboundDocuments: InboundDocumentCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @AppStorage(KeepsakePreferenceKey.defaultImportedSourceRetention)
    private var sourceRetentionRaw = ImportedSourceRetentionPolicy.evidenceExcerptsOnly.rawValue

    let request: InboundDocumentRequest
    let onRoute: (AppSection) -> Void

    @State private var metadata = InboundDocumentMetadata.loading
    @State private var isPreparingReview = false
    @State private var errorMessage: String?

    private var detectedType: UTType? {
        metadata.contentType ?? UTType(filenameExtension: request.url.pathExtension)
    }

    private var canPrepareTextReview: Bool {
        guard let type = detectedType else { return false }
        return type.conforms(to: .plainText)
            || type.conforms(to: .text)
            || type.conforms(to: .pdf)
            || type.conforms(to: .image)
    }

    private var isProfileSnapshot: Bool {
        detectedType?.identifier == "com.zacrotech.keepsake.profile-snapshot-v1"
            || request.url.pathExtension.lowercased() == "keepsakeprofile"
    }

    private var isVaultArchive: Bool {
        let identifier = detectedType?.identifier
        return identifier == "com.zacrotech.keepsake.relationship-vault"
            || identifier == "com.zacrotech.keepsake.encrypted-relationship-vault"
            || request.url.pathExtension.lowercased() == "relationshipvault"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Review this file before Keepsake reads it", systemImage: "doc.badge.ellipsis")
                        .font(.title3.bold())
                    Text("Opening or dropping a file never commits notebook records. The file remains queued while onboarding or App Lock is active, and processing begins only from this unlocked review.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Section("Received file") {
                    LabeledContent("Name", value: request.url.lastPathComponent)
                    switch metadata {
                    case .loading:
                        ProgressView("Inspecting file metadata…")
                    case .loaded(let byteCount, let type):
                        LabeledContent(
                            "Type",
                            value: type?.localizedDescription ?? String(localized: "Unknown", locale: locale)
                        )
                        if let byteCount {
                            LabeledContent(
                                "Size",
                                value: ByteCountFormatter.string(
                                    fromByteCount: byteCount,
                                    countStyle: .file
                                )
                            )
                        }
                    case .unavailable:
                        Label("Keepsake could not inspect this file’s metadata.", systemImage: "exclamationmark.triangle")
                            .keepsakeWarningStyle()
                    }
                }

                Section("Choose a safe review route") {
                    if canPrepareTextReview {
                        Button {
                            Task { await preparePendingTextReview() }
                        } label: {
                            Label("Extract On Device and Open Import Review", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isPreparingReview)
                        if isPreparingReview {
                            ProgressView("Extracting readable text on this device…")
                        }
                        Text("Text, PDF, and image files use the same deterministic, review-first pipeline as the nested importer. PDF/image OCR stays on device. A pending review is saved; no person or fact is added.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    } else if isProfileSnapshot {
                        Button {
                            inboundDocuments.stageReviewedProfileURL(request.url)
                            route(to: .profile)
                        } label: {
                            Label("Continue to Received Profiles", systemImage: "person.text.rectangle")
                        }
                        .buttonStyle(.borderedProminent)
                    } else if isVaultArchive {
                        Button {
                            inboundDocuments.stageReviewedArchiveURL(request.url)
                            route(to: .settings)
                        } label: {
                            Label("Continue to Archive Import", systemImage: "archivebox")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Label(
                            "This file type is not supported for direct review. Use one of the nested Choose File controls below.",
                            systemImage: "questionmark.folder"
                        )
                        .keepsakeWarningStyle()
                    }

                    Text("You can always cancel and use the explicit Choose File control in Imports & Review, Received Profiles, or Settings → Portability instead.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Review Received File")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { loadMetadata() }
            .alert("File review needs attention", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .keepsakeSheetSize(minWidth: 600, minHeight: 520)
        .interactiveDismissDisabled(isPreparingReview)
    }

    private func loadMetadata() {
        do {
            let values = try request.url.resourceValues(forKeys: [
                .fileSizeKey,
                .contentTypeKey
            ])
            metadata = .loaded(
                byteCount: values.fileSize.map { Int64($0) },
                contentType: values.contentType
            )
        } catch {
            metadata = .unavailable
        }
    }

    @MainActor
    private func preparePendingTextReview() async {
        guard !isPreparingReview else { return }
        isPreparingReview = true
        defer { isPreparingReview = false }

        let hasScopedAccess = request.url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess { request.url.stopAccessingSecurityScopedResource() }
        }

        do {
            let document = try await DocumentTextExtractor().extract(url: request.url)
            let retention = ImportedSourceRetentionPolicy(rawValue: sourceRetentionRaw)
                ?? .evidenceExcerptsOnly
            var source = TextImportSourceArtifact(
                kind: .plainTextFile,
                originalFilename: document.sourceName,
                text: document.units.map(\.text).joined(separator: "\n")
            )
            source.retentionPolicy = retention
            var review = try DeterministicTextImportPipeline().extract(from: source)
            let decisions = review.candidates.map { candidate in
                TextImportCandidateDecisionSnapshot(
                    candidateID: candidate.id,
                    displayName: candidate.proposedDisplayName,
                    disposition: initialDisposition(for: candidate),
                    targetPersonID: nil,
                    selectedAssertionIDs: Set(
                        candidate.assertions
                            .filter(\.isPreselectedForReview)
                            .map(\.id)
                    )
                )
            }
            let units = document.units.map { unit in
                TextImportSourceUnitSnapshot(
                    id: unit.id,
                    index: unit.index,
                    text: unit.text,
                    usedOCR: unit.usedOCR,
                    ocrConfidence: unit.ocrConfidence,
                    regions: unit.regions
                )
            }
            let retainedSource: RetainedTextImportSource?
            if retention == .keepOriginal, let data = document.originalData {
                retainedSource = RetainedTextImportSource(
                    contentType: document.contentType,
                    filename: document.sourceName,
                    sha256: document.sha256,
                    data: data
                )
            } else {
                retainedSource = nil
            }
            let artifactKind = sourceArtifactKind(for: document.contentType)
            review.workflow = TextImportWorkflowState(
                lifecycle: .pending,
                sourceArtifactKind: artifactKind,
                sourceRetention: retention,
                candidateDecisions: decisions,
                sourceUnits: units,
                retainedSource: retainedSource,
                portrait: artifactKind == .image
                    ? TextImportPortraitProposal(shouldProposeFirstImageAsPortrait: false)
                    : nil
            )

            canonical.lastError = nil
            canonical.save(review)
            if let error = canonical.lastError { throw InboundDocumentSaveError(error) }
            route(to: .imports)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func initialDisposition(
        for candidate: TextImportCandidate
    ) -> TextImportReviewedDisposition {
        if store.person(id: candidate.id) != nil { return .skip }
        let normalized = SearchNormalizer.normalize(candidate.proposedDisplayName)
        if store.people.contains(where: {
            $0.deletedAt == nil
                && SearchNormalizer.normalize($0.displayName) == normalized
        }) {
            return .deferred
        }
        return candidate.isPreselectedForReview ? .createNew : .deferred
    }

    private func sourceArtifactKind(for identifier: String) -> SourceArtifactKind {
        guard let type = UTType(identifier) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return .other
    }

    private func route(to section: AppSection) {
        onRoute(section)
        dismiss()
    }
}

private enum InboundDocumentMetadata {
    case loading
    case loaded(byteCount: Int64?, contentType: UTType?)
    case unavailable

    var contentType: UTType? {
        if case .loaded(_, let contentType) = self { return contentType }
        return nil
    }
}

private struct InboundDocumentSaveError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct KeepsakeQuickSwitcherView: View {
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @AppStorage(KeepsakePreferenceKey.nameDisplayOrder)
    private var nameDisplayOrder = PersonNameDisplayOrder.asEntered.rawValue
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    let onSelectSection: (AppSection) -> Void
    let onSelectPerson: (UUID) -> Void
    @State private var query = ""

    private var sections: [AppSection] {
        guard !query.isEmpty else { return AppSection.allCases }
        return AppSection.allCases.filter {
            $0.localizedTitle(locale: locale).localizedCaseInsensitiveContains(query)
        }
    }

    private var people: [Person] {
        let active = store.people.filter { $0.deletedAt == nil }
        guard !query.isEmpty else { return Array(active.prefix(12)) }
        return active.filter {
            $0.resolvedDisplayName(order: displayOrder)
                .localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.aliases.contains(where: {
                    $0.localizedCaseInsensitiveContains(query)
                })
        }
        .prefix(50)
        .map { $0 }
    }

    private var displayOrder: PersonNameDisplayOrder {
        PersonNameDisplayOrder(rawValue: nameDisplayOrder) ?? .asEntered
    }

    var body: some View {
        NavigationStack {
            List {
                if !sections.isEmpty {
                    Section("Navigate") {
                        ForEach(sections) { section in
                            Button {
                                onSelectSection(section)
                                dismiss()
                            } label: {
                                Label(
                                    section.localizedTitle(locale: locale),
                                    systemImage: section.icon
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !people.isEmpty {
                    Section("People") {
                        ForEach(people) { person in
                            HStack {
                                Button {
                                    onSelectPerson(person.id)
                                    dismiss()
                                } label: {
                                    HStack {
                                        PersonAvatar(person: person, size: 34)
                                        Text(person.resolvedDisplayName(order: displayOrder))
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                                #if os(macOS)
                                Button {
                                    openWindow(value: person.id)
                                } label: {
                                    Image(systemName: "macwindow.badge.plus")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Open \(person.displayName) in a new window")
                                #endif
                            }
                        }
                    }
                }

                if sections.isEmpty && people.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search people and sections")
            .navigationTitle("Quick Open")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .keepsakeSheetSize(minWidth: 580, minHeight: 540)
    }
}
