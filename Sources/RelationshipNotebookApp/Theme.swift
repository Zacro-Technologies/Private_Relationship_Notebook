import Foundation
import SwiftUI

/// Stable keys shared by Settings and feature-specific editors. Keeping them
/// together prevents a renamed UI property from silently creating a second,
/// conflicting default.
enum KeepsakePreferenceKey {
    static let onboardingComplete = "onboardingComplete"
    static let appLanguage = "appLanguage"
    static let syncEnabled = "syncEnabled"
    static let appLockEnabled = "appLockEnabled"
    static let defaultImportedSourceRetention = "defaultImportedSourceRetention"
    static let defaultImportedTranscriptRetention = "defaultImportedTranscriptRetention"
    static let nameDisplayOrder = "personNameDisplayOrder"
}

/// UserDefaults contains both durable app preferences and short-lived vault
/// routing state. A vault deletion clears only values that can name deleted
/// records; language, App Lock, AI setup, and other app preferences remain.
enum VaultScopedTransientState {
    private static let directKeys = [
        "shortcutPCCBridgePendingTodayRequestID",
        "shortcutPCCBridgePendingTodayContextIdentifier",
        "shortcutPCCBridgePendingTodayPersonID",
        "shortcutPCCBridgePendingTodayExpiration",
        "shortcutPCCBridgePendingContactRequestID",
        "shortcutPCCBridgePendingContactContextIdentifier",
        "shortcutPCCBridgePendingContactPersonID",
        "shortcutPCCBridgePendingContactExpiration"
    ]

    private static let scopedPrefixes = [
        "nudgeSuggestionHistory.v1",
        "nudgeSuggestionHistory.v2.",
        "nudgePoolSelection.v1.",
        "nudgeNotificationPlanningState.v1."
    ]

    /// Returns protected Shortcut handoff IDs so their payload records can be
    /// canceled before the opaque correlation metadata is removed.
    @discardableResult
    static func clear(defaults: UserDefaults = .standard) -> [UUID] {
        let requestKeys = [
            "shortcutPCCBridgePendingTodayRequestID",
            "shortcutPCCBridgePendingContactRequestID"
        ]
        let requestIDs = requestKeys.compactMap {
            defaults.string(forKey: $0).flatMap(UUID.init(uuidString:))
        }

        let allKeys = defaults.dictionaryRepresentation().keys
        let scopedKeys = allKeys.filter { key in
            scopedPrefixes.contains { key.hasPrefix($0) }
        }
        for key in Set(directKeys + scopedKeys) {
            defaults.removeObject(forKey: key)
        }
        return requestIDs
    }
}

enum AppTheme {
    /// High-contrast brand foreground and control tint. Its dark appearance is
    /// intentionally much lighter than the light-appearance green.
    static let accent = Color("KeepsakeAccentText")
    static let actionFill = Color("KeepsakeActionFill")
    static let pageBackground = Color("KeepsakePageBackground")
    static let cardBackground = Color("KeepsakeCardBackground")
    static let warmSurface = Color("KeepsakeWarmSurface")
    static let accentSurface = Color("KeepsakeAccentSurface")
    static let secondaryText = Color("KeepsakeSecondaryText")
    static let tertiaryText = Color("KeepsakeTertiaryText")
    static let border = Color("KeepsakeBorder")

    // Fixed paper colors are reserved for intentionally light artwork. Runtime
    // content, including onboarding and App Lock, uses adaptive semantic roles.
    static let paperAccent = Color(red: 0.20, green: 0.43, blue: 0.38)
    static let paperMint = Color(red: 0.77, green: 0.89, blue: 0.84)
    static let paperCream = Color(red: 0.97, green: 0.95, blue: 0.90)
    static let ink = Color(red: 0.13, green: 0.18, blue: 0.17)
}

struct PersonAvatar: View {
    let person: Person
    var size: CGFloat = 46

    var body: some View {
        PersonPortrait(person: person, size: size)
    }
}

struct PersonAvatarPlaceholder: View {
    let person: Person
    var size: CGFloat = 46

    private var initials: String {
        let words = person.displayName.split(separator: " ")
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var hue: Double {
        let stableHash = person.id.uuidString.utf8.reduce(UInt64(1_469_598_103_934_665_603)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return Double(stableHash % 360) / 360
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(hue: hue, saturation: 0.28, brightness: 0.92).gradient)
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.32, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.ink.opacity(0.8))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Portrait placeholder for \(person.displayName)")
    }
}

struct ContextChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(AppTheme.accentSurface, in: Capsule())
    }
}

struct NotebookCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.10), radius: 16, y: 7)
    }
}

struct EmptyNotebookView: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actionTitle: LocalizedStringKey?
    let action: (() -> Void)?

    init(
        icon: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.actionFill)
            }
        }
    }
}

extension View {
    /// Keeps desktop editor sheets roomy without imposing a desktop width on
    /// compact iPhone presentations.
    @ViewBuilder
    func keepsakeSheetSize(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight)
        #else
        presentationDetents([.large])
        #endif
    }

    /// Warning copy must remain legible in light, dark, and Increase Contrast
    /// appearances. Color is reinforcement rather than the only warning cue.
    func keepsakeWarningStyle() -> some View {
        padding(10)
            .foregroundStyle(.primary)
            .background(AppTheme.warmSurface, in: RoundedRectangle(cornerRadius: 10))
    }
}
