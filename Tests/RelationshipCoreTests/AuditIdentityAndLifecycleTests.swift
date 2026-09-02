import CoreData
import Foundation
import Testing
@testable import RelationshipCore

@Test @MainActor func selfIdentityIsUniqueAndExampleRecordsAreExplicitlyRemovable() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let first = Person(displayName: "First", isSelf: true)
    let second = Person(displayName: "Second", isSelf: true)
    #expect(store.save(first))
    #expect(store.save(second))
    #expect(store.people.filter(\.isSelf).map(\.id) == [second.id])

    let examples = NotebookStore(inMemory: true)
    examples.seedExamples()
    #expect(examples.people.count == 3)
    #expect(examples.people.allSatisfy { $0.isSample })
    #expect(examples.removeAllExamples() == 3)
    #expect(examples.people.allSatisfy { $0.deletedAt != nil })
}

@Test @MainActor func archiveImportCannotCreateTwoActiveSelfIdentities() throws {
    let store = NotebookStore(inMemory: true)
    let existingSelf = Person(displayName: "Existing Me", isSelf: true)
    #expect(store.save(existingSelf))

    let incomingSelf = Person(displayName: "Imported Me", isSelf: true)
    let archive = NotebookArchive(
        people: [incomingSelf],
        interactions: []
    )
    #expect(throws: ArchiveImportCommitError.multipleActiveSelfIdentities(
        [existingSelf.id, incomingSelf.id].sorted { $0.uuidString < $1.uuidString }
    )) {
        try store.commitImportedArchive(archive)
    }
    #expect(store.people.filter(\.isSelf).map(\.id) == [existingSelf.id])
}

@Test func typedNamesPreserveScriptLanguageComponentsAndOnePreferredVariant() throws {
    let japanese = PersonNameVariant(
        fullName: "佐藤 健司",
        givenName: "健司",
        familyName: "佐藤",
        kind: .originalScript,
        languageCode: "ja",
        scriptCode: "Jpan",
        isPreferred: true
    )
    let romanized = PersonNameVariant(
        fullName: "Kenji Sato",
        givenName: "Kenji",
        familyName: "Sato",
        kind: .romanization,
        languageCode: "en",
        scriptCode: "Latn",
        isPreferred: true
    )
    let person = Person(
        displayName: "temporary",
        nameVariants: [japanese, romanized]
    ).normalizedForPersistence()

    #expect(person.nameVariants?.filter(\.isPreferred).count == 1)
    #expect(person.displayName == "佐藤 健司")
    #expect(person.nameVariants?[1].formatted(order: .familyGiven) == "Sato Kenji")

    let data = try JSONEncoder().encode(person)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "nameVariants")
    object.removeValue(forKey: "isSelfIdentity")
    object.removeValue(forKey: "sampleDataSetID")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let legacy = try JSONDecoder().decode(Person.self, from: legacyData)
    #expect(legacy.nameVariants == nil)
    #expect(!legacy.isSelf)
    #expect(!legacy.isSample)
}

@Test @MainActor func quickContextsMatchCanonicalNamesAndCloseDeselectedMemberships() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let person = Person(displayName: "Ari")
    #expect(store.save(person))

    let selected = try canonical.reconcileCurrentContexts(
        for: person.id,
        selectedContextIDs: [],
        creatingLabels: ["Book Club", " book club "]
    )
    #expect(selected.count == 1)
    #expect(canonical.contexts.count == 1)
    #expect(canonical.memberships.count == 1)
    #expect(canonical.memberships[0].status == .active)

    _ = try canonical.reconcileCurrentContexts(
        for: person.id,
        selectedContextIDs: []
    )
    #expect(canonical.memberships.count == 1)
    #expect(canonical.memberships[0].status == .completed)
    #expect(canonical.memberships[0].endDate != nil)
}

@Test @MainActor func customFieldsAndSavedViewsEnforceStableLifecycleIdentity() throws {
    let persistence = PersistenceController(inMemory: true)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let definitionID = UUID()
    let choice = AttributeOption(
        definitionID: definitionID,
        label: .init("Spring"),
        order: 0
    )
    let first = AttributeDefinition(
        id: definitionID,
        predicateID: "custom.\(UUID().uuidString.lowercased())",
        labels: .init("Anniversary"),
        valueKind: .singleSelect,
        options: [choice]
    )
    try canonical.saveAttributeDefinition(first)

    let duplicateLabel = AttributeDefinition(
        predicateID: "custom.\(UUID().uuidString.lowercased())",
        labels: .init(" anniversary "),
        valueKind: .text
    )
    #expect(throws: CanonicalDefinitionSaveError.duplicateFieldName("anniversary")) {
        try canonical.saveAttributeDefinition(duplicateLabel)
    }

    let view = SavedView(
        name: "Close friends",
        filter: .condition(.init(
            field: LocalSearchPersonField.relationshipCircle,
            operator: .equals,
            value: .string(RelationshipCircle.close.rawValue)
        )),
        displayOrder: 0
    )
    try canonical.saveSavedView(view)
    #expect(throws: CanonicalDefinitionSaveError.duplicateSavedViewName("close FRIENDS")) {
        try canonical.saveSavedView(SavedView(
            name: "close FRIENDS",
            filter: view.filter
        ))
    }

    var archived = view
    archived.archivedAt = .now
    try canonical.saveSavedView(archived)
    #expect(canonical.activeSavedViews.isEmpty)
    #expect(canonical.savedViews.first?.isArchived == true)
}

@Test func relativeCohortValuesEnterTheSearchProjectionFromTheSelfIdentity() throws {
    let selfPerson = Person(displayName: "Me", isSelf: true)
    let other = Person(displayName: "Other")
    let context = Context(kind: .program, names: .init("Program"))
    let scheme = CohortScheme(
        contextID: context.id,
        kind: .numberedGeneration,
        name: .init("Generation"),
        orderingMethod: .chronologicalRank,
        distanceIsMeaningful: true
    )
    let earlier = Cohort(schemeID: scheme.id, labels: .init("1"), chronologicalRank: 1)
    let later = Cohort(schemeID: scheme.id, labels: .init("2"), chronologicalRank: 2)
    let selfMembership = MembershipEpisode(personID: selfPerson.id, contextID: context.id)
    let otherMembership = MembershipEpisode(personID: other.id, contextID: context.id)
    let payload = CanonicalArchivePayload(
        contexts: [context],
        cohortSchemes: [scheme],
        cohorts: [earlier, later],
        memberships: [selfMembership, otherMembership],
        cohortAssignments: [
            CohortAssignment(membershipEpisodeID: selfMembership.id, cohortID: later.id),
            CohortAssignment(membershipEpisodeID: otherMembership.id, cohortID: earlier.id)
        ]
    )
    let documents = CanonicalLocalSearchProjection().documents(
        people: [selfPerson, other],
        canonical: payload
    )
    let document = try #require(documents.first { $0.id == other.id })
    #expect(document.filterFields[LocalSearchPersonField.relativeCohortPosition] == [.string("earlier")])
    #expect(document.filterFields[LocalSearchPersonField.cohortDistance] == [.integer(1)])
}
