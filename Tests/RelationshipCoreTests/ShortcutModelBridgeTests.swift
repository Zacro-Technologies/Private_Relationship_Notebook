import Foundation
import Testing
@testable import RelationshipCore

private final class ShortcutModelTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

private func shortcutModelTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("keepsake-shortcut-model-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func changedValidRequestCode(_ code: String) -> String {
    let replacement = code.last == "a" ? "b" : "a"
    return String(code.dropLast()) + replacement
}

@Test func shortcutModelHandoffRequiresExplicitShortcutEligibility() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ShortcutModelHandoffStore(directoryURL: directory)

    await #expect(throws: ShortcutModelHandoffError.sourcePolicyNotShortcutEligible) {
        _ = try await store.prepare(
            modelInput: "eligible prompt",
            contextIdentifier: "context-1",
            sourcePolicy: .onDeviceOnly
        )
    }
    await #expect(throws: ShortcutModelHandoffError.sourcePolicyNotShortcutEligible) {
        _ = try await store.prepare(
            modelInput: "eligible prompt",
            contextIdentifier: "context-1",
            sourcePolicy: .modelsDenied
        )
    }
    await #expect(throws: ShortcutModelHandoffError.sourcePolicyNotShortcutEligible) {
        _ = try await store.prepare(
            modelInput: "native PCC permission is not Shortcut permission",
            contextIdentifier: "context-1",
            sourcePolicy: .cloudEligible
        )
    }
    let prepared = try await store.prepare(
        modelInput: "eligible prompt",
        contextIdentifier: "context-1",
        sourcePolicy: .configuredShortcutEligible
    )
    #expect(prepared.summary.status == .prepared)
    #expect(prepared.requestCode.contains(prepared.requestID.uuidString.lowercased()))
    #expect(!prepared.requestCode.contains("eligible prompt"))
}

@Test func shortcutModelHandoffRejectsEmptyAndOversizedInputWithoutTruncation() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ShortcutModelHandoffStore(
        directoryURL: directory,
        maximumModelInputCharacters: 12
    )

    await #expect(throws: ShortcutModelHandoffError.emptyModelInput) {
        _ = try await store.prepare(
            modelInput: " \n\t ",
            contextIdentifier: "context",
            sourcePolicy: .configuredShortcutEligible
        )
    }
    await #expect(throws: ShortcutModelHandoffError.modelInputTooLong) {
        _ = try await store.prepare(
            modelInput: "1234567890123",
            contextIdentifier: "context",
            sourcePolicy: .configuredShortcutEligible
        )
    }
}

@Test func shortcutModelHandoffValidatesExactOpaqueCode() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ShortcutModelHandoffStore(directoryURL: directory)
    let prepared = try await store.prepare(
        modelInput: "bounded prompt",
        contextIdentifier: "context-code",
        sourcePolicy: .configuredShortcutEligible
    )

    await #expect(throws: ShortcutModelHandoffError.invalidRequestCode) {
        _ = try await store.retrievePrompt(requestCode: "not-a-request-code")
    }
    await #expect(throws: ShortcutModelHandoffError.requestCodeMismatch) {
        _ = try await store.retrievePrompt(
            requestCode: changedValidRequestCode(prepared.requestCode)
        )
    }

    let prompt = try await store.retrievePrompt(requestCode: prepared.requestCode)
    #expect(prompt.requestID == prepared.requestID)
    #expect(prompt.modelInput == "bounded prompt")
}

@Test func shortcutModelHandoffExpiresAndDeletesAtConfiguredDeadline() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = ShortcutModelTestClock(Date(timeIntervalSince1970: 2_000_000_000))
    let store = try ShortcutModelHandoffStore(
        directoryURL: directory,
        clock: clock.now,
        timeToLive: 30
    )
    let prepared = try await store.prepare(
        modelInput: "short-lived prompt",
        contextIdentifier: "context-expiry",
        sourcePolicy: .configuredShortcutEligible
    )

    #expect(prepared.expiresAt == clock.now().addingTimeInterval(30))
    clock.advance(by: 30)
    await #expect(throws: ShortcutModelHandoffError.requestExpired) {
        _ = try await store.retrievePrompt(requestCode: prepared.requestCode)
    }
    await #expect(throws: ShortcutModelHandoffError.requestNotFound) {
        _ = try await store.retrievePrompt(requestCode: prepared.requestCode)
    }
}

@Test func shortcutModelHandoffRequiresRetrievalBeforeSubmission() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ShortcutModelHandoffStore(directoryURL: directory)
    let prepared = try await store.prepare(
        modelInput: "prompt",
        contextIdentifier: "context-order",
        sourcePolicy: .configuredShortcutEligible
    )

    await #expect(throws: ShortcutModelHandoffError.promptNotRetrieved) {
        _ = try await store.submitResult(
            requestCode: prepared.requestCode,
            modelResponse: "too early"
        )
    }
    _ = try await store.retrievePrompt(requestCode: prepared.requestCode)
    let result = try await store.submitResult(
        requestCode: prepared.requestCode,
        modelResponse: "ready"
    )
    #expect(result.modelResponse == "ready")
}

@Test func shortcutModelHandoffTrimsAndCapsSubmittedResult() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ShortcutModelHandoffStore(
        directoryURL: directory,
        maximumResultCharacters: 8
    )
    let prepared = try await store.prepare(
        modelInput: "prompt",
        contextIdentifier: "context-cap",
        sourcePolicy: .configuredShortcutEligible
    )
    _ = try await store.retrievePrompt(requestCode: prepared.requestCode)

    await #expect(throws: ShortcutModelHandoffError.emptyModelResponse) {
        _ = try await store.submitResult(
            requestCode: prepared.requestCode,
            modelResponse: " \n "
        )
    }
    let result = try await store.submitResult(
        requestCode: prepared.requestCode,
        modelResponse: "  abcdefghijk  "
    )

    #expect(result.modelResponse == "abcdefgh")
    #expect(try await store.takeCompletedResult(requestID: prepared.requestID) == result)
    #expect(try await store.takeCompletedResult(requestID: prepared.requestID) == nil)
}

@Test func shortcutModelHandoffEnforcesUTF8ByteLimitsForExtendedGraphemes() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ShortcutModelHandoffStore(
        directoryURL: directory,
        maximumModelInputCharacters: 8,
        maximumResultCharacters: 8,
        maximumModelInputUTF8Bytes: 32,
        maximumResultUTF8Bytes: 16
    )
    let oversizedSingleCharacter = "a" + String(
        repeating: "\u{0301}",
        count: 100
    )
    #expect(oversizedSingleCharacter.count == 1)
    #expect(oversizedSingleCharacter.utf8.count > 32)

    await #expect(throws: ShortcutModelHandoffError.modelInputTooLong) {
        _ = try await store.prepare(
            modelInput: oversizedSingleCharacter,
            contextIdentifier: "context",
            sourcePolicy: .configuredShortcutEligible
        )
    }
    await #expect(throws: ShortcutModelHandoffError.contextIdentifierTooLong) {
        let oversizedContext = "c" + String(
            repeating: "\u{0301}",
            count: 1_100
        )
        _ = try await store.prepare(
            modelInput: "prompt",
            contextIdentifier: oversizedContext,
            sourcePolicy: .configuredShortcutEligible
        )
    }

    let prepared = try await store.prepare(
        modelInput: "prompt",
        contextIdentifier: "context-result-bytes",
        sourcePolicy: .configuredShortcutEligible
    )
    _ = try await store.retrievePrompt(requestCode: prepared.requestCode)
    await #expect(throws: ShortcutModelHandoffError.modelResponseTooLong) {
        _ = try await store.submitResult(
            requestCode: prepared.requestCode,
            modelResponse: oversizedSingleCharacter
        )
    }

    let bounded = try await store.submitResult(
        requestCode: prepared.requestCode,
        modelResponse: "éééééééééé"
    )
    #expect(bounded.modelResponse == "éééééééé")
    #expect(bounded.modelResponse.utf8.count == 16)
}

@Test func shortcutModelHandoffPreventsPromptAndResultReplay() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ShortcutModelHandoffStore(directoryURL: directory)
    let prepared = try await store.prepare(
        modelInput: "prompt",
        contextIdentifier: "context-replay",
        sourcePolicy: .configuredShortcutEligible
    )

    _ = try await store.retrievePrompt(requestCode: prepared.requestCode)
    await #expect(throws: ShortcutModelHandoffError.promptAlreadyRetrieved) {
        _ = try await store.retrievePrompt(requestCode: prepared.requestCode)
    }
    _ = try await store.submitResult(
        requestCode: prepared.requestCode,
        modelResponse: "first result"
    )
    await #expect(throws: ShortcutModelHandoffError.resultAlreadySubmitted) {
        _ = try await store.submitResult(
            requestCode: prepared.requestCode,
            modelResponse: "replayed result"
        )
    }
    await #expect(throws: ShortcutModelHandoffError.resultAlreadySubmitted) {
        _ = try await store.retrievePrompt(requestCode: prepared.requestCode)
    }
}

@Test func shortcutModelHandoffTakeAndCancelDeleteRecords() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ShortcutModelHandoffStore(directoryURL: directory)
    let completed = try await store.prepare(
        modelInput: "prompt",
        contextIdentifier: "context-consume",
        sourcePolicy: .configuredShortcutEligible
    )
    _ = try await store.retrievePrompt(requestCode: completed.requestCode)
    let submitted = try await store.submitResult(
        requestCode: completed.requestCode,
        modelResponse: "consume me"
    )

    #expect(try await store.takeCompletedResult(requestID: completed.requestID) == submitted)
    #expect(try await store.takeCompletedResult(requestID: completed.requestID) == nil)

    let cancelled = try await store.prepare(
        modelInput: "never retrieved",
        contextIdentifier: "context-cancel",
        sourcePolicy: .configuredShortcutEligible
    )
    try await store.cancel(requestID: cancelled.requestID)
    await #expect(throws: ShortcutModelHandoffError.requestNotFound) {
        _ = try await store.retrievePrompt(requestCode: cancelled.requestCode)
    }
}

@Test func shortcutModelHandoffTakeNeverReturnsBeforeSuccessfulDeletion() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try? FileManager.default.removeItem(at: directory)
    }
    let store = try ShortcutModelHandoffStore(directoryURL: directory)
    let prepared = try await store.prepare(
        modelInput: "prompt",
        contextIdentifier: "context-delete-before-return",
        sourcePolicy: .configuredShortcutEligible
    )
    _ = try await store.retrievePrompt(requestCode: prepared.requestCode)
    let submitted = try await store.submitResult(
        requestCode: prepared.requestCode,
        modelResponse: "return only after delete"
    )

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500],
        ofItemAtPath: directory.path
    )
    await #expect(throws: ShortcutModelHandoffError.persistenceFailure) {
        _ = try await store.takeCompletedResult(requestID: prepared.requestID)
    }

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
    )
    #expect(try await store.takeCompletedResult(requestID: prepared.requestID) == submitted)
    #expect(try await store.takeCompletedResult(requestID: prepared.requestID) == nil)
}

@Test func shortcutModelHandoffTakeIsSingleUseAcrossStoreInstances() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstStore = try ShortcutModelHandoffStore(directoryURL: directory)
    let secondStore = try ShortcutModelHandoffStore(directoryURL: directory)
    for iteration in 0..<100 {
        let prepared = try await firstStore.prepare(
            modelInput: "prompt \(iteration)",
            contextIdentifier: "context-cross-store-take-\(iteration)",
            sourcePolicy: .configuredShortcutEligible
        )
        _ = try await firstStore.retrievePrompt(requestCode: prepared.requestCode)
        let submitted = try await firstStore.submitResult(
            requestCode: prepared.requestCode,
            modelResponse: "only one consumer \(iteration)"
        )

        async let first = firstStore.takeCompletedResult(requestID: prepared.requestID)
        async let second = secondStore.takeCompletedResult(requestID: prepared.requestID)
        let results = try await [first, second]

        #expect(results.compactMap { $0 } == [submitted])
        #expect(try await firstStore.takeCompletedResult(requestID: prepared.requestID) == nil)
        #expect(try await secondStore.takeCompletedResult(requestID: prepared.requestID) == nil)
    }
}

@Test func shortcutModelHandoffCancelIsIdempotentAcrossStoreInstances() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstStore = try ShortcutModelHandoffStore(directoryURL: directory)
    let secondStore = try ShortcutModelHandoffStore(directoryURL: directory)
    for iteration in 0..<100 {
        let prepared = try await firstStore.prepare(
            modelInput: "prompt \(iteration)",
            contextIdentifier: "context-cross-store-cancel-\(iteration)",
            sourcePolicy: .configuredShortcutEligible
        )

        async let firstCancel: Void = firstStore.cancel(requestID: prepared.requestID)
        async let secondCancel: Void = secondStore.cancel(requestID: prepared.requestID)
        _ = try await (firstCancel, secondCancel)

        try await firstStore.cancel(requestID: prepared.requestID)
        try await secondStore.cancel(requestID: prepared.requestID)
    }
}

@Test func shortcutModelHandoffPreservesContextIdentifierAcrossRoundTrip() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ShortcutModelHandoffStore(directoryURL: directory)
    let context = "person:7b14|suggestion:92af|packet:41c0"
    let prepared = try await store.prepare(
        modelInput: "  shared prompt  ",
        contextIdentifier: "  \(context)  ",
        sourcePolicy: .configuredShortcutEligible
    )
    #expect(prepared.contextIdentifier == context)

    let prompt = try await store.retrievePrompt(requestCode: prepared.requestCode)
    #expect(prompt.contextIdentifier == context)
    #expect(prompt.modelInput == "shared prompt")
    let submitted = try await store.submitResult(
        requestCode: prepared.requestCode,
        modelResponse: " personalized idea "
    )
    #expect(submitted.contextIdentifier == context)
    #expect(submitted.modelResponse == "personalized idea")
    #expect(try await store.takeCompletedResult(requestID: prepared.requestID)?.contextIdentifier == context)
}

@Test func shortcutModelHandoffCleanupRemovesOnlyExpiredAndInvalidRecords() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = ShortcutModelTestClock(Date(timeIntervalSince1970: 2_100_000_000))
    let store = try ShortcutModelHandoffStore(
        directoryURL: directory,
        clock: clock.now,
        timeToLive: 20
    )
    _ = try await store.prepare(
        modelInput: "will expire",
        contextIdentifier: "expired",
        sourcePolicy: .configuredShortcutEligible
    )
    clock.advance(by: 20)
    let live = try await store.prepare(
        modelInput: "remains live",
        contextIdentifier: "live",
        sourcePolicy: .configuredShortcutEligible
    )
    try Data("not-json".utf8).write(
        to: directory.appendingPathComponent("invalid.json"),
        options: .atomic
    )
    try Data("leave unrelated files alone".utf8).write(
        to: directory.appendingPathComponent("unrelated.txt"),
        options: .atomic
    )

    let cleanup = try await store.cleanupStaleRecords()

    #expect(cleanup.expiredRecordCount == 1)
    #expect(cleanup.invalidRecordCount == 1)
    #expect(cleanup.remainingRecordCount == 1)
    #expect(cleanup.removedRecordCount == 2)
    let prompt = try await store.retrievePrompt(requestCode: live.requestCode)
    #expect(prompt.contextIdentifier == "live")
    #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("unrelated.txt").path
    ))
}

@Test func shortcutModelHandoffErrorsNeverDescribePromptOrResponse() {
    let privatePrompt = "PRIVATE-PROMPT-SENTINEL"
    let privateResponse = "PRIVATE-RESPONSE-SENTINEL"

    for error in [
        ShortcutModelHandoffError.emptyModelInput,
        .modelInputTooLong,
        .emptyModelResponse,
        .modelResponseTooLong,
        .corruptedRecord,
        .persistenceFailure
    ] {
        let description = error.errorDescription ?? ""
        #expect(!description.contains(privatePrompt))
        #expect(!description.contains(privateResponse))
    }
}

@Test func shortcutModelHandoffUsesOneProtectedExcludedRecordPerRequest() async throws {
    let directory = shortcutModelTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ShortcutModelHandoffStore(directoryURL: directory)
    let prepared = try await store.prepare(
        modelInput: "protected prompt",
        contextIdentifier: "context-protection",
        sourcePolicy: .configuredShortcutEligible
    )
    let recordURL = directory
        .appendingPathComponent(prepared.requestID.uuidString.lowercased())
        .appendingPathExtension("json")
    let JSONFiles = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }

    #expect(JSONFiles.count == 1)
    #expect(JSONFiles.first?.lastPathComponent == recordURL.lastPathComponent)
    let storedRecordURL = try #require(JSONFiles.first)
    #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup == true)
    #expect(try storedRecordURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup == true)

    let attributes = try FileManager.default.attributesOfItem(atPath: storedRecordURL.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    #expect(permissions == 0o600)
}
