import Foundation
import Testing
@testable import RelationshipCore

@Test func contextHierarchyReturnsRootFirstPathsAndRejectsCycles() throws {
    let organization = Context(kind: .organization, names: .init("Foundation"))
    let program = Context(parentContextID: organization.id, kind: .program, names: .init("Scholars"))
    let chapter = Context(parentContextID: program.id, kind: .chapter, names: .init("Tokyo"))
    let hierarchy = try ContextHierarchy(contexts: [chapter, organization, program])

    #expect(try hierarchy.path(to: chapter.id).map(\.id) == [organization.id, program.id, chapter.id])
    #expect(try hierarchy.children(of: organization.id).map(\.id) == [program.id])
    #expect(Set(try hierarchy.descendants(of: organization.id).map(\.id)) == [program.id, chapter.id])

    let firstID = UUID()
    let secondID = UUID()
    let first = Context(id: firstID, parentContextID: secondID, kind: .program, names: .init("First"))
    let second = Context(id: secondID, parentContextID: firstID, kind: .track, names: .init("Second"))
    #expect(throws: ContextHierarchyError.self) {
        try ContextHierarchy(contexts: [first, second])
    }
}

@Test func relativeCohortUsesChronologicalRankNotDisplayedGeneration() throws {
    let fixture = try CohortFixture(includeMiddleRank: true)
    let result = RelativeCohortCalculator().relativePosition(
        subject: fixture.earlierPersonID,
        observer: fixture.laterPersonID,
        context: fixture.context.id,
        scheme: fixture.scheme.id,
        asOf: try PartialDate.day(1, month: 6, year: 2026).earliestInstant,
        schemes: [fixture.scheme],
        cohorts: fixture.cohorts,
        memberships: fixture.memberships,
        assignments: fixture.assignments
    )

    #expect(result.position == .earlier)
    #expect(result.rankDelta == -2)
    #expect(result.cohortDistance == 2)
    #expect(result.evidence.map(\.chronologicalRank) == [1, 3])
    // Visible generation numbers count in the opposite direction.
    #expect(fixture.cohorts.first?.displayNumber == 10)
    #expect(fixture.cohorts.last?.displayNumber == 8)
}

@Test func cohortDistanceIsHiddenAcrossAnUnpopulatedRank() throws {
    let fixture = try CohortFixture(includeMiddleRank: false)
    let result = RelativeCohortCalculator().relativePosition(
        subject: fixture.earlierPersonID,
        observer: fixture.laterPersonID,
        context: fixture.context.id,
        scheme: fixture.scheme.id,
        asOf: try PartialDate.day(1, month: 6, year: 2026).earliestInstant,
        schemes: [fixture.scheme],
        cohorts: fixture.cohorts,
        memberships: fixture.memberships,
        assignments: fixture.assignments
    )

    #expect(result.position == .earlier)
    #expect(result.rankDelta == -2)
    #expect(result.cohortDistance == nil)

    let report = CanonicalRelationshipValidator().validate(
        contexts: [fixture.context],
        schemes: [fixture.scheme],
        cohorts: fixture.cohorts,
        memberships: fixture.memberships,
        assignments: fixture.assignments
    )
    #expect(report.warnings.contains { $0.code == "cohortScheme.distanceCoverageGap" })
}

@Test func datedTransfersResolveTheAssignmentActiveAtTheComparisonInstant() throws {
    let context = Context(kind: .program, names: .init("Program"))
    let scheme = CohortScheme(
        contextID: context.id,
        kind: .numberedGeneration,
        name: .init("Generation"),
        orderingMethod: .chronologicalRank,
        distanceIsMeaningful: true
    )
    let cohort1 = Cohort(schemeID: scheme.id, labels: .init("1"), chronologicalRank: 1)
    let cohort2 = Cohort(schemeID: scheme.id, labels: .init("2"), chronologicalRank: 2)
    let movingPerson = UUID()
    let comparisonPerson = UUID()
    let movingMembership = MembershipEpisode(personID: movingPerson, contextID: context.id)
    let comparisonMembership = MembershipEpisode(personID: comparisonPerson, contextID: context.id)
    let assignments = [
        CohortAssignment(
            membershipEpisodeID: movingMembership.id,
            cohortID: cohort1.id,
            endDate: try .year(2024),
            assignmentKind: .initial
        ),
        CohortAssignment(
            membershipEpisodeID: movingMembership.id,
            cohortID: cohort2.id,
            startDate: try .year(2025),
            assignmentKind: .transferred
        ),
        CohortAssignment(membershipEpisodeID: comparisonMembership.id, cohortID: cohort2.id)
    ]
    let calculator = RelativeCohortCalculator()
    let commonArguments = (
        schemes: [scheme],
        cohorts: [cohort1, cohort2],
        memberships: [movingMembership, comparisonMembership],
        assignments: assignments
    )

    let beforeTransfer = calculator.relativePosition(
        subject: movingPerson,
        observer: comparisonPerson,
        context: context.id,
        scheme: scheme.id,
        asOf: try PartialDate.day(1, month: 7, year: 2024).earliestInstant,
        schemes: commonArguments.schemes,
        cohorts: commonArguments.cohorts,
        memberships: commonArguments.memberships,
        assignments: commonArguments.assignments
    )
    let afterTransfer = calculator.relativePosition(
        subject: movingPerson,
        observer: comparisonPerson,
        context: context.id,
        scheme: scheme.id,
        asOf: try PartialDate.day(1, month: 7, year: 2025).earliestInstant,
        schemes: commonArguments.schemes,
        cohorts: commonArguments.cohorts,
        memberships: commonArguments.memberships,
        assignments: commonArguments.assignments
    )

    #expect(beforeTransfer.position == .earlier)
    #expect(afterTransfer.position == .peer)
}

@Test func validatorReportsOverlappingPrimaryAssignmentsInsteadOfDiscardingHistory() throws {
    let context = Context(kind: .program, names: .init("Program"))
    let scheme = CohortScheme(
        contextID: context.id,
        kind: .namedIntake,
        name: .init("Intake"),
        orderingMethod: .chronologicalRank
    )
    let first = Cohort(schemeID: scheme.id, labels: .init("Spring"), chronologicalRank: 1)
    let second = Cohort(schemeID: scheme.id, labels: .init("Autumn"), chronologicalRank: 2)
    let membership = MembershipEpisode(personID: UUID(), contextID: context.id)
    let assignments = [
        CohortAssignment(
            membershipEpisodeID: membership.id,
            cohortID: first.id,
            startDate: try .year(2025),
            endDate: try .year(2026),
            isPrimary: true
        ),
        CohortAssignment(
            membershipEpisodeID: membership.id,
            cohortID: second.id,
            startDate: try .year(2026),
            isPrimary: true
        )
    ]

    let report = CanonicalRelationshipValidator().validate(
        contexts: [context],
        schemes: [scheme],
        cohorts: [first, second],
        memberships: [membership],
        assignments: assignments
    )
    #expect(report.errors.contains { $0.code == "cohortAssignment.overlappingPrimary" })

    let result = RelativeCohortCalculator().relativePosition(
        subject: membership.personID,
        observer: membership.personID,
        context: context.id,
        scheme: scheme.id,
        asOf: try PartialDate.day(1, month: 6, year: 2026).earliestInstant,
        schemes: [scheme],
        cohorts: [first, second],
        memberships: [membership],
        assignments: assignments
    )
    #expect(result.position == .unknown)
    #expect(result.unknownReason == .ambiguousAssignment)
}

@Test func universityGraduationIsOnlyTakenFromEducationEnrollment() throws {
    let enrollment = EducationEnrollment(
        personID: UUID(),
        institutionContextID: UUID(),
        expectedGraduation: try .year(2027),
        status: .enrolled
    )
    let graduated = EducationEnrollment(
        personID: enrollment.personID,
        institutionContextID: enrollment.institutionContextID,
        actualGraduation: try .month(3, of: 2026),
        status: .completed
    )

    #expect(!enrollment.hasUniversityGraduated)
    #expect(graduated.hasUniversityGraduated)
}

private struct CohortFixture {
    let context: Context
    let scheme: CohortScheme
    let cohorts: [Cohort]
    let memberships: [MembershipEpisode]
    let assignments: [CohortAssignment]
    let earlierPersonID: UUID
    let laterPersonID: UUID

    init(includeMiddleRank: Bool) throws {
        context = Context(kind: .program, names: .init("Scholarship"))
        scheme = CohortScheme(
            contextID: context.id,
            kind: .numberedGeneration,
            name: .init("Generation"),
            orderingMethod: .chronologicalRank,
            seniorityRule: .earlierIsSenior,
            distanceIsMeaningful: true
        )
        let first = Cohort(
            schemeID: scheme.id,
            labels: .init("10th generation"),
            displayNumber: 10,
            chronologicalRank: 1
        )
        let middle = Cohort(
            schemeID: scheme.id,
            labels: .init("9th generation"),
            displayNumber: 9,
            chronologicalRank: 2
        )
        let last = Cohort(
            schemeID: scheme.id,
            labels: .init("8th generation"),
            displayNumber: 8,
            chronologicalRank: 3
        )
        cohorts = includeMiddleRank ? [first, middle, last] : [first, last]
        earlierPersonID = UUID()
        laterPersonID = UUID()
        let earlierMembership = MembershipEpisode(personID: earlierPersonID, contextID: context.id)
        let laterMembership = MembershipEpisode(personID: laterPersonID, contextID: context.id)
        memberships = [earlierMembership, laterMembership]
        assignments = [
            CohortAssignment(membershipEpisodeID: earlierMembership.id, cohortID: first.id),
            CohortAssignment(membershipEpisodeID: laterMembership.id, cohortID: last.id)
        ]
    }
}
