import CryptoKit
import CoreData
import Foundation
import Testing
@testable import RelationshipCore

private final class MediaMutationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

@Test @MainActor func mediaPayloadRepositoryCommitsMetadataAndBytesTogether() throws {
    let persistence = PersistenceController(inMemory: true)
    let media = MediaPayloadRepository(persistence: persistence)
    let records = RecordRepository(persistence: persistence)
    let portrait = makeSynchronizedPortrait()
    let probe = MediaMutationProbe()
    let token = NotificationCenter.default.addObserver(
        forName: .relationshipNotebookLocalMutationCommitted,
        object: persistence.container.viewContext,
        queue: nil
    ) { _ in
        probe.increment()
    }
    defer { NotificationCenter.default.removeObserver(token) }

    try media.savePortrait(portrait)

    #expect(probe.count == 1)
    #expect(try media.synchronizedData(for: portrait.asset) == portrait.data)
    #expect(try media.payload(for: portrait.asset.id)?.contentHash == portrait.asset.sha256)
    let storedMetadata = try records.fetch(
        PortraitMediaAsset.self,
        kind: "portraitMedia"
    ).map(\.value)
    #expect(storedMetadata.map(\.id) == [portrait.asset.id])
    #expect(storedMetadata.map(\.sha256) == [portrait.asset.sha256])

    #expect(try media.deletePortrait(portrait.asset))
    #expect(probe.count == 2)
    #expect(try media.payload(for: portrait.asset.id) == nil)
    #expect(try media.payload(for: portrait.asset.id, includeDeleted: true)?.deletedAt != nil)
    #expect(try records.fetch(PortraitMediaAsset.self, kind: "portraitMedia").isEmpty)
    #expect(try records.fetch(
        PortraitMediaAsset.self,
        kind: "portraitMedia",
        includeDeleted: true
    ).first?.deletedAt != nil)
}

@Test @MainActor func synchronizedPayloadMaterializesAndRepairsProtectedCache() async throws {
    let persistence = PersistenceController(inMemory: true)
    let media = MediaPayloadRepository(persistence: persistence)
    let portrait = makeSynchronizedPortrait()
    try media.savePortrait(portrait)

    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let files = PortraitMediaFileStore(rootDirectory: temporaryRoot)

    #expect(try await media.materialize(portrait.asset, in: files) == portrait.data)
    #expect(try await files.data(for: portrait.asset) == portrait.data)

    try Data("corrupt cache".utf8).write(to: await files.fileURL(for: portrait.asset.id))
    #expect(try await media.materialize(portrait.asset, in: files) == portrait.data)
    #expect(try await files.data(for: portrait.asset) == portrait.data)

    let orphanID = UUID()
    try portrait.data.write(to: await files.fileURL(for: orphanID))
    let report = await media.reconcileCache(for: [portrait.asset], in: files)
    #expect(report.unavailableIDs.isEmpty)
    #expect(report.removedOrphanCount == 1)
    #expect(!report.cacheCleanupFailed)
    #expect(!FileManager.default.fileExists(atPath: await files.fileURL(for: orphanID).path))
}

@Test @MainActor func reviewedMediaArchiveImportPersistsSynchronizedPayload() throws {
    let persistence = PersistenceController(inMemory: true)
    let notebook = NotebookStore(persistence: persistence)
    let media = MediaPayloadRepository(persistence: persistence)
    let person = Person(displayName: "Imported portrait owner")
    let portrait = makeSynchronizedPortrait(personID: person.id)
    let archive = NotebookArchive(
        people: [person],
        interactions: [],
        canonical: CanonicalArchivePayload(portraitMedia: [portrait.asset])
    )

    try notebook.commitImportedArchive(
        archive,
        mediaPayloads: [portrait.asset.id: portrait.data]
    )

    #expect(try media.synchronizedData(for: portrait.asset) == portrait.data)
    #expect(try notebook.exportArchive().canonical?.portraitMedia?.map(\.id) == [portrait.asset.id])
}

@Test @MainActor func remotePayloadImportRepublishesMetadataAndMaterializesCache() async throws {
    let persistence = PersistenceController(inMemory: true)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let portrait = makeSynchronizedPortrait()
    let remoteContext = persistence.container.newBackgroundContext()

    try remoteContext.performAndWait {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadata = NSEntityDescription.insertNewObject(
            forEntityName: "CanonicalRecordEntity",
            into: remoteContext
        )
        metadata.setValue(portrait.asset.id, forKey: "id")
        metadata.setValue("portraitMedia", forKey: "kind")
        metadata.setValue(try encoder.encode(portrait.asset), forKey: "payload")
        metadata.setValue(portrait.asset.createdAt, forKey: "createdAt")
        metadata.setValue(portrait.asset.modifiedAt, forKey: "modifiedAt")

        let payload = NSEntityDescription.insertNewObject(
            forEntityName: "MediaPayloadEntity",
            into: remoteContext
        )
        payload.setValue(portrait.asset.id, forKey: "id")
        payload.setValue(portrait.data, forKey: "payload")
        payload.setValue(portrait.asset.sha256, forKey: "contentHash")
        payload.setValue(portrait.asset.createdAt, forKey: "createdAt")
        payload.setValue(portrait.asset.modifiedAt, forKey: "modifiedAt")
        try remoteContext.save()
    }

    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let files = PortraitMediaFileStore(rootDirectory: temporaryRoot)
    let report = await canonical.reloadAfterRemoteImport(materializingInto: files)

    #expect(canonical.portraitMedia.map(\.id) == [portrait.asset.id])
    #expect(report.materializedIDs == [portrait.asset.id])
    #expect(try await files.data(for: portrait.asset) == portrait.data)
}

@Test @MainActor func permanentPersonDeletionRemovesSynchronizedPortraitPayload() throws {
    let persistence = PersistenceController(inMemory: true)
    let notebook = NotebookStore(persistence: persistence)
    let media = MediaPayloadRepository(persistence: persistence)
    let person = Person(displayName: "Delete portrait owner")
    let portrait = makeSynchronizedPortrait(personID: person.id)
    notebook.save(person)
    try media.savePortrait(portrait)

    notebook.permanentlyDelete(person, deleteInteractions: true)

    #expect(notebook.person(id: person.id) == nil)
    #expect(try media.payload(for: portrait.asset.id, includeDeleted: true) == nil)
}

private func makeSynchronizedPortrait(personID: UUID = UUID()) -> SanitizedPortrait {
    let data = Data("bounded metadata-free portrait bytes".utf8)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return SanitizedPortrait(
        asset: PortraitMediaAsset(
            personID: personID,
            sha256: hash,
            byteCount: Int64(data.count),
            pixelWidth: 2,
            pixelHeight: 2,
            isPrimary: true
        ),
        data: data
    )
}
