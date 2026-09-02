import AppIntents
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Shared by the app UI and App Intents so they resolve the same protected,
/// short-lived handoff directory. A failure remains recoverable: callers show
/// the deterministic/manual baseline instead of exposing a filesystem error.
enum ShortcutPCCBridgeRuntime {
    static let store = try? ShortcutModelHandoffStore.live()
}

extension Notification.Name {
    static let shortcutPCCBridgeDidSaveResult = Notification.Name(
        "com.zacrotech.keepsake.shortcut-pcc-bridge.did-save-result"
    )
}

enum ShortcutPCCBridgeNotificationUserInfoKey {
    static let requestID = "requestID"
}

/// Intentionally hides storage paths, request existence, model output, and
/// validation details from Shortcuts dialogs and system logs.
private enum ShortcutPCCBridgeIntentError: LocalizedError {
    case requestUnavailable

    var errorDescription: String? {
        String(localized: "Keepsake couldn’t complete this private handoff. Return to Keepsake and start again.")
    }
}

@available(iOS 26.0, macOS 26.0, *)
struct GetPreparedAIRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Prepared AI Request"
    static let description = IntentDescription(
        "Gets short-lived AI input that you explicitly prepared in Keepsake."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy =
        .requiresLocalDeviceAuthentication
    static let supportedModes: IntentModes = [.background]

    static var parameterSummary: some ParameterSummary {
        Summary("Get prepared AI request for \(\.$requestCode)")
    }

    @Parameter(
        title: "Request Code",
        description: "Choose Shortcut Input — the text passed into this Shortcut."
    )
    var requestCode: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let store = ShortcutPCCBridgeRuntime.store else {
            throw ShortcutPCCBridgeIntentError.requestUnavailable
        }
        do {
            let prompt = try await store.retrievePrompt(requestCode: requestCode)
            return .result(value: prompt.modelInput)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ShortcutPCCBridgeIntentError.requestUnavailable
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
struct ReturnAIResultIntent: AppIntent {
    static let title: LocalizedStringResource = "Return AI Result"
    static let description = IntentDescription(
        "Returns model output to the matching short-lived Keepsake request."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy =
        .requiresLocalDeviceAuthentication
    static let supportedModes: IntentModes = [
        .background,
        .foreground(.deferred),
    ]

    static var parameterSummary: some ParameterSummary {
        Summary("Return \(\.$aiResult) for request \(\.$requestCode)")
    }

    @Parameter(
        title: "Request Code",
        description: "Choose the original Shortcut Input, not the previous action’s output."
    )
    var requestCode: String

    @Parameter(
        title: "AI Result",
        description: "Choose the Text output from Use Model.",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var aiResult: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = ShortcutPCCBridgeRuntime.store else {
            throw ShortcutPCCBridgeIntentError.requestUnavailable
        }
        do {
            let result = try await store.submitResult(
                requestCode: requestCode,
                modelResponse: aiResult
            )
            NotificationCenter.default.post(
                name: .shortcutPCCBridgeDidSaveResult,
                object: nil,
                userInfo: [
                    ShortcutPCCBridgeNotificationUserInfoKey.requestID: result.requestID,
                ]
            )
            return .result(dialog: "The AI result is ready in Keepsake.")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ShortcutPCCBridgeIntentError.requestUnavailable
        }
    }
}

enum ShortcutPCCBridgeSetupState: String, Hashable, Sendable {
    case unsupportedOS
    case privacyAcknowledgmentRequired
    case shortcutConfigurationRequired
    case ready
}

enum ShortcutPCCBridgePreferences {
    static let setupCompletedKey = "shortcutPCCBridgeSetupCompleted"
    static let setupVerificationVersionKey =
        "shortcutPCCBridgeSetupVerificationVersion"
    static let setupVerifiedAtKey = "shortcutPCCBridgeSetupVerifiedAt"
    static let privacyAcknowledgmentKey = "shortcutPCCBridgePrivacyAcknowledged"
    static let privacyAcknowledgmentVersionKey =
        "shortcutPCCBridgePrivacyAcknowledgmentVersion"
    static let shortcutNameKey = "shortcutPCCBridgeShortcutName"
    static let shortcutBuilderStartedKey =
        "shortcutPCCBridgeShortcutBuilderStarted"
    static let pendingSetupTestRequestIDKey =
        "shortcutPCCBridgePendingSetupTestRequestID"
    static let pendingSetupTestContextIdentifierKey =
        "shortcutPCCBridgePendingSetupTestContextIdentifier"
    static let pendingSetupTestChallengeKey =
        "shortcutPCCBridgePendingSetupTestChallenge"
    static let pendingSetupTestShortcutNameKey =
        "shortcutPCCBridgePendingSetupTestShortcutName"
    static let pendingSetupTestExpirationKey =
        "shortcutPCCBridgePendingSetupTestExpiration"
    static let defaultShortcutName = "Keepsake ChatGPT Connection"
    static let legacyDefaultShortcutName = "Keepsake AI Connection"
    // Version 2 deliberately invalidates connection tests completed for the
    // earlier Private Cloud Compute setup. The transport challenge cannot
    // attest which editable model action a Shortcut actually uses.
    static let currentSetupVerificationVersion = 2
    // Provider-specific acknowledgment is separate from transport readiness so
    // an update cannot silently reuse consent granted for a different model.
    static let currentPrivacyAcknowledgmentVersion = 1
    static let setupTestContextPrefix = "shortcut-chatgpt-setup-v2."
    static let maximumSetupVerificationAge: TimeInterval = 30 * 24 * 60 * 60

    static var isPlatformSupported: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { true }
        else { false }
    }

    static func setupState(
        setupCompleted: Bool,
        privacyAcknowledged: Bool,
        shortcutName: String
    ) -> ShortcutPCCBridgeSetupState {
        setupState(
            setupCompleted: setupCompleted,
            privacyAcknowledged: privacyAcknowledged,
            shortcutName: shortcutName,
            verificationVersion: UserDefaults.standard.integer(
                forKey: setupVerificationVersionKey
            ),
            privacyAcknowledgmentVersion: UserDefaults.standard.integer(
                forKey: privacyAcknowledgmentVersionKey
            ),
            verifiedAt: UserDefaults.standard.double(forKey: setupVerifiedAtKey),
            now: .now
        )
    }

    private static func setupState(
        setupCompleted: Bool,
        privacyAcknowledged: Bool,
        shortcutName: String,
        verificationVersion: Int,
        privacyAcknowledgmentVersion: Int,
        verifiedAt: TimeInterval,
        now: Date
    ) -> ShortcutPCCBridgeSetupState {
        guard isPlatformSupported else { return .unsupportedOS }
        guard privacyAcknowledged,
              privacyAcknowledgmentVersion == currentPrivacyAcknowledgmentVersion else {
            return .privacyAcknowledgmentRequired
        }
        let age = now.timeIntervalSince1970 - verifiedAt
        guard setupCompleted,
              verificationVersion == currentSetupVerificationVersion,
              verifiedAt > 0,
              age >= -300,
              age <= maximumSetupVerificationAge,
              normalizedShortcutName(shortcutName) != nil else {
            return .shortcutConfigurationRequired
        }
        return .ready
    }

    static func isSetupReady(
        setupCompleted: Bool,
        privacyAcknowledged: Bool,
        shortcutName: String
    ) -> Bool {
        setupState(
            setupCompleted: setupCompleted,
            privacyAcknowledged: privacyAcknowledged,
            shortcutName: shortcutName
        ) == .ready
    }

    static func setupState(
        defaults: UserDefaults = .standard
    ) -> ShortcutPCCBridgeSetupState {
        setupState(
            setupCompleted: defaults.bool(forKey: setupCompletedKey),
            privacyAcknowledged: defaults.bool(forKey: privacyAcknowledgmentKey),
            shortcutName: configuredShortcutName(defaults: defaults),
            verificationVersion: defaults.integer(
                forKey: setupVerificationVersionKey
            ),
            privacyAcknowledgmentVersion: defaults.integer(
                forKey: privacyAcknowledgmentVersionKey
            ),
            verifiedAt: defaults.double(forKey: setupVerifiedAtKey),
            now: .now
        )
    }

    static func isSetupReady(defaults: UserDefaults = .standard) -> Bool {
        setupState(defaults: defaults) == .ready
    }

    static func isPrivacyAcknowledgmentCurrent(
        acknowledged: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        acknowledged && defaults.integer(forKey: privacyAcknowledgmentVersionKey)
            == currentPrivacyAcknowledgmentVersion
    }

    static func configuredShortcutName(
        defaults: UserDefaults = .standard
    ) -> String {
        defaults.string(forKey: shortcutNameKey) ?? defaultShortcutName
    }

    static func isShortcutNameValid(_ shortcutName: String) -> Bool {
        normalizedShortcutName(shortcutName) != nil
    }

    static var createShortcutURL: URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "create-shortcut"
        return components.url
    }

    static func openShortcutURL(named rawName: String) -> URL? {
        guard let name = normalizedShortcutName(rawName) else { return nil }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "open-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    /// Builds the documented Shortcuts launch URL. Only an opaque, bounded
    /// request code crosses the URL boundary; the prompt and response never do.
    static func runShortcutURL(
        named rawName: String,
        requestCode rawRequestCode: String
    ) -> URL? {
        guard let name = normalizedShortcutName(rawName),
              let requestCode = normalizedRequestCode(rawRequestCode) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: requestCode),
        ]
        return components.url
    }

    private static func normalizedShortcutName(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 120,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func normalizedRequestCode(_ rawValue: String) -> String? {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 256 else { return nil }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        guard rawValue.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return rawValue
    }
}

struct ShortcutPCCBridgeSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @AppStorage(ShortcutPCCBridgePreferences.setupCompletedKey)
    private var setupCompleted = false
    @AppStorage(ShortcutPCCBridgePreferences.setupVerificationVersionKey)
    private var setupVerificationVersion = 0
    @AppStorage(ShortcutPCCBridgePreferences.setupVerifiedAtKey)
    private var setupVerifiedAt = 0.0
    @AppStorage(ShortcutPCCBridgePreferences.privacyAcknowledgmentKey)
    private var privacyAcknowledged = false
    @AppStorage(ShortcutPCCBridgePreferences.privacyAcknowledgmentVersionKey)
    private var privacyAcknowledgmentVersion = 0
    @AppStorage(ShortcutPCCBridgePreferences.shortcutNameKey)
    private var shortcutName = ShortcutPCCBridgePreferences.defaultShortcutName
    @AppStorage(ShortcutPCCBridgePreferences.shortcutBuilderStartedKey)
    private var shortcutBuilderStarted = false
    @AppStorage(ShortcutPCCBridgePreferences.pendingSetupTestRequestIDKey)
    private var pendingTestRequestID = ""
    @AppStorage(ShortcutPCCBridgePreferences.pendingSetupTestContextIdentifierKey)
    private var pendingTestContextIdentifier = ""
    @AppStorage(ShortcutPCCBridgePreferences.pendingSetupTestChallengeKey)
    private var pendingTestChallenge = ""
    @AppStorage(ShortcutPCCBridgePreferences.pendingSetupTestShortcutNameKey)
    private var pendingTestShortcutName = ""
    @AppStorage(ShortcutPCCBridgePreferences.pendingSetupTestExpirationKey)
    private var pendingTestExpiration = 0.0
    @State private var showingAcknowledgment = false
    @State private var isStartingConnectionTest = false
    @State private var connectionTestAttemptID: UUID?
    @State private var connectionTestMessage: String?
    @State private var connectionTestSucceeded = false
    @State private var shortcutBuilderMessage: String?
    @State private var showingAdvancedSetup = false
    @State private var showingDisconnectConfirmation = false

    var body: some View {
        Form {
            if #available(iOS 26.0, macOS 26.0, *) {
                supportedSettings
            } else {
                Section("Keepsake AI Shortcut") {
                    Label(
                        "Keepsake’s AI connection requires iOS 26 or macOS 26 and an Apple Intelligence compatible device.",
                        systemImage: "iphone.slash"
                    )
                    Text("Personalized AI features are unavailable on this system. The private notebook and its deterministic/manual features remain available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Setup status") {
                    Label("AI connection unavailable on this OS", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connect Keepsake AI")
        .keepsakeSheetSize(minWidth: 640, minHeight: 720)
        .onAppear {
            migrateLegacyModelSetupIfNeeded()
        }
        .onChange(of: shortcutName) { _, _ in
            invalidateVerifiedSetup()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await checkForCompletedConnectionTest() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .shortcutPCCBridgeDidSaveResult)
        ) { notification in
            guard let requestID = notification.userInfo?[
                ShortcutPCCBridgeNotificationUserInfoKey.requestID
            ] as? UUID,
                  requestID.uuidString.caseInsensitiveCompare(
                    pendingTestRequestID
                  ) == .orderedSame else { return }
            Task { await checkForCompletedConnectionTest() }
        }
        .task(id: pendingTestRequestID) {
            await pollForCompletedConnectionTest()
        }
        .alert("Connect the Keepsake AI Shortcut?", isPresented: $showingAcknowledgment) {
            Button("Cancel", role: .cancel) {}
            Button("I Understand and Allow ChatGPT") {
                privacyAcknowledged = true
                privacyAcknowledgmentVersion =
                    ShortcutPCCBridgePreferences.currentPrivacyAcknowledgmentVersion
            }
        } message: {
            Text("The exact AI input you review—including a contact’s name and any selected relationship context—leaves Keepsake through Apple Shortcuts and is intended for ChatGPT, operated by OpenAI. If you sign in to ChatGPT, your ChatGPT account settings and history controls apply. Keepsake cannot inspect or attest the selected model, added actions, account state, or retention.")
        }
        .confirmationDialog(
            "Disconnect the Keepsake AI Shortcut?",
            isPresented: $showingDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await disconnectAIShortcut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears Keepsake’s connection status and privacy acknowledgment. It does not delete the Shortcut from the Shortcuts app.")
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    @ViewBuilder
    private var supportedSettings: some View {
        if currentSetupState == .ready {
            connectedSettings
        } else {
            Section("1. Review the handoff") {
                setupStatusLabel
                Text("Keepsake uses one configured Shortcut as its AI connection. Complete this setup before personalized recommendations, contact drafts, and other AI features can run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !privacyAcknowledgmentIsCurrent {
                    Button("Review ChatGPT Privacy and Continue") {
                        showingAcknowledgment = true
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Label("Privacy handoff acknowledged", systemImage: "checkmark.shield")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            if privacyAcknowledgmentIsCurrent {
                shortcutBuilderSettings
                connectionTestSettings
                advancedSettings
            }
        }

        Section("Important privacy limitation") {
            Label(
                "This setup requires Use Model → Extension Model (ChatGPT), but Keepsake cannot inspect or attest that choice, added or changed actions, your ChatGPT account mode, or retention. Review the Shortcut before using it with private context.",
                systemImage: "exclamationmark.shield"
            )
            .font(.caption)
            .keepsakeWarningStyle()
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    @ViewBuilder
    private var connectedSettings: some View {
        Section("Transport connected") {
            Label("Authenticated Shortcut transport connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            LabeledContent("Shortcut", value: shortcutName)
            if setupVerifiedAt > 0 {
                LabeledContent("Last transport test") {
                    Text(
                        Date(timeIntervalSince1970: setupVerifiedAt),
                        format: .dateTime.year().month().day().hour().minute()
                    )
                }
                LabeledContent("Re-test by") {
                    Text(
                        Date(
                            timeIntervalSince1970: setupVerifiedAt
                                + ShortcutPCCBridgePreferences.maximumSetupVerificationAge
                        ),
                        format: .dateTime.year().month().day()
                    )
                }
            }
            Text("Keepsake can now start this named Shortcut with a protected one-time request code.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Review Shortcut") {
                openConfiguredShortcut()
            }
            Button("Re-test Connection") {
                Task { await startConnectionTest() }
            }
            .disabled(isStartingConnectionTest || hasPendingConnectionTest)
            Button("Disconnect", role: .destructive) {
                showingDisconnectConfirmation = true
            }
        }

        Section("Verification") {
            Text("Keepsake requires a new protected transport test every 30 days and whenever the saved Shortcut name changes. The test does not prove which model ran. Before every private request, confirm Use Model is still set to Extension Model (ChatGPT) and review every action.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(
                "Authenticated request and return transport verified; ChatGPT not verified",
                systemImage: "checkmark.shield"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    @ViewBuilder
    private var shortcutBuilderSettings: some View {
        Section("2. Build the Shortcut once") {
            Text("Use the exact name below so Keepsake can open it automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text("Shortcut name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ShortcutPCCBridgePreferences.defaultShortcutName)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Text("Before building, turn on Apple Intelligence and enable the ChatGPT extension in Settings → Apple Intelligence & Siri → ChatGPT. A ChatGPT account is optional; availability depends on device, language, age, and region.")
                .font(.caption)
                .foregroundStyle(.secondary)

            #if os(iOS)
            Text("Fastest setup")
                .font(.subheadline.weight(.semibold))
            ShortcutsLink {
                beginDescribedShortcutSetup()
            }
            .shortcutsLinkStyle(.automatic)
            Text("A complete, non-personal setup prompt is copied. Paste it into Describe a Shortcut, review the generated three actions, and then return here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Button {
                beginRecommendedShortcutSetup()
            } label: {
                Label("Use Blank Editor and Copy Name", systemImage: "plus.app")
            }
            #else
            Button {
                beginRecommendedShortcutSetup()
            } label: {
                Label("Create Shortcut and Copy Name", systemImage: "plus.app")
            }
            .buttonStyle(.borderedProminent)
            #endif

            Button("I already created it — open it") {
                openConfiguredShortcut()
            }
            .disabled(
                ShortcutPCCBridgePreferences.openShortcutURL(named: shortcutName) == nil
            )

            if let shortcutBuilderMessage {
                Label(shortcutBuilderMessage, systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if shortcutBuilderStarted {
                Label(
                    "Shortcut editor opened — add the three actions below.",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()
            Text("Shortcut Input is a variable, not a fourth action. Add only these three actions:")
                .font(.subheadline.weight(.semibold))
            setupStep(
                1,
                title: "Get Prepared AI Request",
                detail: "Add the Keepsake action and set Request Code to Shortcut Input."
            )
            setupStep(
                2,
                title: "Use Model",
                detail: "Use the prepared AI request as input, choose Extension Model (ChatGPT), turn Follow Up off, and choose Text output."
            )
            setupStep(
                3,
                title: "Return AI Result",
                detail: "Set Request Code to the original Shortcut Input and AI Result to the Use Model response."
            )
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    @ViewBuilder
    private var connectionTestSettings: some View {
        Section("3. Verify the connection") {
            Text("The test contains no notebook data. When the Shortcut finishes, Keepsake detects the result automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if hasPendingConnectionTest {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the Shortcut to return its test result…")
                }
                Button("Cancel Connection Test", role: .cancel) {
                    Task { await cancelPendingConnectionTest() }
                }
            } else {
                Button("Verify Connection") {
                    Task { await startConnectionTest() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isStartingConnectionTest || !privacyAcknowledgmentIsCurrent
                        || !ShortcutPCCBridgePreferences.isShortcutNameValid(
                            shortcutName
                        )
                )
                if isStartingConnectionTest {
                    ProgressView("Preparing a private connection test…")
                }
                Text("The test contains no notebook data. A successful round trip validates Keepsake’s authenticated request/return transport and exact challenge response. It does not verify Use Model, Extension Model (ChatGPT), your ChatGPT account mode, or other Shortcut actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let connectionTestMessage {
                Label(
                    connectionTestMessage,
                    systemImage: connectionTestSucceeded
                        ? "checkmark.circle.fill"
                        : "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(connectionTestSucceeded ? .green : .orange)
            }
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private var advancedSettings: some View {
        Section {
            DisclosureGroup(
                "Advanced: custom name or manual setup",
                isExpanded: $showingAdvancedSetup
            ) {
                Text("Most people should keep the recommended name. Change it only if you already use that name for another Shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Shortcut name", text: $shortcutName)
                Button("Create Another Blank Shortcut") {
                    shortcutBuilderStarted = true
                    guard let url = ShortcutPCCBridgePreferences.createShortcutURL else {
                        return
                    }
                    openURL(url)
                }
                Button("Open Custom Shortcut") {
                    openConfiguredShortcut()
                }
                .disabled(
                    ShortcutPCCBridgePreferences.openShortcutURL(named: shortcutName) == nil
                )
            }
        }
    }

    private var currentSetupState: ShortcutPCCBridgeSetupState {
        ShortcutPCCBridgePreferences.setupState(
            setupCompleted: setupCompleted,
            privacyAcknowledged: privacyAcknowledged,
            shortcutName: shortcutName
        )
    }

    private var privacyAcknowledgmentIsCurrent: Bool {
        privacyAcknowledged
            && privacyAcknowledgmentVersion
                == ShortcutPCCBridgePreferences.currentPrivacyAcknowledgmentVersion
    }

    private var hasPendingConnectionTest: Bool {
        UUID(uuidString: pendingTestRequestID) != nil
            && !pendingTestContextIdentifier.isEmpty
            && !pendingTestChallenge.isEmpty
            && !pendingTestShortcutName.isEmpty
            && pendingTestExpiration > 0
    }

    @available(iOS 26.0, macOS 26.0, *)
    @ViewBuilder
    private var setupStatusLabel: some View {
        switch currentSetupState {
        case .unsupportedOS:
            Label("AI connection unavailable", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .privacyAcknowledgmentRequired:
            Label("Setup required · Review privacy", systemImage: "1.circle.fill")
                .foregroundStyle(.primary)
        case .shortcutConfigurationRequired:
            Label("Setup required · Configure Shortcuts", systemImage: "2.circle.fill")
                .foregroundStyle(.primary)
        case .ready:
            Label("Keepsake AI Shortcut connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    @MainActor
    private func beginDescribedShortcutSetup() {
        shortcutName = ShortcutPCCBridgePreferences.defaultShortcutName
        shortcutBuilderStarted = true
        copyShortcutDescriptionPrompt()
        shortcutBuilderMessage = setupLocalized(
            "The setup prompt is copied. Paste it into Describe a Shortcut, then review all three generated actions."
        )
    }

    @MainActor
    private func beginRecommendedShortcutSetup() {
        shortcutName = ShortcutPCCBridgePreferences.defaultShortcutName
        shortcutBuilderStarted = true
        copyRecommendedShortcutName()
        shortcutBuilderMessage = setupLocalized(
            "The name is copied. Rename the blank Shortcut, then add the three actions below."
        )
        guard let url = ShortcutPCCBridgePreferences.createShortcutURL else {
            return
        }
        openURL(url)
    }

    @MainActor
    private func openConfiguredShortcut() {
        guard let url = ShortcutPCCBridgePreferences.openShortcutURL(
            named: shortcutName
        ) else { return }
        openURL(url)
    }

    @MainActor
    private func copyRecommendedShortcutName() {
        copyToPasteboard(ShortcutPCCBridgePreferences.defaultShortcutName)
    }

    @MainActor
    private func copyShortcutDescriptionPrompt() {
        let prompt = setupLocalized(
            "Create a shortcut named “Keepsake ChatGPT Connection” that accepts text as Shortcut Input. First add Keepsake’s Get Prepared AI Request action and set Request Code to Shortcut Input. Next add Use Model, use the prepared AI request as input, choose Extension Model (ChatGPT), turn Follow Up off, and choose Text output. Finally add Keepsake’s Return AI Result action, set Request Code to the original Shortcut Input, and set AI Result to the Use Model response. Do not add any other actions."
        )
        copyToPasteboard(prompt)
    }

    private func setupLocalized(_ key: String) -> String {
        let languageCode = locale.language.languageCode?.identifier
            ?? locale.identifier
        guard let path = Bundle.main.path(
            forResource: languageCode,
            ofType: "lproj"
        ), let languageBundle = Bundle(path: path) else {
            return key
        }
        return languageBundle.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }

    @MainActor
    private func copyToPasteboard(_ value: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = value
        #endif
    }

    @MainActor
    private func pollForCompletedConnectionTest() async {
        while !Task.isCancelled {
            guard hasPendingConnectionTest else { return }
            await checkForCompletedConnectionTest()
            guard hasPendingConnectionTest else { return }
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
        }
    }

    @MainActor
    private func disconnectAIShortcut() async {
        connectionTestAttemptID = nil
        isStartingConnectionTest = false
        if hasPendingConnectionTest {
            await cancelPendingConnectionTest()
        } else {
            clearPendingConnectionTestMetadata()
        }
        privacyAcknowledged = false
        privacyAcknowledgmentVersion = 0
        shortcutBuilderStarted = false
        shortcutName = ShortcutPCCBridgePreferences.defaultShortcutName
        invalidateVerifiedSetup()
        shortcutBuilderMessage = nil
        connectionTestMessage = nil
        connectionTestSucceeded = false
    }

    @MainActor
    private func startConnectionTest() async {
        guard !isStartingConnectionTest,
              !hasPendingConnectionTest,
              privacyAcknowledgmentIsCurrent,
              ShortcutPCCBridgePreferences.isShortcutNameValid(shortcutName),
              let store = ShortcutPCCBridgeRuntime.store else {
            connectionTestSucceeded = false
            connectionTestMessage = setupLocalized("The AI connection test could not start. Review the setup and try again.")
            return
        }

        let attemptID = UUID()
        connectionTestAttemptID = attemptID
        isStartingConnectionTest = true
        invalidateVerifiedSetup()
        connectionTestMessage = nil
        connectionTestSucceeded = false
        defer {
            if connectionTestAttemptID == attemptID {
                connectionTestAttemptID = nil
                isStartingConnectionTest = false
            }
        }

        await discardPendingConnectionTest(using: store)
        guard connectionTestAttemptID == attemptID,
              privacyAcknowledgmentIsCurrent else { return }

        let challenge = "KS-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).uppercased())"
        let contextIdentifier = ShortcutPCCBridgePreferences.setupTestContextPrefix
            + UUID().uuidString.lowercased()
        let modelInput = """
        This is a connection test from Keepsake. It contains no notebook or contact data.
        Reply with exactly this verification code and nothing else:
        \(challenge)
        """

        do {
            let prepared = try await store.prepare(
                modelInput: modelInput,
                contextIdentifier: contextIdentifier,
                sourcePolicy: .configuredShortcutEligible
            )
            guard connectionTestAttemptID == attemptID,
                  privacyAcknowledgmentIsCurrent else {
                try? await store.cancel(requestID: prepared.requestID)
                return
            }
            guard let runURL = ShortcutPCCBridgePreferences.runShortcutURL(
                named: shortcutName,
                requestCode: prepared.requestCode
            ) else {
                try? await store.cancel(requestID: prepared.requestID)
                throw ShortcutPCCBridgeIntentError.requestUnavailable
            }

            pendingTestRequestID = prepared.requestID.uuidString
            pendingTestContextIdentifier = contextIdentifier
            pendingTestChallenge = challenge
            pendingTestShortcutName = shortcutName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            pendingTestExpiration = prepared.expiresAt.timeIntervalSince1970
            connectionTestMessage = setupLocalized("Shortcuts opened with a non-personal connection test. Complete the three actions to return to Keepsake.")

            openURL(runURL) { accepted in
                guard !accepted else { return }
                Task { @MainActor in
                    await cancelPendingConnectionTest(
                        message: setupLocalized("Shortcuts could not be opened. Check the saved Shortcut name and try again.")
                    )
                }
            }
        } catch is CancellationError {
            await cancelPendingConnectionTest(
                message: setupLocalized("The AI connection test was canceled.")
            )
        } catch {
            await cancelPendingConnectionTest(
                message: setupLocalized("The AI connection test could not start. Review the setup and try again.")
            )
        }
    }

    @MainActor
    private func checkForCompletedConnectionTest() async {
        guard hasPendingConnectionTest,
              let requestID = UUID(uuidString: pendingTestRequestID),
              let store = ShortcutPCCBridgeRuntime.store else { return }

        if Date().timeIntervalSince1970 >= pendingTestExpiration {
            await cancelPendingConnectionTest(
                message: setupLocalized("The AI connection test expired. Start a new test and complete the Shortcut within ten minutes.")
            )
            return
        }

        let expectedContext = pendingTestContextIdentifier
        let expectedChallenge = pendingTestChallenge
        let expectedShortcutName = pendingTestShortcutName

        guard expectedContext.hasPrefix(
            ShortcutPCCBridgePreferences.setupTestContextPrefix
        ) else {
            await cancelPendingConnectionTest(
                message: setupLocalized("The saved connection test belongs to an earlier model setup. Start a new ChatGPT connection test.")
            )
            return
        }

        do {
            guard let result = try await store.takeCompletedResult(
                requestID: requestID
            ) else { return }

            guard pendingTestRequestID.caseInsensitiveCompare(
                requestID.uuidString
            ) == .orderedSame,
                  pendingTestContextIdentifier == expectedContext,
                  pendingTestChallenge == expectedChallenge,
                  pendingTestShortcutName == expectedShortcutName else {
                return
            }
            clearPendingConnectionTestMetadata()
            let currentName = shortcutName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard privacyAcknowledgmentIsCurrent,
                  currentName == expectedShortcutName,
                  result.contextIdentifier == expectedContext,
                  response(result.modelResponse, matches: expectedChallenge) else {
                invalidateVerifiedSetup()
                connectionTestSucceeded = false
                connectionTestMessage = setupLocalized("The Shortcut returned, but the protected test did not match. Verify every action and test again.")
                return
            }

            setupVerificationVersion =
                ShortcutPCCBridgePreferences.currentSetupVerificationVersion
            setupVerifiedAt = Date.now.timeIntervalSince1970
            setupCompleted = true
            connectionTestSucceeded = true
            connectionTestMessage = setupLocalized("Keepsake’s authenticated request/return transport returned the exact challenge. Use Model, Extension Model (ChatGPT), the ChatGPT account mode, and other Shortcut actions remain unverified.")
        } catch {
            clearPendingConnectionTestMetadata()
            invalidateVerifiedSetup()
            connectionTestSucceeded = false
            connectionTestMessage = setupLocalized("Keepsake could not validate the returned connection test. Start a new test.")
        }
    }

    @MainActor
    private func cancelPendingConnectionTest(message: String? = nil) async {
        connectionTestAttemptID = nil
        isStartingConnectionTest = false
        var cancellationConfirmed = true
        if let requestID = UUID(uuidString: pendingTestRequestID),
           let store = ShortcutPCCBridgeRuntime.store {
            do {
                try await store.cancel(requestID: requestID)
            } catch ShortcutModelHandoffError.requestNotFound {
                // A missing record is already unusable, so cancellation is complete.
            } catch {
                cancellationConfirmed = false
            }
        }
        clearPendingConnectionTestMetadata()
        invalidateVerifiedSetup()
        connectionTestSucceeded = false
        if let message {
            connectionTestMessage = message
        } else if cancellationConfirmed {
            connectionTestMessage = setupLocalized("The AI connection test was canceled.")
        } else {
            connectionTestMessage = setupLocalized("Keepsake could not confirm cancellation. Do not reuse the prior request code; it expires automatically within ten minutes.")
        }
    }

    @MainActor
    private func discardPendingConnectionTest(
        using store: ShortcutModelHandoffStore
    ) async {
        if let requestID = UUID(uuidString: pendingTestRequestID) {
            try? await store.cancel(requestID: requestID)
        }
        clearPendingConnectionTestMetadata()
    }

    @MainActor
    private func clearPendingConnectionTestMetadata() {
        pendingTestRequestID = ""
        pendingTestContextIdentifier = ""
        pendingTestChallenge = ""
        pendingTestShortcutName = ""
        pendingTestExpiration = 0
    }

    @MainActor
    private func invalidateVerifiedSetup() {
        setupCompleted = false
        setupVerificationVersion = 0
        setupVerifiedAt = 0
    }

    @MainActor
    private func migrateLegacyModelSetupIfNeeded() {
        if shortcutName == ShortcutPCCBridgePreferences.legacyDefaultShortcutName {
            shortcutName = ShortcutPCCBridgePreferences.defaultShortcutName
            shortcutBuilderStarted = false
            shortcutBuilderMessage = setupLocalized(
                "The required model changed to ChatGPT. Build the newly named Shortcut and complete a new connection test."
            )
        }
        if setupVerificationVersion
            != ShortcutPCCBridgePreferences.currentSetupVerificationVersion {
            invalidateVerifiedSetup()
        }
        if privacyAcknowledgmentVersion
            != ShortcutPCCBridgePreferences.currentPrivacyAcknowledgmentVersion {
            privacyAcknowledged = false
            privacyAcknowledgmentVersion = 0
        }
    }

    private func response(_ response: String, matches challenge: String) -> Bool {
        return response
            .trimmingCharacters(in: .whitespacesAndNewlines) == challenge
    }

    private func setupStep(
        _ number: Int,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(.tint.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("Step \(number): ") + Text(title) + Text(verbatim: ". ") + Text(detail)
        )
    }
}
