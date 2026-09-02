import CryptoKit
import SwiftUI

@main
@MainActor
struct RelationshipNotebookApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(KeepsakeAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(KeepsakeAppDelegate.self) private var appDelegate
    #endif

    @StateObject private var appSession = AppSessionController()
    @StateObject private var lock = AppLockController()
    @StateObject private var notificationDelivery = NotificationDeliveryState.shared
    @StateObject private var inboundDocuments = InboundDocumentCoordinator()
    @AppStorage(KeepsakePreferenceKey.onboardingComplete) private var onboardingComplete = false
    @AppStorage(KeepsakePreferenceKey.appLanguage) private var appLanguage = "en"
    @AppStorage(KeepsakePreferenceKey.syncEnabled) private var syncEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var obscuringSnapshot = false

    var body: some Scene {
        WindowGroup {
            SessionHostView(
                appSession: appSession,
                lock: lock,
                onboardingComplete: $onboardingComplete
            )
            .environmentObject(appSession)
            .environmentObject(lock)
            .environmentObject(notificationDelivery)
            .environmentObject(inboundDocuments)
            .environment(\.locale, Locale(identifier: appLanguage))
            .tint(AppTheme.accent)
            .accessibilityHidden(obscuringSnapshot || (onboardingComplete && lock.isLocked))
            .task {
                await Task.detached(priority: .utility) {
                    PasswordEncryptedRelationshipVaultCodec
                        .removeStaleProtectedTemporaryFiles()
                }.value
            }
            .task {
                if let handoffStore = ShortcutPCCBridgeRuntime.store {
                    _ = try? await handoffStore.cleanupStaleRecords()
                }
            }
            .task(id: syncEnabled) {
                notificationDelivery.updateCloudSyncPreference(enabled: syncEnabled)
            }
            .onOpenURL { URL in
                if URL.scheme?.lowercased() == "keepsake",
                   URL.host?.lowercased() == "shared-capture" {
                    // The URL contains no private content. The unlocked root
                    // stages the protected App Group files for explicit review.
                    NotificationCenter.default.post(name: .sharedCaptureArrived, object: nil)
                } else {
                    inboundDocuments.enqueue(URL, source: .openURL)
                }
            }
            .overlay {
                if obscuringSnapshot { PrivacyCurtain() }
                else if onboardingComplete && lock.isLocked { AppLockView().environmentObject(lock) }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    obscuringSnapshot = false
                    notificationDelivery.retryRegistrationIfNeeded()
                    Task { await appSession.reconcileNotificationsForCurrentSession() }
                    if lock.isLocked { Task { await lock.authenticate() } }
                case .inactive:
                    obscuringSnapshot = true
                case .background:
                    lock.lockIfNeeded()
                    obscuringSnapshot = true
                @unknown default:
                    obscuringSnapshot = true
                }
            }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .commands {
            KeepsakeCommands()
        }
        #endif

        #if os(macOS)
        WindowGroup("Person", for: UUID.self) { $personID in
            AuxiliarySessionWindow(
                appSession: appSession,
                lock: lock,
                onboardingComplete: onboardingComplete
            ) {
                PersonWindowContent(personID: personID)
            }
            .environmentObject(appSession)
            .environmentObject(lock)
            .environmentObject(notificationDelivery)
            .environmentObject(inboundDocuments)
            .environment(\.locale, Locale(identifier: appLanguage))
            .tint(AppTheme.accent)
        }
        .defaultSize(width: 720, height: 760)

        Window("Import Review", id: "import-review") {
            AuxiliarySessionWindow(
                appSession: appSession,
                lock: lock,
                onboardingComplete: onboardingComplete
            ) {
                GuidedImportReviewView()
            }
            .environmentObject(appSession)
            .environmentObject(lock)
            .environmentObject(notificationDelivery)
            .environmentObject(inboundDocuments)
            .environment(\.locale, Locale(identifier: appLanguage))
            .tint(AppTheme.accent)
        }
        .defaultSize(width: 820, height: 760)

        Window("Profile Sharing", id: "profile-sharing") {
            AuxiliarySessionWindow(
                appSession: appSession,
                lock: lock,
                onboardingComplete: onboardingComplete
            ) {
                ProfileSnapshotStudioView()
            }
            .environmentObject(appSession)
            .environmentObject(lock)
            .environmentObject(notificationDelivery)
            .environmentObject(inboundDocuments)
            .environment(\.locale, Locale(identifier: appLanguage))
            .tint(AppTheme.accent)
        }
        .defaultSize(width: 820, height: 760)
        #endif
    }
}

extension Notification.Name {
    static let sharedCaptureArrived = Notification.Name("KeepsakeSharedCaptureArrived")
}

#if os(macOS)
private struct KeepsakeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Quick Open…") {
                NotificationCenter.default.post(name: .showQuickSwitcher, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command])
            Divider()
            routeButton("Today", section: .today, shortcut: "1")
            routeButton("People", section: .people, shortcut: "2")
            routeButton("Add Hub", section: .add, shortcut: "3")
        }

        CommandGroup(after: .newItem) {
            Button("Add Person…") {
                NotificationCenter.default.post(name: .showAddPerson, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Import Review Window") {
                openWindow(id: "import-review")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Open Profile Sharing Window") {
                openWindow(id: "profile-sharing")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }

    private func routeButton(
        _ title: LocalizedStringKey,
        section: AppSection,
        shortcut: KeyEquivalent
    ) -> some View {
        Button(title) {
            NotificationCenter.default.post(name: .showAppSection, object: section)
        }
        .keyboardShortcut(shortcut, modifiers: [.command])
    }
}

private struct AuxiliarySessionWindow<Content: View>: View {
    @ObservedObject var appSession: AppSessionController
    @ObservedObject var lock: AppLockController
    let onboardingComplete: Bool
    let content: Content

    init(
        appSession: AppSessionController,
        lock: AppLockController,
        onboardingComplete: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.appSession = appSession
        self.lock = lock
        self.onboardingComplete = onboardingComplete
        self.content = content()
    }

    var body: some View {
        Group {
            if !onboardingComplete {
                ContentUnavailableView(
                    "Finish setup first",
                    systemImage: "book.closed",
                    description: Text("Complete Keepsake onboarding in the main window before opening notebook records here.")
                )
            } else if lock.isLocked {
                AppLockView()
                    .environmentObject(lock)
            } else {
                switch appSession.phase {
                case .ready(let session):
                    NavigationStack { content }
                        .environmentObject(session.store)
                        .environmentObject(session.canonical)
                        .environmentObject(session.sync)
                case .loading(let message):
                    ContentUnavailableView {
                        Label("Keepsake", systemImage: "book.closed.fill")
                    } description: {
                        Text(message)
                    } actions: {
                        ProgressView()
                    }
                default:
                    ContentUnavailableView(
                        "Notebook unavailable in this window",
                        systemImage: "macwindow.badge.exclamationmark",
                        description: Text("Return to the main window to finish recovery or account review.")
                    )
                }
            }
        }
    }
}

private struct PersonWindowContent: View {
    @EnvironmentObject private var store: NotebookStore
    let personID: UUID?

    var body: some View {
        if let personID,
           let person = store.person(id: personID),
           person.deletedAt == nil {
            PersonDetailView(personID: personID)
        } else {
            ContentUnavailableView(
                "Person unavailable",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("This person may have been moved to Recently Deleted or merged.")
            )
        }
    }
}
#endif

private struct SessionHostView: View {
    @ObservedObject var appSession: AppSessionController
    @ObservedObject var lock: AppLockController
    @Environment(\.locale) private var locale
    @Binding var onboardingComplete: Bool
    @AppStorage(KeepsakePreferenceKey.syncEnabled) private var syncEnabled = false
    @State private var showingDiagnostics = false

    var body: some View {
        Group {
            switch appSession.phase {
            case .loading(let message):
                ContentUnavailableView {
                    Label("Keepsake", systemImage: "book.closed.fill")
                } description: {
                    Text(message)
                } actions: {
                    ProgressView()
                }

            case .ready(let session):
                readyContent(session)

            case .migrationReview(let review):
                CloudMigrationReviewView(review: review)

            case .accountChanged:
                CloudAccountChangedView()

            case .failed(let message):
                ContentUnavailableView {
                    Label(
                        "Notebook could not open",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                } description: {
                    VStack(spacing: 8) {
                        Text(message)
                        if appSession.hasPendingRecoveryCheckpoint {
                            Text("A protected migration checkpoint is available and can be reopened without merging notebooks silently.")
                        }
                    }
                } actions: {
                    VStack(spacing: 10) {
                        Button("Retry") { Task { await appSession.start() } }
                            .buttonStyle(.borderedProminent)
                        if appSession.hasPendingRecoveryCheckpoint {
                            Button("Review Recovery Checkpoint") {
                                Task { await appSession.reopenPendingRecoveryCheckpoint() }
                            }
                        }
                        if syncEnabled {
                            Button("Use Separate Local-Only Notebook") {
                                Task { await appSession.useLocalOnly() }
                            }
                        }
                        Button("Open Diagnostics") { showingDiagnostics = true }
                    }
                }
            }
        }
        .sheet(isPresented: $showingDiagnostics) {
            SessionFailureDiagnosticsView(
                failureMessage: currentFailureMessage,
                syncEnabled: syncEnabled,
                hasRecoveryCheckpoint: appSession.hasPendingRecoveryCheckpoint
            )
        }
        .alert("iCloud needs attention", isPresented: Binding(
            get: { appSession.operationError != nil },
            set: { if !$0 { appSession.dismissOperationError() } }
        )) {
            Button("OK") { appSession.dismissOperationError() }
        } message: {
            Text(appSession.operationError ?? "")
        }
    }

    private var currentFailureMessage: String {
        if case .failed(let message) = appSession.phase { return message }
        return String(localized: "No active notebook-open failure.", locale: locale)
    }

    @ViewBuilder
    private func readyContent(_ session: NotebookSession) -> some View {
        Group {
            if onboardingComplete {
                AdaptiveRootView()
            } else {
                OnboardingView(onComplete: { withAnimation { onboardingComplete = true } })
            }
        }
        .environmentObject(session.store)
        .environmentObject(session.canonical)
        .environmentObject(session.sync)
        .alert("Notebook needs attention", isPresented: Binding(
            get: { session.store.lastError != nil },
            set: { if !$0 { session.store.lastError = nil } }
        )) {
            Button("OK") { session.store.lastError = nil }
        } message: {
            Text(session.store.lastError ?? "")
        }
    }
}

private struct SessionFailureDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let failureMessage: String
    let syncEnabled: Bool
    let hasRecoveryCheckpoint: Bool

    private var reference: String {
        let digest = SHA256.hash(data: Data(failureMessage.utf8))
        return "OPEN-" + digest.prefix(6).map { String(format: "%02X", $0) }.joined()
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "unknown"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Privacy-safe diagnostic") {
                    LabeledContent("Reference", value: reference)
                    LabeledContent("Keepsake version", value: version)
                    LabeledContent("System", value: ProcessInfo.processInfo.operatingSystemVersionString)
                    LabeledContent(
                        "iCloud requested",
                        value: syncEnabled
                            ? String(localized: "Yes", locale: locale)
                            : String(localized: "No", locale: locale)
                    )
                    LabeledContent(
                        "Recovery checkpoint",
                        value: hasRecoveryCheckpoint
                            ? String(localized: "Available", locale: locale)
                            : String(localized: "Not available", locale: locale)
                    )
                }
                Section("Safe next steps") {
                    Text("Retry first. If a checkpoint is available, review it before any copy. Choosing the separate local-only notebook retains recovery material and does not merge or erase the iCloud replica.")
                    Text("The reference above contains no names, notes, file paths, or notebook contents. Share it with support together with the action that failed.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Notebook Diagnostics")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .keepsakeSheetSize(minWidth: 560, minHeight: 460)
    }
}

private struct CloudMigrationReviewView: View {
    @EnvironmentObject private var appSession: AppSessionController
    @State private var confirmsDeletionHistory = false
    let review: CloudMigrationReviewState

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Review before moving to iCloud", systemImage: "icloud.and.arrow.up")
                        .font(.title2.bold())
                    Text("Keepsake opened a separate account-bound iCloud replica. Nothing from the local notebook has been merged yet.")
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Section("Protected local checkpoint") {
                    inventory(review.source)
                }
                Section("Current iCloud destination") {
                    inventory(review.destination)
                    if !review.isDestinationReady {
                        Label("Waiting for the initial iCloud download before copying any local records.", systemImage: "icloud.and.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Check iCloud destination again") {
                            Task { await appSession.refreshMigrationDestination() }
                        }
                    } else if review.destination.isEmpty {
                        Text("No notebook records are currently visible in this iCloud replica. CloudKit delivery is eventual, so the copy still uses stable-ID conflict checks.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    } else {
                        Text("The destination already contains records. Only new stable IDs will be copied; every existing same-ID person, interaction, and structured record stays unchanged.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if review.source.durableDeletionTargets > 0 || review.source.wipeEpochs > 0 {
                    Section("Deletion history review") {
                        LabeledContent(
                            "Permanent deletion markers",
                            value: "\(review.source.durableDeletionTargets)"
                        )
                        LabeledContent(
                            "Whole-vault deletion generations",
                            value: "\(review.source.wipeEpochs)"
                        )
                        LabeledContent(
                            "Current iCloud records removed",
                            value: "\(review.deletionPreview.targetsToDelete.count)"
                        )
                        if review.deletionStateNeedsApplication {
                            Text("Deletion history is applied before any active records are copied. This prevents another device from restoring records that were permanently deleted.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                            Toggle(
                                "I understand that the listed iCloud records will be permanently removed",
                                isOn: $confirmsDeletionHistory
                            )
                        } else {
                            Label(
                                "The protected deletion history is already applied to this iCloud destination.",
                                systemImage: "checkmark.shield"
                            )
                            .font(.caption)
                            .foregroundStyle(.green)
                        }
                    }
                }
                if !review.generationClassification.isCompatible {
                    Section("Whole-vault deletion conflict") {
                        LabeledContent(
                            "Local records blocked from copying",
                            value: "\(review.generationClassification.conflicts.count)"
                        )
                        Label(
                            "These local records did not observe every iCloud whole-vault deletion. Copying them would resurrect deleted data, so this move is blocked and the local recovery copy remains intact.",
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .foregroundStyle(.red)
                    }
                }
                if let mediaError = review.mediaPreflightError {
                    Section("Portrait checkpoint integrity") {
                        Label(
                            "Portrait image payload validation failed. No iCloud deletion or recovery change is allowed until the protected checkpoint is rebuilt.",
                            systemImage: "photo.badge.exclamationmark"
                        )
                        .foregroundStyle(.red)
                        Text(mediaError.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                } else if review.source.media > 0 {
                    Section("Portrait checkpoint integrity") {
                        Label(
                            "All portrait metadata and image payloads passed the migration safety check.",
                            systemImage: "checkmark.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)
                    }
                }
                if review.source.recoverableDeletedRows > 0 {
                    Section("Recently Deleted migration") {
                        LabeledContent(
                            "Recoverable deleted rows",
                            value: "\(review.source.recoverableDeletedRows)"
                        )
                        if let recoverablePlan = review.recoverableDeletionPlan {
                            LabeledContent(
                                "Recoverable rows to copy",
                                value: "\(recoverablePlan.rowsToCreate.count)"
                            )
                            LabeledContent(
                                "Recoverable rows already present",
                                value: "\(recoverablePlan.unchangedKeys.count)"
                            )
                            LabeledContent(
                                "Recoverable deletion conflicts",
                                value: "\(recoverablePlan.conflictingKeys.count + recoverablePlan.blockedBySourceDurableDeletionKeys.count + recoverablePlan.blockedByDestinationDurableDeletionKeys.count)"
                            )
                            if recoverablePlan.requiresAttention {
                                Label(
                                    "A recoverable deleted record conflicts with iCloud deletion history or existing content. The move is blocked so no recoverable private payload is silently dropped.",
                                    systemImage: "exclamationmark.shield.fill"
                                )
                                .foregroundStyle(.red)
                            }
                        } else {
                            LabeledContent(
                                "Recoverable rows to copy",
                                value: "\(review.recoverableDeletionPreflight.rowsToCreate.count)"
                            )
                            LabeledContent(
                                "Recoverable rows already present",
                                value: "\(review.recoverableDeletionPreflight.unchangedKeys.count)"
                            )
                            let preflightConflictCount =
                                review.recoverableDeletionPreflight.conflictingKeys.count
                                + review.recoverableDeletionPreflight
                                    .blockedBySourceDurableDeletionKeys.count
                                + review.recoverableDeletionPreflight
                                    .blockedByDestinationDurableDeletionKeys.count
                            LabeledContent(
                                "Recoverable deletion conflicts",
                                value: "\(preflightConflictCount)"
                            )
                            if review.recoverableDeletionPreflight.requiresAttention {
                                Label(
                                    "A recoverable deleted record would still conflict after applying the deletion history. Nothing has been removed from iCloud; repair or export the local checkpoint first.",
                                    systemImage: "exclamationmark.shield.fill"
                                )
                                .foregroundStyle(.red)
                            } else {
                                Text("The post-deletion Recently Deleted copy plan passed its safety preflight. Apply the permanent deletion history, then review the exact destination again.")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                    }
                }
                Section("Reviewed copy plan") {
                    LabeledContent("New people", value: "\(review.plan.peopleToCreate.count)")
                    LabeledContent("New interactions", value: "\(review.plan.interactionsToCreate.count)")
                    LabeledContent("New structured records", value: "\(review.plan.structuredRecordsToCreate.count)")
                    LabeledContent("New preserved fields", value: "\(review.plan.preservedExtensionsToCreate.count)")
                    LabeledContent("Person updates", value: "\(review.plan.personUpdates.filter { $0.direction == .incomingIsNewer }.count)")
                    LabeledContent(
                        "Skipped existing records",
                        value: "\(review.plan.personUpdates.filter { $0.direction != .incomingIsNewer }.count + review.plan.interactionConflicts.count + review.plan.structuredRecordConflicts.count + review.plan.preservedExtensionConflicts.count)"
                    )
                    if review.hasBlockingIssues {
                        Label("Blocking identity, reference, or checkpoint integrity problems must be repaired before copying.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button(review.deletionStateNeedsApplication
                        ? "Apply deletion history and review again"
                        : "Copy reviewed records to iCloud") {
                        Task { await appSession.commitMigration() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        review.hasBlockingIssues
                            || !review.isDestinationReady
                            || (review.deletionStateNeedsApplication && !confirmsDeletionHistory)
                    )
                    Button("Cancel and keep using the local notebook", role: .cancel) {
                        Task { await appSession.cancelMigration() }
                    }
                } footer: {
                    Text("The original local database and a protected recovery checkpoint are retained. This does not claim that another device has already received the copy.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Move to iCloud")
        }
    }

    @ViewBuilder
    private func inventory(_ inventory: CloudVaultInventory) -> some View {
        LabeledContent("People", value: "\(inventory.people)")
        LabeledContent("Interactions", value: "\(inventory.interactions)")
        LabeledContent("Structured records", value: "\(inventory.structuredRecords)")
        LabeledContent("Profile snapshots", value: "\(inventory.profileSnapshots)")
        LabeledContent("Portraits", value: "\(inventory.media)")
        LabeledContent("Preserved future fields", value: "\(inventory.preservedExtensionFields)")
        LabeledContent("Permanent deletion markers", value: "\(inventory.durableDeletionTargets)")
        LabeledContent("Whole-vault deletion generations", value: "\(inventory.wipeEpochs)")
        LabeledContent("Recoverable deleted rows", value: "\(inventory.recoverableDeletedRows)")
    }
}

private struct CloudAccountChangedView: View {
    @EnvironmentObject private var appSession: AppSessionController

    var body: some View {
        ContentUnavailableView {
            Label("iCloud account changed", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text("The previous account’s notebook has been detached and retained separately. Keepsake will never open or upload it through a different Apple Account.")
        } actions: {
            VStack(spacing: 12) {
                Button("Start a separate notebook for this iCloud account") {
                    Task { await appSession.acceptNewICloudAccount() }
                }
                .buttonStyle(.borderedProminent)
                Button("Use the local-only notebook") {
                    Task { await appSession.useLocalOnly() }
                }
            }
        }
    }
}

extension Notification.Name {
    static let showAddPerson = Notification.Name("showAddPerson")
    static let showQuickSwitcher = Notification.Name("showQuickSwitcher")
    static let showAppSection = Notification.Name("showAppSection")
}
