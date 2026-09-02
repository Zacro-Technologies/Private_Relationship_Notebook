import LocalAuthentication
import SwiftUI

@MainActor
final class AppLockController: ObservableObject {
    private static let enabledPreferenceKey = KeepsakePreferenceKey.appLockEnabled

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published var errorMessage: String?
    @Published var setupErrorMessage: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let isEnabled = defaults.bool(forKey: Self.enabledPreferenceKey)
        self.isEnabled = isEnabled
        self.isLocked = isEnabled
    }

    /// Enables App Lock only after this device proves that its owner-
    /// authentication policy is both available and usable. Until that full
    /// transaction succeeds, the stored preference remains off.
    @discardableResult
    func enable() async -> Bool {
        guard !isEnabled else { return true }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        setupErrorMessage = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel", locale: configuredLocale)
        var authError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &authError
        ) else {
            setupErrorMessage = setupFailureMessage(for: authError)
            return false
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(
                    localized: "Confirm your identity before enabling App Lock",
                    locale: configuredLocale
                )
            )
            guard success else {
                setupErrorMessage = setupFailureMessage(for: nil)
                return false
            }

            defaults.set(true, forKey: Self.enabledPreferenceKey)
            isEnabled = true
            // The setup authentication just proved device ownership. Lock on
            // the next background transition rather than hiding onboarding or
            // Settings behind a second, immediate prompt.
            isLocked = false
            return true
        } catch {
            setupErrorMessage = setupFailureMessage(for: error)
            return false
        }
    }

    func disable() {
        defaults.set(false, forKey: Self.enabledPreferenceKey)
        isEnabled = false
        isLocked = false
        setupErrorMessage = nil
    }

    func lockIfNeeded() {
        if isEnabled { isLocked = true }
    }

    func authenticate() async {
        guard isEnabled else { isLocked = false; return }
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = String(
            localized: "Keep Locked",
            locale: configuredLocale
        )
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            errorMessage = unlockFailureMessage(for: authError)
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(
                    localized: "Unlock your private relationship notebook",
                    locale: configuredLocale
                )
            )
            if success {
                withAnimation { isLocked = false }
            } else {
                errorMessage = unlockFailureMessage(for: nil)
            }
        } catch {
            errorMessage = unlockFailureMessage(for: error)
        }
    }

    private func setupFailureMessage(for error: Error?) -> String {
        authenticationFailureMessage(
            outcome: String(
                localized: "App Lock was not enabled.",
                locale: configuredLocale
            ),
            error: error
        )
    }

    private func unlockFailureMessage(for error: Error?) -> String {
        authenticationFailureMessage(
            outcome: String(
                localized: "Keepsake remains locked.",
                locale: configuredLocale
            ),
            error: error
        )
    }

    private func authenticationFailureMessage(
        outcome: String,
        error: Error?
    ) -> String {
        var paragraphs = [outcome]
        if let reason = authenticationFailureReason(error) {
            paragraphs.append(reason)
        }
        paragraphs.append(String(
            localized: "Open System Settings and make sure a device passcode or password, and Face ID or Touch ID where available, are set up, then try again.",
            locale: configuredLocale
        ))
        return paragraphs.joined(separator: "\n\n")
    }

    private func authenticationFailureReason(_ error: Error?) -> String? {
        guard let error else {
            return String(
                localized: "Device authentication did not succeed.",
                locale: configuredLocale
            )
        }
        let cocoaError = error as NSError
        if let failureReason = cocoaError.localizedFailureReason,
           !failureReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return failureReason
        }
        let description = cocoaError.localizedDescription
        return description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : description
    }

    private var configuredLocale: Locale {
        guard let identifier = defaults.string(forKey: KeepsakePreferenceKey.appLanguage),
              !identifier.isEmpty else { return .current }
        return Locale(identifier: identifier)
    }
}

struct AppLockView: View {
    @EnvironmentObject private var lock: AppLockController

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.pageBackground,
                    AppTheme.accentSurface,
                    AppTheme.warmSurface
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityHidden(true)
                    Text("Keepsake is locked")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                    Text("Authenticate with this device to reveal your private notebook.")
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await lock.authenticate() }
                    } label: {
                        if lock.isAuthenticating { ProgressView().controlSize(.small) }
                        else { Label("Unlock", systemImage: "faceid") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.actionFill)
                    .controlSize(.large)
                    .disabled(lock.isAuthenticating)
                }
                .padding(32)
                .frame(maxWidth: 520)
                .background(
                    AppTheme.cardBackground,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 420)
            }
        }
        .accessibilityAddTraits(.isModal)
        .alert("Unable to unlock", isPresented: Binding(
            get: { lock.errorMessage != nil },
            set: { if !$0 { lock.errorMessage = nil } }
        )) {
            Button("OK") { lock.errorMessage = nil }
        } message: { Text(lock.errorMessage ?? "") }
    }
}

struct PrivacyCurtain: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                Image(systemName: "eye.slash.fill").font(.largeTitle).foregroundStyle(AppTheme.accent)
                Text("Private notebook hidden").font(.headline)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
