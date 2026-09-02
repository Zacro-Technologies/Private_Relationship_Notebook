import Foundation

public enum ContextKind: String, Codable, CaseIterable, Sendable {
    case organization
    case program
    case university
    case school
    case company
    case club
    case team
    case chapter
    case track
    case project
    case community
    case other
}

public struct Context: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var parentContextID: UUID?
    public var kind: ContextKind
    public var names: LocalizedText
    public var archivedAt: Date?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        parentContextID: UUID? = nil,
        kind: ContextKind,
        names: LocalizedText,
        archivedAt: Date? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.parentContextID = parentContextID
        self.kind = kind
        self.names = names
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }
}

public enum ContextHierarchyError: Error, Equatable, Sendable {
    case duplicateContextID(UUID)
    case selfParent(UUID)
    case missingParent(contextID: UUID, parentID: UUID)
    case cycle([UUID])
    case unknownContext(UUID)
}

/// A validated, read-only view over nested contexts.
public struct ContextHierarchy: Sendable {
    private let byID: [UUID: Context]

    public init(contexts: [Context]) throws {
        var byID: [UUID: Context] = [:]
        for context in contexts {
            guard byID.updateValue(context, forKey: context.id) == nil else {
                throw ContextHierarchyError.duplicateContextID(context.id)
            }
            guard context.parentContextID != context.id else {
                throw ContextHierarchyError.selfParent(context.id)
            }
        }
        for context in contexts {
            if let parentID = context.parentContextID, byID[parentID] == nil {
                throw ContextHierarchyError.missingParent(contextID: context.id, parentID: parentID)
            }
        }

        for context in contexts {
            var orderedPath: [UUID] = []
            var seen = Set<UUID>()
            var cursor: UUID? = context.id
            while let id = cursor {
                if !seen.insert(id).inserted {
                    let cycleStart = orderedPath.firstIndex(of: id) ?? 0
                    throw ContextHierarchyError.cycle(Array(orderedPath[cycleStart...]) + [id])
                }
                orderedPath.append(id)
                cursor = byID[id]?.parentContextID
            }
        }

        self.byID = byID
    }

    public func context(id: UUID) -> Context? { byID[id] }

    public func children(of id: UUID) throws -> [Context] {
        guard byID[id] != nil else { throw ContextHierarchyError.unknownContext(id) }
        return byID.values
            .filter { $0.parentContextID == id }
            .sorted { $0.names.fallback.localizedStandardCompare($1.names.fallback) == .orderedAscending }
    }

    /// Root-first hierarchy path, including the requested context.
    public func path(to id: UUID) throws -> [Context] {
        guard byID[id] != nil else { throw ContextHierarchyError.unknownContext(id) }
        var path: [Context] = []
        var cursor: UUID? = id
        while let currentID = cursor, let current = byID[currentID] {
            path.append(current)
            cursor = current.parentContextID
        }
        return path.reversed()
    }

    public func descendants(of id: UUID) throws -> [Context] {
        guard byID[id] != nil else { throw ContextHierarchyError.unknownContext(id) }
        var result: [Context] = []
        var pending = [id]
        while let parentID = pending.popLast() {
            let children = byID.values.filter { $0.parentContextID == parentID }
            result.append(contentsOf: children)
            pending.append(contentsOf: children.map(\.id))
        }
        return result
    }
}

public enum CohortSchemeKind: String, Codable, CaseIterable, Sendable {
    case numberedGeneration
    case entryYear
    case graduationClass
    case namedIntake
    case seasonalIntake
    case projectCycle
    case rollingEntry
    case unorderedGroup
}

public enum CohortOrderingMethod: String, Codable, CaseIterable, Sendable {
    /// Cohorts carry an explicit rank. Lower always means earlier in time.
    case chronologicalRank
    case unordered
}

public enum CohortSeniorityRule: String, Codable, CaseIterable, Sendable {
    case earlierIsSenior
    case laterIsSenior
    case noSeniority
}

public struct CohortScheme: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let contextID: UUID
    public var kind: CohortSchemeKind
    public var name: LocalizedText
    public var orderingMethod: CohortOrderingMethod
    public var seniorityRule: CohortSeniorityRule
    /// True only when every integer rank between two cohorts is meaningful.
    public var distanceIsMeaningful: Bool
    public var archivedAt: Date?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        contextID: UUID,
        kind: CohortSchemeKind,
        name: LocalizedText,
        orderingMethod: CohortOrderingMethod,
        seniorityRule: CohortSeniorityRule = .noSeniority,
        distanceIsMeaningful: Bool = false,
        archivedAt: Date? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.contextID = contextID
        self.kind = kind
        self.name = name
        self.orderingMethod = orderingMethod
        self.seniorityRule = seniorityRule
        self.distanceIsMeaningful = distanceIsMeaningful
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }
}

public struct Cohort: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let schemeID: UUID
    public var labels: LocalizedText
    public var displayNumber: Int?
    public var startDate: PartialDate?
    public var endDate: PartialDate?
    /// Lower rank always means earlier in time, independent of display label.
    public var chronologicalRank: Int?
    public var archivedAt: Date?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        schemeID: UUID,
        labels: LocalizedText,
        displayNumber: Int? = nil,
        startDate: PartialDate? = nil,
        endDate: PartialDate? = nil,
        chronologicalRank: Int? = nil,
        archivedAt: Date? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.schemeID = schemeID
        self.labels = labels
        self.displayNumber = displayNumber
        self.startDate = startDate
        self.endDate = endDate
        self.chronologicalRank = chronologicalRank
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }
}

public enum MembershipStatus: String, Codable, CaseIterable, Sendable {
    case active
    case completed
    case withdrawn
    case transferred
    case suspended
    case unknown
}

public struct MembershipEpisode: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let personID: UUID
    public let contextID: UUID
    public var startDate: PartialDate?
    public var endDate: PartialDate?
    public var status: MembershipStatus
    public let assertionID: UUID?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        personID: UUID,
        contextID: UUID,
        startDate: PartialDate? = nil,
        endDate: PartialDate? = nil,
        status: MembershipStatus = .unknown,
        assertionID: UUID? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.personID = personID
        self.contextID = contextID
        self.startDate = startDate
        self.endDate = endDate
        self.status = status
        self.assertionID = assertionID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }

    public func isActive(at date: Date) -> Bool {
        Self.intervalContains(date, start: startDate, end: endDate)
    }

    fileprivate static func intervalContains(
        _ date: Date,
        start: PartialDate?,
        end: PartialDate?
    ) -> Bool {
        let beginsBefore = start.map { $0.earliestInstant <= date } ?? true
        let endsAfter = end.map { date <= $0.latestInstant } ?? true
        return beginsBefore && endsAfter
    }
}

public enum CohortAssignmentKind: String, Codable, CaseIterable, Sendable {
    case initial
    case transferred
    case repeated
    case secondary
}

public struct CohortAssignment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let membershipEpisodeID: UUID
    public let cohortID: UUID
    public var startDate: PartialDate?
    public var endDate: PartialDate?
    public var assignmentKind: CohortAssignmentKind
    public var isPrimary: Bool
    public let assertionID: UUID?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        membershipEpisodeID: UUID,
        cohortID: UUID,
        startDate: PartialDate? = nil,
        endDate: PartialDate? = nil,
        assignmentKind: CohortAssignmentKind = .initial,
        isPrimary: Bool = true,
        assertionID: UUID? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.membershipEpisodeID = membershipEpisodeID
        self.cohortID = cohortID
        self.startDate = startDate
        self.endDate = endDate
        self.assignmentKind = assignmentKind
        self.isPrimary = isPrimary
        self.assertionID = assertionID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }

    public func isActive(at date: Date) -> Bool {
        MembershipEpisode.intervalContains(date, start: startDate, end: endDate)
    }
}

public struct RoleDefinition: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let contextID: UUID
    public var labels: LocalizedText
    public var orderingDimension: String?
    public var order: Int?
    public var archivedAt: Date?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        contextID: UUID,
        labels: LocalizedText,
        orderingDimension: String? = nil,
        order: Int? = nil,
        archivedAt: Date? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.contextID = contextID
        self.labels = labels
        self.orderingDimension = orderingDimension
        self.order = order
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }
}

public struct RoleAssignment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let membershipEpisodeID: UUID
    public var roleDefinitionID: UUID?
    public var roleLabel: LocalizedText
    public var startDate: PartialDate?
    public var endDate: PartialDate?
    public let assertionID: UUID?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        membershipEpisodeID: UUID,
        roleDefinitionID: UUID? = nil,
        roleLabel: LocalizedText,
        startDate: PartialDate? = nil,
        endDate: PartialDate? = nil,
        assertionID: UUID? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.membershipEpisodeID = membershipEpisodeID
        self.roleDefinitionID = roleDefinitionID
        self.roleLabel = roleLabel
        self.startDate = startDate
        self.endDate = endDate
        self.assertionID = assertionID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }
}

public enum EducationStatus: String, Codable, CaseIterable, Sendable {
    case prospective
    case enrolled
    case leaveOfAbsence
    case completed
    case withdrawn
    case graduated
    case unknown
}

public struct EducationEnrollment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let personID: UUID
    public let institutionContextID: UUID
    public var program: LocalizedText?
    public var degree: LocalizedText?
    public var startDate: PartialDate?
    public var endDate: PartialDate?
    public var expectedGraduation: PartialDate?
    public var actualGraduation: PartialDate?
    public var status: EducationStatus
    public let assertionID: UUID?
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        personID: UUID,
        institutionContextID: UUID,
        program: LocalizedText? = nil,
        degree: LocalizedText? = nil,
        startDate: PartialDate? = nil,
        endDate: PartialDate? = nil,
        expectedGraduation: PartialDate? = nil,
        actualGraduation: PartialDate? = nil,
        status: EducationStatus = .unknown,
        assertionID: UUID? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.personID = personID
        self.institutionContextID = institutionContextID
        self.program = program
        self.degree = degree
        self.startDate = startDate
        self.endDate = endDate
        self.expectedGraduation = expectedGraduation
        self.actualGraduation = actualGraduation
        self.status = status
        self.assertionID = assertionID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }

    /// Graduation is never inferred from cohort, age, work, or another context.
    public var hasUniversityGraduated: Bool {
        actualGraduation != nil || status == .graduated
    }
}

public enum RelativeCohortPosition: String, Codable, CaseIterable, Sendable {
    case earlier
    case peer
    case later
    case unknown
}

public enum RelativeCohortUnknownReason: String, Codable, Sendable {
    case schemeNotFound
    case schemeContextMismatch
    case schemeUnordered
    case noActiveMembership
    case noActiveAssignment
    case ambiguousAssignment
    case cohortNotFound
    case rankUnavailable
}

public struct RelativeCohortEvidence: Codable, Hashable, Sendable {
    public let personID: UUID
    public let membershipEpisodeID: UUID
    public let assignmentID: UUID
    public let cohortID: UUID
    public let chronologicalRank: Int
    public let assertionID: UUID?

    public init(
        personID: UUID,
        membershipEpisodeID: UUID,
        assignmentID: UUID,
        cohortID: UUID,
        chronologicalRank: Int,
        assertionID: UUID?
    ) {
        self.personID = personID
        self.membershipEpisodeID = membershipEpisodeID
        self.assignmentID = assignmentID
        self.cohortID = cohortID
        self.chronologicalRank = chronologicalRank
        self.assertionID = assertionID
    }
}

public struct RelativePositionResult: Codable, Hashable, Sendable {
    public let subjectID: UUID
    public let observerID: UUID
    public let contextID: UUID
    public let schemeID: UUID
    public let asOf: Date
    public let position: RelativeCohortPosition
    /// Subject rank minus observer rank. Negative means earlier.
    public let rankDelta: Int?
    /// Absolute distance, present only when the scheme and populated ranks make
    /// every intervening step meaningful.
    public let cohortDistance: Int?
    public let evidence: [RelativeCohortEvidence]
    public let unknownReason: RelativeCohortUnknownReason?

    public init(
        subjectID: UUID,
        observerID: UUID,
        contextID: UUID,
        schemeID: UUID,
        asOf: Date,
        position: RelativeCohortPosition,
        rankDelta: Int?,
        cohortDistance: Int?,
        evidence: [RelativeCohortEvidence],
        unknownReason: RelativeCohortUnknownReason?
    ) {
        self.subjectID = subjectID
        self.observerID = observerID
        self.contextID = contextID
        self.schemeID = schemeID
        self.asOf = asOf
        self.position = position
        self.rankDelta = rankDelta
        self.cohortDistance = cohortDistance
        self.evidence = evidence
        self.unknownReason = unknownReason
    }
}

public struct RelativeCohortCalculator: Sendable {
    public init() {}

    public func relativePosition(
        subject subjectID: UUID,
        observer observerID: UUID,
        context contextID: UUID,
        scheme schemeID: UUID,
        asOf: Date,
        schemes: [CohortScheme],
        cohorts: [Cohort],
        memberships: [MembershipEpisode],
        assignments: [CohortAssignment]
    ) -> RelativePositionResult {
        guard let scheme = schemes.first(where: { $0.id == schemeID }) else {
            return unknown(.schemeNotFound)
        }
        guard scheme.contextID == contextID else {
            return unknown(.schemeContextMismatch)
        }
        guard scheme.orderingMethod == .chronologicalRank else {
            return unknown(.schemeUnordered)
        }

        let schemeCohorts = cohorts.filter { $0.schemeID == schemeID }
        let cohortByID = Self.indexByID(schemeCohorts)

        let subjectResolution = resolve(
            personID: subjectID,
            contextID: contextID,
            asOf: asOf,
            cohortByID: cohortByID,
            memberships: memberships,
            assignments: assignments
        )
        let observerResolution = resolve(
            personID: observerID,
            contextID: contextID,
            asOf: asOf,
            cohortByID: cohortByID,
            memberships: memberships,
            assignments: assignments
        )

        guard case let .resolved(subjectEvidence) = subjectResolution else {
            return unknown(subjectResolution.reason ?? .noActiveAssignment)
        }
        guard case let .resolved(observerEvidence) = observerResolution else {
            return unknown(observerResolution.reason ?? .noActiveAssignment)
        }

        let delta = subjectEvidence.chronologicalRank - observerEvidence.chronologicalRank
        let position: RelativeCohortPosition = delta < 0 ? .earlier : (delta > 0 ? .later : .peer)
        let distance: Int?
        if scheme.distanceIsMeaningful,
           Self.hasCompleteDistanceCoverage(
               from: subjectEvidence.chronologicalRank,
               to: observerEvidence.chronologicalRank,
               cohorts: schemeCohorts
           ) {
            distance = abs(delta)
        } else {
            distance = nil
        }

        return RelativePositionResult(
            subjectID: subjectID,
            observerID: observerID,
            contextID: contextID,
            schemeID: schemeID,
            asOf: asOf,
            position: position,
            rankDelta: delta,
            cohortDistance: distance,
            evidence: [subjectEvidence, observerEvidence],
            unknownReason: nil
        )

        func unknown(_ reason: RelativeCohortUnknownReason) -> RelativePositionResult {
            RelativePositionResult(
                subjectID: subjectID,
                observerID: observerID,
                contextID: contextID,
                schemeID: schemeID,
                asOf: asOf,
                position: .unknown,
                rankDelta: nil,
                cohortDistance: nil,
                evidence: [],
                unknownReason: reason
            )
        }
    }

    private enum Resolution {
        case resolved(RelativeCohortEvidence)
        case unresolved(RelativeCohortUnknownReason)

        var reason: RelativeCohortUnknownReason? {
            if case let .unresolved(reason) = self { return reason }
            return nil
        }
    }

    private func resolve(
        personID: UUID,
        contextID: UUID,
        asOf: Date,
        cohortByID: [UUID: Cohort],
        memberships: [MembershipEpisode],
        assignments: [CohortAssignment]
    ) -> Resolution {
        let activeMemberships = memberships.filter {
            $0.personID == personID && $0.contextID == contextID && $0.isActive(at: asOf)
        }
        guard !activeMemberships.isEmpty else { return .unresolved(.noActiveMembership) }

        let membershipByID = Self.indexByID(activeMemberships)
        let candidates = assignments.filter { assignment in
            membershipByID[assignment.membershipEpisodeID] != nil &&
                assignment.isActive(at: asOf) &&
                cohortByID[assignment.cohortID] != nil
        }
        guard !candidates.isEmpty else { return .unresolved(.noActiveAssignment) }

        let primary = candidates.filter(\.isPrimary)
        let selected: CohortAssignment
        if primary.count == 1 {
            selected = primary[0]
        } else if primary.count > 1 || candidates.count > 1 {
            return .unresolved(.ambiguousAssignment)
        } else {
            selected = candidates[0]
        }

        guard let cohort = cohortByID[selected.cohortID] else {
            return .unresolved(.cohortNotFound)
        }
        guard let rank = cohort.chronologicalRank else {
            return .unresolved(.rankUnavailable)
        }
        guard let membership = membershipByID[selected.membershipEpisodeID] else {
            return .unresolved(.noActiveMembership)
        }
        return .resolved(
            RelativeCohortEvidence(
                personID: personID,
                membershipEpisodeID: membership.id,
                assignmentID: selected.id,
                cohortID: cohort.id,
                chronologicalRank: rank,
                assertionID: selected.assertionID
            )
        )
    }

    private static func hasCompleteDistanceCoverage(
        from first: Int,
        to second: Int,
        cohorts: [Cohort]
    ) -> Bool {
        let ranks = Set(cohorts.compactMap(\.chronologicalRank))
        return Set(min(first, second)...max(first, second)).isSubset(of: ranks)
    }

    private static func indexByID<T: Identifiable>(_ values: [T]) -> [UUID: T] where T.ID == UUID {
        values.reduce(into: [:]) { result, value in
            if result[value.id] == nil { result[value.id] = value }
        }
    }
}

public struct CanonicalRelationshipValidator: Sendable {
    public init() {}

    public func validate(
        contexts: [Context],
        schemes: [CohortScheme],
        cohorts: [Cohort],
        memberships: [MembershipEpisode],
        assignments: [CohortAssignment],
        roleDefinitions: [RoleDefinition] = [],
        roleAssignments: [RoleAssignment] = [],
        educationEnrollments: [EducationEnrollment] = []
    ) -> CanonicalValidationReport {
        var issues: [CanonicalValidationIssue] = []

        issues += duplicateIssues(contexts, entityName: "context")
        issues += duplicateIssues(schemes, entityName: "cohortScheme")
        issues += duplicateIssues(cohorts, entityName: "cohort")
        issues += duplicateIssues(memberships, entityName: "membership")
        issues += duplicateIssues(assignments, entityName: "cohortAssignment")
        issues += duplicateIssues(roleDefinitions, entityName: "roleDefinition")
        issues += duplicateIssues(roleAssignments, entityName: "roleAssignment")
        issues += duplicateIssues(educationEnrollments, entityName: "educationEnrollment")

        let contextByID = indexByID(contexts)
        let schemeByID = indexByID(schemes)
        let cohortByID = indexByID(cohorts)
        let membershipByID = indexByID(memberships)
        let roleDefinitionByID = indexByID(roleDefinitions)

        for context in contexts {
            if context.parentContextID == context.id {
                issues.append(issue("context.selfParent", [context.id], String(localized: "A context cannot contain itself.")))
            } else if let parentID = context.parentContextID, contextByID[parentID] == nil {
                issues.append(issue("context.missingParent", [context.id, parentID], String(localized: "The parent context does not exist.")))
            }
        }
        issues += hierarchyCycleIssues(contexts: contexts, contextByID: contextByID)

        for scheme in schemes {
            if contextByID[scheme.contextID] == nil {
                issues.append(issue("cohortScheme.missingContext", [scheme.id, scheme.contextID], String(localized: "The cohort scheme's context does not exist.")))
            }
            if scheme.orderingMethod == .unordered {
                if scheme.distanceIsMeaningful {
                    issues.append(issue("cohortScheme.unorderedDistance", [scheme.id], String(localized: "An unordered scheme cannot expose cohort distance.")))
                }
                if scheme.seniorityRule != .noSeniority {
                    issues.append(issue("cohortScheme.unorderedSeniority", [scheme.id], String(localized: "An unordered scheme cannot define seniority.")))
                }
            }
        }

        let cohortsByScheme = Dictionary(grouping: cohorts, by: \.schemeID)
        for cohort in cohorts {
            guard let scheme = schemeByID[cohort.schemeID] else {
                issues.append(issue("cohort.missingScheme", [cohort.id, cohort.schemeID], String(localized: "The cohort scheme does not exist.")))
                continue
            }
            if scheme.orderingMethod == .unordered, cohort.chronologicalRank != nil {
                issues.append(issue("cohort.rankInUnorderedScheme", [cohort.id, scheme.id], String(localized: "An unordered cohort must not carry a chronological rank.")))
            }
            if !PartialDateRange.isOrdered(start: cohort.startDate, end: cohort.endDate) {
                issues.append(issue("cohort.reversedDates", [cohort.id], String(localized: "The cohort start date follows its end date.")))
            }
        }
        for (schemeID, members) in cohortsByScheme {
            let ranked = members.compactMap { cohort -> (Int, UUID)? in
                cohort.chronologicalRank.map { ($0, cohort.id) }
            }
            for group in Dictionary(grouping: ranked, by: \.0).values where group.count > 1 {
                issues.append(issue("cohort.duplicateRank", group.map(\.1), String(localized: "Chronological ranks must be unique within a cohort scheme.")))
            }
            if schemeByID[schemeID]?.distanceIsMeaningful == true,
               !ranked.isEmpty {
                let ranks = Set(ranked.map(\.0))
                let minimum = ranks.min()!
                let maximum = ranks.max()!
                if !Set(minimum...maximum).isSubset(of: ranks) {
                    issues.append(
                        CanonicalValidationIssue(
                            code: "cohortScheme.distanceCoverageGap",
                            severity: .warning,
                            entityIDs: [schemeID],
                            message: String(localized: "Cohort distance will be hidden across missing ranks.")
                        )
                    )
                }
            }
        }

        for membership in memberships {
            if contextByID[membership.contextID] == nil {
                issues.append(issue("membership.missingContext", [membership.id, membership.contextID], String(localized: "The membership context does not exist.")))
            }
            if !PartialDateRange.isOrdered(start: membership.startDate, end: membership.endDate) {
                issues.append(issue("membership.reversedDates", [membership.id], String(localized: "The membership start date follows its end date.")))
            }
        }

        for assignment in assignments {
            guard let membership = membershipByID[assignment.membershipEpisodeID] else {
                issues.append(issue("cohortAssignment.missingMembership", [assignment.id, assignment.membershipEpisodeID], String(localized: "The membership episode does not exist.")))
                continue
            }
            guard let cohort = cohortByID[assignment.cohortID] else {
                issues.append(issue("cohortAssignment.missingCohort", [assignment.id, assignment.cohortID], String(localized: "The cohort does not exist.")))
                continue
            }
            if let scheme = schemeByID[cohort.schemeID], scheme.contextID != membership.contextID {
                issues.append(issue("cohortAssignment.contextMismatch", [assignment.id, membership.id, cohort.id], String(localized: "The assigned cohort belongs to a different context.")))
            }
            if !PartialDateRange.isOrdered(start: assignment.startDate, end: assignment.endDate) {
                issues.append(issue("cohortAssignment.reversedDates", [assignment.id], String(localized: "The assignment start date follows its end date.")))
            }
        }

        for group in Dictionary(grouping: assignments.filter(\.isPrimary), by: \.membershipEpisodeID).values {
            for firstIndex in group.indices {
                for secondIndex in group.indices where secondIndex > firstIndex {
                    let first = group[firstIndex]
                    let second = group[secondIndex]
                    if intervalsOverlap(
                        first.startDate,
                        first.endDate,
                        second.startDate,
                        second.endDate
                    ) {
                        issues.append(issue("cohortAssignment.overlappingPrimary", [first.id, second.id], String(localized: "Primary cohort assignments may not overlap.")))
                    }
                }
            }
        }

        for role in roleAssignments {
            guard let membership = membershipByID[role.membershipEpisodeID] else {
                issues.append(issue("roleAssignment.missingMembership", [role.id, role.membershipEpisodeID], String(localized: "The membership episode does not exist.")))
                continue
            }
            if let definitionID = role.roleDefinitionID {
                guard let definition = roleDefinitionByID[definitionID] else {
                    issues.append(issue("roleAssignment.missingDefinition", [role.id, definitionID], String(localized: "The role definition does not exist.")))
                    continue
                }
                if definition.contextID != membership.contextID {
                    issues.append(issue("roleAssignment.contextMismatch", [role.id, definition.id, membership.id], String(localized: "The role definition belongs to a different context.")))
                }
            }
            if !PartialDateRange.isOrdered(start: role.startDate, end: role.endDate) {
                issues.append(issue("roleAssignment.reversedDates", [role.id], String(localized: "The role start date follows its end date.")))
            }
        }

        for enrollment in educationEnrollments {
            if contextByID[enrollment.institutionContextID] == nil {
                issues.append(issue("education.missingInstitution", [enrollment.id, enrollment.institutionContextID], String(localized: "The education institution context does not exist.")))
            }
            if !PartialDateRange.isOrdered(start: enrollment.startDate, end: enrollment.endDate) {
                issues.append(issue("education.reversedDates", [enrollment.id], String(localized: "The enrollment start date follows its end date.")))
            }
            if let actual = enrollment.actualGraduation,
               let start = enrollment.startDate,
               actual.latestInstant < start.earliestInstant {
                issues.append(issue("education.graduationBeforeStart", [enrollment.id], String(localized: "Actual graduation cannot precede enrollment.")))
            }
        }

        return CanonicalValidationReport(issues: issues)
    }

    private func hierarchyCycleIssues(
        contexts: [Context],
        contextByID: [UUID: Context]
    ) -> [CanonicalValidationIssue] {
        var issues: [CanonicalValidationIssue] = []
        var reported = Set<Set<UUID>>()
        for context in contexts {
            var path: [UUID] = []
            var positions: [UUID: Int] = [:]
            var cursor: UUID? = context.id
            while let id = cursor, let current = contextByID[id] {
                if let cycleStart = positions[id] {
                    let cycle = Set(path[cycleStart...])
                    if reported.insert(cycle).inserted {
                        issues.append(issue("context.cycle", cycle.sorted { $0.uuidString < $1.uuidString }, String(localized: "The context hierarchy contains a cycle.")))
                    }
                    break
                }
                positions[id] = path.count
                path.append(id)
                cursor = current.parentContextID
            }
        }
        return issues
    }

    private func duplicateIssues<T: Identifiable>(
        _ values: [T],
        entityName: String
    ) -> [CanonicalValidationIssue] where T.ID == UUID {
        Dictionary(grouping: values, by: \.id).compactMap { id, group in
            guard group.count > 1 else { return nil }
            return issue("\(entityName).duplicateID", [id], String(localized: "The stable identifier is duplicated."))
        }
    }

    private func indexByID<T: Identifiable>(_ values: [T]) -> [UUID: T] where T.ID == UUID {
        values.reduce(into: [:]) { result, value in
            if result[value.id] == nil { result[value.id] = value }
        }
    }

    private func intervalsOverlap(
        _ firstStart: PartialDate?,
        _ firstEnd: PartialDate?,
        _ secondStart: PartialDate?,
        _ secondEnd: PartialDate?
    ) -> Bool {
        let firstLower = firstStart?.earliestInstant ?? .distantPast
        let firstUpper = firstEnd?.latestInstant ?? .distantFuture
        let secondLower = secondStart?.earliestInstant ?? .distantPast
        let secondUpper = secondEnd?.latestInstant ?? .distantFuture
        return firstLower <= secondUpper && secondLower <= firstUpper
    }

    private func issue(_ code: String, _ ids: [UUID], _ message: String) -> CanonicalValidationIssue {
        CanonicalValidationIssue(code: code, entityIDs: ids, message: message)
    }
}
