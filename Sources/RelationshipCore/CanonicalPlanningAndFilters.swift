import Foundation

public enum AttributeCardinality: String, Codable, CaseIterable, Sendable {
    case single
    case multiple
}

public struct AttributeCapabilities: Codable, Hashable, Sendable {
    public var supportsSearch: Bool
    public var supportsFilter: Bool
    public var supportsSort: Bool
    public var supportsReminders: Bool
    public var supportsAI: Bool
    public var supportsConversationMentions: Bool
    public var supportsProfileSharing: Bool

    public init(
        supportsSearch: Bool = false,
        supportsFilter: Bool = false,
        supportsSort: Bool = false,
        supportsReminders: Bool = false,
        supportsAI: Bool = false,
        supportsConversationMentions: Bool = false,
        supportsProfileSharing: Bool = false
    ) {
        self.supportsSearch = supportsSearch
        self.supportsFilter = supportsFilter
        self.supportsSort = supportsSort
        self.supportsReminders = supportsReminders
        self.supportsAI = supportsAI
        self.supportsConversationMentions = supportsConversationMentions
        self.supportsProfileSharing = supportsProfileSharing
    }
}

public struct AttributeValidationRules: Codable, Hashable, Sendable {
    public var minimumTextLength: Int?
    public var maximumTextLength: Int?
    public var regularExpression: String?
    public var minimumNumber: Decimal?
    public var maximumNumber: Decimal?
    public var allowedUnitCodes: Set<String>?
    public var minimumDate: PartialDate?
    public var maximumDate: PartialDate?

    public init(
        minimumTextLength: Int? = nil,
        maximumTextLength: Int? = nil,
        regularExpression: String? = nil,
        minimumNumber: Decimal? = nil,
        maximumNumber: Decimal? = nil,
        allowedUnitCodes: Set<String>? = nil,
        minimumDate: PartialDate? = nil,
        maximumDate: PartialDate? = nil
    ) {
        self.minimumTextLength = minimumTextLength
        self.maximumTextLength = maximumTextLength
        self.regularExpression = regularExpression
        self.minimumNumber = minimumNumber
        self.maximumNumber = maximumNumber
        self.allowedUnitCodes = allowedUnitCodes
        self.minimumDate = minimumDate
        self.maximumDate = maximumDate
    }
}

public struct AttributeOption: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let definitionID: UUID
    public var label: LocalizedText
    public var order: Int
    public var archivedAt: Date?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        definitionID: UUID,
        label: LocalizedText,
        order: Int,
        archivedAt: Date? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.definitionID = definitionID
        self.label = label
        self.order = order
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }
}

public enum AttributeValueValidationIssue: Equatable, Sendable {
    case wrongValueKind(expected: AttributeValueKind, actual: AttributeValueKind)
    case cardinalityMismatch
    case textTooShort(minimum: Int)
    case textTooLong(maximum: Int)
    case textPatternMismatch
    case numberBelowMinimum(Decimal)
    case numberAboveMaximum(Decimal)
    case unitNotAllowed(String?)
    case dateBeforeMinimum
    case dateAfterMaximum
    case optionDoesNotBelong(UUID)
    case optionIsArchived(UUID)
    case duplicateOption(UUID)
}

public struct AttributeDefinition: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Stable predicate identifier retained even if the definition is archived.
    public let predicateID: String
    public var labels: LocalizedText
    public let valueKind: AttributeValueKind
    public let cardinality: AttributeCardinality
    public var validation: AttributeValidationRules
    public var defaultSensitivity: Sensitivity
    public var defaultUsePolicy: AssertionUsePolicy
    public var capabilities: AttributeCapabilities
    /// Embedded, definition-owned choices for select fields. Optional keeps
    /// older archives source-compatible; nil is equivalent to no choices.
    public var options: [AttributeOption]?
    /// Stable user-controlled order, independent of label and modification time.
    public var displayOrder: Int?
    public var archivedAt: Date?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        predicateID: String,
        labels: LocalizedText,
        valueKind: AttributeValueKind,
        cardinality: AttributeCardinality = .single,
        validation: AttributeValidationRules = .init(),
        defaultSensitivity: Sensitivity = .private,
        defaultUsePolicy: AssertionUsePolicy = .init(),
        capabilities: AttributeCapabilities = .init(),
        options: [AttributeOption]? = nil,
        displayOrder: Int? = nil,
        archivedAt: Date? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.predicateID = predicateID
        self.labels = labels
        self.valueKind = valueKind
        self.cardinality = cardinality
        self.validation = validation
        self.defaultSensitivity = defaultSensitivity
        self.defaultUsePolicy = defaultUsePolicy
        self.capabilities = capabilities
        self.options = options
        self.displayOrder = displayOrder
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }

    /// Type changes require a new definition and reviewed conversion.
    public func canReplaceWithoutConversion(_ existing: AttributeDefinition) -> Bool {
        id == existing.id && predicateID == existing.predicateID &&
            valueKind == existing.valueKind && cardinality == existing.cardinality
    }

    public func validate(
        value: TypedValue,
        options explicitOptions: [AttributeOption]? = nil,
        allowArchivedOptions: Bool = false
    ) -> [AttributeValueValidationIssue] {
        let options = explicitOptions ?? self.options ?? []
        var issues: [AttributeValueValidationIssue] = []
        guard value.kind == valueKind else {
            return [.wrongValueKind(expected: valueKind, actual: value.kind)]
        }

        if cardinality == .multiple, valueKind != .multiSelect {
            issues.append(.cardinalityMismatch)
        }
        if cardinality == .single, valueKind == .multiSelect {
            issues.append(.cardinalityMismatch)
        }

        switch value {
        case let .text(text), let .richText(text):
            validate(text: text, into: &issues)

        case let .number(number):
            if let minimum = validation.minimumNumber, number.value < minimum {
                issues.append(.numberBelowMinimum(minimum))
            }
            if let maximum = validation.maximumNumber, number.value > maximum {
                issues.append(.numberAboveMaximum(maximum))
            }
            if let allowed = validation.allowedUnitCodes,
               !allowed.contains(number.unitCode ?? "") {
                issues.append(.unitNotAllowed(number.unitCode))
            }

        case let .partialDate(date):
            validate(date: date, into: &issues)

        case let .dateRange(range):
            if let start = range.start { validate(date: start, into: &issues) }
            if let end = range.end { validate(date: end, into: &issues) }

        case let .singleSelect(optionID):
            validate(optionIDs: [optionID], options: options, allowArchived: allowArchivedOptions, into: &issues)

        case let .multiSelect(optionIDs):
            validate(optionIDs: optionIDs, options: options, allowArchived: allowArchivedOptions, into: &issues)

        default:
            break
        }
        return issues
    }

    private func validate(text: String, into issues: inout [AttributeValueValidationIssue]) {
        if let minimum = validation.minimumTextLength, text.count < minimum {
            issues.append(.textTooShort(minimum: minimum))
        }
        if let maximum = validation.maximumTextLength, text.count > maximum {
            issues.append(.textTooLong(maximum: maximum))
        }
        if let pattern = validation.regularExpression,
           text.range(of: pattern, options: .regularExpression) == nil {
            issues.append(.textPatternMismatch)
        }
    }

    private func validate(date: PartialDate, into issues: inout [AttributeValueValidationIssue]) {
        if let minimum = validation.minimumDate,
           date.latestInstant < minimum.earliestInstant {
            issues.append(.dateBeforeMinimum)
        }
        if let maximum = validation.maximumDate,
           date.earliestInstant > maximum.latestInstant {
            issues.append(.dateAfterMaximum)
        }
    }

    private func validate(
        optionIDs: [UUID],
        options: [AttributeOption],
        allowArchived: Bool,
        into issues: inout [AttributeValueValidationIssue]
    ) {
        let optionByID = options.reduce(into: [UUID: AttributeOption]()) { result, option in
            if result[option.id] == nil { result[option.id] = option }
        }
        var seen = Set<UUID>()
        for optionID in optionIDs {
            if !seen.insert(optionID).inserted {
                issues.append(.duplicateOption(optionID))
            }
            guard let option = optionByID[optionID], option.definitionID == id else {
                issues.append(.optionDoesNotBelong(optionID))
                continue
            }
            if option.archivedAt != nil, !allowArchived {
                issues.append(.optionIsArchived(optionID))
            }
        }
    }
}

public enum CanonicalFactPolicyViolation: Error, Equatable, Sendable {
    case credentialLikeValue
    case definitionValueKindMismatch(
        predicateID: String,
        expected: AttributeValueKind,
        actual: AttributeValueKind
    )
    case sensitivityBelowDefinitionDefault(predicateID: String)
    case usePolicyExceedsDefinition(predicateID: String)
}

extension CanonicalFactPolicyViolation: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .credentialLikeValue:
            String(localized: "Credentials and authentication secrets cannot be saved as facts. Use a password manager instead.")
        case .definitionValueKindMismatch:
            String(localized: "This fact does not match the selected custom field’s value type.")
        case .sensitivityBelowDefinitionDefault:
            String(localized: "This fact cannot be less private than the selected custom field’s default.")
        case .usePolicyExceedsDefinition:
            String(localized: "This fact requests a use that the selected custom field does not allow.")
        }
    }
}

/// The authoritative privacy/capability intersection for facts belonging to a
/// custom-field definition. Callers may make an individual fact more
/// restrictive, but never broader than either the definition's default policy
/// or its enabled capabilities.
public extension AttributeDefinition {
    var permittedFactUsePolicy: AssertionUsePolicy {
        AssertionUsePolicy(
            search: capabilities.supportsSearch ? defaultUsePolicy.search : .exclude,
            remindersAllowed: capabilities.supportsReminders && defaultUsePolicy.remindersAllowed,
            notifications: capabilities.supportsReminders ? defaultUsePolicy.notifications : .exclude,
            sharing: capabilities.supportsProfileSharing ? defaultUsePolicy.sharing : .exclude,
            mention: capabilities.supportsConversationMentions ? defaultUsePolicy.mention : .never,
            ai: capabilities.supportsAI ? defaultUsePolicy.ai : .deny
        )
    }

    func permitsFactSensitivity(_ sensitivity: Sensitivity) -> Bool {
        sensitivity.privacyRank >= defaultSensitivity.privacyRank
    }

    func permitsFactUsePolicy(_ policy: AssertionUsePolicy) -> Bool {
        policy == factUsePolicyByApplyingLimits(to: policy)
    }

    func factUsePolicyByApplyingLimits(to requested: AssertionUsePolicy) -> AssertionUsePolicy {
        let permitted = permittedFactUsePolicy
        return AssertionUsePolicy(
            search: permitted.search == .include ? requested.search : .exclude,
            remindersAllowed: permitted.remindersAllowed && requested.remindersAllowed,
            notifications: requested.notifications.privacyRank <= permitted.notifications.privacyRank
                ? requested.notifications : permitted.notifications,
            sharing: requested.sharing.privacyRank <= permitted.sharing.privacyRank
                ? requested.sharing : permitted.sharing,
            mention: requested.mention.privacyRank <= permitted.mention.privacyRank
                ? requested.mention : permitted.mention,
            // AI destinations are separate consent boundaries rather than a
            // linear ladder. Deny is always valid; any enabled route must be
            // exactly the route authorized by the field definition.
            ai: requested.ai == .deny || requested.ai == permitted.ai ? requested.ai : .deny
        )
    }
}

/// Pure model-boundary validation shared by UI-created, recommendation-created,
/// and repository-saved canonical facts.
public enum CanonicalFactWritePolicy {
    public static func validate(
        _ assertion: AssertionEnvelope,
        definition: AttributeDefinition?
    ) throws {
        if SensitiveFieldPolicy.credentialWarning(forFactValue: assertion.value) != nil {
            throw CanonicalFactPolicyViolation.credentialLikeValue
        }
        guard let definition else { return }
        guard assertion.value.kind == definition.valueKind else {
            throw CanonicalFactPolicyViolation.definitionValueKindMismatch(
                predicateID: definition.predicateID,
                expected: definition.valueKind,
                actual: assertion.value.kind
            )
        }
        guard definition.permitsFactSensitivity(assertion.sensitivity) else {
            throw CanonicalFactPolicyViolation.sensitivityBelowDefinitionDefault(
                predicateID: definition.predicateID
            )
        }
        guard definition.permitsFactUsePolicy(assertion.usePolicy) else {
            throw CanonicalFactPolicyViolation.usePolicyExceedsDefinition(
                predicateID: definition.predicateID
            )
        }
    }
}

private extension Sensitivity {
    var privacyRank: Int {
        switch self {
        case .ordinary: 0
        case .private: 1
        case .sensitive: 2
        case .highlySensitive: 3
        }
    }
}

private extension NotificationUsePolicy {
    var privacyRank: Int {
        switch self {
        case .exclude: 0
        case .genericOnly: 1
        case .includeValue: 2
        }
    }
}

private extension SharingUsePolicy {
    var privacyRank: Int {
        switch self {
        case .exclude: 0
        case .eligibleAfterPreview: 1
        }
    }
}

private extension MentionPolicy {
    var privacyRank: Int {
        switch self {
        case .never: 0
        case .ask: 1
        case .allow: 2
        }
    }
}

public enum CanonicalSubjectReference: Codable, Hashable, Sendable {
    case person(UUID)
    case context(UUID)
    case interaction(UUID)
    case assertion(UUID)
    case commitment(UUID)
}

public enum ReminderDue: Codable, Hashable, Sendable {
    case partialDate(PartialDate)
    case instant(Date, timeZoneIdentifier: String?)
}

public enum Weekday: Int, Codable, CaseIterable, Sendable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
}

public enum RecurrenceRule: Codable, Hashable, Sendable {
    case none
    case daily(interval: Int)
    case weekly(interval: Int, weekdays: Set<Weekday>)
    case monthly(interval: Int)
    case yearly(interval: Int)

    public var isValid: Bool {
        switch self {
        case .none:
            true
        case let .daily(interval), let .monthly(interval), let .yearly(interval):
            interval > 0
        case let .weekly(interval, weekdays):
            interval > 0 && !weekdays.isEmpty
        }
    }
}

public enum ReminderNotificationPrivacy: String, Codable, CaseIterable, Sendable {
    case generic
    case includePersonName
    case includeContext
}

public struct Reminder: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var subject: CanonicalSubjectReference
    public var title: String
    public var due: ReminderDue
    public var recurrence: RecurrenceRule
    public var notificationPrivacy: ReminderNotificationPrivacy
    public var isEnabled: Bool
    /// Links a reminder created from an interaction back to its source. This
    /// is optional so records written by older builds continue to decode.
    public var interactionID: UUID?
    /// An append-only lifecycle log. Keeping events with the reminder makes
    /// completion and snooze state portable in exports and across devices.
    public var events: [ReminderEvent]?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        subject: CanonicalSubjectReference,
        title: String,
        due: ReminderDue,
        recurrence: RecurrenceRule = .none,
        notificationPrivacy: ReminderNotificationPrivacy = .generic,
        isEnabled: Bool = true,
        interactionID: UUID? = nil,
        events: [ReminderEvent]? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.subject = subject
        self.title = title
        self.due = due
        self.recurrence = recurrence
        self.notificationPrivacy = notificationPrivacy
        self.isEnabled = isEnabled
        self.interactionID = interactionID
        self.events = events
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }

    public var validationIssues: [String] {
        var issues: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("reminder.emptyTitle")
        }
        if !recurrence.isValid { issues.append("reminder.invalidRecurrence") }
        return issues
    }
}

public enum ReminderEventKind: Codable, Hashable, Sendable {
    case completed
    case snoozed(until: ReminderDue)
    case reopened
    case dismissed
    case deliveryFailed(message: String)
}

public struct ReminderEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let reminderID: UUID
    public let kind: ReminderEventKind
    public let occurredAt: Date

    public init(
        id: UUID = UUID(),
        reminderID: UUID,
        kind: ReminderEventKind,
        occurredAt: Date = .now
    ) {
        self.id = id
        self.reminderID = reminderID
        self.kind = kind
        self.occurredAt = occurredAt
    }
}

public enum ReminderLifecycleState: Equatable, Sendable {
    case active
    case snoozed(until: ReminderDue)
    case completed
    case dismissed
    case deliveryError(String)
}

public extension Reminder {
    var lifecycleState: ReminderLifecycleState {
        guard let latest = (events ?? []).max(by: { $0.occurredAt < $1.occurredAt }) else {
            return .active
        }
        switch latest.kind {
        case .completed: return .completed
        case let .snoozed(until): return .snoozed(until: until)
        case .reopened: return .active
        case .dismissed: return .dismissed
        case let .deliveryFailed(message): return .deliveryError(message)
        }
    }

    var effectiveDue: ReminderDue {
        if case let .snoozed(until) = lifecycleState { return until }
        return due
    }

    var isActionable: Bool {
        guard isEnabled else { return false }
        return switch lifecycleState {
        case .active, .snoozed, .deliveryError: true
        case .completed, .dismissed: false
        }
    }

    mutating func record(_ kind: ReminderEventKind, at date: Date = .now) {
        var history = events ?? []
        history.append(ReminderEvent(reminderID: id, kind: kind, occurredAt: date))
        events = history
        modifiedAt = date
    }
}

public enum CommitmentOwner: Codable, Hashable, Sendable {
    case notebookOwner
    case person(UUID)
    case shared([UUID])
    case unspecified
}

public struct Commitment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let interactionID: UUID?
    public var personIDs: [UUID]
    public var summary: String
    public var owner: CommitmentOwner
    public var due: ReminderDue?
    public let sourceAssertionID: UUID?
    /// Append-only state transitions for completion, reopening, and
    /// retraction. Optional for backward-compatible decoding.
    public var events: [CommitmentEvent]?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        interactionID: UUID? = nil,
        personIDs: [UUID] = [],
        summary: String,
        owner: CommitmentOwner = .unspecified,
        due: ReminderDue? = nil,
        sourceAssertionID: UUID? = nil,
        events: [CommitmentEvent]? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.interactionID = interactionID
        self.personIDs = personIDs
        self.summary = summary
        self.owner = owner
        self.due = due
        self.sourceAssertionID = sourceAssertionID
        self.events = events
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }

    public var validationIssues: [String] {
        var issues: [String] = []
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("commitment.emptySummary")
        }
        if Set(personIDs).count != personIDs.count {
            issues.append("commitment.duplicatePerson")
        }
        return issues
    }
}

public enum CommitmentEventKind: String, Codable, CaseIterable, Sendable {
    case completed
    case reopened
    case retracted
}

public struct CommitmentEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let commitmentID: UUID
    public let kind: CommitmentEventKind
    public let occurredAt: Date

    public init(
        id: UUID = UUID(),
        commitmentID: UUID,
        kind: CommitmentEventKind,
        occurredAt: Date = .now
    ) {
        self.id = id
        self.commitmentID = commitmentID
        self.kind = kind
        self.occurredAt = occurredAt
    }
}

public enum CommitmentLifecycleState: String, Codable, Equatable, Sendable {
    case active
    case completed
    case retracted
}

public extension Commitment {
    var lifecycleState: CommitmentLifecycleState {
        guard let latest = (events ?? []).max(by: { $0.occurredAt < $1.occurredAt }) else {
            return .active
        }
        return switch latest.kind {
        case .completed: .completed
        case .reopened: .active
        case .retracted: .retracted
        }
    }

    var isActionable: Bool { lifecycleState == .active }

    mutating func record(_ kind: CommitmentEventKind, at date: Date = .now) {
        var history = events ?? []
        history.append(CommitmentEvent(commitmentID: id, kind: kind, occurredAt: date))
        events = history
        modifiedAt = date
    }
}

public enum FilterOperator: String, Codable, CaseIterable, Sendable {
    case equals
    case notEquals
    case containsAny
    case containsAll
    case excludes
    case exists
    case isUnknown
    case before
    case after
    case between
    case beforeRelativeDays
    case afterRelativeDays
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
}

public enum FilterValueKind: String, Codable, CaseIterable, Sendable {
    case string
    case strings
    case boolean
    case integer
    case number
    case uuid
    case uuids
    case instant
    case partialDate
    case dateRange
}

/// Filter values encode as ordinary JSON scalars/arrays where possible so a
/// saved view remains portable and inspectable.
public enum FilterValue: Hashable, Sendable {
    case string(String)
    case strings([String])
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case uuid(UUID)
    case uuids([UUID])
    case instant(Date)
    case partialDate(PartialDate)
    case dateRange(PartialDateRange)

    public var kind: FilterValueKind {
        switch self {
        case .string: .string
        case .strings: .strings
        case .boolean: .boolean
        case .integer: .integer
        case .number: .number
        case .uuid: .uuid
        case .uuids: .uuids
        case .instant: .instant
        case .partialDate: .partialDate
        case .dateRange: .dateRange
        }
    }
}

extension FilterValue: Codable {
    private enum ObjectKeys: String, CodingKey {
        case instant
        case precision
        case start
        case end
    }

    public init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: ObjectKeys.self) {
            if object.contains(.instant) {
                self = .instant(try object.decode(Date.self, forKey: .instant))
                return
            }
            if object.contains(.precision) {
                self = .partialDate(try PartialDate(from: decoder))
                return
            }
            if object.contains(.start) || object.contains(.end) {
                self = .dateRange(try PartialDateRange(from: decoder))
                return
            }
        }

        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = UUID(uuidString: value).map(Self.uuid) ?? .string(value)
        } else if let values = try? container.decode([String].self) {
            let ids = values.compactMap(UUID.init(uuidString:))
            self = ids.count == values.count ? .uuids(ids) : .strings(values)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported filter value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .strings(values):
            var container = encoder.singleValueContainer()
            try container.encode(values)
        case let .boolean(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .integer(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .uuid(value):
            var container = encoder.singleValueContainer()
            try container.encode(value.uuidString.lowercased())
        case let .uuids(values):
            var container = encoder.singleValueContainer()
            try container.encode(values.map { $0.uuidString.lowercased() })
        case let .instant(value):
            var container = encoder.container(keyedBy: ObjectKeys.self)
            try container.encode(value, forKey: .instant)
        case let .partialDate(value):
            try value.encode(to: encoder)
        case let .dateRange(value):
            try value.encode(to: encoder)
        }
    }
}

public struct FilterCondition: Codable, Hashable, Sendable {
    public let field: String
    public let `operator`: FilterOperator
    public let value: FilterValue?

    public init(field: String, operator: FilterOperator, value: FilterValue? = nil) {
        self.field = field
        self.operator = `operator`
        self.value = value
    }
}

public indirect enum FilterNode: Hashable, Sendable {
    case and([FilterNode])
    case or([FilterNode])
    case not(FilterNode)
    case condition(FilterCondition)
}

extension FilterNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case op
        case children
        case field
        case `operator`
        case value
    }

    private enum LogicalOperator: String, Codable {
        case and
        case or
        case not
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let operation = try container.decodeIfPresent(LogicalOperator.self, forKey: .op) {
            let children = try container.decode([FilterNode].self, forKey: .children)
            switch operation {
            case .and:
                self = .and(children)
            case .or:
                self = .or(children)
            case .not:
                guard children.count == 1 else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .children,
                        in: container,
                        debugDescription: "A not node requires exactly one child"
                    )
                }
                self = .not(children[0])
            }
            return
        }

        self = .condition(
            FilterCondition(
                field: try container.decode(String.self, forKey: .field),
                operator: try container.decode(FilterOperator.self, forKey: .operator),
                value: try container.decodeIfPresent(FilterValue.self, forKey: .value)
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .and(children):
            try container.encode(LogicalOperator.and, forKey: .op)
            try container.encode(children, forKey: .children)
        case let .or(children):
            try container.encode(LogicalOperator.or, forKey: .op)
            try container.encode(children, forKey: .children)
        case let .not(child):
            try container.encode(LogicalOperator.not, forKey: .op)
            try container.encode([child], forKey: .children)
        case let .condition(condition):
            try container.encode(condition.field, forKey: .field)
            try container.encode(condition.operator, forKey: .operator)
            try container.encodeIfPresent(condition.value, forKey: .value)
        }
    }
}

public struct FilterFieldDefinition: Codable, Hashable, Sendable {
    public let fieldID: String
    public let valueKinds: Set<FilterValueKind>
    public let allowedOperators: Set<FilterOperator>
    public let isSortable: Bool

    public init(
        fieldID: String,
        valueKinds: Set<FilterValueKind>,
        allowedOperators: Set<FilterOperator>,
        isSortable: Bool = false
    ) {
        self.fieldID = fieldID
        self.valueKinds = valueKinds
        self.allowedOperators = allowedOperators
        self.isSortable = isSortable
    }
}

public enum FilterValidationIssue: Equatable, Sendable {
    case emptyLogicalNode
    case unknownField(String)
    case unsupportedOperator(field: String, operator: FilterOperator)
    case missingValue(field: String, operator: FilterOperator)
    case unexpectedValue(field: String, operator: FilterOperator)
    case wrongValueKind(field: String, expected: Set<FilterValueKind>, actual: FilterValueKind)
    case unsupportedSortField(String)
}

public struct FilterSchema: Codable, Hashable, Sendable {
    public let fields: [String: FilterFieldDefinition]

    public init(
        additionalFields: [FilterFieldDefinition] = [],
        customAttributes: [AttributeDefinition] = []
    ) {
        var fields = Self.builtInFields.reduce(into: [String: FilterFieldDefinition]()) {
            $0[$1.fieldID] = $1
        }
        for field in additionalFields { fields[field.fieldID] = field }
        for attribute in customAttributes where attribute.capabilities.supportsFilter {
            let field = Self.field(for: attribute)
            fields[field.fieldID] = field
        }
        self.fields = fields
    }

    public func validate(_ node: FilterNode) -> [FilterValidationIssue] {
        switch node {
        case let .and(children), let .or(children):
            guard !children.isEmpty else { return [.emptyLogicalNode] }
            return children.flatMap(validate)
        case let .not(child):
            return validate(child)
        case let .condition(condition):
            return validate(condition)
        }
    }

    public func validate(sort: SortSpecification) -> [FilterValidationIssue] {
        guard fields[sort.field]?.isSortable == true else {
            return [.unsupportedSortField(sort.field)]
        }
        return []
    }

    private func validate(_ condition: FilterCondition) -> [FilterValidationIssue] {
        guard let field = fields[condition.field] else {
            return [.unknownField(condition.field)]
        }
        guard field.allowedOperators.contains(condition.operator) else {
            return [.unsupportedOperator(field: condition.field, operator: condition.operator)]
        }

        if condition.operator == .exists || condition.operator == .isUnknown {
            return condition.value == nil
                ? []
                : [.unexpectedValue(field: condition.field, operator: condition.operator)]
        }
        guard let value = condition.value else {
            return [.missingValue(field: condition.field, operator: condition.operator)]
        }

        let acceptedKinds: Set<FilterValueKind>
        switch condition.operator {
        case .beforeRelativeDays, .afterRelativeDays:
            acceptedKinds = [.integer]
        case .containsAny, .containsAll, .excludes:
            acceptedKinds = [.strings, .uuids]
        case .between:
            acceptedKinds = [.dateRange]
        default:
            acceptedKinds = field.valueKinds
        }
        guard acceptedKinds.contains(value.kind) else {
            return [.wrongValueKind(field: condition.field, expected: acceptedKinds, actual: value.kind)]
        }
        return []
    }

    private static let equality: Set<FilterOperator> = [.equals, .notEquals, .exists, .isUnknown]
    private static let setOperators: Set<FilterOperator> = equality.union([.containsAny, .containsAll, .excludes])
    private static let orderedOperators: Set<FilterOperator> = equality.union([
        .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual
    ])
    private static let dateOperators: Set<FilterOperator> = equality.union([
        .before, .after, .between, .beforeRelativeDays, .afterRelativeDays
    ])

    public static let builtInFields: [FilterFieldDefinition] = [
        .init(fieldID: "membership.context", valueKinds: [.uuid], allowedOperators: setOperators),
        .init(fieldID: "membership.cohort", valueKinds: [.uuid], allowedOperators: setOperators, isSortable: true),
        .init(fieldID: "membership.status", valueKinds: [.string], allowedOperators: setOperators),
        .init(fieldID: "cohort.relativePosition", valueKinds: [.string], allowedOperators: setOperators),
        .init(fieldID: "cohort.distance", valueKinds: [.integer], allowedOperators: orderedOperators),
        .init(fieldID: "role", valueKinds: [.uuid, .string], allowedOperators: setOperators),
        .init(fieldID: "education.status", valueKinds: [.string], allowedOperators: setOperators),
        .init(fieldID: "education.graduation", valueKinds: [.partialDate, .instant], allowedOperators: dateOperators, isSortable: true),
        .init(fieldID: "location", valueKinds: [.string], allowedOperators: setOperators),
        .init(fieldID: "timezone", valueKinds: [.string], allowedOperators: setOperators),
        .init(fieldID: "language", valueKinds: [.string], allowedOperators: setOperators),
        .init(fieldID: "channel", valueKinds: [.string], allowedOperators: setOperators),
        .init(fieldID: "relationship.circle", valueKinds: [.string], allowedOperators: setOperators),
        .init(fieldID: "tag", valueKinds: [.uuid, .string], allowedOperators: setOperators),
        .init(fieldID: "interaction.lastAt", valueKinds: [.instant, .partialDate], allowedOperators: dateOperators, isSortable: true),
        .init(fieldID: "cadence.nextDue", valueKinds: [.instant, .partialDate], allowedOperators: dateOperators, isSortable: true),
        .init(fieldID: "nudge.eligible", valueKinds: [.boolean], allowedOperators: equality),
        .init(fieldID: "source", valueKinds: [.uuid], allowedOperators: setOperators),
        .init(fieldID: "assertion.reviewStatus", valueKinds: [.string], allowedOperators: setOperators),
        .init(fieldID: "assertion.confidence", valueKinds: [.number], allowedOperators: orderedOperators),
        .init(fieldID: "assertion.sensitivity", valueKinds: [.string], allowedOperators: setOperators),
        .init(fieldID: "assertion.freshness", valueKinds: [.instant, .partialDate], allowedOperators: dateOperators),
        .init(fieldID: "person.name", valueKinds: [.string], allowedOperators: equality, isSortable: true),
        .init(fieldID: "person.createdAt", valueKinds: [.instant], allowedOperators: dateOperators, isSortable: true),
        .init(fieldID: "person.modifiedAt", valueKinds: [.instant], allowedOperators: dateOperators, isSortable: true)
    ]

    private static func field(for attribute: AttributeDefinition) -> FilterFieldDefinition {
        let kinds: Set<FilterValueKind>
        let operators: Set<FilterOperator>
        switch attribute.valueKind {
        case .boolean:
            kinds = [.boolean]
            operators = equality
        case .number:
            kinds = [.number]
            operators = orderedOperators
        case .partialDate:
            kinds = [.partialDate]
            operators = dateOperators
        case .dateRange:
            kinds = [.dateRange]
            operators = dateOperators
        case .singleSelect, .personReference, .contextReference, .mediaReference:
            kinds = [.uuid]
            operators = setOperators
        case .multiSelect:
            kinds = [.uuids]
            operators = setOperators
        default:
            kinds = [.string]
            operators = setOperators
        }
        return FilterFieldDefinition(
            fieldID: "attribute.\(attribute.predicateID)",
            valueKinds: kinds,
            allowedOperators: operators,
            isSortable: attribute.capabilities.supportsSort
        )
    }
}

public enum SortDirection: String, Codable, CaseIterable, Sendable {
    case ascending
    case descending
}

public enum UnknownValuePlacement: String, Codable, CaseIterable, Sendable {
    case first
    case last
}

public struct SortSpecification: Codable, Hashable, Sendable {
    public let field: String
    public let direction: SortDirection
    public let unknownPlacement: UnknownValuePlacement

    public init(
        field: String,
        direction: SortDirection = .ascending,
        unknownPlacement: UnknownValuePlacement = .last
    ) {
        self.field = field
        self.direction = direction
        self.unknownPlacement = unknownPlacement
    }
}

public struct SavedView: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public let filterVersion: Int
    public var filter: FilterNode
    public var sorts: [SortSpecification]
    public var isEligibleNudgePool: Bool
    public var archivedAt: Date?
    public var displayOrder: Int?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        name: String,
        filterVersion: Int = 1,
        filter: FilterNode,
        sorts: [SortSpecification] = [],
        isEligibleNudgePool: Bool = false,
        archivedAt: Date? = nil,
        displayOrder: Int? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.name = name
        self.filterVersion = filterVersion
        self.filter = filter
        self.sorts = sorts
        self.isEligibleNudgePool = isEligibleNudgePool
        self.archivedAt = archivedAt
        self.displayOrder = displayOrder
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }

    public func validationIssues(using schema: FilterSchema) -> [FilterValidationIssue] {
        schema.validate(filter) + sorts.flatMap(schema.validate(sort:))
    }

    public var isArchived: Bool { archivedAt != nil }
}
