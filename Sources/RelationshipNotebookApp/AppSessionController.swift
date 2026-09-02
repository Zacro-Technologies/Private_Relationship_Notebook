import CloudKit
import Combine
import CryptoKit
import Foundation
import UserNotifications

@MainActor
final class NotebookSession {
    let persistence: PersistenceController
    let store: NotebookStore
    let canonical: CanonicalVaultStore
    let sync: SyncStatusController
    let history: PersistentHistoryCoordinator
    let notificationScopeIdentifier: String

    init(
        persistence: PersistenceController,
        localOnlyReason: LocalOnlyReason = .userChoice
    ) {
        self.persistence = persistence
        let notebookStore = NotebookStore(persistence: persistence)
        let canonicalStore = CanonicalVaultStore(persistence: persistence)
        store = notebookStore
        canonical = canonicalStore
        let vaultIdentifier = switch persistence.mode {
        case .localOnly: "local-default"
        case .cloud(_, let accountBinding), .cloudOffline(_, let accountBinding):
            "cloud-\(accountBinding)"
        }
        notificationScopeIdentifier = vaultIdentifier
        let isAccountBoundOffline: Bool
        if case .cloudOffline = persistence.mode {
            isAccountBoundOffline = true
        } else {
            isAccountBoundOffline = false
        }
        let syncController = SyncStatusController(
            container: persistence.container,
            cloudContainerIdentifier: persistence.mode.cloudContainerIdentifier,
            localOnlyReason: localOnlyReason,
            persistenceScopeIdentifier: vaultIdentifier,
            initialAccountAvailability: isAccountBoundOffline ? .temporarilyUnavailable : nil,
            automaticallyRefreshAccountStatus: !isAccountBoundOffline
        )
        sync = syncController
        history = PersistentHistoryCoordinator(
            container: persistence.container,
            vaultIdentifier: vaultIdentifier
        ) { _ in
            do {
                try notebookStore.reloadAfterRemoteImportOrThrow()
                _ = try await canonicalStore.reloadAfterRemoteImportOrThrow(
                    materializingInto: PortraitMediaEnvironment.files
                )
                syncController.reportApplicationReloadSucceeded()
            } catch {
                syncController.reportApplicationReloadFailure()
                throw error
            }
        }
    }

    func reloadAfterRemoteImport() async throws {
        do {
            try store.reloadAfterRemoteImportOrThrow()
            _ = try await canonical.reloadAfterRemoteImportOrThrow(
                materializingInto: PortraitMediaEnvironment.files
            )
            sync.reportApplicationReloadSucceeded()
        } catch {
            sync.reportApplicationReloadFailure()
            throw error
        }
    }

    func close() async {
        persistence.prepareForClosing()
        await history.stopAndWait()
        persistence.closeStores()
    }
}

struct CloudMigrationReviewState {
    let session: NotebookSession
    let package: CloudVaultMigrationPackage
    let plan: ArchiveImportPlan
    let source: CloudVaultInventory
    let destination: CloudVaultInventory
    let destinationDeletionState: DurableDeletionState
    let deletionPreview: DurableDeletionApplicationPreview
    let generationClassification: CloudVaultMigrationGenerationClassification
    let mediaPreflight: CloudVaultMigrationMediaPreflight?
    let mediaPreflightError: CloudVaultMigrationError?
    let recoverableDeletionPreflight: RecoverableDeletionImportPreflight
    let recoverableDeletionPlan: RecoverableDeletionImportPlan?
    let deletionStateNeedsApplication: Bool
    let isDestinationReady: Bool

    var hasBlockingIssues: Bool {
        return plan.hasBlockingIssues
            || !generationClassification.isCompatible
            || mediaPreflight == nil
            || mediaPreflightError != nil
            || recoverableDeletionPreflight.requiresAttention
            || (recoverableDeletionPlan?.requiresAttention ?? false)
    }
}

enum ReminderNotificationReconciliationState: Equatable {
    case inactive
    case reconciling
    case notificationsDisabled
    case permissionRequired
    case ready(ConnectionNotificationReconciliationReport)
    case failed(String)
}

@MainActor
final class AppSessionController: ObservableObject {
    enum Phase {
        case loading(String)
        case ready(NotebookSession)
        case migrationReview(CloudMigrationReviewState)
        case accountChanged
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading(String(localized: "Opening your private notebook…"))
    @Published private(set) var operationError: String?
    @Published private(set) var reminderNotificationState: ReminderNotificationReconciliationState = .inactive

    private let configuration: AppConfiguration
    private let accountResolver: any CloudAccountResolving
    private let checkpointStore: CloudVaultMigrationCheckpointStore
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var generation = 0
    private var isCloudFallbackSession = false
    private var transitionSourceSession: NotebookSession?
    private var inFlightSession: NotebookSession?
    private var inFlightPersistence: PersistenceController?
    private var cloudRecoveryTask: Task<Void, Never>?
    private var notificationReconciliationTask: Task<Void, Never>?
    private var notificationPlanGeneration = 0
    private var requiresAccountChangeVerification = false
    private var accountChangeExpectedBinding: String?
    private nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []

    private enum Key {
        static let syncEnabled = "syncEnabled"
        static let cloudModeEstablished = "cloudModeEstablished"
        static let cloudAccountBinding = "cloudAccountBinding"
        static let fallbackLocalHasChanges = "cloudFallbackLocalHasChanges"
        static let accountChangeVerificationRequired = "cloudAccountChangeVerificationRequired"
        static let accountChangeExpectedBinding = "cloudAccountChangeExpectedBinding"
        static let pendingMigrationAccountBinding = "cloudPendingMigrationAccountBinding"
    }

    init(
        configuration: AppConfiguration = .bundled(),
        accountResolver: any CloudAccountResolving = SystemCloudAccountResolver(),
        checkpointStore: CloudVaultMigrationCheckpointStore = .init(),
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.configuration = configuration
        self.accountResolver = accountResolver
        self.checkpointStore = checkpointStore
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        requiresAccountChangeVerification = defaults.bool(
            forKey: Key.accountChangeVerificationRequired
        )
        accountChangeExpectedBinding = defaults.string(
            forKey: Key.accountChangeExpectedBinding
        )

        observerTokens.append(notificationCenter.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.handleAccountChange() }
        })
        observerTokens.append(notificationCenter.addObserver(
            forName: .relationshipNotebookRemoteImportCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleRemoteImport()
            }
        })
        observerTokens.append(notificationCenter.addObserver(
            forName: .relationshipNotebookLocalMutationCommitted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let configurations = notification.userInfo?[
                CloudSyncNotificationUserInfoKey.storeConfigurations
            ] as? [String]
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isCloudFallbackSession {
                    self.defaults.set(true, forKey: Key.fallbackLocalHasChanges)
                }
                guard configurations?.contains(CloudSyncStoreConfiguration.vault) != false else {
                    return
                }
                self.scheduleNotificationReconciliation()
            }
        })

        Task { @MainActor [weak self] in await self?.start() }
    }

    deinit {
        cloudRecoveryTask?.cancel()
        notificationReconciliationTask?.cancel()
        for token in observerTokens { notificationCenter.removeObserver(token) }
    }

    var activeSession: NotebookSession? {
        switch phase {
        case .ready(let session): session
        case .migrationReview(let review): review.session
        default: nil
        }
    }

    var hasPendingRecoveryCheckpoint: Bool {
        checkpointStore.hasPendingCheckpoint
    }

    func reopenPendingRecoveryCheckpoint() async {
        await start()
    }

    func start() async {
        cloudRecoveryTask?.cancel()
        cloudRecoveryTask = nil
        if transitionSourceSession == nil {
            transitionSourceSession = activeSession
        }
        generation += 1
        let currentGeneration = generation
        operationError = nil
        phase = .loading(String(localized: "Opening your private notebook…"))

        guard defaults.bool(forKey: Key.syncEnabled) else {
            await openLocal(reason: .userChoice, generation: currentGeneration)
            return
        }
        guard let containerIdentifier = configuration.cloudContainerIdentifier else {
            await openLocal(reason: .entitlementUnavailable, generation: currentGeneration)
            return
        }

        phase = .loading(String(localized: "Checking your private iCloud account…"))
        let resolution = await accountResolver.resolve(containerIdentifier: containerIdentifier)
        guard generation == currentGeneration else { return }

        switch resolution {
        case .available(let binding):
            if requiresAccountChangeVerification {
                guard let expectedBinding = accountChangeExpectedBinding,
                      expectedBinding == binding else {
                    await closeActiveSession()
                    guard generation == currentGeneration else { return }
                    phase = .accountChanged
                    return
                }
                clearAccountChangeVerification()
            }

            let established = defaults.bool(forKey: Key.cloudModeEstablished)
            if established,
               let priorBinding = defaults.string(forKey: Key.cloudAccountBinding),
               priorBinding != binding {
                requireAccountChangeVerification(for: priorBinding)
                await closeActiveSession()
                guard generation == currentGeneration else { return }
                phase = .accountChanged
                return
            }

            if checkpointStore.hasPendingCheckpoint {
                await openMigrationReview(
                    containerIdentifier: containerIdentifier,
                    accountBinding: binding,
                    generation: currentGeneration
                )
                return
            }

            if !established || defaults.bool(forKey: Key.fallbackLocalHasChanges) {
                do {
                    let package = try await makeCheckpointFromLocalVault(generation: currentGeneration)
                    guard generation == currentGeneration else { return }
                    if !package.requiresReviewedMigration {
                        defaults.set(true, forKey: Key.cloudModeEstablished)
                        defaults.set(binding, forKey: Key.cloudAccountBinding)
                        defaults.set(false, forKey: Key.fallbackLocalHasChanges)
                        await openCloud(
                            containerIdentifier: containerIdentifier,
                            accountBinding: binding,
                            generation: currentGeneration
                        )
                    } else {
                        bindPendingMigration(to: binding)
                        do {
                            try checkpointStore.savePending(package)
                        } catch {
                            if !checkpointStore.hasPendingCheckpoint {
                                clearPendingMigrationBinding()
                            }
                            throw error
                        }
                        await openMigrationReview(
                            containerIdentifier: containerIdentifier,
                            accountBinding: binding,
                            generation: currentGeneration
                        )
                    }
                } catch {
                    guard generation == currentGeneration else { return }
                    await openLocal(
                        reason: .userChoice,
                        generation: currentGeneration,
                        error: error.localizedDescription
                    )
                }
            } else {
                defaults.set(binding, forKey: Key.cloudAccountBinding)
                await openCloud(
                    containerIdentifier: containerIdentifier,
                    accountBinding: binding,
                    generation: currentGeneration
                )
            }

        case .noAccount:
            await openLocal(reason: .noAccount, generation: currentGeneration, asCloudFallback: true)
        case .temporarilyUnavailable:
            if !requiresAccountChangeVerification,
               defaults.bool(forKey: Key.cloudModeEstablished),
               let binding = defaults.string(forKey: Key.cloudAccountBinding) {
                await openCloudOffline(
                    containerIdentifier: containerIdentifier,
                    accountBinding: binding,
                    generation: currentGeneration
                )
            } else {
                await openLocal(
                    reason: .temporarilyUnavailable,
                    generation: currentGeneration,
                    asCloudFallback: true
                )
            }
        case .restricted:
            await openLocal(reason: .restricted, generation: currentGeneration, asCloudFallback: true)
        case .failed(let issue):
            let message = switch issue {
            case .network: String(localized: "iCloud could not be reached. The separate local notebook remains available.")
            case .account: String(localized: "The iCloud account could not be verified. The separate local notebook remains available.")
            case .quota: String(localized: "iCloud storage may be full. Your account-bound local replica remains safe.")
            case .service, .unknown: String(localized: "The iCloud service is temporarily unavailable. Your local notebook remains safe.")
            }
            if issue != .account,
               !requiresAccountChangeVerification,
               defaults.bool(forKey: Key.cloudModeEstablished),
               let binding = defaults.string(forKey: Key.cloudAccountBinding) {
                await openCloudOffline(
                    containerIdentifier: containerIdentifier,
                    accountBinding: binding,
                    generation: currentGeneration,
                    error: message
                )
            } else {
                await openLocal(
                    reason: issue == .account ? .noAccount : .temporarilyUnavailable,
                    generation: currentGeneration,
                    asCloudFallback: true,
                    error: message
                )
            }
        }
    }

    func beginMoveToICloud(onTransitionPrepared: () -> Void = {}) async {
        guard configuration.cloudContainerIdentifier != nil else {
            operationError = String(localized: "This build is not configured with a CloudKit container.")
            return
        }
        defaults.set(true, forKey: Key.syncEnabled)
        defaults.set(false, forKey: Key.cloudModeEstablished)
        // Publish the transition before callers persist navigation state, so
        // there is never a ready-session frame between the two screens.
        phase = .loading(String(localized: "Checking your private iCloud account…"))
        onTransitionPrepared()
        await start()
    }

    func useLocalOnly() async {
        defaults.set(false, forKey: Key.syncEnabled)
        defaults.set(false, forKey: Key.fallbackLocalHasChanges)
        if checkpointStore.hasPendingCheckpoint {
            do {
                try checkpointStore.cancelAndRetainRecovery()
            } catch {
                operationError = String(
                    localized: "The pending iCloud move could not be preserved for recovery: \(error.localizedDescription)"
                )
                return
            }
        }
        if !checkpointStore.hasPendingCheckpoint {
            clearPendingMigrationBinding()
        }
        await closeActiveSession()
        await start()
    }

    func acceptNewICloudAccount() async {
        guard let containerIdentifier = configuration.cloudContainerIdentifier else {
            operationError = String(localized: "This build is not configured with a CloudKit container.")
            return
        }
        generation += 1
        let currentGeneration = generation
        phase = .loading(String(localized: "Preparing a separate notebook for this iCloud account…"))
        let resolution = await accountResolver.resolve(containerIdentifier: containerIdentifier)
        guard generation == currentGeneration else { return }
        guard case .available(let binding) = resolution else {
            phase = .accountChanged
            operationError = String(localized: "This iCloud account is not currently available.")
            return
        }
        if checkpointStore.hasPendingCheckpoint {
            do {
                try checkpointStore.cancelAndRetainRecovery()
                clearPendingMigrationBinding()
            } catch {
                phase = .accountChanged
                operationError = error.localizedDescription
                return
            }
        }
        // The user explicitly chose a new, separately verified account here.
        clearAccountChangeVerification()
        defaults.set(true, forKey: Key.syncEnabled)
        defaults.set(true, forKey: Key.cloudModeEstablished)
        defaults.set(binding, forKey: Key.cloudAccountBinding)
        defaults.set(false, forKey: Key.fallbackLocalHasChanges)
        await openCloud(
            containerIdentifier: containerIdentifier,
            accountBinding: binding,
            generation: currentGeneration
        )
    }

    func commitMigration() async {
        guard case .migrationReview(let review) = phase else { return }
        let currentGeneration = generation
        let session = review.session
        guard activeSession === session else { return }
        inFlightSession = session
        phase = .loading(review.deletionStateNeedsApplication
            ? String(localized: "Applying reviewed deletion history…")
            : String(localized: "Copying and verifying your local notebook…"))
        do {
            try session.store.reloadAfterRemoteImportOrThrow()
            try session.canonical.reloadAfterRemoteImportOrThrow()
            let refreshedReview = try makeMigrationReview(
                session: session,
                package: review.package
            )
            guard refreshedReview.isDestinationReady else {
                inFlightSession = nil
                phase = .migrationReview(refreshedReview)
                operationError = String(localized: "The initial iCloud download is still in progress. No local records were copied; check again after it finishes.")
                return
            }
            guard Self.planFingerprint(refreshedReview.plan) == Self.planFingerprint(review.plan),
                  refreshedReview.deletionPreview == review.deletionPreview,
                  refreshedReview.generationClassification == review.generationClassification,
                  refreshedReview.mediaPreflight == review.mediaPreflight,
                  refreshedReview.mediaPreflightError == review.mediaPreflightError,
                  refreshedReview.recoverableDeletionPreflight == review.recoverableDeletionPreflight,
                  refreshedReview.recoverableDeletionPlan == review.recoverableDeletionPlan,
                  refreshedReview.deletionStateNeedsApplication == review.deletionStateNeedsApplication else {
                inFlightSession = nil
                phase = .migrationReview(refreshedReview)
                operationError = String(localized: "The iCloud destination changed while you were reviewing it. The copy plan was updated; please review it again.")
                return
            }
            guard refreshedReview.mediaPreflightError == nil,
                  let mediaPreflight = refreshedReview.mediaPreflight else {
                inFlightSession = nil
                phase = .migrationReview(refreshedReview)
                operationError = String(localized: "Portrait image payload validation failed. No iCloud deletion or recovery change was made.")
                return
            }
            guard refreshedReview.generationClassification.isCompatible else {
                inFlightSession = nil
                phase = .migrationReview(refreshedReview)
                operationError = String(localized: "One or more local records predate an iCloud whole-vault deletion and cannot be copied without resurrecting deleted data.")
                return
            }
            guard !refreshedReview.plan.hasBlockingIssues else {
                inFlightSession = nil
                phase = .migrationReview(refreshedReview)
                operationError = String(localized: "The local notebook has blocking identity or reference conflicts and was not copied.")
                return
            }
            guard !refreshedReview.recoverableDeletionPreflight.requiresAttention else {
                inFlightSession = nil
                phase = .migrationReview(refreshedReview)
                operationError = String(localized: "Recoverable deleted records conflict with this iCloud destination and were not copied.")
                return
            }
            if refreshedReview.deletionStateNeedsApplication {
                try refreshedReview.session.store.applyDurableDeletionState(
                    refreshedReview.package.durableDeletionState,
                    expectedPreview: refreshedReview.deletionPreview
                )
                try refreshedReview.session.canonical.reloadAfterRemoteImportOrThrow()
                guard generation == currentGeneration,
                      inFlightSession === session else { return }
                let updatedReview = try makeMigrationReview(
                    session: session,
                    package: refreshedReview.package
                )
                inFlightSession = nil
                operationError = nil
                phase = .migrationReview(updatedReview)
                return
            }
            guard let recoverableDeletionPlan = refreshedReview.recoverableDeletionPlan,
                  !recoverableDeletionPlan.requiresAttention else {
                inFlightSession = nil
                phase = .migrationReview(refreshedReview)
                operationError = String(localized: "Recoverable deleted records conflict with this iCloud destination and were not copied.")
                return
            }
            let recoverableRepository = RecoverableDeletionCheckpointRepository(
                persistence: refreshedReview.session.persistence
            )
            let recoverableVerification = try recoverableRepository.apply(
                recoverableDeletionPlan,
                sourceDurableState: refreshedReview.package.durableDeletionState,
                destinationDurableState: refreshedReview.destinationDeletionState
            )
            guard recoverableVerification.isVerified else {
                throw CloudVaultMigrationError.verificationFailed
            }
            let reviewedArchive = refreshedReview.plan.reviewedArchive(
                from: refreshedReview.package.archive
            )
            let selectedPortraitIDs = Set(
                (reviewedArchive.canonical?.portraitMedia ?? []).map(\.id)
            )
            let mediaPayloads = mediaPreflight.payloads(for: selectedPortraitIDs)
            guard mediaPayloads.count == selectedPortraitIDs.count else {
                throw CloudVaultMigrationError.verificationFailed
            }
            try refreshedReview.session.store.commitImportedArchive(
                reviewedArchive,
                mediaPayloads: mediaPayloads
            )
            refreshedReview.session.canonical.reload()
            _ = await refreshedReview.session.canonical.reconcilePortraitCache(
                using: PortraitMediaEnvironment.files
            )
            guard generation == currentGeneration,
                  inFlightSession === session else { return }
            let copied = try refreshedReview.session.store.exportArchive()
            guard Self.containsExactAcceptedValues(from: reviewedArchive, in: copied) else {
                throw CloudVaultMigrationError.verificationFailed
            }
            for (id, expectedData) in mediaPayloads {
                guard let asset = reviewedArchive.canonical?.portraitMedia?.first(where: { $0.id == id }),
                      try refreshedReview.session.canonical.mediaPayloads.synchronizedData(for: asset) == expectedData else {
                    throw CloudVaultMigrationError.verificationFailed
                }
            }
            guard try recoverableRepository.verify(recoverableDeletionPlan).isVerified else {
                throw CloudVaultMigrationError.verificationFailed
            }
            let copiedDeletionState = try refreshedReview.session.store
                .exportDurableDeletionState()
            guard refreshedReview.package.durableDeletionState.targets.isSubset(
                    of: copiedDeletionState.targets
                  ),
                  refreshedReview.package.durableDeletionState.wipeEpochIDs.isSubset(
                    of: copiedDeletionState.wipeEpochIDs
                  ) else {
                throw CloudVaultMigrationError.verificationFailed
            }
            try checkpointStore.markCompleted()
            clearPendingMigrationBinding()
            if case .cloud(_, let binding) = refreshedReview.session.persistence.mode {
                defaults.set(binding, forKey: Key.cloudAccountBinding)
            }
            defaults.set(true, forKey: Key.syncEnabled)
            defaults.set(true, forKey: Key.cloudModeEstablished)
            defaults.set(false, forKey: Key.fallbackLocalHasChanges)
            isCloudFallbackSession = false
            inFlightSession = nil
            phase = .ready(refreshedReview.session)
            await activateNotifications(for: refreshedReview.session)
            guard generation == currentGeneration,
                  activeSession === session else { return }
        } catch {
            guard generation == currentGeneration,
                  inFlightSession === session else { return }
            inFlightSession = nil
            operationError = error.localizedDescription
            phase = .migrationReview(review)
        }
    }

    func cancelMigration() async {
        if checkpointStore.hasPendingCheckpoint {
            do {
                try checkpointStore.cancelAndRetainRecovery()
            } catch {
                operationError = String(
                    localized: "The pending iCloud move could not be preserved for recovery: \(error.localizedDescription)"
                )
                return
            }
        }
        if !checkpointStore.hasPendingCheckpoint {
            clearPendingMigrationBinding()
        }
        defaults.set(false, forKey: Key.syncEnabled)
        defaults.set(false, forKey: Key.cloudModeEstablished)
        await closeActiveSession()
        await start()
    }

    func refreshMigrationDestination() async {
        guard case .migrationReview(let review) = phase else { return }
        let currentGeneration = generation
        let session = review.session
        do {
            try await session.history.consumePendingHistory()
            guard generation == currentGeneration,
                  activeSession === session else { return }
            try await session.reloadAfterRemoteImport()
            guard generation == currentGeneration,
                  activeSession === session,
                  case .migrationReview(let currentReview) = phase,
                  currentReview.session === session else { return }
            phase = .migrationReview(try makeMigrationReview(
                session: session,
                package: currentReview.package
            ))
        } catch {
            guard generation == currentGeneration,
                  activeSession === session else { return }
            operationError = error.localizedDescription
        }
    }

    func dismissOperationError() {
        operationError = nil
    }

    private func handleAccountChange() async {
        guard defaults.bool(forKey: Key.syncEnabled) else { return }
        if let expectedBinding = accountBindingForCurrentTransition()
            ?? defaults.string(forKey: Key.pendingMigrationAccountBinding)
            ?? defaults.string(forKey: Key.cloudAccountBinding) {
            requireAccountChangeVerification(for: expectedBinding)
        }
        // Invalidate every continuation before closing its session. In
        // particular, a migration/history continuation can resume while
        // `closeActiveSession()` is waiting for its drain to finish.
        generation += 1
        let invalidationGeneration = generation
        cloudRecoveryTask?.cancel()
        cloudRecoveryTask = nil
        await closeActiveSession()
        guard generation == invalidationGeneration else { return }
        await start()
    }

    private func handleRemoteImport() async {
        let currentGeneration = generation
        guard let session = activeSession else { return }
        do {
            try await session.reloadAfterRemoteImport()
            guard generation == currentGeneration,
                  activeSession === session else { return }
            await reconcileNotifications(for: session)
            guard case .migrationReview(let review) = phase,
                  review.session === session else { return }
            phase = .migrationReview(try makeMigrationReview(
                session: session,
                package: review.package
            ))
        } catch {
            guard generation == currentGeneration,
                  activeSession === session else { return }
            operationError = error.localizedDescription
        }
    }

    private func openLocal(
        reason: LocalOnlyReason,
        generation currentGeneration: Int,
        asCloudFallback: Bool = false,
        error: String? = nil
    ) async {
        await closeActiveSession()
        guard generation == currentGeneration else { return }
        phase = .loading(String(localized: "Opening the separate local notebook…"))
        let persistence = PersistenceController(mode: .localOnly)
        inFlightPersistence = persistence
        await persistence.waitUntilReady()
        guard generation == currentGeneration,
              inFlightPersistence === persistence else {
            closeOpeningPersistenceIfOwned(persistence)
            return
        }
        guard persistence.loadIssues.isEmpty else {
            inFlightPersistence = nil
            persistence.closeStores()
            phase = .failed(persistence.loadIssues.joined(separator: "\n"))
            return
        }
        isCloudFallbackSession = asCloudFallback
        operationError = error
        let session = NotebookSession(persistence: persistence, localOnlyReason: reason)
        inFlightPersistence = nil
        phase = .ready(session)
        await consumePendingHistoryReportingFailure(for: session)
        guard generation == currentGeneration, activeSession === session else { return }
        _ = await session.canonical.reconcilePortraitCache(using: PortraitMediaEnvironment.files)
        guard generation == currentGeneration, activeSession === session else { return }
        await activateNotifications(for: session)
        guard generation == currentGeneration, activeSession === session else { return }
        if asCloudFallback {
            if case .temporarilyUnavailable = reason {
                scheduleCloudRecovery(generation: currentGeneration)
            }
        }
    }

    private func openCloud(
        containerIdentifier: String,
        accountBinding: String,
        generation currentGeneration: Int
    ) async {
        await closeActiveSession()
        guard generation == currentGeneration else { return }
        phase = .loading(String(localized: "Opening your private iCloud notebook…"))
        let persistence = PersistenceController(mode: .cloud(
            containerIdentifier: containerIdentifier,
            accountBinding: accountBinding
        ))
        inFlightPersistence = persistence
        await persistence.waitUntilReady()
        guard generation == currentGeneration,
              inFlightPersistence === persistence else {
            closeOpeningPersistenceIfOwned(persistence)
            return
        }
        guard persistence.loadIssues.isEmpty else {
            inFlightPersistence = nil
            persistence.closeStores()
            await openCloudOffline(
                containerIdentifier: containerIdentifier,
                accountBinding: accountBinding,
                generation: currentGeneration,
                error: persistence.loadIssues.joined(separator: "\n")
            )
            return
        }
        isCloudFallbackSession = false
        let session = NotebookSession(persistence: persistence)
        inFlightPersistence = nil
        phase = .ready(session)
        await consumePendingHistoryReportingFailure(for: session)
        guard generation == currentGeneration, activeSession === session else { return }
        _ = await session.canonical.reconcilePortraitCache(using: PortraitMediaEnvironment.files)
        guard generation == currentGeneration, activeSession === session else { return }
        await activateNotifications(for: session)
        guard generation == currentGeneration, activeSession === session else { return }
    }

    /// Opens the last verified account's local replica without attaching a
    /// CloudKit mirroring delegate. Apple explicitly advises against enqueuing
    /// CloudKit work while account status is temporarily unavailable.
    private func openCloudOffline(
        containerIdentifier: String,
        accountBinding: String,
        generation currentGeneration: Int,
        error: String? = nil
    ) async {
        await closeActiveSession()
        guard generation == currentGeneration else { return }
        phase = .loading(String(localized: "Opening your private iCloud notebook…"))
        let persistence = PersistenceController(mode: .cloudOffline(
            containerIdentifier: containerIdentifier,
            accountBinding: accountBinding
        ))
        inFlightPersistence = persistence
        await persistence.waitUntilReady()
        guard generation == currentGeneration,
              inFlightPersistence === persistence else {
            closeOpeningPersistenceIfOwned(persistence)
            return
        }
        guard persistence.loadIssues.isEmpty else {
            inFlightPersistence = nil
            persistence.closeStores()
            phase = .failed(persistence.loadIssues.joined(separator: "\n"))
            return
        }
        isCloudFallbackSession = false
        operationError = error
        let session = NotebookSession(
            persistence: persistence,
            localOnlyReason: .temporarilyUnavailable
        )
        inFlightPersistence = nil
        phase = .ready(session)
        await consumePendingHistoryReportingFailure(for: session)
        guard generation == currentGeneration, activeSession === session else { return }
        _ = await session.canonical.reconcilePortraitCache(using: PortraitMediaEnvironment.files)
        guard generation == currentGeneration, activeSession === session else { return }
        await activateNotifications(for: session)
        guard generation == currentGeneration, activeSession === session else { return }
        scheduleCloudRecovery(generation: currentGeneration)
    }

    private func openMigrationReview(
        containerIdentifier: String,
        accountBinding: String,
        generation currentGeneration: Int
    ) async {
        var openedSession: NotebookSession?
        do {
            guard defaults.string(forKey: Key.pendingMigrationAccountBinding) == accountBinding else {
                if let expectedBinding = defaults.string(
                    forKey: Key.pendingMigrationAccountBinding
                ) {
                    requireAccountChangeVerification(for: expectedBinding)
                }
                await closeActiveSession()
                guard generation == currentGeneration else { return }
                phase = .accountChanged
                return
            }
            let package = try checkpointStore.loadPending()
            await closeActiveSession()
            guard generation == currentGeneration else { return }
            phase = .loading(String(localized: "Inspecting the iCloud destination without merging…"))
            let persistence = PersistenceController(mode: .cloud(
                containerIdentifier: containerIdentifier,
                accountBinding: accountBinding
            ))
            inFlightPersistence = persistence
            await persistence.waitUntilReady()
            guard generation == currentGeneration,
                  inFlightPersistence === persistence else {
                closeOpeningPersistenceIfOwned(persistence)
                return
            }
            guard persistence.loadIssues.isEmpty else {
                inFlightPersistence = nil
                persistence.closeStores()
                throw NSError(
                    domain: "Keepsake.CloudMigration",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: persistence.loadIssues.joined(separator: "\n")]
                )
            }
            let session = NotebookSession(persistence: persistence)
            openedSession = session
            inFlightSession = session
            inFlightPersistence = nil
            try await session.history.consumePendingHistory()
            guard generation == currentGeneration,
                  inFlightSession === session else { return }
            let review = try makeMigrationReview(session: session, package: package)
            guard generation == currentGeneration,
                  inFlightSession === session else { return }
            isCloudFallbackSession = false
            inFlightSession = nil
            phase = .migrationReview(review)
        } catch CloudVaultMigrationError.legacyCheckpointRequiresRebuild {
            if let openedSession, inFlightSession === openedSession {
                inFlightSession = nil
                await openedSession.close()
            }
            guard generation == currentGeneration else { return }
            await rebuildLegacyMigrationCheckpoint(
                containerIdentifier: containerIdentifier,
                accountBinding: accountBinding,
                generation: currentGeneration
            )
        } catch {
            if let openedSession, inFlightSession === openedSession {
                inFlightSession = nil
                await openedSession.close()
            }
            guard generation == currentGeneration else { return }
            defaults.set(false, forKey: Key.syncEnabled)
            await openLocal(
                reason: .userChoice,
                generation: currentGeneration,
                error: error.localizedDescription
            )
        }
    }

    private func consumePendingHistoryReportingFailure(for session: NotebookSession) async {
        do {
            try await session.history.consumePendingHistory()
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// Preserves the exact legacy bytes under a unique recovery name, then
    /// rebuilds a deletion-safe current checkpoint from the still-separate
    /// local vault. No legacy recovery package or iCloud record is overwritten.
    private func rebuildLegacyMigrationCheckpoint(
        containerIdentifier: String,
        accountBinding: String,
        generation currentGeneration: Int
    ) async {
        do {
            _ = try checkpointStore.retainLegacyPendingForRecovery()
            clearPendingMigrationBinding()
            guard generation == currentGeneration else { return }

            phase = .loading(String(localized: "Rebuilding the protected local checkpoint…"))
            let package = try await makeCheckpointFromLocalVault(
                generation: currentGeneration
            )
            guard generation == currentGeneration else { return }

            if package.requiresReviewedMigration {
                bindPendingMigration(to: accountBinding)
                do {
                    try checkpointStore.savePending(package)
                } catch {
                    if !checkpointStore.hasPendingCheckpoint {
                        clearPendingMigrationBinding()
                    }
                    throw error
                }
                await openMigrationReview(
                    containerIdentifier: containerIdentifier,
                    accountBinding: accountBinding,
                    generation: currentGeneration
                )
            } else {
                defaults.set(true, forKey: Key.cloudModeEstablished)
                defaults.set(accountBinding, forKey: Key.cloudAccountBinding)
                defaults.set(false, forKey: Key.fallbackLocalHasChanges)
                await openCloud(
                    containerIdentifier: containerIdentifier,
                    accountBinding: accountBinding,
                    generation: currentGeneration
                )
            }
        } catch {
            guard generation == currentGeneration else { return }
            defaults.set(false, forKey: Key.syncEnabled)
            await openLocal(
                reason: .userChoice,
                generation: currentGeneration,
                error: error.localizedDescription
            )
        }
    }

    private func makeCheckpointFromLocalVault(
        generation currentGeneration: Int
    ) async throws -> CloudVaultMigrationPackage {
        let localSession: NotebookSession
        if let active = transitionSourceSession,
           active.persistence.mode == .localOnly {
            localSession = active
        } else {
            await closeActiveSession()
            guard generation == currentGeneration else { throw CancellationError() }
            phase = .loading(String(localized: "Creating a protected local recovery checkpoint…"))
            let persistence = PersistenceController(mode: .localOnly)
            inFlightPersistence = persistence
            await persistence.waitUntilReady()
            guard generation == currentGeneration,
                  inFlightPersistence === persistence else {
                closeOpeningPersistenceIfOwned(persistence)
                throw CancellationError()
            }
            guard persistence.loadIssues.isEmpty else {
                inFlightPersistence = nil
                persistence.closeStores()
                throw NSError(
                    domain: "Keepsake.CloudMigration",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: persistence.loadIssues.joined(separator: "\n")]
                )
            }
            localSession = NotebookSession(persistence: persistence, localOnlyReason: .userChoice)
            inFlightPersistence = nil
        }
        // Promote the source into the tracked slot before dropping its
        // transition identity. Account changes can now gate writes and drain it
        // even while checkpoint history or portrait reads are suspended.
        inFlightSession = localSession
        if transitionSourceSession === localSession {
            transitionSourceSession = nil
        }
        defer {
            if inFlightSession === localSession {
                inFlightSession = nil
                localSession.persistence.closeStores()
            }
        }
        await localSession.history.stopAndWait()
        guard generation == currentGeneration,
              inFlightSession === localSession else { throw CancellationError() }
        let archive = try localSession.store.exportArchive()
        var media: [CloudMigrationMediaPayload] = []
        for asset in archive.canonical?.portraitMedia ?? [] {
            let data = try await localSession.canonical.portraitData(
                for: asset,
                using: PortraitMediaEnvironment.files
            )
            guard generation == currentGeneration,
                  inFlightSession === localSession else { throw CancellationError() }
            media.append(.init(asset: asset, data: data))
        }
        let durableDeletionState = try localSession.store.exportDurableDeletionState()
        let recoverableDeletions = try RecoverableDeletionCheckpointRepository(
            persistence: localSession.persistence
        ).capture(sourceDurableState: durableDeletionState)
        return CloudVaultMigrationPackage(
            archive: archive,
            media: media,
            durableDeletionState: durableDeletionState,
            recoverableDeletions: recoverableDeletions
        )
    }

    private func closeActiveSession() async {
        notificationReconciliationTask?.cancel()
        notificationReconciliationTask = nil
        notificationPlanGeneration += 1
        let active = activeSession
        let transition = transitionSourceSession
        let inFlight = inFlightSession
        let openingPersistence = inFlightPersistence
        transitionSourceSession = nil
        inFlightSession = nil
        inFlightPersistence = nil
        isCloudFallbackSession = false
        reminderNotificationState = .inactive
        phase = .loading(String(localized: "Opening your private notebook…"))
        var closed = Set<ObjectIdentifier>()
        let sessions = [active, transition, inFlight].compactMap({ $0 }).filter {
            closed.insert(ObjectIdentifier($0)).inserted
        }
        // Close every write gate before the first suspension. That prevents a
        // stale continuation from modifying a previous account's replica while
        // notification/history teardown is still draining.
        for session in sessions {
            session.persistence.prepareForClosing()
        }
        openingPersistence?.prepareForClosing()
        await ConnectionNotificationScheduler.shared.deactivateScope()
        for session in sessions {
            await session.close()
        }
        if let openingPersistence {
            await openingPersistence.waitUntilReady()
            openingPersistence.closeStores()
        }
    }

    private func closeOpeningPersistenceIfOwned(_ persistence: PersistenceController) {
        guard inFlightPersistence === persistence else { return }
        inFlightPersistence = nil
        persistence.closeStores()
    }

    private func accountBindingForCurrentTransition() -> String? {
        if let inFlightPersistence {
            switch inFlightPersistence.mode {
            case .cloud(_, let binding), .cloudOffline(_, let binding):
                return binding
            case .localOnly:
                break
            }
        }
        for session in [activeSession, inFlightSession, transitionSourceSession].compactMap({ $0 }) {
            switch session.persistence.mode {
            case .cloud(_, let binding), .cloudOffline(_, let binding):
                return binding
            case .localOnly:
                continue
            }
        }
        return nil
    }

    private func requireAccountChangeVerification(for expectedBinding: String) {
        requiresAccountChangeVerification = true
        accountChangeExpectedBinding = expectedBinding
        defaults.set(true, forKey: Key.accountChangeVerificationRequired)
        defaults.set(expectedBinding, forKey: Key.accountChangeExpectedBinding)
    }

    private func clearAccountChangeVerification() {
        requiresAccountChangeVerification = false
        accountChangeExpectedBinding = nil
        defaults.set(false, forKey: Key.accountChangeVerificationRequired)
        defaults.removeObject(forKey: Key.accountChangeExpectedBinding)
    }

    private func bindPendingMigration(to accountBinding: String) {
        defaults.set(accountBinding, forKey: Key.pendingMigrationAccountBinding)
    }

    private func clearPendingMigrationBinding() {
        defaults.removeObject(forKey: Key.pendingMigrationAccountBinding)
    }

    func notificationScope(for canonicalStore: CanonicalVaultStore) -> String? {
        guard let session = activeSession,
              session.canonical === canonicalStore else { return nil }
        return session.notificationScopeIdentifier
    }

    func reconcileNotificationsForCurrentSession() async {
        guard let session = activeSession else { return }
        await reconcileNotifications(for: session)
    }

    private func scheduleNotificationReconciliation() {
        notificationReconciliationTask?.cancel()
        notificationReconciliationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.reconcileNotificationsForCurrentSession()
        }
    }

    private func activateNotifications(for session: NotebookSession) async {
        let scheduler = ConnectionNotificationScheduler.shared
        let scope = session.notificationScopeIdentifier
        await scheduler.activateScope(scope)
        await reconcileNotifications(for: session)
    }

    private func reconcileNotifications(for session: NotebookSession) async {
        let scheduler = ConnectionNotificationScheduler.shared
        let scope = session.notificationScopeIdentifier
        notificationPlanGeneration += 1
        let planningGeneration = notificationPlanGeneration
        let sessionGeneration = generation
        reminderNotificationState = .reconciling
        guard defaults.bool(forKey: "remindersEnabled") else {
            defaults.removeObject(forKey: NudgeNotificationStorage.planningStateKey(
                scopeIdentifier: scope
            ))
            await scheduler.cancelAll()
            guard notificationPlanGeneration == planningGeneration,
                  generation == sessionGeneration,
                  activeSession === session else { return }
            reminderNotificationState = .notificationsDisabled
            return
        }
        let authorizationStatus = await scheduler.authorizationStatus()
        guard notificationPlanGeneration == planningGeneration,
              generation == sessionGeneration,
              activeSession === session else { return }
        guard Self.notificationsAreAuthorized(authorizationStatus) else {
            await scheduler.cancelAll()
            guard notificationPlanGeneration == planningGeneration,
                  generation == sessionGeneration,
                  activeSession === session else { return }
            reminderNotificationState = .permissionRequired
            return
        }
        let quietStart = defaults.object(forKey: "quietHoursStart") == nil
            ? 22.0
            : defaults.double(forKey: "quietHoursStart")
        let quietEnd = defaults.object(forKey: "quietHoursEnd") == nil
            ? 8.0
            : defaults.double(forKey: "quietHoursEnd")
        let explicitSchedules = makeScheduledConnectionReminders(
            reminders: session.canonical.reminders,
            people: session.store.people,
            quietHoursStart: quietStart,
            quietHoursEnd: quietEnd
        )
        let proactiveSchedules: [ScheduledConnectionReminder]
        do {
            proactiveSchedules = try await proactiveNudgeSchedules(
                for: session,
                scopeIdentifier: scope,
                quietHoursStart: quietStart,
                quietHoursEnd: quietEnd
            )
        } catch {
            guard notificationPlanGeneration == planningGeneration,
                  generation == sessionGeneration,
                  activeSession === session else { return }
            reminderNotificationState = .failed(
                String(localized: "Notifications could not be scheduled. Try again from Settings.")
            )
            return
        }
        guard notificationPlanGeneration == planningGeneration,
              generation == sessionGeneration,
              activeSession === session else { return }
        do {
            let report = try await scheduler.reconcile(
                explicitSchedules + proactiveSchedules,
                privacy: .init(
                    showPersonNames: defaults.bool(forKey: "showNamesInNotifications"),
                    showContext: false
                ),
                scopeIdentifier: scope
            )
            guard notificationPlanGeneration == planningGeneration,
                  generation == sessionGeneration,
                  activeSession === session else { return }
            reminderNotificationState = .ready(report)
        } catch {
            guard notificationPlanGeneration == planningGeneration,
                  generation == sessionGeneration,
                  activeSession === session else { return }
            reminderNotificationState = .failed(
                String(localized: "Notifications could not be scheduled. Try again from Settings.")
            )
        }
    }

    private static func notificationsAreAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        @unknown default:
            false
        }
    }

    private func proactiveNudgeSchedules(
        for session: NotebookSession,
        scopeIdentifier: String,
        quietHoursStart: Double,
        quietHoursEnd: Double
    ) async throws -> [ScheduledConnectionReminder] {
        let historyKey = NudgeNotificationStorage.suggestionHistoryKey(
            scopeIdentifier: scopeIdentifier
        )
        let legacyHistory = scopeIdentifier == "local-default"
            ? defaults.data(forKey: "nudgeSuggestionHistory.v1")
            : nil
        let historyData = defaults.data(forKey: historyKey) ?? legacyHistory
        var history = historyData.flatMap {
            try? JSONDecoder().decode(NudgeSuggestionHistory.self, from: $0)
        } ?? NudgeSuggestionHistory()
        history.prune(before: Date.now.addingTimeInterval(-14 * 86_400))
        defaults.set(try JSONEncoder().encode(history), forKey: historyKey)

        let allPeople = session.store.people
        let availableContexts = Array(Set(allPeople.flatMap(\.contexts)))
        let selection = NudgePoolSelection(
            storageValue: defaults.string(forKey: NudgeNotificationStorage.poolSelectionKey(
                scopeIdentifier: scopeIdentifier
            )),
            availableContexts: availableContexts
        )
        let candidatePeople: [Person]
        let pool: NudgePool
        switch selection {
        case .everyone:
            candidatePeople = allPeople
            pool = NudgePool()
        case let .circle(circle):
            candidatePeople = allPeople
            pool = NudgePool(name: circle.localizedTitle, circles: [circle])
        case let .context(context):
            candidatePeople = allPeople
            pool = NudgePool(name: context, contextNames: [context])
        case let .savedView(savedViewID):
            guard let savedView = session.canonical.savedViews.first(where: {
                $0.id == savedViewID && $0.isEligibleNudgePool
            }) else {
                return try persistProactiveNudgePlan(
                    policy: NudgePolicy(frequency: .off),
                    scopeIdentifier: scopeIdentifier,
                    history: history
                )
            }
            let allowedIDs = try await NudgeSavedViewPoolResolver().personIDs(
                in: savedView,
                people: allPeople,
                canonical: session.canonical.archivePayload,
                localeIdentifier: Locale.current.identifier
            )
            candidatePeople = allPeople.filter { allowedIDs.contains($0.id) }
            pool = NudgePool(name: savedView.name)
        }

        var policy = NudgePolicy(
            frequency: NudgeFrequency(rawValue: defaults.string(forKey: "nudgeFrequency") ?? "")
                ?? .twiceWeekly,
            effort: EffortLevel(rawValue: defaults.string(forKey: "effortLevel") ?? "")
                ?? .light,
            pool: pool,
            cooldownDays: 14,
            quietStartHour: Int(quietHoursStart),
            quietEndHour: Int(quietHoursEnd),
            customFrequencyPerWeek: defaults.object(forKey: "customNudgesPerWeek") == nil
                ? 2
                : defaults.integer(forKey: "customNudgesPerWeek")
        )
        let eligibility = NudgeEngine().eligibilityReport(
            for: candidatePeople,
            policy: policy,
            recentSuggestions: history.recentSuggestionByPerson
        )
        if eligibility.eligibleIDs.isEmpty {
            policy.frequency = .off
        }
        return try persistProactiveNudgePlan(
            policy: policy,
            scopeIdentifier: scopeIdentifier,
            history: history
        )
    }

    private func persistProactiveNudgePlan(
        policy: NudgePolicy,
        scopeIdentifier: String,
        history: NudgeSuggestionHistory
    ) throws -> [ScheduledConnectionReminder] {
        let stateKey = NudgeNotificationStorage.planningStateKey(
            scopeIdentifier: scopeIdentifier
        )
        let existingState = defaults.data(forKey: stateKey).flatMap {
            try? JSONDecoder().decode(
                ProactiveNudgeNotificationPlanningState.self,
                from: $0
            )
        } ?? ProactiveNudgeNotificationPlanningState()
        let state = ProactiveNudgeNotificationPlanner().plan(
            policy: policy,
            scopeIdentifier: scopeIdentifier,
            suggestionHistory: history,
            existingState: existingState
        )
        defaults.set(try JSONEncoder().encode(state), forKey: stateKey)
        return state.scheduledReminders()
    }

    /// Account-status lookups can fail while a device is offline. The app opens
    /// the last verified account's replica without a mirroring delegate in that
    /// state, then revalidates periodically so queued edits resume syncing
    /// without requiring a manual Settings action. Mirroring is reattached only
    /// after the account resolver can verify the current Apple Account again.
    private func scheduleCloudRecovery(generation expectedGeneration: Int) {
        guard defaults.bool(forKey: Key.syncEnabled),
              configuration.cloudContainerIdentifier != nil else { return }
        cloudRecoveryTask?.cancel()
        cloudRecoveryTask = Task { @MainActor [weak self] in
            let retryDelays = [15, 30, 60]
            var attempt = 0
            while !Task.isCancelled {
                let seconds = retryDelays[min(attempt, retryDelays.count - 1)]
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.generation == expectedGeneration,
                      let containerIdentifier = self.configuration.cloudContainerIdentifier else {
                    return
                }
                let resolution = await self.accountResolver.resolve(
                    containerIdentifier: containerIdentifier
                )
                guard !Task.isCancelled,
                      self.generation == expectedGeneration else { return }
                switch resolution {
                case .temporarilyUnavailable,
                     .failed(.network),
                     .failed(.service),
                     .failed(.quota),
                     .failed(.unknown):
                    attempt += 1
                case .available, .noAccount, .restricted, .failed(.account):
                    await self.start()
                    return
                }
            }
        }
    }

    private func makeMigrationReview(
        session: NotebookSession,
        package: CloudVaultMigrationPackage
    ) throws -> CloudMigrationReviewState {
        try NotebookStore.validateDurableDeletionState(
            package.durableDeletionState,
            for: package.archive
        )
        let mediaValidation: (
            preflight: CloudVaultMigrationMediaPreflight?,
            error: CloudVaultMigrationError?
        )
        do {
            mediaValidation = (try package.preflightMediaPayloads(), nil)
        } catch let error as CloudVaultMigrationError {
            mediaValidation = (nil, error)
        } catch {
            throw error
        }
        let destination = try session.store.inspectMigrationDestination()
        let destinationDeletionState = try session.store.exportDurableDeletionState()
        let recoverableRepository = RecoverableDeletionCheckpointRepository(
            persistence: session.persistence
        )
        let destinationRecoverableDeletions = try recoverableRepository.capture(
            sourceDurableState: destinationDeletionState
        )
        let deletionPreview = try session.store.previewApplyingDurableDeletionState(
            package.durableDeletionState
        )
        let generationClassification = try CloudVaultMigrationGenerationGate.classify(
            archive: package.archive,
            sourceDeletionState: package.durableDeletionState,
            destinationDeletionState: destinationDeletionState
        )
        let deletionStateNeedsApplication =
            !package.durableDeletionState.targets.isSubset(of: destinationDeletionState.targets)
            || !package.durableDeletionState.wipeEpochIDs.isSubset(
                of: destinationDeletionState.wipeEpochIDs
            )
        let projectedDestinationDeletionState = DurableDeletionState(
            targets: destinationDeletionState.targets
                .union(package.durableDeletionState.targets)
                .union(deletionPreview.targetsToDelete),
            wipeEpochIDs: destinationDeletionState.wipeEpochIDs
                .union(package.durableDeletionState.wipeEpochIDs),
            generationMemberships: Set(
                destinationDeletionState.generationMemberships.filter {
                    !deletionPreview.targetsToDelete.contains($0.target)
                }
            )
        )
        let recoverableDeletionPreflight = try recoverableRepository.preflightImport(
            package.recoverableDeletions,
            sourceDurableState: package.durableDeletionState,
            projectedDestinationDurableState: projectedDestinationDeletionState,
            removingDestinationTargets: deletionPreview.targetsToDelete
        )
        let recoverableDeletionPlan = deletionStateNeedsApplication
            ? nil
            : try recoverableRepository.planImport(
                package.recoverableDeletions,
                sourceDurableState: package.durableDeletionState,
                destinationDurableState: destinationDeletionState
            )
        let planningArchive: NotebookArchive
        let planningTombstones: ArchiveTombstoneInventory
        let recoverableReferenceClosure: RecoverableDeletionReferenceClosure
        if deletionStateNeedsApplication {
            planningArchive = try deletionPreview.projectedArchive()
            planningTombstones = Self.projecting(
                destination.tombstones,
                adding: projectedDestinationDeletionState.targets
            )
            recoverableReferenceClosure = RecoverableDeletionReferenceClosure(
                destination: RecoverableDeletionCheckpoint(rows:
                    destinationRecoverableDeletions.rows.filter {
                        !deletionPreview.targetsToDelete.contains(
                            $0.key.durableDeletionTarget
                        )
                    }
                ),
                acceptedSourceRows: recoverableDeletionPreflight.acceptedSourceRows
            )
        } else {
            planningArchive = destination.archive
            planningTombstones = destination.tombstones
            recoverableReferenceClosure = RecoverableDeletionReferenceClosure(
                destination: destinationRecoverableDeletions,
                sourcePlan: recoverableDeletionPlan
            )
        }
        let archiveData = try ArchiveCodec.encode(package.archive)
        var plan = try ArchiveImportPlanner().inspect(
            archiveData,
            existingPeople: planningArchive.people,
            existingInteractions: planningArchive.interactions,
            existingCanonical: recoverableReferenceClosure.merging(
                into: planningArchive.canonical
            ),
            existingOwnedProfileSnapshots: planningArchive.ownedProfileSnapshots ?? [],
            existingPreservedExtensions: planningArchive.preservedExtensions ?? [:],
            verifiedPortraitMediaIDs: mediaValidation.preflight?
                .verifiedPortraitMediaIDs ?? [],
            existingTombstones: planningTombstones,
            additionalAvailablePersonIDs: recoverableReferenceClosure.personIDs,
            additionalAvailableInteractionIDs: recoverableReferenceClosure.interactionIDs,
            acceptIncomingPersonUpdates: false
        )
        if let mediaError = mediaValidation.error {
            let issueCode: ArchiveImportIssueCode = switch mediaError {
            case .duplicateMediaPayload, .duplicatePortraitMetadata:
                .duplicateStableIdentifier
            case .missingMediaPayload,
                 .orphanMediaPayload,
                 .mediaAssetMismatch,
                 .invalidMediaPayload:
                .missingMediaPayload
            default:
                .missingMediaPayload
            }
            plan.issues.append(ArchiveImportIssue(
                id: UUID(),
                severity: .blocking,
                code: issueCode,
                path: "checkpoint.media",
                message: mediaError.localizedDescription
            ))
        }
        let extensionsTarget = DurableDeletionTarget.vaultRecord(
            id: CloudVaultMigrationGenerationGate.archiveExtensionsRecordID,
            kind: "archiveExtensions"
        )
        if package.archive.preservedExtensions?.isEmpty == false,
           projectedDestinationDeletionState.targets.contains(extensionsTarget) {
            plan.issues.append(ArchiveImportIssue(
                id: UUID(),
                severity: .blocking,
                code: .editDeleteConflict,
                path: "$.preservedExtensions",
                message: String(localized: "The destination contains a deletion tombstone for this stable identifier. The incoming active record will not restore it without explicit edit-versus-delete review.")
            ))
        }
        return .init(
            session: session,
            package: package,
            plan: plan,
            source: .init(
                archive: package.archive,
                durableDeletionState: package.durableDeletionState,
                recoverableDeletions: package.recoverableDeletions
            ),
            destination: .init(
                archive: destination.archive,
                durableDeletionState: destinationDeletionState,
                recoverableDeletions: destinationRecoverableDeletions
            ),
            destinationDeletionState: destinationDeletionState,
            deletionPreview: deletionPreview,
            generationClassification: generationClassification,
            mediaPreflight: mediaValidation.preflight,
            mediaPreflightError: mediaValidation.error,
            recoverableDeletionPreflight: recoverableDeletionPreflight,
            recoverableDeletionPlan: recoverableDeletionPlan,
            deletionStateNeedsApplication: deletionStateNeedsApplication,
            isDestinationReady: (try? session.persistence.cloudMigrationReadiness().isReady) ?? false
        )
    }

    private static func projecting(
        _ inventory: ArchiveTombstoneInventory,
        adding targets: Set<DurableDeletionTarget>
    ) -> ArchiveTombstoneInventory {
        var result = inventory
        for target in targets {
            switch target.family {
            case .person:
                result.personIDs.insert(target.id)
            case .interaction:
                result.interactionIDs.insert(target.id)
            case .vaultRecord(let kind):
                guard let family = ArchiveStructuredRecordFamily(rawValue: kind) else {
                    continue
                }
                result.structuredRecordIDs.insert(.init(
                    family: family,
                    id: target.id
                ))
            case .ownedProfileRecord(let kind) where kind == "profileSnapshot":
                result.structuredRecordIDs.insert(.init(
                    family: .profileSnapshot,
                    id: target.id
                ))
            case .ownedProfileRecord:
                continue
            }
        }
        return result
    }

    private static func planFingerprint(_ plan: ArchiveImportPlan) -> [String] {
        let people = plan.peopleToCreate.map { "person:\($0.id.uuidString)" }
        let updates = plan.personUpdates.map {
            "person-update:\($0.id.uuidString):\($0.direction.rawValue):"
                + "\(fingerprintDigest($0.existing)):\(fingerprintDigest($0.incoming))"
        }
        let interactions = plan.interactionsToCreate.map { "interaction:\($0.id.uuidString)" }
        let interactionConflicts = plan.interactionConflicts.map {
            "interaction-conflict:\($0.id.uuidString)"
        }
        let structured = plan.structuredRecordsToCreate.map {
            "structured:\($0.family.rawValue):\($0.id.uuidString)"
        }
        let structuredConflicts = plan.structuredRecordConflicts.map {
            "structured-conflict:\($0.family.rawValue):\($0.id.uuidString)"
        }
        let preservedExtensions = plan.preservedExtensionsToCreate.map {
            "preserved-extension:\($0.key):\(fingerprintDigest($0.value))"
        }
        let unchangedPreservedExtensions = plan.unchangedPreservedExtensionKeys.map {
            "preserved-extension-unchanged:\($0)"
        }
        let preservedExtensionConflicts = plan.preservedExtensionConflicts.map {
            "preserved-extension-conflict:\($0.key):"
                + "\(fingerprintDigest($0.existing)):\(fingerprintDigest($0.incoming))"
        }
        let tombstonedPeople = plan.tombstoneConflicts.personIDs.map {
            "tombstone:person:\($0.uuidString)"
        }
        let tombstonedInteractions = plan.tombstoneConflicts.interactionIDs.map {
            "tombstone:interaction:\($0.uuidString)"
        }
        let tombstonedStructuredRecords = plan.tombstoneConflicts.structuredRecordIDs.map {
            "tombstone:structured:\($0.family.rawValue):\($0.id.uuidString)"
        }
        let issues = plan.issues.map { "issue:\($0.code.rawValue):\($0.path)" }
        return (
            people + updates + interactions + interactionConflicts + structured
                + structuredConflicts + preservedExtensions + unchangedPreservedExtensions
                + preservedExtensionConflicts + tombstonedPeople + tombstonedInteractions
                + tombstonedStructuredRecords + issues
        )
            .sorted()
    }

    private static func fingerprintDigest<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else {
            return "encoding-failed-\(String(reflecting: Value.self))"
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func containsExactAcceptedValues(
        from source: NotebookArchive,
        in destination: NotebookArchive
    ) -> Bool {
        guard containsExact(source.people, in: destination.people, identifiedBy: \.id),
              containsExact(source.interactions, in: destination.interactions, identifiedBy: \.id),
              source.preservedExtensions?.allSatisfy({ destination.preservedExtensions?[$0.key] == $0.value }) ?? true else {
            return false
        }
        let sourceCanonical = source.canonical ?? CanonicalArchivePayload()
        let destinationCanonical = destination.canonical ?? CanonicalArchivePayload()
        return containsExact(sourceCanonical.contexts, in: destinationCanonical.contexts, identifiedBy: \.id)
            && containsExact(sourceCanonical.cohortSchemes, in: destinationCanonical.cohortSchemes, identifiedBy: \.id)
            && containsExact(sourceCanonical.cohorts, in: destinationCanonical.cohorts, identifiedBy: \.id)
            && containsExact(sourceCanonical.memberships, in: destinationCanonical.memberships, identifiedBy: \.id)
            && containsExact(sourceCanonical.cohortAssignments, in: destinationCanonical.cohortAssignments, identifiedBy: \.id)
            && containsExact(sourceCanonical.roleDefinitions, in: destinationCanonical.roleDefinitions, identifiedBy: \.id)
            && containsExact(sourceCanonical.roleAssignments, in: destinationCanonical.roleAssignments, identifiedBy: \.id)
            && containsExact(sourceCanonical.education, in: destinationCanonical.education, identifiedBy: \.id)
            && containsExact(sourceCanonical.assertions, in: destinationCanonical.assertions, identifiedBy: \.id)
            && containsExact(sourceCanonical.sources, in: destinationCanonical.sources, identifiedBy: \.id)
            && containsExact(sourceCanonical.artifactUnits ?? [], in: destinationCanonical.artifactUnits ?? [], identifiedBy: \.id)
            && containsExact(sourceCanonical.portraitMedia ?? [], in: destinationCanonical.portraitMedia ?? [], identifiedBy: \.id)
            && containsExact(sourceCanonical.evidence, in: destinationCanonical.evidence, identifiedBy: \.id)
            && containsExact(sourceCanonical.reminders, in: destinationCanonical.reminders, identifiedBy: \.id)
            && containsExact(sourceCanonical.commitments, in: destinationCanonical.commitments, identifiedBy: \.id)
            && containsExact(sourceCanonical.savedViews, in: destinationCanonical.savedViews, identifiedBy: \.id)
            && containsExact(sourceCanonical.attributeDefinitions, in: destinationCanonical.attributeDefinitions, identifiedBy: \.id)
            && containsExact(sourceCanonical.textImportReviews, in: destinationCanonical.textImportReviews, identifiedBy: { $0.source.id })
            && containsExact(sourceCanonical.personMergeEvents, in: destinationCanonical.personMergeEvents, identifiedBy: \.id)
            && containsExact(
                source.ownedProfileSnapshots ?? [],
                in: destination.ownedProfileSnapshots ?? [],
                identifiedBy: \.cardVersionID
            )
    }

    private static func containsExact<Value: Equatable>(
        _ source: [Value],
        in destination: [Value],
        identifiedBy identifier: (Value) -> UUID
    ) -> Bool {
        let grouped = Dictionary(grouping: destination, by: identifier)
        return source.allSatisfy { value in
            guard let matches = grouped[identifier(value)], matches.count == 1 else { return false }
            return matches[0] == value
        }
    }
}
