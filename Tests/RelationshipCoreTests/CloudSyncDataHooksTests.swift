import CoreData
import Foundation
import Testing
@testable import RelationshipCore

private struct SyncHookRecord: Codable, Sendable {
    let title: String
}

private final class SyncNotificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var notifications: [Notification] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return notifications.count
    }

    var lastCommittedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return notifications.last?.userInfo?[CloudSyncNotificationUserInfoKey.committedAt] as? Date
    }

    var lastStoreConfigurations: Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        guard let values = notifications.last?.userInfo?[
            CloudSyncNotificationUserInfoKey.storeConfigurations
        ] as? [String] else { return nil }
        return Set(values)
    }

    func record(_ notification: Notification) {
        lock.lock()
        notifications.append(notification)
        lock.unlock()
    }
}

@Test @MainActor func cloudSyncMutationNotificationTracksOnlyCommittedMirroredWrites() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let records = RecordRepository(persistence: persistence)
    let probe = SyncNotificationProbe()
    let token = NotificationCenter.default.addObserver(
        forName: .relationshipNotebookLocalMutationCommitted,
        object: persistence.container.viewContext,
        queue: nil
    ) { notification in
        probe.record(notification)
    }
    defer { NotificationCenter.default.removeObserver(token) }

    store.reload()
    _ = try records.fetch(SyncHookRecord.self, kind: "syncHook")
    #expect(probe.count == 0)

    store.save(Person(displayName: "Locally edited"))
    #expect(probe.count == 1)
    #expect(probe.lastCommittedAt != nil)

    try records.upsert(
        SyncHookRecord(title: "Search cache"),
        id: UUID(),
        kind: "syncHook",
        in: .derived
    )
    #expect(probe.count == 1)

    try records.upsert(
        SyncHookRecord(title: "Vault record"),
        id: UUID(),
        kind: "syncHook",
        in: .vault
    )
    #expect(probe.count == 2)
    #expect(probe.lastStoreConfigurations == [CloudSyncStoreConfiguration.vault])

    try records.upsert(
        SyncHookRecord(title: "Owned profile record"),
        id: UUID(),
        kind: "syncHook",
        in: .ownedProfiles
    )
    #expect(probe.count == 3)
    #expect(probe.lastStoreConfigurations == [CloudSyncStoreConfiguration.ownedProfiles])
}

@Test @MainActor func reviewedArchiveImportIsLocalEditButRemoteReloadIsNot() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let probe = SyncNotificationProbe()
    let token = NotificationCenter.default.addObserver(
        forName: .relationshipNotebookLocalMutationCommitted,
        object: persistence.container.viewContext,
        queue: nil
    ) { notification in
        probe.record(notification)
    }
    defer { NotificationCenter.default.removeObserver(token) }

    try store.commitImportedArchive(NotebookArchive(
        people: [Person(displayName: "Imported")],
        interactions: []
    ))
    #expect(probe.count == 1)

    store.reloadAfterRemoteImport()
    canonical.reloadAfterRemoteImport()

    #expect(probe.count == 1)
    #expect(store.people.map(\.displayName) == ["Imported"])
}

@Test @MainActor func remoteImportReloadRepublishesBackgroundContextChanges() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let importedID = UUID()
    let importedContext = Context(
        kind: .community,
        names: LocalizedText("Imported community")
    )
    let remoteContext = persistence.container.newBackgroundContext()

    try remoteContext.performAndWait {
        let object = NSEntityDescription.insertNewObject(
            forEntityName: "PersonEntity",
            into: remoteContext
        )
        object.setValue(importedID, forKey: "id")
        object.setValue("From iCloud", forKey: "displayName")
        object.setValue(Date.now, forKey: "createdAt")
        object.setValue(Date.now, forKey: "modifiedAt")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let canonicalObject = NSEntityDescription.insertNewObject(
            forEntityName: "CanonicalRecordEntity",
            into: remoteContext
        )
        canonicalObject.setValue(importedContext.id, forKey: "id")
        canonicalObject.setValue("context", forKey: "kind")
        canonicalObject.setValue(try encoder.encode(importedContext), forKey: "payload")
        canonicalObject.setValue(importedContext.createdAt, forKey: "createdAt")
        canonicalObject.setValue(importedContext.modifiedAt, forKey: "modifiedAt")
        try remoteContext.save()
    }

    store.reloadAfterRemoteImport()
    canonical.reloadAfterRemoteImport()

    #expect(store.person(id: importedID)?.displayName == "From iCloud")
    #expect(canonical.contexts.map(\.id) == [importedContext.id])
}
