import Foundation

public enum CommunicationChannelID: String, Codable, CaseIterable, Sendable {
    case email
    case messages
    case phone
    case line
    case instagram
    case whatsapp
    case snapchat

    /// Messages intentionally does not promise iMessage, SMS, or RCS because
    /// the Apple Messages experience chooses the actual transport.
    public var userFacingName: String {
        switch self {
        case .email: String(localized: "Email")
        case .messages: String(localized: "Messages")
        case .phone: String(localized: "Phone")
        case .line: String(localized: "LINE")
        case .instagram: String(localized: "Instagram")
        case .whatsapp: String(localized: "WhatsApp")
        case .snapchat: String(localized: "Snapchat")
        }
    }
}

public struct CommunicationChannelCapabilities: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let canPrefillRecipient = Self(rawValue: 1 << 0)
    public static let canPrefillText = Self(rawValue: 1 << 1)
    public static let canReportComposerResult = Self(rawValue: 1 << 2)
    public static let canImportUserExport = Self(rawValue: 1 << 3)
    public static let usesSystemComposer = Self(rawValue: 1 << 4)
    public static let usesExternalDestination = Self(rawValue: 1 << 5)
    public static let canProvideAPIAcceptance = Self(rawValue: 1 << 6)
    public static let canProvideDeliveryEvidence = Self(rawValue: 1 << 7)
    public static let canProvideReadEvidence = Self(rawValue: 1 << 8)
    public static let canReturnExactFinalContent = Self(rawValue: 1 << 9)
}

public struct CommunicationChannelAvailability: Hashable, Codable, Sendable {
    public var channel: CommunicationChannelID
    public var isDestinationAvailable: Bool
    public var capabilities: CommunicationChannelCapabilities

    public init(
        channel: CommunicationChannelID,
        isDestinationAvailable: Bool,
        capabilities: CommunicationChannelCapabilities
    ) {
        self.channel = channel
        self.isDestinationAvailable = isDestinationAvailable
        self.capabilities = capabilities
    }
}

public struct CommunicationRecipient: Hashable, Codable, Sendable {
    public var channel: CommunicationChannelID
    public var value: String

    public init(channel: CommunicationChannelID, value: String) {
        self.channel = channel
        self.value = value
    }
}

public struct EditableCommunicationDraft: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var subject: String?
    public var body: String

    public init(id: UUID = UUID(), subject: String? = nil, body: String) {
        self.id = id
        self.subject = subject
        self.body = body
    }
}

public enum CommunicationHandoffStrategy: String, Codable, Sendable {
    case systemComposer
    case externalDestination
    case systemShareSheet
}

public enum CommunicationPostReturnAction: String, Codable, Sendable {
    case askUserWhatHappened
}

public struct PreparedCommunicationHandoff: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var channel: CommunicationChannelID
    public var strategy: CommunicationHandoffStrategy
    public var recipientForPrefill: String?
    public var subjectForPrefill: String?
    public var bodyForPrefill: String?
    public var originalDraftID: UUID
    public var requiresExplicitUserSend: Bool
    public var postReturnAction: CommunicationPostReturnAction
    public var initialContentFidelity: CommunicationContentFidelity

    public init(
        id: UUID = UUID(),
        channel: CommunicationChannelID,
        strategy: CommunicationHandoffStrategy,
        recipientForPrefill: String?,
        subjectForPrefill: String?,
        bodyForPrefill: String?,
        originalDraftID: UUID,
        requiresExplicitUserSend: Bool = true,
        postReturnAction: CommunicationPostReturnAction = .askUserWhatHappened,
        initialContentFidelity: CommunicationContentFidelity = .draftKnown
    ) {
        self.id = id
        self.channel = channel
        self.strategy = strategy
        self.recipientForPrefill = recipientForPrefill
        self.subjectForPrefill = subjectForPrefill
        self.bodyForPrefill = bodyForPrefill
        self.originalDraftID = originalDraftID
        self.requiresExplicitUserSend = requiresExplicitUserSend
        self.postReturnAction = postReturnAction
        self.initialContentFidelity = initialContentFidelity
    }
}

public enum CommunicationHandoffUnavailableReason: String, Codable, Sendable {
    case channelMismatch
    case destinationUnavailable
    case invalidRecipient
    case emptyDraft
    case draftTooLarge
    case noSafeHandoffCapability
}

public enum CommunicationHandoffPlanningResult: Hashable, Codable, Sendable {
    case ready(PreparedCommunicationHandoff)
    case unavailable(CommunicationHandoffUnavailableReason)
}

/// Produces a plan only. It never opens a URL, invokes an application, or sends
/// a message, which keeps capability checks separate from side effects.
public struct CommunicationHandoffPlanner: Sendable {
    public var maximumDraftCharacters: Int

    public init(maximumDraftCharacters: Int = 20_000) {
        self.maximumDraftCharacters = maximumDraftCharacters
    }

    public func plan(
        recipient: CommunicationRecipient,
        draft: EditableCommunicationDraft,
        availability: CommunicationChannelAvailability
    ) -> CommunicationHandoffPlanningResult {
        guard recipient.channel == availability.channel else {
            return .unavailable(.channelMismatch)
        }
        guard availability.isDestinationAvailable else {
            return .unavailable(.destinationUnavailable)
        }
        guard validRecipient(recipient) else {
            return .unavailable(.invalidRecipient)
        }
        guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(.emptyDraft)
        }
        guard draft.body.count <= maximumDraftCharacters,
              (draft.subject?.count ?? 0) <= maximumDraftCharacters else {
            return .unavailable(.draftTooLarge)
        }

        let capabilities = availability.capabilities
        let strategy: CommunicationHandoffStrategy
        if capabilities.contains(.usesSystemComposer) {
            strategy = .systemComposer
        } else if capabilities.contains(.usesExternalDestination) {
            strategy = .externalDestination
        } else if capabilities.contains(.canPrefillText) {
            strategy = .systemShareSheet
        } else {
            return .unavailable(.noSafeHandoffCapability)
        }

        return .ready(PreparedCommunicationHandoff(
            channel: availability.channel,
            strategy: strategy,
            recipientForPrefill: capabilities.contains(.canPrefillRecipient) ? recipient.value : nil,
            subjectForPrefill: capabilities.contains(.canPrefillText) ? draft.subject : nil,
            bodyForPrefill: capabilities.contains(.canPrefillText) ? draft.body : nil,
            originalDraftID: draft.id
        ))
    }

    private func validRecipient(_ recipient: CommunicationRecipient) -> Bool {
        let value = recipient.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }

        switch recipient.channel {
        case .email:
            return value.range(
                of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        case .messages, .phone, .whatsapp:
            let digits = value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            return digits.count >= 5 || value.contains("@")
        case .line, .instagram, .snapchat:
            return !value.contains(where: { $0.isWhitespace })
        }
    }
}

public enum CommunicationEvidenceState: String, Codable, CaseIterable, Sendable {
    case suggested
    case composerOpened = "composer_opened"
    case composerReportedSent = "composer_reported_sent"
    case userConfirmedSent = "user_confirmed_sent"
    case apiAccepted = "api_accepted"
    case delivered
    case read
    case composerCancelled = "composer_cancelled"
    case composerFailed = "composer_failed"

    public var localizedTitle: String {
        switch self {
        case .suggested: String(localized: "Suggestion shown")
        case .composerOpened: String(localized: "Destination opened")
        case .composerReportedSent: String(localized: "Composer reported sent")
        case .userConfirmedSent: String(localized: "User confirmed contact")
        case .apiAccepted: String(localized: "Provider accepted")
        case .delivered: String(localized: "Delivered")
        case .read: String(localized: "Read")
        case .composerCancelled: String(localized: "Composer canceled")
        case .composerFailed: String(localized: "Composer failed")
        }
    }
}

public enum CommunicationEvidenceKind: String, Codable, Sendable {
    case applicationObservation = "application_observation"
    case systemComposerResult = "system_composer_result"
    case userConfirmation = "user_confirmation"
    case providerAPI = "provider_api"
}

public struct CommunicationEvidenceEvent: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var state: CommunicationEvidenceState
    public var occurredAt: Date
    public var evidenceKind: CommunicationEvidenceKind

    public init(
        id: UUID = UUID(),
        state: CommunicationEvidenceState,
        occurredAt: Date = .now,
        evidenceKind: CommunicationEvidenceKind
    ) {
        self.id = id
        self.state = state
        self.occurredAt = occurredAt
        self.evidenceKind = evidenceKind
    }
}

public enum CommunicationContentFidelity: String, Codable, CaseIterable, Sendable {
    case draftKnown = "draft_known"
    case finalContentUnknown = "final_content_unknown"
    case summaryOnly = "summary_only"
    case exactFromUserImport = "exact_from_user_import"
    case exactFromAPI = "exact_from_api"

    public var localizedTitle: String {
        switch self {
        case .draftKnown: String(localized: "Draft known; final content not established")
        case .finalContentUnknown: String(localized: "Final content unknown")
        case .summaryOnly: String(localized: "Summary only")
        case .exactFromUserImport: String(localized: "Exact content from user import")
        case .exactFromAPI: String(localized: "Exact content from provider API")
        }
    }
}

public enum CommunicationContentEvidenceKind: String, Codable, Sendable {
    case externalHandoff
    case userApprovedSummary
    case explicitUserImport
    case providerAPI
}

public enum CommunicationEvidenceTransitionError: LocalizedError, Equatable, Sendable {
    case duplicateEventIdentifier
    case nonChronologicalEvent
    case wrongEvidenceKind
    case prerequisiteMissing
    case capabilityNotAvailable
    case composerAlreadyClosed
    case invalidContentTransition

    public var errorDescription: String? {
        switch self {
        case .duplicateEventIdentifier:
            String(localized: "The evidence identifier was already used for a different event.")
        case .nonChronologicalEvent:
            String(localized: "Evidence cannot be inserted before the latest known event.")
        case .wrongEvidenceKind:
            String(localized: "That state is not supported by the supplied evidence.")
        case .prerequisiteMissing:
            String(localized: "The preceding evidence state is missing.")
        case .capabilityNotAvailable:
            String(localized: "This channel cannot prove that state.")
        case .composerAlreadyClosed:
            String(localized: "The composer was already cancelled or failed.")
        case .invalidContentTransition:
            String(localized: "The content evidence would overstate what is known.")
        }
    }
}

/// Append-only, value-semantic evidence ledger. A caller must supply the
/// capability snapshot that was active for the handoff, so later UI changes
/// cannot retroactively upgrade an unproven state.
public struct CommunicationEvidenceLedger: Hashable, Codable, Sendable {
    public var channel: CommunicationChannelID
    public var capabilities: CommunicationChannelCapabilities
    public private(set) var events: [CommunicationEvidenceEvent]
    public private(set) var contentFidelity: CommunicationContentFidelity

    public init(
        channel: CommunicationChannelID,
        capabilities: CommunicationChannelCapabilities,
        suggestedAt: Date = .now
    ) {
        self.channel = channel
        self.capabilities = capabilities
        self.events = [CommunicationEvidenceEvent(
            state: .suggested,
            occurredAt: suggestedAt,
            evidenceKind: .applicationObservation
        )]
        self.contentFidelity = .draftKnown
    }

    public var knownStates: Set<CommunicationEvidenceState> {
        Set(events.map(\.state))
    }

    public var canClaimSent: Bool {
        knownStates.contains(.composerReportedSent) || knownStates.contains(.userConfirmedSent)
    }

    public var canClaimDelivered: Bool { knownStates.contains(.delivered) }
    public var canClaimRead: Bool { knownStates.contains(.read) }

    /// A legacy status projection for list filtering. The append-only event
    /// ledger remains authoritative and retains the distinctions hidden by the
    /// older status column.
    public var projectedInteractionStatus: InteractionStatus {
        let states = knownStates
        if states.contains(.read) { return .read }
        if states.contains(.delivered) { return .delivered }
        if states.contains(.apiAccepted) { return .apiAccepted }
        if states.contains(.userConfirmedSent) { return .userConfirmedSent }
        if states.contains(.composerReportedSent) { return .composerReportedSent }
        if states.contains(.composerFailed) { return .failed }
        if states.contains(.composerCancelled) { return .cancelled }
        if states.contains(.composerOpened) { return .composerOpened }
        return .suggested
    }

    public func applying(_ event: CommunicationEvidenceEvent) throws -> Self {
        if let existing = events.first(where: { $0.id == event.id }) {
            guard existing == event else {
                throw CommunicationEvidenceTransitionError.duplicateEventIdentifier
            }
            return self
        }
        if knownStates.contains(event.state) { return self }
        guard let last = events.last, event.occurredAt >= last.occurredAt else {
            throw CommunicationEvidenceTransitionError.nonChronologicalEvent
        }

        try validateEvidenceKind(event)
        try validatePrerequisites(event.state)

        var copy = self
        copy.events.append(event)
        // The user can edit text after any composer/external destination opens.
        // Until exact final content is explicitly imported, the draft cannot be
        // displayed as though it were the sent text.
        if event.state == .composerOpened, copy.contentFidelity == .draftKnown {
            copy.contentFidelity = .finalContentUnknown
        }
        return copy
    }

    public func recordingContent(
        _ fidelity: CommunicationContentFidelity,
        evidenceKind: CommunicationContentEvidenceKind
    ) throws -> Self {
        let valid: Bool = switch (fidelity, evidenceKind) {
        case (.finalContentUnknown, .externalHandoff),
             (.summaryOnly, .userApprovedSummary),
             (.exactFromUserImport, .explicitUserImport):
            true
        case (.exactFromAPI, .providerAPI):
            capabilities.contains(.canReturnExactFinalContent)
        case (.draftKnown, _):
            false
        default:
            false
        }
        guard valid else { throw CommunicationEvidenceTransitionError.invalidContentTransition }

        // Exact user/provider evidence must never be downgraded to a draft,
        // unknown text, or an AI/user summary.
        if contentFidelity == .exactFromUserImport || contentFidelity == .exactFromAPI {
            guard fidelity == contentFidelity else {
                throw CommunicationEvidenceTransitionError.invalidContentTransition
            }
            return self
        }

        var copy = self
        copy.contentFidelity = fidelity
        return copy
    }

    private func validateEvidenceKind(_ event: CommunicationEvidenceEvent) throws {
        let expected: CommunicationEvidenceKind = switch event.state {
        case .suggested, .composerOpened, .composerFailed:
            .applicationObservation
        case .composerReportedSent, .composerCancelled:
            .systemComposerResult
        case .userConfirmedSent:
            .userConfirmation
        case .apiAccepted, .delivered, .read:
            .providerAPI
        }
        guard event.evidenceKind == expected else {
            throw CommunicationEvidenceTransitionError.wrongEvidenceKind
        }
    }

    private func validatePrerequisites(_ state: CommunicationEvidenceState) throws {
        let states = knownStates
        switch state {
        case .suggested:
            return
        case .composerOpened:
            guard states.contains(.suggested) else {
                throw CommunicationEvidenceTransitionError.prerequisiteMissing
            }
        case .composerReportedSent:
            guard capabilities.contains(.canReportComposerResult) else {
                throw CommunicationEvidenceTransitionError.capabilityNotAvailable
            }
            guard states.contains(.composerOpened) else {
                throw CommunicationEvidenceTransitionError.prerequisiteMissing
            }
            guard !states.contains(.composerCancelled), !states.contains(.composerFailed) else {
                throw CommunicationEvidenceTransitionError.composerAlreadyClosed
            }
        case .composerCancelled, .composerFailed:
            guard states.contains(.composerOpened) else {
                throw CommunicationEvidenceTransitionError.prerequisiteMissing
            }
            guard !states.contains(.composerReportedSent) else {
                throw CommunicationEvidenceTransitionError.composerAlreadyClosed
            }
        case .userConfirmedSent:
            // A user can truthfully confirm contact performed in a different
            // app even when a system composer could not report a result.
            guard states.contains(.suggested) else {
                throw CommunicationEvidenceTransitionError.prerequisiteMissing
            }
        case .apiAccepted:
            guard capabilities.contains(.canProvideAPIAcceptance) else {
                throw CommunicationEvidenceTransitionError.capabilityNotAvailable
            }
        case .delivered:
            guard capabilities.contains(.canProvideDeliveryEvidence) else {
                throw CommunicationEvidenceTransitionError.capabilityNotAvailable
            }
            guard states.contains(.apiAccepted) else {
                throw CommunicationEvidenceTransitionError.prerequisiteMissing
            }
        case .read:
            guard capabilities.contains(.canProvideReadEvidence) else {
                throw CommunicationEvidenceTransitionError.capabilityNotAvailable
            }
            guard states.contains(.delivered) else {
                throw CommunicationEvidenceTransitionError.prerequisiteMissing
            }
        }
    }
}
