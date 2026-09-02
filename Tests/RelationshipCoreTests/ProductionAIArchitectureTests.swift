import Foundation
import Testing

private enum ProductionAIArchitectureTestError: Error {
    case repositoryRootNotFound
}

private func productionAIRepositoryRoot() throws -> URL {
    let fileManager = FileManager.default
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    while candidate.path != "/" {
        let manifest = candidate.appendingPathComponent("Package.swift")
        let project = candidate.appendingPathComponent(
            "RelationshipNotebook.xcodeproj/project.pbxproj"
        )
        if fileManager.fileExists(atPath: manifest.path),
           fileManager.fileExists(atPath: project.path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw ProductionAIArchitectureTestError.repositoryRootNotFound
}

private func productionAppSource(
    named fileName: String,
    root: URL
) throws -> String {
    try String(
        contentsOf: root
            .appendingPathComponent("Sources/RelationshipNotebookApp")
            .appendingPathComponent(fileName),
        encoding: .utf8
    )
}

private func compactedWhitespace(_ source: Substring) -> String {
    source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

@Test func productionTargetsExposeOnlyTheConfiguredShortcutAIArchitecture() throws {
    let root = try productionAIRepositoryRoot()
    let fileManager = FileManager.default
    let legacyFileNames = [
        "AppleFoundationModelClient.swift",
        "IntelligenceRouter.swift",
    ]

    let coreSourceDirectory = root.appendingPathComponent("Sources/RelationshipCore")
    for fileName in legacyFileNames {
        #expect(!fileManager.fileExists(
            atPath: coreSourceDirectory.appendingPathComponent(fileName).path
        ))
    }

    let projectText = try String(
        contentsOf: root.appendingPathComponent(
            "RelationshipNotebook.xcodeproj/project.pbxproj"
        ),
        encoding: .utf8
    )
    for fileName in legacyFileNames {
        #expect(!projectText.contains(fileName))
    }
    #expect(projectText.contains("ShortcutPCCBridge.swift in Sources"))

    let manifest = try String(
        contentsOf: root.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    let productStart = try #require(manifest.range(of: "products: ["))
    let dependencyStart = try #require(
        manifest.range(of: "dependencies: [", range: productStart.upperBound..<manifest.endIndex)
    )
    let productDeclaration = manifest[productStart.lowerBound..<dependencyStart.lowerBound]
    #expect(productDeclaration.contains("RelationshipCore"))
    #expect(!productDeclaration.contains("RelationshipLegacyIntelligence"))

    let appSourceDirectory = root.appendingPathComponent("Sources/RelationshipNotebookApp")
    let sourceEnumerator = try #require(fileManager.enumerator(
        at: appSourceDirectory,
        includingPropertiesForKeys: nil
    ))
    let forbiddenProductionSymbols = [
        "AIMode",
        "AppleFoundationModelClient",
        "IntelligenceRouter",
        "PCCEntitlementProvisioned",
        "PrivateCloudComputeLanguageModel",
        "RoutedTextIntelligenceService",
        "SystemLanguageModel",
    ]
    var appSource = ""
    while let URL = sourceEnumerator.nextObject() as? URL {
        guard URL.pathExtension == "swift" else { continue }
        appSource += "\n"
        appSource += try String(contentsOf: URL, encoding: .utf8)
    }
    for symbol in forbiddenProductionSymbols {
        let escapedSymbol = NSRegularExpression.escapedPattern(for: symbol)
        let symbolPattern = "(?<![A-Za-z0-9_])\(escapedSymbol)(?![A-Za-z0-9_])"
        #expect(
            appSource.range(of: symbolPattern, options: .regularExpression) == nil,
            "Production app sources reference the legacy symbol \(symbol)"
        )
    }

    let legacyDirectory = root.appendingPathComponent(
        "Sources/RelationshipLegacyIntelligence"
    )
    for fileName in legacyFileNames {
        let source = try String(
            contentsOf: legacyDirectory.appendingPathComponent(fileName),
            encoding: .utf8
        )
        #expect(source.hasPrefix("#if RELATIONSHIP_LEGACY_INTELLIGENCE"))
    }
}

@Test func shortcutSetupExplainsTheActualThreeActionWorkflow() throws {
    let root = try productionAIRepositoryRoot()
    let source = try productionAppSource(
        named: "ShortcutPCCBridge.swift",
        root: root
    )
    let lowercasedSource = source.lowercased()

    #expect(
        lowercasedSource.range(
            of: #"four(?:[\s-]+)(?:step|action)s?"#,
            options: .regularExpression
        ) == nil,
        "The setup must not imply that Shortcut Input is a fourth action."
    )
    #expect(
        lowercasedSource.range(
            of: #"three(?:[\s-]+)actions?"#,
            options: .regularExpression
        ) != nil,
        "The setup should tell users that they add three actions."
    )
    let explainsShortcutInputVariable = lowercasedSource.contains(
        "shortcut input is a variable"
    )
    #expect(
        explainsShortcutInputVariable,
        "The setup should explicitly distinguish Shortcut Input from an action."
    )
    let hasAppActionsEntryPoint = source.contains("ShortcutsLink")
    #expect(
        hasAppActionsEntryPoint,
        "The guided setup should offer a direct entry point to Keepsake's app actions."
    )
    #expect(
        source.contains("copyShortcutDescriptionPrompt()")
            && source.contains("Describe a Shortcut"),
        "The fastest iPhone path should copy a complete prompt for Apple's Shortcut builder."
    )
    #expect(
        source.contains("Use Blank Editor and Copy Name"),
        "A copied-name blank-editor fallback should remain available."
    )
}

@Test func shortcutSetupContinuouslyPollsForAPendingResult() throws {
    let root = try productionAIRepositoryRoot()
    let source = try productionAppSource(
        named: "ShortcutPCCBridge.swift",
        root: root
    )
    let pollingLoopStart = source.range(
        of: #"while\s+!Task\.isCancelled"#,
        options: .regularExpression
    )
    #expect(
        pollingLoopStart != nil,
        "A pending connection test should keep polling until it completes or is canceled."
    )
    guard let pollingLoopStart else { return }
    let pollingLoopEnd = source.index(
        pollingLoopStart.lowerBound,
        offsetBy: 2_500,
        limitedBy: source.endIndex
    ) ?? source.endIndex
    let pollingLoopWindow = source[
        pollingLoopStart.lowerBound..<pollingLoopEnd
    ]

    let checksPendingState = pollingLoopWindow.contains(
        "hasPendingConnectionTest"
    )
    let checksForResult = pollingLoopWindow.contains(
        "checkForCompletedConnectionTest()"
    )
    let yieldsBetweenChecks = pollingLoopWindow.contains("Task.sleep")
    #expect(checksPendingState)
    #expect(checksForResult)
    #expect(yieldsBetweenChecks)
}

@Test func onboardingAppliesTheSelectedLocaleToShortcutSetupImmediately() throws {
    let root = try productionAIRepositoryRoot()
    let source = try productionAppSource(
        named: "RootAndOnboarding.swift",
        root: root
    )
    let sheetStart = try #require(
        source.range(of: ".sheet(isPresented: $showingShortcutAISetup)")
    )
    let followingDeclaration = try #require(
        source.range(
            of: "private var shortcutAISetupReady",
            range: sheetStart.upperBound..<source.endIndex
        )
    )
    let shortcutSetupSheet = compactedWhitespace(
        source[sheetStart.lowerBound..<followingDeclaration.lowerBound]
    )

    let appliesSelectedLocaleDirectly = shortcutSetupSheet.contains(
        #".environment(\.locale, Locale(identifier: language))"#
    )
    let appliesSelectedLocaleThroughHelper = shortcutSetupSheet.contains(
        #".environment(\.locale, onboardingLocale)"#
    ) && compactedWhitespace(source[...]).contains(
        #"private var onboardingLocale: Locale { Locale(identifier: language) }"#
    )
    let appliesSelectedLocale = appliesSelectedLocaleDirectly
        || appliesSelectedLocaleThroughHelper
    #expect(
        appliesSelectedLocale,
        "Changing the onboarding language should localize the setup sheet before onboarding is saved."
    )
}

@Test func shortcutSetupRequiresChatGPTAndInvalidatesEarlierModelSetup() throws {
    let root = try productionAIRepositoryRoot()
    let bridgeSource = try productionAppSource(
        named: "ShortcutPCCBridge.swift",
        root: root
    )
    let onboardingSource = try productionAppSource(
        named: "RootAndOnboarding.swift",
        root: root
    )
    let captureSource = try productionAppSource(
        named: "CaptureAndSettingsViews.swift",
        root: root
    )
    let todaySource = try productionAppSource(
        named: "TodayAndPeopleViews.swift",
        root: root
    )

    #expect(bridgeSource.contains(
        #"static let defaultShortcutName = "Keepsake ChatGPT Connection""#
    ))
    #expect(bridgeSource.contains(
        #"static let legacyDefaultShortcutName = "Keepsake AI Connection""#
    ))
    #expect(bridgeSource.contains("currentSetupVerificationVersion = 2"))
    #expect(bridgeSource.contains("currentPrivacyAcknowledgmentVersion = 1"))
    #expect(bridgeSource.contains(
        #"setupTestContextPrefix = "shortcut-chatgpt-setup-v2.""#
    ))
    #expect(bridgeSource.contains("migrateLegacyModelSetupIfNeeded()"))

    for source in [bridgeSource, onboardingSource, captureSource, todaySource] {
        #expect(source.contains("Extension Model (ChatGPT)"))
        #expect(!source.contains("choose Private Cloud Compute"))
        #expect(!source.contains("Use Model remains set to Private Cloud Compute"))
    }

    #expect(bridgeSource.contains("ChatGPT not verified"))
    #expect(bridgeSource.contains("operated by OpenAI"))
    #expect(captureSource.contains("operated by OpenAI"))
    #expect(todaySource.contains("operated by OpenAI"))
    #expect(bridgeSource.contains("guard !isStartingConnectionTest,"))
    #expect(bridgeSource.contains("!hasPendingConnectionTest,"))
    #expect(bridgeSource.contains(
        "pendingTestRequestID.caseInsensitiveCompare("
    ))
    #expect(onboardingSource.contains(
        "await appSession.beginMoveToICloud {"
    ))
    #expect(onboardingSource.contains("before any long CloudKit wait"))
    #expect(onboardingSource.contains(
        "Today/lock-screen flash that can look"
    ))
    #expect(onboardingSource.contains("like an app crash"))
}

@Test func productionAppDoesNotCallOpenAIDirectly() throws {
    let root = try productionAIRepositoryRoot()
    let appSourceDirectory = root.appendingPathComponent(
        "Sources/RelationshipNotebookApp"
    )
    let enumerator = try #require(FileManager.default.enumerator(
        at: appSourceDirectory,
        includingPropertiesForKeys: nil
    ))
    var appSource = ""
    while let url = enumerator.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        appSource += try String(contentsOf: url, encoding: .utf8)
    }

    let forbiddenDirectClientMarkers = [
        "api.openai.com",
        "OPENAI_API_KEY",
        "Authorization: Bearer",
    ]
    for marker in forbiddenDirectClientMarkers {
        #expect(
            !appSource.contains(marker),
            "Keepsake must use the user-owned Shortcut, not a direct OpenAI client"
        )
    }
}
