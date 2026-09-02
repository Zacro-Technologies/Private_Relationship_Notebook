import Foundation
import Testing
@testable import RelationshipCore

@Test func searchNormalizesCaseWidthPunctuationAndKana() {
    let person = Person(
        displayName: "佐藤　健",
        pronunciation: "さとう けん",
        aliases: ["Sato Ken"],
        contexts: ["Scholarship ８期"]
    )

    #expect(SearchNormalizer.matches(person, query: "SATO-KEN"))
    #expect(SearchNormalizer.matches(person, query: "８期"))
    #expect(SearchNormalizer.matches(person, query: "8期"))
    #expect(!SearchNormalizer.matches(person, query: "Tanaka"))
}

@Test func personPersistenceNormalizationRemovesDuplicateListsAndPreferredRoutes() {
    let firstContactID = UUID()
    let person = Person(
        displayName: "  Alex  ",
        aliases: ["Lex", " lex ", ""],
        contexts: ["Book Club", "book club"],
        tags: ["Neighbor", "Ｎｅｉｇｈｂｏｒ"],
        contacts: [
            ContactMethod(
                id: firstContactID,
                kind: .email,
                value: " alex@example.com ",
                isPreferred: true
            ),
            ContactMethod(kind: .email, value: "ALEX@example.com", isPreferred: true),
            ContactMethod(kind: .messages, value: "+1 555 0100", isPreferred: true)
        ]
    ).normalizedForPersistence()

    #expect(person.displayName == "Alex")
    #expect(person.aliases == ["Lex"])
    #expect(person.contexts == ["Book Club"])
    #expect(person.tags == ["Neighbor"])
    #expect(person.contacts.count == 2)
    #expect(person.contacts.first?.id == firstContactID)
    #expect(person.contacts.filter(\.isPreferred).map(\.id) == [firstContactID])
}

@Test func nudgeRespectsHardExclusionsAndSnooze() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let eligible = Person(displayName: "Eligible", contexts: ["Community"])
    let blocked = Person(displayName: "Blocked", contexts: ["Community"], doNotContact: true)
    let snoozed = Person(displayName: "Snoozed", contexts: ["Community"], snoozedUntil: now.addingTimeInterval(600))
    let archived = Person(displayName: "Archived", contexts: ["Community"], isArchived: true)
    let engine = NudgeEngine(now: { now }, random: SeededRandomSource(value: 0.5))

    #expect(engine.eligiblePeople(from: [eligible, blocked, snoozed, archived]).map(\.displayName) == ["Eligible"])
}

@Test func proactiveNudgesRespectOffAndQuietHoursWhileManualEligibilityRemainsAvailable() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let midday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 12))!
    let late = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 23))!

    #expect(NudgePolicy(frequency: .off).allowsProactiveSuggestion(at: midday, calendar: calendar) == false)
    #expect(NudgePolicy(frequency: .daily, quietStartHour: 22, quietEndHour: 8)
        .allowsProactiveSuggestion(at: late, calendar: calendar) == false)
    #expect(NudgePolicy(frequency: .daily, quietStartHour: 22, quietEndHour: 8)
        .allowsProactiveSuggestion(at: midday, calendar: calendar))
}

@Test func proactiveNudgeCadenceUsesPersistableRollingBudgetsAndSpacing() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 12))!

    let weekly = NudgePolicy(frequency: .weekly, quietStartHour: 0, quietEndHour: 0)
    #expect(!weekly.allowsProactiveSuggestion(
        at: now,
        shownDates: [now.addingTimeInterval(-6 * 86_400)],
        calendar: calendar
    ))
    #expect(weekly.allowsProactiveSuggestion(
        at: now,
        shownDates: [now.addingTimeInterval(-8 * 86_400)],
        calendar: calendar
    ))

    let twiceWeekly = NudgePolicy(frequency: .twiceWeekly, quietStartHour: 0, quietEndHour: 0)
    #expect(!twiceWeekly.allowsProactiveSuggestion(
        at: now,
        shownDates: [now.addingTimeInterval(-3 * 86_400)],
        calendar: calendar
    ))
    #expect(twiceWeekly.allowsProactiveSuggestion(
        at: now,
        shownDates: [now.addingTimeInterval(-4 * 86_400)],
        calendar: calendar
    ))

    let daily = NudgePolicy(frequency: .daily, quietStartHour: 0, quietEndHour: 0)
    #expect(!daily.allowsProactiveSuggestion(
        at: now,
        shownDates: [now.addingTimeInterval(-23 * 3_600)],
        calendar: calendar
    ))
    #expect(daily.allowsProactiveSuggestion(
        at: now,
        shownDates: [now.addingTimeInterval(-25 * 3_600)],
        calendar: calendar
    ))

    #expect(!NudgePolicy(
        frequency: .custom,
        quietStartHour: 0,
        quietEndHour: 0,
        customFrequencyPerWeek: 0
    ).allowsProactiveSuggestion(at: now, calendar: calendar))
    let custom = NudgePolicy(
        frequency: .custom,
        quietStartHour: 0,
        quietEndHour: 0,
        customFrequencyPerWeek: 3
    )
    #expect(!custom.allowsProactiveSuggestion(
        at: now,
        shownDates: [
            now.addingTimeInterval(-6 * 86_400),
            now.addingTimeInterval(-4 * 86_400),
            now.addingTimeInterval(-2.5 * 86_400)
        ],
        calendar: calendar
    ))

    let personID = UUID()
    var history = NudgeSuggestionHistory()
    history.record(personID: personID, at: now, proactive: true)
    let encoded = try JSONEncoder().encode(history)
    let decoded = try JSONDecoder().decode(NudgeSuggestionHistory.self, from: encoded)
    #expect(decoded.proactiveShownDates == [now])
    #expect(decoded.recentSuggestionByPerson[personID] == now)
}

@Test func manualSuggestionBypassesProactiveCadenceButKeepsHardSafetyExclusions() {
    let now = Date(timeIntervalSince1970: 20_000_000)
    let eligible = Person(displayName: "Eligible", contexts: ["Community"])
    let never = Person(displayName: "Never", contexts: ["Community"], neverSuggest: true)
    let blocked = Person(displayName: "Blocked", contexts: ["Community"], doNotContact: true)
    let policy = NudgePolicy(frequency: .off, cooldownDays: 0)
    let engine = NudgeEngine(now: { now }, random: SeededRandomSource(value: 0))

    #expect(!policy.allowsProactiveSuggestion(at: now))
    // Manual callers invoke the eligibility engine directly instead of the
    // proactive cadence gate. Hard safety exclusions still apply.
    let result = engine.suggest(from: [never, blocked, eligible], policy: policy)
    #expect(result?.person.id == eligible.id)
}

@Test func eligibleSavedViewResolvesOfflineThenNudgeSafetyStillApplies() async throws {
    let allowed = Person(displayName: "Allowed", contexts: ["Community"], circle: .close)
    let blocked = Person(
        displayName: "Blocked",
        contexts: ["Community"],
        circle: .close,
        doNotContact: true
    )
    let outside = Person(displayName: "Outside", contexts: ["Community"], circle: .acquaintance)
    let view = SavedView(
        name: "Inner circle",
        filter: .condition(.init(
            field: LocalSearchPersonField.relationshipCircle,
            operator: .equals,
            value: .string(RelationshipCircle.close.rawValue)
        )),
        isEligibleNudgePool: true
    )

    let people = [allowed, blocked, outside]
    let ids = try await NudgeSavedViewPoolResolver().personIDs(
        in: view,
        people: people,
        canonical: CanonicalArchivePayload(),
        localeIdentifier: "en_US",
        referenceDate: Date(timeIntervalSince1970: 30_000_000)
    )
    #expect(ids == Set<UUID>([allowed.id, blocked.id]))

    let candidates = people.filter { ids.contains($0.id) }
    let suggestion = NudgeEngine(
        now: { Date(timeIntervalSince1970: 30_000_000) },
        random: SeededRandomSource(value: 0)
    ).suggest(from: candidates, policy: NudgePolicy(cooldownDays: 0))
    #expect(suggestion?.person.id == allowed.id)
}

@Test func overduePersonReceivesHigherWeight() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let overdue = Person(displayName: "Overdue", contexts: ["Work"], cadenceDays: 30, lastInteractionAt: now.addingTimeInterval(-120 * 86_400))
    let recent = Person(displayName: "Recent", contexts: ["Work"], cadenceDays: 30, lastInteractionAt: now.addingTimeInterval(-5 * 86_400))
    let engine = NudgeEngine(now: { now }, random: SeededRandomSource(value: 0))

    #expect(engine.weight(for: overdue) > engine.weight(for: recent))
}

@Test func archiveRoundTripPreservesStableIdentifiers() throws {
    let person = Person(displayName: "Maya", contacts: [.init(kind: .email, value: "maya@example.com")])
    let interaction = Interaction(personID: person.id, summary: "Caught up")
    let data = try ArchiveCodec.encode(people: [person], interactions: [interaction])
    let decoded = try ArchiveCodec.decode(data)

    #expect(decoded.people.first?.id == person.id)
    #expect(decoded.interactions.first?.personID == person.id)
    #expect(decoded.schemaVersion == 1)
}

@Test @MainActor func localPersistenceSavesPeopleAndConfirmedInteractions() {
    let store = NotebookStore(inMemory: true)
    let person = Person(displayName: "Offline Person", contexts: ["Local community"])
    store.save(person)
    #expect(store.people.count == 1)
    #expect(store.people.first?.displayName == "Offline Person")

    store.save(Interaction(personID: person.id, status: .confirmed, summary: "Met for coffee"))
    #expect(store.interactions.count == 1)
    #expect(store.person(id: person.id)?.lastInteractionAt != nil)
}
