import Foundation
import Testing

private enum PlatformReliabilityTestError: Error {
    case repositoryRootNotFound
}

private func platformReliabilityRepositoryRoot() throws -> URL {
    let fileManager = FileManager.default
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        if fileManager.fileExists(
            atPath: candidate.appendingPathComponent("Package.swift").path
        ) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw PlatformReliabilityTestError.repositoryRootNotFound
}

private func platformSource(_ name: String) throws -> String {
    try String(
        contentsOf: platformReliabilityRepositoryRoot()
            .appendingPathComponent("Sources/RelationshipNotebookApp")
            .appendingPathComponent(name),
        encoding: .utf8
    )
}

@Test func onboardingUsesLiveLocaleProgressAndAdaptiveAppearance() throws {
    let source = try platformSource("RootAndOnboarding.swift")
    let start = try #require(source.range(of: "struct OnboardingView: View"))
    let onboarding = source[start.lowerBound..<source.endIndex]

    #expect(onboarding.contains(".environment(\\.locale, onboardingLocale)"))
    #expect(onboarding.contains("ProgressView(value: Double(page + 1), total: 4)"))
    #expect(onboarding.contains("Changes this setup screen immediately."))
    #expect(onboarding.contains("AppTheme.cardBackground"))
    #expect(onboarding.contains("firstPersonContext"))
    #expect(onboarding.contains("firstPersonContactKind"))
    #expect(onboarding.contains("First suggestion preview"))
    #expect(onboarding.contains("deterministic and generated on this device"))
    #expect(onboarding.contains("contacts: contacts"))
    #expect(!onboarding.contains(".environment(\\.colorScheme, .light)"))
}

@Test func appLockUsesAdaptiveSemanticColorsAndScrollsAtLargeTextSizes() throws {
    let source = try platformSource("SecurityViews.swift")
    let start = try #require(source.range(of: "struct AppLockView: View"))
    let end = try #require(source.range(of: "struct PrivacyCurtain: View"))
    let appLock = source[start.lowerBound..<end.lowerBound]

    #expect(appLock.contains("ScrollView"))
    #expect(appLock.contains("AppTheme.pageBackground"))
    #expect(appLock.contains("AppTheme.cardBackground"))
    #expect(appLock.contains("AppTheme.secondaryText"))
    #expect(!appLock.contains("AppTheme.paperCream"))
    #expect(!appLock.contains(".environment(\\.colorScheme, .light)"))
}

@Test func phoneNavigationAvoidsTabOverlayInCompactLandscape() throws {
    let source = try platformSource("RootAndOnboarding.swift")

    #expect(source.contains("if verticalSizeClass == .compact"))
    #expect(source.contains("compactLandscapeRoot"))
    #expect(source.contains("tabBarClearance"))
    #expect(source.contains(".frame(height: 72)"))
    #expect(source.contains("horizontalSizeClass == .regular"))
}

@Test func phoneMeTabSeparatesIdentityFromSettings() throws {
    let source = try platformSource("RootAndOnboarding.swift")

    #expect(source.contains("tabDestination(.settings) { MeView() }"))
    #expect(source.contains("struct MeView: View"))
    #expect(source.contains("$0.isSelf && $0.deletedAt == nil"))
    #expect(source.contains("Label(\"Open My Profile\""))
    #expect(source.contains("Label(\"Edit My Profile\""))
    #expect(source.contains("Label(\"Settings & Privacy\""))
    #expect(source.contains("Your optional Self profile"))
}

@Test func receivedFilesQueueUntilUnlockedReviewAndHaveDocumentRoles() throws {
    let app = try platformSource("RelationshipNotebookApp.swift")
    let root = try platformSource("RootAndOnboarding.swift")
    let platform = try platformSource("PlatformReliabilityViews.swift")

    #expect(app.contains(".onOpenURL"))
    #expect(app.contains("inboundDocuments.enqueue(URL, source: .openURL)"))
    #expect(root.contains("guard !lock.isLocked, inboundDocument == nil"))
    #expect(root.contains(".dropDestination(for: URL.self)"))
    #expect(platform.contains("Review this file before Keepsake reads it"))
    #expect(platform.contains("lifecycle: .pending"))
    #expect(platform.contains("stageReviewedProfileURL(request.url)"))
    #expect(platform.contains("stageReviewedArchiveURL(request.url)"))
    #expect(platform.contains("takeRoutedProfileURL()"))
    #expect(platform.contains("takeRoutedArchiveURL()"))

    let plistData = try Data(contentsOf: platformReliabilityRepositoryRoot()
        .appendingPathComponent("Resources/Keepsake-Info.plist"))
    let plist = try #require(
        PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any]
    )
    let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
    let identifiers = Set(documentTypes.flatMap {
        $0["LSItemContentTypes"] as? [String] ?? []
    })
    #expect(identifiers.contains("com.zacrotech.keepsake.relationship-vault"))
    #expect(identifiers.contains("com.zacrotech.keepsake.profile-snapshot-v1"))
    #expect(identifiers.contains("public.plain-text"))
    #expect(identifiers.contains("com.adobe.pdf"))
}

@Test func shareExtensionQueuesProtectedItemsForUnlockedReview() throws {
    let root = try platformReliabilityRepositoryRoot()
    let extensionSource = try String(
        contentsOf: root.appendingPathComponent("ShareExtension/ShareViewController.swift"),
        encoding: .utf8
    )
    let platform = try platformSource("PlatformReliabilityViews.swift")
    let app = try platformSource("RelationshipNotebookApp.swift")
    let project = try String(
        contentsOf: root.appendingPathComponent("RelationshipNotebook.xcodeproj/project.pbxproj"),
        encoding: .utf8
    )

    #expect(project.contains("KeepsakeShare.appex in Embed App Extensions"))
    #expect(project.contains("platformFilter = ios"))
    #expect(extensionSource.contains("maximumFileCount = 20"))
    #expect(extensionSource.contains("maximumTotalBytes"))
    #expect(extensionSource.contains(".completeFileProtection"))
    #expect(extensionSource.contains("manifest.json"))
    #expect(platform.contains("stagePendingShareExtensionItems"))
    #expect(platform.contains("guard manifest.version == 1"))
    #expect(app.contains("URL.host?.lowercased() == \"shared-capture\""))
}

@Test func fatalOpenFailureOffersReviewedRecoveryActionsAndSafeDiagnostics() throws {
    let app = try platformSource("RelationshipNotebookApp.swift")
    let session = try platformSource("AppSessionController.swift")

    #expect(app.contains("Button(\"Retry\")"))
    #expect(app.contains("Button(\"Review Recovery Checkpoint\")"))
    #expect(app.contains("Button(\"Use Separate Local-Only Notebook\")"))
    #expect(app.contains("Button(\"Open Diagnostics\")"))
    #expect(app.contains("contains no names, notes, file paths, or notebook contents"))
    #expect(session.contains("var hasPendingRecoveryCheckpoint"))
}

@Test func portraitLoadingHasTerminalFailureFallbackRetryAndDiagnostic() throws {
    let source = try platformSource("PortraitViews.swift")

    #expect(source.contains("enum PortraitThumbnailState"))
    #expect(source.contains("case failed"))
    #expect(source.contains("Button(\"Retry\")"))
    #expect(source.contains("Retry portrait"))
    #expect(source.contains("PORTRAIT-"))
    #expect(source.contains("Color.clear"))
    #expect(source.contains("Button(\"Remove Photo…\""))
}

@Test func vaultDeletionClearsOnlyVaultScopedTransientState() throws {
    let theme = try platformSource("Theme.swift")
    let settings = try platformSource("CaptureAndSettingsViews.swift")

    #expect(theme.contains("enum VaultScopedTransientState"))
    #expect(theme.contains("nudgeSuggestionHistory.v2."))
    #expect(theme.contains("shortcutPCCBridgePendingTodayPersonID"))
    #expect(settings.contains("VaultScopedTransientState.clear()"))
    #expect(settings.contains("Application preferences remain"))
    #expect(settings.contains("notificationDelivery.clearPendingRoute()"))
    #expect(settings.contains("reconcileNotificationsForCurrentSession"))
}

@Test func settingsExposeRetentionAndNameDefaultsAndNotificationErrors() throws {
    let source = try platformSource("CaptureAndSettingsViews.swift")

    #expect(source.contains("KeepsakePreferenceKey.defaultImportedSourceRetention"))
    #expect(source.contains("KeepsakePreferenceKey.defaultImportedTranscriptRetention"))
    #expect(source.contains("KeepsakePreferenceKey.nameDisplayOrder"))
    #expect(source.contains("Each import still has its own review"))
    #expect(source.contains("notificationEnablementError"))
    #expect(source.contains("unsigned development build"))
}

@Test func externalQualificationWorkIsExplicitlyTracked() throws {
    let checklist = try String(
        contentsOf: platformReliabilityRepositoryRoot()
            .appendingPathComponent("PLATFORM_QUALIFICATION_CHECKLIST.md"),
        encoding: .utf8
    )

    #expect(checklist.contains("does **not** qualify"))
    #expect(checklist.contains("VoiceOver"))
    #expect(checklist.contains("Signed physical device"))
    #expect(checklist.contains("iPad multiwindow"))
    #expect(checklist.contains("Double-click/Open In"))
    #expect(checklist.contains("Paid-team CloudKit build"))
}
