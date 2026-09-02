import CoreData
import Foundation
import OSLog

public struct PersistentHistoryStoreSummary: Equatable, Sendable {
    public let storeIdentifier: String
    public let transactionCount: Int
    public let latestTransactionAt: Date

    public init(storeIdentifier: String, transactionCount: Int, latestTransactionAt: Date) {
        self.storeIdentifier = storeIdentifier
        self.transactionCount = transactionCount
        self.latestTransactionAt = latestTransactionAt
    }
}

public struct PersistentHistoryBatch: Equatable, Sendable {
    public let vaultIdentifier: String
    public let stores: [PersistentHistoryStoreSummary]

    public init(vaultIdentifier: String, stores: [PersistentHistoryStoreSummary]) {
        self.vaultIdentifier = vaultIdentifier
        self.stores = stores
    }

    public var transactionCount: Int {
        stores.reduce(0) { $0 + $1.transactionCount }
    }
}

/// Persists opaque Core Data history tokens in a vault- and store-scoped namespace.
/// Implementations must commit a supplied token dictionary as one logical update.
@MainActor
public protocol PersistentHistoryTokenPersisting: AnyObject {
    func tokenData(vaultIdentifier: String, storeIdentifier: String) throws -> Data?
    func commitTokenData(_ tokenDataByStoreIdentifier: [String: Data], vaultIdentifier: String) throws
}

/// The default token store. History tokens contain no notebook content and stay local.
@MainActor
public final class UserDefaultsPersistentHistoryTokenStore: PersistentHistoryTokenPersisting {
    private let userDefaults: UserDefaults
    private let keyPrefix: String

    public init(
        userDefaults: UserDefaults = .standard,
        keyPrefix: String = "RelationshipNotebook.PersistentHistory"
    ) {
        self.userDefaults = userDefaults
        self.keyPrefix = keyPrefix
    }

    public func tokenData(vaultIdentifier: String, storeIdentifier: String) throws -> Data? {
        tokenDictionary(vaultIdentifier: vaultIdentifier)[storeIdentifier]
    }

    public func commitTokenData(
        _ tokenDataByStoreIdentifier: [String: Data],
        vaultIdentifier: String
    ) throws {
        guard !tokenDataByStoreIdentifier.isEmpty else { return }
        var tokens = tokenDictionary(vaultIdentifier: vaultIdentifier)
        tokens.merge(tokenDataByStoreIdentifier) { _, replacement in replacement }
        userDefaults.set(tokens, forKey: defaultsKey(vaultIdentifier: vaultIdentifier))
    }

    private func tokenDictionary(vaultIdentifier: String) -> [String: Data] {
        userDefaults.dictionary(forKey: defaultsKey(vaultIdentifier: vaultIdentifier)) as? [String: Data] ?? [:]
    }

    private func defaultsKey(vaultIdentifier: String) -> String {
        let encodedVault = Data(vaultIdentifier.utf8).base64EncodedString()
        return "\(keyPrefix).\(encodedVault)"
    }
}

public enum PersistentHistoryCoordinatorError: Error, Equatable, Sendable {
    case storeUnavailable(String)
    case unexpectedHistoryResult(String)
}

private struct FetchedStoreHistory: Sendable {
    let storeIdentifier: String
    let transactionCount: Int
    let latestTransactionAt: Date
    let latestTokenData: Data
}

/// Serially consumes replayable persistent history after Core Data remote-change
/// notifications. Tokens advance only after the downstream MainActor refresh and
/// the token-store commit both succeed.
@MainActor
public final class PersistentHistoryCoordinator {
    public static let userTransactionAuthor = "app.user"

    public private(set) var lastError: (any Error)?

    private static let logger = Logger(
        subsystem: "com.zacrotech.RelationshipNotebook",
        category: "persistent-history"
    )

    private let container: NSPersistentContainer
    private let vaultIdentifier: String
    private let ignoredTransactionAuthor: String
    private let tokenStore: any PersistentHistoryTokenPersisting
    private let notificationCenter: NotificationCenter
    private let reload: @MainActor @Sendable (PersistentHistoryBatch) async throws -> Void
    private let historyContext: NSManagedObjectContext

    // NotificationCenter's opaque token predates Sendable. It is installed on the
    // main actor and is only accessed outside that isolation during deinit cleanup.
    private nonisolated(unsafe) var remoteChangeObserver: NSObjectProtocol?

    private var pendingAllStores = false
    private var pendingStoreIdentifiers: Set<String> = []
    private var isConsuming = false
    private var isStopping = false
    private var drainWaiters: [CheckedContinuation<Void, any Error>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        container: NSPersistentContainer,
        vaultIdentifier: String,
        ignoredTransactionAuthor: String = PersistentHistoryCoordinator.userTransactionAuthor,
        tokenStore: any PersistentHistoryTokenPersisting = UserDefaultsPersistentHistoryTokenStore(),
        notificationCenter: NotificationCenter = .default,
        automaticallyStart: Bool = true,
        reload: @escaping @MainActor @Sendable (PersistentHistoryBatch) async throws -> Void
    ) {
        self.container = container
        self.vaultIdentifier = vaultIdentifier
        self.ignoredTransactionAuthor = ignoredTransactionAuthor
        self.tokenStore = tokenStore
        self.notificationCenter = notificationCenter
        self.reload = reload
        historyContext = container.newBackgroundContext()
        historyContext.name = "persistent-history.consumer"
        historyContext.transactionAuthor = "app.history"
        historyContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType)

        if automaticallyStart {
            start()
        }
    }

    deinit {
        if let remoteChangeObserver {
            notificationCenter.removeObserver(remoteChangeObserver)
        }
    }

    public func start() {
        guard remoteChangeObserver == nil else { return }
        isStopping = false
        remoteChangeObserver = notificationCenter.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: nil
        ) { [weak self] notification in
            let storeIdentifier = notification.userInfo?[NSStoreUUIDKey] as? String
            Task { @MainActor [weak self] in
                self?.enqueue(storeIdentifier: storeIdentifier, waiter: nil)
            }
        }
    }

    public func stop() {
        isStopping = true
        pendingAllStores = false
        pendingStoreIdentifiers.removeAll()
        if let remoteChangeObserver {
            notificationCenter.removeObserver(remoteChangeObserver)
            self.remoteChangeObserver = nil
        }
    }

    /// Removes the remote-change observer and waits for any in-flight fetch or
    /// downstream reload to finish before its persistent stores are detached.
    public func stopAndWait() async {
        stop()
        guard isConsuming else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    /// Deterministically drains all currently available non-user history. Calls made
    /// while another drain is running join that serialized drain instead of racing it.
    public func consumePendingHistory() async throws {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(storeIdentifier: nil, waiter: continuation)
        }
    }

    private func enqueue(
        storeIdentifier: String?,
        waiter: CheckedContinuation<Void, any Error>?
    ) {
        guard !isStopping else {
            waiter?.resume(throwing: CancellationError())
            return
        }
        if let storeIdentifier, !pendingAllStores {
            pendingStoreIdentifiers.insert(storeIdentifier)
        } else if storeIdentifier == nil {
            pendingAllStores = true
            pendingStoreIdentifiers.removeAll()
        }
        if let waiter {
            drainWaiters.append(waiter)
        }
        guard !isConsuming else { return }
        isConsuming = true
        Task { @MainActor [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        var failure: (any Error)?

        while pendingAllStores || !pendingStoreIdentifiers.isEmpty {
            let requestedIdentifiers: Set<String>? = pendingAllStores ? nil : pendingStoreIdentifiers
            pendingAllStores = false
            pendingStoreIdentifiers.removeAll()

            do {
                try await consumeHistory(storeIdentifiers: requestedIdentifiers)
                lastError = nil
            } catch {
                failure = error
                lastError = error
                pendingAllStores = false
                pendingStoreIdentifiers.removeAll()
                Self.logger.error("persistent_history_consume_failed")
                break
            }
        }

        isConsuming = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        if let failure {
            waiters.forEach { $0.resume(throwing: failure) }
        } else {
            waiters.forEach { $0.resume() }
        }
        let stopping = stopWaiters
        stopWaiters.removeAll()
        stopping.forEach { $0.resume() }
    }

    private func consumeHistory(storeIdentifiers requestedIdentifiers: Set<String>?) async throws {
        let availableIdentifiers = container.persistentStoreCoordinator.persistentStores
            .map(\.identifier)
            .filter { requestedIdentifiers?.contains($0) ?? true }
            .sorted()

        var fetchedStores: [FetchedStoreHistory] = []
        for storeIdentifier in availableIdentifiers {
            let tokenData = try tokenStore.tokenData(
                vaultIdentifier: vaultIdentifier,
                storeIdentifier: storeIdentifier
            )
            if let fetched = try await fetchHistory(
                storeIdentifier: storeIdentifier,
                after: tokenData
            ) {
                fetchedStores.append(fetched)
            }
        }

        guard !fetchedStores.isEmpty else { return }
        let batch = PersistentHistoryBatch(
            vaultIdentifier: vaultIdentifier,
            stores: fetchedStores.map {
                PersistentHistoryStoreSummary(
                    storeIdentifier: $0.storeIdentifier,
                    transactionCount: $0.transactionCount,
                    latestTransactionAt: $0.latestTransactionAt
                )
            }
        )

        try await reload(batch)

        let nextTokens = Dictionary(
            uniqueKeysWithValues: fetchedStores.map { ($0.storeIdentifier, $0.latestTokenData) }
        )
        try tokenStore.commitTokenData(nextTokens, vaultIdentifier: vaultIdentifier)
    }

    private func fetchHistory(
        storeIdentifier: String,
        after tokenData: Data?
    ) async throws -> FetchedStoreHistory? {
        do {
            return try await executeHistoryFetch(
                storeIdentifier: storeIdentifier,
                tokenData: tokenData
            )
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSPersistentHistoryTokenExpiredError {
            // Replaying from the beginning is conservative and lets downstream
            // projections rebuild without trusting an expired checkpoint.
            return try await executeHistoryFetch(storeIdentifier: storeIdentifier, tokenData: nil)
        }
    }

    private func executeHistoryFetch(
        storeIdentifier: String,
        tokenData: Data?
    ) async throws -> FetchedStoreHistory? {
        let ignoredTransactionAuthor = self.ignoredTransactionAuthor
        return try await historyContext.perform { [historyContext] in
            guard let coordinator = historyContext.persistentStoreCoordinator,
                  let store = coordinator.persistentStores.first(where: { $0.identifier == storeIdentifier }) else {
                throw PersistentHistoryCoordinatorError.storeUnavailable(storeIdentifier)
            }

            let token = tokenData.flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NSPersistentHistoryToken.self,
                    from: $0
                )
            }
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
            guard let transactionFetch = NSPersistentHistoryTransaction.fetchRequest else {
                throw PersistentHistoryCoordinatorError.unexpectedHistoryResult(storeIdentifier)
            }
            transactionFetch.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "author == nil"),
                NSPredicate(format: "author != %@", ignoredTransactionAuthor),
            ])
            request.fetchRequest = transactionFetch
            request.affectedStores = [store]

            guard let result = try historyContext.execute(request) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction] else {
                throw PersistentHistoryCoordinatorError.unexpectedHistoryResult(storeIdentifier)
            }
            guard let latest = transactions.last else { return nil }

            return FetchedStoreHistory(
                storeIdentifier: storeIdentifier,
                transactionCount: transactions.count,
                latestTransactionAt: latest.timestamp,
                latestTokenData: try NSKeyedArchiver.archivedData(
                    withRootObject: latest.token,
                    requiringSecureCoding: true
                )
            )
        }
    }
}
