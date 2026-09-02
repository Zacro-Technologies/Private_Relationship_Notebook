import Combine
import Foundation
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum RemoteNotificationRegistrationState: Equatable, Sendable {
    case disabled
    case registering
    case registered
    case unavailable

    var localizedTitle: String {
        localizedTitle(locale: .current)
    }

    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .disabled:
            String(localized: "Off", locale: locale)
        case .registering:
            String(localized: "Checking…", locale: locale)
        case .registered:
            String(localized: "Available", locale: locale)
        case .unavailable:
            String(localized: "Unavailable", locale: locale)
        }
    }
}

/// Owns only ephemeral APNs state and an in-app navigation intent. Device
/// tokens are deliberately neither logged nor cached. CloudKit is the only
/// remote provider in this app, so there is no app-owned token endpoint.
@MainActor
final class NotificationDeliveryState: ObservableObject {
    static let shared = NotificationDeliveryState()

    @Published private(set) var remoteRegistration: RemoteNotificationRegistrationState = .disabled
    @Published private(set) var pendingRoute: ConnectionNotificationRoute?

    private var cloudSyncEnabled = false

    private init() {}

    func updateCloudSyncPreference(enabled: Bool) {
        cloudSyncEnabled = enabled
        guard enabled else {
            unregisterForRemoteNotifications()
            remoteRegistration = .disabled
            return
        }
        registerIfNeeded()
    }

    func retryRegistrationIfNeeded() {
        guard cloudSyncEnabled, remoteRegistration == .unavailable else { return }
        registerIfNeeded()
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard cloudSyncEnabled else {
            unregisterForRemoteNotifications()
            remoteRegistration = .disabled
            return
        }
        // A nonempty token proves APNs registration. The bytes are intentionally
        // discarded because NSPersistentCloudKitContainer owns the provider path.
        remoteRegistration = deviceToken.isEmpty ? .unavailable : .registered
    }

    func didFailToRegisterForRemoteNotifications() {
        guard cloudSyncEnabled else { return }
        remoteRegistration = .unavailable
    }

    func open(_ route: ConnectionNotificationRoute) {
        pendingRoute = route
    }

    func consume(_ route: ConnectionNotificationRoute) {
        guard pendingRoute == route else { return }
        pendingRoute = nil
    }

    func clearPendingRoute() {
        pendingRoute = nil
    }

    private func registerIfNeeded() {
        guard remoteRegistration != .registering,
              remoteRegistration != .registered else { return }
        remoteRegistration = .registering
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    private func unregisterForRemoteNotifications() {
        #if os(iOS)
        UIApplication.shared.unregisterForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.unregisterForRemoteNotifications()
        #endif
    }
}

/// Installed before launch completes so foreground delivery and taps are never
/// missed. Silent CloudKit pushes have no Keepsake category and remain silent;
/// only locally-authored connection reminders opt into foreground presentation.
private final class KeepsakeUserNotificationDelegate: NSObject,
    UNUserNotificationCenterDelegate,
    @unchecked Sendable {
    static let shared = KeepsakeUserNotificationDelegate()

    @MainActor
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: ConnectionNotificationMetadata.categoryIdentifier,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let category = notification.request.content.categoryIdentifier
        guard category == ConnectionNotificationMetadata.categoryIdentifier else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let content = response.notification.request.content
        guard let route = ConnectionNotificationMetadata.route(
            from: content.userInfo,
            categoryIdentifier: content.categoryIdentifier
        ) else { return }
        Task { @MainActor in
            NotificationDeliveryState.shared.open(route)
        }
    }
}

#if os(iOS)
@MainActor
final class KeepsakeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        KeepsakeUserNotificationDelegate.shared.install()
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationDeliveryState.shared.updateCloudSyncPreference(
            enabled: UserDefaults.standard.bool(forKey: "syncEnabled")
        )
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationDeliveryState.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        NotificationDeliveryState.shared.didFailToRegisterForRemoteNotifications()
    }
}
#elseif os(macOS)
@MainActor
final class KeepsakeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        KeepsakeUserNotificationDelegate.shared.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationDeliveryState.shared.updateCloudSyncPreference(
            enabled: UserDefaults.standard.bool(forKey: "syncEnabled")
        )
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationDeliveryState.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        NotificationDeliveryState.shared.didFailToRegisterForRemoteNotifications()
    }
}
#endif
