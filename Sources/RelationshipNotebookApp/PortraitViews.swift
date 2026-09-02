import PhotosUI
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PortraitMediaEnvironment {
    static let files = PortraitMediaFileStore()
}

struct PersonPortrait: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    let person: Person
    var size: CGFloat = 46

    private var primaryAsset: PortraitMediaAsset? {
        let assets = canonical.portraits(for: person.id)
        return assets.first(where: \.isPrimary) ?? assets.first
    }

    var body: some View {
        ZStack {
            PersonAvatarPlaceholder(person: person, size: size)
            if let primaryAsset {
                PortraitThumbnail(asset: primaryAsset)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Portrait for \(person.displayName)")
    }
}

/// A first-class contact-photo affordance for person-facing screens. The
/// portrait model supports more than one image, but the primary photo is what
/// people see throughout the app.
struct ContactPhotoButton: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore

    let person: Person
    var size: CGFloat = 78
    let action: () -> Void

    private var hasPhoto: Bool {
        !canonical.portraits(for: person.id).isEmpty
    }

    private var title: String {
        hasPhoto
            ? String(localized: "Manage photos")
            : String(localized: "Add photo")
    }

    private var accessibilityTitle: String {
        hasPhoto
            ? String(localized: "Manage photos for \(person.displayName)")
            : String(localized: "Add a photo for \(person.displayName)")
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack(alignment: .bottomTrailing) {
                    PersonAvatar(person: person, size: size)
                    Image(systemName: hasPhoto ? "photo.stack.fill" : "camera.fill")
                        .font(.system(size: max(12, size * 0.17), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: max(28, size * 0.36), height: max(28, size * 0.36))
                        .background(AppTheme.actionFill, in: Circle())
                        .overlay {
                            Circle().stroke(AppTheme.pageBackground, lineWidth: 2.5)
                        }
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: max(96, size + 24))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("Opens contact photo settings.")
        .help(title)
    }
}

struct PortraitLibraryView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    let person: Person

    @State private var selectedItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var pendingRemoval: PortraitMediaAsset?
    @State private var errorMessage: String?

    private var assets: [PortraitMediaAsset] {
        canonical.portraits(for: person.id)
            .sorted {
                if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
                return $0.createdAt < $1.createdAt
            }
    }

    var body: some View {
        NavigationStack {
            Form {
                ContactPhotoAboutSection()
                ContactPhotoLibrarySection(
                    assets: assets,
                    selectedItem: $selectedItem,
                    isImporting: isImporting,
                    onMakePrimary: makePrimary,
                    onRemove: { pendingRemoval = $0 }
                )
                ContactPhotoPrivacySection()
            }
            .formStyle(.grouped)
            .navigationTitle("Photos for \(person.displayName)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                Task { await importPortrait(from: item) }
            }
            .confirmationDialog(
                "Remove this photo permanently?",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Photo", role: .destructive) {
                    guard let asset = pendingRemoval else { return }
                    pendingRemoval = nil
                    Task { await remove(asset) }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("The photo will be deleted from this notebook and synchronized devices. Other person details are unchanged.")
            }
            .alert("Photo needs attention", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .keepsakeSheetSize(minWidth: 520, minHeight: 560)
        .task(id: canonical.portraitMedia.map { "\($0.id.uuidString):\($0.sha256)" }.joined(separator: "|")) {
            _ = await canonical.reconcilePortraitCache(using: PortraitMediaEnvironment.files)
        }
    }

    @MainActor
    private func importPortrait(from item: PhotosPickerItem) async {
        isImporting = true
        defer {
            isImporting = false
            selectedItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PortraitMediaError.invalidImage
            }
            let sanitized = try await PortraitMediaEnvironment.files.sanitize(
                data,
                personID: person.id,
                isPrimary: assets.isEmpty
            )
            try await PortraitMediaEnvironment.files.store(sanitized)
            canonical.lastError = nil
            canonical.save(sanitized)
            if let error = canonical.lastError {
                try? await PortraitMediaEnvironment.files.remove(sanitized.asset)
                errorMessage = error
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makePrimary(_ selected: PortraitMediaAsset) {
        canonical.setPrimaryPortrait(selected.id, for: person.id)
    }

    @MainActor
    private func remove(_ asset: PortraitMediaAsset) async {
        do {
            let ticket = try await PortraitMediaEnvironment.files.stageRemoval(asset)
            canonical.lastError = nil
            canonical.deletePortrait(asset)
            if let error = canonical.lastError {
                try? await PortraitMediaEnvironment.files.restoreRemoval(ticket)
                errorMessage = error
                return
            }
            do {
                try await PortraitMediaEnvironment.files.finalizeRemoval(ticket)
            } catch {
                errorMessage = String(localized: "The photo was removed from the notebook, but protected file cleanup needs attention.")
            }
            if asset.isPrimary, let next = assets.first(where: { $0.id != asset.id }) {
                makePrimary(next)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ContactPhotoAboutSection: View {
    var body: some View {
        Section("About contact photos") {
            Label("A visual reminder for you", systemImage: "eye")
                .foregroundStyle(AppTheme.accent)
            Text("Contact photos appear beside this person throughout Keepsake. The app never identifies, groups, labels, or matches faces.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }
}

private struct ContactPhotoLibrarySection: View {
    let assets: [PortraitMediaAsset]
    @Binding var selectedItem: PhotosPickerItem?
    let isImporting: Bool
    let onMakePrimary: (PortraitMediaAsset) -> Void
    let onRemove: (PortraitMediaAsset) -> Void

    private var footer: String {
        assets.isEmpty
            ? String(localized: "Adding a contact photo is optional.")
            : String(localized: "The primary photo appears throughout Keepsake. Keep other photos here and make any one primary.")
    }

    var body: some View {
        Section {
            ContactPhotoLibraryContent(
                assets: assets,
                selectedItem: $selectedItem,
                isImporting: isImporting,
                onMakePrimary: onMakePrimary,
                onRemove: onRemove
            )
        } header: {
            Text("Contact photos")
        } footer: {
            Text(footer)
        }
    }
}

private struct ContactPhotoPrivacySection: View {
    var body: some View {
        Section("Privacy & sync") {
            Label("Location and camera metadata removed", systemImage: "checkmark.shield")
                .foregroundStyle(AppTheme.accent)
            Text("The original stays in your photo library. Keepsake re-rasterizes the selected image on this device and stores only a bounded, metadata-free JPEG in protected app storage.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
            Text("When iCloud sync is enabled, only that sanitized copy is mirrored to your private notebook.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }
}

private struct ContactPhotoLibraryContent: View {
    let assets: [PortraitMediaAsset]
    @Binding var selectedItem: PhotosPickerItem?
    let isImporting: Bool
    let onMakePrimary: (PortraitMediaAsset) -> Void
    let onRemove: (PortraitMediaAsset) -> Void

    var body: some View {
        if assets.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.square")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("No contact photo")
                    .font(.headline)
                Text("Choose a photo that helps you recognize this person. Initials remain visible until you add one.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    Label("Choose from Photos…", systemImage: "photo.badge.plus")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(AppTheme.actionFill, in: Capsule())
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .disabled(isImporting)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            ForEach(assets) { asset in
                ContactPhotoRow(
                    asset: asset,
                    onMakePrimary: { onMakePrimary(asset) },
                    onRemove: { onRemove(asset) }
                )
            }
            PhotosPicker(selection: $selectedItem, matching: .images) {
                Label("Add Another Photo…", systemImage: "photo.badge.plus")
            }
            .disabled(isImporting)
        }
        if isImporting {
            HStack(spacing: 10) {
                ProgressView()
                Text("Preparing photo privately on this device…")
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
    }
}

private struct ContactPhotoRow: View {
    let asset: PortraitMediaAsset
    let onMakePrimary: () -> Void
    let onRemove: () -> Void

    private var title: String {
        asset.isPrimary
            ? String(localized: "Primary photo")
            : String(localized: "Photo")
    }

    private var details: String {
        let fileSize = ByteCountFormatter.string(
            fromByteCount: asset.byteCount,
            countStyle: .file
        )
        return "\(asset.pixelWidth) × \(asset.pixelHeight) · \(fileSize)"
    }

    var body: some View {
        HStack(spacing: 14) {
            PortraitThumbnail(asset: asset)
                .portraitRetryControls()
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Label("Metadata stripped", systemImage: "checkmark.shield")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.accent)
            }
            Spacer()
            Menu {
                if !asset.isPrimary {
                    Button("Use as Primary Photo", action: onMakePrimary)
                }
                Button("Remove Photo…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Photo actions")
        }
        .padding(.vertical, 4)
    }
}

private struct PortraitThumbnail: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    let asset: PortraitMediaAsset
    @Environment(\.portraitRetryControlsEnabled) private var retryControlsEnabled
    @State private var state = PortraitThumbnailState.loading
    @State private var retryGeneration = 0

    var body: some View {
        Group {
            switch state {
            case .loading:
                ZStack {
                    Color.secondary.opacity(0.12)
                    ProgressView().controlSize(.small)
                }
                .accessibilityLabel("Loading portrait")
            case .loaded(let data):
                if let image = platformImage(data) {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    failureView
                }
            case .failed:
                failureView
            }
        }
        .clipped()
        .task(id: "\(asset.id.uuidString)-\(asset.modifiedAt.timeIntervalSinceReferenceDate)-\(retryGeneration)") {
            await loadPortrait()
        }
    }

    private var failureView: some View {
        ZStack {
            if retryControlsEnabled {
                Color.secondary.opacity(0.10)
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Button("Retry") { retryGeneration += 1 }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            } else {
                // PersonPortrait keeps its initials placeholder beneath this
                // transparent failure state.
                Color.clear
            }
        }
        .accessibilityElement(children: retryControlsEnabled ? .contain : .ignore)
        .accessibilityLabel("Portrait unavailable")
        .accessibilityHint(
            retryControlsEnabled
                ? "Retry loading, or use Photo actions to remove this photo."
                : "Open photo settings to retry or remove this photo."
        )
        .accessibilityAction(named: "Retry portrait") { retryGeneration += 1 }
        .help("Portrait could not be loaded · diagnostic \(diagnosticReference)")
    }

    @MainActor
    private func loadPortrait() async {
        state = .loading
        do {
            let data = try await canonical.portraitData(
                for: asset,
                using: PortraitMediaEnvironment.files
            )
            guard platformImage(data) != nil else {
                state = .failed
                return
            }
            state = .loaded(data)
        } catch is CancellationError {
            return
        } catch {
            state = .failed
        }
    }

    private var diagnosticReference: String {
        "PORTRAIT-\(asset.id.uuidString.prefix(8).uppercased())"
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #endif
    }
}

private enum PortraitThumbnailState {
    case loading
    case loaded(Data)
    case failed
}

private struct PortraitRetryControlsEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var portraitRetryControlsEnabled: Bool {
        get { self[PortraitRetryControlsEnabledKey.self] }
        set { self[PortraitRetryControlsEnabledKey.self] = newValue }
    }
}

private extension View {
    func portraitRetryControls() -> some View {
        environment(\.portraitRetryControlsEnabled, true)
    }
}
