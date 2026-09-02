import Foundation

enum LocalSearchEvaluator {
    private struct Candidate {
        let document: LocalSearchDocument
        let fields: [String: [FilterValue]]
        let reasons: [LocalSearchMatchReason]
    }

    private struct FilterEvaluation {
        let matches: Bool
        let reasons: [LocalSearchMatchReason]
    }

    private struct DateIntervalValue {
        let lower: Date
        let upper: Date

        func overlaps(_ other: DateIntervalValue) -> Bool {
            lower <= other.upper && other.lower <= upper
        }
    }

    private enum SetAtom: Hashable {
        case string(String)
        case uuid(UUID)
    }

    private enum SortableValue {
        case string(String)
        case number(Double)
        case date(Date)
        case boolean(Bool)
        case uuid(String)

        var typeOrder: Int {
            switch self {
            case .string: 0
            case .number: 1
            case .date: 2
            case .boolean: 3
            case .uuid: 4
            }
        }
    }

    static func search(
        documents: [LocalSearchDocument],
        generation: UInt64,
        query: LocalSearchQuery,
        page: LocalSearchPageRequest
    ) throws -> LocalSearchPage {
        let signature = try LocalSearchStableEncoding.querySignature(query)
        let offset: Int
        if let cursor = page.cursor {
            guard cursor.querySignature == signature else {
                throw LocalSearchError.cursorDoesNotMatchQuery
            }
            guard cursor.generation == generation else {
                throw LocalSearchError.staleCursor
            }
            guard cursor.offset >= 0 else { throw LocalSearchError.invalidCursor }
            offset = cursor.offset
        } else {
            offset = 0
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(documents.count)
        for document in documents {
            let person = document.person
            // Deleted/merged records never reappear from a stale derived index.
            guard person.deletedAt == nil, person.mergedIntoPersonID == nil else { continue }
            guard query.includeArchived || !person.isArchived else { continue }

            let textResult = textEvaluation(document: document, query: query)
            guard textResult.matches else { continue }
            let fields = fieldValues(for: document, referenceDate: query.referenceDate)
            let filterResult: FilterEvaluation
            if let filter = query.filter {
                filterResult = evaluate(
                    filter,
                    fields: fields,
                    document: document,
                    referenceDate: query.referenceDate
                )
            } else {
                filterResult = FilterEvaluation(matches: true, reasons: [])
            }
            guard filterResult.matches else { continue }
            candidates.append(Candidate(
                document: document,
                fields: fields,
                reasons: deduplicatedReasons(textResult.reasons + filterResult.reasons)
            ))
        }

        let locale = Locale(identifier: query.localeIdentifier)
        let sorts = query.sorts.isEmpty
            ? [SortSpecification(field: LocalSearchPersonField.name)]
            : query.sorts
        candidates.sort { lhs, rhs in
            compare(lhs, rhs, sorts: sorts, locale: locale) == .orderedAscending
        }

        guard offset <= candidates.count else { throw LocalSearchError.invalidCursor }
        let end = min(candidates.count, offset + page.limit)
        let hits = candidates[offset..<end].map {
            LocalSearchHit(personID: $0.document.id, matchReasons: $0.reasons)
        }
        let nextCursor = end < candidates.count
            ? LocalSearchCursor(
                generation: generation,
                querySignature: signature,
                offset: end
            )
            : nil
        return LocalSearchPage(
            hits: Array(hits),
            totalCount: candidates.count,
            nextCursor: nextCursor,
            indexGeneration: generation
        )
    }

    // MARK: - Text matching

    private static func textEvaluation(
        document: LocalSearchDocument,
        query: LocalSearchQuery
    ) -> FilterEvaluation {
        guard let rawQuery = query.text else {
            return FilterEvaluation(matches: true, reasons: [])
        }
        let normalizedWhole = normalizedText(rawQuery)
        guard !normalizedWhole.isEmpty else {
            return FilterEvaluation(matches: true, reasons: [])
        }

        if query.textMatchMode == .allTerms {
            let terms = searchTerms(rawQuery)
            var reasons: [LocalSearchMatchReason] = []
            for term in terms {
                var termMatched = false
                for field in document.searchableFields {
                    let haystack = normalizedText(field.value)
                    guard haystack.contains(term) else { continue }
                    termMatched = true
                    reasons.append(LocalSearchMatchReason(
                        fieldID: field.fieldID,
                        kind: textReasonKind(haystack: haystack, needle: term),
                        sensitivity: field.sensitivity
                    ))
                }
                guard termMatched else {
                    return FilterEvaluation(matches: false, reasons: [])
                }
            }
            return FilterEvaluation(matches: true, reasons: deduplicatedReasons(reasons))
        }

        var reasons: [LocalSearchMatchReason] = []
        for field in document.searchableFields {
            let haystack = normalizedText(field.value)
            let matches: Bool
            switch query.textMatchMode {
            case .contains:
                matches = haystack.contains(normalizedWhole)
            case .prefix:
                matches = haystack.hasPrefix(normalizedWhole)
            case .exact:
                matches = haystack == normalizedWhole
            case .allTerms:
                matches = false
            }
            if matches {
                reasons.append(LocalSearchMatchReason(
                    fieldID: field.fieldID,
                    kind: textReasonKind(haystack: haystack, needle: normalizedWhole),
                    sensitivity: field.sensitivity
                ))
            }
        }
        return FilterEvaluation(
            matches: !reasons.isEmpty,
            reasons: deduplicatedReasons(reasons)
        )
    }

    /// Uses the existing product normalizer first, then folds Katakana into
    /// Hiragana so stored readings remain display-faithful but script-tolerant.
    private static func normalizedText(_ value: String) -> String {
        let base = SearchNormalizer.normalize(value)
        let scalars = base.unicodeScalars.map { scalar -> UnicodeScalar in
            let value = scalar.value
            if (0x30A1...0x30F6).contains(value),
               let hiragana = UnicodeScalar(value - 0x60) {
                return hiragana
            }
            return scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func searchTerms(_ value: String) -> [String] {
        var separators = CharacterSet.whitespacesAndNewlines
        separators.formUnion(.punctuationCharacters)
        separators.formUnion(.symbols)
        let terms = value
            .components(separatedBy: separators)
            .map(normalizedText)
            .filter { !$0.isEmpty }
        return terms.isEmpty ? [normalizedText(value)] : terms
    }

    private static func textReasonKind(
        haystack: String,
        needle: String
    ) -> LocalSearchMatchReasonKind {
        if haystack == needle { return .exactText }
        if haystack.hasPrefix(needle) { return .prefixText }
        return .containsText
    }

    // MARK: - Flattened fields

    private static func fieldValues(
        for document: LocalSearchDocument,
        referenceDate: Date
    ) -> [String: [FilterValue]] {
        let person = document.person
        var fields = document.filterFields

        append(.uuid(person.id), to: LocalSearchPersonField.id, fields: &fields)
        appendNonempty(.string(person.displayName), to: LocalSearchPersonField.name, fields: &fields)
        appendNonempty(.string(person.pronunciation), to: LocalSearchPersonField.pronunciation, fields: &fields)
        for alias in person.aliases {
            appendNonempty(.string(alias), to: LocalSearchPersonField.alias, fields: &fields)
        }
        for variant in person.nameVariants ?? [] {
            appendNonempty(.string(variant.fullName), to: LocalSearchPersonField.alias, fields: &fields)
            if let givenName = variant.givenName {
                appendNonempty(.string(givenName), to: LocalSearchPersonField.alias, fields: &fields)
            }
            if let familyName = variant.familyName {
                appendNonempty(.string(familyName), to: LocalSearchPersonField.alias, fields: &fields)
            }
        }
        for context in person.contexts {
            appendNonempty(.string(context), to: LocalSearchPersonField.context, fields: &fields)
        }
        appendNonempty(.string(person.role), to: LocalSearchPersonField.role, fields: &fields)
        for tag in person.tags {
            appendNonempty(.string(tag), to: LocalSearchPersonField.tag, fields: &fields)
        }
        appendNonempty(
            .string(person.mentionableContext),
            to: LocalSearchPersonField.mentionableContext,
            fields: &fields
        )
        for contact in person.contacts {
            append(.string(contact.kind.rawValue), to: LocalSearchPersonField.channel, fields: &fields)
        }
        append(.string(person.circle.rawValue), to: LocalSearchPersonField.relationshipCircle, fields: &fields)
        append(.integer(person.cadenceDays), to: LocalSearchPersonField.cadenceDays, fields: &fields)
        append(.integer(person.priority), to: LocalSearchPersonField.priority, fields: &fields)
        append(.instant(person.createdAt), to: LocalSearchPersonField.createdAt, fields: &fields)
        append(.instant(person.modifiedAt), to: LocalSearchPersonField.modifiedAt, fields: &fields)
        if let lastInteractionAt = person.lastInteractionAt {
            append(.instant(lastInteractionAt), to: LocalSearchPersonField.lastInteractionAt, fields: &fields)
        }
        if let snoozedUntil = person.snoozedUntil {
            append(.instant(snoozedUntil), to: LocalSearchPersonField.snoozedUntil, fields: &fields)
        }
        if let nextDue = addingDays(
            person.cadenceDays,
            to: person.lastInteractionAt ?? person.createdAt
        ) {
            append(.instant(nextDue), to: LocalSearchPersonField.nextCadenceDue, fields: &fields)
        }
        append(.boolean(person.isArchived), to: LocalSearchPersonField.isArchived, fields: &fields)
        append(.boolean(person.neverSuggest), to: LocalSearchPersonField.neverSuggest, fields: &fields)
        append(.boolean(person.doNotContact), to: LocalSearchPersonField.doNotContact, fields: &fields)
        let eligible = !person.isArchived && !person.neverSuggest && !person.doNotContact &&
            person.deletedAt == nil && person.mergedIntoPersonID == nil &&
            (person.snoozedUntil == nil || person.snoozedUntil! <= referenceDate)
        append(.boolean(eligible), to: LocalSearchPersonField.nudgeEligible, fields: &fields)
        append(.boolean(person.isSelf), to: LocalSearchPersonField.isSelf, fields: &fields)
        return fields
    }

    private static func append(
        _ value: FilterValue,
        to field: String,
        fields: inout [String: [FilterValue]]
    ) {
        fields[field, default: []].append(value)
    }

    private static func appendNonempty(
        _ value: FilterValue,
        to field: String,
        fields: inout [String: [FilterValue]]
    ) {
        if case let .string(string) = value,
           normalizedText(string).isEmpty {
            return
        }
        append(value, to: field, fields: &fields)
    }

    private static func addingDays(_ days: Int, to date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .day, value: days, to: date)
    }

    // MARK: - Filter AST

    private static func evaluate(
        _ node: FilterNode,
        fields: [String: [FilterValue]],
        document: LocalSearchDocument,
        referenceDate: Date
    ) -> FilterEvaluation {
        switch node {
        case let .and(children):
            var reasons: [LocalSearchMatchReason] = []
            for child in children {
                let result = evaluate(
                    child,
                    fields: fields,
                    document: document,
                    referenceDate: referenceDate
                )
                guard result.matches else {
                    return FilterEvaluation(matches: false, reasons: [])
                }
                reasons += result.reasons
            }
            return FilterEvaluation(matches: true, reasons: deduplicatedReasons(reasons))

        case let .or(children):
            let matching = children.map {
                evaluate(
                    $0,
                    fields: fields,
                    document: document,
                    referenceDate: referenceDate
                )
            }.filter(\.matches)
            return FilterEvaluation(
                matches: !matching.isEmpty,
                reasons: deduplicatedReasons(matching.flatMap(\.reasons))
            )

        case let .not(child):
            let childResult = evaluate(
                child,
                fields: fields,
                document: document,
                referenceDate: referenceDate
            )
            guard !childResult.matches else {
                return FilterEvaluation(matches: false, reasons: [])
            }
            let reasons = referencedFields(in: child).map {
                LocalSearchMatchReason(
                    fieldID: $0,
                    kind: .filterExclusion,
                    sensitivity: sensitivity(for: $0, document: document)
                )
            }
            return FilterEvaluation(matches: true, reasons: deduplicatedReasons(reasons))

        case let .condition(condition):
            let values = fields[condition.field] ?? []
            let matches = conditionMatches(
                condition,
                candidateValues: values,
                referenceDate: referenceDate
            )
            guard matches else { return FilterEvaluation(matches: false, reasons: []) }
            let exclusion = condition.operator == .notEquals || condition.operator == .excludes
            return FilterEvaluation(
                matches: true,
                reasons: [LocalSearchMatchReason(
                    fieldID: condition.field,
                    kind: exclusion ? .filterExclusion : .filter,
                    sensitivity: sensitivity(for: condition.field, document: document)
                )]
            )
        }
    }

    private static func conditionMatches(
        _ condition: FilterCondition,
        candidateValues: [FilterValue],
        referenceDate: Date
    ) -> Bool {
        let knownValues = candidateValues.filter(isMeaningful)
        switch condition.operator {
        case .exists:
            return !knownValues.isEmpty
        case .isUnknown:
            return knownValues.isEmpty
        default:
            break
        }
        guard let target = condition.value else { return false }

        switch condition.operator {
        case .equals:
            return knownValues.contains { equivalent($0, target) }
        case .notEquals:
            return !knownValues.isEmpty && !knownValues.contains { equivalent($0, target) }
        case .containsAny:
            let candidateAtoms = Set(knownValues.flatMap(setAtoms))
            let targetAtoms = Set(setAtoms(target))
            return !candidateAtoms.isEmpty && !targetAtoms.isDisjoint(with: candidateAtoms)
        case .containsAll:
            let candidateAtoms = Set(knownValues.flatMap(setAtoms))
            let targetAtoms = Set(setAtoms(target))
            return !candidateAtoms.isEmpty && !targetAtoms.isEmpty && targetAtoms.isSubset(of: candidateAtoms)
        case .excludes:
            let candidateAtoms = Set(knownValues.flatMap(setAtoms))
            let targetAtoms = Set(setAtoms(target))
            return !candidateAtoms.isEmpty && !targetAtoms.isEmpty && targetAtoms.isDisjoint(with: candidateAtoms)
        case .before:
            guard let targetInterval = dateInterval(target) else { return false }
            return knownValues.contains {
                guard let candidate = dateInterval($0) else { return false }
                return candidate.upper < targetInterval.lower
            }
        case .after:
            guard let targetInterval = dateInterval(target) else { return false }
            return knownValues.contains {
                guard let candidate = dateInterval($0) else { return false }
                return candidate.lower > targetInterval.upper
            }
        case .between:
            guard let targetInterval = dateInterval(target) else { return false }
            return knownValues.contains {
                dateInterval($0)?.overlaps(targetInterval) == true
            }
        case .beforeRelativeDays, .afterRelativeDays:
            guard case let .integer(days) = target,
                  let threshold = addingDays(-days, to: referenceDate) else {
                return false
            }
            return knownValues.contains {
                guard let candidate = dateInterval($0) else { return false }
                if condition.operator == .beforeRelativeDays {
                    return candidate.upper < threshold
                }
                return candidate.lower > threshold
            }
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            guard let targetNumber = number(target) else { return false }
            return knownValues.contains {
                guard let candidateNumber = number($0) else { return false }
                switch condition.operator {
                case .lessThan: return candidateNumber < targetNumber
                case .lessThanOrEqual: return candidateNumber <= targetNumber
                case .greaterThan: return candidateNumber > targetNumber
                case .greaterThanOrEqual: return candidateNumber >= targetNumber
                default: return false
                }
            }
        case .exists, .isUnknown:
            return false
        }
    }

    private static func isMeaningful(_ value: FilterValue) -> Bool {
        switch value {
        case let .string(string):
            return !normalizedText(string).isEmpty
        case let .strings(strings):
            return strings.contains { !normalizedText($0).isEmpty }
        case let .uuids(ids):
            return !ids.isEmpty
        default:
            return true
        }
    }

    private static func equivalent(_ lhs: FilterValue, _ rhs: FilterValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)):
            return normalizedText(a) == normalizedText(b)
        case let (.strings(a), .strings(b)):
            return Set(a.map(normalizedText)) == Set(b.map(normalizedText))
        case let (.boolean(a), .boolean(b)):
            return a == b
        case let (.integer(a), .integer(b)):
            return a == b
        case let (.number(a), .number(b)):
            return a == b
        case let (.integer(a), .number(b)), let (.number(b), .integer(a)):
            return Double(a) == b
        case let (.uuid(a), .uuid(b)):
            return a == b
        case let (.uuids(a), .uuids(b)):
            return Set(a) == Set(b)
        default:
            if let lhsDate = dateInterval(lhs), let rhsDate = dateInterval(rhs) {
                return lhsDate.overlaps(rhsDate)
            }
            return false
        }
    }

    private static func setAtoms(_ value: FilterValue) -> [SetAtom] {
        switch value {
        case let .string(string):
            let normalized = normalizedText(string)
            return normalized.isEmpty ? [] : [.string(normalized)]
        case let .strings(strings):
            return strings.compactMap {
                let normalized = normalizedText($0)
                return normalized.isEmpty ? nil : .string(normalized)
            }
        case let .uuid(id):
            return [.uuid(id)]
        case let .uuids(ids):
            return ids.map(SetAtom.uuid)
        default:
            return []
        }
    }

    private static func number(_ value: FilterValue) -> Double? {
        switch value {
        case let .integer(number): Double(number)
        case let .number(number): number
        default: nil
        }
    }

    private static func dateInterval(_ value: FilterValue) -> DateIntervalValue? {
        switch value {
        case let .instant(date):
            return DateIntervalValue(lower: date, upper: date)
        case let .partialDate(date):
            return DateIntervalValue(lower: date.earliestInstant, upper: date.latestInstant)
        case let .dateRange(range):
            return DateIntervalValue(
                lower: range.start?.earliestInstant ?? .distantPast,
                upper: range.end?.latestInstant ?? .distantFuture
            )
        default:
            return nil
        }
    }

    private static func referencedFields(in node: FilterNode) -> [String] {
        switch node {
        case let .and(children), let .or(children):
            return Array(Set(children.flatMap(referencedFields))).sorted()
        case let .not(child):
            return referencedFields(in: child)
        case let .condition(condition):
            return [condition.field]
        }
    }

    private static func sensitivity(
        for fieldID: String,
        document: LocalSearchDocument
    ) -> Sensitivity {
        document.searchableFields.first { $0.fieldID == fieldID }?.sensitivity ?? .private
    }

    // MARK: - Sorting

    private static func compare(
        _ lhs: Candidate,
        _ rhs: Candidate,
        sorts: [SortSpecification],
        locale: Locale
    ) -> ComparisonResult {
        for sort in sorts {
            let lhsValue = selectedSortValue(
                lhs.fields[sort.field] ?? [],
                direction: sort.direction,
                locale: locale
            )
            let rhsValue = selectedSortValue(
                rhs.fields[sort.field] ?? [],
                direction: sort.direction,
                locale: locale
            )
            let result = compareOptional(
                lhsValue,
                rhsValue,
                specification: sort,
                locale: locale
            )
            if result != .orderedSame { return result }
        }

        let nameResult = lhs.document.person.displayName.compare(
            rhs.document.person.displayName,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            range: nil,
            locale: locale
        )
        if nameResult != .orderedSame { return nameResult }
        return lhs.document.id.uuidString.compare(rhs.document.id.uuidString)
    }

    private static func selectedSortValue(
        _ values: [FilterValue],
        direction: SortDirection,
        locale: Locale
    ) -> SortableValue? {
        let flattened = values.flatMap { sortableValues($0, direction: direction) }
        guard var selected = flattened.first else { return nil }
        for candidate in flattened.dropFirst() {
            let result = compareValues(candidate, selected, locale: locale)
            if direction == .ascending, result == .orderedAscending {
                selected = candidate
            } else if direction == .descending, result == .orderedDescending {
                selected = candidate
            }
        }
        return selected
    }

    private static func sortableValues(
        _ value: FilterValue,
        direction: SortDirection
    ) -> [SortableValue] {
        switch value {
        case let .string(string):
            return normalizedText(string).isEmpty ? [] : [.string(string)]
        case let .strings(strings):
            return strings.filter { !normalizedText($0).isEmpty }.map(SortableValue.string)
        case let .boolean(boolean):
            return [.boolean(boolean)]
        case let .integer(number):
            return [.number(Double(number))]
        case let .number(number):
            return [.number(number)]
        case let .uuid(id):
            return [.uuid(id.uuidString)]
        case let .uuids(ids):
            return ids.map { .uuid($0.uuidString) }
        case let .instant(date):
            return [.date(date)]
        case let .partialDate(date):
            return [.date(direction == .ascending ? date.earliestInstant : date.latestInstant)]
        case let .dateRange(range):
            if direction == .ascending {
                return [.date(range.start?.earliestInstant ?? .distantPast)]
            }
            return [.date(range.end?.latestInstant ?? .distantFuture)]
        }
    }

    private static func compareOptional(
        _ lhs: SortableValue?,
        _ rhs: SortableValue?,
        specification: SortSpecification,
        locale: Locale
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, .some):
            return specification.unknownPlacement == .first ? .orderedAscending : .orderedDescending
        case (.some, nil):
            return specification.unknownPlacement == .first ? .orderedDescending : .orderedAscending
        case let (.some(lhs), .some(rhs)):
            let result = compareValues(lhs, rhs, locale: locale)
            return specification.direction == .ascending ? result : inverted(result)
        }
    }

    private static func compareValues(
        _ lhs: SortableValue,
        _ rhs: SortableValue,
        locale: Locale
    ) -> ComparisonResult {
        guard lhs.typeOrder == rhs.typeOrder else {
            return lhs.typeOrder < rhs.typeOrder ? .orderedAscending : .orderedDescending
        }
        switch (lhs, rhs) {
        case let (.string(a), .string(b)):
            return a.compare(
                b,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: nil,
                locale: locale
            )
        case let (.number(a), .number(b)):
            if a == b { return .orderedSame }
            return a < b ? .orderedAscending : .orderedDescending
        case let (.date(a), .date(b)):
            if a == b { return .orderedSame }
            return a < b ? .orderedAscending : .orderedDescending
        case let (.boolean(a), .boolean(b)):
            if a == b { return .orderedSame }
            return a ? .orderedDescending : .orderedAscending
        case let (.uuid(a), .uuid(b)):
            return a.compare(b)
        default:
            return .orderedSame
        }
    }

    private static func inverted(_ result: ComparisonResult) -> ComparisonResult {
        switch result {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }

    private static func deduplicatedReasons(
        _ reasons: [LocalSearchMatchReason]
    ) -> [LocalSearchMatchReason] {
        var seen = Set<String>()
        return reasons
            .sorted {
                ($0.fieldID, $0.kind.rawValue, $0.sensitivity.rawValue) <
                    ($1.fieldID, $1.kind.rawValue, $1.sensitivity.rawValue)
            }
            .filter {
                seen.insert("\($0.fieldID)|\($0.kind.rawValue)|\($0.sensitivity.rawValue)").inserted
            }
    }
}
