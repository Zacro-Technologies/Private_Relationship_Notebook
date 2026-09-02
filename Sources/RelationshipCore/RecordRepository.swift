import CoreData
import Foundation

public enum CanonicalStore: String, Sendable, Hashable {
    case vault
    case ownedProfiles
    case derived

    var entityName: String {
        switch self {
        case .vault: "CanonicalRecordEntity"
        case .ownedProfiles: "ProfileRecordEntity"
        case .derived: "DerivedRecordEntity"
        }
    }

    var participatesInCloudSync: Bool {
        switch self {
        case .vault, .ownedProfiles: true
        case .derived: false
        }
    }
}

public struct StoredRecord<Value: Sendable>: Sendable, Identifiable {
    public let id: UUID
    public let kind: String
    public let value: Value
    public let createdAt: Date
    public let modifiedAt: Date
    public let deletedAt: Date?
}

/// Payload-free reference used by the recovery UI. Keeping this projection
/// payload-free lets Recently Deleted enumerate every canonical record family,
/// including records created by a newer app version, without decoding or
/// exposing private values merely to offer Restore.
public struct DeletedRecordReference: Hashable, Sendable, Identifiable {
    public var id: String { "\(store.rawValue):\(kind):\(recordID.uuidString.lowercased())" }
    public let recordID: UUID
    public let kind: String
    public let store: CanonicalStore
    public let deletedAt: Date
    public let modifiedAt: Date

    public init(
        recordID: UUID,
        kind: String,
        store: CanonicalStore = .vault,
        deletedAt: Date,
        modifiedAt: Date
    ) {
        self.recordID = recordID
        self.kind = kind
        self.store = store
        self.deletedAt = deletedAt
        self.modifiedAt = modifiedAt
    }
}

public enum RecordRepositoryError: LocalizedError {
    case missingIdentifier(kind: String)
    case missingPayload(id: UUID, kind: String)
    case undecodablePayload(id: UUID, kind: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .missingIdentifier(let kind):
            String(localized: "A stored \(kind) record has no stable identifier.")
        case .missingPayload(_, let kind):
            String(localized: "A stored \(kind) record has no readable payload.")
        case .undecodablePayload(_, let kind, _):
            String(localized: "A stored \(kind) record uses an unreadable or unsupported payload.")
        }
    }
}

@MainActor
public final class RecordRepository {
    private let persistence: PersistenceController
    private let context: NSManagedObjectContext
    private let deletionMarkers: SynchronizedDeletionMarkerRepository
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(persistence: PersistenceController) {
        self.persistence = persistence
        context = persistence.container.viewContext
        deletionMarkers = SynchronizedDeletionMarkerRepository(persistence: persistence)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func upsert<Value: Encodable>(
        _ value: Value,
        id: UUID,
        kind: String,
        in store: CanonicalStore = .vault,
        now: Date = .now
    ) throws {
        do {
            try persistence.requireWritable()
            try stageUpsert(value, id: id, kind: kind, in: store, now: now)
            try context.save()
            notifyCommittedMutation(in: store)
        } catch {
            context.rollback()
            throw error
        }
    }

    public func upsertAll<Value: Encodable & Identifiable>(
        _ values: [Value],
        kind: String,
        in store: CanonicalStore = .vault,
        now: Date = .now
    ) throws where Value.ID == UUID {
        do {
            try persistence.requireWritable()
            for value in values {
                try stageUpsert(value, id: value.id, kind: kind, in: store, now: now)
            }
            if !values.isEmpty {
                try context.save()
                notifyCommittedMutation(in: store)
            }
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Stages the heterogeneous records produced by one received-profile
    /// review and saves them exactly once. This closes the partial-source gap
    /// even for callers that attach the import to an existing Person.
    public func upsertReceivedProfileAtomically(
        source: SourceArtifact?,
        assertions: [AssertionEnvelope],
        now: Date = .now
    ) throws {
        do {
            try persistence.requireWritable()
            if let source {
                try stageUpsert(source, id: source.id, kind: "source", in: .vault, now: now)
            }
            for assertion in assertions {
                try stageUpsert(
                    assertion,
                    id: assertion.id,
                    kind: "assertion",
                    in: .vault,
                    now: now
                )
            }
            if source != nil || !assertions.isEmpty {
                try context.save()
                notifyCommittedMutation(in: .vault)
            }
        } catch {
            context.rollback()
            throw error
        }
    }

    private func stageUpsert<Value: Encodable>(
        _ value: Value,
        id: UUID,
        kind: String,
        in store: CanonicalStore,
        now: Date
    ) throws {
        try validateUserKind(kind)
        let existing = try find(id: id, kind: kind, in: store)
        let preparation = try deletionTarget(id: id, kind: kind, store: store).map {
            try deletionMarkers.writePreparation(
                for: $0,
                existingObjects: existing.map { [$0] } ?? []
            )
        }
        let object = existing ?? NSEntityDescription.insertNewObject(
            forEntityName: store.entityName,
            into: context
        )
        if let preparation {
            _ = try deletionMarkers.stamp(preparation, on: [object])
        }
        if object.value(forKey: "createdAt") == nil {
            object.setValue(now, forKey: "createdAt")
        }
        object.setValue(id, forKey: "id")
        object.setValue(kind, forKey: "kind")
        object.setValue(try encoder.encode(value), forKey: "payload")
        object.setValue(now, forKey: "modifiedAt")
        object.setValue(nil, forKey: "deletedAt")
    }

    public func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        kind: String,
        from store: CanonicalStore = .vault,
        includeDeleted: Bool = false
    ) throws -> [StoredRecord<Value>] {
        try validateUserKind(kind)
        let request = NSFetchRequest<NSManagedObject>(entityName: store.entityName)
        request.predicate = includeDeleted
            ? NSPredicate(format: "kind == %@", kind)
            : NSPredicate(format: "kind == %@ AND deletedAt == nil", kind)
        request.sortDescriptors = [NSSortDescriptor(key: "modifiedAt", ascending: false)]
        return try context.fetch(request).map { object in
            guard let id = object.value(forKey: "id") as? UUID else {
                throw RecordRepositoryError.missingIdentifier(kind: kind)
            }
            guard let data = object.value(forKey: "payload") as? Data else {
                throw RecordRepositoryError.missingPayload(id: id, kind: kind)
            }
            let value: Value
            do {
                value = try decoder.decode(type, from: data)
            } catch {
                throw RecordRepositoryError.undecodablePayload(
                    id: id,
                    kind: kind,
                    reason: String(describing: error)
                )
            }
            return StoredRecord(
                id: id,
                kind: kind,
                value: value,
                createdAt: object.value(forKey: "createdAt") as? Date ?? .distantPast,
                modifiedAt: object.value(forKey: "modifiedAt") as? Date ?? .distantPast,
                deletedAt: object.value(forKey: "deletedAt") as? Date
            )
        }
    }

    public func deletedRecords(
        in store: CanonicalStore = .vault
    ) throws -> [DeletedRecordReference] {
        let request = NSFetchRequest<NSManagedObject>(entityName: store.entityName)
        if store == .vault {
            request.predicate = NSPredicate(
                format: "deletedAt != nil AND NOT (kind BEGINSWITH %@) AND kind != %@",
                SynchronizedDeletionMarkerRepository.markerKindPrefix,
                SynchronizedDeletionMarkerRepository.wipeEpochKind
            )
        } else {
            request.predicate = NSPredicate(format: "deletedAt != nil")
        }
        request.sortDescriptors = [NSSortDescriptor(key: "deletedAt", ascending: false)]
        return try context.fetch(request).map { object in
            guard let recordID = object.value(forKey: "id") as? UUID,
                  let kind = object.value(forKey: "kind") as? String,
                  let deletedAt = object.value(forKey: "deletedAt") as? Date else {
                throw RecordRepositoryError.missingIdentifier(kind: "deleted record")
            }
            return DeletedRecordReference(
                recordID: recordID,
                kind: kind,
                store: store,
                deletedAt: deletedAt,
                modifiedAt: object.value(forKey: "modifiedAt") as? Date ?? deletedAt
            )
        }
    }

    public func softDelete(id: UUID, kind: String, in store: CanonicalStore = .vault, now: Date = .now) throws {
        try persistence.requireWritable()
        try validateUserKind(kind)
        guard let object = try find(id: id, kind: kind, in: store) else { return }
        object.setValue(now, forKey: "deletedAt")
        object.setValue(now, forKey: "modifiedAt")
        try context.save()
        notifyCommittedMutation(in: store)
    }

    public func restore(id: UUID, kind: String, in store: CanonicalStore = .vault, now: Date = .now) throws {
        try persistence.requireWritable()
        try validateUserKind(kind)
        guard let object = try find(id: id, kind: kind, in: store) else { return }
        if let target = deletionTarget(id: id, kind: kind, store: store) {
            let preparation = try deletionMarkers.writePreparation(
                for: target,
                existingObjects: [object]
            )
            _ = try deletionMarkers.stamp(preparation, on: [object])
        }
        object.setValue(nil, forKey: "deletedAt")
        object.setValue(now, forKey: "modifiedAt")
        try context.save()
        notifyCommittedMutation(in: store)
    }

    public func purgeDeleted(before cutoff: Date, in store: CanonicalStore = .vault) throws -> Int {
        try persistence.requireWritable()
        let request = NSFetchRequest<NSManagedObject>(entityName: store.entityName)
        if store == .vault {
            request.predicate = NSPredicate(
                format: "deletedAt != nil AND deletedAt < %@ AND NOT (kind BEGINSWITH %@) AND kind != %@",
                cutoff as NSDate,
                SynchronizedDeletionMarkerRepository.markerKindPrefix,
                SynchronizedDeletionMarkerRepository.wipeEpochKind
            )
        } else {
            request.predicate = NSPredicate(
                format: "deletedAt != nil AND deletedAt < %@",
                cutoff as NSDate
            )
        }
        let objects = try context.fetch(request)
        var permanentlyDeletedObjects = objects
        if store == .vault {
            let portraitIDs = objects.compactMap { object -> UUID? in
                guard object.value(forKey: "kind") as? String == "portraitMedia" else {
                    return nil
                }
                return object.value(forKey: "id") as? UUID
            }
            if !portraitIDs.isEmpty {
                let payloadRequest = NSFetchRequest<NSManagedObject>(entityName: "MediaPayloadEntity")
                payloadRequest.predicate = NSPredicate(format: "id IN %@", portraitIDs)
                permanentlyDeletedObjects.append(contentsOf: try context.fetch(payloadRequest))
            }
        }
        if !permanentlyDeletedObjects.isEmpty {
            let markerChanged = try deletionMarkers.markPermanentlyDeleted(
                objects: permanentlyDeletedObjects
            )
            if markerChanged, store.participatesInCloudSync {
                do {
                    try context.save()
                    postLocalMutationCommitted(
                        source: context,
                        storeConfigurations: [CloudSyncStoreConfiguration.vault]
                    )
                } catch {
                    context.rollback()
                    throw error
                }
            }
            permanentlyDeletedObjects.forEach(context.delete)
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            notifyCommittedMutation(in: store)
        }
        return objects.count
    }

    /// Invalidates registered snapshots after an external store writer (such
    /// as CloudKit import) commits. It never discards an unsaved local edit.
    public func refreshAfterRemoteImport() {
        context.processPendingChanges()
        guard !context.hasChanges else { return }
        context.refreshAllObjects()
    }

    public func counts() throws -> [CanonicalStore: Int] {
        var result: [CanonicalStore: Int] = [:]
        for store in [CanonicalStore.vault, .ownedProfiles, .derived] {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: store.entityName)
            request.predicate = store == .vault
                ? NSPredicate(
                    format: "deletedAt == nil AND NOT (kind BEGINSWITH %@) AND kind != %@",
                    SynchronizedDeletionMarkerRepository.markerKindPrefix,
                    SynchronizedDeletionMarkerRepository.wipeEpochKind
                )
                : NSPredicate(format: "deletedAt == nil")
            result[store] = try context.count(for: request)
        }
        return result
    }

    private func object(id: UUID, kind: String, in store: CanonicalStore) throws -> NSManagedObject {
        if let existing = try find(id: id, kind: kind, in: store) { return existing }
        return NSEntityDescription.insertNewObject(forEntityName: store.entityName, into: context)
    }

    private func find(id: UUID, kind: String, in store: CanonicalStore) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: store.entityName)
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@ AND kind == %@", id as CVarArg, kind)
        return try context.fetch(request).first
    }

    private func deletionTarget(
        id: UUID,
        kind: String,
        store: CanonicalStore
    ) -> SynchronizedDeletionTarget? {
        switch store {
        case .vault:
            return .vaultRecord(id: id, kind: kind)
        case .ownedProfiles:
            return .ownedProfileRecord(id: id, kind: kind)
        case .derived:
            return nil
        }
    }

    private func validateUserKind(_ kind: String) throws {
        guard !SynchronizedDeletionMarkerRepository.isReservedKind(kind),
              !DeletionConflictDraftRepository.isReservedKind(kind) else {
            throw SynchronizedDeletionMarkerError.reservedSynchronizationKind(kind)
        }
    }

    private func notifyCommittedMutation(in store: CanonicalStore) {
        guard store.participatesInCloudSync else { return }
        let configuration: String
        switch store {
        case .vault:
            configuration = CloudSyncStoreConfiguration.vault
        case .ownedProfiles:
            configuration = CloudSyncStoreConfiguration.ownedProfiles
        case .derived:
            return
        }
        postLocalMutationCommitted(source: context, storeConfigurations: [configuration])
    }
}
