import CoreData
import Foundation
import Testing
@testable import RelationshipCore

@MainActor
private final class MemoryHistoryTokenStore: PersistentHistoryTokenPersisting {
    private(set) var tokensByVault: [String: [String: Data]] = [:]
    var shouldFailCommit = false

    func tokenData(vaultIdentifier: String, storeIdentifier: String) throws -> Data? {
        tokensByVault[vaultIdentifier]?[storeIdentifier]
    }

    func commitTokenData(
        _ tokenDataByStoreIdentifier: [String: Data],
        vaultIdentifier: String
    ) throws {
        if shouldFailCommit { throw HistoryTestError.tokenCommit }
        var existing = tokensByVault[vaultIdentifier] ?? [:]
        existing.merge(tokenDataByStoreIdentifier) { _, replacement in replacement }
        tokensByVault[vaultIdentifier] = existing
    }
}

private enum HistoryTestError: Error {
    case downstream
    case tokenCommit
}

@MainActor
private final class FailableReloadProbe {
    var attempts = 0
    var shouldFail = true

    func reload() throws {
        attempts += 1
        if shouldFail { throw HistoryTestError.downstream }
    }
}

@MainActor
private final class SQLiteHistoryFixture {
    let container: NSPersistentContainer
    let directoryURL: URL

    init(container: NSPersistentContainer, directoryURL: URL) {
        self.container = container
        self.directoryURL = directoryURL
    }

    var storeIdentifier: String {
        container.persistentStoreCoordinator.persistentStores[0].identifier
    }

    func save(author: String?, value: String = UUID().uuidString) throws {
        let context = container.newBackgroundContext()
        context.transactionAuthor = author
        try context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: "HistoryItem", into: context)
            object.setValue(UUID(), forKey: "id")
            object.setValue(value, forKey: "value")
            try context.save()
        }
    }

    func cleanUp() {
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@MainActor
private func makeSQLiteHistoryFixture() async throws -> SQLiteHistoryFixture {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersistentHistoryCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let entity = NSEntityDescription()
    entity.name = "HistoryItem"
    entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

    let id = NSAttributeDescription()
    id.name = "id"
    id.attributeType = .UUIDAttributeType
    id.isOptional = false

    let value = NSAttributeDescription()
    value.name = "value"
    value.attributeType = .stringAttributeType
    value.isOptional = false
    entity.properties = [id, value]

    let model = NSManagedObjectModel()
    model.entities = [entity]

    let container = NSPersistentContainer(name: "HistoryTests", managedObjectModel: model)
    let description = NSPersistentStoreDescription(
        url: directoryURL.appendingPathComponent("History.sqlite")
    )
    description.type = NSSQLiteStoreType
    description.shouldAddStoreAsynchronously = false
    description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
    description.setOption(
        true as NSNumber,
        forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey
    )
    container.persistentStoreDescriptions = [description]

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        container.loadPersistentStores { _, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
    container.viewContext.transactionAuthor = PersistentHistoryCoordinator.userTransactionAuthor
    return SQLiteHistoryFixture(container: container, directoryURL: directoryURL)
}

@Test @MainActor func persistentHistoryIgnoresUserTransactionsAndCheckpointsRemoteOnSuccess() async throws {
    let fixture = try await makeSQLiteHistoryFixture()
    defer { fixture.cleanUp() }
    let tokens = MemoryHistoryTokenStore()
    var batches: [PersistentHistoryBatch] = []
    let coordinator = PersistentHistoryCoordinator(
        container: fixture.container,
        vaultIdentifier: "vault-a",
        tokenStore: tokens,
        automaticallyStart: false
    ) { batch in
        batches.append(batch)
    }

    try fixture.save(author: PersistentHistoryCoordinator.userTransactionAuthor, value: "local")
    try await coordinator.consumePendingHistory()
    #expect(batches.isEmpty)
    #expect(try tokens.tokenData(
        vaultIdentifier: "vault-a",
        storeIdentifier: fixture.storeIdentifier
    ) == nil)

    try fixture.save(author: "cloud.import", value: "remote")
    try await coordinator.consumePendingHistory()

    #expect(batches.count == 1)
    #expect(batches[0].transactionCount == 1)
    #expect(batches[0].stores.map(\.storeIdentifier) == [fixture.storeIdentifier])
    #expect(try tokens.tokenData(
        vaultIdentifier: "vault-a",
        storeIdentifier: fixture.storeIdentifier
    ) != nil)
}

@Test @MainActor func failedDownstreamRefreshLeavesTokenReplayable() async throws {
    let fixture = try await makeSQLiteHistoryFixture()
    defer { fixture.cleanUp() }
    try fixture.save(author: "cloud.import")
    let tokens = MemoryHistoryTokenStore()
    let probe = FailableReloadProbe()
    let coordinator = PersistentHistoryCoordinator(
        container: fixture.container,
        vaultIdentifier: "vault-replay",
        tokenStore: tokens,
        automaticallyStart: false
    ) { _ in
        try probe.reload()
    }

    var observedFailure = false
    do {
        try await coordinator.consumePendingHistory()
    } catch HistoryTestError.downstream {
        observedFailure = true
    }
    #expect(observedFailure)
    #expect(probe.attempts == 1)
    #expect(try tokens.tokenData(
        vaultIdentifier: "vault-replay",
        storeIdentifier: fixture.storeIdentifier
    ) == nil)

    probe.shouldFail = false
    try await coordinator.consumePendingHistory()
    #expect(probe.attempts == 2)
    #expect(try tokens.tokenData(
        vaultIdentifier: "vault-replay",
        storeIdentifier: fixture.storeIdentifier
    ) != nil)
}

@Test @MainActor func tokenCommitFailureAlsoReplaysTheCompletedRefresh() async throws {
    let fixture = try await makeSQLiteHistoryFixture()
    defer { fixture.cleanUp() }
    try fixture.save(author: "cloud.import")
    let tokens = MemoryHistoryTokenStore()
    tokens.shouldFailCommit = true
    var refreshCount = 0
    let coordinator = PersistentHistoryCoordinator(
        container: fixture.container,
        vaultIdentifier: "vault-token-failure",
        tokenStore: tokens,
        automaticallyStart: false
    ) { _ in
        refreshCount += 1
    }

    do {
        try await coordinator.consumePendingHistory()
        Issue.record("Expected token persistence to fail")
    } catch HistoryTestError.tokenCommit {
        // Expected: the downstream refresh ran, but its checkpoint did not advance.
    }
    #expect(refreshCount == 1)
    #expect(try tokens.tokenData(
        vaultIdentifier: "vault-token-failure",
        storeIdentifier: fixture.storeIdentifier
    ) == nil)

    tokens.shouldFailCommit = false
    try await coordinator.consumePendingHistory()
    #expect(refreshCount == 2)
}

@Test @MainActor func historyTokensAreIsolatedByVault() async throws {
    let fixture = try await makeSQLiteHistoryFixture()
    defer { fixture.cleanUp() }
    try fixture.save(author: "cloud.import")
    let tokens = MemoryHistoryTokenStore()
    let firstVault = PersistentHistoryCoordinator(
        container: fixture.container,
        vaultIdentifier: "account-one",
        tokenStore: tokens,
        automaticallyStart: false
    ) { _ in }

    try await firstVault.consumePendingHistory()
    #expect(try tokens.tokenData(
        vaultIdentifier: "account-one",
        storeIdentifier: fixture.storeIdentifier
    ) != nil)
    #expect(try tokens.tokenData(
        vaultIdentifier: "account-two",
        storeIdentifier: fixture.storeIdentifier
    ) == nil)
}

@Test @MainActor func concurrentDrainRequestsAreSerializedAndCoalesced() async throws {
    let fixture = try await makeSQLiteHistoryFixture()
    defer { fixture.cleanUp() }
    try fixture.save(author: "cloud.import")
    let tokens = MemoryHistoryTokenStore()
    var activeRefreshes = 0
    var maximumActiveRefreshes = 0
    var refreshCount = 0
    let coordinator = PersistentHistoryCoordinator(
        container: fixture.container,
        vaultIdentifier: "vault-serial",
        tokenStore: tokens,
        automaticallyStart: false
    ) { _ in
        activeRefreshes += 1
        maximumActiveRefreshes = max(maximumActiveRefreshes, activeRefreshes)
        refreshCount += 1
        await Task.yield()
        activeRefreshes -= 1
    }

    let first = Task { @MainActor in try await coordinator.consumePendingHistory() }
    let second = Task { @MainActor in try await coordinator.consumePendingHistory() }
    try await first.value
    try await second.value

    #expect(maximumActiveRefreshes == 1)
    #expect(refreshCount == 1)
}

@Test @MainActor func remoteChangeNotificationQueuesTheAffectedStore() async throws {
    let fixture = try await makeSQLiteHistoryFixture()
    defer { fixture.cleanUp() }
    try fixture.save(author: "cloud.import")
    let center = NotificationCenter()
    let tokens = MemoryHistoryTokenStore()
    var refreshCount = 0
    let coordinator = PersistentHistoryCoordinator(
        container: fixture.container,
        vaultIdentifier: "vault-notification",
        tokenStore: tokens,
        notificationCenter: center
    ) { _ in
        refreshCount += 1
    }

    center.post(
        name: .NSPersistentStoreRemoteChange,
        object: fixture.container.persistentStoreCoordinator,
        userInfo: [NSStoreUUIDKey: fixture.storeIdentifier]
    )
    for _ in 0..<500 where refreshCount == 0 {
        await Task.yield()
    }

    #expect(refreshCount == 1)
    coordinator.stop()
}
