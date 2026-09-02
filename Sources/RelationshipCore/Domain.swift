import Foundation

public enum RelationshipCircle: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case close = "Close"
    case friends = "Friends"
    case community = "Community"
    case acquaintance = "Acquaintance"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .close: String(localized: "Close")
        case .friends: String(localized: "Friends")
        case .community: String(localized: "Community")
        case .acquaintance: String(localized: "Acquaintance")
        }
    }
}

public enum ContactKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case email = "Email"
    case messages = "Messages"
    case phone = "Phone"
    case line = "LINE"
    case instagram = "Instagram"
    case whatsapp = "WhatsApp"
    case snapchat = "Snapchat"

    public var id: String { rawValue }

    public var localizedTitle: String { localizedTitle(locale: .current) }

    public func localizedTitle(locale: Locale) -> String {
        switch self {
        case .email: String(localized: "Email", locale: locale)
        case .messages: String(localized: "Messages", locale: locale)
        case .phone: String(localized: "Phone", locale: locale)
        case .line: String(localized: "LINE", locale: locale)
        case .instagram: String(localized: "Instagram", locale: locale)
        case .whatsapp: String(localized: "WhatsApp", locale: locale)
        case .snapchat: String(localized: "Snapchat", locale: locale)
        }
    }
}

public struct ContactMethod: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: ContactKind
    public var value: String
    public var isPreferred: Bool
    /// Optional for decode compatibility with contact methods saved before
    /// avoided-channel preferences were introduced.
    public var isAvoided: Bool?

    public init(
        id: UUID = UUID(),
        kind: ContactKind,
        value: String,
        isPreferred: Bool = true,
        isAvoided: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.isPreferred = isPreferred
        self.isAvoided = isAvoided
    }

    public var avoided: Bool { isAvoided == true }
}

public enum PersonNameVariantKind: String, Codable, CaseIterable, Hashable, Sendable {
    case originalScript
    case kana
    case romanization
    case alternate
    case historical
}

public enum PersonNameDisplayOrder: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case asEntered
    case givenFamily
    case familyGiven

    public var id: String { rawValue }

    public var localizedTitle: String { localizedTitle(locale: .current) }

    public func localizedTitle(locale: Locale) -> String {
        switch self {
        case .asEntered: String(localized: "As entered", locale: locale)
        case .givenFamily: String(localized: "Given name, family name", locale: locale)
        case .familyGiven: String(localized: "Family name, given name", locale: locale)
        }
    }
}

/// A typed, locale-aware name representation. `fullName` preserves exactly
/// what the user entered, while optional components permit an explicit display
/// order without trying to infer Japanese or Western name structure.
public struct PersonNameVariant: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var fullName: String
    public var givenName: String?
    public var familyName: String?
    public var kind: PersonNameVariantKind
    public var languageCode: String?
    public var scriptCode: String?
    public var isPreferred: Bool
    public var validFrom: PartialDate?
    public var validThrough: PartialDate?

    public init(
        id: UUID = UUID(),
        fullName: String,
        givenName: String? = nil,
        familyName: String? = nil,
        kind: PersonNameVariantKind = .alternate,
        languageCode: String? = nil,
        scriptCode: String? = nil,
        isPreferred: Bool = false,
        validFrom: PartialDate? = nil,
        validThrough: PartialDate? = nil
    ) {
        self.id = id
        self.fullName = fullName
        self.givenName = givenName
        self.familyName = familyName
        self.kind = kind
        self.languageCode = languageCode
        self.scriptCode = scriptCode
        self.isPreferred = isPreferred
        self.validFrom = validFrom
        self.validThrough = validThrough
    }

    public func formatted(order: PersonNameDisplayOrder) -> String {
        let given = givenName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let family = familyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch order {
        case .asEntered:
            return fullName
        case .givenFamily where !given.isEmpty || !family.isEmpty:
            return [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        case .familyGiven where !given.isEmpty || !family.isEmpty:
            return [family, given].filter { !$0.isEmpty }.joined(separator: " ")
        default:
            return fullName
        }
    }
}

public struct Person: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var pronunciation: String
    public var aliases: [String]
    public var contexts: [String]
    public var role: String
    public var tags: [String]
    public var privateNote: String
    public var mentionableContext: String
    public var circle: RelationshipCircle
    public var contacts: [ContactMethod]
    /// Optional, encrypted relationship preferences. An IANA identifier keeps
    /// recipient-local timing deterministic without persisting a location.
    public var recipientTimeZoneIdentifier: String?
    public var communicationPreferences: String?
    /// Device Contacts identifiers are opaque and may not resolve after a
    /// device/account change; the UI treats that as an explicit relink state.
    public var linkedContactIdentifier: String?
    public var cadenceDays: Int
    public var priority: Int
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastInteractionAt: Date?
    public var snoozedUntil: Date?
    public var isArchived: Bool
    public var neverSuggest: Bool
    public var doNotContact: Bool
    public var deletedAt: Date?
    public var mergedIntoPersonID: UUID?
    /// Optional for backward-compatible decoding of pre-variant archives.
    public var nameVariants: [PersonNameVariant]?
    /// Optional for backward-compatible decoding. At most one active person is
    /// allowed to carry this flag by `NotebookStore.save`.
    public var isSelfIdentity: Bool?
    /// Shared marker for seeded example records, enabling clear badges and
    /// one-action cleanup without relying on names.
    public var sampleDataSetID: UUID?

    public init(
        id: UUID = UUID(),
        displayName: String,
        pronunciation: String = "",
        aliases: [String] = [],
        contexts: [String] = [],
        role: String = "",
        tags: [String] = [],
        privateNote: String = "",
        mentionableContext: String = "",
        circle: RelationshipCircle = .acquaintance,
        contacts: [ContactMethod] = [],
        recipientTimeZoneIdentifier: String? = nil,
        communicationPreferences: String? = nil,
        linkedContactIdentifier: String? = nil,
        cadenceDays: Int = 90,
        priority: Int = 2,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        lastInteractionAt: Date? = nil,
        snoozedUntil: Date? = nil,
        isArchived: Bool = false,
        neverSuggest: Bool = false,
        doNotContact: Bool = false,
        deletedAt: Date? = nil,
        mergedIntoPersonID: UUID? = nil,
        nameVariants: [PersonNameVariant]? = nil,
        isSelf: Bool = false,
        sampleDataSetID: UUID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.pronunciation = pronunciation
        self.aliases = aliases
        self.contexts = contexts
        self.role = role
        self.tags = tags
        self.privateNote = privateNote
        self.mentionableContext = mentionableContext
        self.circle = circle
        self.contacts = contacts
        self.recipientTimeZoneIdentifier = recipientTimeZoneIdentifier
        self.communicationPreferences = communicationPreferences
        self.linkedContactIdentifier = linkedContactIdentifier
        self.cadenceDays = cadenceDays
        self.priority = priority
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastInteractionAt = lastInteractionAt
        self.snoozedUntil = snoozedUntil
        self.isArchived = isArchived
        self.neverSuggest = neverSuggest
        self.doNotContact = doNotContact
        self.deletedAt = deletedAt
        self.mergedIntoPersonID = mergedIntoPersonID
        self.nameVariants = nameVariants
        self.isSelfIdentity = isSelf
        self.sampleDataSetID = sampleDataSetID
    }

    public var isSelf: Bool { isSelfIdentity == true }
    public var isSample: Bool { sampleDataSetID != nil }

    public func resolvedDisplayName(order: PersonNameDisplayOrder = .asEntered) -> String {
        let active = (nameVariants ?? []).filter { variant in
            let now = Date.now
            let begins = variant.validFrom.map { $0.earliestInstant <= now } ?? true
            let ends = variant.validThrough.map { now <= $0.latestInstant } ?? true
            return begins && ends
        }
        return (active.first(where: \.isPreferred) ?? active.first)?.formatted(order: order)
            ?? displayName
    }

    /// Normalizes user-entered list and contact fields before ordinary saves.
    /// The first spelling/order wins so visual identity remains stable, while
    /// duplicate chips and ambiguous multiple preferred routes cannot persist.
    public func normalizedForPersistence() -> Self {
        var copy = self
        copy.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.aliases = Self.stableUniqueText(aliases)
        copy.contexts = Self.stableUniqueText(contexts)
        copy.tags = Self.stableUniqueText(tags)
        copy.recipientTimeZoneIdentifier = Self.trimmedOptional(recipientTimeZoneIdentifier)
        if let identifier = copy.recipientTimeZoneIdentifier,
           TimeZone(identifier: identifier) == nil {
            copy.recipientTimeZoneIdentifier = nil
        }
        copy.communicationPreferences = Self.trimmedOptional(communicationPreferences)
        copy.linkedContactIdentifier = Self.trimmedOptional(linkedContactIdentifier)

        var seenNames = Set<String>()
        var retainedPreferredName = false
        copy.nameVariants = (nameVariants ?? []).compactMap { original in
            var variant = original
            variant.fullName = variant.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            variant.givenName = variant.givenName?.trimmingCharacters(in: .whitespacesAndNewlines)
            variant.familyName = variant.familyName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !variant.fullName.isEmpty else { return nil }
            let key = [
                variant.kind.rawValue,
                variant.languageCode ?? "",
                variant.scriptCode ?? "",
                variant.fullName
            ].map { $0.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ) }.joined(separator: "|")
            guard seenNames.insert(key).inserted else { return nil }
            if variant.isPreferred {
                variant.isPreferred = !retainedPreferredName
                retainedPreferredName = true
            }
            return variant
        }
        if let preferred = copy.nameVariants?.first(where: \.isPreferred) {
            copy.displayName = preferred.fullName
        }

        var seenContacts = Set<String>()
        var retainedPreferredContact = false
        copy.contacts = contacts.compactMap { original in
            var contact = original
            contact.value = contact.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contact.value.isEmpty else { return nil }
            let normalizedValue = contact.value.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            let key = "\(contact.kind.rawValue)|\(normalizedValue)"
            guard seenContacts.insert(key).inserted else { return nil }
            if contact.avoided { contact.isPreferred = false }
            if contact.isPreferred {
                contact.isPreferred = !retainedPreferredContact
                retainedPreferredContact = true
            }
            return contact
        }
        return copy
    }

    public var availableContactMethods: [ContactMethod] {
        contacts.filter { !$0.avoided }
    }

    public var preferredAvailableContactMethod: ContactMethod? {
        availableContactMethods.first(where: \.isPreferred) ?? availableContactMethods.first
    }

    public func isWithinRecipientContactHours(at date: Date = .now) -> Bool {
        guard let identifier = recipientTimeZoneIdentifier,
              let timeZone = TimeZone(identifier: identifier) else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: date)
        return (8..<21).contains(hour)
    }

    private static func trimmedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stableUniqueText(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            return seen.insert(key).inserted ? value : nil
        }
    }
}

public enum InteractionKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case message = "Message"
    case email = "Email"
    case call = "Call"
    case meeting = "Meeting"
    case activity = "Shared activity"
    case attempt = "Contact attempt"
    case other = "Other"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .message: String(localized: "Message")
        case .email: String(localized: "Email")
        case .call: String(localized: "Call")
        case .meeting: String(localized: "Meeting")
        case .activity: String(localized: "Shared activity")
        case .attempt: String(localized: "Contact attempt")
        case .other: String(localized: "Other")
        }
    }
}

public enum InteractionDirection: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case incoming
    case outgoing
    case mutual
    case unspecified

    public var id: Self { self }

    public var localizedTitle: String {
        switch self {
        case .incoming: String(localized: "Incoming")
        case .outgoing: String(localized: "Outgoing")
        case .mutual: String(localized: "Mutual / together")
        case .unspecified: String(localized: "Not specified")
        }
    }
}

public enum InteractionStatus: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case suggested = "Suggestion shown"
    case confirmed = "Confirmed"
    case attempted = "Attempted"
    case composerOpened = "Destination opened"
    case composerReportedSent = "Composer reported sent"
    case userConfirmedSent = "User confirmed contact"
    case apiAccepted = "Provider accepted"
    case delivered = "Delivered"
    case read = "Read"
    case cancelled = "Canceled"
    case failed = "Failed"
    case unknown = "Outcome unknown"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .suggested: String(localized: "Suggestion shown")
        case .confirmed: String(localized: "Confirmed")
        case .attempted: String(localized: "Attempted")
        case .composerOpened: String(localized: "Destination opened")
        case .composerReportedSent: String(localized: "Composer reported sent")
        case .userConfirmedSent: String(localized: "User confirmed contact")
        case .apiAccepted: String(localized: "Provider accepted")
        case .delivered: String(localized: "Delivered")
        case .read: String(localized: "Read")
        case .cancelled: String(localized: "Canceled")
        case .failed: String(localized: "Failed")
        case .unknown: String(localized: "Outcome unknown")
        }
    }

    /// True only when the record contains evidence that contact occurred. A
    /// destination opening, API acceptance, or unknown outcome is not enough.
    public var confirmsContact: Bool {
        switch self {
        case .confirmed, .composerReportedSent, .userConfirmedSent, .delivered, .read:
            true
        case .suggested, .attempted, .composerOpened, .apiAccepted, .cancelled, .failed, .unknown:
            false
        }
    }
}

public enum TranscriptRetention: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case metadataOnly = "Metadata only"
    case summaryAndCommitments = "Summary and commitments"
    case fullTranscript = "Full transcript (sensitive)"

    public var id: String { rawValue }

    public var localizedTitle: String {
        localizedTitle(locale: .current)
    }

    public func localizedTitle(locale: Locale) -> String {
        switch self {
        case .metadataOnly: String(localized: "Metadata only", locale: locale)
        case .summaryAndCommitments: String(localized: "Summary and commitments", locale: locale)
        case .fullTranscript: String(localized: "Full transcript (sensitive)", locale: locale)
        }
    }
}

public struct Interaction: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Primary participant when one remains linked. A permanently deleted solo
    /// participant may be unlinked while the user retains the interaction as
    /// private history, so this reference is deliberately optional.
    public var personID: UUID?
    public var occurredAt: Date
    /// Preserves year/month/day precision when the exact timestamp is not
    /// known. `occurredAt` remains a stable sortable representative instant.
    public var approximateDate: PartialDate?
    public var kind: InteractionKind
    public var direction: InteractionDirection?
    public var channel: String
    public var status: InteractionStatus
    public var summary: String
    public var commitment: String
    public var followUpAt: Date?
    public var additionalParticipantIDs: [UUID]?
    public var privateReflection: String?
    public var generatedDraft: String?
    public var finalContent: String?
    public var sourceEvidenceIDs: [UUID]?
    public var transcriptRetention: TranscriptRetention?
    /// Raw transcript text is retained only after an explicit high-sensitivity
    /// choice. It is never populated by an external handoff.
    public var rawTranscript: String?
    /// The content claim is independent of delivery/read evidence. A generated
    /// draft therefore remains distinct from exact imported final content.
    public var contentFidelity: CommunicationContentFidelity?
    public var communicationEvidence: CommunicationEvidenceLedger?
    public var anticipatedHesitation: Int?
    public var postActionDifficulty: Int?
    public var feltWorthwhile: Bool?
    /// Append-only, privacy-preserving correction metadata. Optional so
    /// interaction payloads created by older builds remain decodable.
    public var correctionHistory: [InteractionCorrection]?
    /// A soft-deletion marker carried inside the encrypted interaction payload.
    /// Keeping it in `detailsData` preserves the additive CloudKit schema while
    /// allowing migration inspection to distinguish deletion from absence.
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        personID: UUID?,
        occurredAt: Date = .now,
        approximateDate: PartialDate? = nil,
        kind: InteractionKind = .message,
        direction: InteractionDirection? = .unspecified,
        channel: String = "",
        status: InteractionStatus = .confirmed,
        summary: String = "",
        commitment: String = "",
        followUpAt: Date? = nil,
        additionalParticipantIDs: [UUID]? = nil,
        privateReflection: String? = nil,
        generatedDraft: String? = nil,
        finalContent: String? = nil,
        sourceEvidenceIDs: [UUID]? = nil,
        transcriptRetention: TranscriptRetention? = .summaryAndCommitments,
        rawTranscript: String? = nil,
        contentFidelity: CommunicationContentFidelity? = nil,
        communicationEvidence: CommunicationEvidenceLedger? = nil,
        anticipatedHesitation: Int? = nil,
        postActionDifficulty: Int? = nil,
        feltWorthwhile: Bool? = nil,
        correctionHistory: [InteractionCorrection]? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.personID = personID
        self.occurredAt = occurredAt
        self.approximateDate = approximateDate
        self.kind = kind
        self.direction = direction
        self.channel = channel
        self.status = status
        self.summary = summary
        self.commitment = commitment
        self.followUpAt = followUpAt
        self.additionalParticipantIDs = additionalParticipantIDs
        self.privateReflection = privateReflection
        self.generatedDraft = generatedDraft
        self.finalContent = finalContent
        self.sourceEvidenceIDs = sourceEvidenceIDs
        self.transcriptRetention = transcriptRetention
        self.rawTranscript = rawTranscript
        self.contentFidelity = contentFidelity
        self.communicationEvidence = communicationEvidence
        self.anticipatedHesitation = anticipatedHesitation
        self.postActionDifficulty = postActionDifficulty
        self.feltWorthwhile = feltWorthwhile
        self.correctionHistory = correctionHistory
        self.deletedAt = deletedAt
    }

    public var effectiveContentFidelity: CommunicationContentFidelity? {
        communicationEvidence?.contentFidelity ?? contentFidelity
    }

    /// Enforces the transcript-retention choice at the persistence boundary.
    /// UI state alone is not trusted to keep exact content out of lower-
    /// retention records.
    public func normalizedForRetention() -> Self {
        var copy = self
        var seenParticipantIDs = Set<UUID>()
        let normalizedAdditionalParticipants = (additionalParticipantIDs ?? []).filter { participantID in
            participantID != personID && seenParticipantIDs.insert(participantID).inserted
        }
        copy.additionalParticipantIDs = normalizedAdditionalParticipants.isEmpty
            ? nil
            : normalizedAdditionalParticipants
        let retention = transcriptRetention ?? .summaryAndCommitments
        let trimmedTranscript = rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.rawTranscript = (retention == .fullTranscript && !(trimmedTranscript ?? "").isEmpty)
            ? trimmedTranscript
            : nil

        switch retention {
        case .metadataOnly:
            copy.summary = ""
            copy.commitment = ""
            copy.rawTranscript = nil
            copy.finalContent = nil
            if copy.communicationEvidence == nil { copy.contentFidelity = nil }
        case .summaryAndCommitments:
            copy.rawTranscript = nil
            copy.finalContent = nil
            if copy.communicationEvidence == nil,
               !copy.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copy.contentFidelity = .summaryOnly
            }
        case .fullTranscript:
            if copy.rawTranscript != nil,
               copy.communicationEvidence == nil,
               copy.contentFidelity == nil {
                copy.contentFidelity = .exactFromUserImport
            }
            let fidelity = copy.effectiveContentFidelity
            if fidelity != .exactFromUserImport && fidelity != .exactFromAPI {
                copy.finalContent = nil
            }
        }

        if let ledger = copy.communicationEvidence {
            copy.status = ledger.projectedInteractionStatus
            copy.contentFidelity = ledger.contentFidelity
        }
        return copy
    }
}

public enum EffortLevel: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case tiny = "Tiny"
    case light = "Light"
    case meaningful = "Meaningful"
    case deep = "Deep"

    public var id: String { rawValue }

    public var localizedTitle: String {
        localizedTitle(locale: .current)
    }

    public func localizedTitle(locale: Locale) -> String {
        switch self {
        case .tiny: String(localized: "Tiny", locale: locale)
        case .light: String(localized: "Light", locale: locale)
        case .meaningful: String(localized: "Meaningful", locale: locale)
        case .deep: String(localized: "Deep", locale: locale)
        }
    }

    public var suggestion: String {
        switch self {
        case .tiny: String(localized: "Send a reaction or a one-line hello")
        case .light: String(localized: "Share a brief check-in")
        case .meaningful: String(localized: "Ask an open question and make time for the reply")
        case .deep: String(localized: "Suggest a call or time together")
        }
    }
}

public enum NudgeFrequency: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case off = "Off"
    case weekly = "1 / week"
    case twiceWeekly = "2 / week"
    case threeWeekly = "3 / week"
    case weekdays = "5 / week"
    case daily = "Daily"
    case custom = "Custom"

    public var id: String { rawValue }

    public var localizedTitle: String {
        localizedTitle(locale: .current)
    }

    public func localizedTitle(locale: Locale) -> String {
        switch self {
        case .off: String(localized: "Off", locale: locale)
        case .weekly: String(localized: "1 / week", locale: locale)
        case .twiceWeekly: String(localized: "2 / week", locale: locale)
        case .threeWeekly: String(localized: "3 / week", locale: locale)
        case .weekdays: String(localized: "5 / week", locale: locale)
        case .daily: String(localized: "Daily", locale: locale)
        case .custom: String(localized: "Custom", locale: locale)
        }
    }
}

public struct NudgeSuggestion: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let person: Person
    public let explanation: String
    public let prompt: String

    public init(id: UUID = UUID(), person: Person, explanation: String, prompt: String) {
        self.id = id
        self.person = person
        self.explanation = explanation
        self.prompt = prompt
    }
}

public struct NotebookArchive: Codable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var people: [Person]
    public var interactions: [Interaction]
    public var canonical: CanonicalArchivePayload?
    public var ownedProfileSnapshots: [ProfileCardSnapshotPayload]?
    /// Namespaced future fields are retained when a newer build explicitly places them here.
    public var preservedExtensions: [String: JSONValue]?

    public init(
        schemaVersion: Int = 1,
        exportedAt: Date = .now,
        people: [Person],
        interactions: [Interaction],
        canonical: CanonicalArchivePayload? = nil,
        ownedProfileSnapshots: [ProfileCardSnapshotPayload]? = nil,
        preservedExtensions: [String: JSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.people = people
        self.interactions = interactions
        self.canonical = canonical
        self.ownedProfileSnapshots = ownedProfileSnapshots
        self.preservedExtensions = preservedExtensions
    }
}
