import Foundation

/// The lifecycle of one user-initiated model handoff through Apple Shortcuts.
///
/// A handoff is intentionally single-use: the prompt can be retrieved once and
/// a result can be submitted once. Cancellation and consumption remove the
/// record instead of leaving private prompt or output text behind.
public enum ShortcutModelHandoffStatus: String, Codable, Hashable, Sendable {
    case prepared
    case promptRetrieved = "prompt_retrieved"
    case completed
}

/// The complete on-disk representation of one handoff. Callers should normally
/// use the narrower prepared, prompt, and result values returned by the store.
public struct ShortcutModelHandoffRecord: Codable, Hashable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let requestCode: String
    public let contextIdentifier: String
    public let modelInput: String
    public let createdAt: Date
    public let expiresAt: Date
    public var status: ShortcutModelHandoffStatus
    public var promptRetrievedAt: Date?
    public var modelResponse: String?
    public var completedAt: Date?

    public init(
        version: Int = 1,
        requestID: UUID,
        requestCode: String,
        contextIdentifier: String,
        modelInput: String,
        createdAt: Date,
        expiresAt: Date,
        status: ShortcutModelHandoffStatus = .prepared,
        promptRetrievedAt: Date? = nil,
        modelResponse: String? = nil,
        completedAt: Date? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.requestCode = requestCode
        self.contextIdentifier = contextIdentifier
        self.modelInput = modelInput
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.status = status
        self.promptRetrievedAt = promptRetrievedAt
        self.modelResponse = modelResponse
        self.completedAt = completedAt
    }

    public var summary: ShortcutModelHandoffSummary {
        ShortcutModelHandoffSummary(
            requestID: requestID,
            contextIdentifier: contextIdentifier,
            createdAt: createdAt,
            expiresAt: expiresAt,
            status: status
        )
    }
}

/// Non-prompt metadata suitable for app state and route correlation.
public struct ShortcutModelHandoffSummary: Codable, Hashable, Sendable {
    public let requestID: UUID
    public let contextIdentifier: String
    public let createdAt: Date
    public let expiresAt: Date
    public let status: ShortcutModelHandoffStatus

    public init(
        requestID: UUID,
        contextIdentifier: String,
        createdAt: Date,
        expiresAt: Date,
        status: ShortcutModelHandoffStatus
    ) {
        self.requestID = requestID
        self.contextIdentifier = contextIdentifier
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.status = status
    }
}

/// The opaque code passed to Shortcuts plus safe request metadata retained by
/// the calling view. The code embeds a random request UUID and independent
/// nonce, but carries no prompt text itself.
public struct ShortcutModelPreparedRequest: Codable, Hashable, Sendable {
    public let requestCode: String
    public let summary: ShortcutModelHandoffSummary

    public init(requestCode: String, summary: ShortcutModelHandoffSummary) {
        self.requestCode = requestCode
        self.summary = summary
    }

    public var requestID: UUID { summary.requestID }
    public var contextIdentifier: String { summary.contextIdentifier }
    public var expiresAt: Date { summary.expiresAt }
}

/// The bounded prompt returned once to the app intent used by a Shortcut.
public struct ShortcutModelPrompt: Codable, Hashable, Sendable {
    public let requestID: UUID
    public let contextIdentifier: String
    public let modelInput: String
    public let expiresAt: Date

    public init(
        requestID: UUID,
        contextIdentifier: String,
        modelInput: String,
        expiresAt: Date
    ) {
        self.requestID = requestID
        self.contextIdentifier = contextIdentifier
        self.modelInput = modelInput
        self.expiresAt = expiresAt
    }
}

/// A bounded model response and its correlation metadata. It remains a
/// suggestion; consuming it removes the underlying prompt and response file.
public struct ShortcutModelResult: Codable, Hashable, Sendable {
    public let requestID: UUID
    public let contextIdentifier: String
    public let modelResponse: String
    public let completedAt: Date

    public init(
        requestID: UUID,
        contextIdentifier: String,
        modelResponse: String,
        completedAt: Date
    ) {
        self.requestID = requestID
        self.contextIdentifier = contextIdentifier
        self.modelResponse = modelResponse
        self.completedAt = completedAt
    }
}

public struct ShortcutModelCleanupSummary: Codable, Hashable, Sendable {
    public let expiredRecordCount: Int
    public let invalidRecordCount: Int
    public let remainingRecordCount: Int

    public init(
        expiredRecordCount: Int,
        invalidRecordCount: Int,
        remainingRecordCount: Int
    ) {
        self.expiredRecordCount = max(0, expiredRecordCount)
        self.invalidRecordCount = max(0, invalidRecordCount)
        self.remainingRecordCount = max(0, remainingRecordCount)
    }

    public var removedRecordCount: Int {
        expiredRecordCount + invalidRecordCount
    }
}

/// Payload-free errors prevent private prompts or model output from appearing
/// in logs, alerts, crash reports, or Shortcut error callbacks.
public enum ShortcutModelHandoffError:
    Error,
    Codable,
    Hashable,
    Sendable,
    LocalizedError {
    case invalidConfiguration
    case sourcePolicyNotShortcutEligible
    case emptyModelInput
    case modelInputTooLong
    case emptyContextIdentifier
    case contextIdentifierTooLong
    case invalidRequestCode
    case requestNotFound
    case requestCodeMismatch
    case requestExpired
    case promptAlreadyRetrieved
    case promptNotRetrieved
    case resultAlreadySubmitted
    case emptyModelResponse
    case modelResponseTooLong
    case storageUnavailable
    case corruptedRecord
    case persistenceFailure

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The Shortcuts handoff configuration is invalid."
        case .sourcePolicyNotShortcutEligible:
            "This context is not authorized for the configured AI Shortcut."
        case .emptyModelInput:
            "The model request is empty."
        case .modelInputTooLong:
            "The model request exceeds the handoff limit."
        case .emptyContextIdentifier:
            "The handoff context identifier is empty."
        case .contextIdentifierTooLong:
            "The handoff context identifier exceeds the limit."
        case .invalidRequestCode:
            "The Shortcuts request code is invalid."
        case .requestNotFound:
            "The Shortcuts request is no longer available."
        case .requestCodeMismatch:
            "The Shortcuts request code does not match."
        case .requestExpired:
            "The Shortcuts request has expired."
        case .promptAlreadyRetrieved:
            "The Shortcuts request was already retrieved."
        case .promptNotRetrieved:
            "The Shortcuts request must be retrieved before submitting a result."
        case .resultAlreadySubmitted:
            "A result was already submitted for this Shortcuts request."
        case .emptyModelResponse:
            "The Shortcuts model response is empty."
        case .modelResponseTooLong:
            "The Shortcuts model response exceeds the handoff limit."
        case .storageUnavailable:
            "Protected Shortcuts handoff storage is unavailable."
        case .corruptedRecord:
            "The Shortcuts handoff record is invalid."
        case .persistenceFailure:
            "The Shortcuts handoff could not be saved."
        }
    }
}

/// A short-lived, file-backed exchange between Keepsake and user-authored
/// Shortcuts actions. Each request is a separate protected, excluded-from-
/// backup JSON file so there is no shared plaintext queue or prompt in a URL.
public actor ShortcutModelHandoffStore {
    public static let defaultTimeToLive: TimeInterval = 10 * 60
    public static let defaultMaximumModelInputCharacters = 8_000
    public static let defaultMaximumResultCharacters = 600
    /// Independent encoded-size ceilings prevent a single extended grapheme
    /// from bypassing the user-facing character limits.
    public static let defaultMaximumModelInputUTF8Bytes = 32_000
    public static let defaultMaximumResultUTF8Bytes = 2_400

    private static let recordVersion = 1
    private static let requestCodePrefix = "ksm1"
    private static let recordExtension = "json"
    private static let liveDirectoryName = "ShortcutModelHandoffs-v1"
    private static let maximumContextIdentifierCharacters = 512
    private static let maximumContextIdentifierUTF8Bytes = 2_048

    private let directoryURL: URL
    private let clock: @Sendable () -> Date
    private let timeToLive: TimeInterval
    private let maximumModelInputCharacters: Int
    private let maximumResultCharacters: Int
    private let maximumModelInputUTF8Bytes: Int
    private let maximumResultUTF8Bytes: Int

    /// Creates a store in this app's Caches container. App Intents in the app
    /// target can independently construct this value and reach the same files.
    public static func live(
        clock: @escaping @Sendable () -> Date = Date.init,
        timeToLive: TimeInterval = defaultTimeToLive,
        maximumModelInputCharacters: Int = defaultMaximumModelInputCharacters,
        maximumResultCharacters: Int = defaultMaximumResultCharacters,
        maximumModelInputUTF8Bytes: Int = defaultMaximumModelInputUTF8Bytes,
        maximumResultUTF8Bytes: Int = defaultMaximumResultUTF8Bytes
    ) throws -> ShortcutModelHandoffStore {
        let fileManager = FileManager.default
        let cachesURL: URL
        do {
            cachesURL = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw ShortcutModelHandoffError.storageUnavailable
        }
        return try ShortcutModelHandoffStore(
            directoryURL: cachesURL.appendingPathComponent(
                liveDirectoryName,
                isDirectory: true
            ),
            clock: clock,
            timeToLive: timeToLive,
            maximumModelInputCharacters: maximumModelInputCharacters,
            maximumResultCharacters: maximumResultCharacters,
            maximumModelInputUTF8Bytes: maximumModelInputUTF8Bytes,
            maximumResultUTF8Bytes: maximumResultUTF8Bytes
        )
    }

    public init(
        directoryURL: URL,
        clock: @escaping @Sendable () -> Date = Date.init,
        timeToLive: TimeInterval = defaultTimeToLive,
        maximumModelInputCharacters: Int = defaultMaximumModelInputCharacters,
        maximumResultCharacters: Int = defaultMaximumResultCharacters,
        maximumModelInputUTF8Bytes: Int = defaultMaximumModelInputUTF8Bytes,
        maximumResultUTF8Bytes: Int = defaultMaximumResultUTF8Bytes
    ) throws {
        guard directoryURL.isFileURL,
              timeToLive.isFinite,
              timeToLive > 0,
              maximumModelInputCharacters > 0,
              maximumResultCharacters > 0,
              maximumModelInputUTF8Bytes > 0,
              maximumResultUTF8Bytes > 0 else {
            throw ShortcutModelHandoffError.invalidConfiguration
        }
        self.directoryURL = directoryURL.standardizedFileURL
        self.clock = clock
        self.timeToLive = timeToLive
        self.maximumModelInputCharacters = maximumModelInputCharacters
        self.maximumResultCharacters = maximumResultCharacters
        self.maximumModelInputUTF8Bytes = maximumModelInputUTF8Bytes
        self.maximumResultUTF8Bytes = maximumResultUTF8Bytes
        try Self.prepareDirectory(self.directoryURL)
    }

    public func prepare(
        modelInput: String,
        contextIdentifier: String,
        sourcePolicy: IntelligenceSourcePolicy
    ) throws -> ShortcutModelPreparedRequest {
        guard sourcePolicy == .configuredShortcutEligible else {
            throw ShortcutModelHandoffError.sourcePolicyNotShortcutEligible
        }

        let preparedInput = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preparedInput.isEmpty else {
            throw ShortcutModelHandoffError.emptyModelInput
        }
        guard preparedInput.count <= maximumModelInputCharacters,
              preparedInput.utf8.count <= maximumModelInputUTF8Bytes else {
            // Prompt truncation could remove a delimiter or safety instruction,
            // so oversized input is rejected rather than silently shortened.
            throw ShortcutModelHandoffError.modelInputTooLong
        }

        let preparedContext = contextIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !preparedContext.isEmpty else {
            throw ShortcutModelHandoffError.emptyContextIdentifier
        }
        guard preparedContext.count <= Self.maximumContextIdentifierCharacters,
              preparedContext.utf8.count <= Self.maximumContextIdentifierUTF8Bytes else {
            throw ShortcutModelHandoffError.contextIdentifierTooLong
        }

        let createdAt = Self.storageDate(clock())
        let requestID = UUID()
        let requestCode = Self.makeRequestCode(requestID: requestID)
        let record = ShortcutModelHandoffRecord(
            version: Self.recordVersion,
            requestID: requestID,
            requestCode: requestCode,
            contextIdentifier: preparedContext,
            modelInput: preparedInput,
            createdAt: createdAt,
            expiresAt: Self.storageDate(createdAt.addingTimeInterval(timeToLive))
        )
        try persist(record)
        return ShortcutModelPreparedRequest(
            requestCode: requestCode,
            summary: record.summary
        )
    }

    public func retrievePrompt(requestCode: String) throws -> ShortcutModelPrompt {
        let requestID = try Self.requestID(from: requestCode)
        var record = try requiredRecord(requestID: requestID)
        try validate(record, requestCode: requestCode)

        switch record.status {
        case .prepared:
            break
        case .promptRetrieved:
            throw ShortcutModelHandoffError.promptAlreadyRetrieved
        case .completed:
            throw ShortcutModelHandoffError.resultAlreadySubmitted
        }

        record.status = .promptRetrieved
        record.promptRetrievedAt = Self.storageDate(clock())
        try persist(record)
        return ShortcutModelPrompt(
            requestID: record.requestID,
            contextIdentifier: record.contextIdentifier,
            modelInput: record.modelInput,
            expiresAt: record.expiresAt
        )
    }

    public func submitResult(
        requestCode: String,
        modelResponse: String
    ) throws -> ShortcutModelResult {
        let requestID = try Self.requestID(from: requestCode)
        var record = try requiredRecord(requestID: requestID)
        try validate(record, requestCode: requestCode)

        switch record.status {
        case .prepared:
            throw ShortcutModelHandoffError.promptNotRetrieved
        case .promptRetrieved:
            break
        case .completed:
            throw ShortcutModelHandoffError.resultAlreadySubmitted
        }

        let trimmed = modelResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShortcutModelHandoffError.emptyModelResponse
        }
        let bounded = Self.prefix(
            of: trimmed,
            maximumCharacters: maximumResultCharacters,
            maximumUTF8Bytes: maximumResultUTF8Bytes
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bounded.isEmpty else {
            throw ShortcutModelHandoffError.modelResponseTooLong
        }

        let completedAt = Self.storageDate(clock())
        record.status = .completed
        record.modelResponse = bounded
        record.completedAt = completedAt
        try persist(record)
        return ShortcutModelResult(
            requestID: record.requestID,
            contextIdentifier: record.contextIdentifier,
            modelResponse: bounded,
            completedAt: completedAt
        )
    }

    private func completedResult(requestID: UUID) throws -> ShortcutModelResult? {
        guard let record = try optionalRecord(requestID: requestID) else { return nil }
        if record.expiresAt <= clock() {
            try removeRecord(requestID: requestID)
            return nil
        }
        try validateStoredRecord(record, expectedRequestID: requestID)
        guard record.status == .completed else { return nil }
        guard let response = record.modelResponse,
              !response.isEmpty,
              let completedAt = record.completedAt else {
            throw ShortcutModelHandoffError.corruptedRecord
        }
        return ShortcutModelResult(
            requestID: record.requestID,
            contextIdentifier: record.contextIdentifier,
            modelResponse: response,
            completedAt: completedAt
        )
    }

    /// Atomically validates and removes a completed record before releasing its
    /// output to the caller. The same-directory claim rename also serializes
    /// independent store instances or app processes. If claiming or deletion
    /// fails, this method throws and never releases a replayable result.
    public func takeCompletedResult(requestID: UUID) throws -> ShortcutModelResult? {
        guard try completedResult(requestID: requestID) != nil else { return nil }

        let sourceURL = recordURL(requestID: requestID)
        let claimedURL = claimedRecordURL(requestID: requestID)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: claimedURL)
        } catch {
            // Another store/process may have won the atomic same-directory
            // rename or cancellation may have removed the request first.
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                return nil
            }
            throw ShortcutModelHandoffError.persistenceFailure
        }

        do {
            let record = try decodeRecord(at: claimedURL)
            if record.expiresAt <= clock() {
                try removeItemIfPresent(at: claimedURL)
                return nil
            }
            try validateStoredRecord(record, expectedRequestID: requestID)
            guard record.status == .completed,
                  let response = record.modelResponse,
                  !response.isEmpty,
                  let completedAt = record.completedAt else {
                throw ShortcutModelHandoffError.corruptedRecord
            }
            let result = ShortcutModelResult(
                requestID: record.requestID,
                contextIdentifier: record.contextIdentifier,
                modelResponse: response,
                completedAt: completedAt
            )
            try removeItemIfPresent(at: claimedURL)
            return result
        } catch {
            // A failed delete never releases output. Best-effort cleanup leaves
            // a `.json` claim that startup cleanup recognizes as invalid if the
            // filesystem remains unavailable here.
            try? removeItemIfPresent(at: claimedURL)
            if let handoffError = error as? ShortcutModelHandoffError {
                throw handoffError
            }
            throw ShortcutModelHandoffError.persistenceFailure
        }
    }

    public func cancel(requestID: UUID) throws {
        try removeRecord(requestID: requestID)
    }

    /// Removes expired records and malformed JSON records. Unrelated files are
    /// ignored so cleanup cannot broaden into destructive cache deletion.
    @discardableResult
    public func cleanupStaleRecords() throws -> ShortcutModelCleanupSummary {
        let fileManager = FileManager.default
        let candidateURLs: [URL]
        do {
            candidateURLs = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ).filter { $0.pathExtension == Self.recordExtension }
        } catch {
            throw ShortcutModelHandoffError.storageUnavailable
        }

        var expired = 0
        var invalid = 0
        var remaining = 0
        let currentDate = clock()

        for URL in candidateURLs {
            do {
                let record = try decodeRecord(at: URL)
                let filenameID = UUID(
                    uuidString: URL.deletingPathExtension().lastPathComponent
                )
                guard let filenameID else {
                    try fileManager.removeItem(at: URL)
                    invalid += 1
                    continue
                }
                do {
                    try validateStoredRecord(record, expectedRequestID: filenameID)
                } catch {
                    try fileManager.removeItem(at: URL)
                    invalid += 1
                    continue
                }
                if record.expiresAt <= currentDate {
                    try fileManager.removeItem(at: URL)
                    expired += 1
                } else {
                    remaining += 1
                }
            } catch {
                do {
                    try fileManager.removeItem(at: URL)
                    invalid += 1
                } catch {
                    throw ShortcutModelHandoffError.persistenceFailure
                }
            }
        }

        return ShortcutModelCleanupSummary(
            expiredRecordCount: expired,
            invalidRecordCount: invalid,
            remainingRecordCount: remaining
        )
    }

    private func validate(
        _ record: ShortcutModelHandoffRecord,
        requestCode: String
    ) throws {
        try validateStoredRecord(record, expectedRequestID: record.requestID)
        guard Self.constantTimeEqual(record.requestCode, requestCode) else {
            throw ShortcutModelHandoffError.requestCodeMismatch
        }
        if record.expiresAt <= clock() {
            try removeRecord(requestID: record.requestID)
            throw ShortcutModelHandoffError.requestExpired
        }
    }

    private func validateStoredRecord(
        _ record: ShortcutModelHandoffRecord,
        expectedRequestID: UUID
    ) throws {
        guard record.version == Self.recordVersion,
              record.requestID == expectedRequestID,
              record.createdAt < record.expiresAt,
              record.modelInput.count <= maximumModelInputCharacters,
              record.modelInput.utf8.count <= maximumModelInputUTF8Bytes,
              !record.modelInput.isEmpty,
              !record.contextIdentifier.isEmpty,
              record.contextIdentifier.count <= Self.maximumContextIdentifierCharacters,
              record.contextIdentifier.utf8.count <= Self.maximumContextIdentifierUTF8Bytes,
              (try? Self.requestID(from: record.requestCode)) == expectedRequestID else {
            throw ShortcutModelHandoffError.corruptedRecord
        }

        switch record.status {
        case .prepared:
            guard record.promptRetrievedAt == nil,
                  record.modelResponse == nil,
                  record.completedAt == nil else {
                throw ShortcutModelHandoffError.corruptedRecord
            }
        case .promptRetrieved:
            guard record.promptRetrievedAt != nil,
                  record.modelResponse == nil,
                  record.completedAt == nil else {
                throw ShortcutModelHandoffError.corruptedRecord
            }
        case .completed:
            guard record.promptRetrievedAt != nil,
                  let response = record.modelResponse,
                  !response.isEmpty,
                  response.count <= maximumResultCharacters,
                  response.utf8.count <= maximumResultUTF8Bytes,
                  record.completedAt != nil else {
                throw ShortcutModelHandoffError.corruptedRecord
            }
        }
    }

    private func requiredRecord(requestID: UUID) throws -> ShortcutModelHandoffRecord {
        guard let record = try optionalRecord(requestID: requestID) else {
            throw ShortcutModelHandoffError.requestNotFound
        }
        return record
    }

    private func optionalRecord(requestID: UUID) throws -> ShortcutModelHandoffRecord? {
        let URL = recordURL(requestID: requestID)
        guard FileManager.default.fileExists(atPath: URL.path) else { return nil }
        do {
            return try decodeRecord(at: URL)
        } catch {
            // Another store or process can atomically claim/remove the record
            // after the existence check but before Data opens it. That is a
            // normal missing-record outcome, not evidence of corrupt JSON.
            if Self.isMissingFileError(error)
                || !FileManager.default.fileExists(atPath: URL.path) {
                return nil
            }
            throw error
        }
    }

    private func decodeRecord(at URL: URL) throws -> ShortcutModelHandoffRecord {
        do {
            let data = try Data(contentsOf: URL, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(ShortcutModelHandoffRecord.self, from: data)
        } catch {
            if Self.isMissingFileError(error) {
                throw error
            }
            throw ShortcutModelHandoffError.corruptedRecord
        }
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain,
           cocoaError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
            || cocoaError.code == CocoaError.Code.fileNoSuchFile.rawValue {
            return true
        }
        if cocoaError.domain == NSPOSIXErrorDomain, cocoaError.code == 2 {
            return true
        }
        if let underlyingError = cocoaError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingFileError(underlyingError)
        }
        return false
    }

    private func persist(_ record: ShortcutModelHandoffRecord) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            let URL = recordURL(requestID: record.requestID)
            try data.write(to: URL, options: Self.protectedWriteOptions)
            try Self.protectAndExcludeFromBackup(URL, isDirectory: false)
        } catch let error as ShortcutModelHandoffError {
            throw error
        } catch {
            throw ShortcutModelHandoffError.persistenceFailure
        }
    }

    private func removeRecord(requestID: UUID) throws {
        try removeItemIfPresent(at: recordURL(requestID: requestID))
    }

    private func removeItemIfPresent(at URL: URL) throws {
        guard FileManager.default.fileExists(atPath: URL.path) else { return }
        do {
            try FileManager.default.removeItem(at: URL)
        } catch {
            // Removal is intentionally idempotent. A concurrent consumer or
            // cancellation can win after the existence check.
            if Self.isMissingFileError(error)
                || !FileManager.default.fileExists(atPath: URL.path) {
                return
            }
            throw ShortcutModelHandoffError.persistenceFailure
        }
    }

    private func recordURL(requestID: UUID) -> URL {
        directoryURL
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension(Self.recordExtension)
    }

    private func claimedRecordURL(requestID: UUID) -> URL {
        directoryURL
            .appendingPathComponent(
                "\(requestID.uuidString.lowercased()).take.\(UUID().uuidString.lowercased())",
                isDirectory: false
            )
            .appendingPathExtension(Self.recordExtension)
    }

    private static func makeRequestCode(requestID: UUID) -> String {
        let nonce = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return "\(requestCodePrefix).\(requestID.uuidString.lowercased()).\(nonce)"
    }

    private static func requestID(from requestCode: String) throws -> UUID {
        let parts = requestCode.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == Substring(requestCodePrefix),
              let requestID = UUID(uuidString: String(parts[1])),
              parts[2].count == 32,
              parts[2].allSatisfy({ $0.isHexDigit }) else {
            throw ShortcutModelHandoffError.invalidRequestCode
        }
        return requestID
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    /// Returns the longest Character-aligned prefix satisfying both limits.
    /// Iterating by Character prevents invalid UTF-8 while the independent byte
    /// budget prevents pathological extended graphemes from defeating the cap.
    private static func prefix(
        of value: String,
        maximumCharacters: Int,
        maximumUTF8Bytes: Int
    ) -> String {
        var end = value.startIndex
        var characterCount = 0
        var byteCount = 0
        while end < value.endIndex, characterCount < maximumCharacters {
            let next = value.index(after: end)
            let nextByteCount = value[end..<next].utf8.count
            guard nextByteCount <= maximumUTF8Bytes - byteCount else { break }
            end = next
            characterCount += 1
            byteCount += nextByteCount
        }
        return String(value[..<end])
    }

    /// Matches the JSON millisecond date strategy so a value returned directly
    /// after a write is identical to the same value loaded from disk.
    private static func storageDate(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static func prepareDirectory(_ URL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: URL,
                withIntermediateDirectories: true,
                attributes: protectedDirectoryAttributes
            )
            try protectAndExcludeFromBackup(URL, isDirectory: true)
        } catch {
            throw ShortcutModelHandoffError.storageUnavailable
        }
    }

    private static func protectAndExcludeFromBackup(
        _ URL: URL,
        isDirectory: Bool
    ) throws {
        try FileManager.default.setAttributes(
            isDirectory ? protectedDirectoryAttributes : protectedFileAttributes,
            ofItemAtPath: URL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = URL
        try mutableURL.setResourceValues(values)
    }

    private static var protectedDirectoryAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        [
            .protectionKey: FileProtectionType.complete,
            .posixPermissions: 0o700
        ]
        #else
        [.posixPermissions: 0o700]
        #endif
    }

    private static var protectedFileAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        [
            .protectionKey: FileProtectionType.complete,
            .posixPermissions: 0o600
        ]
        #else
        [.posixPermissions: 0o600]
        #endif
    }

    private static var protectedWriteOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }
}
