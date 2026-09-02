import Foundation
import Testing

private enum ProductionAppSafetyTestError: Error {
    case repositoryRootNotFound
}

private func productionAppSafetyRepositoryRoot() throws -> URL {
    let fileManager = FileManager.default
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    while candidate.path != "/" {
        if fileManager.fileExists(
            atPath: candidate.appendingPathComponent("Package.swift").path
        ), fileManager.fileExists(
            atPath: candidate
                .appendingPathComponent("RelationshipNotebook.xcodeproj")
                .appendingPathComponent("project.pbxproj")
                .path
        ) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw ProductionAppSafetyTestError.repositoryRootNotFound
}

private func productionAppSafetySource(named fileName: String) throws -> String {
    try String(
        contentsOf: productionAppSafetyRepositoryRoot()
            .appendingPathComponent("Sources/RelationshipNotebookApp")
            .appendingPathComponent(fileName),
        encoding: .utf8
    )
}

@Test func appLockEnablementCommitsOnlyAfterPreflightAndAuthentication() throws {
    let source = try productionAppSafetySource(named: "SecurityViews.swift")
    let enableStart = try #require(source.range(of: "func enable() async -> Bool"))
    let disableStart = try #require(source.range(
        of: "func disable()",
        range: enableStart.upperBound..<source.endIndex
    ))
    let enablement = source[enableStart.lowerBound..<disableStart.lowerBound]

    let preflight = try #require(enablement.range(of: "canEvaluatePolicy"))
    let authentication = try #require(enablement.range(of: "evaluatePolicy"))
    let preferenceCommit = try #require(enablement.range(
        of: "defaults.set(true, forKey: Self.enabledPreferenceKey)"
    ))

    #expect(preflight.lowerBound < authentication.lowerBound)
    #expect(authentication.lowerBound < preferenceCommit.lowerBound)
    #expect(enablement.contains("guard success else"))
    #expect(enablement.contains("setupErrorMessage = setupFailureMessage"))
    #expect(source.contains("@Published private(set) var isEnabled: Bool"))
    #expect(source.contains("cocoaError.localizedFailureReason"))
    #expect(source.contains("Open System Settings"))
}

@Test func settingsAndOnboardingUseTheAuthenticatedAppLockTransaction() throws {
    let settings = try productionAppSafetySource(
        named: "CaptureAndSettingsViews.swift"
    )
    let onboarding = try productionAppSafetySource(named: "RootAndOnboarding.swift")

    #expect(settings.contains("_ = await lock.enable()"))
    #expect(settings.contains("lock.disable()"))
    #expect(settings.contains("lock.setupErrorMessage"))
    #expect(!settings.contains("lock.isEnabled ="))

    #expect(onboarding.contains("wantsLock = await lock.enable()"))
    #expect(onboarding.contains("lock.disable()"))
    #expect(onboarding.contains("lock.setupErrorMessage"))
    #expect(!onboarding.contains("lock.isEnabled = wantsLock"))
}

@Test func onboardingKeepsAllContentScrollableWithPersistentAdaptiveActions() throws {
    let source = try productionAppSafetySource(named: "RootAndOnboarding.swift")
    let onboardingStart = try #require(
        source.range(of: "struct OnboardingView: View")
    )
    let onboarding = source[onboardingStart.lowerBound..<source.endIndex]

    #expect(onboarding.contains("ScrollView {"))
    #expect(onboarding.contains(".safeAreaInset(edge: .bottom"))
    #expect(onboarding.contains("dynamicTypeSize.isAccessibilitySize"))
    #expect(onboarding.contains("VStack(spacing: 12)"))
    #expect(onboarding.contains("fixedSize(horizontal: false, vertical: true)"))
    #expect(onboarding.contains("setupActionsAreDisabled"))
}
