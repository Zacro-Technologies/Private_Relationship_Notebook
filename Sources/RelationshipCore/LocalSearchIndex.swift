import Foundation

public enum LocalSearchIndexFormat {
    public static let currentVersion = 1
}

/// Portable representation used by simple local persistence adapters. A
/// production SQLite backend can implement `LocalSearchIndexBackend` directly
/// and does not need to materialize this snapshot.
public struct LocalSearchPersistedIndex: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generation: UInt64
    public let updatedAt: Date
    public let documents: [LocalSearchDocument]
    public let checksum: String

    public init(
        schemaVersion: Int = LocalSearchIndexFormat.currentVersion,
        generation: UInt64,
        updatedAt: Date,
        documents: [LocalSearchDocument],
        checksum: String? = nil
    ) throws {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.updatedAt = updatedAt
        self.documents = documents.sorted { $0.id.uuidString < $1.id.uuidString }
        self.checksum = try checksum ?? LocalSearchStableEncoding.checksum(
            schemaVersion: schemaVersion,
            generation: generation,
            updatedAt: updatedAt,
            documents: self.documents
        )
    }

    public var hasValidChecksum: Bool {
        guard let expected = try? LocalSearchStableEncoding.checksum(
            schemaVersion: schemaVersion,
            generation: generation,
            updatedAt: updatedAt,
            documents: documents
        ) else {
            return false
        }
        return checksum == expected
    }
}

/// Local-only persistence for the rebuildable index. Snapshot persistence is
/// intentionally separate from canonical notebook persistence.
public protocol LocalSearchIndexPersistence: Sendable {
    func load() async throws -> LocalSearchPersistedIndex?
    func save(_ snapshot: LocalSearchPersistedIndex) async throws
    func discard() async throws
}

/// Test and preview persistence that survives backend recreation in-process.
public actor InMemoryLocalSearchIndexPersistence: LocalSearchIndexPersistence {
    private var snapshot: LocalSearchPersistedIndex?

    public init(snapshot: LocalSearchPersistedIndex? = nil) {
        self.snapshot = snapshot
    }

    public func load() -> LocalSearchPersistedIndex? {
        snapshot
    }

    public func save(_ snapshot: LocalSearchPersistedIndex) {
        self.snapshot = snapshot
    }

    public func discard() {
        snapshot = nil
    }

    public func storedSnapshot() -> LocalSearchPersistedIndex? {
        snapshot
    }

    /// Allows integrity/recovery tests to model a corrupt or outdated store.
    public func replace(with snapshot: LocalSearchPersistedIndex?) {
        self.snapshot = snapshot
    }
}

/// Encrypted-container-local persistence for the rebuildable search index.
///
/// The index is derived state, so corrupt or partially written snapshots are
/// discarded and rebuilt from the canonical notebook instead of blocking the
/// user from opening People. Writes are atomic and the file is excluded from
/// backups because the canonical vault remains the source of truth.
public actor FileLocalSearchIndexPersistence: LocalSearchIndexPersistence {
    public let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    public func load() throws -> LocalSearchPersistedIndex? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let snapshot = try decoder.decode(LocalSearchPersistedIndex.self, from: data)
            guard snapshot.hasValidChecksum else {
                try discard()
                return nil
            }
            return snapshot
        } catch {
            // This is a privacy-preserving cache: never retain a second copy of
            // corrupt derived content, and never make search availability
            // depend on being able to decode it.
            try? discard()
            return nil
        }
    }

    public func save(_ snapshot: LocalSearchPersistedIndex) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)

        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func discard() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

/// Reference backend with full filter semantics. It is deliberately actor
/// isolated and transactional, making it useful for tests and modest vaults;
/// larger vaults can substitute a SQLite backend without changing LocalSearch.
public actor InMemoryLocalSearchIndex: LocalSearchIndexBackend {
    private let schemaVersion: Int
    private let persistence: (any LocalSearchIndexPersistence)?
    private let now: @Sendable () -> Date

    private var documents: [UUID: LocalSearchDocument] = [:]
    private var generation: UInt64 = 0
    private var updatedAt: Date = .distantPast
    private var stagedRebuilds: [UUID: [UUID: LocalSearchDocument]] = [:]

    // Persistence calls can suspend. This logical lock serializes mutations
    // across actor reentrancy while still allowing reads of the prior index.
    private var mutationIsLocked = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        schemaVersion: Int = LocalSearchIndexFormat.currentVersion,
        persistence: (any LocalSearchIndexPersistence)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.schemaVersion = schemaVersion
        self.persistence = persistence
        self.now = now
    }

    public func restore() async throws -> LocalSearchRestoreOutcome {
        await acquireMutationLock()
        defer { releaseMutationLock() }

        guard let persistence, let snapshot = try await persistence.load() else {
            return .empty
        }
        guard snapshot.schemaVersion == schemaVersion else {
            documents = [:]
            generation = 0
            updatedAt = .distantPast
            try await persistence.discard()
            return .rebuildRequired(.schemaVersion(
                expected: schemaVersion,
                actual: snapshot.schemaVersion
            ))
        }
        guard snapshot.hasValidChecksum else {
            documents = [:]
            generation = 0
            updatedAt = .distantPast
            try await persistence.discard()
            return .rebuildRequired(.checksum)
        }

        var restored: [UUID: LocalSearchDocument] = [:]
        for document in snapshot.documents {
            guard restored[document.id] == nil else {
                documents = [:]
                generation = 0
                updatedAt = .distantPast
                try await persistence.discard()
                return .rebuildRequired(.duplicatePerson(document.id))
            }
            restored[document.id] = document
        }
        documents = restored
        generation = snapshot.generation
        updatedAt = snapshot.updatedAt
        return .restored(makeMetadata())
    }

    public func metadata() -> LocalSearchIndexMetadata {
        makeMetadata()
    }

    public func search(
        _ query: LocalSearchQuery,
        page: LocalSearchPageRequest
    ) throws -> LocalSearchPage {
        guard (1...500).contains(page.limit) else {
            throw LocalSearchError.invalidPageLimit(page.limit)
        }
        return try LocalSearchEvaluator.search(
            documents: Array(documents.values),
            generation: generation,
            query: query,
            page: page
        )
    }

    public func apply(_ mutation: LocalSearchIndexMutation) async throws {
        guard !mutation.upserts.isEmpty || !mutation.removals.isEmpty else { return }
        await acquireMutationLock()
        defer { releaseMutationLock() }

        var replacement = documents
        for id in mutation.removals { replacement.removeValue(forKey: id) }
        for document in mutation.upserts { replacement[document.id] = document }
        let replacementGeneration = generation &+ 1
        let replacementDate = now()
        try await persist(
            documents: replacement,
            generation: replacementGeneration,
            updatedAt: replacementDate
        )
        documents = replacement
        generation = replacementGeneration
        updatedAt = replacementDate
    }

    public func beginRebuild() -> UUID {
        let id = UUID()
        stagedRebuilds[id] = [:]
        return id
    }

    public func append(
        _ newDocuments: [LocalSearchDocument],
        to rebuildID: UUID
    ) throws {
        guard var staged = stagedRebuilds[rebuildID] else {
            throw LocalSearchError.unknownRebuildSession
        }
        for document in newDocuments {
            guard staged[document.id] == nil else {
                throw LocalSearchError.duplicatePersonInRebuild(document.id)
            }
            staged[document.id] = document
        }
        stagedRebuilds[rebuildID] = staged
    }

    public func commitRebuild(_ rebuildID: UUID) async throws -> LocalSearchIndexMetadata {
        await acquireMutationLock()
        defer { releaseMutationLock() }

        guard let staged = stagedRebuilds.removeValue(forKey: rebuildID) else {
            throw LocalSearchError.unknownRebuildSession
        }
        let replacementGeneration = generation &+ 1
        let replacementDate = now()
        do {
            try await persist(
                documents: staged,
                generation: replacementGeneration,
                updatedAt: replacementDate
            )
        } catch {
            stagedRebuilds[rebuildID] = staged
            throw error
        }
        documents = staged
        generation = replacementGeneration
        updatedAt = replacementDate
        return makeMetadata()
    }

    public func abandonRebuild(_ rebuildID: UUID) {
        stagedRebuilds.removeValue(forKey: rebuildID)
    }

    private func makeMetadata() -> LocalSearchIndexMetadata {
        LocalSearchIndexMetadata(
            schemaVersion: schemaVersion,
            generation: generation,
            documentCount: documents.count,
            updatedAt: updatedAt
        )
    }

    private func persist(
        documents: [UUID: LocalSearchDocument],
        generation: UInt64,
        updatedAt: Date
    ) async throws {
        guard let persistence else { return }
        let snapshot = try LocalSearchPersistedIndex(
            schemaVersion: schemaVersion,
            generation: generation,
            updatedAt: updatedAt,
            documents: Array(documents.values)
        )
        try await persistence.save(snapshot)
    }

    private func acquireMutationLock() async {
        if !mutationIsLocked {
            mutationIsLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationLock() {
        if mutationWaiters.isEmpty {
            mutationIsLocked = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }
}

/// Validates canonical saved-filter ASTs and coordinates index operations.
public actor LocalSearch {
    public static let supportedFilterVersion = 1

    private let index: any LocalSearchIndexBackend
    private let schema: FilterSchema

    public init(
        index: any LocalSearchIndexBackend = InMemoryLocalSearchIndex(),
        schema: FilterSchema = .localSearchPerson
    ) {
        self.index = index
        self.schema = schema
    }

    public func restore() async throws -> LocalSearchRestoreOutcome {
        try await index.restore()
    }

    public func metadata() async -> LocalSearchIndexMetadata {
        await index.metadata()
    }

    public func search(
        _ query: LocalSearchQuery = LocalSearchQuery(),
        page: LocalSearchPageRequest = LocalSearchPageRequest()
    ) async throws -> LocalSearchPage {
        try validate(query, page: page)
        return try await index.search(query, page: page)
    }

    public func search(
        savedView: SavedView,
        text: String? = nil,
        includeArchived: Bool = false,
        referenceDate: Date = .now,
        localeIdentifier: String = Locale.current.identifier,
        page: LocalSearchPageRequest = LocalSearchPageRequest()
    ) async throws -> LocalSearchPage {
        try await search(
            LocalSearchQuery(
                savedView: savedView,
                text: text,
                includeArchived: includeArchived,
                referenceDate: referenceDate,
                localeIdentifier: localeIdentifier
            ),
            page: page
        )
    }

    public func upsert(_ people: [Person]) async throws {
        try await upsert(people.map { LocalSearchDocument(person: $0) })
    }

    public func upsert(_ documents: [LocalSearchDocument]) async throws {
        try await index.apply(.init(upserts: documents))
    }

    public func remove(personIDs: Set<UUID>) async throws {
        try await index.apply(.init(removals: personIDs))
    }

    /// Streams canonical projections into a staged index. The live index is
    /// replaced only after every page succeeds.
    @discardableResult
    public func rebuild(
        from source: any LocalSearchRebuildSource,
        batchSize: Int = 500,
        progress: (@Sendable (LocalSearchRebuildProgress) -> Void)? = nil
    ) async throws -> LocalSearchIndexMetadata {
        guard (1...5_000).contains(batchSize) else {
            throw LocalSearchError.invalidRebuildBatchSize(batchSize)
        }

        let rebuildID = try await index.beginRebuild()
        var cursor: LocalSearchRebuildCursor?
        var seenCursors = Set<LocalSearchRebuildCursor>()
        var indexedCount = 0
        var reportedTotal: Int?

        do {
            while true {
                try Task.checkCancellation()
                let sourcePage = try await source.fetchPage(after: cursor, limit: batchSize)
                guard sourcePage.documents.count <= batchSize else {
                    throw LocalSearchError.rebuildPageTooLarge(
                        actual: sourcePage.documents.count,
                        limit: batchSize
                    )
                }
                try await index.append(sourcePage.documents, to: rebuildID)
                indexedCount += sourcePage.documents.count
                if let total = sourcePage.totalCount { reportedTotal = total }
                progress?(LocalSearchRebuildProgress(
                    indexedCount: indexedCount,
                    totalCount: reportedTotal
                ))

                guard let next = sourcePage.nextCursor else { break }
                guard next != cursor, seenCursors.insert(next).inserted else {
                    throw LocalSearchError.rebuildCursorDidNotAdvance
                }
                cursor = next
            }

            let metadata = try await index.commitRebuild(rebuildID)
            progress?(LocalSearchRebuildProgress(
                indexedCount: indexedCount,
                totalCount: reportedTotal ?? indexedCount
            ))
            return metadata
        } catch {
            await index.abandonRebuild(rebuildID)
            throw error
        }
    }

    private func validate(_ query: LocalSearchQuery, page: LocalSearchPageRequest) throws {
        guard query.filterVersion == Self.supportedFilterVersion else {
            throw LocalSearchError.unsupportedFilterVersion(query.filterVersion)
        }
        guard (1...500).contains(page.limit) else {
            throw LocalSearchError.invalidPageLimit(page.limit)
        }

        var issues: [FilterValidationIssue] = []
        if let filter = query.filter {
            issues += schema.validate(filter)
            if let negativeDays = Self.firstNegativeRelativeDayCount(in: filter) {
                throw LocalSearchError.negativeRelativeDayCount(negativeDays)
            }
        }
        issues += query.sorts.flatMap(schema.validate(sort:))
        guard issues.isEmpty else {
            throw LocalSearchError.invalidQuery(issues)
        }
    }

    private static func firstNegativeRelativeDayCount(in node: FilterNode) -> Int? {
        switch node {
        case let .and(children), let .or(children):
            return children.lazy.compactMap(firstNegativeRelativeDayCount).first
        case let .not(child):
            return firstNegativeRelativeDayCount(in: child)
        case let .condition(condition):
            guard condition.operator == .beforeRelativeDays ||
                    condition.operator == .afterRelativeDays,
                  case let .integer(days)? = condition.value,
                  days < 0 else {
                return nil
            }
            return days
        }
    }
}

enum LocalSearchStableEncoding {
    private struct ChecksumPayload: Codable {
        let schemaVersion: Int
        let generation: UInt64
        let updatedAt: Date
        let documents: [LocalSearchDocument]
    }

    static func checksum(
        schemaVersion: Int,
        generation: UInt64,
        updatedAt: Date,
        documents: [LocalSearchDocument]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(ChecksumPayload(
                schemaVersion: schemaVersion,
                generation: generation,
                updatedAt: updatedAt,
                documents: documents.sorted { $0.id.uuidString < $1.id.uuidString }
            ))
        } catch {
            throw LocalSearchError.encodingFailure
        }

        // Stable FNV-1a checksum. This detects corruption/version drift; it is
        // not an authentication primitive and the index contains no authority.
        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return String(format: "%016llx", digest)
    }

    static func querySignature(_ query: LocalSearchQuery) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(query)
        } catch {
            throw LocalSearchError.encodingFailure
        }
        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return String(format: "%016llx", digest)
    }
}
