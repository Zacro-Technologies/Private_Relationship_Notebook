import Foundation
import Testing
@testable import RelationshipCore

@Test func customAttributeDefinitionsValidateTypesRangesAndOptions() {
    let scoreDefinition = AttributeDefinition(
        predicateID: "custom.sharedInterestScore",
        labels: .init("Shared interest score"),
        valueKind: .number,
        validation: .init(
            minimumNumber: 0,
            maximumNumber: 10,
            allowedUnitCodes: ["points"]
        ),
        capabilities: .init(supportsFilter: true, supportsSort: true)
    )

    #expect(scoreDefinition.validate(value: .number(.init(value: 7, unitCode: "points"))).isEmpty)
    #expect(scoreDefinition.validate(value: .number(.init(value: 11, unitCode: "points"))).contains(.numberAboveMaximum(10)))
    #expect(scoreDefinition.validate(value: .text("seven")) == [
        .wrongValueKind(expected: .number, actual: .text)
    ])

    let selectDefinition = AttributeDefinition(
        predicateID: "custom.favoriteSeason",
        labels: .init("Favorite season"),
        valueKind: .multiSelect,
        cardinality: .multiple
    )
    let spring = AttributeOption(
        definitionID: selectDefinition.id,
        label: .init("Spring"),
        order: 0
    )
    let archived = AttributeOption(
        definitionID: selectDefinition.id,
        label: .init("Old option"),
        order: 1,
        archivedAt: .now
    )
    let issues = selectDefinition.validate(
        value: .multiSelect([spring.id, archived.id, spring.id]),
        options: [spring, archived]
    )

    #expect(issues.contains(.optionIsArchived(archived.id)))
    #expect(issues.contains(.duplicateOption(spring.id)))
}

@Test func changingCustomAttributeTypeRequiresReviewedConversion() {
    let id = UUID()
    let original = AttributeDefinition(
        id: id,
        predicateID: "custom.startYear",
        labels: .init("Start year"),
        valueKind: .partialDate
    )
    let renamed = AttributeDefinition(
        id: id,
        predicateID: "custom.startYear",
        labels: .init("Year joined"),
        valueKind: .partialDate
    )
    let retyped = AttributeDefinition(
        id: id,
        predicateID: "custom.startYear",
        labels: .init("Start year"),
        valueKind: .number
    )

    #expect(renamed.canReplaceWithoutConversion(original))
    #expect(!retyped.canReplaceWithoutConversion(original))
}

@Test func savedViewFilterASTUsesPortableJSONAndRoundTrips() throws {
    let contextID = UUID()
    let filter: FilterNode = .and([
        .condition(.init(field: "membership.context", operator: .equals, value: .uuid(contextID))),
        .condition(.init(field: "education.status", operator: .equals, value: .string("graduated"))),
        .condition(.init(field: "interaction.lastAt", operator: .beforeRelativeDays, value: .integer(180)))
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(filter)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let children = try #require(object["children"] as? [[String: Any]])

    #expect(object["op"] as? String == "and")
    #expect(children[0]["field"] as? String == "membership.context")
    #expect(children[0]["value"] as? String == contextID.uuidString.lowercased())
    #expect(children[2]["value"] as? Int == 180)
    #expect(try JSONDecoder().decode(FilterNode.self, from: data) == filter)

    let view = SavedView(
        name: "Graduates to reconnect with",
        filter: filter,
        sorts: [.init(field: "interaction.lastAt", direction: .ascending)],
        isEligibleNudgePool: true
    )
    #expect(view.validationIssues(using: FilterSchema()).isEmpty)
}

@Test func filterSchemaRejectsUnknownFieldsAndOperatorValueMismatches() {
    let schema = FilterSchema()
    let unknown = FilterNode.condition(
        .init(field: "arbitrary.executablePredicate", operator: .equals, value: .string("x"))
    )
    let missingValue = FilterNode.condition(
        .init(field: "education.status", operator: .equals)
    )
    let wrongRelativeValue = FilterNode.condition(
        .init(field: "interaction.lastAt", operator: .beforeRelativeDays, value: .string("six months"))
    )

    #expect(schema.validate(unknown) == [.unknownField("arbitrary.executablePredicate")])
    #expect(schema.validate(missingValue) == [
        .missingValue(field: "education.status", operator: .equals)
    ])
    #expect(schema.validate(wrongRelativeValue) == [
        .wrongValueKind(field: "interaction.lastAt", expected: [.integer], actual: .string)
    ])
}

@Test func filterSchemaIncludesOnlyOptedInCustomAttributes() {
    let visible = AttributeDefinition(
        predicateID: "custom.languagesUsed",
        labels: .init("Languages used"),
        valueKind: .language,
        capabilities: .init(supportsFilter: true, supportsSort: true)
    )
    let privateNote = AttributeDefinition(
        predicateID: "custom.unindexedNote",
        labels: .init("Unindexed note"),
        valueKind: .richText,
        capabilities: .init(supportsFilter: false)
    )
    let schema = FilterSchema(customAttributes: [visible, privateNote])

    #expect(schema.fields["attribute.custom.languagesUsed"] != nil)
    #expect(schema.fields["attribute.custom.unindexedNote"] == nil)
    #expect(schema.validate(sort: .init(field: "attribute.custom.languagesUsed")).isEmpty)
}

@Test func remindersAndCommitmentsRetainPartialDatesAndEventHistory() throws {
    let personID = UUID()
    let reminder = Reminder(
        subject: .person(personID),
        title: "Send birthday note",
        due: .partialDate(try .month(4, of: 2027)),
        recurrence: .yearly(interval: 1),
        notificationPrivacy: .generic
    )
    let snooze = ReminderEvent(
        reminderID: reminder.id,
        kind: .snoozed(until: .partialDate(try .day(3, month: 4, year: 2027)))
    )
    let commitment = Commitment(
        interactionID: UUID(),
        personIDs: [personID],
        summary: "Send the reading list",
        owner: .notebookOwner,
        due: .partialDate(try .month(9, of: 2026))
    )
    let completion = CommitmentEvent(commitmentID: commitment.id, kind: .completed)

    #expect(reminder.validationIssues.isEmpty)
    #expect(commitment.validationIssues.isEmpty)
    #expect(try JSONDecoder().decode(Reminder.self, from: JSONEncoder().encode(reminder)) == reminder)
    #expect(try JSONDecoder().decode(ReminderEvent.self, from: JSONEncoder().encode(snooze)) == snooze)
    #expect(try JSONDecoder().decode(Commitment.self, from: JSONEncoder().encode(commitment)) == commitment)
    #expect(completion.commitmentID == commitment.id)

    let invalidReminder = Reminder(
        subject: .person(personID),
        title: " ",
        due: .partialDate(try .year(2027)),
        recurrence: .daily(interval: 0)
    )
    #expect(invalidReminder.validationIssues == ["reminder.emptyTitle", "reminder.invalidRecurrence"])
}
