import CloudKit
import CoreData
import Foundation
import Testing
@testable import RelationshipCore

private actor StubCloudAccountProvider: CloudAccountStatusProviding {
    private var availability: CloudAccountAvailability
    private(set) var requestCount = 0

    init(_ availability: CloudAccountAvailability) {
        self.availability = availability
    }

    func accountAvailability(forContainerIdentifier identifier: String) async throws -> CloudAccountAvailability {
        requestCount += 1
        return availability
    }

    func setAvailability(_ availability: CloudAccountAvailability) {
        self.availability = availability
    }
}

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func increment() {
        lock.lock()
        storedCount += 1
        lock.unlock()
    }
}

private func makeSyncTestContainer() -> NSPersistentCloudKitContainer {
    NSPersistentCloudKitContainer(
        name: "SyncStatusTest",
        managedObjectModel: NSManagedObjectModel()
    )
}

private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "SyncStatusControllerTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
}

@MainActor
private func makeController(
    provider: any CloudAccountStatusProviding,
    center: NotificationCenter = NotificationCenter(),
    defaults: UserDefaults,
    now: @escaping @MainActor () -> Date = Date.init,
    initialAccountAvailability: CloudAccountAvailability? = nil,
    automaticallyRefresh: Bool = false,
    durableCloudEvents: [CloudEventSnapshot] = []
) -> SyncStatusController {
    SyncStatusController(
        container: makeSyncTestContainer(),
        cloudContainerIdentifier: "iCloud.com.example.SyncStatusTests",
        localOnlyReason: .entitlementUnavailable,
        accountStatusProvider: provider,
        notificationCenter: center,
        userDefaults: defaults,
        now: now,
        initialAccountAvailability: initialAccountAvailability,
        automaticallyRefreshAccountStatus: automaticallyRefresh,
        durableCloudEvents: durableCloudEvents
    )
}

@Test @MainActor func durableSetupCompletionPreventsAPerpetualStartupSpinner() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let end = Date(timeIntervalSince1970: 9_000)
    let controller = makeController(
        provider: StubCloudAccountProvider(.available),
        defaults: isolated.defaults,
        initialAccountAvailability: .available,
        durableCloudEvents: [
            CloudEventSnapshot(
                identifier: UUID(),
                direction: .setup,
                startDate: end.addingTimeInterval(-1),
                endDate: end,
                succeeded: true,
                issue: nil
            ),
        ]
    )

    #expect(controller.state == .upToDate(lastSuccess: end))
}

@Test @MainActor func durableHistoryKeepsPersistedLocalMutationPending() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let provider = StubCloudAccountProvider(.available)
    let mutationDate = Date(timeIntervalSince1970: 9_100)
    var controller: SyncStatusController? = makeController(
        provider: provider,
        defaults: isolated.defaults,
        initialAccountAvailability: .available
    )
    controller?.markLocalChange(
        at: mutationDate,
        storeConfigurations: [CloudSyncStoreConfiguration.vault]
    )
    controller = nil

    let exportEnd = mutationDate.addingTimeInterval(10)
    let restored = makeController(
        provider: provider,
        defaults: isolated.defaults,
        initialAccountAvailability: .available,
        durableCloudEvents: [
            CloudEventSnapshot(
                identifier: UUID(),
                direction: .exporting,
                startDate: mutationDate.addingTimeInterval(-10),
                endDate: exportEnd,
                succeeded: true,
                issue: nil,
                storeIdentifier: CloudSyncStoreConfiguration.vault
            ),
        ]
    )

    #expect(restored.localMutationSequence == 1)
    #expect(restored.lastSuccessfulExportSequence == 0)
    #expect(restored.lastSuccessfulExportAt == exportEnd)
    #expect(restored.hasPendingLocalChanges)
    #expect(restored.state == .waitingForNetwork(hasLocalChanges: true))
}

@Test @MainActor func durableCompletionClosesRacingStartWithoutGrantingExportCoverage() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let controller = makeController(
        provider: StubCloudAccountProvider(.available),
        defaults: isolated.defaults,
        initialAccountAvailability: .available
    )
    let mutationDate = Date(timeIntervalSince1970: 9_150)
    let eventIdentifier = UUID()
    controller.markLocalChange(
        at: mutationDate,
        storeConfigurations: [CloudSyncStoreConfiguration.vault]
    )
    controller.consume(CloudEventSnapshot(
        identifier: eventIdentifier,
        direction: .exporting,
        startDate: mutationDate.addingTimeInterval(1),
        endDate: nil,
        succeeded: false,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.vault
    ))
    #expect(controller.state == .syncing(.exporting))

    let completionDate = mutationDate.addingTimeInterval(2)
    controller.reconcileDurableCloudEvents([
        CloudEventSnapshot(
            identifier: eventIdentifier,
            direction: .exporting,
            startDate: mutationDate.addingTimeInterval(1),
            endDate: completionDate,
            succeeded: true,
            issue: nil,
            storeIdentifier: CloudSyncStoreConfiguration.vault
        ),
    ])

    #expect(controller.lastSuccessfulExportAt == completionDate)
    #expect(controller.lastSuccessfulExportSequence == 0)
    #expect(controller.hasPendingLocalChanges)
    #expect(controller.state == .waitingForNetwork(hasLocalChanges: true))
}

@Test @MainActor func durableErrorWatermarkRejectsOlderLateSuccess() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let failureEnd = Date(timeIntervalSince1970: 9_200)
    let controller = makeController(
        provider: StubCloudAccountProvider(.available),
        defaults: isolated.defaults,
        initialAccountAvailability: .available,
        durableCloudEvents: [
            CloudEventSnapshot(
                identifier: UUID(),
                direction: .importing,
                startDate: failureEnd.addingTimeInterval(-1),
                endDate: failureEnd,
                succeeded: false,
                issue: .network
            ),
        ]
    )
    #expect(controller.state == .needsAttention(.network))

    controller.consume(CloudEventSnapshot(
        identifier: UUID(),
        direction: .importing,
        startDate: failureEnd.addingTimeInterval(-20),
        endDate: failureEnd.addingTimeInterval(-10),
        succeeded: true,
        issue: nil
    ))
    #expect(controller.state == .needsAttention(.network))

    let recoveryEnd = failureEnd.addingTimeInterval(10)
    controller.consume(CloudEventSnapshot(
        identifier: UUID(),
        direction: .importing,
        startDate: failureEnd.addingTimeInterval(1),
        endDate: recoveryEnd,
        succeeded: true,
        issue: nil
    ))
    #expect(controller.state == .upToDate(lastSuccess: recoveryEnd))
}

@Test @MainActor func durableReplayUsesLatestOutcomeAndDoesNotRepeatImportSideEffects() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let center = NotificationCenter()
    let counter = NotificationCounter()
    let store = CloudSyncStoreConfiguration.vault
    let firstEnd = Date(timeIntervalSince1970: 9_300)
    let recoveredEnd = firstEnd.addingTimeInterval(10)
    let recoveredImportIdentifier = UUID()
    let token = center.addObserver(
        forName: .relationshipNotebookRemoteImportCompleted,
        object: nil,
        queue: nil
    ) { _ in counter.increment() }
    defer { center.removeObserver(token) }

    let controller = makeController(
        provider: StubCloudAccountProvider(.available),
        center: center,
        defaults: isolated.defaults,
        initialAccountAvailability: .available,
        durableCloudEvents: Array([
            CloudEventSnapshot(
                identifier: UUID(),
                direction: .importing,
                startDate: firstEnd.addingTimeInterval(-1),
                endDate: firstEnd,
                succeeded: false,
                issue: .service,
                storeIdentifier: store
            ),
            CloudEventSnapshot(
                identifier: recoveredImportIdentifier,
                direction: .importing,
                startDate: recoveredEnd.addingTimeInterval(-1),
                endDate: recoveredEnd,
                succeeded: true,
                issue: nil,
                storeIdentifier: store
            ),
        ].reversed())
    )

    #expect(controller.state == .upToDate(lastSuccess: recoveredEnd))
    #expect(counter.count == 0)

    controller.consume(CloudEventSnapshot(
        identifier: recoveredImportIdentifier,
        direction: .importing,
        startDate: recoveredEnd.addingTimeInterval(-1),
        endDate: nil,
        succeeded: true,
        issue: nil,
        storeIdentifier: store
    ))
    #expect(controller.state == .upToDate(lastSuccess: recoveredEnd))
    #expect(counter.count == 0)

    controller.consume(CloudEventSnapshot(
        identifier: recoveredImportIdentifier,
        direction: .importing,
        startDate: recoveredEnd.addingTimeInterval(-1),
        endDate: recoveredEnd,
        succeeded: true,
        issue: nil,
        storeIdentifier: store
    ))
    #expect(controller.state == .upToDate(lastSuccess: recoveredEnd))
    #expect(counter.count == 0)
}

@Test @MainActor func applicationReloadFailureCannotBeReportedAsUpToDate() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let controller = makeController(
        provider: StubCloudAccountProvider(.available),
        defaults: isolated.defaults,
        initialAccountAvailability: .available
    )

    controller.reportApplicationReloadFailure()
    #expect(controller.state == .needsAttention(.service))

    controller.reportApplicationReloadSucceeded()
    #expect(controller.state == .syncing(.setup))
}

@Test @MainActor func localMutationWatermarkSurvivesControllerRecreation() async {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let provider = StubCloudAccountProvider(.available)
    let mutationDate = Date(timeIntervalSince1970: 10_000)

    var firstController: SyncStatusController? = makeController(
        provider: provider,
        defaults: isolated.defaults,
        now: { mutationDate }
    )
    firstController?.markLocalChange()
    #expect(firstController?.state == .waitingForNetwork(hasLocalChanges: true))
    firstController = nil

    let restoredController = makeController(provider: provider, defaults: isolated.defaults)
    await restoredController.refreshAccountStatus()

    #expect(restoredController.lastLocalMutationAt == mutationDate)
    #expect(restoredController.lastSuccessfulExportAt == nil)
    #expect(restoredController.localMutationSequence == 1)
    #expect(restoredController.lastSuccessfulExportSequence == 0)
    #expect(restoredController.hasPendingLocalChanges)
    #expect(restoredController.state == .waitingForNetwork(hasLocalChanges: true))
}

@Test @MainActor func exportCannotClearAnEditMadeAfterExportStarted() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let provider = StubCloudAccountProvider(.available)
    let mutationDate = Date(timeIntervalSince1970: 20_000)
    let controller = makeController(
        provider: provider,
        defaults: isolated.defaults,
        now: { mutationDate }
    )
    let firstExportID = UUID()

    controller.consume(CloudEventSnapshot(
        identifier: firstExportID,
        direction: .exporting,
        startDate: mutationDate.addingTimeInterval(-10),
        endDate: nil,
        succeeded: false,
        issue: nil
    ))
    controller.markLocalChange(
        at: mutationDate,
        storeConfigurations: [CloudSyncStoreConfiguration.vault]
    )
    controller.consume(CloudEventSnapshot(
        identifier: firstExportID,
        direction: .exporting,
        startDate: mutationDate.addingTimeInterval(-10),
        endDate: mutationDate.addingTimeInterval(10),
        succeeded: true,
        issue: nil
    ))

    #expect(controller.lastSuccessfulExportAt == mutationDate.addingTimeInterval(10))
    #expect(controller.localMutationSequence == 1)
    #expect(controller.lastSuccessfulExportSequence == 0)
    #expect(controller.hasPendingLocalChanges)
    #expect(controller.state == .waitingForNetwork(hasLocalChanges: true))

    let coveringExportStart = mutationDate.addingTimeInterval(20)
    let coveringExportEnd = mutationDate.addingTimeInterval(30)
    let coveringExportID = UUID()
    controller.consume(CloudEventSnapshot(
        identifier: coveringExportID,
        direction: .exporting,
        startDate: coveringExportStart,
        endDate: nil,
        succeeded: false,
        issue: nil
    ))
    controller.consume(CloudEventSnapshot(
        identifier: coveringExportID,
        direction: .exporting,
        startDate: coveringExportStart,
        endDate: coveringExportEnd,
        succeeded: true,
        issue: nil
    ))

    #expect(controller.lastSuccessfulExportAt == coveringExportEnd)
    #expect(controller.lastSuccessfulExportSequence == 1)
    #expect(!controller.hasPendingLocalChanges)
    #expect(controller.state == .upToDate(lastSuccess: coveringExportEnd))
}

@Test @MainActor func completionWithoutAnObservedStartCannotAdvanceExportCoverage() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let provider = StubCloudAccountProvider(.available)
    let mutationDate = Date(timeIntervalSince1970: 25_000)
    let controller = makeController(
        provider: provider,
        defaults: isolated.defaults,
        now: { mutationDate }
    )
    controller.markLocalChange(
        at: mutationDate,
        storeConfigurations: [CloudSyncStoreConfiguration.vault]
    )

    let completionDate = mutationDate.addingTimeInterval(10)
    controller.consume(CloudEventSnapshot(
        identifier: UUID(),
        direction: .exporting,
        startDate: mutationDate.addingTimeInterval(-10),
        endDate: completionDate,
        succeeded: true,
        issue: nil
    ))

    #expect(controller.lastSuccessfulExportAt == completionDate)
    #expect(controller.lastSuccessfulExportSequence == 0)
    #expect(controller.hasPendingLocalChanges)
    #expect(controller.state == .waitingForNetwork(hasLocalChanges: true))
}

@Test @MainActor func mismatchedStoreCompletionCannotAdvanceCapturedCoverage() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let controller = makeController(
        provider: StubCloudAccountProvider(.available),
        defaults: isolated.defaults
    )
    let mutationDate = Date(timeIntervalSince1970: 25_500)
    controller.markLocalChange(
        at: mutationDate,
        storeConfigurations: [CloudSyncStoreConfiguration.vault]
    )
    let exportID = UUID()
    controller.consume(CloudEventSnapshot(
        identifier: exportID,
        direction: .exporting,
        startDate: mutationDate.addingTimeInterval(1),
        endDate: nil,
        succeeded: false,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.vault
    ))
    controller.consume(CloudEventSnapshot(
        identifier: exportID,
        direction: .exporting,
        startDate: mutationDate.addingTimeInterval(1),
        endDate: mutationDate.addingTimeInterval(2),
        succeeded: true,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.ownedProfiles
    ))

    #expect(controller.lastSuccessfulExportSequence == 0)
    #expect(controller.hasPendingLocalChanges)
}

@Test @MainActor func clockRollbackCannotHidePendingChangesAfterControllerRecreation() async {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let provider = StubCloudAccountProvider(.available)
    var clock = Date(timeIntervalSince1970: 100)
    var firstController: SyncStatusController? = makeController(
        provider: provider,
        defaults: isolated.defaults,
        now: { clock }
    )

    firstController?.markLocalChange(
        at: clock,
        storeConfigurations: [CloudSyncStoreConfiguration.vault]
    )
    let exportID = UUID()
    firstController?.consume(CloudEventSnapshot(
        identifier: exportID,
        direction: .exporting,
        startDate: Date(timeIntervalSince1970: 110),
        endDate: nil,
        succeeded: false,
        issue: nil
    ))
    firstController?.consume(CloudEventSnapshot(
        identifier: exportID,
        direction: .exporting,
        startDate: Date(timeIntervalSince1970: 110),
        endDate: Date(timeIntervalSince1970: 1_000),
        succeeded: true,
        issue: nil
    ))
    #expect(firstController?.hasPendingLocalChanges == false)

    clock = Date(timeIntervalSince1970: 50)
    firstController?.markLocalChange(
        at: clock,
        storeConfigurations: [CloudSyncStoreConfiguration.vault]
    )
    #expect(firstController?.lastLocalMutationAt ?? .distantFuture < Date(timeIntervalSince1970: 1_000))
    #expect(firstController?.localMutationSequence == 2)
    #expect(firstController?.lastSuccessfulExportSequence == 1)
    #expect(firstController?.hasPendingLocalChanges == true)
    firstController = nil

    let restoredController = makeController(provider: provider, defaults: isolated.defaults)
    await restoredController.refreshAccountStatus()

    #expect(restoredController.lastLocalMutationAt ?? .distantFuture < Date(timeIntervalSince1970: 1_000))
    #expect(restoredController.lastSuccessfulExportAt == Date(timeIntervalSince1970: 1_000))
    #expect(restoredController.localMutationSequence == 2)
    #expect(restoredController.lastSuccessfulExportSequence == 1)
    #expect(restoredController.hasPendingLocalChanges)
    #expect(restoredController.state == .waitingForNetwork(hasLocalChanges: true))
}

@Test @MainActor func ownedProfilesExportCannotClearAVaultMutation() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let controller = makeController(
        provider: StubCloudAccountProvider(.available),
        defaults: isolated.defaults
    )
    let mutationDate = Date(timeIntervalSince1970: 26_000)
    controller.markLocalChange(
        at: mutationDate,
        storeConfigurations: [CloudSyncStoreConfiguration.vault]
    )

    let profilesExportID = UUID()
    controller.consume(CloudEventSnapshot(
        identifier: profilesExportID,
        direction: .exporting,
        startDate: mutationDate.addingTimeInterval(1),
        endDate: nil,
        succeeded: false,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.ownedProfiles
    ))
    controller.consume(CloudEventSnapshot(
        identifier: profilesExportID,
        direction: .exporting,
        startDate: mutationDate.addingTimeInterval(1),
        endDate: mutationDate.addingTimeInterval(2),
        succeeded: true,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.ownedProfiles
    ))

    #expect(controller.hasPendingLocalChanges)
    #expect(controller.state == .waitingForNetwork(hasLocalChanges: true))

    let vaultExportID = UUID()
    controller.consume(CloudEventSnapshot(
        identifier: vaultExportID,
        direction: .exporting,
        startDate: mutationDate.addingTimeInterval(3),
        endDate: nil,
        succeeded: false,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.vault
    ))
    controller.consume(CloudEventSnapshot(
        identifier: vaultExportID,
        direction: .exporting,
        startDate: mutationDate.addingTimeInterval(3),
        endDate: mutationDate.addingTimeInterval(4),
        succeeded: true,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.vault
    ))

    #expect(!controller.hasPendingLocalChanges)
}

@Test @MainActor func unscopedMutationRequiresEveryMirroredStoreToExport() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let controller = makeController(
        provider: StubCloudAccountProvider(.available),
        defaults: isolated.defaults
    )
    controller.markLocalChange()
    let start = Date(timeIntervalSince1970: 27_000)

    for (offset, store) in [
        CloudSyncStoreConfiguration.vault,
        CloudSyncStoreConfiguration.ownedProfiles,
    ].enumerated() {
        let identifier = UUID()
        controller.consume(CloudEventSnapshot(
            identifier: identifier,
            direction: .exporting,
            startDate: start.addingTimeInterval(Double(offset * 2)),
            endDate: nil,
            succeeded: false,
            issue: nil,
            storeIdentifier: store
        ))
        controller.consume(CloudEventSnapshot(
            identifier: identifier,
            direction: .exporting,
            startDate: start.addingTimeInterval(Double(offset * 2)),
            endDate: start.addingTimeInterval(Double(offset * 2 + 1)),
            succeeded: true,
            issue: nil,
            storeIdentifier: store
        ))
        #expect(controller.hasPendingLocalChanges == (offset == 0))
    }
}

@Test @MainActor func perStoreExportCoverageSurvivesControllerRecreation() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let provider = StubCloudAccountProvider(.available)
    var controller: SyncStatusController? = makeController(
        provider: provider,
        defaults: isolated.defaults
    )
    controller?.markLocalChange()
    let start = Date(timeIntervalSince1970: 27_500)
    let vaultExportID = UUID()
    controller?.consume(CloudEventSnapshot(
        identifier: vaultExportID,
        direction: .exporting,
        startDate: start,
        endDate: nil,
        succeeded: false,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.vault
    ))
    controller?.consume(CloudEventSnapshot(
        identifier: vaultExportID,
        direction: .exporting,
        startDate: start,
        endDate: start.addingTimeInterval(1),
        succeeded: true,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.vault
    ))
    #expect(controller?.hasPendingLocalChanges == true)
    controller = nil

    let restored = makeController(provider: provider, defaults: isolated.defaults)
    #expect(restored.hasPendingLocalChanges)
    let profilesExportID = UUID()
    restored.consume(CloudEventSnapshot(
        identifier: profilesExportID,
        direction: .exporting,
        startDate: start.addingTimeInterval(2),
        endDate: nil,
        succeeded: false,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.ownedProfiles
    ))
    restored.consume(CloudEventSnapshot(
        identifier: profilesExportID,
        direction: .exporting,
        startDate: start.addingTimeInterval(2),
        endDate: start.addingTimeInterval(3),
        succeeded: true,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.ownedProfiles
    ))
    #expect(!restored.hasPendingLocalChanges)
}

@Test @MainActor func successfulOwnedProfilesEventCannotClearAVaultError() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let controller = makeController(
        provider: StubCloudAccountProvider(.available),
        defaults: isolated.defaults
    )
    let start = Date(timeIntervalSince1970: 28_000)
    let vaultFailureID = UUID()
    controller.consume(CloudEventSnapshot(
        identifier: vaultFailureID,
        direction: .exporting,
        startDate: start,
        endDate: nil,
        succeeded: false,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.vault
    ))
    controller.consume(CloudEventSnapshot(
        identifier: vaultFailureID,
        direction: .exporting,
        startDate: start,
        endDate: start.addingTimeInterval(1),
        succeeded: false,
        issue: .network,
        storeIdentifier: CloudSyncStoreConfiguration.vault
    ))
    #expect(controller.state == .needsAttention(.network))

    let profilesSuccessID = UUID()
    controller.consume(CloudEventSnapshot(
        identifier: profilesSuccessID,
        direction: .exporting,
        startDate: start.addingTimeInterval(2),
        endDate: nil,
        succeeded: false,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.ownedProfiles
    ))
    controller.consume(CloudEventSnapshot(
        identifier: profilesSuccessID,
        direction: .exporting,
        startDate: start.addingTimeInterval(2),
        endDate: start.addingTimeInterval(3),
        succeeded: true,
        issue: nil,
        storeIdentifier: CloudSyncStoreConfiguration.ownedProfiles
    ))

    #expect(controller.state == .needsAttention(.network))
}

@Test @MainActor func overlappingCloudEventsRemainSyncingUntilEveryEventFinishes() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let provider = StubCloudAccountProvider(.available)
    let controller = makeController(provider: provider, defaults: isolated.defaults)
    let importID = UUID()
    let exportID = UUID()
    let start = Date(timeIntervalSince1970: 30_000)

    controller.consume(CloudEventSnapshot(
        identifier: importID,
        direction: .importing,
        startDate: start,
        endDate: nil,
        succeeded: false,
        issue: nil
    ))
    controller.consume(CloudEventSnapshot(
        identifier: exportID,
        direction: .exporting,
        startDate: start.addingTimeInterval(1),
        endDate: nil,
        succeeded: false,
        issue: nil
    ))
    #expect(controller.state == .syncing(.importing))

    controller.consume(CloudEventSnapshot(
        identifier: importID,
        direction: .importing,
        startDate: start,
        endDate: start.addingTimeInterval(2),
        succeeded: true,
        issue: nil
    ))
    #expect(controller.state == .syncing(.exporting))

    controller.consume(CloudEventSnapshot(
        identifier: exportID,
        direction: .exporting,
        startDate: start.addingTimeInterval(1),
        endDate: start.addingTimeInterval(3),
        succeeded: true,
        issue: nil
    ))
    #expect(controller.state == .upToDate(lastSuccess: start.addingTimeInterval(3)))
}

@Test @MainActor func successfulImportPostsRemoteReloadNotification() {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let center = NotificationCenter()
    let provider = StubCloudAccountProvider(.available)
    let controller = makeController(provider: provider, center: center, defaults: isolated.defaults)
    let counter = NotificationCounter()
    let token = center.addObserver(
        forName: .relationshipNotebookRemoteImportCompleted,
        object: controller,
        queue: nil
    ) { _ in counter.increment() }
    defer { center.removeObserver(token) }

    let start = Date(timeIntervalSince1970: 40_000)
    controller.consume(CloudEventSnapshot(
        identifier: UUID(),
        direction: .importing,
        startDate: start,
        endDate: start.addingTimeInterval(1),
        succeeded: true,
        issue: nil
    ))

    #expect(counter.count == 1)
}

@Test @MainActor func accountChangeNotificationRechecksPrivateAccount() async {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let center = NotificationCenter()
    let provider = StubCloudAccountProvider(.available)
    let controller = makeController(provider: provider, center: center, defaults: isolated.defaults)

    await controller.refreshAccountStatus()
    await provider.setAvailability(.noAccount)
    center.post(name: .CKAccountChanged, object: nil)

    for _ in 0..<100 where controller.state != .localOnly(.noAccount) {
        await Task.yield()
    }

    #expect(controller.state == .localOnly(.noAccount))
    #expect(await provider.requestCount >= 2)
}

@Test @MainActor func localMutationNotificationUsesTheCommittedTransactionDate() async {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let center = NotificationCenter()
    let provider = StubCloudAccountProvider(.available)
    let controller = makeController(
        provider: provider,
        center: center,
        defaults: isolated.defaults,
        now: { Date(timeIntervalSince1970: 99_999) }
    )
    let committedAt = Date(timeIntervalSince1970: 55_000)

    center.post(
        name: .relationshipNotebookLocalMutationCommitted,
        object: nil,
        userInfo: [CloudSyncNotificationUserInfoKey.committedAt: committedAt]
    )
    for _ in 0..<100 where controller.lastLocalMutationAt != committedAt {
        await Task.yield()
    }

    #expect(controller.lastLocalMutationAt == committedAt)
    #expect(controller.state == .waitingForNetwork(hasLocalChanges: true))
}

@Test @MainActor func privateAccountStatesRemainDistinctAndActionable() async {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let provider = StubCloudAccountProvider(.noAccount)
    let controller = makeController(provider: provider, defaults: isolated.defaults)

    await controller.refreshAccountStatus()
    #expect(controller.state == .localOnly(.noAccount))

    await provider.setAvailability(.restricted)
    await controller.refreshAccountStatus()
    #expect(controller.state == .localOnly(.restricted))

    await provider.setAvailability(.temporarilyUnavailable)
    await controller.refreshAccountStatus()
    #expect(controller.state == .waitingForNetwork(hasLocalChanges: nil))

    await provider.setAvailability(.couldNotDetermine)
    await controller.refreshAccountStatus()
    #expect(controller.state == .needsAttention(.account))
}

@Test @MainActor func accountBoundOfflineSessionCanStartWaitingWithoutAStatusFetch() async {
    let isolated = makeIsolatedDefaults()
    defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
    let provider = StubCloudAccountProvider(.available)
    let controller = makeController(
        provider: provider,
        defaults: isolated.defaults,
        initialAccountAvailability: .temporarilyUnavailable,
        automaticallyRefresh: false
    )

    #expect(controller.state == .waitingForNetwork(hasLocalChanges: nil))
    #expect(await provider.requestCount == 0)
    #expect(
        VaultSyncState.localOnly(.temporarilyUnavailable).detail
            == "Saved on this device. iCloud is temporarily unavailable; synchronization can resume after account verification."
    )
}

@Test @MainActor func configuredLocalOnlyReasonIsPreservedWithoutAContainer() {
    let controller = SyncStatusController(
        container: makeSyncTestContainer(),
        cloudContainerIdentifier: nil,
        localOnlyReason: .userChoice,
        accountStatusProvider: StubCloudAccountProvider(.available)
    )

    #expect(controller.state == .localOnly(.userChoice))
}
