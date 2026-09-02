import CloudKit
import Combine
import CoreData
import Foundation

public enum LocalOnlyReason: String, Codable, Sendable {
    case userChoice
    case noAccount
    case entitlementUnavailable
    case restricted
    case temporarilyUnavailable
}

public enum SyncDirection: String, Codable, Sendable {
    case importing
    case exporting
    case setup
}

public enum SyncIssue: String, Codable, Sendable {
    case account
    case quota
    case network
    case service
    case unknown
}

public enum VaultSyncState: Equatable, Sendable {
    case localOnly(LocalOnlyReason)
    case waitingForNetwork(hasLocalChanges: Bool?)
    case syncing(SyncDirection)
    case upToDate(lastSuccess: Date?)
    case needsAttention(SyncIssue)

    public var title: String {
        title(locale: .current)
    }

    public func title(locale: Locale) -> String {
        switch self {
        case .localOnly: String(localized: "Local only", locale: locale)
        case .waitingForNetwork: String(localized: "Waiting for iCloud", locale: locale)
        case .syncing: String(localized: "Syncing", locale: locale)
        case .upToDate: String(localized: "Up to date", locale: locale)
        case .needsAttention: String(localized: "Needs attention", locale: locale)
        }
    }

    public var detail: String {
        detail(locale: .current)
    }

    public func detail(locale: Locale) -> String {
        switch self {
        case .localOnly(.userChoice): String(localized: "Saved on this device. iCloud sync is off.", locale: locale)
        case .localOnly(.noAccount): String(localized: "Saved on this device. Sign in to iCloud to synchronize.", locale: locale)
        case .localOnly(.entitlementUnavailable): String(localized: "This build has no CloudKit container, so your notebook stays local.", locale: locale)
        case .localOnly(.restricted): String(localized: "iCloud access is restricted. Local editing remains available.", locale: locale)
        case .localOnly(.temporarilyUnavailable): String(localized: "Saved on this device. iCloud is temporarily unavailable; synchronization can resume after account verification.", locale: locale)
        case .waitingForNetwork(let changed): changed == true
            ? String(localized: "Saved locally; waiting to synchronize changes.", locale: locale)
            : String(localized: "Waiting for iCloud connectivity.", locale: locale)
        case .syncing(.importing): String(localized: "Receiving changes from your private iCloud database.", locale: locale)
        case .syncing(.exporting): String(localized: "Sending locally saved changes to your private iCloud database.", locale: locale)
        case .syncing(.setup): String(localized: "Preparing private iCloud synchronization.", locale: locale)
        case .upToDate(let date): date.map {
            let formatted = $0.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
            )
            return String(localized: "The last synchronization event succeeded at \(formatted).", locale: locale)
        } ?? String(localized: "The latest synchronization event succeeded.", locale: locale)
        case .needsAttention(.quota): String(localized: "Your iCloud storage may be full. The notebook remains usable locally.", locale: locale)
        case .needsAttention(.account): String(localized: "Check the Apple Account used for iCloud.", locale: locale)
        case .needsAttention(.network): String(localized: "A network problem interrupted synchronization. Local changes are safe.", locale: locale)
        case .needsAttention: String(localized: "Synchronization needs attention. Local changes are safe.", locale: locale)
        }
    }
}

/// A small, testable representation of the CloudKit account states the app cares about.
public enum CloudAccountAvailability: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
}

public protocol CloudAccountStatusProviding: Sendable {
    func accountAvailability(forContainerIdentifier identifier: String) async throws -> CloudAccountAvailability
}

public struct SystemCloudAccountStatusProvider: CloudAccountStatusProviding {
    public init() {}

    public func accountAvailability(forContainerIdentifier identifier: String) async throws -> CloudAccountAvailability {
        switch try await CKContainer(identifier: identifier).accountStatus() {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .temporarilyUnavailable: .temporarilyUnavailable
        case .couldNotDetermine: .couldNotDetermine
        @unknown default: .couldNotDetermine
        }
    }
}

struct CloudEventSnapshot: Sendable {
    let identifier: UUID
    let direction: SyncDirection
    let startDate: Date
    let endDate: Date?
    let succeeded: Bool
    let issue: SyncIssue?
    let storeIdentifier: String

    init(
        identifier: UUID,
        direction: SyncDirection,
        startDate: Date,
        endDate: Date?,
        succeeded: Bool,
        issue: SyncIssue?,
        storeIdentifier: String = CloudSyncStoreConfiguration.vault
    ) {
        self.identifier = identifier
        self.direction = direction
        self.startDate = startDate
        self.endDate = endDate
        self.succeeded = succeeded
        self.issue = issue
        self.storeIdentifier = storeIdentifier
    }
}

private struct ActiveCloudEvent {
    let direction: SyncDirection
    let issueScope: String
}

private struct ExportSequenceCapture {
    let storeConfiguration: String
    let mutationSequence: UInt64
}

private struct CloudEventBatchCompletion {
    var latestEndDate: Date
    var containsObservedEvent: Bool
}

@MainActor
public final class SyncStatusController: ObservableObject {
    @Published public private(set) var state: VaultSyncState

    public private(set) var lastLocalMutationAt: Date?
    public private(set) var lastSuccessfulExportAt: Date?
    public private(set) var localMutationSequence: UInt64
    public private(set) var lastSuccessfulExportSequence: UInt64

    public var hasPendingLocalChanges: Bool {
        let stores = Set(localMutationSequencesByStore.keys)
            .union(successfulExportSequencesByStore.keys)
        return stores.contains { store in
            localMutationSequencesByStore[store, default: 0]
                > successfulExportSequencesByStore[store, default: 0]
        }
    }

    private let cloudContainerIdentifier: String?
    private let configuredLocalOnlyReason: LocalOnlyReason
    private let accountStatusProvider: any CloudAccountStatusProviding
    private let notificationCenter: NotificationCenter
    private let userDefaults: UserDefaults
    private let now: @MainActor () -> Date
    private let localMutationDefaultsKey: String?
    private let successfulExportDefaultsKey: String?
    private let localMutationSequenceDefaultsKey: String?
    private let successfulExportSequenceDefaultsKey: String?
    private let localMutationSequencesByStoreDefaultsKey: String?
    private let successfulExportSequencesByStoreDefaultsKey: String?
    private let configurationByStoreIdentifier: [String: String]
    private let mirroredStoreConfigurations: Set<String>
    private let localMutationSource: NSManagedObjectContext

    // NotificationCenter's opaque observer token predates Sendable. Registration and
    // mutation remain main-actor confined; deinit only uses the tokens to unregister.
    private nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []
    private var activeEvents: [UUID: ActiveCloudEvent] = [:]
    private var exportStartMutationSequences: [UUID: ExportSequenceCapture] = [:]
    private var localMutationSequencesByStore: [String: UInt64]
    private var successfulExportSequencesByStore: [String: UInt64]
    private var pendingBatchIssuesByStore: [String: SyncIssue] = [:]
    private var pendingBatchCompletionsByStore: [String: CloudEventBatchCompletion] = [:]
    private var successfulStoresInBatch: Set<String> = []
    private var quiescentIssuesByStore: [String: SyncIssue] = [:]
    private var completionWatermarksByStore: [String: Date] = [:]
    private var completedEventIdentifiers: Set<UUID> = []
    private var accountAvailability: CloudAccountAvailability?
    private var accountStatusIssue: SyncIssue?
    private var applicationReloadIssue: SyncIssue?
    private var lastSuccessfulEventAt: Date?
    private var accountRefreshGeneration = 0

    public convenience init(
        container: NSPersistentCloudKitContainer,
        cloudContainerIdentifier: String?,
        localOnlyReason: LocalOnlyReason = .entitlementUnavailable,
        persistenceScopeIdentifier: String? = nil,
        accountStatusProvider: any CloudAccountStatusProviding = SystemCloudAccountStatusProvider(),
        initialAccountAvailability: CloudAccountAvailability? = nil,
        automaticallyRefreshAccountStatus: Bool = true
    ) {
        self.init(
            container: container,
            cloudContainerIdentifier: cloudContainerIdentifier,
            localOnlyReason: localOnlyReason,
            persistenceScopeIdentifier: persistenceScopeIdentifier,
            accountStatusProvider: accountStatusProvider,
            notificationCenter: .default,
            userDefaults: .standard,
            now: Date.init,
            initialAccountAvailability: initialAccountAvailability,
            automaticallyRefreshAccountStatus: automaticallyRefreshAccountStatus
        )
    }

    init(
        container: NSPersistentCloudKitContainer,
        cloudContainerIdentifier: String?,
        localOnlyReason: LocalOnlyReason,
        persistenceScopeIdentifier: String? = nil,
        accountStatusProvider: any CloudAccountStatusProviding,
        notificationCenter: NotificationCenter,
        userDefaults: UserDefaults,
        now: @escaping @MainActor () -> Date,
        initialAccountAvailability: CloudAccountAvailability? = nil,
        automaticallyRefreshAccountStatus: Bool,
        durableCloudEvents: [CloudEventSnapshot]? = nil
    ) {
        self.cloudContainerIdentifier = cloudContainerIdentifier
        self.configuredLocalOnlyReason = localOnlyReason
        self.accountStatusProvider = accountStatusProvider
        self.notificationCenter = notificationCenter
        self.userDefaults = userDefaults
        self.now = now
        self.localMutationSource = container.viewContext
        let configurationByStoreIdentifier: [String: String] = Dictionary(
            container.persistentStoreCoordinator.persistentStores.compactMap { store in
                let configuration = store.configurationName
                guard CloudSyncStoreConfiguration.mirrored.contains(configuration) else {
                    return nil
                }
                return (store.identifier, configuration)
            },
            uniquingKeysWith: { first, _ in first }
        )
        self.configurationByStoreIdentifier = configurationByStoreIdentifier
        let detectedMirroredConfigurations = Set(
            configurationByStoreIdentifier.values
        )
        let mirroredStoreConfigurations = detectedMirroredConfigurations.isEmpty
            ? CloudSyncStoreConfiguration.mirrored
            : detectedMirroredConfigurations
        self.mirroredStoreConfigurations = mirroredStoreConfigurations

        if let cloudContainerIdentifier {
            let scope = persistenceScopeIdentifier ?? cloudContainerIdentifier
            let keyPrefix = "RelationshipNotebook.SyncStatus.\(scope)"
            let mutationKey = "\(keyPrefix).lastLocalMutation"
            let exportKey = "\(keyPrefix).lastSuccessfulExport"
            let mutationSequenceKey = "\(keyPrefix).localMutationSequence"
            let exportSequenceKey = "\(keyPrefix).lastSuccessfulExportSequence"
            let mutationsByStoreKey = "\(keyPrefix).localMutationSequencesByStore"
            let exportsByStoreKey = "\(keyPrefix).lastSuccessfulExportSequencesByStore"
            localMutationDefaultsKey = mutationKey
            successfulExportDefaultsKey = exportKey
            localMutationSequenceDefaultsKey = mutationSequenceKey
            successfulExportSequenceDefaultsKey = exportSequenceKey
            localMutationSequencesByStoreDefaultsKey = mutationsByStoreKey
            successfulExportSequencesByStoreDefaultsKey = exportsByStoreKey
            lastLocalMutationAt = userDefaults.object(forKey: mutationKey) as? Date
            lastSuccessfulExportAt = userDefaults.object(forKey: exportKey) as? Date

            let storedMutationSequence = (userDefaults.object(forKey: mutationSequenceKey) as? NSNumber)?.uint64Value
            let storedExportSequence = (userDefaults.object(forKey: exportSequenceKey) as? NSNumber)?.uint64Value
            let persistedMutationsByStore = Self.persistedSequences(
                in: userDefaults,
                key: mutationsByStoreKey
            )
            let persistedExportsByStore = Self.persistedSequences(
                in: userDefaults,
                key: exportsByStoreKey
            )

            var mutationsByStore: [String: UInt64]
            var exportsByStore: [String: UInt64]
            if let persistedMutationsByStore, let persistedExportsByStore {
                mutationsByStore = persistedMutationsByStore
                exportsByStore = persistedExportsByStore
            } else if let persistedMutationsByStore {
                // An interrupted write left export scope unknown. Requiring each
                // store to export again is safer than applying the aggregate scalar.
                mutationsByStore = persistedMutationsByStore
                exportsByStore = [:]
            } else if let persistedExportsByStore {
                // If the mutation map is missing, the global sequence has lost its
                // scope. Apply it to every active mirrored store and retain only
                // known export coverage.
                let conservativeMutationSequence = max(
                    storedMutationSequence ?? 0,
                    persistedExportsByStore.values.max() ?? 0
                )
                mutationsByStore = Dictionary(
                    uniqueKeysWithValues: mirroredStoreConfigurations.map {
                        ($0, conservativeMutationSequence)
                    }
                )
                exportsByStore = persistedExportsByStore
            } else {
                // Migrate the former date watermark once. Dates remain presentation
                // metadata, while all future correctness decisions use store sequences.
                let legacyMutationSequence: UInt64
                let legacyExportSequence: UInt64
                if let storedMutationSequence {
                    legacyMutationSequence = max(storedMutationSequence, storedExportSequence ?? 0)
                    legacyExportSequence = min(storedExportSequence ?? 0, legacyMutationSequence)
                } else if let lastLocalMutationAt {
                    legacyMutationSequence = 1
                    legacyExportSequence = if let lastSuccessfulExportAt,
                                              lastSuccessfulExportAt >= lastLocalMutationAt {
                        1
                    } else {
                        0
                    }
                } else {
                    legacyMutationSequence = 0
                    legacyExportSequence = 0
                }
                mutationsByStore = Dictionary(
                    uniqueKeysWithValues: mirroredStoreConfigurations.map {
                        ($0, legacyMutationSequence)
                    }
                )
                exportsByStore = Dictionary(
                    uniqueKeysWithValues: mirroredStoreConfigurations.map {
                        ($0, legacyExportSequence)
                    }
                )
            }

            mutationsByStore = mutationsByStore.filter {
                mirroredStoreConfigurations.contains($0.key)
            }
            exportsByStore = exportsByStore.filter {
                mirroredStoreConfigurations.contains($0.key)
            }
            for configuration in mirroredStoreConfigurations {
                mutationsByStore[configuration] = mutationsByStore[configuration, default: 0]
                exportsByStore[configuration] = min(
                    exportsByStore[configuration, default: 0],
                    mutationsByStore[configuration, default: 0]
                )
            }

            let greatestPersistedMutation = mutationsByStore.values.max() ?? 0
            localMutationSequence = max(storedMutationSequence ?? 0, greatestPersistedMutation)
            if localMutationSequence > greatestPersistedMutation {
                // A crash between writing the global sequence and its store map loses
                // scope information, so conservatively mark every mirrored store.
                for configuration in mirroredStoreConfigurations {
                    mutationsByStore[configuration] = localMutationSequence
                }
            }
            localMutationSequencesByStore = mutationsByStore
            successfulExportSequencesByStore = exportsByStore
            let hasPendingStore = mirroredStoreConfigurations.contains { configuration in
                mutationsByStore[configuration, default: 0]
                    > exportsByStore[configuration, default: 0]
            }
            lastSuccessfulExportSequence = hasPendingStore
                ? min(storedExportSequence ?? (exportsByStore.values.min() ?? 0), localMutationSequence)
                : localMutationSequence
            userDefaults.set(NSNumber(value: localMutationSequence), forKey: mutationSequenceKey)
            userDefaults.set(NSNumber(value: lastSuccessfulExportSequence), forKey: exportSequenceKey)
            Self.persist(
                mutationsByStore,
                in: userDefaults,
                key: mutationsByStoreKey
            )
            Self.persist(
                exportsByStore,
                in: userDefaults,
                key: exportsByStoreKey
            )
            state = .syncing(.setup)
        } else {
            localMutationDefaultsKey = nil
            successfulExportDefaultsKey = nil
            localMutationSequenceDefaultsKey = nil
            successfulExportSequenceDefaultsKey = nil
            localMutationSequencesByStoreDefaultsKey = nil
            successfulExportSequencesByStoreDefaultsKey = nil
            lastLocalMutationAt = nil
            lastSuccessfulExportAt = nil
            localMutationSequence = 0
            lastSuccessfulExportSequence = 0
            localMutationSequencesByStore = [:]
            successfulExportSequencesByStore = [:]
            state = .localOnly(localOnlyReason)
        }

        accountAvailability = initialAccountAvailability

        observeCloudEvents(from: container)
        observeLocalMutations()
        observeAccountChanges()

        if cloudContainerIdentifier != nil {
            reconcileDurableCloudEvents(
                durableCloudEvents ?? Self.fetchDurableCloudEvents(from: container)
            )
        }

        if initialAccountAvailability != nil {
            recomputeState()
        }

        if cloudContainerIdentifier != nil, automaticallyRefreshAccountStatus {
            Task { @MainActor [weak self] in await self?.refreshAccountStatus() }
        }
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
    }

    /// Records a successfully committed user edit. This method is safe to call while an
    /// export is already running; the export will not clear an edit that it may not contain.
    public func markLocalChange() {
        guard cloudContainerIdentifier != nil else { return }

        markLocalChange(at: now(), storeConfigurations: nil)
    }

    func markLocalChange(at committedAt: Date, storeConfigurations: Set<String>?) {
        guard cloudContainerIdentifier != nil else { return }

        let timestamp = monotonicMutationTimestamp(for: committedAt)
        let affectedStores: Set<String>
        if let storeConfigurations,
           !storeConfigurations.isEmpty,
           storeConfigurations.isSubset(of: mirroredStoreConfigurations) {
            affectedStores = storeConfigurations
        } else {
            // Losing mutation scope must never permit a mirrored store to
            // report clean before it has exported the edit.
            affectedStores = mirroredStoreConfigurations
        }
        advanceLocalMutationSequence(for: affectedStores)
        lastLocalMutationAt = timestamp
        if let localMutationDefaultsKey {
            userDefaults.set(timestamp, forKey: localMutationDefaultsKey)
        }
        recomputeState()
    }

    public func refreshAccountStatus() async {
        guard let cloudContainerIdentifier else {
            state = .localOnly(configuredLocalOnlyReason)
            return
        }

        accountRefreshGeneration += 1
        let generation = accountRefreshGeneration

        do {
            let availability = try await accountStatusProvider.accountAvailability(
                forContainerIdentifier: cloudContainerIdentifier
            )
            guard generation == accountRefreshGeneration else { return }
            accountAvailability = availability
            accountStatusIssue = nil
        } catch {
            guard generation == accountRefreshGeneration else { return }
            accountAvailability = nil
            accountStatusIssue = Self.issue(for: error)
        }
        recomputeState()
    }

    /// CloudKit can finish an import even when the app cannot decode and
    /// republish the resulting local snapshot. Keep that failure visible until
    /// a later coherent application reload succeeds.
    public func reportApplicationReloadFailure() {
        applicationReloadIssue = .service
        recomputeState()
    }

    public func reportApplicationReloadSucceeded() {
        applicationReloadIssue = nil
        recomputeState()
    }

    private func observeCloudEvents(from container: NSPersistentCloudKitContainer) {
        let token = notificationCenter.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let direction: SyncDirection = switch event.type {
            case .setup: .setup
            case .import: .importing
            case .export: .exporting
            @unknown default: .setup
            }
            let snapshot = CloudEventSnapshot(
                identifier: event.identifier,
                direction: direction,
                startDate: event.startDate,
                endDate: event.endDate,
                succeeded: event.succeeded,
                issue: event.error.map(Self.issue(for:)),
                storeIdentifier: event.storeIdentifier
            )
            Task { @MainActor [weak self] in self?.consume(snapshot) }
        }
        observerTokens.append(token)
    }

    private func observeLocalMutations() {
        let token = notificationCenter.addObserver(
            forName: .relationshipNotebookLocalMutationCommitted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let committedAt = notification.userInfo?[CloudSyncNotificationUserInfoKey.committedAt] as? Date
            let storeConfigurations = notification.userInfo?[
                CloudSyncNotificationUserInfoKey.storeConfigurations
            ] as? [String]
            let storeConfiguration = notification.userInfo?[
                CloudSyncNotificationUserInfoKey.storeConfiguration
            ] as? String
            let storeIdentifiers = notification.userInfo?[
                CloudSyncNotificationUserInfoKey.storeIdentifiers
            ] as? [String]
            let storeIdentifier = notification.userInfo?[
                CloudSyncNotificationUserInfoKey.storeIdentifier
            ] as? String
            let sourceIdentifier = (notification.object as? NSManagedObjectContext)
                .map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let sourceIdentifier,
                   sourceIdentifier != ObjectIdentifier(self.localMutationSource) {
                    return
                }
                let reportedConfigurations = self.mirroredConfigurations(
                    storeConfigurations: storeConfigurations,
                    storeConfiguration: storeConfiguration,
                    storeIdentifiers: storeIdentifiers,
                    storeIdentifier: storeIdentifier
                )
                self.markLocalChange(
                    at: committedAt ?? self.now(),
                    storeConfigurations: reportedConfigurations
                )
            }
        }
        observerTokens.append(token)
    }

    private func observeAccountChanges() {
        let token = notificationCenter.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshAccountStatus() }
        }
        observerTokens.append(token)
    }

    func consume(_ event: CloudEventSnapshot) {
        // Registration intentionally precedes durable-log hydration. A notification
        // already represented by that log can consequently arrive afterward; never
        // replay its completion side effects or resurrect its start as active work.
        guard !completedEventIdentifiers.contains(event.identifier) else { return }

        let eventStoreConfiguration = storeConfiguration(for: event.storeIdentifier)
        let issueScope = event.storeIdentifier
        if event.endDate == nil {
            if !activeEvents.values.contains(where: { $0.issueScope == issueScope }) {
                pendingBatchIssuesByStore.removeValue(forKey: issueScope)
                successfulStoresInBatch.remove(issueScope)
            }
            activeEvents[event.identifier] = ActiveCloudEvent(
                direction: event.direction,
                issueScope: issueScope
            )
            if event.direction == .exporting,
               let eventStoreConfiguration,
               exportStartMutationSequences[event.identifier] == nil {
                exportStartMutationSequences[event.identifier] = ExportSequenceCapture(
                    storeConfiguration: eventStoreConfiguration,
                    mutationSequence: localMutationSequencesByStore[
                        eventStoreConfiguration,
                        default: 0
                    ]
                )
            }
            recomputeState()
            return
        }

        let activeEvent = activeEvents.removeValue(forKey: event.identifier)
        let completedIssueScope = activeEvent?.issueScope ?? event.storeIdentifier
        let capturedExportSequence = exportStartMutationSequences.removeValue(forKey: event.identifier)
        let verifiedExportSequence = activeEvent?.issueScope == event.storeIdentifier
            ? capturedExportSequence
            : nil
        guard let endDate = event.endDate else { return }
        completedEventIdentifiers.insert(event.identifier)

        let previousCompletionWatermark = completionWatermarksByStore[completedIssueScope]
        if activeEvent == nil,
           let previousCompletionWatermark,
           endDate < previousCompletionWatermark {
            // An unobserved, out-of-order completion cannot clear a newer durable
            // failure (or replace a newer success). An observed start is stronger
            // evidence and is therefore allowed to finish normally.
            recomputeState()
            return
        }

        if var batch = pendingBatchCompletionsByStore[completedIssueScope] {
            batch.latestEndDate = max(batch.latestEndDate, endDate)
            batch.containsObservedEvent = batch.containsObservedEvent || activeEvent != nil
            pendingBatchCompletionsByStore[completedIssueScope] = batch
        } else {
            pendingBatchCompletionsByStore[completedIssueScope] = CloudEventBatchCompletion(
                latestEndDate: endDate,
                containsObservedEvent: activeEvent != nil
            )
        }
        if event.succeeded {
            successfulStoresInBatch.insert(completedIssueScope)
            consumeSuccessfulCompletion(
                event,
                capturedExportSequence: verifiedExportSequence,
                postsRemoteImportNotification: activeEvent != nil
                    || previousCompletionWatermark.map { endDate > $0 } != false
            )
        } else {
            let issue = event.issue ?? .unknown
            pendingBatchIssuesByStore[completedIssueScope] = Self.preferredIssue(
                pendingBatchIssuesByStore[completedIssueScope],
                issue
            )
        }

        guard !activeEvents.values.contains(where: { $0.issueScope == completedIssueScope }) else {
            recomputeState()
            return
        }

        let batch = pendingBatchCompletionsByStore[completedIssueScope]
        let previousWatermark = completionWatermarksByStore[completedIssueScope]
        let batchIsNewer = if let batch, let previousWatermark {
            batch.latestEndDate > previousWatermark
        } else {
            batch != nil
        }
        let mayReplaceWatermark = batch?.containsObservedEvent == true
        if let issue = pendingBatchIssuesByStore[completedIssueScope] {
            if batchIsNewer || mayReplaceWatermark || batch?.latestEndDate == previousWatermark {
                quiescentIssuesByStore[completedIssueScope] = Self.preferredIssue(
                    batchIsNewer || mayReplaceWatermark
                        ? nil
                        : quiescentIssuesByStore[completedIssueScope],
                    issue
                )
            }
        } else if successfulStoresInBatch.contains(completedIssueScope),
                  batchIsNewer || mayReplaceWatermark {
            quiescentIssuesByStore.removeValue(forKey: completedIssueScope)
        }
        if let batch {
            completionWatermarksByStore[completedIssueScope] = max(
                previousWatermark ?? batch.latestEndDate,
                batch.latestEndDate
            )
        }
        pendingBatchIssuesByStore.removeValue(forKey: completedIssueScope)
        pendingBatchCompletionsByStore.removeValue(forKey: completedIssueScope)
        successfulStoresInBatch.remove(completedIssueScope)
        recomputeState()
    }

    private func consumeSuccessfulCompletion(
        _ event: CloudEventSnapshot,
        capturedExportSequence: ExportSequenceCapture?,
        postsRemoteImportNotification: Bool = true
    ) {
        if let endDate = event.endDate {
            lastSuccessfulEventAt = max(lastSuccessfulEventAt ?? endDate, endDate)
        }

        switch event.direction {
        case .exporting:
            if let endDate = event.endDate {
                lastSuccessfulExportAt = max(lastSuccessfulExportAt ?? endDate, endDate)
                if let successfulExportDefaultsKey {
                    userDefaults.set(lastSuccessfulExportAt, forKey: successfulExportDefaultsKey)
                }
            }
            // Only an observed export start establishes which local mutations the
            // batch could contain. Later edits retain a larger sequence and stay pending.
            if let capturedExportSequence {
                let store = capturedExportSequence.storeConfiguration
                successfulExportSequencesByStore[store] = max(
                    successfulExportSequencesByStore[store, default: 0],
                    capturedExportSequence.mutationSequence
                )
                if !hasPendingLocalChanges {
                    // This compatibility watermark represents the last sequence for
                    // which every affected mirrored store is known to be covered.
                    lastSuccessfulExportSequence = localMutationSequence
                }
                if let successfulExportSequenceDefaultsKey {
                    userDefaults.set(
                        NSNumber(value: lastSuccessfulExportSequence),
                        forKey: successfulExportSequenceDefaultsKey
                    )
                }
                persistStoreSequences()
            }
        case .importing where postsRemoteImportNotification:
            notificationCenter.post(
                name: .relationshipNotebookRemoteImportCompleted,
                object: self,
                userInfo: event.endDate.map { ["endDate": $0] }
            )
        case .importing:
            break
        case .setup:
            break
        }
    }

    /// Reconstructs quiescent presentation and error state from Core Data's
    /// persistent CloudKit event log. Export sequence coverage is deliberately
    /// not reconstructed: a completed event alone cannot prove which persisted
    /// local-mutation sequence was present when that export began.
    func reconcileDurableCloudEvents(_ events: [CloudEventSnapshot]) {
        let completed = events
            .filter { $0.endDate != nil }
            .sorted(by: Self.durableCompletionOrder)

        for event in completed {
            completedEventIdentifiers.insert(event.identifier)
            // Hydration can race a start notification registered just before the
            // durable fetch. The completed log entry is authoritative for activity,
            // but its replay cannot prove the mutation sequence captured in memory,
            // so discard both pieces of transient state without granting coverage.
            activeEvents.removeValue(forKey: event.identifier)
            exportStartMutationSequences.removeValue(forKey: event.identifier)
            guard let endDate = event.endDate else { continue }
            let scope = event.storeIdentifier
            let previousWatermark = completionWatermarksByStore[scope]

            if event.succeeded {
                consumeSuccessfulCompletion(
                    event,
                    capturedExportSequence: nil,
                    postsRemoteImportNotification: false
                )
            }

            guard previousWatermark == nil || endDate >= previousWatermark! else {
                continue
            }

            if endDate > (previousWatermark ?? .distantPast) {
                completionWatermarksByStore[scope] = endDate
                if event.succeeded {
                    quiescentIssuesByStore.removeValue(forKey: scope)
                } else {
                    quiescentIssuesByStore[scope] = event.issue ?? .unknown
                }
            } else if !event.succeeded {
                // Multiple operations can finish at the same timestamp. A failure
                // wins that tie, and the most actionable issue wins among failures.
                quiescentIssuesByStore[scope] = Self.preferredIssue(
                    quiescentIssuesByStore[scope],
                    event.issue ?? .unknown
                )
            }
        }

        let completedIdentifiers = completedEventIdentifiers
        for event in events
            .filter({ $0.endDate == nil && !completedIdentifiers.contains($0.identifier) })
            .sorted(by: Self.durableActiveEventOrder) {
            activeEvents[event.identifier] = ActiveCloudEvent(
                direction: event.direction,
                issueScope: event.storeIdentifier
            )
            // An event that began before this controller existed cannot safely
            // capture a local-mutation sequence for export coverage.
        }

        recomputeState()
    }

    private static func fetchDurableCloudEvents(
        from container: NSPersistentCloudKitContainer
    ) -> [CloudEventSnapshot] {
        let request = NSPersistentCloudKitContainerEventRequest.fetchEvents(after: .distantPast)
        request.resultType = .events

        guard let result = try? container.viewContext.execute(request)
                as? NSPersistentCloudKitContainerEventResult,
              let events = result.result as? [NSPersistentCloudKitContainer.Event] else {
            return []
        }

        return events.map { event in
            let direction: SyncDirection = switch event.type {
            case .setup: .setup
            case .import: .importing
            case .export: .exporting
            @unknown default: .setup
            }
            return CloudEventSnapshot(
                identifier: event.identifier,
                direction: direction,
                startDate: event.startDate,
                endDate: event.endDate,
                succeeded: event.succeeded,
                issue: event.error.map(Self.issue(for:)),
                storeIdentifier: event.storeIdentifier
            )
        }
    }

    nonisolated private static func durableCompletionOrder(
        _ lhs: CloudEventSnapshot,
        _ rhs: CloudEventSnapshot
    ) -> Bool {
        let lhsEnd = lhs.endDate ?? .distantPast
        let rhsEnd = rhs.endDate ?? .distantPast
        if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
        if lhs.succeeded != rhs.succeeded { return lhs.succeeded }
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        return lhs.identifier.uuidString < rhs.identifier.uuidString
    }

    nonisolated private static func durableActiveEventOrder(
        _ lhs: CloudEventSnapshot,
        _ rhs: CloudEventSnapshot
    ) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        return lhs.identifier.uuidString < rhs.identifier.uuidString
    }

    private func recomputeState() {
        guard cloudContainerIdentifier != nil else {
            state = .localOnly(configuredLocalOnlyReason)
            return
        }

        switch accountAvailability {
        case .noAccount:
            state = .localOnly(.noAccount)
            return
        case .restricted:
            state = .localOnly(.restricted)
            return
        case .temporarilyUnavailable:
            state = .waitingForNetwork(hasLocalChanges: hasPendingLocalChanges ? true : nil)
            return
        case .couldNotDetermine:
            state = .needsAttention(.account)
            return
        case .available, nil:
            break
        }

        if let direction = activeDirection {
            state = .syncing(direction)
        } else if let applicationReloadIssue {
            state = .needsAttention(applicationReloadIssue)
        } else if let accountStatusIssue {
            state = .needsAttention(accountStatusIssue)
        } else if let quiescentIssue {
            state = .needsAttention(quiescentIssue)
        } else if hasPendingLocalChanges {
            state = .waitingForNetwork(hasLocalChanges: true)
        } else if let lastSuccess = lastSuccessfulEventAt ?? lastSuccessfulExportAt {
            state = .upToDate(lastSuccess: lastSuccess)
        } else {
            state = .syncing(.setup)
        }
    }

    private var activeDirection: SyncDirection? {
        let directions = Set(activeEvents.values.map(\.direction))
        if directions.contains(.setup) { return .setup }
        if directions.contains(.importing) { return .importing }
        if directions.contains(.exporting) { return .exporting }
        return nil
    }

    private var quiescentIssue: SyncIssue? {
        quiescentIssuesByStore.values.reduce(nil) {
            Self.preferredIssue($0, $1)
        }
    }

    private func storeConfiguration(for storeIdentifier: String?) -> String? {
        guard let storeIdentifier else { return nil }
        if let configuration = configurationByStoreIdentifier[storeIdentifier] {
            return configuration
        }
        // Unit snapshots use configuration names as deterministic stand-ins for
        // Core Data's runtime-generated persistent-store identifiers.
        return mirroredStoreConfigurations.contains(storeIdentifier)
            ? storeIdentifier
            : nil
    }

    private func mirroredConfigurations(
        storeConfigurations: [String]?,
        storeConfiguration: String?,
        storeIdentifiers: [String]?,
        storeIdentifier: String?
    ) -> Set<String>? {
        if let reported = storeConfigurations {
            let configurations = Set(reported)
            guard !configurations.isEmpty,
                  configurations.isSubset(of: mirroredStoreConfigurations) else {
                return nil
            }
            return configurations
        }
        if let reported = storeConfiguration {
            return mirroredStoreConfigurations.contains(reported) ? [reported] : nil
        }

        let identifiers: [String]
        if let reported = storeIdentifiers {
            identifiers = reported
        } else if let reported = storeIdentifier {
            identifiers = [reported]
        } else {
            return nil
        }
        let configurations = identifiers.compactMap { configurationByStoreIdentifier[$0] }
        return configurations.count == identifiers.count && !configurations.isEmpty
            ? Set(configurations)
            : nil
    }

    private func monotonicMutationTimestamp(for current: Date) -> Date {
        guard let lastLocalMutationAt, current <= lastLocalMutationAt else { return current }
        return lastLocalMutationAt.addingTimeInterval(0.000_001)
    }

    private func advanceLocalMutationSequence(for affectedStores: Set<String>) {
        if localMutationSequence == UInt64.max {
            // This is practically unreachable, but invalidating in-flight captures keeps
            // a mutation at saturation from being mistaken for part of an older export.
            exportStartMutationSequences.removeAll()
            for store in affectedStores
                where successfulExportSequencesByStore[store, default: 0] == UInt64.max {
                successfulExportSequencesByStore[store] = UInt64.max - 1
            }
        } else {
            localMutationSequence += 1
        }

        for store in affectedStores {
            localMutationSequencesByStore[store] = localMutationSequence
        }
        if localMutationSequence == UInt64.max,
           lastSuccessfulExportSequence == UInt64.max {
            lastSuccessfulExportSequence = UInt64.max - 1
        }

        if let localMutationSequenceDefaultsKey {
            userDefaults.set(
                NSNumber(value: localMutationSequence),
                forKey: localMutationSequenceDefaultsKey
            )
        }
        if let successfulExportSequenceDefaultsKey {
            userDefaults.set(
                NSNumber(value: lastSuccessfulExportSequence),
                forKey: successfulExportSequenceDefaultsKey
            )
        }
        persistStoreSequences()
    }

    private func persistStoreSequences() {
        if let localMutationSequencesByStoreDefaultsKey {
            Self.persist(
                localMutationSequencesByStore,
                in: userDefaults,
                key: localMutationSequencesByStoreDefaultsKey
            )
        }
        if let successfulExportSequencesByStoreDefaultsKey {
            Self.persist(
                successfulExportSequencesByStore,
                in: userDefaults,
                key: successfulExportSequencesByStoreDefaultsKey
            )
        }
    }

    private static func persistedSequences(
        in userDefaults: UserDefaults,
        key: String
    ) -> [String: UInt64]? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([String: UInt64].self, from: data)
    }

    private static func persist(
        _ sequences: [String: UInt64],
        in userDefaults: UserDefaults,
        key: String
    ) {
        if let data = try? JSONEncoder().encode(sequences) {
            userDefaults.set(data, forKey: key)
        }
    }

    nonisolated private static func preferredIssue(_ current: SyncIssue?, _ candidate: SyncIssue) -> SyncIssue {
        guard let current else { return candidate }
        let priority: [SyncIssue: Int] = [
            .account: 5,
            .quota: 4,
            .network: 3,
            .service: 2,
            .unknown: 1,
        ]
        return priority[candidate, default: 0] > priority[current, default: 0] ? candidate : current
    }

    nonisolated private static func issue(for error: Error) -> SyncIssue {
        guard let error = error as? CKError else { return .unknown }
        switch error.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return .network
        case .quotaExceeded:
            return .quota
        case .notAuthenticated, .permissionFailure:
            return .account
        default:
            return .service
        }
    }
}
