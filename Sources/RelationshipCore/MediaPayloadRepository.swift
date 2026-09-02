import CoreData
import CryptoKit
import Foundation

public struct MediaPayloadRecord: Sendable, Identifiable {
    public let id: UUID
    public let payload: Data
    public let contentHash: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let deletedAt: Date?
}

public struct PortraitCacheReconciliationResult: Equatable, Sendable {
    public let materializedIDs: [UUID]
    public let unavailableIDs: [UUID]
    public let removedOrphanCount: Int
    public let cacheCleanupFailed: Bool

    public init(
        materializedIDs: [UUID],
        unavailableIDs: [UUID],
        removedOrphanCount: Int,
        cacheCleanupFailed: Bool
    ) {
        self.materializedIDs = materializedIDs
        self.unavailableIDs = unavailableIDs
        self.removedOrphanCount = removedOrphanCount
        self.cacheCleanupFailed = cacheCleanupFailed
    }
}

/// Owns the synchronized binary half of a portrait. `MediaPayloadEntity` lives
/// in the private Vault store, while `PortraitMediaFileStore` remains a
/// replaceable, protected device-local cache.
@MainActor
public final class MediaPayloadRepository {
    private let persistence: PersistenceController
    private let context: NSManagedObjectContext
    private let deletionMarkers: SynchronizedDeletionMarkerRepository
    private let encoder: JSONEncoder

    public init(persistence: PersistenceController) {
        self.persistence = persistence
        context = persistence.container.viewContext
        deletionMarkers = SynchronizedDeletionMarkerRepository(persistence: persistence)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    /// Commits metadata and sanitized bytes in one local Vault transaction so
    /// CloudKit never receives a newly-created portrait without its payload.
    public func savePortrait(_ portrait: SanitizedPortrait, now: Date = .now) throws {
        do {
            try persistence.requireWritable()
            let target = SynchronizedDeletionTarget.vaultRecord(
                id: portrait.asset.id,
                kind: "portraitMedia"
            )
            let metadata = try findMetadata(id: portrait.asset.id)
            let payload = try findPayload(id: portrait.asset.id)
            let preparation = try deletionMarkers.writePreparation(
                for: target,
                existingObjects: [metadata, payload].compactMap { $0 }
            )
            try validate(portrait)
            try stageMetadataUpsert(portrait.asset, now: now)
            if let stagedMetadata = try findMetadata(id: portrait.asset.id) {
                _ = try deletionMarkers.stamp(preparation, on: [stagedMetadata])
            }
            try stagePayloadUpsert(portrait, now: now)
            let savedMetadata = try findMetadata(id: portrait.asset.id)
            let savedPayload = try findPayload(id: portrait.asset.id)
            _ = try deletionMarkers.stamp(
                preparation,
                on: [savedMetadata, savedPayload].compactMap { $0 }
            )
            guard context.hasChanges else { return }
            try context.save()
            postLocalMutationCommitted(
                source: context,
                at: now,
                storeConfigurations: [CloudSyncStoreConfiguration.vault]
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Soft-deletes metadata and synchronized bytes together. The local cache
    /// is staged/finalized separately by the UI so it can be restored if this
    /// transaction fails.
    @discardableResult
    public func deletePortrait(_ asset: PortraitMediaAsset, now: Date = .now) throws -> Bool {
        do {
            try persistence.requireWritable()
            var changed = false
            if let metadata = try findMetadata(id: asset.id) {
                metadata.setValue(now, forKey: "deletedAt")
                metadata.setValue(now, forKey: "modifiedAt")
                changed = true
            }
            if let payload = try findPayload(id: asset.id) {
                payload.setValue(now, forKey: "deletedAt")
                payload.setValue(now, forKey: "modifiedAt")
                changed = true
            }
            guard changed else { return false }
            try context.save()
            postLocalMutationCommitted(
                source: context,
                at: now,
                storeConfigurations: [CloudSyncStoreConfiguration.vault]
            )
            return true
        } catch {
            context.rollback()
            throw error
        }
    }

    public func payload(
        for id: UUID,
        includeDeleted: Bool = false
    ) throws -> MediaPayloadRecord? {
        guard let object = try findPayload(id: id) else { return nil }
        let deletedAt = object.value(forKey: "deletedAt") as? Date
        guard includeDeleted || deletedAt == nil else { return nil }
        guard let storedID = object.value(forKey: "id") as? UUID,
              let payload = object.value(forKey: "payload") as? Data,
              let contentHash = object.value(forKey: "contentHash") as? String else {
            throw PortraitMediaError.integrityMismatch
        }
        return MediaPayloadRecord(
            id: storedID,
            payload: payload,
            contentHash: contentHash,
            createdAt: object.value(forKey: "createdAt") as? Date ?? .distantPast,
            modifiedAt: object.value(forKey: "modifiedAt") as? Date ?? .distantPast,
            deletedAt: deletedAt
        )
    }

    /// Returns verified synchronized bytes. A missing payload can be temporary
    /// while CloudKit is importing, so callers may retry after the next import
    /// completion notification.
    public func synchronizedData(for asset: PortraitMediaAsset) throws -> Data {
        guard asset.metadataWasStripped,
              let record = try payload(for: asset.id),
              record.contentHash.lowercased() == asset.sha256.lowercased(),
              Int64(record.payload.count) == asset.byteCount,
              Self.sha256(record.payload) == asset.sha256.lowercased() else {
            throw PortraitMediaError.integrityMismatch
        }
        return record.payload
    }

    /// Reads the protected cache first, then repairs or creates it from the
    /// synchronized payload after verifying the metadata-bound checksum.
    @discardableResult
    public func materialize(
        _ asset: PortraitMediaAsset,
        in fileStore: PortraitMediaFileStore
    ) async throws -> Data {
        if let cached = try? await fileStore.data(for: asset) {
            return cached
        }
        let data = try synchronizedData(for: asset)
        try await fileStore.store(SanitizedPortrait(asset: asset, data: data))
        return data
    }

    /// Materializes every available synchronized portrait and removes only
    /// recognizable top-level cache files whose stable IDs are no longer in
    /// the active metadata set. Staging directories are never touched.
    public func reconcileCache(
        for assets: [PortraitMediaAsset],
        in fileStore: PortraitMediaFileStore
    ) async -> PortraitCacheReconciliationResult {
        var materialized: [UUID] = []
        var unavailable: [UUID] = []
        for asset in assets {
            do {
                _ = try await materialize(asset, in: fileStore)
                materialized.append(asset.id)
            } catch {
                unavailable.append(asset.id)
            }
        }

        let cleanup: (count: Int, failed: Bool)
        do {
            cleanup = (
                try await fileStore.removeCachedPortraits(except: Set(assets.map(\.id))),
                false
            )
        } catch {
            cleanup = (0, true)
        }
        return PortraitCacheReconciliationResult(
            materializedIDs: materialized,
            unavailableIDs: unavailable,
            removedOrphanCount: cleanup.count,
            cacheCleanupFailed: cleanup.failed
        )
    }

    /// Stages bytes into the caller's existing Core Data transaction. Used by
    /// reviewed archive and local-to-iCloud imports after their metadata has
    /// already been staged on the same view context.
    func stagePayloadUpsert(_ portrait: SanitizedPortrait, now: Date = .now) throws {
        try persistence.requireWritable()
        let target = SynchronizedDeletionTarget.vaultRecord(
            id: portrait.asset.id,
            kind: "portraitMedia"
        )
        let metadata = try findMetadata(id: portrait.asset.id)
        let payload = try findPayload(id: portrait.asset.id)
        let preparation = try deletionMarkers.writePreparation(
            for: target,
            existingObjects: [metadata, payload].compactMap { $0 }
        )
        try validate(portrait)
        let object = try payloadObject(id: portrait.asset.id)
        _ = try deletionMarkers.stamp(preparation, on: [object])
        if object.value(forKey: "createdAt") == nil {
            object.setValue(portrait.asset.createdAt, forKey: "createdAt")
        }
        object.setValue(portrait.asset.id, forKey: "id")
        object.setValue(portrait.data, forKey: "payload")
        object.setValue(portrait.asset.sha256.lowercased(), forKey: "contentHash")
        object.setValue(now, forKey: "modifiedAt")
        object.setValue(nil, forKey: "deletedAt")
    }

    private func stageMetadataUpsert(_ asset: PortraitMediaAsset, now: Date) throws {
        let object = try metadataObject(id: asset.id)
        if object.value(forKey: "createdAt") == nil {
            object.setValue(asset.createdAt, forKey: "createdAt")
        }
        object.setValue(asset.id, forKey: "id")
        object.setValue("portraitMedia", forKey: "kind")
        object.setValue(try encoder.encode(asset), forKey: "payload")
        object.setValue(now, forKey: "modifiedAt")
        object.setValue(nil, forKey: "deletedAt")
    }

    private func validate(_ portrait: SanitizedPortrait) throws {
        guard portrait.asset.metadataWasStripped,
              portrait.asset.byteCount == Int64(portrait.data.count),
              portrait.asset.sha256.lowercased() == Self.sha256(portrait.data) else {
            throw PortraitMediaError.integrityMismatch
        }
    }

    private func metadataObject(id: UUID) throws -> NSManagedObject {
        if let existing = try findMetadata(id: id) { return existing }
        return NSEntityDescription.insertNewObject(
            forEntityName: "CanonicalRecordEntity",
            into: context
        )
    }

    private func payloadObject(id: UUID) throws -> NSManagedObject {
        if let existing = try findPayload(id: id) { return existing }
        return NSEntityDescription.insertNewObject(
            forEntityName: "MediaPayloadEntity",
            into: context
        )
    }

    private func findMetadata(id: UUID) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CanonicalRecordEntity")
        request.fetchLimit = 1
        request.predicate = NSPredicate(
            format: "id == %@ AND kind == %@",
            id as CVarArg,
            "portraitMedia"
        )
        return try context.fetch(request).first
    }

    private func findPayload(id: UUID) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MediaPayloadEntity")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request).first
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
