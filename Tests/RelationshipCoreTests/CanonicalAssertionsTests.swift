import Foundation
import Testing
@testable import RelationshipCore

@Test func partialDatesPreservePrecisionAndValidateGregorianDates() throws {
    let yearOnly = try PartialDate.year(2027)
    let monthOnly = try PartialDate.month(3, of: 2027)
    let leapDay = try PartialDate.day(29, month: 2, year: 2028)

    #expect(yearOnly.precision == .year)
    #expect(yearOnly.month == nil)
    #expect(yearOnly.description == "2027")
    #expect(monthOnly.description == "2027-03")
    #expect(leapDay.description == "2028-02-29")

    #expect(throws: PartialDateValidationError.self) {
        try PartialDate.day(29, month: 2, year: 2027)
    }
    #expect(throws: PartialDateValidationError.self) {
        try PartialDate(year: 2027, month: 3, precision: .year)
    }

    let data = try JSONEncoder().encode(monthOnly)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["precision"] as? String == "month")
    #expect(object["month"] as? Int == 3)
    #expect(object["day"] == nil)
    #expect(try JSONDecoder().decode(PartialDate.self, from: data) == monthOnly)
}

@Test func partialDateRangesUseWholeKnownPrecision() throws {
    let range = try PartialDateRange(start: .month(3, of: 2027), end: .year(2027))
    let april = try PartialDate.day(15, month: 4, year: 2027).earliestInstant
    let nextYear = try PartialDate.day(1, month: 1, year: 2028).earliestInstant

    #expect(range.contains(april))
    #expect(!range.contains(nextYear))
    #expect(throws: PartialDateValidationError.self) {
        try PartialDateRange(start: .year(2028), end: .year(2027))
    }
}

@Test func sourcedTypedAssertionRoundTripsWithEvidenceAndPolicies() throws {
    let source = SourceArtifact(
        kind: .pdf,
        originalFilename: "program.pdf",
        sha256: "deadbeef",
        parserVersion: "pdf-1"
    )
    let unit = ArtifactUnit(sourceID: source.id, kind: .page, index: 2)
    let evidence = try EvidenceSpan(
        unitID: unit.id,
        textRange: TextEvidenceRange(startUTF16Offset: 40, endUTF16Offset: 58),
        boundingBox: NormalizedBoundingBox(x: 0.1, y: 0.2, width: 0.4, height: 0.1),
        excerptHash: "abc123"
    )
    let subjectID = UUID()
    let assertion = try AssertionEnvelope(
        subjectID: subjectID,
        predicateID: "education.expectedGraduation",
        value: .partialDate(.month(3, of: 2027)),
        sourceID: source.id,
        evidenceIDs: [evidence.id],
        origin: .imported,
        confidence: 0.82,
        reviewStatus: .pending,
        certainty: .approximate,
        observedAt: Date(timeIntervalSince1970: 1_700_000_000),
        assertedAt: Date(timeIntervalSince1970: 1_700_000_100),
        sensitivity: .private,
        usePolicy: .init(
            search: .include,
            remindersAllowed: true,
            notifications: .genericOnly,
            sharing: .exclude,
            mention: .ask,
            ai: .allowOnDevice
        )
    )

    let data = try JSONEncoder().encode(assertion)
    let decoded = try JSONDecoder().decode(AssertionEnvelope.self, from: data)

    #expect(decoded == assertion)
    #expect(decoded.subjectID == subjectID)
    #expect(decoded.value.kind == .partialDate)
    #expect(decoded.evidenceIDs == [evidence.id])
    #expect(decoded.origin == .imported)
}

@Test func provenanceValidationRejectsUntraceableOrInvalidClaims() {
    #expect(throws: AssertionValidationError.self) {
        try AssertionEnvelope(
            subjectID: UUID(),
            predicateID: "context.role",
            value: .text("Mentor"),
            evidenceIDs: [UUID()],
            origin: .manual
        )
    }

    #expect(throws: AssertionValidationError.self) {
        try AssertionEnvelope(
            subjectID: UUID(),
            predicateID: "context.role",
            value: .text("Mentor"),
            origin: .model,
            confidence: 1.01
        )
    }

    #expect(throws: EvidenceLocationValidationError.self) {
        try NormalizedBoundingBox(x: 0.8, y: 0.1, width: 0.3, height: 0.2)
    }
}

@Test func newCanonicalDataDoesNotAuthorizeAnyAIPathByDefault() {
    #expect(SourceArtifact(kind: .userNote).aiPolicy == .deny)
    #expect(AssertionUsePolicy().ai == .deny)
}
