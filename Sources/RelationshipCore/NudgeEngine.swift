import Foundation

public struct NudgePool: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var contextNames: Set<String>
    public var circles: Set<RelationshipCircle>
    public var channels: Set<ContactKind>
    public var includeArchived: Bool

    public init(
        id: UUID = UUID(),
        name: String = String(localized: "Everyone"),
        contextNames: Set<String> = [],
        circles: Set<RelationshipCircle> = [],
        channels: Set<ContactKind> = [],
        includeArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.contextNames = contextNames
        self.circles = circles
        self.channels = channels
        self.includeArchived = includeArchived
    }
}

public struct NudgePolicy: Codable, Hashable, Sendable {
    public var frequency: NudgeFrequency
    public var effort: EffortLevel
    public var pool: NudgePool
    public var cooldownDays: Int
    public var allowUnknownLastContact: Bool
    public var quietStartHour: Int
    public var quietEndHour: Int
    public var customFrequencyPerWeek: Int

    public init(
        frequency: NudgeFrequency = .twiceWeekly,
        effort: EffortLevel = .light,
        pool: NudgePool = .init(),
        cooldownDays: Int = 14,
        allowUnknownLastContact: Bool = true,
        quietStartHour: Int = 22,
        quietEndHour: Int = 8,
        customFrequencyPerWeek: Int = 2
    ) {
        self.frequency = frequency
        self.effort = effort
        self.pool = pool
        self.cooldownDays = max(0, cooldownDays)
        self.allowUnknownLastContact = allowUnknownLastContact
        self.quietStartHour = min(max(quietStartHour, 0), 23)
        self.quietEndHour = min(max(quietEndHour, 0), 23)
        self.customFrequencyPerWeek = min(max(customFrequencyPerWeek, 0), 14)
    }

    /// The configured proactive budget. Manual, user-requested suggestions do
    /// not consume or consult this budget.
    public var proactiveSuggestionsPerWeek: Int {
        switch frequency {
        case .off: 0
        case .weekly: 1
        case .twiceWeekly: 2
        case .threeWeekly: 3
        case .weekdays: 5
        case .daily: 7
        case .custom: customFrequencyPerWeek
        }
    }

    /// Returns whether a new proactive suggestion may be shown now.
    ///
    /// Both a rolling seven-day budget and a minimum interval are enforced.
    /// The interval prevents repeated app launches from consuming an entire
    /// weekly budget at once. Pass only dates for suggestions that were
    /// actually presented proactively; manual "Surprise Me" requests bypass
    /// this method and continue through the regular safety eligibility path.
    public func allowsProactiveSuggestion(
        at date: Date,
        shownDates: [Date] = [],
        calendar: Calendar = .current
    ) -> Bool {
        let weeklyLimit = proactiveSuggestionsPerWeek
        guard weeklyLimit > 0 else { return false }
        let isQuiet: Bool
        if quietStartHour == quietEndHour {
            isQuiet = false
        } else {
            let hour = calendar.component(.hour, from: date)
            isQuiet = quietStartHour < quietEndHour
                ? (hour >= quietStartHour && hour < quietEndHour)
                : (hour >= quietStartHour || hour < quietEndHour)
        }
        guard !isQuiet else { return false }

        let windowStart = calendar.date(byAdding: .day, value: -7, to: date)
            ?? date.addingTimeInterval(-7 * 86_400)
        let recent = shownDates.filter { $0 <= date && $0 > windowStart }
        guard recent.count < weeklyLimit else { return false }
        guard let latest = recent.max() else { return true }

        let minimumInterval = (7 * 86_400) / Double(weeklyLimit)
        return date.timeIntervalSince(latest) >= minimumInterval
    }
}

/// Small, local-only record used to keep nudge limits and per-person cooldowns
/// stable across app launches. It deliberately stores only dates and local
/// person identifiers, never prompts or relationship notes.
public struct NudgeSuggestionHistory: Codable, Hashable, Sendable {
    public var proactiveShownDates: [Date]
    public var recentSuggestionByPerson: [UUID: Date]
    /// Manual draws use a separate cooldown so requesting a surprise never
    /// suppresses a later proactive suggestion. Optional for old payloads.
    public var manualSuggestionByPerson: [UUID: Date]?

    public init(
        proactiveShownDates: [Date] = [],
        recentSuggestionByPerson: [UUID: Date] = [:],
        manualSuggestionByPerson: [UUID: Date]? = nil
    ) {
        self.proactiveShownDates = proactiveShownDates
        self.recentSuggestionByPerson = recentSuggestionByPerson
        self.manualSuggestionByPerson = manualSuggestionByPerson
    }

    public mutating func record(personID: UUID, at date: Date, proactive: Bool) {
        if proactive {
            recentSuggestionByPerson[personID] = max(
                recentSuggestionByPerson[personID] ?? .distantPast,
                date
            )
            proactiveShownDates.append(date)
        } else {
            var manual = manualSuggestionByPerson ?? [:]
            manual[personID] = max(manual[personID] ?? .distantPast, date)
            manualSuggestionByPerson = manual
        }
    }

    /// Records only the per-person proactive cooldown when cadence was already
    /// consumed by a delivered notification slot.
    public mutating func recordReservedProactiveCooldown(personID: UUID, at date: Date) {
        recentSuggestionByPerson[personID] = max(
            recentSuggestionByPerson[personID] ?? .distantPast,
            date
        )
    }

    public mutating func prune(before cutoff: Date) {
        proactiveShownDates.removeAll { $0 < cutoff }
        recentSuggestionByPerson = recentSuggestionByPerson.filter { $0.value >= cutoff }
        manualSuggestionByPerson = manualSuggestionByPerson?.filter { $0.value >= cutoff }
    }
}

public enum NudgeExclusionReason: String, Codable, Hashable, Sendable {
    case archived
    case neverSuggest
    case doNotContact
    case snoozed
    case outsidePool
    case noViableRoute
    case recipientQuietHours
    case unknownLastContact
    case recentSuggestionCooldown
}

public struct NudgeEligibilityReport: Codable, Hashable, Sendable {
    public var eligibleIDs: [UUID]
    public var excluded: [UUID: NudgeExclusionReason]

    public init(eligibleIDs: [UUID], excluded: [UUID: NudgeExclusionReason]) {
        self.eligibleIDs = eligibleIDs
        self.excluded = excluded
    }
}

public protocol RandomSource: Sendable {
    func unit() -> Double
}

public struct SystemRandomSource: RandomSource {
    public init() {}
    public func unit() -> Double { Double.random(in: 0..<1) }
}

public struct SeededRandomSource: RandomSource {
    private let value: Double
    public init(value: Double) { self.value = min(max(value, 0), 0.999_999) }
    public func unit() -> Double { value }
}

public struct NudgeEngine: Sendable {
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let random: any RandomSource

    public init(
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { .now },
        random: any RandomSource = SystemRandomSource()
    ) {
        self.calendar = calendar
        self.now = now
        self.random = random
    }

    public func eligiblePeople(from people: [Person]) -> [Person] {
        let date = now()
        return people.filter { person in
            person.deletedAt == nil && !person.isArchived && !person.neverSuggest && !person.doNotContact
                && (person.snoozedUntil == nil || person.snoozedUntil! <= date)
                && (!person.availableContactMethods.isEmpty || !person.contexts.isEmpty)
                && person.isWithinRecipientContactHours(at: date)
        }
    }

    public func suggest(from people: [Person], effort: EffortLevel) -> NudgeSuggestion? {
        let candidates = eligiblePeople(from: people)
        guard !candidates.isEmpty else { return nil }

        let weighted = candidates.map { ($0, weight(for: $0)) }
        let total = weighted.reduce(0) { $0 + $1.1 }
        var cursor = random.unit() * total
        let selected = weighted.first { pair in
            cursor -= pair.1
            return cursor <= 0
        }?.0 ?? weighted.last!.0

        return NudgeSuggestion(
            person: selected,
            explanation: explanation(for: selected),
            prompt: prompt(for: selected, effort: effort)
        )
    }

    public func eligibilityReport(
        for people: [Person],
        policy: NudgePolicy,
        recentSuggestions: [UUID: Date] = [:]
    ) -> NudgeEligibilityReport {
        let date = now()
        var eligible: [UUID] = []
        var excluded: [UUID: NudgeExclusionReason] = [:]
        for person in people {
            let reason: NudgeExclusionReason?
            if person.deletedAt != nil { reason = .archived }
            else if person.isArchived && !policy.pool.includeArchived { reason = .archived }
            else if person.neverSuggest { reason = .neverSuggest }
            else if person.doNotContact { reason = .doNotContact }
            else if let until = person.snoozedUntil, until > date { reason = .snoozed }
            else if person.availableContactMethods.isEmpty && person.contexts.isEmpty { reason = .noViableRoute }
            else if !person.isWithinRecipientContactHours(at: date) { reason = .recipientQuietHours }
            else if !matches(person, pool: policy.pool) { reason = .outsidePool }
            else if person.lastInteractionAt == nil && !policy.allowUnknownLastContact { reason = .unknownLastContact }
            else if let lastSuggested = recentSuggestions[person.id],
                    date.timeIntervalSince(lastSuggested) < Double(policy.cooldownDays) * 86_400 {
                reason = .recentSuggestionCooldown
            } else { reason = nil }

            if let reason { excluded[person.id] = reason }
            else { eligible.append(person.id) }
        }
        return NudgeEligibilityReport(eligibleIDs: eligible, excluded: excluded)
    }

    public func suggest(
        from people: [Person],
        policy: NudgePolicy,
        recentSuggestions: [UUID: Date] = [:]
    ) -> NudgeSuggestion? {
        let report = eligibilityReport(for: people, policy: policy, recentSuggestions: recentSuggestions)
        let allowed = Set(report.eligibleIDs)
        let candidates = people.filter { allowed.contains($0.id) }
        guard !candidates.isEmpty else { return nil }
        let weighted = candidates.map { person in
            let channelFit = policy.pool.channels.isEmpty || person.availableContactMethods.contains(where: { policy.pool.channels.contains($0.kind) }) ? 1.15 : 0.8
            let contextFit = policy.pool.contextNames.isEmpty || !Set(person.contexts).isDisjoint(with: policy.pool.contextNames) ? 1.15 : 1
            return (person, weight(for: person) * channelFit * contextFit)
        }
        let total = weighted.reduce(0) { $0 + $1.1 }
        var cursor = random.unit() * total
        let selected = weighted.first { pair in cursor -= pair.1; return cursor <= 0 }?.0 ?? weighted.last!.0
        return NudgeSuggestion(
            person: selected,
            explanation: explanation(for: selected),
            prompt: prompt(for: selected, effort: policy.effort)
        )
    }

    public func weight(for person: Person) -> Double {
        let elapsedDays: Double
        if let last = person.lastInteractionAt {
            elapsedDays = max(0, now().timeIntervalSince(last) / 86_400)
        } else {
            elapsedDays = Double(person.cadenceDays) * 0.75
        }
        let dueFactor = max(0.4, elapsedDays / Double(max(person.cadenceDays, 1)))
        let priorityFactor = 0.75 + Double(min(max(person.priority, 1), 3)) * 0.25
        return min(5, dueFactor * priorityFactor)
    }

    private func explanation(for person: Person) -> String {
        guard let last = person.lastInteractionAt else {
            return String(localized: "No recent interaction is recorded. This choice came from your eligible pool.")
        }
        let days = max(0, calendar.dateComponents([.day], from: last, to: now()).day ?? 0)
        if days >= person.cadenceDays {
            return String(localized: "Your \(person.cadenceDays)-day cadence is due. You last logged contact \(days) days ago.")
        }
        return String(localized: "You last logged contact \(days) days ago. This adds variety within your eligible pool.")
    }

    private func prompt(for person: Person, effort: EffortLevel) -> String {
        if let preference = person.communicationPreferences,
           !preference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "\(effort.suggestion). Their communication preference: \(preference)")
        }
        if !person.mentionableContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "\(effort.suggestion). You marked this as safe to mention: \(person.mentionableContext)")
        }
        return String(localized: "\(effort.suggestion). A simple, context-neutral check-in works well.")
    }

    private func matches(_ person: Person, pool: NudgePool) -> Bool {
        let contextMatch = pool.contextNames.isEmpty || !Set(person.contexts).isDisjoint(with: pool.contextNames)
        let circleMatch = pool.circles.isEmpty || pool.circles.contains(person.circle)
        let channelMatch = pool.channels.isEmpty || person.availableContactMethods.contains { pool.channels.contains($0.kind) }
        return contextMatch && circleMatch && channelMatch
    }
}

/// Resolves a user-authored, nudge-enabled saved view through the same
/// validated offline filter engine used by People search. The result is only
/// a candidate pool; `NudgeEngine` still applies do-not-contact, never-suggest,
/// snooze, archive, route, and cooldown exclusions afterward.
public struct NudgeSavedViewPoolResolver: Sendable {
    public init() {}

    public func personIDs(
        in savedView: SavedView,
        people: [Person],
        canonical: CanonicalArchivePayload,
        localeIdentifier: String = Locale.current.identifier,
        referenceDate: Date = .now
    ) async throws -> Set<UUID> {
        guard savedView.isEligibleNudgePool else { return [] }

        let search = LocalSearch(schema: .localSearchPerson(
            customAttributes: canonical.attributeDefinitions
        ))
        let documents = CanonicalLocalSearchProjection().documents(
            people: people,
            canonical: canonical,
            localeIdentifier: localeIdentifier
        )
        try await search.upsert(documents)

        var result = Set<UUID>()
        var cursor: LocalSearchCursor?
        repeat {
            let page = try await search.search(
                savedView: savedView,
                includeArchived: true,
                referenceDate: referenceDate,
                localeIdentifier: localeIdentifier,
                page: LocalSearchPageRequest(limit: 500, cursor: cursor)
            )
            result.formUnion(page.hits.map(\.personID))
            cursor = page.nextCursor
        } while cursor != nil
        return result
    }
}
