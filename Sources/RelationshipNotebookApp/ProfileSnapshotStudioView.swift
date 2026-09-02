import CoreTransferable
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Creates immutable, versioned self-profile snapshots from a deny-by-default
/// field allowlist. Person access is used only to locate the explicitly marked
/// Self record's sanitized portrait; private notes and relationship history
/// still have no representation in the snapshot graph.
private enum ProfileSnapshotStudioMode: String, CaseIterable, Identifiable {
    case create
    case receive
    case saved

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .create: "Create"
        case .receive: "Receive"
        case .saved: "Saved"
        }
    }
}

struct ProfileSnapshotStudioView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @EnvironmentObject private var inboundDocuments: InboundDocumentCoordinator

    @State private var studioMode = ProfileSnapshotStudioMode.create
    @State private var fields = ProfileStudioFieldEditor.defaults
    @State private var selectedPreset = ProfileStudioPreset.custom
    @State private var cardVersion = 1
    @State private var publicationID = UUID()
    @State private var cardVersionID = UUID()
    @State private var usesAdvisoryExpiry = false
    @State private var advisoryExpiry = Date.now.addingTimeInterval(30 * 86_400)
    @State private var retentionIntent = ProfileSnapshotRetentionIntent.recipientMayRetain
    @State private var exactPayloadBytes: Data?
    @State private var exactPayload: ProfileCardSnapshotPayload?
    @State private var preparedCopyIsSaved = false
    @State private var exportDocument: ProfileSnapshotFileDocument?
    @State private var isExporting = false
    @State private var isShowingPreview = false
    @State private var isChoosingReceivedProfile = false
    @State private var isChoosingReceivedQRCode = false
    @State private var receivedProfileDraft: ReceivedProfileReviewDraft?
    @State private var selectedSavedSnapshot: SavedProfileSnapshotSelection?
    @State private var selectedPortraitAssetID: UUID?
    @State private var portraitFieldID = UUID()
    @State private var hasSeededVersion = false
    @State private var confirmingNewCard = false
    @State private var errorMessage: String?

    private let serializer = ProfileCardSnapshotSerializer()

    private var includedFieldCount: Int {
        fields.filter(\.isIncluded).count + (selectedPortraitAssetID == nil ? 0 : 1)
    }
    private var canPublish: Bool {
        includedFieldCount > 0 && fields.filter(\.isIncluded).allSatisfy(\.hasPublishableValue)
    }
    private var selfPortraits: [PortraitMediaAsset] {
        guard let selfID = store.people.first(where: {
            $0.deletedAt == nil && $0.mergedIntoPersonID == nil && $0.isSelfIdentity == true
        })?.id else { return [] }
        return canonical.portraits(for: selfID)
    }
    private var savedSeries: [ProfileSnapshotSeriesSummary] {
        let visible = canonical.profileSnapshots.filter {
            canonical.state(forProfileSnapshotID: $0.cardVersionID)?.archivedAt == nil
        }
        return Dictionary(grouping: visible, by: \.publicationID)
            .compactMap { publicationID, versions in
                guard let latest = versions.max(by: {
                    if $0.cardVersion == $1.cardVersion { return $0.publishedAt < $1.publishedAt }
                    return $0.cardVersion < $1.cardVersion
                }) else { return nil }
                return ProfileSnapshotSeriesSummary(
                    id: publicationID,
                    latest: latest,
                    versionCount: versions.count
                )
            }
            .sorted { $0.latest.publishedAt > $1.latest.publishedAt }
    }

    var body: some View {
        Form {
            Section {
                Picker("Profile sharing task", selection: $studioMode) {
                    ForEach(ProfileSnapshotStudioMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if studioMode == .create {
                Section("How profile sharing works") {
                    Label("1. Choose only the details you want to send", systemImage: "checklist")
                    Label("2. Review the exact copy before anything is saved", systemImage: "eye")
                    Label("3. Save that version, then use AirDrop, Messages, Mail, or Files", systemImage: "square.and.arrow.up")
                    Label("The recipient gets a copy—not access to your notebook", systemImage: "lock.shield.fill")
                        .foregroundStyle(AppTheme.accent)
                    Text("Profile cards are for facts about you that you deliberately choose to share. Private notes, people, interactions, reminders, and source files cannot be added to a card.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Section("This card") {
                    LabeledContent("Version to review", value: "\(cardVersion)")
                    LabeledContent("Details selected", value: "\(includedFieldCount)")
                    Text("A shared card is a static file. A later version cannot update, erase, or retract a copy someone already received.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Button("Start a new card…") { confirmingNewCard = true }
                    Button("Use the first-meeting field set") { startFirstMeetingCard() }
                }
            }

            if studioMode == .receive {
                Section("Receive a shared profile") {
                    Label("Someone sent you a Keepsake profile?", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.headline)
                    Text("Choose the original .keepsakeprofile file or a QR image, review every self-asserted detail, then create a new person or explicitly attach it to an existing person. Keepsake never matches by name automatically.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Button {
                        isChoosingReceivedProfile = true
                    } label: {
                        Label("Review a shared profile file…", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.actionFill)
                    Button {
                        isChoosingReceivedQRCode = true
                    } label: {
                        Label("Review a profile QR image…", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.bordered)
                }

                Section("Before anything is added") {
                    Label("The exact received snapshot is verified", systemImage: "checkmark.shield")
                    Label("You choose the person and every imported field", systemImage: "person.crop.circle.badge.checkmark")
                    Label("Portraits are sanitized before they enter the notebook", systemImage: "photo.badge.checkmark")
                    Text("Opening a file or QR image only prepares a review. Nothing is committed until you approve it on the review screen.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Section("Nearby first meeting") {
                    Label("Exchange the reviewed card in person", systemImage: "person.2.wave.2")
                        .foregroundStyle(AppTheme.accent)
                    Text("One person prepares and saves a minimal First Meeting card, then shows its exact-payload QR. The other chooses the QR image here and reviews every field before import.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Button("Prepare my first-meeting card") { startFirstMeetingCard() }
                    Button("Choose a nearby profile QR image…") {
                        isChoosingReceivedQRCode = true
                    }
                }
            }

            if studioMode == .saved, savedSeries.isEmpty {
                Section("Saved card series") {
                    ContentUnavailableView(
                        "No Saved Profile Cards",
                        systemImage: "person.text.rectangle",
                        description: Text("Create and save an exact profile snapshot to start a version history.")
                    )
                    Button("Create a profile card") { studioMode = .create }
                }
            }

            if studioMode == .saved, !savedSeries.isEmpty {
                Section("Saved card series") {
                    Text("Open any immutable version to inspect its exact fields, compare it with the previous version, export the original bytes, or display its QR code when it fits.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text("Revoking or archiving controls future sharing from this notebook. It cannot recall a static copy already sent to someone.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    ForEach(savedSeries) { series in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(profileSnapshotDisplayName(series.latest))
                                    .font(.headline)
                                Spacer()
                                Text("Latest: v\(series.latest.cardVersion)")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            Text("\(series.versionCount) saved version(s) · \(series.latest.publishedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                            Button("Continue this series") { continueSeries(from: series.latest) }
                                .buttonStyle(.bordered)
                            DisclosureGroup("Browse saved versions") {
                                ForEach(canonical.profileSnapshots.filter {
                                    $0.publicationID == series.id
                                }.sorted { $0.cardVersion > $1.cardVersion }, id: \.cardVersionID) { snapshot in
                                    Button {
                                        selectedSavedSnapshot = SavedProfileSnapshotSelection(snapshot: snapshot)
                                    } label: {
                                        HStack {
                                            Text("Version \(snapshot.cardVersion)")
                                            Spacer()
                                            Text(snapshot.publishedAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.secondaryText)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if studioMode == .create {
                Section("Starting template") {
                Picker("Profile card preset", selection: $selectedPreset) {
                    ForEach(ProfileStudioPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Text("A preset only chooses a starting set of fields and audiences. You can change every field before publishing.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

                Section("Deliberately shareable fields") {
                ForEach($fields) { $field in
                    ProfileStudioFieldRow(field: $field)
                }
            }

                Section("Portrait (optional)") {
                if selfPortraits.isEmpty {
                    Label("Add a portrait to your Self profile first", systemImage: "person.crop.circle.badge.plus")
                        .foregroundStyle(AppTheme.secondaryText)
                    Text("Only a metadata-stripped portrait attached to the active Self record can cross this sharing boundary.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    Picker("Sanitized portrait", selection: $selectedPortraitAssetID) {
                        Text("Do not include a portrait").tag(nil as UUID?)
                        ForEach(selfPortraits) { asset in
                            Text(asset.isPrimary ? String(localized: "Primary portrait") : String(localized: "Portrait \(asset.id.uuidString.prefix(8))"))
                                .tag(asset.id as UUID?)
                        }
                    }
                    Text("The exact metadata-free JPEG bytes are embedded in the profile file. Portrait cards are normally too large for QR and should be shared as a file.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

                Section("Recipient expectations (optional)") {
                Toggle("Add advisory expiry", isOn: $usesAdvisoryExpiry)
                if usesAdvisoryExpiry {
                    DatePicker(
                        "Advisory expiry",
                        selection: $advisoryExpiry,
                        in: Date.now...,
                        displayedComponents: [.date]
                    )
                    Text("Expiry is metadata and cannot erase a downloaded file, export, screenshot, or other recipient-controlled copy.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("Intended retention", selection: $retentionIntent) {
                    Text("Recipient may retain the copy").tag(ProfileSnapshotRetentionIntent.recipientMayRetain)
                    Text("Ask recipient to delete after expiry").tag(ProfileSnapshotRetentionIntent.askRecipientToDeleteAfterExpiry)
                }
                Text(profileStudioRetentionExplanation(retentionIntent))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

                Section {
                DisclosureGroup("What can never be included") {
                    Label("Private notes about anyone", systemImage: "lock.fill")
                    Label("Interactions, transcripts, and relationship history", systemImage: "lock.fill")
                    Label("Reminders, nudges, and relationship settings", systemImage: "lock.fill")
                    Label("Source files and facts about other people", systemImage: "lock.fill")
                }
            }

                Section {
                Button {
                    if exactPayload != nil {
                        isShowingPreview = true
                    } else {
                        preparePreview()
                    }
                } label: {
                    Label("Review what will be shared", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.actionFill)
                .disabled(!canPublish)

                if includedFieldCount > 0, !canPublish {
                    Text("Complete every included field before preparing the exact snapshot.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                if let exactPayloadBytes, let exactPayload {
                    Button {
                        isShowingPreview = true
                    } label: {
                        Label(preparedCopyIsSaved ? "Open saved copy" : "Continue reviewing", systemImage: "eye")
                    }

                    if preparedCopyIsSaved {
                        Button {
                            exportDocument = ProfileSnapshotFileDocument(data: exactPayloadBytes)
                            isExporting = true
                        } label: {
                            Label("Save a copy to Files…", systemImage: "folder")
                        }

                        Label("Version \(exactPayload.cardVersion) is saved and ready to share.", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("This preview is not saved and cannot be shared yet.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                } else {
                    Text("Reviewing creates a temporary exact copy. You decide whether to save it on the next screen; saving still does not send it anywhere.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
        }
        .formStyle(.grouped)
        .navigationTitle("Profile Sharing")
        .onAppear {
            if !hasSeededVersion {
                cardVersion = 1
                hasSeededVersion = true
            }
            consumeInboundProfileIfAvailable()
        }
        .onChange(of: inboundDocuments.routedProfileCount) { _, _ in
            consumeInboundProfileIfAvailable()
        }
        .onChange(of: fields) { _, _ in invalidatePublishedCopy() }
        .onChange(of: selectedPreset) { _, preset in apply(preset) }
        .onChange(of: usesAdvisoryExpiry) { _, _ in invalidatePublishedCopy() }
        .onChange(of: advisoryExpiry) { _, _ in invalidatePublishedCopy() }
        .onChange(of: retentionIntent) { _, _ in invalidatePublishedCopy() }
        .onChange(of: selectedPortraitAssetID) { _, _ in invalidatePublishedCopy() }
        .fileImporter(
            isPresented: $isChoosingReceivedProfile,
            allowedContentTypes: [.keepsakeProfileSnapshotV1],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let URLs):
                guard let URL = URLs.first else { return }
                prepareReceivedProfile(at: URL)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isChoosingReceivedQRCode,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let URLs):
                guard let URL = URLs.first else { return }
                prepareReceivedProfileQRCode(at: URL)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .keepsakeProfileSnapshotV1,
            defaultFilename: "Keepsake-Profile-v\(exactPayload?.cardVersion ?? cardVersion).keepsakeprofile"
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            exportDocument = nil
        }
        .sheet(isPresented: $isShowingPreview) {
            if let exactPayloadBytes, let exactPayload {
                ProfileSnapshotExactPreview(
                    payload: exactPayload,
                    exactPayloadBytes: exactPayloadBytes,
                    isSaved: $preparedCopyIsSaved,
                    onSave: savePreparedCopy
                )
            }
        }
        .sheet(item: $receivedProfileDraft, onDismiss: consumeInboundProfileIfAvailable) { draft in
            ReceivedProfileSnapshotReviewView(draft: draft)
        }
        .sheet(item: $selectedSavedSnapshot) { selection in
            SavedProfileSnapshotDetailView(
                snapshot: selection.snapshot,
                previous: canonical.profileSnapshots
                    .filter {
                        $0.publicationID == selection.snapshot.publicationID
                            && $0.cardVersion < selection.snapshot.cardVersion
                    }
                    .max { $0.cardVersion < $1.cardVersion },
                onContinue: { continueSeries(from: selection.snapshot) },
                onRevoke: { revoked in
                    canonical.setProfileSnapshotRevoked(selection.snapshot, revoked: revoked)
                },
                onArchive: { canonical.archiveProfileSnapshot(selection.snapshot) }
            )
        }
        .confirmationDialog(
            "Start a new profile card?",
            isPresented: $confirmingNewCard,
            titleVisibility: .visible
        ) {
            Button("Start New Card") { startNewCard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved static versions stay available. Unsaved edits in the current card are cleared.")
        }
        .alert("Profile card needs attention", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func preparePreview() {
        do {
            let publicationDate = Date.now
            var fieldDrafts = try fields.compactMap { field -> ProfileSnapshotFieldDraft? in
                guard field.isIncluded else { return nil }
                return ProfileSnapshotFieldDraft(
                    id: field.id,
                    key: field.key.rawValue,
                    value: try field.snapshotValue(),
                    audience: field.audience
                )
            }
            var embeddedMedia: [ProfileSnapshotEmbeddedMedia] = []
            if let selectedPortraitAssetID,
               let asset = selfPortraits.first(where: { $0.id == selectedPortraitAssetID }) {
                let data = try canonical.mediaPayloads.synchronizedData(for: asset)
                let contentType = UTType(asset.contentType)?.preferredMIMEType ?? "image/jpeg"
                fieldDrafts.append(ProfileSnapshotFieldDraft(
                    id: portraitFieldID,
                    key: ShareableProfileFieldKey.portrait.rawValue,
                    value: .sanitizedMedia(
                        mediaID: asset.id,
                        contentType: contentType,
                        sha256: asset.sha256,
                        byteCount: data.count,
                        metadataStripped: asset.metadataWasStripped
                    ),
                    audience: .anyRecipient
                ))
                embeddedMedia.append(ProfileSnapshotEmbeddedMedia(
                    fieldID: portraitFieldID,
                    mediaID: asset.id,
                    contentType: contentType,
                    sha256: asset.sha256,
                    data: data
                ))
            }
            let draft = ProfileCardSnapshotDraft(
                publicationID: publicationID,
                cardVersionID: cardVersionID,
                cardVersion: cardVersion,
                publishedAt: publicationDate,
                advisoryExpiresAt: usesAdvisoryExpiry ? advisoryExpiry : nil,
                retentionIntent: retentionIntent,
                fields: fieldDrafts,
                embeddedMedia: embeddedMedia
            )
            let serialized = try serializer.serialize(draft)
            let preview = try serializer.preview(from: serialized.data)

            exactPayloadBytes = serialized.data
            exactPayload = preview
            preparedCopyIsSaved = false
            isShowingPreview = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareReceivedProfile(at URL: URL) {
        let hasScopedAccess = URL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess { URL.stopAccessingSecurityScopedResource() }
        }

        do {
            let values = try URL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ReceivedProfileFileError.notRegularFile
            }
            guard (values.fileSize ?? 0) <= ReceivedProfileFileError.maximumBytes else {
                throw ReceivedProfileFileError.tooLarge
            }
            let exactPayloadBytes = try Data(contentsOf: URL, options: [.mappedIfSafe])
            guard exactPayloadBytes.count <= ReceivedProfileFileError.maximumBytes else {
                throw ReceivedProfileFileError.tooLarge
            }
            let payload = try ReceivedProfileSnapshotImportPlanner()
                .inspect(exactPayloadBytes: exactPayloadBytes)
            receivedProfileDraft = ReceivedProfileReviewDraft(
                exactPayloadBytes: exactPayloadBytes,
                payload: payload,
                originalFilename: URL.lastPathComponent
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func consumeInboundProfileIfAvailable() {
        guard receivedProfileDraft == nil,
              let URL = inboundDocuments.takeRoutedProfileURL() else { return }
        studioMode = .receive
        prepareReceivedProfile(at: URL)
    }

    private func prepareReceivedProfileQRCode(at URL: URL) {
        let hasScopedAccess = URL.startAccessingSecurityScopedResource()
        defer { if hasScopedAccess { URL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: URL, options: [.mappedIfSafe])
            guard let image = CIImage(data: data),
                  let detector = CIDetector(
                    ofType: CIDetectorTypeQRCode,
                    context: CIContext(),
                    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
                  ),
                  let message = detector.features(in: image)
                    .compactMap({ ($0 as? CIQRCodeFeature)?.messageString })
                    .first else {
                throw ProfileSnapshotQRCodeError.invalidCode
            }
            let exactPayloadBytes = try ProfileSnapshotQRCodeCodec().exactPayloadBytes(from: message)
            let payload = try serializer.deserialize(exactPayloadBytes)
            receivedProfileDraft = ReceivedProfileReviewDraft(
                exactPayloadBytes: exactPayloadBytes,
                payload: payload,
                originalFilename: String(localized: "Scanned profile QR")
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func savePreparedCopy() -> Bool {
        guard let exactPayloadBytes, let exactPayload else { return false }
        do {
            let validated = try serializer.deserialize(exactPayloadBytes)
            guard validated == exactPayload else {
                errorMessage = String(localized: "The reviewed copy changed before it could be saved.")
                return false
            }
            if let existing = canonical.profileSnapshots.first(where: {
                $0.cardVersionID == exactPayload.cardVersionID
            }), existing != exactPayload {
                errorMessage = String(localized: "That saved version already exists with different contents. Start a new version before sharing.")
                return false
            }

            canonical.lastError = nil
            canonical.saveProfileSnapshot(exactPayload)
            if let error = canonical.lastError {
                errorMessage = error
                return false
            }
            preparedCopyIsSaved = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func invalidatePublishedCopy() {
        guard exactPayloadBytes != nil || exactPayload != nil else { return }
        let wasSaved = preparedCopyIsSaved
        exactPayloadBytes = nil
        exactPayload = nil
        preparedCopyIsSaved = false
        // Editing a published card creates another immutable version in the
        // same publication lineage. A new publication identifier is reserved
        // for an explicitly new card, not an ordinary revision.
        cardVersionID = UUID()
        if wasSaved {
            cardVersion = max(
                cardVersion + 1,
                (canonical.profileSnapshots
                    .filter { $0.publicationID == publicationID }
                    .map(\.cardVersion)
                    .max() ?? cardVersion) + 1
            )
        }
    }

    private func startNewCard() {
        studioMode = .create
        exactPayloadBytes = nil
        exactPayload = nil
        preparedCopyIsSaved = false
        isShowingPreview = false
        publicationID = UUID()
        cardVersionID = UUID()
        cardVersion = 1
        usesAdvisoryExpiry = false
        advisoryExpiry = .now.addingTimeInterval(30 * 86_400)
        retentionIntent = .recipientMayRetain
        selectedPreset = .custom
        fields = ProfileStudioFieldEditor.defaults
        selectedPortraitAssetID = nil
        portraitFieldID = UUID()
    }

    private func startFirstMeetingCard() {
        studioMode = .create
        selectedPreset = .firstMeeting
        apply(.firstMeeting)
    }

    private func continueSeries(from snapshot: ProfileCardSnapshotPayload) {
        studioMode = .create
        exactPayloadBytes = nil
        exactPayload = nil
        preparedCopyIsSaved = false
        isShowingPreview = false
        publicationID = snapshot.publicationID
        cardVersionID = UUID()
        cardVersion = max(
            snapshot.cardVersion + 1,
            (canonical.profileSnapshots
                .filter { $0.publicationID == snapshot.publicationID }
                .map(\.cardVersion)
                .max() ?? snapshot.cardVersion) + 1
        )
        usesAdvisoryExpiry = snapshot.advisoryExpiresAt != nil
        if let expiry = snapshot.advisoryExpiresAt, expiry > Date.now {
            advisoryExpiry = expiry
        } else {
            advisoryExpiry = .now.addingTimeInterval(30 * 86_400)
        }
        retentionIntent = snapshot.retentionIntent
        selectedPreset = .custom
        fields = ProfileStudioFieldEditor.loading(snapshot)
        if let portrait = snapshot.fields.first(where: { $0.key == .portrait }),
           case .sanitizedMedia(let mediaID, _, _, _, _) = portrait.value,
           selfPortraits.contains(where: { $0.id == mediaID }) {
            selectedPortraitAssetID = mediaID
            portraitFieldID = portrait.id
        } else {
            selectedPortraitAssetID = nil
            portraitFieldID = UUID()
        }
    }

    private func apply(_ preset: ProfileStudioPreset) {
        guard preset != .custom else { return }
        fields = fields.map { field in
            var updated = field
            updated.isIncluded = preset.includedKeys.contains(field.key)
            updated.audience = preset.audience
            return updated
        }
    }
}

private struct SavedProfileSnapshotSelection: Identifiable {
    var snapshot: ProfileCardSnapshotPayload
    var id: UUID { snapshot.cardVersionID }
}

private struct SavedProfileSnapshotDetailView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    let snapshot: ProfileCardSnapshotPayload
    let previous: ProfileCardSnapshotPayload?
    let onContinue: () -> Void
    let onRevoke: (Bool) -> Void
    let onArchive: () -> Void

    @State private var exactBytes: Data?
    @State private var exportDocument: ProfileSnapshotFileDocument?
    @State private var isExporting = false
    @State private var isShowingQR = false
    @State private var confirmingArchive = false
    @State private var errorMessage: String?

    private var isRevoked: Bool {
        canonical.state(forProfileSnapshotID: snapshot.cardVersionID)?.isRevokedForFutureSharing == true
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Saved immutable version") {
                    LabeledContent("Card", value: profileSnapshotDisplayName(snapshot))
                    LabeledContent("Version", value: "\(snapshot.cardVersion)")
                    LabeledContent("Published", value: snapshot.publishedAt.formatted(date: .abbreviated, time: .shortened))
                    if let expiry = snapshot.advisoryExpiresAt {
                        LabeledContent(
                            "Advisory expiry",
                            value: expiry.formatted(date: .abbreviated, time: .omitted)
                        )
                        if expiry <= .now {
                            Label("Advisory expiry has passed", systemImage: "calendar.badge.exclamationmark")
                                .foregroundStyle(.orange)
                        } else {
                            Label(
                                "Advisory expiry \(expiry.formatted(.relative(presentation: .named)))",
                                systemImage: "calendar.badge.clock"
                            )
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    } else {
                        LabeledContent("Advisory expiry", value: String(localized: "None"))
                    }
                    LabeledContent(
                        "Retention request",
                        value: profileStudioRetentionTitle(snapshot.retentionIntent)
                    )
                    LabeledContent("Exact payload", value: exactBytes.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file)
                    } ?? String(localized: "Preparing…"))
                    if isRevoked {
                        Label("Revoked for future sharing on this notebook", systemImage: "nosign")
                            .foregroundStyle(.orange)
                        Text("Previously exported or received static copies cannot be recalled.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }

                ProfileSnapshotFieldsComparisonSection(
                    currentFields: snapshot.fields,
                    previousFields: previous?.fields
                )

                ProfileSnapshotShareActionsSection(
                    exactBytes: exactBytes,
                    isRevoked: isRevoked,
                    onExport: { bytes in
                        exportDocument = ProfileSnapshotFileDocument(data: bytes)
                        isExporting = true
                    },
                    onShowQR: { isShowingQR = true },
                    onContinue: {
                        onContinue()
                        dismiss()
                    }
                )

                Section("Version lifecycle") {
                    Button(isRevoked ? "Unrevoke for future sharing" : "Revoke future sharing") {
                        onRevoke(!isRevoked)
                    }
                    Button("Archive this saved version…", role: .destructive) {
                        confirmingArchive = true
                    }
                    Text("Revocation and archive state apply to this notebook only. A static file already shared remains recipient-controlled.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .navigationTitle("Saved Profile Version")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            do {
                exactBytes = try ProfileCardSnapshotSerializer().canonicalBytes(for: snapshot)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .keepsakeProfileSnapshotV1,
            defaultFilename: "Keepsake-Profile-v\(snapshot.cardVersion).keepsakeprofile"
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            exportDocument = nil
        }
        .sheet(isPresented: $isShowingQR) {
            if let exactBytes {
                ProfileSnapshotQRCodeView(exactPayloadBytes: exactBytes)
            }
        }
        .confirmationDialog("Archive this saved version?", isPresented: $confirmingArchive) {
            Button("Archive Version", role: .destructive) {
                onArchive()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The version leaves the active browser but previously shared copies are unaffected.")
        }
        .alert("Saved version needs attention", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .keepsakeSheetSize(minWidth: 540, minHeight: 680)
    }
}

private struct ProfileSnapshotShareActionsSection: View {
    let exactBytes: Data?
    let isRevoked: Bool
    let onExport: (Data) -> Void
    let onShowQR: () -> Void
    let onContinue: () -> Void

    var body: some View {
        Section("Share or export this exact version") {
            if let exactBytes, !isRevoked {
                ShareLink(
                    item: ProfileSnapshotTransfer(data: exactBytes),
                    preview: SharePreview(
                        "Keepsake profile snapshot",
                        image: Image(systemName: "person.text.rectangle")
                    )
                ) {
                    Label("Share exact profile file…", systemImage: "square.and.arrow.up")
                }
                Button {
                    onExport(exactBytes)
                } label: {
                    Label("Save exact file to Files…", systemImage: "folder")
                }
                Button(action: onShowQR) {
                    Label("Show exact-payload QR", systemImage: "qrcode")
                }
            } else if isRevoked {
                Text("Unrevoke this local version before sharing it again.")
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Button("Continue as a new version", action: onContinue)
        }
    }
}

private struct ProfileSnapshotFieldsComparisonSection: View {
    let currentFields: [ProfileCardSnapshotField]
    let previousFields: [ProfileCardSnapshotField]?

    private struct Comparison: Identifiable {
        let field: ProfileCardSnapshotField
        let previousField: ProfileCardSnapshotField?
        let hasPreviousVersion: Bool

        var id: UUID { field.id }
    }

    private var comparisons: [Comparison] {
        let previousByKey = Dictionary(
            uniqueKeysWithValues: (previousFields ?? []).map { ($0.key, $0) }
        )
        return currentFields.map { field in
            Comparison(
                field: field,
                previousField: previousByKey[field.key],
                hasPreviousVersion: previousFields != nil
            )
        }
    }

    private var removedFields: [ProfileCardSnapshotField] {
        guard let previousFields else { return [] }
        let currentKeys = Set(currentFields.map(\.key))
        return previousFields.filter { !currentKeys.contains($0.key) }
    }

    var body: some View {
        Section("Exact fields") {
            ForEach(comparisons) { comparison in
                ProfileSnapshotFieldComparisonRow(
                    field: comparison.field,
                    previousField: comparison.previousField,
                    hasPreviousVersion: comparison.hasPreviousVersion
                )
            }
            ForEach(removedFields) { removed in
                ProfileSnapshotRemovedFieldRow(field: removed)
            }
        }
    }
}

private struct ProfileSnapshotFieldComparisonRow: View {
    let field: ProfileCardSnapshotField
    let previousField: ProfileCardSnapshotField?
    let hasPreviousVersion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(profileStudioFieldTitle(field.key))
                .font(.headline)
            Text(profileStudioValueText(field.value))
                .textSelection(.enabled)
            if let previousField {
                if previousField.value == field.value {
                    Text("Unchanged from previous version")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    Text("Changed from previous version")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if hasPreviousVersion {
                Text("Added in this version")
                    .font(.caption)
                    .foregroundStyle(AppTheme.accent)
            }
        }
    }
}

private struct ProfileSnapshotRemovedFieldRow: View {
    let field: ProfileCardSnapshotField

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(profileStudioFieldTitle(field.key))
                .font(.headline)
            Text("Removed after the previous version")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct ProfileSnapshotQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    let exactPayloadBytes: Data

    private var result: Result<CGImage, Error> {
        Result {
            let message = try ProfileSnapshotQRCodeCodec().message(for: exactPayloadBytes)
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(message.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage,
                  let image = CIContext().createCGImage(output, from: output.extent) else {
                throw ProfileSnapshotQRCodeError.invalidCode
            }
            return image
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch result {
                case .success(let image):
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 420, maxHeight: 420)
                        .accessibilityLabel("QR code containing the exact profile payload")
                    Text("The code contains the exact reviewed profile bytes. The recipient still reviews every field before importing.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                case .failure(let error):
                    ContentUnavailableView(
                        "Use the profile file",
                        systemImage: "doc.badge.arrow.up",
                        description: Text(error.localizedDescription)
                    )
                }
            }
            .padding(28)
            .navigationTitle("Profile QR")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .keepsakeSheetSize(minWidth: 500, minHeight: 580)
    }
}

private struct ReceivedProfileReviewDraft: Identifiable {
    var id: UUID { payload.cardVersionID }
    let exactPayloadBytes: Data
    let payload: ProfileCardSnapshotPayload
    let originalFilename: String
}

private enum ReceivedProfileFileError: LocalizedError {
    static let maximumBytes = 7_000_000

    case notRegularFile
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notRegularFile:
            String(localized: "Choose a regular .keepsakeprofile file, not a folder or link.")
        case .tooLarge:
            String(localized: "This profile file is too large to review safely.")
        }
    }
}

private enum ReceivedProfileDestination: Hashable {
    case newPerson
    case existingPerson
}

private enum ReceivedProfileConflictDecision: String, Hashable {
    case undecided
    case importSelfAsserted
    case keepExisting
}

private struct ReceivedProfileSnapshotReviewView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss

    let draft: ReceivedProfileReviewDraft

    @State private var selectedFieldIDs: Set<UUID>
    @State private var destination = ReceivedProfileDestination.newPerson
    @State private var newPersonName: String
    @State private var newPersonID = UUID()
    @State private var existingPersonID: UUID?
    @State private var conflictDecisions: [UUID: ReceivedProfileConflictDecision] = [:]
    @State private var errorMessage: String?
    @State private var completionMessage: String?
    @State private var completionTitle = ""
    @State private var completedPersonID: UUID?

    init(draft: ReceivedProfileReviewDraft) {
        self.draft = draft
        _selectedFieldIDs = State(initialValue: Set(draft.payload.fields.map(\.id)))
        _newPersonName = State(initialValue: Self.preferredName(in: draft.payload) ?? "")
    }

    private var activePeople: [Person] {
        store.people
            .filter { $0.deletedAt == nil && !$0.isArchived }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var canImport: Bool {
        guard !effectiveSelectedFieldIDs.isEmpty,
              unresolvedConflictFieldIDs.isEmpty else { return false }
        switch destination {
        case .newPerson:
            return !newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .existingPerson:
            return existingPersonID.flatMap(store.person(id:)) != nil
        }
    }

    private var effectiveSelectedFieldIDs: Set<UUID> {
        selectedFieldIDs.filter { conflictDecisions[$0] != .keepExisting }
    }

    private var unresolvedConflictFieldIDs: Set<UUID> {
        guard destination == .existingPerson else { return [] }
        return Set(draft.payload.fields.compactMap { field in
            guard selectedFieldIDs.contains(field.id),
                  !conflictingAssertions(for: field).isEmpty,
                  conflictDecisions[field.id, default: .undecided] == .undecided else {
                return nil
            }
            return field.id
        })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let completionMessage {
                    ContentUnavailableView {
                        Label(completionTitle, systemImage: "checkmark.seal.fill")
                    } description: {
                        Text(completionMessage)
                    } actions: {
                        if let completedPersonID {
                            NavigationLink("Open person") {
                                PersonDetailView(personID: completedPersonID)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.actionFill)
                        }
                        Button("Done") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                } else {
                    reviewForm
                }
            }
            .navigationTitle("Review Shared Profile")
            .toolbar {
                if completionMessage == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import selected details") {
                            Task { await importSelectedDetails() }
                        }
                            .disabled(!canImport)
                    }
                }
            }
        }
        .keepsakeSheetSize(minWidth: 540, minHeight: 680)
        .alert("Profile import needs attention", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: destination) { _, _ in conflictDecisions = [:] }
        .onChange(of: existingPersonID) { _, _ in conflictDecisions = [:] }
    }

    private var reviewForm: some View {
        Form {
            Section {
                Label("Self-asserted, not identity-verified", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.orange)
                Text("This is a static copy created by its sender. Review the values yourself; the file does not prove who authored it.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Text("Only the details you keep selected become source-attributed facts. The original file is discarded after extraction; Keepsake retains its cryptographic fingerprint.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Section("Shared copy") {
                LabeledContent("File", value: draft.originalFilename)
                LabeledContent("Card version", value: "\(draft.payload.cardVersion)")
                LabeledContent(
                    "Published",
                    value: draft.payload.publishedAt.formatted(date: .abbreviated, time: .shortened)
                )
                if let expiry = draft.payload.advisoryExpiresAt {
                    LabeledContent("Advisory expiry", value: expiry.formatted(date: .abbreviated, time: .omitted))
                    if expiry < Date.now {
                        Label("The sender’s advisory expiry has passed. You can still review the static copy, but consider whether it should be retained.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                LabeledContent("Retention request", value: profileStudioRetentionTitle(draft.payload.retentionIntent))
            }

            Section {
                ForEach(draft.payload.fields) { field in
                    ReceivedProfileFieldReviewRow(
                        field: field,
                        embeddedMedia: draft.payload.embeddedMedia?.first {
                            $0.fieldID == field.id
                        },
                        isSelected: selectionBinding(for: field.id),
                        conflictingAssertions: conflictingAssertions(for: field),
                        matchingAssertionCount: matchingAssertionCount(for: field),
                        conflictDecision: conflictDecisionBinding(for: field.id),
                        requiresConflictDecision: destination == .existingPerson
                    )
                }
            } header: {
                Text("Details to import")
            } footer: {
                Text("These values remain self-asserted facts with their source and version history. A later card can supersede only the same sender publication field after another review.")
            }

            Section("Where should these facts go?") {
                Picker("Destination", selection: $destination) {
                    Text("Create new person").tag(ReceivedProfileDestination.newPerson)
                    if !activePeople.isEmpty {
                        Text("Choose existing person").tag(ReceivedProfileDestination.existingPerson)
                    }
                }
                .pickerStyle(.segmented)

                switch destination {
                case .newPerson:
                    TextField("Display name for the new person", text: $newPersonName)
                    Text("The display name is your reviewed local label. Shared fields are still kept separately as self-asserted facts.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                case .existingPerson:
                    Picker("Existing person", selection: $existingPersonID) {
                        Text("Choose a person").tag(nil as UUID?)
                        ForEach(activePeople) { person in
                            Text(existingPersonLabel(person)).tag(person.id as UUID?)
                        }
                    }
                }

                Label("Keepsake never guesses a match from a name.", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                if !unresolvedConflictFieldIDs.isEmpty {
                    Label(
                        "Choose Import or Keep existing for \(unresolvedConflictFieldIDs.count) conflicting field(s).",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("What this import will not change") {
                Label("Private notes and safe-to-mention context", systemImage: "lock.fill")
                Label("Manual facts, contact methods, and relationship settings", systemImage: "lock.fill")
                Text("Imported details appear under Facts & provenance. You decide separately whether any value should replace a local detail.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .formStyle(.grouped)
    }

    private func selectionBinding(for fieldID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedFieldIDs.contains(fieldID) },
            set: { isSelected in
                if isSelected {
                    selectedFieldIDs.insert(fieldID)
                } else {
                    selectedFieldIDs.remove(fieldID)
                }
            }
        )
    }

    private func conflictDecisionBinding(
        for fieldID: UUID
    ) -> Binding<ReceivedProfileConflictDecision> {
        Binding(
            get: { conflictDecisions[fieldID, default: .undecided] },
            set: { conflictDecisions[fieldID] = $0 }
        )
    }

    private func assertions(for field: ProfileCardSnapshotField) -> [AssertionEnvelope] {
        guard destination == .existingPerson, let existingPersonID else { return [] }
        let predicateID = ReceivedProfileSnapshotImportPlanner.predicateID(for: field.key)
        return canonical.assertions.filter {
            $0.subjectID == existingPersonID
                && $0.predicateID == predicateID
                && $0.reviewStatus != .rejected
        }
    }

    private func conflictingAssertions(
        for field: ProfileCardSnapshotField
    ) -> [AssertionEnvelope] {
        let incoming = ReceivedProfileSnapshotImportPlanner.typedValue(for: field.value)
        return assertions(for: field).filter { $0.value != incoming }
    }

    private func matchingAssertionCount(for field: ProfileCardSnapshotField) -> Int {
        let incoming = ReceivedProfileSnapshotImportPlanner.typedValue(for: field.value)
        return assertions(for: field).filter { $0.value == incoming }.count
    }

    @MainActor
    private func importSelectedDetails() async {
        guard canImport else { return }
        let targetID: UUID
        let targetName: String
        var personToCreate: Person?

        switch destination {
        case .newPerson:
            targetID = newPersonID
            targetName = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
            personToCreate = Person(id: targetID, displayName: targetName)
        case .existingPerson:
            guard let existingPersonID,
                  let person = store.person(id: existingPersonID) else { return }
            targetID = existingPersonID
            targetName = person.displayName
        }

        do {
            let bundle = try ReceivedProfileSnapshotImportPlanner().plan(
                exactPayloadBytes: draft.exactPayloadBytes,
                selectedFieldIDs: effectiveSelectedFieldIDs,
                subjectID: targetID,
                existingAssertions: canonical.assertions,
                existingDefinitions: canonical.attributeDefinitions,
                existingSources: canonical.sources,
                originalFilename: draft.originalFilename,
                retentionPolicy: .discardOriginalAfterExtraction,
                importedAt: .now
            )

            let portrait: SanitizedPortrait?
            if let portraitField = draft.payload.fields.first(where: {
                $0.key == .portrait && effectiveSelectedFieldIDs.contains($0.id)
            }), !bundle.alreadyImportedFieldIDs.contains(portraitField.id),
               let embedded = draft.payload.embeddedMedia?.first(where: {
                $0.fieldID == portraitField.id
            }) {
                portrait = try await PortraitMediaEnvironment.files.sanitize(
                    embedded.data,
                    personID: targetID,
                    isPrimary: canonical.portraits(for: targetID).isEmpty
                )
            } else {
                portrait = nil
            }
            let changed = try store.commitReceivedProfileSnapshot(
                bundle,
                creating: personToCreate,
                portrait: portrait
            )
            canonical.reload()
            if portrait != nil {
                _ = await canonical.reconcilePortraitCache(using: PortraitMediaEnvironment.files)
            }
            completedPersonID = targetID
            completionTitle = changed
                ? String(localized: "Profile imported")
                : String(localized: "Already imported")
            completionMessage = changed
                ? String(localized: "The reviewed profile is now attached to \(targetName). Existing manual details and private notes were left unchanged.")
                : String(localized: "Those exact profile fields were already attached to \(targetName). Nothing was duplicated.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func existingPersonLabel(_ person: Person) -> String {
        "\(person.displayName) — \(PersonChoiceDescription.detail(for: person))"
    }

    private static func preferredName(in payload: ProfileCardSnapshotPayload) -> String? {
        guard let field = payload.fields.first(where: { $0.key == .preferredName }),
              case .text(let value) = field.value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ReceivedProfileFieldReviewRow: View {
    let field: ProfileCardSnapshotField
    let embeddedMedia: ProfileSnapshotEmbeddedMedia?
    @Binding var isSelected: Bool
    let conflictingAssertions: [AssertionEnvelope]
    let matchingAssertionCount: Int
    @Binding var conflictDecision: ReceivedProfileConflictDecision
    let requiresConflictDecision: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: $isSelected) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(profileStudioFieldTitle(field.key))
                            .font(.headline)
                        Spacer()
                        Text(profileStudioAudienceTitle(field.audience))
                            .font(.caption2)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Text(profileStudioValueText(field.value))
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                }
            }
            .tint(AppTheme.accent)

            if isSelected, let embeddedMedia, field.key == .portrait {
                ProfileEmbeddedPortrait(data: embeddedMedia.data)
            }

            if isSelected, requiresConflictDecision {
                if matchingAssertionCount > 0, conflictingAssertions.isEmpty {
                    Label("Already matches an existing fact", systemImage: "equal.circle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                if !conflictingAssertions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Different value(s) already exist", systemImage: "arrow.triangle.branch")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        ForEach(conflictingAssertions.prefix(3)) { assertion in
                            LabeledContent("Existing", value: receivedProfileValueText(assertion.value))
                                .font(.caption)
                        }
                        if conflictingAssertions.count > 3 {
                            Text("And \(conflictingAssertions.count - 3) more existing value(s)")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    Picker("Conflict decision", selection: $conflictDecision) {
                        Text("Choose…").tag(ReceivedProfileConflictDecision.undecided)
                        Text("Import as self-asserted fact").tag(ReceivedProfileConflictDecision.importSelfAsserted)
                        Text("Keep existing; skip field").tag(ReceivedProfileConflictDecision.keepExisting)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private enum ProfileStudioPreset: String, CaseIterable, Identifiable {
    case firstMeeting
    case scholarship
    case professional
    case friends
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .firstMeeting: String(localized: "First meeting")
        case .scholarship: String(localized: "Scholarship")
        case .professional: String(localized: "Professional")
        case .friends: String(localized: "Friends")
        case .custom: String(localized: "Custom")
        }
    }

    var audience: ProfileSnapshotAudience {
        switch self {
        case .firstMeeting: .firstMeeting
        case .scholarship: .scholarship
        case .professional: .professional
        case .friends: .friends
        case .custom: .anyRecipient
        }
    }

    var includedKeys: Set<ShareableProfileFieldKey> {
        switch self {
        case .firstMeeting:
            [.preferredName, .pronunciation, .languages, .contactMethod, .interests, .communicationPreference]
        case .scholarship:
            [.preferredName, .pronunciation, .languages, .contactMethod, .affiliation, .cohort, .currentRole, .interests]
        case .professional:
            [.preferredName, .pronunciation, .timeZone, .contactMethod, .affiliation, .currentRole, .communicationPreference]
        case .friends:
            [.preferredName, .pronunciation, .languages, .timeZone, .contactMethod, .interests, .communicationPreference]
        case .custom:
            []
        }
    }
}

private struct ProfileSnapshotSeriesSummary: Identifiable {
    let id: UUID
    let latest: ProfileCardSnapshotPayload
    let versionCount: Int
}

private enum ProfileStudioFieldInputKind: Hashable {
    case text
    case list
    case contact
}

private struct ProfileStudioFieldEditor: Identifiable, Hashable {
    let id: UUID
    let key: ShareableProfileFieldKey
    let title: String
    let prompt: String
    let inputKind: ProfileStudioFieldInputKind
    var isIncluded: Bool
    var text: String
    var audience: ProfileSnapshotAudience
    var contactChannel: ProfileSnapshotContactChannel
    var contactLabel: String

    init(
        id: UUID = UUID(),
        key: ShareableProfileFieldKey,
        title: String,
        prompt: String,
        inputKind: ProfileStudioFieldInputKind = .text,
        isIncluded: Bool = false,
        text: String = "",
        audience: ProfileSnapshotAudience = .anyRecipient,
        contactChannel: ProfileSnapshotContactChannel = .email,
        contactLabel: String = ""
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.prompt = prompt
        self.inputKind = inputKind
        self.isIncluded = isIncluded
        self.text = text
        self.audience = audience
        self.contactChannel = contactChannel
        self.contactLabel = contactLabel
    }

    /// Each new publication receives unlinkable field identifiers. Loading an
    /// existing version intentionally preserves its IDs within that lineage.
    static var defaults: [ProfileStudioFieldEditor] { [
        .init(key: .preferredName, title: String(localized: "Preferred name"), prompt: String(localized: "How recipients should address you")),
        .init(key: .pronunciation, title: String(localized: "Pronunciation"), prompt: String(localized: "Phonetic spelling or reading")),
        .init(key: .languages, title: String(localized: "Languages"), prompt: String(localized: "Comma-separated languages"), inputKind: .list),
        .init(key: .timeZone, title: String(localized: "Time zone"), prompt: String(localized: "For example, Asia/Tokyo")),
        .init(key: .contactMethod, title: String(localized: "Contact method"), prompt: String(localized: "Address, handle, or number"), inputKind: .contact),
        .init(key: .affiliation, title: String(localized: "Affiliation"), prompt: String(localized: "Organization or community")),
        .init(key: .cohort, title: String(localized: "Cohort"), prompt: String(localized: "A cohort you choose to disclose")),
        .init(key: .currentRole, title: String(localized: "Current role"), prompt: String(localized: "A current role you choose to disclose")),
        .init(key: .interests, title: String(localized: "Interests"), prompt: String(localized: "Comma-separated interests"), inputKind: .list),
        .init(key: .communicationPreference, title: String(localized: "Communication preference"), prompt: String(localized: "For example, messages before calls"))
    ] }

    static func loading(_ snapshot: ProfileCardSnapshotPayload) -> [ProfileStudioFieldEditor] {
        var fieldsByKey: [ShareableProfileFieldKey: ProfileCardSnapshotField] = [:]
        for field in snapshot.fields where fieldsByKey[field.key] == nil {
            fieldsByKey[field.key] = field
        }
        return defaults.map { template in
            guard let snapshotField = fieldsByKey[template.key] else { return template }
            let text: String
            var contactChannel = template.contactChannel
            var contactLabel = template.contactLabel
            switch snapshotField.value {
            case .text(let value):
                text = value
            case .textList(let values):
                text = values.joined(separator: ", ")
            case .contact(let channel, let value, let label):
                text = value
                contactChannel = channel
                contactLabel = label ?? ""
            case .sanitizedMedia:
                return template
            }
            return ProfileStudioFieldEditor(
                id: snapshotField.id,
                key: template.key,
                title: template.title,
                prompt: template.prompt,
                inputKind: template.inputKind,
                isIncluded: true,
                text: text,
                audience: snapshotField.audience,
                contactChannel: contactChannel,
                contactLabel: contactLabel
            )
        }
    }

    var hasPublishableValue: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if inputKind == .list {
            return text
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return true
    }

    func snapshotValue() throws -> ProfileSnapshotFieldValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch inputKind {
        case .text:
            return .text(trimmed)
        case .list:
            let values = text
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return .textList(values)
        case .contact:
            let label = contactLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return .contact(
                channel: contactChannel,
                value: trimmed,
                label: label.isEmpty ? nil : label
            )
        }
    }
}

private struct ProfileStudioFieldRow: View {
    @Binding var field: ProfileStudioFieldEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $field.isIncluded) {
                HStack {
                    Text(field.title)
                    Spacer()
                    Text(field.isIncluded
                         ? String(localized: "Included")
                         : String(localized: "Private"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(field.isIncluded ? AppTheme.accent : AppTheme.secondaryText)
                }
            }
            .accessibilityLabel(Text(field.title))
            .accessibilityValue(Text(field.isIncluded
                                     ? String(localized: "Included")
                                     : String(localized: "Private")))
            .accessibilityHint(Text("Controls whether this field appears in the next static profile snapshot."))

            if field.isIncluded {
                if field.inputKind == .contact {
                    Picker("Channel", selection: $field.contactChannel) {
                        ForEach(ProfileSnapshotContactChannel.allCases, id: \.self) { channel in
                            Text(profileStudioContactTitle(channel)).tag(channel)
                        }
                    }
                    TextField(field.prompt, text: $field.text)
                        .textContentType(.none)
                    TextField("Optional label, such as Work", text: $field.contactLabel)
                } else {
                    TextField(field.prompt, text: $field.text, axis: .vertical)
                        .lineLimit(1...4)
                }

                Picker("Field audience", selection: $field.audience) {
                    ForEach(ProfileSnapshotAudience.allCases, id: \.self) { audience in
                        Text(profileStudioAudienceTitle(audience)).tag(audience)
                    }
                }
                Text("Audience is advisory metadata shown to the recipient; it is not access control after a static copy is shared.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct ProfileSnapshotExactPreview: View {
    @Environment(\.dismiss) private var dismiss
    let payload: ProfileCardSnapshotPayload
    let exactPayloadBytes: Data
    @Binding var isSaved: Bool
    let onSave: () -> Bool
    @State private var isShowingQR = false

    private var transfer: ProfileSnapshotTransfer {
        ProfileSnapshotTransfer(data: exactPayloadBytes)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        isSaved ? "Saved static copy" : "Nothing has been saved or shared yet",
                        systemImage: isSaved ? "checkmark.shield.fill" : "eye.fill"
                    )
                        .foregroundStyle(AppTheme.accent)
                    Text("The fields below are decoded from the exact file that will be sent. Check every value before saving this version.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Section("Publication") {
                    LabeledContent("Version", value: "\(payload.cardVersion)")
                    LabeledContent("Published", value: payload.publishedAt.formatted(date: .abbreviated, time: .shortened))
                    if let expiry = payload.advisoryExpiresAt {
                        LabeledContent("Advisory expiry", value: expiry.formatted(date: .abbreviated, time: .omitted))
                    } else {
                        LabeledContent("Advisory expiry", value: String(localized: "None"))
                    }
                    LabeledContent("Retention request", value: profileStudioRetentionTitle(payload.retentionIntent))
                    LabeledContent(
                        "Authorship",
                        value: payload.authorshipIsUnverified
                            ? String(localized: "Self-asserted, unverified")
                            : String(localized: "Verified")
                    )
                }

                Section("Exact included fields") {
                    ForEach(payload.fields) { field in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(profileStudioFieldTitle(field.key))
                                    .font(.headline)
                                Spacer()
                                Text(profileStudioAudienceTitle(field.audience))
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            Text(profileStudioValueText(field.value))
                                .textSelection(.enabled)
                            if field.key == .portrait,
                               let media = payload.embeddedMedia?.first(where: { $0.fieldID == field.id }) {
                                ProfileEmbeddedPortrait(data: media.data)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }

                Section("Exact JSON") {
                    DisclosureGroup("Inspect serialized payload") {
                        ScrollView(.horizontal) {
                            Text(String(data: exactPayloadBytes, encoding: .utf8) ?? "")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(.vertical, 8)
                        }
                    }
                }

                Section {
                    if isSaved {
                        ShareLink(
                            item: transfer,
                            preview: SharePreview(
                                "Keepsake profile snapshot v\(payload.cardVersion)",
                                image: Image(systemName: "person.text.rectangle")
                            )
                        ) {
                            Label("Share with AirDrop, Messages, Mail, or another app…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.actionFill)
                        Button {
                            isShowingQR = true
                        } label: {
                            Label("Show exact-payload QR", systemImage: "qrcode")
                        }
                    } else {
                        Button {
                            isSaved = onSave()
                        } label: {
                            Label("Save this version and enable sharing", systemImage: "checkmark.shield")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.actionFill)

                        Text("Saving keeps this reviewed version in your private profile-card store. It does not contact anyone or open the share sheet.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                } footer: {
                    Text("Sharing is a deliberate external action. The recipient receives a separate copy and no access to your private notebook.")
                }
            }
            .navigationTitle("Review Profile Copy")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .keepsakeSheetSize(minWidth: 520, minHeight: 620)
        .sheet(isPresented: $isShowingQR) {
            ProfileSnapshotQRCodeView(exactPayloadBytes: exactPayloadBytes)
        }
    }
}

private struct ProfileEmbeddedPortrait: View {
    let data: Data

    var body: some View {
        Group {
            #if os(iOS)
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            }
            #elseif os(macOS)
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            }
            #endif
        }
        .frame(maxWidth: 260, maxHeight: 260)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Shared portrait preview")
    }
}

private struct ProfileSnapshotTransfer: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .keepsakeProfileSnapshotV1) { snapshot in
            snapshot.data
        }
    }
}

private struct ProfileSnapshotFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.keepsakeProfileSnapshotV1] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension UTType {
    static let keepsakeProfileSnapshotV1 = UTType(
        exportedAs: "com.zacrotech.keepsake.profile-snapshot-v1",
        conformingTo: .json
    )
}

private func profileStudioAudienceTitle(_ audience: ProfileSnapshotAudience) -> String {
    switch audience {
    case .anyRecipient: String(localized: "Any chosen recipient")
    case .firstMeeting: String(localized: "First meeting")
    case .scholarship: String(localized: "Scholarship community")
    case .professional: String(localized: "Professional")
    case .friends: String(localized: "Friends")
    }
}

private func profileSnapshotDisplayName(_ snapshot: ProfileCardSnapshotPayload) -> String {
    guard let preferredName = snapshot.fields.first(where: { $0.key == .preferredName }),
          case .text(let value) = preferredName.value,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return String(localized: "Profile card")
    }
    return value
}

private func profileStudioContactTitle(_ channel: ProfileSnapshotContactChannel) -> String {
    switch channel {
    case .email: String(localized: "Email")
    case .messages: String(localized: "Messages")
    case .phone: String(localized: "Phone")
    case .line: String(localized: "LINE")
    case .instagram: String(localized: "Instagram")
    case .whatsapp: String(localized: "WhatsApp")
    case .snapchat: String(localized: "Snapchat")
    }
}

private func profileStudioRetentionTitle(_ intent: ProfileSnapshotRetentionIntent) -> String {
    switch intent {
    case .recipientMayRetain: String(localized: "Recipient may retain")
    case .askRecipientToDeleteAfterExpiry: String(localized: "Delete after advisory expiry requested")
    }
}

private func profileStudioRetentionExplanation(_ intent: ProfileSnapshotRetentionIntent) -> String {
    switch intent {
    case .recipientMayRetain:
        String(localized: "The snapshot says the recipient may keep their copy. It remains separate from future card versions.")
    case .askRecipientToDeleteAfterExpiry:
        String(localized: "The snapshot asks the recipient to delete their copy after the advisory expiry, but the app cannot enforce deletion on another device or retract exports.")
    }
}

private func profileStudioFieldTitle(_ key: ShareableProfileFieldKey) -> String {
    switch key {
    case .preferredName: String(localized: "Preferred name")
    case .pronunciation: String(localized: "Pronunciation")
    case .languages: String(localized: "Languages")
    case .timeZone: String(localized: "Time zone")
    case .contactMethod: String(localized: "Contact method")
    case .affiliation: String(localized: "Affiliation")
    case .cohort: String(localized: "Cohort")
    case .currentRole: String(localized: "Current role")
    case .interests: String(localized: "Interests")
    case .communicationPreference: String(localized: "Communication preference")
    case .portrait: String(localized: "Portrait")
    }
}

private func profileStudioValueText(_ value: ProfileSnapshotFieldValue) -> String {
    switch value {
    case .text(let text):
        return text
    case .textList(let values):
        return values.joined(separator: ", ")
    case .contact(let channel, let value, let label):
        return [profileStudioContactTitle(channel), label, value]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    case .sanitizedMedia(_, let contentType, _, let byteCount, let metadataStripped):
        let byteCountText = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return metadataStripped
            ? String(localized: "\(contentType) · \(byteCountText) · metadata removed")
            : String(localized: "\(contentType) · \(byteCountText) · metadata present")
    }
}

private func receivedProfileValueText(_ value: TypedValue) -> String {
    switch value {
    case .text(let text), .richText(let text): text
    case .boolean(let value): value ? String(localized: "Yes") : String(localized: "No")
    case .number(let value):
        [NSDecimalNumber(decimal: value.value).stringValue, value.unitCode]
            .compactMap { $0 }
            .joined(separator: " ")
    case .partialDate(let value): value.description
    case .dateRange(let value): "\(value.start?.description ?? "—") – \(value.end?.description ?? "—")"
    case .singleSelect(let id): String(localized: "Selection \(id.uuidString.prefix(8))")
    case .multiSelect(let ids): String(localized: "\(ids.count) selections")
    case .language(let value): value
    case .url(let value): value.absoluteString
    case .email(let value): value
    case .phone(let value): value
    case .location(let value): value.label
    case .address(let value):
        [value.street, value.locality, value.administrativeArea, value.postalCode, value.countryCode]
            .compactMap { $0 }
            .joined(separator: ", ")
    case .personReference(let id): String(localized: "Person \(id.uuidString.prefix(8))")
    case .contextReference(let id): String(localized: "Context \(id.uuidString.prefix(8))")
    case .mediaReference: String(localized: "Media")
    case .structuredJSON: String(localized: "Structured data")
    }
}
