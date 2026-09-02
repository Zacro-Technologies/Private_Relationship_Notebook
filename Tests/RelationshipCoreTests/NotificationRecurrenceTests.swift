import Foundation
import Testing
@testable import RelationshipCore

@Test func notificationRecurrencePlannerBuildsNativeRepeatingPatterns() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let fireDate = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 3,
        hour: 9,
        minute: 30
    )))

    let daily = NotificationRecurrencePlanner.patterns(
        fireDate: fireDate,
        recurrence: .daily(interval: 1),
        calendar: calendar
    )
    #expect(daily.count == 1)
    #expect(daily[0].repeats)
    #expect(daily[0].components.hour == 9)
    #expect(daily[0].components.minute == 30)
    #expect(daily[0].components.day == nil)

    let weekly = NotificationRecurrencePlanner.patterns(
        fireDate: fireDate,
        recurrence: .weekly(interval: 1, weekdays: [.monday, .friday]),
        calendar: calendar
    )
    #expect(weekly.map(\.components.weekday) == [Weekday.monday.rawValue, Weekday.friday.rawValue])
    #expect(weekly.allSatisfy { $0.repeats })

    let yearly = NotificationRecurrencePlanner.patterns(
        fireDate: fireDate,
        recurrence: .yearly(interval: 1),
        calendar: calendar
    )
    #expect(yearly[0].components.month == 8)
    #expect(yearly[0].components.day == 3)
    #expect(yearly[0].repeats)
}

@Test func unsupportedNotificationIntervalsRemainSafeSingleOccurrences() {
    let patterns = NotificationRecurrencePlanner.patterns(
        fireDate: .now.addingTimeInterval(86_400),
        recurrence: .daily(interval: 3)
    )
    #expect(patterns.count == 1)
    #expect(!patterns[0].repeats)
    #expect(patterns[0].identifierSuffix == ".next")
}

@Test func connectionNotificationRouteRequiresTheOwnedCategoryAndAnOpaqueUUID() {
    let personID = UUID()
    let validPayload: [AnyHashable: Any] = [
        ConnectionNotificationMetadata.personIDUserInfoKey: personID.uuidString
    ]

    #expect(ConnectionNotificationMetadata.personID(
        from: validPayload,
        categoryIdentifier: ConnectionNotificationMetadata.categoryIdentifier
    ) == personID)
    #expect(ConnectionNotificationMetadata.personID(
        from: validPayload,
        categoryIdentifier: "untrusted-category"
    ) == nil)
    #expect(ConnectionNotificationMetadata.personID(
        from: [ConnectionNotificationMetadata.personIDUserInfoKey: "not-a-uuid"],
        categoryIdentifier: ConnectionNotificationMetadata.categoryIdentifier
    ) == nil)
    #expect(ConnectionNotificationMetadata.personID(
        from: ["person_name": "Private Name"],
        categoryIdentifier: ConnectionNotificationMetadata.categoryIdentifier
    ) == nil)
    let todayPayload = ConnectionNotificationMetadata.userInfo(for: .today)
    #expect(ConnectionNotificationMetadata.route(
        from: todayPayload,
        categoryIdentifier: ConnectionNotificationMetadata.categoryIdentifier
    ) == .today)
    #expect(todayPayload[ConnectionNotificationMetadata.personIDUserInfoKey] == nil)
}

@Test func reminderProjectionMovesOutOfQuietHoursAndDeniesContextPayloads() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let person = Person(
        displayName: "Visible only after opt-in",
        contexts: ["Sensitive context must not leave the app"]
    )
    let due = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 3,
        hour: 23,
        minute: 15
    )))
    let reminder = Reminder(
        subject: .person(person.id),
        title: "Private reminder title",
        due: .instant(due, timeZoneIdentifier: calendar.timeZone.identifier),
        notificationPrivacy: .includeContext
    )

    let projected = makeScheduledConnectionReminders(
        reminders: [reminder],
        people: [person],
        quietHoursStart: 22,
        quietHoursEnd: 8,
        calendar: calendar
    )
    let schedule = try #require(projected.first)
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: schedule.fireDate)

    #expect(components.day == 4)
    #expect(components.hour == 8)
    #expect(components.minute == 0)
    #expect(schedule.personName == person.displayName)
    #expect(schedule.allowsPersonName)
    #expect(schedule.context == nil)
    #expect(!schedule.allowsContext)
}

@Test func reminderProjectionExcludesDeletedAndMissingPeople() {
    let activePerson = Person(displayName: "Active")
    let deletedPerson = Person(displayName: "Deleted", deletedAt: .now)
    let due = Date.now.addingTimeInterval(86_400)
    let activeReminder = Reminder(
        subject: .person(activePerson.id),
        title: "Active reminder",
        due: .instant(due, timeZoneIdentifier: nil)
    )
    let deletedReminder = Reminder(
        subject: .person(deletedPerson.id),
        title: "Deleted reminder",
        due: .instant(due, timeZoneIdentifier: nil)
    )
    let missingReminder = Reminder(
        subject: .person(UUID()),
        title: "Missing reminder",
        due: .instant(due, timeZoneIdentifier: nil)
    )

    let projected = makeScheduledConnectionReminders(
        reminders: [activeReminder, deletedReminder, missingReminder],
        people: [activePerson, deletedPerson],
        quietHoursStart: 0,
        quietHoursEnd: 0
    )

    #expect(projected.map(\.id) == [activeReminder.id])
}

@Test func notificationRequestPlanReportsPastOneTimeReminderAsUnscheduled() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let reminder = ScheduledConnectionReminder(
        fireDate: now.addingTimeInterval(-60),
        recurrence: .none
    )

    let plan = ConnectionNotificationRequestPlanner.plan(
        [reminder],
        requestBudget: 60,
        after: now
    )

    #expect(plan.allocations.isEmpty)
    #expect(plan.report.scheduledRequestCount == 0)
    #expect(plan.report.outcomes[reminder.id] == .unscheduled(.pastDue))
}

@Test func notificationRequestPlanPrioritizesExplicitNearTermRemindersAndReportsCapacity() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let nearExplicit = ScheduledConnectionReminder(
        fireDate: now.addingTimeInterval(60),
        kind: .explicitReminder
    )
    let farExplicit = ScheduledConnectionReminder(
        fireDate: now.addingTimeInterval(120),
        kind: .explicitReminder
    )
    let earlierProactive = ScheduledConnectionReminder(
        fireDate: now.addingTimeInterval(30),
        kind: .proactiveNudge
    )

    let plan = ConnectionNotificationRequestPlanner.plan(
        [farExplicit, earlierProactive, nearExplicit],
        requestBudget: 1,
        after: now
    )

    #expect(plan.allocations.map(\.reminder.id) == [nearExplicit.id])
    #expect(plan.report.scheduledRequestCount == 1)
    #expect(plan.report.outcomes[nearExplicit.id] == .scheduled(requestCount: 1))
    #expect(plan.report.outcomes[farExplicit.id] == .unscheduled(.capacity))
    #expect(plan.report.outcomes[earlierProactive.id] == .unscheduled(.capacity))
    #expect(plan.report.capacityLimitedReminderCount == 2)
}

@Test func notificationRequestPlanNeverPartiallyAllocatesAWeeklyReminder() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let weekly = ScheduledConnectionReminder(
        fireDate: now.addingTimeInterval(60),
        recurrence: .weekly(interval: 1, weekdays: [.monday, .friday])
    )
    let oneTime = ScheduledConnectionReminder(
        fireDate: now.addingTimeInterval(120),
        recurrence: .none
    )

    let plan = ConnectionNotificationRequestPlanner.plan(
        [weekly, oneTime],
        requestBudget: 1,
        after: now
    )

    #expect(plan.allocations.map(\.reminder.id) == [oneTime.id])
    #expect(plan.report.outcomes[weekly.id] == .unscheduled(.capacity))
    #expect(plan.report.outcomes[oneTime.id] == .scheduled(requestCount: 1))
}

@Test func nudgePoolSelectionRoundTripsEveryScopeAndFallsBackSafely() throws {
    let savedViewID = UUID(uuidString: "50A83643-06CA-4AA6-AFF4-6ACBBEDB6175")!
    let selections: [NudgePoolSelection] = [
        .everyone,
        .savedView(savedViewID),
        .circle(.close),
        .context("Scholarship 🌸")
    ]

    for selection in selections {
        let storageValue = selection.storageValue
        #expect(!storageValue.isEmpty)
        #expect(NudgePoolSelection(
            storageValue: storageValue,
            availableContexts: ["Scholarship 🌸"]
        ) == selection)
        let decodedStorage = try #require(Data(base64Encoded: storageValue))
        #expect(!String(decoding: decodedStorage, as: UTF8.self).contains("Scholarship"))
    }

    #expect(NudgePoolSelection(storageValue: nil) == .everyone)
    #expect(NudgePoolSelection(storageValue: "not-valid-base64") == .everyone)

    let firstScope = "local:notebook-a"
    let secondScope = "icloud:notebook-b"
    let firstKeys = [
        NudgeNotificationStorage.suggestionHistoryKey(scopeIdentifier: firstScope),
        NudgeNotificationStorage.poolSelectionKey(scopeIdentifier: firstScope),
        NudgeNotificationStorage.planningStateKey(scopeIdentifier: firstScope)
    ]
    let secondKeys = [
        NudgeNotificationStorage.suggestionHistoryKey(scopeIdentifier: secondScope),
        NudgeNotificationStorage.poolSelectionKey(scopeIdentifier: secondScope),
        NudgeNotificationStorage.planningStateKey(scopeIdentifier: secondScope)
    ]
    #expect(Set(firstKeys).count == firstKeys.count)
    #expect(zip(firstKeys, secondKeys).allSatisfy(!=))
}

@Test func proactiveNudgePlannerProducesConfiguredSevenDayCounts() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 3,
        hour: 12
    )))
    let planner = ProactiveNudgeNotificationPlanner(calendar: calendar, now: { now })
    let cases: [(NudgeFrequency, Int, Int)] = [
        (.off, 2, 0),
        (.weekly, 2, 1),
        (.twiceWeekly, 2, 2),
        (.threeWeekly, 2, 3),
        (.weekdays, 2, 5),
        (.daily, 2, 7),
        (.custom, 4, 4)
    ]

    for (frequency, customFrequency, expectedCount) in cases {
        let state = planner.plan(
            policy: NudgePolicy(
                frequency: frequency,
                quietStartHour: 0,
                quietEndHour: 0,
                customFrequencyPerWeek: customFrequency
            ),
            scopeIdentifier: "frequency-\(frequency.rawValue)"
        )
        #expect(state.scheduledReminders(after: now).count == expectedCount)
    }
}

@Test func proactiveNudgePlannerMovesSlotsOutsideQuietHoursWithoutLosingCadence() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 3,
        hour: 12
    )))
    let planner = ProactiveNudgeNotificationPlanner(calendar: calendar, now: { now })
    let policy = NudgePolicy(
        frequency: .threeWeekly,
        quietStartHour: 22,
        quietEndHour: 8
    )

    let state = planner.plan(policy: policy, scopeIdentifier: "quiet-hours")
    let reminders = state.scheduledReminders(after: now)

    #expect(reminders.count == 3)
    #expect(reminders.allSatisfy { reminder in
        let hour = calendar.component(.hour, from: reminder.fireDate)
        return hour >= 8 && hour < 22
    })
}

@Test func proactiveNudgePlannerUsesStableIDsWithinScopeAndSeparatesScopes() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 3,
        hour: 12
    )))
    let planner = ProactiveNudgeNotificationPlanner(calendar: calendar, now: { now })
    let policy = NudgePolicy(
        frequency: .daily,
        quietStartHour: 0,
        quietEndHour: 0
    )

    let first = planner.plan(policy: policy, scopeIdentifier: "account-a")
    let repeated = planner.plan(policy: policy, scopeIdentifier: "account-a")
    let restored = planner.plan(
        policy: policy,
        scopeIdentifier: "account-a",
        existingState: first
    )
    let otherScope = planner.plan(policy: policy, scopeIdentifier: "account-b")

    #expect(first.items == repeated.items)
    #expect(first.items == restored.items)
    #expect(first.items.map(\.fireDate) == otherScope.items.map(\.fireDate))
    #expect(first.items.map(\.id) != otherScope.items.map(\.id))
    #expect(Set(first.items.map(\.id)).count == first.items.count)
}

@Test func proactiveNudgePlanningStatePersistsAsGenericPrivacySafeReminders() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 3,
        hour: 12
    )))
    let planner = ProactiveNudgeNotificationPlanner(calendar: calendar, now: { now })
    let planned = planner.plan(
        policy: NudgePolicy(
            frequency: .twiceWeekly,
            quietStartHour: 0,
            quietEndHour: 0
        ),
        scopeIdentifier: "private-notebook"
    )

    let encoded = try JSONEncoder().encode(planned)
    let decoded = try JSONDecoder().decode(
        ProactiveNudgeNotificationPlanningState.self,
        from: encoded
    )
    let reminders = decoded.scheduledReminders(after: now)

    #expect(decoded == planned)
    #expect(!reminders.isEmpty)
    #expect(reminders.allSatisfy { reminder in
        reminder.kind == .proactiveNudge
            && reminder.personID == nil
            && reminder.personName == nil
            && reminder.context == nil
            && !reminder.allowsPersonName
            && !reminder.allowsContext
            && reminder.recurrence == .none
    })
}
