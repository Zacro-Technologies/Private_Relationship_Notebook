import Foundation

/// Stable field identifiers used by the flattened `Person` search projection.
///
/// Callers may add `attribute.<predicateID>` fields through
/// `LocalSearchDocument.filterFields` and a matching `FilterSchema`.
public enum LocalSearchPersonField {
    public static let id = "person.id"
    public static let name = "person.name"
    public static let pronunciation = "person.pronunciation"
    public static let alias = "person.alias"
    public static let mentionableContext = "person.mentionableContext"
    public static let context = "membership.context"
    public static let cohort = "membership.cohort"
    public static let relativeCohortPosition = "cohort.relativePosition"
    public static let cohortDistance = "cohort.distance"
    public static let membershipStatus = "membership.status"
    public static let role = "role"
    public static let educationStatus = "education.status"
    public static let educationGraduation = "education.graduation"
    public static let source = "source"
    public static let assertionReviewStatus = "assertion.reviewStatus"
    public static let assertionConfidence = "assertion.confidence"
    public static let assertionSensitivity = "assertion.sensitivity"
    public static let assertionFreshness = "assertion.freshness"
    public static let location = "location"
    public static let timeZone = "timezone"
    public static let language = "language"
    public static let tag = "tag"
    public static let channel = "channel"
    public static let relationshipCircle = "relationship.circle"
    public static let cadenceDays = "person.cadenceDays"
    public static let priority = "person.priority"
    public static let createdAt = "person.createdAt"
    public static let modifiedAt = "person.modifiedAt"
    public static let lastInteractionAt = "interaction.lastAt"
    public static let nextCadenceDue = "cadence.nextDue"
    public static let snoozedUntil = "person.snoozedUntil"
    public static let isArchived = "person.isArchived"
    public static let neverSuggest = "person.neverSuggest"
    public static let doNotContact = "person.doNotContact"
    public static let nudgeEligible = "nudge.eligible"
    public static let isSelf = "person.isSelf"
}

public extension FilterSchema {
    /// The canonical filter schema augmented with fields available directly on
    /// the current flattened `Person` model.
    static var localSearchPerson: FilterSchema {
        localSearchPerson(customAttributes: [])
    }

    static func localSearchPerson(customAttributes: [AttributeDefinition]) -> FilterSchema {
        let equality: Set<FilterOperator> = [.equals, .notEquals, .exists, .isUnknown]
        let sets = equality.union([.containsAny, .containsAll, .excludes])
        let ordered = equality.union([
            .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual
        ])
        let dates = equality.union([
            .before, .after, .between, .beforeRelativeDays, .afterRelativeDays
        ])

        let projectedFields: [FilterFieldDefinition] = [
            .init(fieldID: LocalSearchPersonField.id, valueKinds: [.uuid], allowedOperators: equality),
            .init(fieldID: LocalSearchPersonField.name, valueKinds: [.string], allowedOperators: equality, isSortable: true),
            .init(fieldID: LocalSearchPersonField.pronunciation, valueKinds: [.string], allowedOperators: sets, isSortable: true),
            .init(fieldID: LocalSearchPersonField.alias, valueKinds: [.string], allowedOperators: sets),
            // The compact Person model currently stores context labels. A
            // canonical repository may additionally project context UUIDs.
            .init(fieldID: LocalSearchPersonField.context, valueKinds: [.string, .uuid], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.cohort, valueKinds: [.uuid], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.relativeCohortPosition, valueKinds: [.string], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.cohortDistance, valueKinds: [.integer], allowedOperators: ordered),
            .init(fieldID: LocalSearchPersonField.membershipStatus, valueKinds: [.string], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.role, valueKinds: [.string, .uuid], allowedOperators: sets, isSortable: true),
            .init(fieldID: LocalSearchPersonField.educationStatus, valueKinds: [.string], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.educationGraduation, valueKinds: [.partialDate, .instant], allowedOperators: dates, isSortable: true),
            .init(fieldID: LocalSearchPersonField.location, valueKinds: [.string], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.timeZone, valueKinds: [.string], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.language, valueKinds: [.string], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.tag, valueKinds: [.string, .uuid], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.channel, valueKinds: [.string], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.relationshipCircle, valueKinds: [.string], allowedOperators: sets, isSortable: true),
            .init(fieldID: LocalSearchPersonField.mentionableContext, valueKinds: [.string], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.cadenceDays, valueKinds: [.integer], allowedOperators: ordered, isSortable: true),
            .init(fieldID: LocalSearchPersonField.priority, valueKinds: [.integer], allowedOperators: ordered, isSortable: true),
            .init(fieldID: LocalSearchPersonField.createdAt, valueKinds: [.instant], allowedOperators: dates, isSortable: true),
            .init(fieldID: LocalSearchPersonField.modifiedAt, valueKinds: [.instant], allowedOperators: dates, isSortable: true),
            .init(fieldID: LocalSearchPersonField.lastInteractionAt, valueKinds: [.instant, .partialDate], allowedOperators: dates, isSortable: true),
            .init(fieldID: LocalSearchPersonField.nextCadenceDue, valueKinds: [.instant, .partialDate], allowedOperators: dates, isSortable: true),
            .init(fieldID: LocalSearchPersonField.snoozedUntil, valueKinds: [.instant], allowedOperators: dates, isSortable: true),
            .init(fieldID: LocalSearchPersonField.isArchived, valueKinds: [.boolean], allowedOperators: equality),
            .init(fieldID: LocalSearchPersonField.neverSuggest, valueKinds: [.boolean], allowedOperators: equality),
            .init(fieldID: LocalSearchPersonField.doNotContact, valueKinds: [.boolean], allowedOperators: equality),
            .init(fieldID: LocalSearchPersonField.nudgeEligible, valueKinds: [.boolean], allowedOperators: equality),
            .init(fieldID: LocalSearchPersonField.isSelf, valueKinds: [.boolean], allowedOperators: equality),
            .init(fieldID: LocalSearchPersonField.source, valueKinds: [.uuid], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.assertionReviewStatus, valueKinds: [.string], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.assertionConfidence, valueKinds: [.number], allowedOperators: ordered),
            .init(fieldID: LocalSearchPersonField.assertionSensitivity, valueKinds: [.string], allowedOperators: sets),
            .init(fieldID: LocalSearchPersonField.assertionFreshness, valueKinds: [.instant, .partialDate], allowedOperators: dates)
        ]

        // A custom field may intentionally support sorting without exposing a
        // filter control. `FilterSchema` normally discovers filter-capable
        // attributes, so add these sort-only definitions explicitly.
        let sortOnlyCustomFields = customAttributes.compactMap { attribute -> FilterFieldDefinition? in
            guard attribute.archivedAt == nil,
                  attribute.capabilities.supportsSort,
                  !attribute.capabilities.supportsFilter else { return nil }
            return FilterFieldDefinition(
                fieldID: "attribute.\(attribute.predicateID)",
                valueKinds: localSearchKinds(for: attribute.valueKind),
                allowedOperators: [],
                isSortable: true
            )
        }

        return FilterSchema(
            additionalFields: projectedFields + sortOnlyCustomFields,
            customAttributes: customAttributes.filter { $0.archivedAt == nil }
        )
    }

    private static func localSearchKinds(for kind: AttributeValueKind) -> Set<FilterValueKind> {
        switch kind {
        case .boolean: [.boolean]
        case .number: [.number]
        case .partialDate: [.partialDate]
        case .dateRange: [.dateRange]
        case .singleSelect, .personReference, .contextReference, .mediaReference: [.uuid]
        case .multiSelect: [.uuids]
        default: [.string]
        }
    }
}

/// A user-approved text field stored in the local-only derived index.
///
/// Its value is intentionally absent from `LocalSearchMatchReason`, preventing
/// accidental sensitive snippets from crossing the index API boundary.
public struct LocalSearchTextField: Codable, Hashable, Sendable {
    public let fieldID: String
    public let value: String
    public let sensitivity: Sensitivity

    public init(
        fieldID: String,
        value: String,
        sensitivity: Sensitivity = .private
    ) {
        self.fieldID = fieldID
        self.value = value
        self.sensitivity = sensitivity
    }
}

/// A rebuildable search projection. It is derived data, never canonical data.
public struct LocalSearchDocument: Codable, Hashable, Sendable, Identifiable {
    public let person: Person
    public let searchableFields: [LocalSearchTextField]
    public let filterFields: [String: [FilterValue]]

    public var id: UUID { person.id }

    public init(
        person: Person,
        additionalSearchableFields: [LocalSearchTextField] = [],
        filterFields: [String: [FilterValue]] = [:]
    ) {
        self.person = person
        self.searchableFields = Self.personTextFields(person) + additionalSearchableFields
        self.filterFields = filterFields
    }

    private init(
        person: Person,
        searchableFields: [LocalSearchTextField],
        filterFields: [String: [FilterValue]]
    ) {
        self.person = person
        self.searchableFields = searchableFields
        self.filterFields = filterFields
    }

    private static func personTextFields(_ person: Person) -> [LocalSearchTextField] {
        var fields = [LocalSearchTextField(
            fieldID: LocalSearchPersonField.name,
            value: person.displayName,
            sensitivity: .private
        )]
        fields.append(.init(
            fieldID: LocalSearchPersonField.pronunciation,
            value: person.pronunciation,
            sensitivity: .private
        ))
        fields += person.aliases.map {
            .init(fieldID: LocalSearchPersonField.alias, value: $0, sensitivity: .private)
        }
        fields += (person.nameVariants ?? []).flatMap { variant in
            [variant.fullName, variant.givenName, variant.familyName]
                .compactMap { $0 }
                .map { .init(
                    fieldID: LocalSearchPersonField.alias,
                    value: $0,
                    sensitivity: .private
                ) }
        }
        fields += person.contexts.map {
            .init(fieldID: LocalSearchPersonField.context, value: $0, sensitivity: .private)
        }
        fields.append(.init(fieldID: LocalSearchPersonField.role, value: person.role, sensitivity: .private))
        fields += person.tags.map {
            .init(fieldID: LocalSearchPersonField.tag, value: $0, sensitivity: .private)
        }
        fields.append(.init(
            fieldID: LocalSearchPersonField.mentionableContext,
            value: person.mentionableContext,
            sensitivity: .private
        ))
        return fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case person
        case searchableFields
        case filterFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            person: try container.decode(Person.self, forKey: .person),
            searchableFields: try container.decode([LocalSearchTextField].self, forKey: .searchableFields),
            filterFields: try container.decode([String: [FilterValue]].self, forKey: .filterFields)
        )
    }
}

/// Builds the rebuildable search projection from the canonical vault without copying private
/// values into match reasons. Assertion values enter full-text search only after both their
/// review state and explicit search-use policy allow it.
public struct CanonicalLocalSearchProjection: Sendable {
    public init() {}

    public func documents(
        people: [Person],
        canonical: CanonicalArchivePayload,
        localeIdentifier: String = Locale.current.identifier
    ) -> [LocalSearchDocument] {
        let languageTags = [localeIdentifier]
        let contextByID = Dictionary(
            canonical.contexts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let cohortByID = Dictionary(
            canonical.cohorts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let roleDefinitionByID = Dictionary(
            canonical.roleDefinitions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let definitionByPredicate = Dictionary(
            canonical.attributeDefinitions.map { ($0.predicateID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let membershipsByPerson = Dictionary(grouping: canonical.memberships, by: \.personID)
        let assignmentsByMembership = Dictionary(grouping: canonical.cohortAssignments, by: \.membershipEpisodeID)
        let rolesByMembership = Dictionary(grouping: canonical.roleAssignments, by: \.membershipEpisodeID)
        let educationByPerson = Dictionary(grouping: canonical.education, by: \.personID)
        let assertionsByPerson = Dictionary(grouping: canonical.assertions, by: \.subjectID)
        let selfPersonID = people.first(where: {
            $0.isSelf && $0.deletedAt == nil && $0.mergedIntoPersonID == nil
        })?.id
        let relativeCalculator = RelativeCohortCalculator()

        return people.map { person in
            var searchable: [LocalSearchTextField] = []
            var filters: [String: [FilterValue]] = [:]

            func addSearch(_ fieldID: String, _ value: String, sensitivity: Sensitivity = .private) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                searchable.append(.init(fieldID: fieldID, value: trimmed, sensitivity: sensitivity))
            }
            func addFilter(_ fieldID: String, _ value: FilterValue) {
                filters[fieldID, default: []].append(value)
            }

            for membership in membershipsByPerson[person.id] ?? [] {
                addFilter(LocalSearchPersonField.context, .uuid(membership.contextID))
                addFilter(LocalSearchPersonField.membershipStatus, .string(membership.status.rawValue))
                if let context = contextByID[membership.contextID] {
                    let name = context.names.resolved(preferredLanguageTags: languageTags)
                    addSearch(LocalSearchPersonField.context, name)
                    addFilter(LocalSearchPersonField.context, .string(name))
                }

                for assignment in assignmentsByMembership[membership.id] ?? [] {
                    addFilter(LocalSearchPersonField.cohort, .uuid(assignment.cohortID))
                    if let cohort = cohortByID[assignment.cohortID] {
                        addSearch(
                            LocalSearchPersonField.cohort,
                            cohort.labels.resolved(preferredLanguageTags: languageTags)
                        )
                    }
                }

                for role in rolesByMembership[membership.id] ?? [] {
                    let label: String
                    if let definitionID = role.roleDefinitionID,
                       let definition = roleDefinitionByID[definitionID] {
                        addFilter(LocalSearchPersonField.role, .uuid(definitionID))
                        label = definition.labels.resolved(preferredLanguageTags: languageTags)
                    } else {
                        label = role.roleLabel.resolved(preferredLanguageTags: languageTags)
                    }
                    addSearch(LocalSearchPersonField.role, label)
                    addFilter(LocalSearchPersonField.role, .string(label))
                }
            }

            if let selfPersonID {
                for scheme in canonical.cohortSchemes where
                    scheme.archivedAt == nil && scheme.orderingMethod == .chronologicalRank {
                    let result = relativeCalculator.relativePosition(
                        subject: person.id,
                        observer: selfPersonID,
                        context: scheme.contextID,
                        scheme: scheme.id,
                        asOf: .now,
                        schemes: canonical.cohortSchemes,
                        cohorts: canonical.cohorts,
                        memberships: canonical.memberships,
                        assignments: canonical.cohortAssignments
                    )
                    guard result.position != .unknown else { continue }
                    addFilter(
                        LocalSearchPersonField.relativeCohortPosition,
                        .string(result.position.rawValue)
                    )
                    if let distance = result.cohortDistance {
                        addFilter(LocalSearchPersonField.cohortDistance, .integer(distance))
                    }
                }
            }

            addFilter(LocalSearchPersonField.isSelf, .boolean(person.isSelf))

            for enrollment in educationByPerson[person.id] ?? [] {
                addFilter(LocalSearchPersonField.context, .uuid(enrollment.institutionContextID))
                addFilter(LocalSearchPersonField.educationStatus, .string(enrollment.status.rawValue))
                if let actualGraduation = enrollment.actualGraduation {
                    addFilter(LocalSearchPersonField.educationGraduation, .partialDate(actualGraduation))
                }
                if let institution = contextByID[enrollment.institutionContextID] {
                    let institutionName = institution.names.resolved(preferredLanguageTags: languageTags)
                    addSearch(LocalSearchPersonField.context, institutionName)
                    addFilter(LocalSearchPersonField.context, .string(institutionName))
                }
                if let program = enrollment.program {
                    addSearch(LocalSearchPersonField.role, program.resolved(preferredLanguageTags: languageTags))
                }
                if let degree = enrollment.degree {
                    addSearch(LocalSearchPersonField.role, degree.resolved(preferredLanguageTags: languageTags))
                }
            }

            for assertion in assertionsByPerson[person.id] ?? [] {
                addFilter(LocalSearchPersonField.assertionReviewStatus, .string(assertion.reviewStatus.rawValue))
                addFilter(LocalSearchPersonField.assertionSensitivity, .string(assertion.sensitivity.rawValue))
                addFilter(LocalSearchPersonField.assertionFreshness, .instant(assertion.assertedAt))
                if let confidence = assertion.confidence {
                    addFilter(LocalSearchPersonField.assertionConfidence, .number(confidence))
                }
                if let sourceID = assertion.sourceID {
                    addFilter(LocalSearchPersonField.source, .uuid(sourceID))
                }

                guard assertion.reviewStatus == .accepted,
                      assertion.usePolicy.search == .include else { continue }
                let customFieldID = "attribute.\(assertion.predicateID)"
                if definitionByPredicate[assertion.predicateID]?.capabilities.supportsSearch != false,
                   let text = searchableText(
                       assertion.value,
                       people: people,
                       contexts: contextByID,
                       languageTags: languageTags
                   ) {
                    addSearch(customFieldID, text, sensitivity: assertion.sensitivity)
                }
                if let definition = definitionByPredicate[assertion.predicateID],
                   definition.archivedAt == nil,
                   (definition.capabilities.supportsFilter || definition.capabilities.supportsSort),
                   let value = filterValue(assertion.value) {
                    addFilter(customFieldID, value)
                }

                switch assertion.value {
                case .language(let value):
                    addFilter(LocalSearchPersonField.language, .string(value))
                case .location(let value):
                    addFilter(LocalSearchPersonField.location, .string(value.label))
                    if let timeZone = value.timeZoneIdentifier {
                        addFilter(LocalSearchPersonField.timeZone, .string(timeZone))
                    }
                case .address(let value):
                    for location in [value.locality, value.administrativeArea, value.countryCode].compactMap({ $0 }) {
                        addFilter(LocalSearchPersonField.location, .string(location))
                    }
                default:
                    break
                }
            }

            return LocalSearchDocument(
                person: person,
                additionalSearchableFields: searchable,
                filterFields: filters
            )
        }
    }

    private func searchableText(
        _ value: TypedValue,
        people: [Person],
        contexts: [UUID: Context],
        languageTags: [String]
    ) -> String? {
        switch value {
        case .text(let value), .richText(let value), .language(let value),
             .email(let value), .phone(let value):
            value
        case .url(let value):
            value.absoluteString
        case .location(let value):
            value.label
        case .address(let value):
            [value.street, value.locality, value.administrativeArea, value.postalCode, value.countryCode]
                .compactMap { $0 }
                .joined(separator: " ")
        case .personReference(let id):
            people.first { $0.id == id }?.displayName
        case .contextReference(let id):
            contexts[id]?.names.resolved(preferredLanguageTags: languageTags)
        case .boolean, .number, .partialDate, .dateRange, .singleSelect, .multiSelect,
             .mediaReference, .structuredJSON:
            nil
        }
    }

    private func filterValue(_ value: TypedValue) -> FilterValue? {
        switch value {
        case .text(let value), .richText(let value), .language(let value),
             .email(let value), .phone(let value):
            .string(value)
        case .boolean(let value):
            .boolean(value)
        case .number(let value):
            .number(NSDecimalNumber(decimal: value.value).doubleValue)
        case .partialDate(let value):
            .partialDate(value)
        case .dateRange(let value):
            .dateRange(value)
        case .singleSelect(let value), .personReference(let value),
             .contextReference(let value), .mediaReference(let value):
            .uuid(value)
        case .multiSelect(let values):
            .uuids(values)
        case .url(let value):
            .string(value.absoluteString)
        case .location(let value):
            .string(value.label)
        case .address(let value):
            .string([value.street, value.locality, value.administrativeArea, value.postalCode, value.countryCode]
                .compactMap { $0 }
                .joined(separator: " "))
        case .structuredJSON:
            nil
        }
    }
}

public enum LocalSearchTextMatchMode: String, Codable, CaseIterable, Sendable {
    case contains
    case prefix
    case exact
    /// Every whitespace/punctuation-delimited term must match at least one field.
    case allTerms
}

public struct LocalSearchQuery: Codable, Hashable, Sendable {
    public var text: String?
    public var textMatchMode: LocalSearchTextMatchMode
    public var filterVersion: Int
    public var filter: FilterNode?
    public var sorts: [SortSpecification]
    public var includeArchived: Bool
    /// Fixed at query construction so relative-date filters and cursors remain deterministic.
    public var referenceDate: Date
    public var localeIdentifier: String

    public init(
        text: String? = nil,
        textMatchMode: LocalSearchTextMatchMode = .contains,
        filterVersion: Int = 1,
        filter: FilterNode? = nil,
        sorts: [SortSpecification] = [],
        includeArchived: Bool = false,
        referenceDate: Date = .now,
        localeIdentifier: String = Locale.current.identifier
    ) {
        self.text = text
        self.textMatchMode = textMatchMode
        self.filterVersion = filterVersion
        self.filter = filter
        self.sorts = sorts
        self.includeArchived = includeArchived
        self.referenceDate = referenceDate
        self.localeIdentifier = localeIdentifier
    }

    public init(
        savedView: SavedView,
        text: String? = nil,
        textMatchMode: LocalSearchTextMatchMode = .contains,
        includeArchived: Bool = false,
        referenceDate: Date = .now,
        localeIdentifier: String = Locale.current.identifier
    ) {
        self.init(
            text: text,
            textMatchMode: textMatchMode,
            filterVersion: savedView.filterVersion,
            filter: savedView.filter,
            sorts: savedView.sorts,
            includeArchived: includeArchived,
            referenceDate: referenceDate,
            localeIdentifier: localeIdentifier
        )
    }
}

public enum LocalSearchMatchReasonKind: String, Codable, CaseIterable, Sendable {
    case exactText
    case prefixText
    case containsText
    case filter
    case filterExclusion
}

/// Explains a match without containing the query, indexed value, or a snippet.
public struct LocalSearchMatchReason: Codable, Hashable, Sendable {
    public let fieldID: String
    public let kind: LocalSearchMatchReasonKind
    public let sensitivity: Sensitivity

    public init(
        fieldID: String,
        kind: LocalSearchMatchReasonKind,
        sensitivity: Sensitivity = .private
    ) {
        self.fieldID = fieldID
        self.kind = kind
        self.sensitivity = sensitivity
    }
}

/// Search returns IDs so authorization and current canonical values can be
/// re-fetched before display. No indexed content is returned in a hit.
public struct LocalSearchHit: Codable, Hashable, Sendable, Identifiable {
    public let personID: UUID
    public let matchReasons: [LocalSearchMatchReason]

    public var id: UUID { personID }

    public init(personID: UUID, matchReasons: [LocalSearchMatchReason]) {
        self.personID = personID
        self.matchReasons = matchReasons
    }
}

public struct LocalSearchCursor: Codable, Hashable, Sendable {
    let generation: UInt64
    let querySignature: String
    let offset: Int

    init(generation: UInt64, querySignature: String, offset: Int) {
        self.generation = generation
        self.querySignature = querySignature
        self.offset = offset
    }
}

public struct LocalSearchPageRequest: Codable, Hashable, Sendable {
    public let limit: Int
    public let cursor: LocalSearchCursor?

    public init(limit: Int = 50, cursor: LocalSearchCursor? = nil) {
        self.limit = limit
        self.cursor = cursor
    }
}

public struct LocalSearchPage: Codable, Hashable, Sendable {
    public let hits: [LocalSearchHit]
    public let totalCount: Int
    public let nextCursor: LocalSearchCursor?
    public let indexGeneration: UInt64

    public init(
        hits: [LocalSearchHit],
        totalCount: Int,
        nextCursor: LocalSearchCursor?,
        indexGeneration: UInt64
    ) {
        self.hits = hits
        self.totalCount = totalCount
        self.nextCursor = nextCursor
        self.indexGeneration = indexGeneration
    }
}

public struct LocalSearchIndexMetadata: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generation: UInt64
    public let documentCount: Int
    public let updatedAt: Date

    public init(
        schemaVersion: Int,
        generation: UInt64,
        documentCount: Int,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.documentCount = documentCount
        self.updatedAt = updatedAt
    }
}

public enum LocalSearchRebuildReason: Codable, Hashable, Sendable {
    case schemaVersion(expected: Int, actual: Int)
    case checksum
    case duplicatePerson(UUID)
}

public enum LocalSearchRestoreOutcome: Codable, Hashable, Sendable {
    case empty
    case restored(LocalSearchIndexMetadata)
    case rebuildRequired(LocalSearchRebuildReason)
}

public enum LocalSearchError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedFilterVersion(Int)
    case invalidQuery([FilterValidationIssue])
    case negativeRelativeDayCount(Int)
    case invalidPageLimit(Int)
    case invalidRebuildBatchSize(Int)
    case rebuildPageTooLarge(actual: Int, limit: Int)
    case duplicatePersonInRebuild(UUID)
    case rebuildCursorDidNotAdvance
    case cursorDoesNotMatchQuery
    case staleCursor
    case invalidCursor
    case unknownRebuildSession
    case encodingFailure

    public var errorDescription: String? {
        switch self {
        case .unsupportedFilterVersion:
            String(localized: "This saved view uses a newer filter format. Update the app or edit the view.")
        case .invalidQuery:
            String(localized: "One or more filters or sort choices are no longer supported. Review the current filters.")
        case .negativeRelativeDayCount:
            String(localized: "A relative-date filter must use zero or more days.")
        case .invalidPageLimit, .invalidCursor:
            String(localized: "Search could not load this result page. Try the search again.")
        case .invalidRebuildBatchSize, .rebuildPageTooLarge:
            String(localized: "The offline search index could not be rebuilt in a safe batch size.")
        case .duplicatePersonInRebuild:
            String(localized: "The offline search index found a duplicate person identifier and stopped safely.")
        case .rebuildCursorDidNotAdvance, .unknownRebuildSession:
            String(localized: "The offline search index rebuild could not continue. Reopen People to try again.")
        case .cursorDoesNotMatchQuery, .staleCursor:
            String(localized: "The notebook changed while results were loading. Run the search again.")
        case .encodingFailure:
            String(localized: "The offline search index could not safely encode its local cache.")
        }
    }
}

public struct LocalSearchRebuildCursor: Codable, Hashable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

public struct LocalSearchRebuildPage: Codable, Hashable, Sendable {
    public let documents: [LocalSearchDocument]
    public let nextCursor: LocalSearchRebuildCursor?
    public let totalCount: Int?

    public init(
        documents: [LocalSearchDocument],
        nextCursor: LocalSearchRebuildCursor?,
        totalCount: Int? = nil
    ) {
        self.documents = documents
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }
}

public struct LocalSearchRebuildProgress: Codable, Hashable, Sendable {
    public let indexedCount: Int
    public let totalCount: Int?
    public let fractionCompleted: Double?

    public init(indexedCount: Int, totalCount: Int?) {
        self.indexedCount = indexedCount
        self.totalCount = totalCount
        if let totalCount, totalCount > 0 {
            self.fractionCompleted = min(1, Double(indexedCount) / Double(totalCount))
        } else if totalCount == 0 {
            self.fractionCompleted = 1
        } else {
            self.fractionCompleted = nil
        }
    }
}

/// Canonical repositories implement this page-by-page; the search layer never
/// requires a full-vault array for rebuilds.
public protocol LocalSearchRebuildSource: Sendable {
    func fetchPage(
        after cursor: LocalSearchRebuildCursor?,
        limit: Int
    ) async throws -> LocalSearchRebuildPage
}

/// Convenient bounded source for tests, previews, and small imports.
public struct CollectionLocalSearchRebuildSource: LocalSearchRebuildSource {
    private let documents: [LocalSearchDocument]

    public init(documents: [LocalSearchDocument]) {
        self.documents = documents
    }

    public init(people: [Person]) {
        self.documents = people.map { LocalSearchDocument(person: $0) }
    }

    public func fetchPage(
        after cursor: LocalSearchRebuildCursor?,
        limit: Int
    ) async throws -> LocalSearchRebuildPage {
        let offset: Int
        if let cursor {
            guard let decoded = Int(cursor.token), decoded >= 0, decoded <= documents.count else {
                throw LocalSearchError.invalidCursor
            }
            offset = decoded
        } else {
            offset = 0
        }
        let end = min(documents.count, offset + max(0, limit))
        let page = Array(documents[offset..<end])
        let next = end < documents.count
            ? LocalSearchRebuildCursor(token: String(end))
            : nil
        return LocalSearchRebuildPage(
            documents: page,
            nextCursor: next,
            totalCount: documents.count
        )
    }
}

public struct LocalSearchIndexMutation: Sendable {
    public let upserts: [LocalSearchDocument]
    public let removals: Set<UUID>

    public init(
        upserts: [LocalSearchDocument] = [],
        removals: Set<UUID> = []
    ) {
        self.upserts = upserts
        self.removals = removals
    }
}

/// A backend boundary suitable for a persistent SQLite/FTS implementation.
/// Rebuild sessions stage batches and commit atomically while the old index
/// remains searchable.
public protocol LocalSearchIndexBackend: Sendable {
    func restore() async throws -> LocalSearchRestoreOutcome
    func metadata() async -> LocalSearchIndexMetadata
    func search(_ query: LocalSearchQuery, page: LocalSearchPageRequest) async throws -> LocalSearchPage
    func apply(_ mutation: LocalSearchIndexMutation) async throws
    func beginRebuild() async throws -> UUID
    func append(_ documents: [LocalSearchDocument], to rebuildID: UUID) async throws
    func commitRebuild(_ rebuildID: UUID) async throws -> LocalSearchIndexMetadata
    func abandonRebuild(_ rebuildID: UUID) async
}
