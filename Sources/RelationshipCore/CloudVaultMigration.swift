import CoreData
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CloudMigrationEventKind: Equatable, Sendable {
    case setup
    case importing
    case exporting
}

public struct CloudMigrationEventSummary: Equatable, Sendable {
    public let storeIdentifier: String
    public let kind: CloudMigrationEventKind
    public let startDate: Date
    public let endDate: Date?
    public let succeeded: Bool

    public init(
        storeIdentifier: String,
        kind: CloudMigrationEventKind,
        startDate: Date,
        endDate: Date?,
        succeeded: Bool
    ) {
        self.storeIdentifier = storeIdentifier
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
        self.succeeded = succeeded
    }
}

public struct CloudMigrationReadiness: Equatable, Sendable {
    public let sessionStartedAt: Date
    public let readyStoreIdentifiers: Set<String>
    public let pendingStoreIdentifiers: Set<String>

    public var isReady: Bool {
        !readyStoreIdentifiers.isEmpty && pendingStoreIdentifiers.isEmpty
    }

    public init(
        mirroredStoreIdentifiers: Set<String>,
        events: [CloudMigrationEventSummary],
        sessionStartedAt: Date
    ) {
        var ready: Set<String> = []
        for storeIdentifier in mirroredStoreIdentifiers {
            let storeEvents = events
                .filter {
                    $0.storeIdentifier == storeIdentifier
                        && $0.startDate >= sessionStartedAt
                }
                .sorted { $0.startDate < $1.startDate }
            guard let latestSetup = storeEvents.last(where: { $0.kind == .setup }),
                  latestSetup.endDate != nil,
                  latestSetup.succeeded,
                  let latestImport = storeEvents.last(where: {
                      $0.kind == .importing && $0.startDate >= latestSetup.startDate
                  }),
                  latestImport.endDate != nil,
                  latestImport.succeeded else {
                continue
            }
            let hasActiveSetupOrImport = storeEvents.contains {
                ($0.kind == .setup || $0.kind == .importing)
                    && $0.startDate >= latestSetup.startDate
                    && $0.endDate == nil
            }
            if !hasActiveSetupOrImport { ready.insert(storeIdentifier) }
        }
        self.sessionStartedAt = sessionStartedAt
        readyStoreIdentifiers = ready
        pendingStoreIdentifiers = mirroredStoreIdentifiers.subtracting(ready)
    }
}

public struct CloudMigrationMediaPayload: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { asset.id }
    public var asset: PortraitMediaAsset
    public var data: Data

    public init(asset: PortraitMediaAsset, data: Data) {
        self.asset = asset
        self.data = data
    }
}

/// Fully validated portrait bytes from a protected local-to-iCloud checkpoint.
/// Migration review can use the stable-ID set without claiming that an image is
/// available merely because a same-ID envelope exists, and commit can reuse the
/// exact bytes that passed validation.
public struct CloudVaultMigrationMediaPreflight: Equatable, Sendable {
    public let payloadsByID: [UUID: Data]

    init(payloadsByID: [UUID: Data]) {
        self.payloadsByID = payloadsByID
    }

    public var verifiedPortraitMediaIDs: Set<UUID> {
        Set(payloadsByID.keys)
    }

    public func payloads(for selectedIDs: Set<UUID>) -> [UUID: Data] {
        payloadsByID.filter { selectedIDs.contains($0.key) }
    }
}

/// A protected, app-internal checkpoint used while moving a local notebook to
/// a separate CloudKit replica. It is not an external export and is retained as
/// a recovery backup until the user explicitly removes the local vault.
public struct CloudVaultMigrationPackage: Codable, Sendable {
    public static let currentVersion = 3

    public var version: Int
    public var createdAt: Date
    public var archive: NotebookArchive
    public var media: [CloudMigrationMediaPayload]
    public var durableDeletionState: DurableDeletionState
    public var recoverableDeletions: RecoverableDeletionCheckpoint

    public init(
        version: Int = currentVersion,
        createdAt: Date = .now,
        archive: NotebookArchive,
        media: [CloudMigrationMediaPayload] = [],
        durableDeletionState: DurableDeletionState = .init(),
        recoverableDeletions: RecoverableDeletionCheckpoint = .init()
    ) {
        self.version = version
        self.createdAt = createdAt
        self.archive = archive
        self.media = media
        self.durableDeletionState = durableDeletionState
        self.recoverableDeletions = recoverableDeletions
    }

    /// A checkpoint containing only durable deletion controls still has work
    /// to review and apply. In particular, a whole-vault wipe must never be
    /// mistaken for an empty local notebook and silently skipped.
    public var requiresReviewedMigration: Bool {
        !CloudVaultInventory(
            archive: archive,
            durableDeletionState: durableDeletionState
        ).isEmpty || !durableDeletionState.generationMemberships.isEmpty
            || !recoverableDeletions.isEmpty
            || !media.isEmpty
    }

    /// Validates the complete portrait package before any migration phase is
    /// allowed to mutate its iCloud destination. Every archive portrait must
    /// have exactly one matching payload, and payload envelopes not represented
    /// by the archive are rejected rather than silently ignored.
    public func preflightMediaPayloads(
        limits: PortraitImportLimits = .init()
    ) throws -> CloudVaultMigrationMediaPreflight {
        let archiveAssets = archive.canonical?.portraitMedia ?? []
        let archiveGroups = Dictionary(grouping: archiveAssets, by: \.id)
        if let duplicateID = archiveGroups.keys
            .filter({ archiveGroups[$0]?.count != 1 })
            .sorted(by: Self.uuidOrder)
            .first {
            throw CloudVaultMigrationError.duplicatePortraitMetadata(duplicateID)
        }

        let payloadGroups = Dictionary(grouping: media, by: \.id)
        if payloadGroups.values.contains(where: { $0.count != 1 }) {
            throw CloudVaultMigrationError.duplicateMediaPayload
        }

        let archiveIDs = Set(archiveGroups.keys)
        let payloadIDs = Set(payloadGroups.keys)
        if let missingID = archiveIDs.subtracting(payloadIDs)
            .sorted(by: Self.uuidOrder)
            .first {
            throw CloudVaultMigrationError.missingMediaPayload(missingID)
        }
        if let orphanID = payloadIDs.subtracting(archiveIDs)
            .sorted(by: Self.uuidOrder)
            .first {
            throw CloudVaultMigrationError.orphanMediaPayload(orphanID)
        }

        var result: [UUID: Data] = [:]
        for id in archiveIDs.sorted(by: Self.uuidOrder) {
            guard let archiveAsset = archiveGroups[id]?.first,
                  let payload = payloadGroups[id]?.first else {
                throw CloudVaultMigrationError.missingMediaPayload(id)
            }
            guard payload.asset == archiveAsset else {
                throw CloudVaultMigrationError.mediaAssetMismatch(id)
            }
            guard Self.isValidMediaPayload(payload, limits: limits) else {
                throw CloudVaultMigrationError.invalidMediaPayload(id)
            }
            result[id] = payload.data
        }
        return CloudVaultMigrationMediaPreflight(payloadsByID: result)
    }

    private static func isValidMediaPayload(
        _ payload: CloudMigrationMediaPayload,
        limits: PortraitImportLimits
    ) -> Bool {
        let asset = payload.asset
        let data = payload.data
        guard asset.metadataWasStripped,
              !data.isEmpty,
              data.count <= limits.maximumInputBytes,
              data.count <= limits.maximumOutputBytes,
              asset.byteCount == Int64(data.count),
              asset.pixelWidth > 0,
              asset.pixelHeight > 0,
              asset.pixelWidth <= limits.maximumOutputDimension,
              asset.pixelHeight <= limits.maximumOutputDimension,
              let declaredType = UTType(asset.contentType),
              declaredType.conforms(to: .jpeg),
              asset.sha256.lowercased() == sha256(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let sourceTypeIdentifier = CGImageSourceGetType(source) as String?,
              let sourceType = UTType(sourceTypeIdentifier),
              sourceType == declaredType,
              sourceType.conforms(to: .jpeg),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width == asset.pixelWidth,
              height == asset.pixelHeight else {
            return false
        }
        let (pixelCount, overflowed) = Int64(width).multipliedReportingOverflow(
            by: Int64(height)
        )
        return !overflowed && pixelCount <= limits.maximumSourcePixels
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
}

public struct CloudVaultInventory: Equatable, Sendable {
    public var people: Int
    public var interactions: Int
    public var structuredRecords: Int
    public var profileSnapshots: Int
    public var media: Int
    public var preservedExtensionFields: Int
    public var durableDeletionTargets: Int
    public var wipeEpochs: Int
    public var recoverableDeletedRows: Int

    public init(
        archive: NotebookArchive,
        durableDeletionState: DurableDeletionState = .init(),
        recoverableDeletions: RecoverableDeletionCheckpoint = .init()
    ) {
        people = archive.people.count
        interactions = archive.interactions.count
        let canonical = archive.canonical
        let relationshipRows = (canonical?.contexts.count ?? 0)
            + (canonical?.cohortSchemes.count ?? 0)
            + (canonical?.cohorts.count ?? 0)
            + (canonical?.memberships.count ?? 0)
            + (canonical?.cohortAssignments.count ?? 0)
            + (canonical?.roleDefinitions.count ?? 0)
            + (canonical?.roleAssignments.count ?? 0)
            + (canonical?.education.count ?? 0)
        let knowledgeRows = (canonical?.assertions.count ?? 0)
            + (canonical?.sources.count ?? 0)
            + (canonical?.artifactUnits?.count ?? 0)
            + (canonical?.evidence.count ?? 0)
            + (canonical?.reminders.count ?? 0)
            + (canonical?.commitments.count ?? 0)
        let configurationRows = (canonical?.savedViews.count ?? 0)
            + (canonical?.attributeDefinitions.count ?? 0)
            + (canonical?.textImportReviews.count ?? 0)
            + (canonical?.personMergeEvents.count ?? 0)
        structuredRecords = relationshipRows + knowledgeRows + configurationRows
        profileSnapshots = archive.ownedProfileSnapshots?.count ?? 0
        media = canonical?.portraitMedia?.count ?? 0
        preservedExtensionFields = archive.preservedExtensions?.count ?? 0
        durableDeletionTargets = durableDeletionState.targets.count
        wipeEpochs = durableDeletionState.wipeEpochIDs.count
        recoverableDeletedRows = recoverableDeletions.rows.count
    }

    public var totalRecords: Int {
        people + interactions + structuredRecords + profileSnapshots + media
            + preservedExtensionFields + durableDeletionTargets + wipeEpochs
            + recoverableDeletedRows
    }

    public var isEmpty: Bool { totalRecords == 0 }
}

public enum CloudVaultMigrationError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(Int)
    case legacyCheckpointRequiresRebuild
    case checkpointIsNotLegacy
    case missingCheckpoint
    case verificationFailed
    case duplicateMediaPayload
    case duplicatePortraitMetadata(UUID)
    case missingMediaPayload(UUID)
    case orphanMediaPayload(UUID)
    case mediaAssetMismatch(UUID)
    case invalidMediaPayload(UUID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            String(localized: "This local-to-iCloud checkpoint uses unsupported version \(version).")
        case .legacyCheckpointRequiresRebuild:
            String(localized: "This protected checkpoint predates deletion-safe migration. It was retained unchanged; rebuild it from the local notebook before moving to iCloud.")
        case .checkpointIsNotLegacy, .missingCheckpoint:
            String(localized: "The protected local-to-iCloud checkpoint is unavailable.")
        case .verificationFailed:
            String(localized: "The copied notebook did not pass stable-ID verification, so the local notebook remains active.")
        case .duplicateMediaPayload:
            String(localized: "The protected checkpoint contains more than one portrait payload for the same stable identifier.")
        case .duplicatePortraitMetadata,
             .missingMediaPayload,
             .orphanMediaPayload,
             .mediaAssetMismatch,
             .invalidMediaPayload:
            String(localized: "The stored portrait failed its integrity check.")
        }
    }
}

public final class CloudVaultMigrationCheckpointStore: @unchecked Sendable {
    public let pendingURL: URL
    public let recoveryURL: URL
    private let fileManager: FileManager

    public init(
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let support = applicationSupportURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let root = support
            .appendingPathComponent("PrivateRelationshipNotebook", isDirectory: true)
            .appendingPathComponent("MigrationBackups", isDirectory: true)
        pendingURL = root.appendingPathComponent("MoveToICloud.pending.json")
        recoveryURL = root.appendingPathComponent("LocalNotebook.recovery.json")
    }

    public var hasPendingCheckpoint: Bool {
        fileManager.fileExists(atPath: pendingURL.path)
    }

    public func savePending(_ package: CloudVaultMigrationPackage) throws {
        let data = try Self.encoder.encode(package)
        try createDirectoryIfNeeded()
        try data.write(to: pendingURL, options: protectedWriteOptions)
        try fileManager.setAttributes(protectedFileAttributes, ofItemAtPath: pendingURL.path)
    }

    public func loadPending() throws -> CloudVaultMigrationPackage {
        guard fileManager.fileExists(atPath: pendingURL.path) else {
            throw CloudVaultMigrationError.missingCheckpoint
        }
        let data = try Data(contentsOf: pendingURL, options: [.mappedIfSafe])
        let probe = try Self.decoder.decode(CheckpointVersionProbe.self, from: data)
        if probe.version == 1 || probe.version == 2 {
            // Earlier checkpoints do not contain the complete durable and
            // recoverable deletion payload. Treating missing fields as empty
            // could resurrect or silently drop deleted records, so the file is
            // intentionally retained for recovery.
            throw CloudVaultMigrationError.legacyCheckpointRequiresRebuild
        }
        guard probe.version == CloudVaultMigrationPackage.currentVersion else {
            throw CloudVaultMigrationError.unsupportedVersion(probe.version)
        }
        // `durableDeletionState` and `recoverableDeletions` are nonoptional. A
        // malformed current checkpoint missing either field fails decoding
        // rather than being accepted as empty.
        return try Self.decoder.decode(CloudVaultMigrationPackage.self, from: data)
    }

    /// Moves a confirmed v1/v2 checkpoint out of the pending slot without
    /// overwriting any prior recovery package. The source and destination live
    /// in the same protected directory, so `moveItem` is an atomic rename on the
    /// app-support volume. The legacy bytes remain unchanged.
    @discardableResult
    public func retainLegacyPendingForRecovery() throws -> URL {
        guard fileManager.fileExists(atPath: pendingURL.path) else {
            throw CloudVaultMigrationError.missingCheckpoint
        }
        let data = try Data(contentsOf: pendingURL, options: [.mappedIfSafe])
        let probe = try Self.decoder.decode(CheckpointVersionProbe.self, from: data)
        guard probe.version == 1 || probe.version == 2 else {
            throw CloudVaultMigrationError.checkpointIsNotLegacy
        }

        try createDirectoryIfNeeded()
        // Set protection before renaming as well as afterward. If a later
        // attribute call fails, the renamed inode is never left unprotected.
        try fileManager.setAttributes(protectedFileAttributes, ofItemAtPath: pendingURL.path)
        let destination = uniqueLegacyRecoveryURL(version: probe.version)
        try fileManager.moveItem(at: pendingURL, to: destination)
        try fileManager.setAttributes(protectedFileAttributes, ofItemAtPath: destination.path)
        return destination
    }

    /// Keeps a recoverable local snapshot after a successful switch. A later
    /// retry replaces the prior recovery copy atomically.
    public func markCompleted() throws {
        guard fileManager.fileExists(atPath: pendingURL.path) else {
            throw CloudVaultMigrationError.missingCheckpoint
        }
        try createDirectoryIfNeeded()
        if fileManager.fileExists(atPath: recoveryURL.path) {
            try fileManager.removeItem(at: recoveryURL)
        }
        try fileManager.moveItem(at: pendingURL, to: recoveryURL)
        try fileManager.setAttributes(protectedFileAttributes, ofItemAtPath: recoveryURL.path)
    }

    /// Cancels the attempted move while retaining the protected source copy for
    /// recovery. No cloud or local database file is deleted.
    public func cancelAndRetainRecovery() throws {
        guard fileManager.fileExists(atPath: pendingURL.path) else { return }
        let data = try Data(contentsOf: pendingURL, options: [.mappedIfSafe])
        let probe = try Self.decoder.decode(CheckpointVersionProbe.self, from: data)
        if probe.version == 1 || probe.version == 2 {
            _ = try retainLegacyPendingForRecovery()
        } else {
            try markCompleted()
        }
    }

    private func createDirectoryIfNeeded() throws {
        try fileManager.createDirectory(
            at: pendingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: protectedDirectoryAttributes
        )
    }

    private func uniqueLegacyRecoveryURL(version: Int) -> URL {
        let directory = pendingURL.deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(
                "LocalNotebook.legacy-v\(version).\(UUID().uuidString).recovery.json"
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct CheckpointVersionProbe: Decodable {
        let version: Int
    }

    private var protectedDirectoryAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        [:]
        #endif
    }

    private var protectedFileAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        [:]
        #endif
    }

    private var protectedWriteOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }
}

public extension ArchiveImportPlan {
    /// Builds the conservative portion of an inspected archive: new rows,
    /// explicitly accepted person updates, and new future-extension keys.
    /// Existing same-ID or same-key conflicts are never overwritten.
    func reviewedArchive(from archive: NotebookArchive) -> NotebookArchive {
        let acceptedUpdates = personUpdates.compactMap { update in
            update.direction == .incomingIsNewer ? update.incoming : nil
        }
        let selected = Set(structuredRecordsToCreate)
        let canonical = archive.canonical?.selectingNewRecords(identifiedBy: selected)
        let profiles = archive.ownedProfileSnapshots?.filter { snapshot in
            selected.contains(.init(family: .profileSnapshot, id: snapshot.cardVersionID))
        }
        return NotebookArchive(
            schemaVersion: archive.schemaVersion,
            exportedAt: archive.exportedAt,
            people: peopleToCreate + acceptedUpdates,
            interactions: interactionsToCreate,
            canonical: canonical,
            ownedProfileSnapshots: profiles,
            preservedExtensions: preservedExtensionsToCreate.isEmpty
                ? nil
                : preservedExtensionsToCreate
        )
    }
}
