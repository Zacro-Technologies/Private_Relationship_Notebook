import CoreData
import Foundation
import OSLog

public enum PersistenceAccessError: LocalizedError, Sendable {
    case storeIsClosing

    public var errorDescription: String? {
        String(localized: "This notebook changed iCloud accounts while the edit was in progress. Reopen the record and try again in the active notebook.")
    }
}

public enum PersistenceMode: Equatable, Sendable {
    /// The original on-device notebook. These files are deliberately never
    /// attached to CloudKit, even if the user later enables synchronization.
    case localOnly
    /// A CloudKit replica scoped to a one-way account binding. Different Apple
    /// Accounts therefore cannot open or upload one another's local replicas.
    case cloud(containerIdentifier: String, accountBinding: String)
    /// The same account-bound replica opened without a mirroring delegate while
    /// CloudKit cannot verify the active account. This keeps offline edits in the
    /// correct notebook without risking an upload through a different account.
    case cloudOffline(containerIdentifier: String, accountBinding: String)

    public var cloudContainerIdentifier: String? {
        switch self {
        case .localOnly:
            nil
        case .cloud(let identifier, _), .cloudOffline(let identifier, _):
            identifier
        }
    }

    public var isCloudEnabled: Bool { cloudContainerIdentifier != nil }

    var mirroredCloudContainerIdentifier: String? {
        guard case .cloud(let identifier, _) = self else { return nil }
        return identifier
    }

    var accountBinding: String? {
        switch self {
        case .localOnly:
            nil
        case .cloud(_, let binding), .cloudOffline(_, let binding):
            binding
        }
    }

    var isMirroringEnabled: Bool { mirroredCloudContainerIdentifier != nil }
}

@MainActor
public final class PersistenceController {
    public let container: NSPersistentCloudKitContainer
    public let mode: PersistenceMode
    public let storeRootURL: URL?
    /// Lower bound for CloudKit setup/import events that can authorize a
    /// local-to-cloud migration in this loaded persistence session.
    public let cloudMigrationSessionStartedAt: Date
    public private(set) var loadIssues: [String] = []
    public private(set) var isReady = false
    public private(set) var acceptsWrites = true

    private static let logger = Logger(subsystem: "com.zacrotech.RelationshipNotebook", category: "persistence")
    private var expectedStoreCount = 0
    private var completedStoreCount = 0
    private var readinessWaiters: [CheckedContinuation<Void, Never>] = []

    /// Convenience initializer for local-only stores and in-memory tests.
    /// Cloud stores must use `init(mode:)` so an account binding is always
    /// present before any database file can be attached to CloudKit.
    public init(inMemory: Bool = false) {
        self.mode = .localOnly
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        container = NSPersistentCloudKitContainer(
            name: "RelationshipVault",
            managedObjectModel: Self.makeModel(mode: .localOnly)
        )

        if inMemory {
            self.storeRootURL = nil
            let description = Self.description(
                url: URL(fileURLWithPath: "/dev/null/RelationshipVault"),
                configuration: nil,
                type: NSInMemoryStoreType,
                cloudContainerIdentifier: nil
            )
            container.persistentStoreDescriptions = [description]
        } else {
            let descriptions = Self.storeDescriptions(
                applicationSupportURL: applicationSupport,
                mode: .localOnly
            )
            self.storeRootURL = descriptions.first?.url?.deletingLastPathComponent()
            container.persistentStoreDescriptions = descriptions
        }

        cloudMigrationSessionStartedAt = .now
        finishConfigurationAndLoad()
    }

    public init(
        mode: PersistenceMode,
        applicationSupportURL: URL? = nil
    ) {
        self.mode = mode
        let applicationSupport = applicationSupportURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let descriptions = Self.storeDescriptions(
            applicationSupportURL: applicationSupport,
            mode: mode
        )
        self.storeRootURL = descriptions.first?.url?.deletingLastPathComponent()
        container = NSPersistentCloudKitContainer(
            name: "RelationshipVault",
            managedObjectModel: Self.makeModel(mode: mode)
        )
        container.persistentStoreDescriptions = descriptions
        cloudMigrationSessionStartedAt = .now
        finishConfigurationAndLoad()
    }

    /// Waits for all configured SQLite stores to finish opening. CloudKit setup
    /// can take materially longer than a local store, so repositories should be
    /// created only after this barrier completes.
    public func waitUntilReady() async {
        guard !isReady else { return }
        await withCheckedContinuation { continuation in
            readinessWaiters.append(continuation)
        }
    }

    /// Detaches every store before an Apple Account transition. The files are
    /// retained as an offline recovery replica and are never connected to a
    /// different account binding.
    public func closeStores() {
        prepareForClosing()
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores {
            do {
                try container.persistentStoreCoordinator.remove(store)
            } catch {
                Self.logger.error("store_close_failed")
            }
        }
    }

    /// Closes the write gate synchronously before asynchronous history drains
    /// are quiesced, so UI tasks that resume during an account transition fail
    /// safely instead of writing through the old session.
    public func prepareForClosing() {
        acceptsWrites = false
    }

    public func requireWritable() throws {
        guard acceptsWrites else { throw PersistenceAccessError.storeIsClosing }
    }

    /// Reads Core Data's durable CloudKit event log. A local-to-cloud copy is
    /// permitted only after every mirrored store has completed both setup and
    /// an initial import, preventing a not-yet-hydrated destination from being
    /// mistaken for an empty notebook.
    public func cloudMigrationReadiness() throws -> CloudMigrationReadiness {
        let mirroredURLs: Set<URL> = Set(container.persistentStoreDescriptions.compactMap { description in
            description.cloudKitContainerOptions == nil
                ? nil
                : description.url?.standardizedFileURL
        })
        let mirroredStoreIdentifiers: Set<String> = Set(
            container.persistentStoreCoordinator.persistentStores.compactMap { store -> String? in
                guard let url = store.url?.standardizedFileURL,
                      mirroredURLs.contains(url) else { return nil }
                return store.identifier
            }
        )
        guard !mirroredStoreIdentifiers.isEmpty else {
            return CloudMigrationReadiness(
                mirroredStoreIdentifiers: [],
                events: [],
                sessionStartedAt: cloudMigrationSessionStartedAt
            )
        }

        let request = NSPersistentCloudKitContainerEventRequest.fetchEvents(after: Date.distantPast)
        request.resultType = .events
        guard let result = try container.viewContext.execute(request)
                as? NSPersistentCloudKitContainerEventResult,
              let events = result.result as? [NSPersistentCloudKitContainer.Event] else {
            return CloudMigrationReadiness(
                mirroredStoreIdentifiers: mirroredStoreIdentifiers,
                events: [],
                sessionStartedAt: cloudMigrationSessionStartedAt
            )
        }
        let summaries = events.map { event in
            let kind: CloudMigrationEventKind = switch event.type {
            case .setup: .setup
            case .import: .importing
            case .export: .exporting
            @unknown default: .setup
            }
            return CloudMigrationEventSummary(
                storeIdentifier: event.storeIdentifier,
                kind: kind,
                startDate: event.startDate,
                endDate: event.endDate,
                succeeded: event.succeeded
            )
        }
        return CloudMigrationReadiness(
            mirroredStoreIdentifiers: mirroredStoreIdentifiers,
            events: summaries,
            sessionStartedAt: cloudMigrationSessionStartedAt
        )
    }

    public static func storeDescriptions(
        applicationSupportURL: URL,
        mode: PersistenceMode
    ) -> [NSPersistentStoreDescription] {
        let legacyLocalRoot = applicationSupportURL
            .appendingPathComponent("PrivateRelationshipNotebook", isDirectory: true)
        let root: URL
        switch mode {
        case .localOnly:
            // Preserve the pre-CloudKit location as the permanent local vault.
            root = legacyLocalRoot
        case .cloud(_, let accountBinding), .cloudOffline(_, let accountBinding):
            let safeBinding = sanitizedAccountBinding(accountBinding)
            root = legacyLocalRoot
                .appendingPathComponent("Vaults", isDirectory: true)
                .appendingPathComponent("cloud", isDirectory: true)
                .appendingPathComponent(safeBinding, isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        } catch {
            logger.error("store_directory_create_failed")
        }

        let cloudIdentifier = mode.mirroredCloudContainerIdentifier
        let vault = description(
            url: root.appendingPathComponent("Vault.sqlite"),
            configuration: "VaultPrivate",
            type: NSSQLiteStoreType,
            cloudContainerIdentifier: cloudIdentifier
        )
        let derived = description(
            url: root.appendingPathComponent("Derived.sqlite"),
            configuration: "LocalDerived",
            type: NSSQLiteStoreType,
            cloudContainerIdentifier: nil
        )
        guard mode == .localOnly else {
            // Core Data rejects two stores that use the same CloudKit container
            // identifier and database scope. Cloud sessions therefore keep all
            // synchronized entities in one private store. Local sessions retain
            // the historical split so existing on-device profile data remains
            // readable before the reviewed archive migration.
            return [vault, derived]
        }
        let ownedProfiles = description(
            url: root.appendingPathComponent("OwnedProfiles.sqlite"),
            configuration: "OwnedProfilesPrivate",
            type: NSSQLiteStoreType,
            cloudContainerIdentifier: nil
        )
        return [vault, ownedProfiles, derived]
    }

    private func finishConfigurationAndLoad() {
        expectedStoreCount = container.persistentStoreDescriptions.count

        container.loadPersistentStores { [weak self] description, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    Self.logger.error("store_load_failed configuration=\(description.configuration ?? "default", privacy: .public)")
                    let configurationName = description.configuration ?? String(localized: "Default")
                    let errorType = String(describing: type(of: error))
                    loadIssues.append(String(
                        localized: "\(configurationName) store could not open (\(errorType)). The original files were not deleted."
                    ))
                }
                completedStoreCount += 1
                guard completedStoreCount >= expectedStoreCount else { return }
                #if DEBUG
                if mode.isMirroringEnabled,
                   ProcessInfo.processInfo.arguments.contains("--initialize-cloudkit-schema") {
                    do {
                        try container.initializeCloudKitSchema(options: [])
                    } catch {
                        Self.logger.error("cloudkit_schema_initialization_failed")
                        loadIssues.append(String(
                            localized: "The CloudKit development schema could not be initialized. Check signing, container ownership, and the Xcode console."
                        ))
                    }
                }
                #endif
                isReady = true
                let waiters = readinessWaiters
                readinessWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        container.viewContext.transactionAuthor = "app.user"
    }

    static func description(
        url: URL,
        configuration: String?,
        type: String,
        cloudContainerIdentifier: String?
    ) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.configuration = configuration
        description.type = type
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        #if os(iOS)
        description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject, forKey: NSPersistentStoreFileProtectionKey)
        #endif
        if let cloudContainerIdentifier {
            let options = NSPersistentCloudKitContainerOptions(
                containerIdentifier: cloudContainerIdentifier
            )
            options.databaseScope = .private
            description.cloudKitContainerOptions = options
        }
        return description
    }

    static func makeModel(mode: PersistenceMode = .localOnly) -> NSManagedObjectModel {
        makeModel(includesVaultEpochs: true, mode: mode)
    }

    static func makeLegacyV1Model() -> NSManagedObjectModel {
        makeModel(includesVaultEpochs: false, mode: .localOnly)
    }

    private static func makeModel(
        includesVaultEpochs: Bool,
        mode: PersistenceMode
    ) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let person = NSEntityDescription()
        person.name = "PersonEntity"
        person.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        var personProperties: [NSPropertyDescription] = [
            attribute("id", .UUIDAttributeType),
            attribute("displayName", .stringAttributeType, defaultValue: "", encrypted: true),
            attribute("pronunciation", .stringAttributeType, defaultValue: "", encrypted: true),
            attribute("aliasesData", .binaryDataAttributeType, encrypted: true),
            attribute("nameVariantsData", .binaryDataAttributeType, encrypted: true),
            attribute("contextsData", .binaryDataAttributeType, encrypted: true),
            attribute("role", .stringAttributeType, defaultValue: "", encrypted: true),
            attribute("tagsData", .binaryDataAttributeType, encrypted: true),
            attribute("privateNote", .stringAttributeType, defaultValue: "", encrypted: true),
            attribute("mentionableContext", .stringAttributeType, defaultValue: "", encrypted: true),
            attribute("circle", .stringAttributeType, defaultValue: RelationshipCircle.acquaintance.rawValue, encrypted: true),
            attribute("contactsData", .binaryDataAttributeType, encrypted: true),
            attribute("cadenceDays", .integer32AttributeType, defaultValue: 90),
            attribute("priority", .integer16AttributeType, defaultValue: 2),
            attribute("createdAt", .dateAttributeType),
            attribute("modifiedAt", .dateAttributeType),
            attribute("lastInteractionAt", .dateAttributeType),
            attribute("snoozedUntil", .dateAttributeType),
            attribute("isArchived", .booleanAttributeType, defaultValue: false),
            attribute("neverSuggest", .booleanAttributeType, defaultValue: false),
            attribute("doNotContact", .booleanAttributeType, defaultValue: false),
            attribute("deletedAt", .dateAttributeType),
            attribute("mergedIntoPersonID", .UUIDAttributeType),
            attribute("isSelfIdentity", .booleanAttributeType, defaultValue: false),
            attribute("sampleDataSetID", .UUIDAttributeType)
        ]
        if includesVaultEpochs {
            personProperties.append(attribute(
                "relationshipPreferencesData",
                .binaryDataAttributeType,
                encrypted: true
            ))
            personProperties.append(attribute("vaultEpochsData", .binaryDataAttributeType))
        }
        person.properties = personProperties

        let interaction = NSEntityDescription()
        interaction.name = "InteractionEntity"
        interaction.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        var interactionProperties: [NSPropertyDescription] = [
            attribute("id", .UUIDAttributeType),
            attribute("personID", .UUIDAttributeType),
            attribute("occurredAt", .dateAttributeType),
            attribute("kind", .stringAttributeType, defaultValue: InteractionKind.message.rawValue),
            attribute("channel", .stringAttributeType, defaultValue: "", encrypted: true),
            attribute("status", .stringAttributeType, defaultValue: InteractionStatus.confirmed.rawValue),
            attribute("summary", .stringAttributeType, defaultValue: "", encrypted: true),
            attribute("commitment", .stringAttributeType, defaultValue: "", encrypted: true),
            attribute("followUpAt", .dateAttributeType),
            attribute("detailsData", .binaryDataAttributeType, encrypted: true)
        ]
        if includesVaultEpochs {
            interactionProperties.append(attribute("vaultEpochsData", .binaryDataAttributeType))
        }
        interaction.properties = interactionProperties

        let canonical = recordEntity(
            named: "CanonicalRecordEntity",
            encryptedPayload: true,
            includesVaultEpochs: includesVaultEpochs
        )
        let profile = recordEntity(
            named: "ProfileRecordEntity",
            encryptedPayload: true,
            includesVaultEpochs: includesVaultEpochs
        )
        let derived = recordEntity(named: "DerivedRecordEntity", includesVaultEpochs: false)
        let mediaPayload = mediaPayloadEntity(includesVaultEpochs: includesVaultEpochs)

        model.versionIdentifiers = [includesVaultEpochs ? "RelationshipVaultV2" : "RelationshipVaultV1"]
        model.entities = [person, interaction, canonical, profile, derived, mediaPayload]
        let vaultEntities = mode == .localOnly
            ? [person, interaction, canonical, mediaPayload]
            : [person, interaction, canonical, profile, mediaPayload]
        model.setEntities(vaultEntities, forConfigurationName: "VaultPrivate")
        if mode == .localOnly {
            model.setEntities([profile], forConfigurationName: "OwnedProfilesPrivate")
        }
        model.setEntities([derived], forConfigurationName: "LocalDerived")
        return model
    }

    private static func recordEntity(
        named name: String,
        encryptedPayload: Bool = false,
        includesVaultEpochs: Bool = true
    ) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        var properties: [NSPropertyDescription] = [
            attribute("id", .UUIDAttributeType),
            attribute("kind", .stringAttributeType, optional: false, defaultValue: ""),
            attribute(
                "payload",
                .binaryDataAttributeType,
                optional: false,
                defaultValue: Data(),
                encrypted: encryptedPayload
            ),
            attribute("createdAt", .dateAttributeType),
            attribute("modifiedAt", .dateAttributeType),
            attribute("deletedAt", .dateAttributeType)
        ]
        if includesVaultEpochs {
            properties.append(attribute("vaultEpochsData", .binaryDataAttributeType))
        }
        entity.properties = properties
        return entity
    }

    private static func mediaPayloadEntity(
        includesVaultEpochs: Bool = true
    ) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "MediaPayloadEntity"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        let payload = attribute(
            "payload",
            .binaryDataAttributeType,
            optional: false,
            defaultValue: Data(),
            encrypted: true
        )
        payload.allowsExternalBinaryDataStorage = true
        var properties: [NSPropertyDescription] = [
            attribute("id", .UUIDAttributeType),
            payload,
            attribute("contentHash", .stringAttributeType, defaultValue: ""),
            attribute("createdAt", .dateAttributeType),
            attribute("modifiedAt", .dateAttributeType),
            attribute("deletedAt", .dateAttributeType)
        ]
        if includesVaultEpochs {
            properties.append(attribute("vaultEpochsData", .binaryDataAttributeType))
        }
        entity.properties = properties
        return entity
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = true,
        defaultValue: Any? = nil,
        encrypted: Bool = false
    ) -> NSAttributeDescription {
        let value = NSAttributeDescription()
        value.name = name
        value.attributeType = type
        value.isOptional = optional
        value.defaultValue = defaultValue
        value.allowsCloudEncryption = encrypted
        if name == "id" { value.preservesValueInHistoryOnDeletion = true }
        return value
    }

    private static func sanitizedAccountBinding(_ binding: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = binding.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let value = String(sanitized.prefix(96))
        return value.isEmpty ? "invalid-account-binding" : value
    }
}
