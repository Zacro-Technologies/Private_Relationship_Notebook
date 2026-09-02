import Foundation
import Testing
@testable import RelationshipCore

private let searchReferenceDate = Date(timeIntervalSince1970: 2_000_000_000)

private func fixedPerson(
    _ name: String,
    id: UUID = UUID(),
    role: String = "",
    tags: [String] = [],
    circle: RelationshipCircle = .acquaintance,
    lastInteractionAt: Date? = nil,
    doNotContact: Bool = false
) -> Person {
    Person(
        id: id,
        displayName: name,
        role: role,
        tags: tags,
        circle: circle,
        createdAt: searchReferenceDate.addingTimeInterval(-400 * 86_400),
        modifiedAt: searchReferenceDate.addingTimeInterval(-10 * 86_400),
        lastInteractionAt: lastInteractionAt,
        doNotContact: doNotContact
    )
}

@Test func localSearchNormalizesKanaAndReportsOnlyFieldReasons() async throws {
    let restrictedValue = "oncology follow-up"
    let person = Person(
        displayName: "佐藤 健",
        pronunciation: "サトウ ケン",
        aliases: ["Sato Ken"],
        privateNote: "another private value"
    )
    let document = LocalSearchDocument(
        person: person,
        additionalSearchableFields: [
            .init(
                fieldID: "attribute.privateHealthContext",
                value: restrictedValue,
                sensitivity: .highlySensitive
            )
        ]
    )
    let search = LocalSearch()
    try await search.upsert([document])

    let kanaPage = try await search.search(LocalSearchQuery(
        text: "さとうけん",
        referenceDate: searchReferenceDate,
        localeIdentifier: "ja_JP"
    ))
    #expect(kanaPage.hits.map(\.personID) == [person.id])
    #expect(kanaPage.hits[0].matchReasons.contains {
        $0.fieldID == LocalSearchPersonField.pronunciation && $0.kind == .exactText
    })

    let sensitivePage = try await search.search(LocalSearchQuery(
        text: "ONCOLOGY-FOLLOW UP",
        referenceDate: searchReferenceDate
    ))
    let reason = try #require(sensitivePage.hits.first?.matchReasons.first)
    #expect(reason.fieldID == "attribute.privateHealthContext")
    #expect(reason.sensitivity == .highlySensitive)

    let serializedResult = String(
        decoding: try JSONEncoder().encode(sensitivePage),
        as: UTF8.self
    )
    #expect(!serializedResult.localizedCaseInsensitiveContains(restrictedValue))
    #expect(!serializedResult.localizedCaseInsensitiveContains("oncology"))
    #expect(!serializedResult.contains(person.privateNote))
}

@Test func canonicalProjectionIndexesRelationshipsAndApprovedCustomFacts() async throws {
    let person = fixedPerson("Aiko")
    let context = Context(kind: .program, names: LocalizedText("Kizuna Scholarship"))
    let membership = MembershipEpisode(
        personID: person.id,
        contextID: context.id,
        status: .active
    )
    let definition = AttributeDefinition(
        predicateID: "interest.primary",
        labels: LocalizedText("Primary interest"),
        valueKind: .text,
        capabilities: .init(supportsSearch: true, supportsFilter: true, supportsSort: true)
    )
    let assertion = try AssertionEnvelope(
        subjectID: person.id,
        predicateID: definition.predicateID,
        value: .text("Ceramics"),
        reviewStatus: .accepted,
        sensitivity: .private,
        usePolicy: .init(search: .include)
    )
    let canonical = CanonicalArchivePayload(
        contexts: [context],
        memberships: [membership],
        assertions: [assertion],
        attributeDefinitions: [definition]
    )
    let documents = CanonicalLocalSearchProjection().documents(
        people: [person],
        canonical: canonical,
        localeIdentifier: "en"
    )
    let search = LocalSearch(schema: .localSearchPerson(customAttributes: [definition]))
    try await search.upsert(documents)

    let relationshipPage = try await search.search(LocalSearchQuery(text: "kizuna"))
    #expect(relationshipPage.hits.map(\.personID) == [person.id])
    #expect(relationshipPage.hits[0].matchReasons.contains {
        $0.fieldID == LocalSearchPersonField.context
    })

    let factPage = try await search.search(LocalSearchQuery(
        filter: .condition(.init(
            field: "attribute.interest.primary",
            operator: .containsAny,
            value: .strings(["ceramics"])
        ))
    ))
    #expect(factPage.hits.map(\.personID) == [person.id])
    #expect(factPage.hits[0].matchReasons.first?.sensitivity == .private)
}

@Test func localSearchSchemaExposesEveryProjectedCanonicalFieldAndSortOnlyCustomFields() {
    let sortOnly = AttributeDefinition(
        predicateID: "custom.sortOnlyNumber",
        labels: LocalizedText("Sort-only number"),
        valueKind: .number,
        capabilities: .init(supportsSort: true)
    )
    let schema = FilterSchema.localSearchPerson(customAttributes: [sortOnly])
    let projectedFields = [
        LocalSearchPersonField.cohort,
        LocalSearchPersonField.membershipStatus,
        LocalSearchPersonField.role,
        LocalSearchPersonField.educationStatus,
        LocalSearchPersonField.educationGraduation,
        LocalSearchPersonField.location,
        LocalSearchPersonField.timeZone,
        LocalSearchPersonField.language,
        LocalSearchPersonField.source,
        LocalSearchPersonField.assertionReviewStatus,
        LocalSearchPersonField.assertionConfidence,
        LocalSearchPersonField.assertionSensitivity,
        LocalSearchPersonField.assertionFreshness
    ]

    #expect(projectedFields.allSatisfy { schema.fields[$0] != nil })
    #expect(schema.fields[LocalSearchPersonField.educationGraduation]?.isSortable == true)
    #expect(schema.fields["attribute.custom.sortOnlyNumber"]?.isSortable == true)
    #expect(schema.validate(sort: .init(field: "attribute.custom.sortOnlyNumber")).isEmpty)
    #expect(!schema.validate(.condition(.init(
        field: "attribute.custom.sortOnlyNumber",
        operator: .greaterThan,
        value: .number(1)
    ))).isEmpty)

    let safeDescription = LocalSearchError.invalidQuery([]).errorDescription ?? ""
    #expect(!safeDescription.isEmpty)
    #expect(!safeDescription.contains("custom.sortOnlyNumber"))
}

@Test func canonicalProjectionSortsBySortOnlyCustomAttribute() async throws {
    let lower = fixedPerson("Zulu")
    let higher = fixedPerson("Alpha")
    let definition = AttributeDefinition(
        predicateID: "custom.sortOnlyNumber",
        labels: LocalizedText("Sort-only number"),
        valueKind: .number,
        capabilities: .init(supportsSort: true)
    )
    let assertions = [
        try AssertionEnvelope(
            subjectID: lower.id,
            predicateID: definition.predicateID,
            value: .number(.init(value: 1))
        ),
        try AssertionEnvelope(
            subjectID: higher.id,
            predicateID: definition.predicateID,
            value: .number(.init(value: 2))
        )
    ]
    let canonical = CanonicalArchivePayload(
        assertions: assertions,
        attributeDefinitions: [definition]
    )
    let search = LocalSearch(schema: .localSearchPerson(customAttributes: [definition]))
    try await search.upsert(CanonicalLocalSearchProjection().documents(
        people: [higher, lower],
        canonical: canonical
    ))

    let page = try await search.search(LocalSearchQuery(sorts: [
        .init(field: "attribute.custom.sortOnlyNumber")
    ]))
    #expect(page.hits.map(\.personID) == [lower.id, higher.id])
}

@Test func canonicalCompoundFacetsAreAndAcrossAndOrWithin() async throws {
    let included = fixedPerson("Included")
    let excluded = fixedPerson("Excluded")
    let context = Context(kind: .program, names: LocalizedText("Scholarship"))
    let includedCohort = Cohort(schemeID: UUID(), labels: LocalizedText("Cohort A"))
    let excludedCohort = Cohort(schemeID: UUID(), labels: LocalizedText("Cohort B"))
    let includedMembership = MembershipEpisode(
        personID: included.id,
        contextID: context.id,
        status: .active
    )
    let excludedMembership = MembershipEpisode(
        personID: excluded.id,
        contextID: context.id,
        status: .completed
    )
    let sourceA = SourceArtifact(kind: .pdf, originalFilename: "source-a.pdf")
    let sourceB = SourceArtifact(kind: .pdf, originalFilename: "source-b.pdf")
    let includedGraduation = try PartialDate.year(2024)
    let excludedGraduation = try PartialDate.year(2010)
    let includedAssertions = [
        try AssertionEnvelope(
            subjectID: included.id,
            predicateID: "location.current",
            value: .location(.init(label: "Tokyo", timeZoneIdentifier: "Asia/Tokyo")),
            sourceID: sourceA.id,
            confidence: 0.9,
            assertedAt: searchReferenceDate.addingTimeInterval(-20 * 86_400),
            sensitivity: .ordinary
        ),
        try AssertionEnvelope(
            subjectID: included.id,
            predicateID: "language.primary",
            value: .language("ja"),
            sourceID: sourceA.id,
            confidence: 0.95,
            assertedAt: searchReferenceDate.addingTimeInterval(-10 * 86_400),
            sensitivity: .ordinary
        )
    ]
    let excludedAssertion = try AssertionEnvelope(
        subjectID: excluded.id,
        predicateID: "location.current",
        value: .location(.init(label: "Osaka", timeZoneIdentifier: "Asia/Tokyo")),
        sourceID: sourceB.id,
        confidence: 0.4,
        assertedAt: searchReferenceDate.addingTimeInterval(-500 * 86_400),
        sensitivity: .sensitive
    )
    let canonical = CanonicalArchivePayload(
        contexts: [context],
        cohorts: [includedCohort, excludedCohort],
        memberships: [includedMembership, excludedMembership],
        cohortAssignments: [
            CohortAssignment(
                membershipEpisodeID: includedMembership.id,
                cohortID: includedCohort.id
            ),
            CohortAssignment(
                membershipEpisodeID: excludedMembership.id,
                cohortID: excludedCohort.id
            )
        ],
        education: [
            EducationEnrollment(
                personID: included.id,
                institutionContextID: context.id,
                actualGraduation: includedGraduation,
                status: .graduated
            ),
            EducationEnrollment(
                personID: excluded.id,
                institutionContextID: context.id,
                actualGraduation: excludedGraduation,
                status: .withdrawn
            )
        ],
        assertions: includedAssertions + [excludedAssertion],
        sources: [sourceA, sourceB]
    )
    let search = LocalSearch(schema: .localSearchPerson)
    try await search.upsert(CanonicalLocalSearchProjection().documents(
        people: [included, excluded],
        canonical: canonical
    ))
    let graduationRange = try PartialDateRange(
        start: PartialDate.year(2020),
        end: PartialDate.year(2026)
    )
    let query = LocalSearchQuery(
        filter: .and([
            .condition(.init(
                field: LocalSearchPersonField.cohort,
                operator: .containsAny,
                value: .uuids([UUID(), includedCohort.id])
            )),
            .not(.condition(.init(
                field: LocalSearchPersonField.cohort,
                operator: .containsAny,
                value: .uuids([excludedCohort.id])
            ))),
            .condition(.init(
                field: LocalSearchPersonField.membershipStatus,
                operator: .containsAny,
                value: .strings([MembershipStatus.active.rawValue])
            )),
            .condition(.init(
                field: LocalSearchPersonField.educationStatus,
                operator: .containsAny,
                value: .strings([EducationStatus.graduated.rawValue])
            )),
            .condition(.init(
                field: LocalSearchPersonField.educationGraduation,
                operator: .between,
                value: .dateRange(graduationRange)
            )),
            .condition(.init(
                field: LocalSearchPersonField.location,
                operator: .containsAny,
                value: .strings(["Kyoto", "Tokyo"])
            )),
            .condition(.init(
                field: LocalSearchPersonField.timeZone,
                operator: .containsAny,
                value: .strings(["Asia/Tokyo"])
            )),
            .condition(.init(
                field: LocalSearchPersonField.language,
                operator: .containsAny,
                value: .strings(["ja"])
            )),
            .condition(.init(
                field: LocalSearchPersonField.source,
                operator: .containsAny,
                value: .uuids([sourceA.id])
            )),
            .condition(.init(
                field: LocalSearchPersonField.assertionReviewStatus,
                operator: .containsAny,
                value: .strings([AssertionReviewStatus.accepted.rawValue])
            )),
            .condition(.init(
                field: LocalSearchPersonField.assertionConfidence,
                operator: .greaterThanOrEqual,
                value: .number(0.8)
            )),
            .condition(.init(
                field: LocalSearchPersonField.assertionSensitivity,
                operator: .containsAny,
                value: .strings([Sensitivity.ordinary.rawValue])
            )),
            .condition(.init(
                field: LocalSearchPersonField.assertionFreshness,
                operator: .afterRelativeDays,
                value: .integer(90)
            ))
        ]),
        referenceDate: searchReferenceDate
    )

    let page = try await search.search(query)
    #expect(page.hits.map(\.personID) == [included.id])

    let saved = SavedView(
        name: "Canonical compound",
        filter: try #require(query.filter),
        sorts: [.init(field: LocalSearchPersonField.educationGraduation)]
    )
    let portable = try JSONDecoder().decode(
        SavedView.self,
        from: JSONEncoder().encode(saved)
    )
    let savedPage = try await search.search(
        savedView: portable,
        referenceDate: searchReferenceDate
    )
    #expect(savedPage.hits.map(\.personID) == [included.id])
}

@Test func localSearchExecutesCompoundAndOrNotFilters() async throws {
    let expected = fixedPerson(
        "Aya",
        role: "Engineer",
        tags: ["Tokyo"],
        circle: .friends
    )
    let excluded = fixedPerson(
        "Ben",
        role: "Designer",
        tags: ["Design"],
        circle: .friends,
        doNotContact: true
    )
    let wrongCircle = fixedPerson(
        "Chika",
        role: "Engineer",
        tags: ["Tokyo"],
        circle: .community
    )
    let search = LocalSearch()
    try await search.upsert([expected, excluded, wrongCircle])

    let filter: FilterNode = .and([
        .condition(.init(
            field: LocalSearchPersonField.relationshipCircle,
            operator: .equals,
            value: .string(RelationshipCircle.friends.rawValue)
        )),
        .or([
            .condition(.init(
                field: LocalSearchPersonField.role,
                operator: .equals,
                value: .string("engineer")
            )),
            .condition(.init(
                field: LocalSearchPersonField.tag,
                operator: .containsAny,
                value: .strings(["design"])
            ))
        ]),
        .not(.condition(.init(
            field: LocalSearchPersonField.doNotContact,
            operator: .equals,
            value: .boolean(true)
        )))
    ])
    let page = try await search.search(LocalSearchQuery(
        filter: filter,
        referenceDate: searchReferenceDate
    ))

    #expect(page.hits.map(\.personID) == [expected.id])
    #expect(page.hits[0].matchReasons.contains {
        $0.fieldID == LocalSearchPersonField.doNotContact && $0.kind == .filterExclusion
    })
}

@Test func localSearchHandlesDatesRangesRelativeDaysAndUnknowns() async throws {
    let old = fixedPerson(
        "Old contact",
        lastInteractionAt: searchReferenceDate.addingTimeInterval(-200 * 86_400)
    )
    let recent = fixedPerson(
        "Recent contact",
        lastInteractionAt: searchReferenceDate.addingTimeInterval(-10 * 86_400)
    )
    let unknown = fixedPerson("Unknown contact")
    let graduated = LocalSearchDocument(
        person: old,
        filterFields: [
            "education.graduation": [.partialDate(try .year(2021))]
        ]
    )
    let search = LocalSearch()
    try await search.upsert([
        graduated,
        LocalSearchDocument(person: recent),
        LocalSearchDocument(person: unknown)
    ])

    let staleOrUnknown: FilterNode = .or([
        .condition(.init(
            field: LocalSearchPersonField.lastInteractionAt,
            operator: .beforeRelativeDays,
            value: .integer(180)
        )),
        .condition(.init(
            field: LocalSearchPersonField.lastInteractionAt,
            operator: .isUnknown
        ))
    ])
    let stalePage = try await search.search(LocalSearchQuery(
        filter: staleOrUnknown,
        referenceDate: searchReferenceDate
    ))
    #expect(Set(stalePage.hits.map(\.personID)) == [old.id, unknown.id])

    let graduationWindow = try PartialDateRange(
        start: .year(2020),
        end: .year(2022)
    )
    let rangePage = try await search.search(LocalSearchQuery(
        filter: .condition(.init(
            field: "education.graduation",
            operator: .between,
            value: .dateRange(graduationWindow)
        )),
        referenceDate: searchReferenceDate
    ))
    #expect(rangePage.hits.map(\.personID) == [old.id])
}

@Test func localSearchSortsWithDirectionIndependentUnknownPlacement() async throws {
    let oldest = fixedPerson(
        "C Oldest",
        lastInteractionAt: searchReferenceDate.addingTimeInterval(-100 * 86_400)
    )
    let newest = fixedPerson(
        "D Newest",
        lastInteractionAt: searchReferenceDate.addingTimeInterval(-2 * 86_400)
    )
    let unknownA = fixedPerson(
        "A Unknown",
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    )
    let unknownB = fixedPerson(
        "B Unknown",
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    )
    let search = LocalSearch()
    try await search.upsert([oldest, newest, unknownB, unknownA])

    let unknownFirst = try await search.search(LocalSearchQuery(
        sorts: [.init(
            field: LocalSearchPersonField.lastInteractionAt,
            direction: .descending,
            unknownPlacement: .first
        )],
        referenceDate: searchReferenceDate
    ))
    #expect(unknownFirst.hits.map(\.personID) == [
        unknownA.id, unknownB.id, newest.id, oldest.id
    ])

    let unknownLast = try await search.search(LocalSearchQuery(
        sorts: [.init(
            field: LocalSearchPersonField.lastInteractionAt,
            direction: .ascending,
            unknownPlacement: .last
        )],
        referenceDate: searchReferenceDate
    ))
    #expect(unknownLast.hits.map(\.personID) == [
        oldest.id, newest.id, unknownA.id, unknownB.id
    ])
}

@Test func localSearchRebuildAndResultPaginationUseStableCursors() async throws {
    let people = ["E", "A", "D", "B", "C"].map {
        fixedPerson($0)
    }
    let search = LocalSearch()
    let metadata = try await search.rebuild(
        from: CollectionLocalSearchRebuildSource(people: people),
        batchSize: 2
    )
    #expect(metadata.documentCount == 5)

    let query = LocalSearchQuery(referenceDate: searchReferenceDate, localeIdentifier: "en_US")
    let first = try await search.search(query, page: .init(limit: 2))
    let firstCursor = try #require(first.nextCursor)
    let second = try await search.search(query, page: .init(limit: 2, cursor: firstCursor))
    let secondCursor = try #require(second.nextCursor)
    let third = try await search.search(query, page: .init(limit: 2, cursor: secondCursor))

    #expect(first.totalCount == 5)
    #expect(first.hits.count == 2)
    #expect(second.hits.count == 2)
    #expect(third.hits.count == 1)
    #expect(third.nextCursor == nil)
    #expect(Set((first.hits + second.hits + third.hits).map(\.personID)) == Set(people.map(\.id)))

    await #expect(throws: LocalSearchError.cursorDoesNotMatchQuery) {
        try await search.search(
            LocalSearchQuery(text: "A", referenceDate: searchReferenceDate),
            page: .init(limit: 2, cursor: firstCursor)
        )
    }

    try await search.upsert([fixedPerson("F")])
    await #expect(throws: LocalSearchError.staleCursor) {
        try await search.search(query, page: .init(limit: 2, cursor: firstCursor))
    }
}

@Test func localSearchPersistsRestoresAndRejectsCorruptDerivedIndexes() async throws {
    let persistedAt = Date(timeIntervalSince1970: 2_100_000_000)
    let persistence = InMemoryLocalSearchIndexPersistence()
    let firstBackend = InMemoryLocalSearchIndex(
        persistence: persistence,
        now: { persistedAt }
    )
    let person = fixedPerson("Persisted")
    let firstSearch = LocalSearch(index: firstBackend)
    try await firstSearch.upsert([person])

    let secondBackend = InMemoryLocalSearchIndex(persistence: persistence)
    let secondSearch = LocalSearch(index: secondBackend)
    let outcome = try await secondSearch.restore()
    guard case let .restored(metadata) = outcome else {
        Issue.record("Expected the local-only derived index to restore")
        return
    }
    #expect(metadata.documentCount == 1)
    let restoredPage = try await secondSearch.search(LocalSearchQuery(
        text: "persisted",
        referenceDate: searchReferenceDate
    ))
    #expect(restoredPage.hits.map(\.personID) == [person.id])

    let valid = try #require(await persistence.storedSnapshot())
    let corrupt = try LocalSearchPersistedIndex(
        schemaVersion: valid.schemaVersion,
        generation: valid.generation,
        updatedAt: valid.updatedAt,
        documents: valid.documents,
        checksum: "corrupt"
    )
    await persistence.replace(with: corrupt)
    let thirdSearch = LocalSearch(index: InMemoryLocalSearchIndex(persistence: persistence))
    #expect(try await thirdSearch.restore() == .rebuildRequired(.checksum))
    #expect(await persistence.storedSnapshot() == nil)
}

@Test func fileSearchPersistenceSurvivesRecreationAndRecoversFromCorruption() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeepsakeSearch-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("index.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let persistence = FileLocalSearchIndexPersistence(fileURL: fileURL)
    let person = fixedPerson("On disk")
    let first = LocalSearch(index: InMemoryLocalSearchIndex(persistence: persistence))
    try await first.upsert([person])

    let restored = LocalSearch(index: InMemoryLocalSearchIndex(
        persistence: FileLocalSearchIndexPersistence(fileURL: fileURL)
    ))
    guard case let .restored(metadata) = try await restored.restore() else {
        Issue.record("Expected the file-backed index to restore")
        return
    }
    #expect(metadata.documentCount == 1)
    #expect(try await restored.search(LocalSearchQuery(
        text: "disk",
        referenceDate: searchReferenceDate
    )).hits.map(\.personID) == [person.id])

    try Data("not an index".utf8).write(to: fileURL, options: .atomic)
    let recoveredPersistence = FileLocalSearchIndexPersistence(fileURL: fileURL)
    #expect(try await recoveredPersistence.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func localSearchValidatesCanonicalSavedViewsBeforeExecution() async throws {
    let search = LocalSearch()
    try await search.upsert([fixedPerson("Valid")])
    let view = SavedView(
        name: "Invalid external predicate",
        filter: .condition(.init(
            field: "arbitrary.executablePredicate",
            operator: .equals,
            value: .string("x")
        ))
    )

    await #expect(throws: LocalSearchError.invalidQuery([
        .unknownField("arbitrary.executablePredicate")
    ])) {
        try await search.search(
            savedView: view,
            referenceDate: searchReferenceDate
        )
    }
}
