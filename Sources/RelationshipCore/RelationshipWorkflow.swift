import Foundation

/// The first-class planning records derived from one interaction. Re-running
/// the projection updates the existing linked records and identifies stale
/// duplicates, so editing an interaction never leaves phantom next steps.
public struct InteractionPlanningProjection: Equatable, Sendable {
    public var reminder: Reminder?
    public var commitment: Commitment?
    public var reminderIDsToDelete: [UUID]
    public var commitmentIDsToDelete: [UUID]

    public init(
        reminder: Reminder?,
        commitment: Commitment?,
        reminderIDsToDelete: [UUID] = [],
        commitmentIDsToDelete: [UUID] = []
    ) {
        self.reminder = reminder
        self.commitment = commitment
        self.reminderIDsToDelete = reminderIDsToDelete
        self.commitmentIDsToDelete = commitmentIDsToDelete
    }

    public static func make(
        for interaction: Interaction,
        existingReminders: [Reminder],
        existingCommitments: [Commitment],
        now: Date = .now,
        timeZoneIdentifier: String? = TimeZone.current.identifier
    ) -> Self {
        let linkedReminders = existingReminders
            .filter { $0.interactionID == interaction.id }
            .sorted { $0.createdAt < $1.createdAt }
        let linkedCommitments = existingCommitments
            .filter { $0.interactionID == interaction.id }
            .sorted { $0.createdAt < $1.createdAt }
        let participantIDs = stableUnique(
            [interaction.personID].compactMap { $0 } + (interaction.additionalParticipantIDs ?? [])
        )

        let reminder: Reminder?
        if interaction.deletedAt == nil,
           let personID = interaction.personID,
           let followUpAt = interaction.followUpAt {
            let previous = linkedReminders.first
            reminder = Reminder(
                id: previous?.id ?? UUID(),
                subject: .person(personID),
                title: String(localized: "Follow up after interaction"),
                due: .instant(followUpAt, timeZoneIdentifier: timeZoneIdentifier),
                recurrence: .none,
                notificationPrivacy: previous?.notificationPrivacy ?? .generic,
                isEnabled: previous?.isEnabled ?? true,
                interactionID: interaction.id,
                events: previous?.events,
                createdAt: previous?.createdAt ?? now,
                modifiedAt: now,
                schemaRevision: previous?.schemaRevision ?? 1
            )
        } else {
            reminder = nil
        }

        let commitmentText = interaction.commitment
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commitment: Commitment?
        if interaction.deletedAt == nil, !commitmentText.isEmpty {
            let previous = linkedCommitments.first
            commitment = Commitment(
                id: previous?.id ?? UUID(),
                interactionID: interaction.id,
                personIDs: participantIDs,
                summary: commitmentText,
                owner: previous?.owner ?? .unspecified,
                due: interaction.followUpAt.map {
                    .instant($0, timeZoneIdentifier: timeZoneIdentifier)
                },
                sourceAssertionID: previous?.sourceAssertionID,
                events: previous?.events,
                createdAt: previous?.createdAt ?? now,
                modifiedAt: now,
                schemaRevision: previous?.schemaRevision ?? 1
            )
        } else {
            commitment = nil
        }

        return Self(
            reminder: reminder,
            commitment: commitment,
            reminderIDsToDelete: linkedReminders.dropFirst(reminder == nil ? 0 : 1).map(\.id),
            commitmentIDsToDelete: linkedCommitments.dropFirst(commitment == nil ? 0 : 1).map(\.id)
        )
    }

    private static func stableUnique(_ values: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// A privacy-preserving audit entry for an interaction correction. Sensitive
/// narrative text is represented as present/empty instead of duplicated into
/// history, while state, timing, participants, and retention changes retain
/// their before/after values.
public struct InteractionCorrection: Codable, Hashable, Sendable, Identifiable {
    public struct Change: Codable, Hashable, Sendable, Identifiable {
        public var id: String { field }
        public let field: String
        public let previousValue: String
        public let newValue: String

        public init(field: String, previousValue: String, newValue: String) {
            self.field = field
            self.previousValue = previousValue
            self.newValue = newValue
        }
    }

    public let id: UUID
    public let occurredAt: Date
    public let changes: [Change]

    public init(id: UUID = UUID(), occurredAt: Date = .now, changes: [Change]) {
        self.id = id
        self.occurredAt = occurredAt
        self.changes = changes
    }
}

public extension Interaction {
    /// Appends an audit entry when the edited record differs from its source.
    /// Existing history always wins over a stale editor copy.
    func recordingCorrection(from original: Interaction, at date: Date = .now) -> Self {
        var copy = self
        copy.correctionHistory = original.correctionHistory
        let changes = correctionChanges(from: original)
        guard !changes.isEmpty else { return copy }
        var history = copy.correctionHistory ?? []
        history.append(InteractionCorrection(occurredAt: date, changes: changes))
        copy.correctionHistory = history
        return copy
    }

    private func correctionChanges(from old: Interaction) -> [InteractionCorrection.Change] {
        var values: [InteractionCorrection.Change] = []
        func add(_ field: String, _ previous: String, _ next: String) {
            guard previous != next else { return }
            values.append(.init(field: field, previousValue: previous, newValue: next))
        }
        func presence(_ value: String?) -> String {
            (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "Empty") : String(localized: "Present")
        }
        func date(_ value: Date?) -> String {
            value?.formatted(.iso8601) ?? String(localized: "None")
        }

        add("person", old.personID?.uuidString ?? "none", personID?.uuidString ?? "none")
        add("occurredAt", date(old.occurredAt), date(occurredAt))
        add("approximateDate", old.approximateDate?.description ?? "none", approximateDate?.description ?? "none")
        add("kind", old.kind.rawValue, kind.rawValue)
        add("direction", old.direction?.rawValue ?? "none", direction?.rawValue ?? "none")
        add("channel", old.channel, channel)
        add("status", old.status.rawValue, status.rawValue)
        add("summary", presence(old.summary), presence(summary))
        add("commitment", presence(old.commitment), presence(commitment))
        add("followUp", date(old.followUpAt), date(followUpAt))
        add(
            "participants",
            (old.additionalParticipantIDs ?? []).map(\.uuidString).joined(separator: ","),
            (additionalParticipantIDs ?? []).map(\.uuidString).joined(separator: ",")
        )
        add("privateReflection", presence(old.privateReflection), presence(privateReflection))
        add("retention", old.transcriptRetention?.rawValue ?? "none", transcriptRetention?.rawValue ?? "none")
        add("rawTranscript", presence(old.rawTranscript), presence(rawTranscript))
        add("deletedAt", date(old.deletedAt), date(deletedAt))
        return values
    }
}

public extension AssertionEnvelope {
    /// Creates an auditable policy/review revision without mutating or losing
    /// the prior assertion, source, evidence, validity, or remote provenance.
    func revisingReviewAndUsePolicy(
        reviewStatus: AssertionReviewStatus? = nil,
        usePolicy: AssertionUsePolicy? = nil,
        assertedAt: Date = .now
    ) throws -> AssertionEnvelope {
        try AssertionEnvelope(
            subjectID: subjectID,
            predicateID: predicateID,
            value: value,
            sourceID: sourceID,
            evidenceIDs: evidenceIDs,
            origin: origin,
            confidence: confidence,
            reviewStatus: reviewStatus ?? self.reviewStatus,
            certainty: certainty,
            observedAt: observedAt,
            assertedAt: assertedAt,
            validFrom: validFrom,
            validTo: validTo,
            sensitivity: sensitivity,
            usePolicy: usePolicy ?? self.usePolicy,
            supersedesID: id,
            remoteSelfProfileProvenance: remoteSelfProfileProvenance,
            schemaRevision: schemaRevision
        )
    }
}

/// Stable, non-secret context used to disambiguate equal display names in
/// pickers without exposing whole contact values.
public enum PersonChoiceDescription {
    public static func detail(for person: Person) -> String {
        var parts: [String] = []
        if let alias = person.aliases.first, !alias.isEmpty { parts.append(alias) }
        if let context = person.contexts.first, !context.isEmpty { parts.append(context) }
        if let contact = person.preferredAvailableContactMethod {
            parts.append(contactHint(contact))
        }
        return parts.isEmpty ? String(localized: "No context yet") : parts.joined(separator: " · ")
    }

    private static func contactHint(_ contact: ContactMethod) -> String {
        let value = contact.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if contact.kind == .email, let at = value.firstIndex(of: "@") {
            return "\(contact.kind.localizedTitle) · …\(value[at...])"
        }
        let suffix = value.suffix(4)
        return suffix.isEmpty
            ? contact.kind.localizedTitle
            : "\(contact.kind.localizedTitle) · ••••\(suffix)"
    }
}

public enum TodayAttentionKind: String, Codable, Hashable, Sendable {
    case reminder
    case commitment
    case unresolvedContact
    case pendingReview
}

public struct TodayAttentionItem: Codable, Hashable, Sendable, Identifiable {
    public let kind: TodayAttentionKind
    public let recordID: UUID
    public let title: String
    public let personIDs: [UUID]
    public let dueAt: Date?

    public var id: String { "\(kind.rawValue):\(recordID.uuidString)" }

    public init(
        kind: TodayAttentionKind,
        recordID: UUID,
        title: String,
        personIDs: [UUID] = [],
        dueAt: Date? = nil
    ) {
        self.kind = kind
        self.recordID = recordID
        self.title = title
        self.personIDs = personIDs
        self.dueAt = dueAt
    }

    public func isOverdue(at date: Date = .now) -> Bool {
        dueAt.map { $0 < date } ?? false
    }
}

public enum TodayAttentionProjector {
    public static func project(
        reminders: [Reminder],
        commitments: [Commitment],
        interactions: [Interaction],
        pendingReviewIDs: [UUID] = []
    ) -> [TodayAttentionItem] {
        var items: [TodayAttentionItem] = []
        items += reminders.compactMap { reminder in
            guard reminder.isActionable else { return nil }
            let personIDs: [UUID] = if case let .person(id) = reminder.subject { [id] } else { [] }
            return TodayAttentionItem(
                kind: .reminder,
                recordID: reminder.id,
                title: reminder.title,
                personIDs: personIDs,
                dueAt: date(reminder.effectiveDue)
            )
        }
        items += commitments.compactMap { commitment in
            guard commitment.isActionable else { return nil }
            return TodayAttentionItem(
                kind: .commitment,
                recordID: commitment.id,
                title: commitment.summary,
                personIDs: commitment.personIDs,
                dueAt: commitment.due.map(date)
            )
        }
        items += interactions.compactMap { interaction in
            guard interaction.deletedAt == nil,
                  [.composerOpened, .attempted, .unknown, .apiAccepted, .failed]
                    .contains(interaction.status) else { return nil }
            let people = stableUnique(
                [interaction.personID].compactMap { $0 } + (interaction.additionalParticipantIDs ?? [])
            )
            return TodayAttentionItem(
                kind: .unresolvedContact,
                recordID: interaction.id,
                title: String(localized: "Confirm contact outcome"),
                personIDs: people,
                dueAt: interaction.occurredAt
            )
        }
        items += pendingReviewIDs.map {
            TodayAttentionItem(
                kind: .pendingReview,
                recordID: $0,
                title: String(localized: "Finish import review")
            )
        }
        return items.sorted { left, right in
            switch (left.dueAt, right.dueAt) {
            case let (left?, right?) where left != right: left < right
            case (.some, .none): true
            case (.none, .some): false
            default: left.id < right.id
            }
        }
    }

    private static func date(_ due: ReminderDue) -> Date {
        switch due {
        case let .instant(value, _): value
        case let .partialDate(value): value.earliestInstant
        }
    }

    private static func stableUnique(_ values: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0).inserted }
    }
}

public enum ContactHandoffSupport: String, Codable, Hashable, Sendable {
    /// Both the intended recipient and reviewed body are encoded in the URL.
    case recipientAndBody
    /// The recipient is targeted, but the reviewed body remains on clipboard.
    case recipientOnlyClipboardBody
    /// The destination can be opened, but Keepsake cannot target the saved
    /// recipient or prefill the body. Clipboard is the only content handoff.
    case clipboardOnlyUntargeted
}

public struct ContactHandoffRoute: Hashable, Sendable {
    public let URL: URL?
    public let support: ContactHandoffSupport

    public init(URL: URL?, support: ContactHandoffSupport) {
        self.URL = URL
        self.support = support
    }
}

public enum ContactHandoffRouteBuilder {
    public static func route(for contact: ContactMethod, reviewedBody: String) -> ContactHandoffRoute {
        guard !contact.avoided else {
            return ContactHandoffRoute(URL: nil, support: .clipboardOnlyUntargeted)
        }
        switch contact.kind {
        case .email:
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = contact.value.trimmingCharacters(in: .whitespacesAndNewlines)
            components.queryItems = [URLQueryItem(name: "body", value: reviewedBody)]
            return ContactHandoffRoute(URL: components.url, support: .recipientAndBody)
        case .messages:
            var components = URLComponents()
            components.scheme = "sms"
            components.path = dialable(contact.value)
            components.queryItems = [URLQueryItem(name: "body", value: reviewedBody)]
            return ContactHandoffRoute(URL: components.url, support: .recipientAndBody)
        case .whatsapp:
            var components = URLComponents()
            components.scheme = "https"
            components.host = "wa.me"
            components.path = "/\(digits(contact.value))"
            components.queryItems = [URLQueryItem(name: "text", value: reviewedBody)]
            return ContactHandoffRoute(URL: components.url, support: .recipientAndBody)
        case .phone:
            var components = URLComponents()
            components.scheme = "tel"
            components.path = dialable(contact.value)
            return ContactHandoffRoute(URL: components.url, support: .recipientOnlyClipboardBody)
        case .line:
            return ContactHandoffRoute(URL: URL(string: "line://"), support: .clipboardOnlyUntargeted)
        case .instagram:
            return ContactHandoffRoute(URL: URL(string: "instagram://"), support: .clipboardOnlyUntargeted)
        case .snapchat:
            return ContactHandoffRoute(URL: URL(string: "snapchat://"), support: .clipboardOnlyUntargeted)
        }
    }

    private static func dialable(_ value: String) -> String {
        value.filter { $0.isNumber || $0 == "+" }
    }

    private static func digits(_ value: String) -> String {
        value.filter(\.isNumber)
    }
}
