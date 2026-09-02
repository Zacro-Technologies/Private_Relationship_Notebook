import CoreData
import Foundation

public enum CloudSyncStoreConfiguration {
    public static let vault = "VaultPrivate"
    public static let ownedProfiles = "OwnedProfilesPrivate"

    static let mirrored: Set<String> = [vault, ownedProfiles]
}

public extension Notification.Name {
    /// Posted after a user-originated transaction affecting a CloudKit-mirrored
    /// store commits successfully. Reads, reloads, and archive imports do not
    /// post this notification.
    static let relationshipNotebookLocalMutationCommitted = Notification.Name(
        "RelationshipNotebook.localMutationCommitted"
    )

    /// Posted by the sync coordinator after a CloudKit import finishes so
    /// value-backed stores can publish a fresh snapshot to SwiftUI.
    static let relationshipNotebookRemoteImportCompleted = Notification.Name(
        "RelationshipNotebook.remoteImportCompleted"
    )
}

public enum CloudSyncNotificationUserInfoKey {
    /// A `Date` representing when the local transaction finished committing.
    public static let committedAt = "RelationshipNotebook.committedAt"
    /// The Core Data configuration that owns the committed transaction.
    public static let storeConfiguration = "RelationshipNotebook.storeConfiguration"
    /// Every Core Data configuration affected by a multi-store transaction.
    public static let storeConfigurations = "RelationshipNotebook.storeConfigurations"
    /// The persistent-store identifier, when the source context can resolve it.
    public static let storeIdentifier = "RelationshipNotebook.storeIdentifier"
    /// Every persistent-store identifier resolved for a multi-store transaction.
    public static let storeIdentifiers = "RelationshipNotebook.storeIdentifiers"
}

@MainActor
func postLocalMutationCommitted(
    source: AnyObject,
    at committedAt: Date = .now,
    storeConfigurations: Set<String>? = nil
) {
    var userInfo: [String: Any] = [CloudSyncNotificationUserInfoKey.committedAt: committedAt]
    if let storeConfigurations {
        let resolvedConfigurations: Set<String>
        if let context = source as? NSManagedObjectContext,
           let coordinator = context.persistentStoreCoordinator {
            let available = Set(
                coordinator.persistentStores.map(\.configurationName)
            )
            resolvedConfigurations = Set(storeConfigurations.map { configuration in
                if configuration == CloudSyncStoreConfiguration.ownedProfiles,
                   !available.contains(configuration),
                   available.contains(CloudSyncStoreConfiguration.vault) {
                    return CloudSyncStoreConfiguration.vault
                }
                return configuration
            })
        } else {
            resolvedConfigurations = storeConfigurations
        }
        let configurations = resolvedConfigurations.sorted()
        userInfo[CloudSyncNotificationUserInfoKey.storeConfigurations] = configurations
        if configurations.count == 1 {
            userInfo[CloudSyncNotificationUserInfoKey.storeConfiguration] = configurations[0]
        }

        if let context = source as? NSManagedObjectContext {
            let identifiers = context.persistentStoreCoordinator?.persistentStores.compactMap { store in
                resolvedConfigurations.contains(store.configurationName) ? store.identifier : nil
            } ?? []
            userInfo[CloudSyncNotificationUserInfoKey.storeIdentifiers] = identifiers
            if identifiers.count == 1 {
                userInfo[CloudSyncNotificationUserInfoKey.storeIdentifier] = identifiers[0]
            }
        }
    }
    NotificationCenter.default.post(
        name: .relationshipNotebookLocalMutationCommitted,
        object: source,
        userInfo: userInfo
    )
}
