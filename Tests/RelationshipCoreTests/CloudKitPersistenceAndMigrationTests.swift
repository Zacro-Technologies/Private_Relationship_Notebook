import CloudKit
import CoreData
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RelationshipCore

private func makeCloudKitTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudKitPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct CloudProfileStoreFixture: Codable, Equatable, Sendable {
    let title: String
}

private func checkpointDataOmittingField(
    _ package: CloudVaultMigrationPackage,
    version: Int,
    field: String
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(package)
    guard var root = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw CocoaError(.coderInvalidValue)
    }
    root["version"] = version
    root.removeValue(forKey: field)
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

private func writePendingCheckpointData(
    _ data: Data,
    to store: CloudVaultMigrationCheckpointStore
) throws {
    try FileManager.default.createDirectory(
        at: store.pendingURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: store.pendingURL, options: .atomic)
}

private func makeCheckpointPortraitFixture() throws -> (
    person: Person,
    asset: PortraitMediaAsset,
    data: Data
) {
    let pixels: [UInt8] = [
        255, 0, 0, 255, 0, 255, 0, 255,
        0, 0, 255, 255, 255, 255, 255, 255,
    ]
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        output,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let data = output as Data
    let person = Person(displayName: "Portrait migration")
    let asset = PortraitMediaAsset(
        personID: person.id,
        sha256: SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined(),
        byteCount: Int64(data.count),
        pixelWidth: 2,
        pixelHeight: 2,
        isPrimary: true
    )
    return (person, asset, data)
}

private func rootURL(of descriptions: [NSPersistentStoreDescription]) -> URL? {
    descriptions.first?.url?.deletingLastPathComponent().standardizedFileURL
}

private func boolOption(_ key: String, in description: NSPersistentStoreDescription) -> Bool {
    (description.options[key] as? NSNumber)?.boolValue == true
}

@Test @MainActor func localAndAccountBoundCloudStoreFilesAreDisjointAndStable() throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let containerIdentifier = "iCloud.com.example.Keepsake"
    let firstBinding = SystemCloudAccountResolver.accountBinding(
        containerIdentifier: containerIdentifier,
        recordName: "account-one"
    )
    let secondBinding = SystemCloudAccountResolver.accountBinding(
        containerIdentifier: containerIdentifier,
        recordName: "account-two"
    )

    let local = PersistenceController.storeDescriptions(
        applicationSupportURL: applicationSupportURL,
        mode: .localOnly
    )
    let firstCloud = PersistenceController.storeDescriptions(
        applicationSupportURL: applicationSupportURL,
        mode: .cloud(containerIdentifier: containerIdentifier, accountBinding: firstBinding)
    )
    let repeatedFirstCloud = PersistenceController.storeDescriptions(
        applicationSupportURL: applicationSupportURL,
        mode: .cloud(containerIdentifier: containerIdentifier, accountBinding: firstBinding)
    )
    let secondCloud = PersistenceController.storeDescriptions(
        applicationSupportURL: applicationSupportURL,
        mode: .cloud(containerIdentifier: containerIdentifier, accountBinding: secondBinding)
    )
    let offlineFirstCloud = PersistenceController.storeDescriptions(
        applicationSupportURL: applicationSupportURL,
        mode: .cloudOffline(containerIdentifier: containerIdentifier, accountBinding: firstBinding)
    )

    #expect(rootURL(of: local) != rootURL(of: firstCloud))
    #expect(rootURL(of: firstCloud) != rootURL(of: secondCloud))
    #expect(rootURL(of: firstCloud) == rootURL(of: repeatedFirstCloud))
    #expect(rootURL(of: firstCloud) == rootURL(of: offlineFirstCloud))
    #expect(offlineFirstCloud.allSatisfy { $0.cloudKitContainerOptions == nil })
    #expect(Set(local.compactMap(\.url)).isDisjoint(with: Set(firstCloud.compactMap(\.url))))
    #expect(Set(firstCloud.compactMap(\.url)).isDisjoint(with: Set(secondCloud.compactMap(\.url))))

    #expect(PersistenceMode.localOnly.cloudContainerIdentifier == nil)
    #expect(!PersistenceMode.localOnly.isCloudEnabled)
    let cloudMode = PersistenceMode.cloud(
        containerIdentifier: containerIdentifier,
        accountBinding: firstBinding
    )
    #expect(cloudMode.cloudContainerIdentifier == containerIdentifier)
    #expect(cloudMode.isCloudEnabled)
    #expect(cloudMode.isMirroringEnabled)
    let offlineMode = PersistenceMode.cloudOffline(
        containerIdentifier: containerIdentifier,
        accountBinding: firstBinding
    )
    #expect(offlineMode.cloudContainerIdentifier == containerIdentifier)
    #expect(offlineMode.isCloudEnabled)
    #expect(!offlineMode.isMirroringEnabled)
    #expect(offlineMode.accountBinding == firstBinding)
}

@Test @MainActor func cloudStoreDescriptionsMirrorOnlyPrivateCanonicalStores() throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let containerIdentifier = "iCloud.com.example.Keepsake"
    let descriptions = PersistenceController.storeDescriptions(
        applicationSupportURL: applicationSupportURL,
        mode: .cloud(containerIdentifier: containerIdentifier, accountBinding: "account-binding")
    )
    let byConfiguration = Dictionary(
        uniqueKeysWithValues: descriptions.compactMap { description in
            description.configuration.map { ($0, description) }
        }
    )

    #expect(Set(byConfiguration.keys) == ["VaultPrivate", "LocalDerived"])
    let options = byConfiguration["VaultPrivate"]?.cloudKitContainerOptions
    #expect(options?.containerIdentifier == containerIdentifier)
    #expect(options?.databaseScope == .private)
    #expect(byConfiguration["LocalDerived"]?.cloudKitContainerOptions == nil)

    for description in descriptions {
        #expect(boolOption(NSPersistentHistoryTrackingKey, in: description))
        #expect(boolOption(NSPersistentStoreRemoteChangeNotificationPostOptionKey, in: description))
        #expect(description.shouldMigrateStoreAutomatically)
        #expect(description.shouldInferMappingModelAutomatically)
    }

    let localDescriptions = PersistenceController.storeDescriptions(
        applicationSupportURL: applicationSupportURL,
        mode: .localOnly
    )
    #expect(Set(localDescriptions.compactMap(\.configuration)) == [
        "VaultPrivate", "OwnedProfilesPrivate", "LocalDerived",
    ])
    #expect(localDescriptions.allSatisfy { $0.cloudKitContainerOptions == nil })
}

@Test @MainActor func cloudDescriptionsCanBeAssignedWithoutDuplicateContainerScope() throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let mode = PersistenceMode.cloud(
        containerIdentifier: "iCloud.com.zacrotech.RelationshipNotebook",
        accountBinding: "regression-test-account"
    )
    let descriptions = PersistenceController.storeDescriptions(
        applicationSupportURL: applicationSupportURL,
        mode: mode
    )
    let container = NSPersistentCloudKitContainer(
        name: "RelationshipVault",
        managedObjectModel: PersistenceController.makeModel(mode: mode)
    )

    // This assignment is the exact operation that raised NSInvalidArgumentException
    // in TestFlight build 3 when two private stores reused one CloudKit scope. Do not
    // load the stores in the unsigned SwiftPM host: CloudKit intentionally traps when
    // it cannot resolve the app's signed container entitlement.
    container.persistentStoreDescriptions = descriptions

    #expect(container.persistentStoreDescriptions.count == 2)
    #expect(Set(container.persistentStoreDescriptions.compactMap(\.configuration)) == [
        "VaultPrivate", "LocalDerived",
    ])
}

@Test @MainActor func offlineCloudReplicaLoadsProfilesFromCombinedVaultStore() async throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let persistence = PersistenceController(
        mode: .cloudOffline(
            containerIdentifier: "iCloud.com.zacrotech.RelationshipNotebook",
            accountBinding: "regression-test-account"
        ),
        applicationSupportURL: applicationSupportURL
    )
    await persistence.waitUntilReady()

    #expect(persistence.container.persistentStoreDescriptions.count == 2)
    #expect(Set(
        persistence.container.persistentStoreCoordinator.persistentStores
            .map(\.configurationName)
    ) == ["VaultPrivate", "LocalDerived"])

    let records = RecordRepository(persistence: persistence)
    let fixtureID = UUID()
    try records.upsert(
        CloudProfileStoreFixture(title: "Combined CloudKit store"),
        id: fixtureID,
        kind: "cloud-profile-regression",
        in: .ownedProfiles
    )
    let fetched = try records.fetch(
        CloudProfileStoreFixture.self,
        kind: "cloud-profile-regression",
        from: .ownedProfiles
    )
    #expect(fetched.map(\.id) == [fixtureID])
    #expect(fetched.map(\.value) == [CloudProfileStoreFixture(
        title: "Combined CloudKit store"
    )])
    persistence.closeStores()
}

@Test func cloudMigrationWaitsForInitialImportInEveryMirroredStore() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let setupVault = CloudMigrationEventSummary(
        storeIdentifier: "vault",
        kind: .setup,
        startDate: start,
        endDate: start.addingTimeInterval(1),
        succeeded: true
    )
    let importVault = CloudMigrationEventSummary(
        storeIdentifier: "vault",
        kind: .importing,
        startDate: start.addingTimeInterval(2),
        endDate: start.addingTimeInterval(3),
        succeeded: true
    )
    let setupProfiles = CloudMigrationEventSummary(
        storeIdentifier: "profiles",
        kind: .setup,
        startDate: start,
        endDate: start.addingTimeInterval(1),
        succeeded: true
    )

    let pending = CloudMigrationReadiness(
        mirroredStoreIdentifiers: ["vault", "profiles"],
        events: [setupVault, importVault, setupProfiles],
        sessionStartedAt: start
    )
    #expect(!pending.isReady)
    #expect(pending.readyStoreIdentifiers == ["vault"])
    #expect(pending.pendingStoreIdentifiers == ["profiles"])

    let importProfiles = CloudMigrationEventSummary(
        storeIdentifier: "profiles",
        kind: .importing,
        startDate: start.addingTimeInterval(2),
        endDate: start.addingTimeInterval(3),
        succeeded: true
    )
    let ready = CloudMigrationReadiness(
        mirroredStoreIdentifiers: ["vault", "profiles"],
        events: [setupVault, importVault, setupProfiles, importProfiles],
        sessionStartedAt: start
    )
    #expect(ready.isReady)
}

@Test func cloudMigrationRejectsFailedOrStillActiveLatestImport() {
    let start = Date(timeIntervalSince1970: 1_800_100_000)
    let setup = CloudMigrationEventSummary(
        storeIdentifier: "vault",
        kind: .setup,
        startDate: start,
        endDate: start.addingTimeInterval(1),
        succeeded: true
    )
    let priorSuccess = CloudMigrationEventSummary(
        storeIdentifier: "vault",
        kind: .importing,
        startDate: start.addingTimeInterval(2),
        endDate: start.addingTimeInterval(3),
        succeeded: true
    )
    let activeImport = CloudMigrationEventSummary(
        storeIdentifier: "vault",
        kind: .importing,
        startDate: start.addingTimeInterval(4),
        endDate: nil,
        succeeded: false
    )
    let active = CloudMigrationReadiness(
        mirroredStoreIdentifiers: ["vault"],
        events: [setup, priorSuccess, activeImport],
        sessionStartedAt: start
    )
    #expect(!active.isReady)

    let failedImport = CloudMigrationEventSummary(
        storeIdentifier: "vault",
        kind: .importing,
        startDate: start.addingTimeInterval(4),
        endDate: start.addingTimeInterval(5),
        succeeded: false
    )
    let failed = CloudMigrationReadiness(
        mirroredStoreIdentifiers: ["vault"],
        events: [setup, priorSuccess, failedImport],
        sessionStartedAt: start
    )
    #expect(!failed.isReady)
}

@Test func cloudMigrationRejectsSuccessfulEventsFromPriorPersistenceSession() {
    let priorSessionStart = Date(timeIntervalSince1970: 1_800_200_000)
    let currentSessionStart = priorSessionStart.addingTimeInterval(60)
    let historicalSetup = CloudMigrationEventSummary(
        storeIdentifier: "vault",
        kind: .setup,
        startDate: priorSessionStart,
        endDate: priorSessionStart.addingTimeInterval(1),
        succeeded: true
    )
    let historicalImport = CloudMigrationEventSummary(
        storeIdentifier: "vault",
        kind: .importing,
        startDate: priorSessionStart.addingTimeInterval(2),
        endDate: priorSessionStart.addingTimeInterval(3),
        succeeded: true
    )

    let historicalOnly = CloudMigrationReadiness(
        mirroredStoreIdentifiers: ["vault"],
        events: [historicalSetup, historicalImport],
        sessionStartedAt: currentSessionStart
    )
    #expect(!historicalOnly.isReady)
    #expect(historicalOnly.readyStoreIdentifiers.isEmpty)
    #expect(historicalOnly.pendingStoreIdentifiers == ["vault"])

    let currentSetup = CloudMigrationEventSummary(
        storeIdentifier: "vault",
        kind: .setup,
        startDate: currentSessionStart,
        endDate: currentSessionStart.addingTimeInterval(1),
        succeeded: true
    )
    let currentImport = CloudMigrationEventSummary(
        storeIdentifier: "vault",
        kind: .importing,
        startDate: currentSessionStart.addingTimeInterval(2),
        endDate: currentSessionStart.addingTimeInterval(3),
        succeeded: true
    )
    let currentImportCannotReuseHistoricalSetup = CloudMigrationReadiness(
        mirroredStoreIdentifiers: ["vault"],
        events: [historicalSetup, currentImport],
        sessionStartedAt: currentSessionStart
    )
    #expect(!currentImportCannotReuseHistoricalSetup.isReady)

    let currentSetupCannotReuseHistoricalImport = CloudMigrationReadiness(
        mirroredStoreIdentifiers: ["vault"],
        events: [historicalImport, currentSetup],
        sessionStartedAt: currentSessionStart
    )
    #expect(!currentSetupCannotReuseHistoricalImport.isReady)

    let currentEvents = CloudMigrationReadiness(
        mirroredStoreIdentifiers: ["vault"],
        events: [historicalSetup, historicalImport, currentSetup, currentImport],
        sessionStartedAt: currentSessionStart
    )
    #expect(currentEvents.isReady)
    #expect(currentEvents.readyStoreIdentifiers == ["vault"])
}

@Test @MainActor func accountBindingIsStableOpaqueAndContainerScoped() {
    let first = SystemCloudAccountResolver.accountBinding(
        containerIdentifier: "iCloud.com.example.first",
        recordName: "private-record-name"
    )
    let repeated = SystemCloudAccountResolver.accountBinding(
        containerIdentifier: "iCloud.com.example.first",
        recordName: "private-record-name"
    )
    let differentContainer = SystemCloudAccountResolver.accountBinding(
        containerIdentifier: "iCloud.com.example.second",
        recordName: "private-record-name"
    )
    let differentAccount = SystemCloudAccountResolver.accountBinding(
        containerIdentifier: "iCloud.com.example.first",
        recordName: "another-private-record-name"
    )

    #expect(first == repeated)
    #expect(first != differentContainer)
    #expect(first != differentAccount)
    #expect(first.count == 64)
    #expect(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(!first.contains("private-record-name"))
}

@Test @MainActor func managedObjectModelMeetsCloudKitSchemaAndEncryptionRules() {
    let model = PersistenceController.makeModel(mode: .cloud(
        containerIdentifier: "iCloud.com.example.Keepsake",
        accountBinding: "schema-test-account"
    ))
    let mirroredConfigurations = ["VaultPrivate"]
    let mirroredEntities = mirroredConfigurations.flatMap {
        model.entities(forConfigurationName: $0) ?? []
    }

    #expect(model.entities.allSatisfy { $0.uniquenessConstraints.isEmpty })
    #expect(mirroredEntities.allSatisfy { entity in
        entity.relationshipsByName.values.allSatisfy(\.isOptional)
    })

    let requiredAttributesWithoutDefaults = mirroredEntities.flatMap { entity in
        entity.attributesByName.values.compactMap { attribute in
            !attribute.isOptional && attribute.defaultValue == nil
                ? "\(entity.name ?? "unknown").\(attribute.name)"
                : nil
        }
    }
    #expect(requiredAttributesWithoutDefaults.isEmpty)

    let encryptedAttributes: [String: Set<String>] = [
        "PersonEntity": [
            "displayName", "pronunciation", "aliasesData", "contextsData", "role",
            "tagsData", "privateNote", "mentionableContext", "circle", "contactsData",
        ],
        "InteractionEntity": ["channel", "summary", "commitment", "detailsData"],
        "CanonicalRecordEntity": ["payload"],
        "ProfileRecordEntity": ["payload"],
        "MediaPayloadEntity": ["payload"],
    ]
    for (entityName, attributeNames) in encryptedAttributes {
        let attributes = model.entitiesByName[entityName]?.attributesByName ?? [:]
        for attributeName in attributeNames {
            #expect(attributes[attributeName]?.allowsCloudEncryption == true)
        }
    }

    let mediaPayload = model.entitiesByName["MediaPayloadEntity"]?
        .attributesByName["payload"]
    #expect(mediaPayload?.attributeType == .binaryDataAttributeType)
    #expect(mediaPayload?.allowsExternalBinaryDataStorage == true)
    #expect(model.entitiesByName["DerivedRecordEntity"]?
        .attributesByName["payload"]?.allowsCloudEncryption == false)

    let vaultEntityNames = Set(
        (model.entities(forConfigurationName: "VaultPrivate") ?? []).compactMap(\.name)
    )
    let derivedEntityNames = Set(
        (model.entities(forConfigurationName: "LocalDerived") ?? []).compactMap(\.name)
    )
    #expect(vaultEntityNames == [
        "PersonEntity", "InteractionEntity", "CanonicalRecordEntity", "ProfileRecordEntity",
        "MediaPayloadEntity",
    ])
    #expect((model.entities(forConfigurationName: "OwnedProfilesPrivate") ?? []).isEmpty)
    #expect(derivedEntityNames == ["DerivedRecordEntity"])

    let localModel = PersistenceController.makeModel()
    #expect(Set(
        (localModel.entities(forConfigurationName: "OwnedProfilesPrivate") ?? [])
            .compactMap(\.name)
    ) == ["ProfileRecordEntity"])
}

@Test @MainActor func legacyV1SQLiteVaultMigratesWithoutLosingExistingData() async throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let legacyRoot = applicationSupportURL
        .appendingPathComponent("PrivateRelationshipNotebook", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    let vaultURL = legacyRoot.appendingPathComponent("Vault.sqlite")
    let personID = UUID()

    let legacyCoordinator = NSPersistentStoreCoordinator(
        managedObjectModel: PersistenceController.makeLegacyV1Model()
    )
    let legacyStore = try legacyCoordinator.addPersistentStore(
        type: .sqlite,
        configuration: "VaultPrivate",
        at: vaultURL
    )
    let legacyContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    legacyContext.persistentStoreCoordinator = legacyCoordinator
    try legacyContext.performAndWait {
        let object = NSEntityDescription.insertNewObject(
            forEntityName: "PersonEntity",
            into: legacyContext
        )
        object.setValue(personID, forKey: "id")
        object.setValue("Preserve V1 person", forKey: "displayName")
        object.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "createdAt")
        object.setValue(Date(timeIntervalSince1970: 1_700_000_100), forKey: "modifiedAt")
        try legacyContext.save()
    }
    try legacyCoordinator.remove(legacyStore)

    let persistence = PersistenceController(
        mode: .localOnly,
        applicationSupportURL: applicationSupportURL
    )
    await persistence.waitUntilReady()

    #expect(persistence.loadIssues.isEmpty)
    let request = NSFetchRequest<NSManagedObject>(entityName: "PersonEntity")
    request.predicate = NSPredicate(format: "id == %@", personID as CVarArg)
    let migrated = try persistence.container.viewContext.fetch(request)
    #expect(migrated.count == 1)
    #expect(migrated.first?.value(forKey: "displayName") as? String == "Preserve V1 person")
    #expect(migrated.first?.value(forKey: "vaultEpochsData") == nil)
}

@Test func protectedMigrationCheckpointRoundTripsArchiveAndMedia() throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let personID = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
    let assetID = UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!
    let deletedInteractionID = UUID(uuidString: "A1000000-0000-4000-8000-000000000003")!
    let wipeEpochID = UUID(uuidString: "A1000000-0000-4000-8000-000000000004")!
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let person = Person(id: personID, displayName: "Checkpoint Person", createdAt: createdAt, modifiedAt: createdAt)
    let asset = PortraitMediaAsset(
        id: assetID,
        personID: personID,
        sha256: "checkpoint-hash",
        byteCount: 4,
        pixelWidth: 1,
        pixelHeight: 1,
        isPrimary: true,
        createdAt: createdAt,
        modifiedAt: createdAt
    )
    let package = CloudVaultMigrationPackage(
        createdAt: createdAt,
        archive: NotebookArchive(
            exportedAt: createdAt,
            people: [person],
            interactions: [],
            canonical: CanonicalArchivePayload(portraitMedia: [asset])
        ),
        media: [CloudMigrationMediaPayload(asset: asset, data: Data([0x01, 0x02, 0x03, 0x04]))],
        durableDeletionState: DurableDeletionState(
            targets: [.interaction(deletedInteractionID)],
            wipeEpochIDs: [wipeEpochID],
            generationMemberships: [
                DurableVaultGenerationMembership(
                    target: .person(personID),
                    wipeEpochID: wipeEpochID
                ),
            ]
        )
    )
    let store = CloudVaultMigrationCheckpointStore(applicationSupportURL: applicationSupportURL)

    try store.savePending(package)
    let restored = try store.loadPending()

    #expect(store.hasPendingCheckpoint)
    #expect(restored.version == CloudVaultMigrationPackage.currentVersion)
    #expect(restored.createdAt == createdAt)
    #expect(restored.archive.people.map(\.id) == [personID])
    #expect(restored.archive.canonical?.portraitMedia?.map(\.id) == [assetID])
    #expect(restored.media.map(\.id) == [assetID])
    #expect(restored.media.first?.data == Data([0x01, 0x02, 0x03, 0x04]))
    #expect(restored.durableDeletionState == package.durableDeletionState)
    #expect(restored.recoverableDeletions == package.recoverableDeletions)
    #expect(restored.requiresReviewedMigration)

    try store.markCompleted()
    #expect(!store.hasPendingCheckpoint)
    #expect(FileManager.default.fileExists(atPath: store.recoveryURL.path))
}

@Test func deletionOnlyCheckpointRequiresReviewAndAppearsInInventory() {
    let deletedPersonID = UUID(uuidString: "A2000000-0000-4000-8000-000000000001")!
    let wipeEpochID = UUID(uuidString: "A2000000-0000-4000-8000-000000000002")!
    let archive = NotebookArchive(people: [], interactions: [])
    let state = DurableDeletionState(
        targets: [.person(deletedPersonID)],
        wipeEpochIDs: [wipeEpochID]
    )
    let package = CloudVaultMigrationPackage(
        archive: archive,
        durableDeletionState: state
    )
    let inventory = CloudVaultInventory(
        archive: archive,
        durableDeletionState: state
    )

    #expect(package.requiresReviewedMigration)
    #expect(inventory.durableDeletionTargets == 1)
    #expect(inventory.wipeEpochs == 1)
    #expect(inventory.totalRecords == 2)
    #expect(!inventory.isEmpty)
    #expect(!CloudVaultMigrationPackage(archive: archive).requiresReviewedMigration)
}

@Test func migrationPortraitPreflightAcceptsOnlyExactVerifiedPackage() throws {
    let fixture = try makeCheckpointPortraitFixture()
    let package = CloudVaultMigrationPackage(
        archive: NotebookArchive(
            people: [fixture.person],
            interactions: [],
            canonical: CanonicalArchivePayload(portraitMedia: [fixture.asset])
        ),
        media: [.init(asset: fixture.asset, data: fixture.data)]
    )

    let preflight = try package.preflightMediaPayloads()

    #expect(preflight.verifiedPortraitMediaIDs == [fixture.asset.id])
    #expect(preflight.payloadsByID == [fixture.asset.id: fixture.data])
}

@Test func migrationPortraitPreflightEnforcesExactCardinalityAndMetadata() throws {
    let fixture = try makeCheckpointPortraitFixture()
    func package(
        archiveAssets: [PortraitMediaAsset],
        payloads: [CloudMigrationMediaPayload]
    ) -> CloudVaultMigrationPackage {
        CloudVaultMigrationPackage(
            archive: NotebookArchive(
                people: [fixture.person],
                interactions: [],
                canonical: CanonicalArchivePayload(portraitMedia: archiveAssets)
            ),
            media: payloads
        )
    }
    let payload = CloudMigrationMediaPayload(
        asset: fixture.asset,
        data: fixture.data
    )

    #expect(throws: CloudVaultMigrationError.duplicatePortraitMetadata(fixture.asset.id)) {
        _ = try package(
            archiveAssets: [fixture.asset, fixture.asset],
            payloads: [payload]
        ).preflightMediaPayloads()
    }
    #expect(throws: CloudVaultMigrationError.duplicateMediaPayload) {
        _ = try package(
            archiveAssets: [fixture.asset],
            payloads: [payload, payload]
        ).preflightMediaPayloads()
    }
    #expect(throws: CloudVaultMigrationError.missingMediaPayload(fixture.asset.id)) {
        _ = try package(
            archiveAssets: [fixture.asset],
            payloads: []
        ).preflightMediaPayloads()
    }
    let orphanPackage = package(archiveAssets: [], payloads: [payload])
    #expect(orphanPackage.requiresReviewedMigration)
    #expect(throws: CloudVaultMigrationError.orphanMediaPayload(fixture.asset.id)) {
        _ = try orphanPackage.preflightMediaPayloads()
    }

    var mismatchedMetadata = fixture.asset
    mismatchedMetadata.isPrimary.toggle()
    #expect(throws: CloudVaultMigrationError.mediaAssetMismatch(fixture.asset.id)) {
        _ = try package(
            archiveAssets: [mismatchedMetadata],
            payloads: [payload]
        ).preflightMediaPayloads()
    }
}

@Test func migrationPortraitPreflightValidatesHashBytesTypeDimensionsAndLimits() throws {
    let fixture = try makeCheckpointPortraitFixture()
    func package(for asset: PortraitMediaAsset) -> CloudVaultMigrationPackage {
        CloudVaultMigrationPackage(
            archive: NotebookArchive(
                people: [fixture.person],
                interactions: [],
                canonical: CanonicalArchivePayload(portraitMedia: [asset])
            ),
            media: [.init(asset: asset, data: fixture.data)]
        )
    }
    func expectsInvalid(_ asset: PortraitMediaAsset) throws {
        #expect(throws: CloudVaultMigrationError.invalidMediaPayload(asset.id)) {
            _ = try package(for: asset).preflightMediaPayloads()
        }
    }

    var invalidHash = fixture.asset
    invalidHash.sha256 = String(repeating: "0", count: 64)
    try expectsInvalid(invalidHash)

    var invalidByteCount = fixture.asset
    invalidByteCount.byteCount += 1
    try expectsInvalid(invalidByteCount)

    var invalidType = fixture.asset
    invalidType.contentType = UTType.png.identifier
    try expectsInvalid(invalidType)

    let falseJPEGData = Data("not a JPEG".utf8)
    var falseJPEGAsset = fixture.asset
    falseJPEGAsset.sha256 = SHA256.hash(data: falseJPEGData)
        .map { String(format: "%02x", $0) }
        .joined()
    falseJPEGAsset.byteCount = Int64(falseJPEGData.count)
    let falseJPEGPackage = CloudVaultMigrationPackage(
        archive: NotebookArchive(
            people: [fixture.person],
            interactions: [],
            canonical: CanonicalArchivePayload(portraitMedia: [falseJPEGAsset])
        ),
        media: [.init(asset: falseJPEGAsset, data: falseJPEGData)]
    )
    #expect(throws: CloudVaultMigrationError.invalidMediaPayload(fixture.asset.id)) {
        _ = try falseJPEGPackage.preflightMediaPayloads()
    }

    var invalidDimensions = fixture.asset
    invalidDimensions.pixelWidth += 1
    try expectsInvalid(invalidDimensions)

    let unstrippedMetadata = PortraitMediaAsset(
        id: fixture.asset.id,
        personID: fixture.asset.personID,
        contentType: fixture.asset.contentType,
        sha256: fixture.asset.sha256,
        byteCount: fixture.asset.byteCount,
        pixelWidth: fixture.asset.pixelWidth,
        pixelHeight: fixture.asset.pixelHeight,
        isPrimary: fixture.asset.isPrimary,
        metadataWasStripped: false,
        createdAt: fixture.asset.createdAt,
        modifiedAt: fixture.asset.modifiedAt,
        schemaRevision: fixture.asset.schemaRevision
    )
    try expectsInvalid(unstrippedMetadata)

    #expect(throws: CloudVaultMigrationError.invalidMediaPayload(fixture.asset.id)) {
        _ = try package(for: fixture.asset).preflightMediaPayloads(limits: .init(
            maximumInputBytes: fixture.data.count - 1,
            maximumSourcePixels: 80_000_000,
            maximumOutputDimension: 4_096,
            maximumOutputBytes: 20 * 1_024 * 1_024
        ))
    }
    #expect(throws: CloudVaultMigrationError.invalidMediaPayload(fixture.asset.id)) {
        _ = try package(for: fixture.asset).preflightMediaPayloads(limits: .init(
            maximumInputBytes: 30 * 1_024 * 1_024,
            maximumSourcePixels: 80_000_000,
            maximumOutputDimension: 4_096,
            maximumOutputBytes: fixture.data.count - 1
        ))
    }
    #expect(throws: CloudVaultMigrationError.invalidMediaPayload(fixture.asset.id)) {
        _ = try package(for: fixture.asset).preflightMediaPayloads(limits: .init(
            maximumInputBytes: 30 * 1_024 * 1_024,
            maximumSourcePixels: 3,
            maximumOutputDimension: 4_096,
            maximumOutputBytes: 20 * 1_024 * 1_024
        ))
    }
    #expect(throws: CloudVaultMigrationError.invalidMediaPayload(fixture.asset.id)) {
        _ = try package(for: fixture.asset).preflightMediaPayloads(limits: .init(
            maximumInputBytes: 30 * 1_024 * 1_024,
            maximumSourcePixels: 80_000_000,
            maximumOutputDimension: 1,
            maximumOutputBytes: 20 * 1_024 * 1_024
        ))
    }
}

@Test func migrationCheckpointRejectsDuplicatePortraitPayloadIDsWithoutTrapping() throws {
    let personID = UUID()
    let assetID = UUID()
    let asset = PortraitMediaAsset(
        id: assetID,
        personID: personID,
        sha256: "duplicate",
        byteCount: 1,
        pixelWidth: 1,
        pixelHeight: 1,
        isPrimary: true
    )
    let package = CloudVaultMigrationPackage(
        archive: NotebookArchive(
            people: [],
            interactions: [],
            canonical: CanonicalArchivePayload(portraitMedia: [asset])
        ),
        media: [
            .init(asset: asset, data: Data([0x01])),
            .init(asset: asset, data: Data([0x01])),
        ]
    )

    #expect(throws: CloudVaultMigrationError.duplicateMediaPayload) {
        _ = try package.preflightMediaPayloads()
    }
}

@Test func recoverableDeletionOnlyCheckpointRequiresReviewedMigration() {
    let id = UUID()
    let checkpoint = RecoverableDeletionCheckpoint(rows: [
        RecoverableDeletionRow(
            key: .init(entity: .person, id: id),
            attributes: [
                "id": .uuid(id),
                "deletedAt": .date(Date(timeIntervalSince1970: 1_700_000_000)),
            ]
        ),
    ])
    let archive = NotebookArchive(people: [], interactions: [])
    let package = CloudVaultMigrationPackage(
        archive: archive,
        recoverableDeletions: checkpoint
    )
    let inventory = CloudVaultInventory(
        archive: archive,
        recoverableDeletions: checkpoint
    )

    #expect(package.requiresReviewedMigration)
    #expect(inventory.recoverableDeletedRows == 1)
    #expect(inventory.totalRecords == 1)
}

@Test func legacyCheckpointIsRejectedAndRetainedUnchanged() throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let store = CloudVaultMigrationCheckpointStore(applicationSupportURL: applicationSupportURL)
    let package = CloudVaultMigrationPackage(
        createdAt: Date(timeIntervalSince1970: 1_700_000_100),
        archive: NotebookArchive(people: [], interactions: [])
    )
    let legacyData = try checkpointDataOmittingField(
        package,
        version: 1,
        field: "durableDeletionState"
    )
    try writePendingCheckpointData(legacyData, to: store)

    #expect(throws: CloudVaultMigrationError.legacyCheckpointRequiresRebuild) {
        _ = try store.loadPending()
    }
    #expect(store.hasPendingCheckpoint)
    #expect(try Data(contentsOf: store.pendingURL) == legacyData)
    #expect(!FileManager.default.fileExists(atPath: store.recoveryURL.path))
}

@Test func versionTwoCheckpointIsRejectedAndRetainedForRecovery() throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let store = CloudVaultMigrationCheckpointStore(applicationSupportURL: applicationSupportURL)
    let package = CloudVaultMigrationPackage(
        archive: NotebookArchive(people: [], interactions: [])
    )
    let incompleteData = try checkpointDataOmittingField(
        package,
        version: 2,
        field: "recoverableDeletions"
    )
    try writePendingCheckpointData(incompleteData, to: store)

    #expect(throws: CloudVaultMigrationError.legacyCheckpointRequiresRebuild) {
        _ = try store.loadPending()
    }
    #expect(store.hasPendingCheckpoint)
    #expect(try Data(contentsOf: store.pendingURL) == incompleteData)
}

@Test func legacyCheckpointRetentionNeverOverwritesPriorRecoveryBytes() throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let store = CloudVaultMigrationCheckpointStore(
        applicationSupportURL: applicationSupportURL
    )
    let package = CloudVaultMigrationPackage(
        archive: NotebookArchive(people: [], interactions: [])
    )
    let versionOneData = try checkpointDataOmittingField(
        package,
        version: 1,
        field: "durableDeletionState"
    )
    let versionTwoData = try checkpointDataOmittingField(
        package,
        version: 2,
        field: "recoverableDeletions"
    )
    let existingRecoveryData = Data("existing-current-recovery".utf8)

    try writePendingCheckpointData(versionOneData, to: store)
    try existingRecoveryData.write(to: store.recoveryURL, options: .atomic)
    let firstLegacyURL = try store.retainLegacyPendingForRecovery()

    #expect(!store.hasPendingCheckpoint)
    #expect(firstLegacyURL != store.recoveryURL)
    #expect(try Data(contentsOf: firstLegacyURL) == versionOneData)
    #expect(try Data(contentsOf: store.recoveryURL) == existingRecoveryData)

    try writePendingCheckpointData(versionTwoData, to: store)
    let secondLegacyURL = try store.retainLegacyPendingForRecovery()

    #expect(!store.hasPendingCheckpoint)
    #expect(secondLegacyURL != firstLegacyURL)
    #expect(secondLegacyURL != store.recoveryURL)
    #expect(try Data(contentsOf: firstLegacyURL) == versionOneData)
    #expect(try Data(contentsOf: secondLegacyURL) == versionTwoData)
    #expect(try Data(contentsOf: store.recoveryURL) == existingRecoveryData)
}

@Test func currentCheckpointCannotBeMisclassifiedAsLegacyRecovery() throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let store = CloudVaultMigrationCheckpointStore(
        applicationSupportURL: applicationSupportURL
    )
    let package = CloudVaultMigrationPackage(
        archive: NotebookArchive(people: [], interactions: [])
    )
    try store.savePending(package)
    let original = try Data(contentsOf: store.pendingURL)

    #expect(throws: CloudVaultMigrationError.checkpointIsNotLegacy) {
        _ = try store.retainLegacyPendingForRecovery()
    }
    #expect(store.hasPendingCheckpoint)
    #expect(try Data(contentsOf: store.pendingURL) == original)
}

@Test func currentCheckpointCannotOmitDurableDeletionState() throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let store = CloudVaultMigrationCheckpointStore(applicationSupportURL: applicationSupportURL)
    let package = CloudVaultMigrationPackage(
        archive: NotebookArchive(people: [], interactions: [])
    )
    let incompleteData = try checkpointDataOmittingField(
        package,
        version: CloudVaultMigrationPackage.currentVersion,
        field: "durableDeletionState"
    )
    try writePendingCheckpointData(incompleteData, to: store)

    #expect(throws: DecodingError.self) {
        _ = try store.loadPending()
    }
    #expect(try Data(contentsOf: store.pendingURL) == incompleteData)
}

@Test func currentCheckpointCannotOmitRecoverableDeletions() throws {
    let applicationSupportURL = try makeCloudKitTestDirectory()
    defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
    let store = CloudVaultMigrationCheckpointStore(applicationSupportURL: applicationSupportURL)
    let package = CloudVaultMigrationPackage(
        archive: NotebookArchive(people: [], interactions: [])
    )
    let incompleteData = try checkpointDataOmittingField(
        package,
        version: CloudVaultMigrationPackage.currentVersion,
        field: "recoverableDeletions"
    )
    try writePendingCheckpointData(incompleteData, to: store)

    #expect(throws: DecodingError.self) {
        _ = try store.loadPending()
    }
    #expect(try Data(contentsOf: store.pendingURL) == incompleteData)
}

@Test func reviewedCloudMigrationIncludesNewStructuredRowsButNeverConflicts() throws {
    let instant = Date(timeIntervalSince1970: 1_710_000_000)
    let conflictID = UUID(uuidString: "B1000000-0000-4000-8000-000000000001")!
    let newID = UUID(uuidString: "B1000000-0000-4000-8000-000000000002")!
    let existingConflict = Context(
        id: conflictID,
        kind: .community,
        names: LocalizedText("Existing protected value"),
        createdAt: instant,
        modifiedAt: instant
    )
    let incomingConflict = Context(
        id: conflictID,
        kind: .community,
        names: LocalizedText("Incoming replacement must not win"),
        createdAt: instant,
        modifiedAt: instant.addingTimeInterval(100)
    )
    let newContext = Context(
        id: newID,
        kind: .project,
        names: LocalizedText("Safe new row"),
        createdAt: instant,
        modifiedAt: instant
    )
    let incomingArchive = NotebookArchive(
        people: [],
        interactions: [],
        canonical: CanonicalArchivePayload(contexts: [incomingConflict, newContext])
    )
    let plan = try ArchiveImportPlanner().inspect(
        ArchiveCodec.encode(incomingArchive),
        existingPeople: [],
        existingInteractions: [],
        existingCanonical: CanonicalArchivePayload(contexts: [existingConflict])
    )

    let reviewed = plan.reviewedArchive(from: incomingArchive)
    let reviewedContexts = reviewed.canonical?.contexts ?? []

    #expect(plan.structuredRecordConflicts == [
        ArchiveStructuredRecordIdentity(family: .context, id: conflictID),
    ])
    #expect(plan.structuredRecordsToCreate == [
        ArchiveStructuredRecordIdentity(family: .context, id: newID),
    ])
    #expect(reviewedContexts.map(\.id) == [newID])
    #expect(!reviewedContexts.contains { $0.id == conflictID })
}

@Test func localToCloudMigrationKeepsEveryExistingPersonWithoutTrustingClockOrder() throws {
    let id = UUID()
    let destination = Person(
        id: id,
        displayName: "Destination edit",
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let clockSkewedIncoming = Person(
        id: id,
        displayName: "Incoming edit with a later clock",
        modifiedAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
    let archive = NotebookArchive(people: [clockSkewedIncoming], interactions: [])

    let plan = try ArchiveImportPlanner().inspect(
        ArchiveCodec.encode(archive),
        existingPeople: [destination],
        existingInteractions: [],
        acceptIncomingPersonUpdates: false
    )
    let reviewed = plan.reviewedArchive(from: archive)

    #expect(plan.peopleToCreate.isEmpty)
    #expect(plan.personUpdates.map(\.direction) == [.destinationKept])
    #expect(reviewed.people.isEmpty)
}

@Test func migrationInventoryTreatsPreservedFutureFieldsAsData() {
    let archive = NotebookArchive(
        people: [],
        interactions: [],
        preservedExtensions: ["future.example": .string("retained")]
    )
    let inventory = CloudVaultInventory(archive: archive)

    #expect(inventory.preservedExtensionFields == 1)
    #expect(!inventory.isEmpty)
}

@Test func reviewedMigrationCopiesOnlyAbsentPreservedExtensionKeys() throws {
    let incoming = NotebookArchive(
        people: [],
        interactions: [],
        preservedExtensions: [
            "future.conflict": .string("incoming"),
            "future.same": .boolean(true),
            "future.new": .number(42),
        ]
    )
    let plan = try ArchiveImportPlanner().inspect(
        ArchiveCodec.encode(incoming),
        existingPeople: [],
        existingInteractions: [],
        existingPreservedExtensions: [
            "future.conflict": .string("destination"),
            "future.same": .boolean(true),
        ]
    )
    let reviewed = plan.reviewedArchive(from: incoming)

    let expectedNewFields: [String: JSONValue] = ["future.new": .number(42)]
    #expect(plan.preservedExtensionsToCreate == expectedNewFields)
    #expect(plan.unchangedPreservedExtensionKeys == ["future.same"])
    #expect(plan.preservedExtensionConflicts == [
        ArchivePreservedExtensionConflict(
            key: "future.conflict",
            existing: .string("destination"),
            incoming: .string("incoming")
        ),
    ])
    #expect(reviewed.preservedExtensions == expectedNewFields)
}
