import Foundation

public struct ArchiveInspectionLimits: Hashable, Codable, Sendable {
    public var maximumArchiveBytes: Int
    public var maximumPeople: Int
    public var maximumInteractions: Int
    public var maximumJSONDepth: Int
    public var maximumJSONValues: Int
    public var maximumStringCharacters: Int

    public init(
        maximumArchiveBytes: Int = 50_000_000,
        maximumPeople: Int = 100_000,
        maximumInteractions: Int = 500_000,
        maximumJSONDepth: Int = 32,
        maximumJSONValues: Int = 5_000_000,
        maximumStringCharacters: Int = 100_000
    ) {
        self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumPeople = maximumPeople
        self.maximumInteractions = maximumInteractions
        self.maximumJSONDepth = maximumJSONDepth
        self.maximumJSONValues = maximumJSONValues
        self.maximumStringCharacters = maximumStringCharacters
    }
}

public enum ArchiveInspectionError: LocalizedError, Equatable, Sendable {
    case invalidLimits
    case archiveTooLarge
    case malformedJSON
    case jsonTooDeep
    case tooManyJSONValues
    case stringTooLong
    case unsupportedSchema(Int)
    case tooManyPeople
    case tooManyInteractions
    case malformedArchive

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: String(localized: "Archive inspection limits are invalid.")
        case .archiveTooLarge: String(localized: "The archive exceeds the safe inspection size.")
        case .malformedJSON: String(localized: "The archive is not valid JSON.")
        case .jsonTooDeep: String(localized: "The archive contains excessively nested JSON.")
        case .tooManyJSONValues: String(localized: "The archive contains too many JSON values.")
        case .stringTooLong: String(localized: "The archive contains an excessively long string.")
        case .unsupportedSchema(let version): String(localized: "Archive schema \(version) is not supported.")
        case .tooManyPeople: String(localized: "The archive contains too many people.")
        case .tooManyInteractions: String(localized: "The archive contains too many interactions.")
        case .malformedArchive: String(localized: "The archive does not match the supported structure.")
        }
    }
}

public enum ArchiveImportIssueSeverity: String, Codable, Sendable {
    case warning
    case blocking
}

public enum ArchiveImportIssueCode: String, Codable, Sendable {
    case unknownField
    case duplicateStableIdentifier
    case conflictingDuplicateIdentifier
    case missingPersonReference
    case missingMediaPayload
    case existingStoreDuplicateIdentifier
    case interactionConflict
    case structuredRecordConflict
    case invalidStructuredReference
    case editDeleteConflict
}

public enum ArchiveStructuredRecordFamily: String, Codable, CaseIterable, Sendable {
    case context
    case cohortScheme
    case cohort
    case membership
    case cohortAssignment
    case roleDefinition
    case roleAssignment
    case education
    case assertion
    case source
    case artifactUnit
    case portraitMedia
    case evidence
    case reminder
    case commitment
    case savedView
    case attributeDefinition
    case textImportReview
    case personMergeEvent
    case profileSnapshot
}

public struct ArchiveStructuredRecordIdentity: Hashable, Codable, Sendable {
    public var family: ArchiveStructuredRecordFamily
    public var id: UUID

    public init(family: ArchiveStructuredRecordFamily, id: UUID) {
        self.family = family
        self.id = id
    }
}

public struct ArchiveImportIssue: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var severity: ArchiveImportIssueSeverity
    public var code: ArchiveImportIssueCode
    public var path: String
    public var message: String

    public init(
        id: UUID,
        severity: ArchiveImportIssueSeverity,
        code: ArchiveImportIssueCode,
        path: String,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.code = code
        self.path = path
        self.message = message
    }
}

public enum ArchiveUpdateDirection: String, Codable, Sendable {
    case incomingIsNewer
    case existingIsNewer
    case sameTimestamp
    /// The destination is intentionally retained even when the incoming
    /// timestamp is later. Used by reviewed local-to-cloud migration, where a
    /// wall clock must never authorize an overwrite by itself.
    case destinationKept
}

public struct ArchivePersonUpdate: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID { incoming.id }
    public var existing: Person
    public var incoming: Person
    public var direction: ArchiveUpdateDirection

    public init(existing: Person, incoming: Person, direction: ArchiveUpdateDirection) {
        self.existing = existing
        self.incoming = incoming
        self.direction = direction
    }
}

public struct ArchiveInteractionConflict: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID { incoming.id }
    public var existing: Interaction
    public var incoming: Interaction

    public init(existing: Interaction, incoming: Interaction) {
        self.existing = existing
        self.incoming = incoming
    }
}

public struct ArchivePreservedExtensionConflict: Hashable, Codable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var existing: JSONValue
    public var incoming: JSONValue

    public init(key: String, existing: JSONValue, incoming: JSONValue) {
        self.key = key
        self.existing = existing
        self.incoming = incoming
    }
}

/// Read-only import proposal. Applying any of these changes is intentionally a
/// separate, user-confirmed transaction.
public struct ArchiveImportPlan: Sendable {
    public var archiveSHA256: String
    public var idempotencyKey: UUID
    public var schemaVersion: Int
    public var exportedAt: Date
    public var peopleToCreate: [Person]
    public var personUpdates: [ArchivePersonUpdate]
    public var unchangedPersonIDs: [UUID]
    public var interactionsToCreate: [Interaction]
    public var interactionConflicts: [ArchiveInteractionConflict]
    public var unchangedInteractionIDs: [UUID]
    public var structuredRecordsToCreate: [ArchiveStructuredRecordIdentity]
    public var unchangedStructuredRecords: [ArchiveStructuredRecordIdentity]
    public var structuredRecordConflicts: [ArchiveStructuredRecordIdentity]
    public var preservedExtensionsToCreate: [String: JSONValue]
    public var unchangedPreservedExtensionKeys: [String]
    public var preservedExtensionConflicts: [ArchivePreservedExtensionConflict]
    public var tombstoneConflicts: ArchiveTombstoneInventory
    public var issues: [ArchiveImportIssue]

    public init(
        archiveSHA256: String,
        idempotencyKey: UUID,
        schemaVersion: Int,
        exportedAt: Date,
        peopleToCreate: [Person],
        personUpdates: [ArchivePersonUpdate],
        unchangedPersonIDs: [UUID],
        interactionsToCreate: [Interaction],
        interactionConflicts: [ArchiveInteractionConflict],
        unchangedInteractionIDs: [UUID],
        structuredRecordsToCreate: [ArchiveStructuredRecordIdentity] = [],
        unchangedStructuredRecords: [ArchiveStructuredRecordIdentity] = [],
        structuredRecordConflicts: [ArchiveStructuredRecordIdentity] = [],
        preservedExtensionsToCreate: [String: JSONValue] = [:],
        unchangedPreservedExtensionKeys: [String] = [],
        preservedExtensionConflicts: [ArchivePreservedExtensionConflict] = [],
        tombstoneConflicts: ArchiveTombstoneInventory = .init(),
        issues: [ArchiveImportIssue]
    ) {
        self.archiveSHA256 = archiveSHA256
        self.idempotencyKey = idempotencyKey
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.peopleToCreate = peopleToCreate
        self.personUpdates = personUpdates
        self.unchangedPersonIDs = unchangedPersonIDs
        self.interactionsToCreate = interactionsToCreate
        self.interactionConflicts = interactionConflicts
        self.unchangedInteractionIDs = unchangedInteractionIDs
        self.structuredRecordsToCreate = structuredRecordsToCreate
        self.unchangedStructuredRecords = unchangedStructuredRecords
        self.structuredRecordConflicts = structuredRecordConflicts
        self.preservedExtensionsToCreate = preservedExtensionsToCreate
        self.unchangedPreservedExtensionKeys = unchangedPreservedExtensionKeys
        self.preservedExtensionConflicts = preservedExtensionConflicts
        self.tombstoneConflicts = tombstoneConflicts
        self.issues = issues
    }

    public var hasProposedChanges: Bool {
        !peopleToCreate.isEmpty
            || !personUpdates.isEmpty
            || !interactionsToCreate.isEmpty
            || !interactionConflicts.isEmpty
            || !structuredRecordsToCreate.isEmpty
            || !preservedExtensionsToCreate.isEmpty
    }

    public var hasBlockingIssues: Bool {
        issues.contains { $0.severity == .blocking }
    }

    /// True when re-importing against the supplied state would be a no-op.
    public var isAlreadyImported: Bool {
        !hasProposedChanges && !hasBlockingIssues
    }
}

/// Validates bounded JSON before decoding and compares portable stable IDs to
/// produce an idempotent, non-mutating import preview.
public struct ArchiveImportPlanner: Sendable {
    public var limits: ArchiveInspectionLimits

    public init(limits: ArchiveInspectionLimits = .init()) {
        self.limits = limits
    }

    public func inspect(
        _ data: Data,
        existingPeople: [Person],
        existingInteractions: [Interaction],
        existingCanonical: CanonicalArchivePayload? = nil,
        existingOwnedProfileSnapshots: [ProfileCardSnapshotPayload] = [],
        existingPreservedExtensions: [String: JSONValue] = [:],
        verifiedPortraitMediaIDs: Set<UUID> = [],
        existingTombstones: ArchiveTombstoneInventory = .init(),
        additionalAvailablePersonIDs: Set<UUID> = [],
        additionalAvailableInteractionIDs: Set<UUID> = [],
        acceptIncomingPersonUpdates: Bool = true
    ) throws -> ArchiveImportPlan {
        try validateLimits()
        guard data.count <= limits.maximumArchiveBytes else {
            throw ArchiveInspectionError.archiveTooLarge
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ArchiveInspectionError.malformedJSON
        }
        var valueCount = 0
        try inspectJSONValue(jsonObject, depth: 0, valueCount: &valueCount)
        guard let root = jsonObject as? [String: Any] else {
            throw ArchiveInspectionError.malformedArchive
        }
        if let people = root["people"] as? [Any], people.count > limits.maximumPeople {
            throw ArchiveInspectionError.tooManyPeople
        }
        if let interactions = root["interactions"] as? [Any],
           interactions.count > limits.maximumInteractions {
            throw ArchiveInspectionError.tooManyInteractions
        }

        let archive: NotebookArchive
        do {
            archive = try ArchiveCodec.decode(data)
        } catch ArchiveCodec.ArchiveError.unsupportedSchema(let version) {
            throw ArchiveInspectionError.unsupportedSchema(version)
        } catch {
            throw ArchiveInspectionError.malformedArchive
        }
        guard archive.people.count <= limits.maximumPeople else {
            throw ArchiveInspectionError.tooManyPeople
        }
        guard archive.interactions.count <= limits.maximumInteractions else {
            throw ArchiveInspectionError.tooManyInteractions
        }

        let archiveDigest = ServiceDigest.sha256Hex(data)
        var issues = unknownFieldIssues(in: jsonObject, archiveDigest: archiveDigest)
        if let normalizedData = try? ArchiveCodec.encode(archive),
           let normalizedObject = try? JSONSerialization.jsonObject(
               with: normalizedData,
               options: [.fragmentsAllowed]
           ) {
            issues.append(contentsOf: roundTripUnknownFieldIssues(
                original: jsonObject,
                normalized: normalizedObject,
                archiveDigest: archiveDigest
            ))
            var seenUnknownPaths = Set<String>()
            issues = issues.filter { issue in
                issue.code != .unknownField || seenUnknownPaths.insert(issue.path).inserted
            }
        }
        let incomingPortraitIDs = Set((archive.canonical?.portraitMedia ?? []).map(\.id))
        let missingPortraitIDs = incomingPortraitIDs.subtracting(verifiedPortraitMediaIDs)
        if !missingPortraitIDs.isEmpty {
            issues.append(issue(
                digest: archiveDigest,
                code: .missingMediaPayload,
                severity: .warning,
                path: "$.canonical.portraitMedia",
                message: String(localized: "Some portrait metadata has no verified image file. Those portraits will be skipped; use a complete media archive to restore them.")
            ))
        }
        var effectiveTombstones = existingTombstones
        effectiveTombstones.personIDs.formUnion(
            existingPeople.lazy.filter { $0.deletedAt != nil }.map(\.id)
        )
        effectiveTombstones.interactionIDs.formUnion(
            existingInteractions.lazy.filter { $0.deletedAt != nil }.map(\.id)
        )
        let tombstoneConflicts = effectiveTombstones.conflicts(with: archive)
        issues.append(contentsOf: tombstoneConflictIssues(
            tombstoneConflicts,
            archiveDigest: archiveDigest
        ))
        var peopleToCreate: [Person] = []
        var personUpdates: [ArchivePersonUpdate] = []
        var unchangedPersonIDs: [UUID] = []
        var interactionsToCreate: [Interaction] = []
        var interactionConflicts: [ArchiveInteractionConflict] = []
        var unchangedInteractionIDs: [UUID] = []

        let existingPeopleGroups = Dictionary(
            grouping: existingPeople.filter { $0.deletedAt == nil },
            by: \.id
        )
        let existingInteractionGroups = Dictionary(
            grouping: existingInteractions.filter { $0.deletedAt == nil },
            by: \.id
        )
        let incomingPeopleGroups = Dictionary(grouping: archive.people, by: \.id)
        let incomingInteractionGroups = Dictionary(grouping: archive.interactions, by: \.id)

        let invalidExistingPersonIDs = Set(existingPeopleGroups.compactMap { id, values in
            values.count > 1 ? id : nil
        })
        let invalidExistingInteractionIDs = Set(existingInteractionGroups.compactMap { id, values in
            values.count > 1 ? id : nil
        })
        for id in invalidExistingPersonIDs {
            issues.append(issue(
                digest: archiveDigest,
                code: .existingStoreDuplicateIdentifier,
                severity: .blocking,
                path: "existing.people[\(id.uuidString)]",
                message: String(localized: "The existing notebook contains this person identifier more than once.")
            ))
        }
        for id in invalidExistingInteractionIDs {
            issues.append(issue(
                digest: archiveDigest,
                code: .existingStoreDuplicateIdentifier,
                severity: .blocking,
                path: "existing.interactions[\(id.uuidString)]",
                message: String(localized: "The existing notebook contains this interaction identifier more than once.")
            ))
        }

        var usableIncomingPeople: [UUID: Person] = [:]
        for id in incomingPeopleGroups.keys.sorted(by: uuidOrder) {
            guard let values = incomingPeopleGroups[id] else { continue }
            if values.count > 1 {
                let allEqual = values.dropFirst().allSatisfy { $0 == values[0] }
                issues.append(issue(
                    digest: archiveDigest,
                    code: allEqual ? .duplicateStableIdentifier : .conflictingDuplicateIdentifier,
                    severity: allEqual ? .warning : .blocking,
                    path: "people[\(id.uuidString)]",
                    message: allEqual
                        ? String(localized: "An identical duplicate person identifier was collapsed during review.")
                        : String(localized: "Different people use the same stable identifier and require repair.")
                ))
                guard allEqual else { continue }
            }
            usableIncomingPeople[id] = values[0]
        }

        for id in usableIncomingPeople.keys.sorted(by: uuidOrder) {
            guard let incoming = usableIncomingPeople[id] else { continue }
            guard !tombstoneConflicts.personIDs.contains(id) else { continue }
            if invalidExistingPersonIDs.contains(id) { continue }
            guard let existing = existingPeopleGroups[id]?.first else {
                peopleToCreate.append(incoming)
                continue
            }
            if existing == incoming {
                unchangedPersonIDs.append(id)
            } else {
                let direction: ArchiveUpdateDirection
                if !acceptIncomingPersonUpdates {
                    direction = .destinationKept
                } else if incoming.modifiedAt > existing.modifiedAt {
                    direction = .incomingIsNewer
                } else if incoming.modifiedAt < existing.modifiedAt {
                    direction = .existingIsNewer
                } else {
                    direction = .sameTimestamp
                }
                personUpdates.append(.init(
                    existing: existing,
                    incoming: incoming,
                    direction: direction
                ))
            }
        }

        let availablePersonIDs = Set(existingPeopleGroups.keys)
            .union(usableIncomingPeople.keys.filter { !tombstoneConflicts.personIDs.contains($0) })
            .union(additionalAvailablePersonIDs)
            .subtracting(invalidExistingPersonIDs)

        var usableIncomingInteractions: [UUID: Interaction] = [:]
        for id in incomingInteractionGroups.keys.sorted(by: uuidOrder) {
            guard let values = incomingInteractionGroups[id] else { continue }
            if values.count > 1 {
                let allEqual = values.dropFirst().allSatisfy { $0 == values[0] }
                issues.append(issue(
                    digest: archiveDigest,
                    code: allEqual ? .duplicateStableIdentifier : .conflictingDuplicateIdentifier,
                    severity: allEqual ? .warning : .blocking,
                    path: "interactions[\(id.uuidString)]",
                    message: allEqual
                        ? String(localized: "An identical duplicate interaction identifier was collapsed during review.")
                        : String(localized: "Different interactions use the same stable identifier and require repair.")
                ))
                guard allEqual else { continue }
            }
            usableIncomingInteractions[id] = values[0]
        }

        for id in usableIncomingInteractions.keys.sorted(by: uuidOrder) {
            guard let incoming = usableIncomingInteractions[id] else { continue }
            guard !tombstoneConflicts.interactionIDs.contains(id) else { continue }
            let referencedPersonIDs = Set(
                [incoming.personID].compactMap { $0 } + (incoming.additionalParticipantIDs ?? [])
            )
            let missingPersonIDs = referencedPersonIDs.subtracting(availablePersonIDs)
            guard missingPersonIDs.isEmpty else {
                issues.append(issue(
                    digest: archiveDigest,
                    code: .missingPersonReference,
                    severity: .blocking,
                    path: "interactions[\(id.uuidString)].participants",
                    message: String(localized: "The interaction references one or more people that are not available in this import or notebook.")
                ))
                continue
            }
            if invalidExistingInteractionIDs.contains(id) { continue }
            guard let existing = existingInteractionGroups[id]?.first else {
                interactionsToCreate.append(incoming)
                continue
            }
            if existing == incoming {
                unchangedInteractionIDs.append(id)
            } else {
                interactionConflicts.append(.init(existing: existing, incoming: incoming))
                issues.append(issue(
                    digest: archiveDigest,
                    code: .interactionConflict,
                    severity: .warning,
                    path: "interactions[\(id.uuidString)]",
                    message: String(localized: "An existing interaction has the same stable identifier but different content.")
                ))
            }
        }

        var structuredInspection = inspectStructuredRecords(
            incoming: archive.canonical,
            existing: existingCanonical,
            incomingProfileSnapshots: archive.ownedProfileSnapshots ?? [],
            existingProfileSnapshots: existingOwnedProfileSnapshots,
            verifiedPortraitMediaIDs: verifiedPortraitMediaIDs,
            archiveDigest: archiveDigest
        )
        if !tombstoneConflicts.structuredRecordIDs.isEmpty {
            structuredInspection.toCreate.removeAll {
                tombstoneConflicts.structuredRecordIDs.contains($0)
            }
            structuredInspection.unchanged.removeAll {
                tombstoneConflicts.structuredRecordIDs.contains($0)
            }
            structuredInspection.conflicts = Array(
                Set(structuredInspection.conflicts)
                    .union(tombstoneConflicts.structuredRecordIDs)
            ).sorted(by: structuredIdentityOrder)
        }
        issues.append(contentsOf: structuredInspection.issues)
        var preservedExtensionsToCreate: [String: JSONValue] = [:]
        var unchangedPreservedExtensionKeys: [String] = []
        var preservedExtensionConflicts: [ArchivePreservedExtensionConflict] = []
        for key in (archive.preservedExtensions ?? [:]).keys.sorted() {
            guard let incoming = archive.preservedExtensions?[key] else { continue }
            guard let existing = existingPreservedExtensions[key] else {
                preservedExtensionsToCreate[key] = incoming
                continue
            }
            if existing == incoming {
                unchangedPreservedExtensionKeys.append(key)
            } else {
                preservedExtensionConflicts.append(.init(
                    key: key,
                    existing: existing,
                    incoming: incoming
                ))
                issues.append(issue(
                    digest: archiveDigest,
                    code: .structuredRecordConflict,
                    severity: .warning,
                    path: "$.preservedExtensions.\(key)",
                    message: String(localized: "An existing preserved field has the same key but different content. The incoming field will be skipped.")
                ))
            }
        }
        issues.append(contentsOf: structuredReferenceIssues(
            incoming: archive.canonical,
            existing: existingCanonical,
            recordsToCreate: Set(structuredInspection.toCreate),
            availablePersonIDs: availablePersonIDs,
            availableInteractionIDs: Set(existingInteractionGroups.keys)
                .union(usableIncomingInteractions.keys)
                .union(additionalAvailableInteractionIDs)
                .subtracting(invalidExistingInteractionIDs),
            archiveDigest: archiveDigest
        ))

        return ArchiveImportPlan(
            archiveSHA256: archiveDigest,
            idempotencyKey: ServiceDigest.deterministicUUID(seed: "archive-import:\(archiveDigest)"),
            schemaVersion: archive.schemaVersion,
            exportedAt: archive.exportedAt,
            peopleToCreate: peopleToCreate,
            personUpdates: personUpdates,
            unchangedPersonIDs: unchangedPersonIDs.sorted(by: uuidOrder),
            interactionsToCreate: interactionsToCreate,
            interactionConflicts: interactionConflicts,
            unchangedInteractionIDs: unchangedInteractionIDs.sorted(by: uuidOrder),
            structuredRecordsToCreate: structuredInspection.toCreate,
            unchangedStructuredRecords: structuredInspection.unchanged,
            structuredRecordConflicts: structuredInspection.conflicts,
            preservedExtensionsToCreate: preservedExtensionsToCreate,
            unchangedPreservedExtensionKeys: unchangedPreservedExtensionKeys,
            preservedExtensionConflicts: preservedExtensionConflicts,
            tombstoneConflicts: tombstoneConflicts,
            issues: issues.sorted {
                if $0.path == $1.path { return $0.code.rawValue < $1.code.rawValue }
                return $0.path < $1.path
            }
        )
    }

    private func inspectStructuredRecords(
        incoming: CanonicalArchivePayload?,
        existing: CanonicalArchivePayload?,
        incomingProfileSnapshots: [ProfileCardSnapshotPayload],
        existingProfileSnapshots: [ProfileCardSnapshotPayload],
        verifiedPortraitMediaIDs: Set<UUID>,
        archiveDigest: String
    ) -> StructuredArchiveInspection {
        var result = StructuredArchiveInspection()

        classify(
            incoming: incoming?.contexts ?? [], existing: existing?.contexts ?? [],
            id: { $0.id }, family: .context, path: "$.canonical.contexts",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.cohortSchemes ?? [], existing: existing?.cohortSchemes ?? [],
            id: { $0.id }, family: .cohortScheme, path: "$.canonical.cohortSchemes",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.cohorts ?? [], existing: existing?.cohorts ?? [],
            id: { $0.id }, family: .cohort, path: "$.canonical.cohorts",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.memberships ?? [], existing: existing?.memberships ?? [],
            id: { $0.id }, family: .membership, path: "$.canonical.memberships",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.cohortAssignments ?? [], existing: existing?.cohortAssignments ?? [],
            id: { $0.id }, family: .cohortAssignment, path: "$.canonical.cohortAssignments",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.roleDefinitions ?? [], existing: existing?.roleDefinitions ?? [],
            id: { $0.id }, family: .roleDefinition, path: "$.canonical.roleDefinitions",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.roleAssignments ?? [], existing: existing?.roleAssignments ?? [],
            id: { $0.id }, family: .roleAssignment, path: "$.canonical.roleAssignments",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.education ?? [], existing: existing?.education ?? [],
            id: { $0.id }, family: .education, path: "$.canonical.education",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.assertions ?? [], existing: existing?.assertions ?? [],
            id: { $0.id }, family: .assertion, path: "$.canonical.assertions",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.sources ?? [], existing: existing?.sources ?? [],
            id: { $0.id }, family: .source, path: "$.canonical.sources",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.artifactUnits ?? [], existing: existing?.artifactUnits ?? [],
            id: { $0.id }, family: .artifactUnit, path: "$.canonical.artifactUnits",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: (incoming?.portraitMedia ?? []).filter {
                verifiedPortraitMediaIDs.contains($0.id)
            },
            existing: existing?.portraitMedia ?? [],
            id: { $0.id }, family: .portraitMedia, path: "$.canonical.portraitMedia",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.evidence ?? [], existing: existing?.evidence ?? [],
            id: { $0.id }, family: .evidence, path: "$.canonical.evidence",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.reminders ?? [], existing: existing?.reminders ?? [],
            id: { $0.id }, family: .reminder, path: "$.canonical.reminders",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.commitments ?? [], existing: existing?.commitments ?? [],
            id: { $0.id }, family: .commitment, path: "$.canonical.commitments",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.savedViews ?? [], existing: existing?.savedViews ?? [],
            id: { $0.id }, family: .savedView, path: "$.canonical.savedViews",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.attributeDefinitions ?? [], existing: existing?.attributeDefinitions ?? [],
            id: { $0.id }, family: .attributeDefinition, path: "$.canonical.attributeDefinitions",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.textImportReviews ?? [], existing: existing?.textImportReviews ?? [],
            id: { $0.source.id }, family: .textImportReview, path: "$.canonical.textImportReviews",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incoming?.personMergeEvents ?? [], existing: existing?.personMergeEvents ?? [],
            id: { $0.id }, family: .personMergeEvent, path: "$.canonical.personMergeEvents",
            archiveDigest: archiveDigest, result: &result
        )
        classify(
            incoming: incomingProfileSnapshots, existing: existingProfileSnapshots,
            id: { $0.cardVersionID }, family: .profileSnapshot, path: "$.ownedProfileSnapshots",
            archiveDigest: archiveDigest, result: &result
        )

        result.toCreate.sort(by: structuredIdentityOrder)
        result.unchanged.sort(by: structuredIdentityOrder)
        result.conflicts.sort(by: structuredIdentityOrder)
        return result
    }

    private func structuredReferenceIssues(
        incoming: CanonicalArchivePayload?,
        existing: CanonicalArchivePayload?,
        recordsToCreate: Set<ArchiveStructuredRecordIdentity>,
        availablePersonIDs: Set<UUID>,
        availableInteractionIDs: Set<UUID>,
        archiveDigest: String
    ) -> [ArchiveImportIssue] {
        guard let incoming else { return [] }
        let selected = incoming.selectingNewRecords(identifiedBy: recordsToCreate)
        let current = existing ?? CanonicalArchivePayload()
        let combined = CanonicalArchivePayload(
            contexts: current.contexts + selected.contexts,
            cohortSchemes: current.cohortSchemes + selected.cohortSchemes,
            cohorts: current.cohorts + selected.cohorts,
            memberships: current.memberships + selected.memberships,
            cohortAssignments: current.cohortAssignments + selected.cohortAssignments,
            roleDefinitions: current.roleDefinitions + selected.roleDefinitions,
            roleAssignments: current.roleAssignments + selected.roleAssignments,
            education: current.education + selected.education,
            assertions: current.assertions + selected.assertions,
            sources: current.sources + selected.sources,
            artifactUnits: (current.artifactUnits ?? []) + (selected.artifactUnits ?? []),
            portraitMedia: (current.portraitMedia ?? []) + (selected.portraitMedia ?? []),
            evidence: current.evidence + selected.evidence,
            reminders: current.reminders + selected.reminders,
            commitments: current.commitments + selected.commitments,
            savedViews: current.savedViews + selected.savedViews,
            attributeDefinitions: current.attributeDefinitions + selected.attributeDefinitions,
            textImportReviews: current.textImportReviews + selected.textImportReviews,
            personMergeEvents: current.personMergeEvents + selected.personMergeEvents
        )

        var output: [ArchiveImportIssue] = []
        func append(_ path: String, _ message: String) {
            output.append(issue(
                digest: archiveDigest,
                code: .invalidStructuredReference,
                severity: .blocking,
                path: path,
                message: message
            ))
        }

        let validator = CanonicalRelationshipValidator()
        let baselineErrorIDs = Set(validator.validate(
            contexts: current.contexts,
            schemes: current.cohortSchemes,
            cohorts: current.cohorts,
            memberships: current.memberships,
            assignments: current.cohortAssignments,
            roleDefinitions: current.roleDefinitions,
            roleAssignments: current.roleAssignments,
            educationEnrollments: current.education
        ).errors.map(\.id))
        let combinedReport = validator.validate(
            contexts: combined.contexts,
            schemes: combined.cohortSchemes,
            cohorts: combined.cohorts,
            memberships: combined.memberships,
            assignments: combined.cohortAssignments,
            roleDefinitions: combined.roleDefinitions,
            roleAssignments: combined.roleAssignments,
            educationEnrollments: combined.education
        )
        for validationIssue in combinedReport.errors where !baselineErrorIDs.contains(validationIssue.id) {
            append("$.canonical.\(validationIssue.code)", validationIssue.message)
        }

        let sourceIDs = Set(combined.sources.map(\.id))
        let unitIDs = Set((combined.artifactUnits ?? []).map(\.id))
        let evidenceIDs = Set(combined.evidence.map(\.id))
        let assertionIDs = Set(combined.assertions.map(\.id))
        let contextIDs = Set(combined.contexts.map(\.id))
        let commitmentIDs = Set(combined.commitments.map(\.id))
        let portraitIDs = Set((combined.portraitMedia ?? []).map(\.id))

        for portrait in selected.portraitMedia ?? []
            where !availablePersonIDs.contains(portrait.personID) {
            append(
                "$.canonical.portraitMedia[\(portrait.id.uuidString)].personID",
                String(localized: "A portrait references a person that is not available after review.")
            )
        }
        for source in selected.sources {
            if let mediaID = source.mediaID, !portraitIDs.contains(mediaID) {
                append(
                    "$.canonical.sources[\(source.id.uuidString)].mediaID",
                    String(localized: "A source references media that is not available after review.")
                )
            }
        }

        for membership in selected.memberships where !availablePersonIDs.contains(membership.personID) {
            append(
                "$.canonical.memberships[\(membership.id.uuidString)].personID",
                String(localized: "A membership references a person that is not available in this import or notebook.")
            )
        }
        for enrollment in selected.education where !availablePersonIDs.contains(enrollment.personID) {
            append(
                "$.canonical.education[\(enrollment.id.uuidString)].personID",
                String(localized: "An education record references a person that is not available in this import or notebook.")
            )
        }
        for unit in selected.artifactUnits ?? [] where !sourceIDs.contains(unit.sourceID) {
            append(
                "$.canonical.artifactUnits[\(unit.id.uuidString)].sourceID",
                String(localized: "An artifact unit references a source that is not available after review.")
            )
        }
        for span in selected.evidence where !unitIDs.contains(span.unitID) {
            append(
                "$.canonical.evidence[\(span.id.uuidString)].unitID",
                String(localized: "An evidence span references an artifact unit that is not available after review.")
            )
        }
        for assertion in selected.assertions {
            if let sourceID = assertion.sourceID, !sourceIDs.contains(sourceID) {
                append(
                    "$.canonical.assertions[\(assertion.id.uuidString)].sourceID",
                    String(localized: "An assertion references a source that is not available after review.")
                )
            }
            for evidenceID in assertion.evidenceIDs where !evidenceIDs.contains(evidenceID) {
                append(
                    "$.canonical.assertions[\(assertion.id.uuidString)].evidenceIDs",
                    String(localized: "An assertion references evidence that is not available after review.")
                )
            }
            if let supersedesID = assertion.supersedesID, !assertionIDs.contains(supersedesID) {
                append(
                    "$.canonical.assertions[\(assertion.id.uuidString)].supersedesID",
                    String(localized: "An assertion supersedes a record that is not available after review.")
                )
            }
            switch assertion.value {
            case .personReference(let personID) where !availablePersonIDs.contains(personID):
                append(
                    "$.canonical.assertions[\(assertion.id.uuidString)].value",
                    String(localized: "An assertion value references a person that is not available after review.")
                )
            case .contextReference(let contextID) where !contextIDs.contains(contextID):
                append(
                    "$.canonical.assertions[\(assertion.id.uuidString)].value",
                    String(localized: "An assertion value references a context that is not available after review.")
                )
            case .mediaReference(let mediaID) where !portraitIDs.contains(mediaID):
                append(
                    "$.canonical.assertions[\(assertion.id.uuidString)].value",
                    String(localized: "An assertion value references media that is not present in this plaintext import.")
                )
            default:
                break
            }
        }

        let assertionBackedRecords: [(String, UUID, UUID?)] =
            selected.memberships.map { ("memberships", $0.id, $0.assertionID) }
            + selected.cohortAssignments.map { ("cohortAssignments", $0.id, $0.assertionID) }
            + selected.roleAssignments.map { ("roleAssignments", $0.id, $0.assertionID) }
            + selected.education.map { ("education", $0.id, $0.assertionID) }
        for (family, recordID, assertionID) in assertionBackedRecords {
            if let assertionID, !assertionIDs.contains(assertionID) {
                append(
                    "$.canonical.\(family)[\(recordID.uuidString)].assertionID",
                    String(localized: "A structured record references an assertion that is not available after review.")
                )
            }
        }

        for reminder in selected.reminders {
            let isAvailable: Bool = switch reminder.subject {
            case .person(let id): availablePersonIDs.contains(id)
            case .context(let id): contextIDs.contains(id)
            case .interaction(let id): availableInteractionIDs.contains(id)
            case .assertion(let id): assertionIDs.contains(id)
            case .commitment(let id): commitmentIDs.contains(id)
            }
            if !isAvailable {
                append(
                    "$.canonical.reminders[\(reminder.id.uuidString)].subject",
                    String(localized: "A reminder references a subject that is not available after review.")
                )
            }
        }
        for commitment in selected.commitments {
            for personID in commitment.personIDs where !availablePersonIDs.contains(personID) {
                append(
                    "$.canonical.commitments[\(commitment.id.uuidString)].personIDs",
                    String(localized: "A commitment references a person that is not available after review.")
                )
            }
            if let interactionID = commitment.interactionID,
               !availableInteractionIDs.contains(interactionID) {
                append(
                    "$.canonical.commitments[\(commitment.id.uuidString)].interactionID",
                    String(localized: "A commitment references an interaction that is not available after review.")
                )
            }
            if let sourceAssertionID = commitment.sourceAssertionID,
               !assertionIDs.contains(sourceAssertionID) {
                append(
                    "$.canonical.commitments[\(commitment.id.uuidString)].sourceAssertionID",
                    String(localized: "A commitment references an assertion that is not available after review.")
                )
            }
            let ownerIDs: [UUID] = switch commitment.owner {
            case .person(let id): [id]
            case .shared(let ids): ids
            case .notebookOwner, .unspecified: []
            }
            if ownerIDs.contains(where: { !availablePersonIDs.contains($0) }) {
                append(
                    "$.canonical.commitments[\(commitment.id.uuidString)].owner",
                    String(localized: "A commitment owner references a person that is not available after review.")
                )
            }
        }
        for review in selected.textImportReviews where !sourceIDs.contains(review.source.id) {
            append(
                "$.canonical.textImportReviews[\(review.source.id.uuidString)].source",
                String(localized: "An import review references source metadata that is not available after review.")
            )
        }

        return output
    }

    private func classify<Value: Hashable>(
        incoming: [Value],
        existing: [Value],
        id: (Value) -> UUID,
        family: ArchiveStructuredRecordFamily,
        path: String,
        archiveDigest: String,
        result: inout StructuredArchiveInspection
    ) {
        let incomingGroups = Dictionary(grouping: incoming, by: id)
        let existingGroups = Dictionary(grouping: existing, by: id)

        for recordID in existingGroups.keys.sorted(by: uuidOrder) {
            guard let values = existingGroups[recordID], values.count > 1 else { continue }
            result.issues.append(issue(
                digest: archiveDigest,
                code: .existingStoreDuplicateIdentifier,
                severity: .blocking,
                path: "existing.\(family.rawValue)[\(recordID.uuidString)]",
                message: String(localized: "The existing notebook contains this structured record identifier more than once.")
            ))
        }

        for recordID in incomingGroups.keys.sorted(by: uuidOrder) {
            guard let values = incomingGroups[recordID], let incomingValue = values.first else { continue }
            let identity = ArchiveStructuredRecordIdentity(family: family, id: recordID)
            if values.count > 1 {
                let allEqual = values.dropFirst().allSatisfy { $0 == incomingValue }
                result.issues.append(issue(
                    digest: archiveDigest,
                    code: allEqual ? .duplicateStableIdentifier : .conflictingDuplicateIdentifier,
                    severity: allEqual ? .warning : .blocking,
                    path: "\(path)[\(recordID.uuidString)]",
                    message: allEqual
                        ? String(localized: "An identical duplicate structured record identifier was collapsed during review.")
                        : String(localized: "Different structured records use the same stable identifier and require repair.")
                ))
                guard allEqual else { continue }
            }

            guard let existingValues = existingGroups[recordID] else {
                result.toCreate.append(identity)
                continue
            }
            guard existingValues.count == 1, let existingValue = existingValues.first else { continue }
            if existingValue == incomingValue {
                result.unchanged.append(identity)
            } else {
                result.conflicts.append(identity)
                result.issues.append(issue(
                    digest: archiveDigest,
                    code: .structuredRecordConflict,
                    severity: .warning,
                    path: "\(path)[\(recordID.uuidString)]",
                    message: String(localized: "An existing structured record has the same stable identifier but different content. The incoming record will be skipped.")
                ))
            }
        }
    }

    private func structuredIdentityOrder(
        _ lhs: ArchiveStructuredRecordIdentity,
        _ rhs: ArchiveStructuredRecordIdentity
    ) -> Bool {
        if lhs.family.rawValue == rhs.family.rawValue {
            return uuidOrder(lhs.id, rhs.id)
        }
        return lhs.family.rawValue < rhs.family.rawValue
    }

    private func validateLimits() throws {
        guard limits.maximumArchiveBytes > 0,
              limits.maximumPeople > 0,
              limits.maximumInteractions > 0,
              limits.maximumJSONDepth > 0,
              limits.maximumJSONValues > 0,
              limits.maximumStringCharacters > 0 else {
            throw ArchiveInspectionError.invalidLimits
        }
    }

    private func inspectJSONValue(
        _ value: Any,
        depth: Int,
        valueCount: inout Int
    ) throws {
        guard depth <= limits.maximumJSONDepth else {
            throw ArchiveInspectionError.jsonTooDeep
        }
        valueCount += 1
        guard valueCount <= limits.maximumJSONValues else {
            throw ArchiveInspectionError.tooManyJSONValues
        }

        if let string = value as? String {
            guard string.count <= limits.maximumStringCharacters else {
                throw ArchiveInspectionError.stringTooLong
            }
        } else if let array = value as? [Any] {
            for item in array {
                try inspectJSONValue(item, depth: depth + 1, valueCount: &valueCount)
            }
        } else if let dictionary = value as? [String: Any] {
            for (key, item) in dictionary {
                guard key.count <= limits.maximumStringCharacters else {
                    throw ArchiveInspectionError.stringTooLong
                }
                try inspectJSONValue(item, depth: depth + 1, valueCount: &valueCount)
            }
        }
    }

    private func unknownFieldIssues(in object: Any, archiveDigest: String) -> [ArchiveImportIssue] {
        guard let root = object as? [String: Any] else { return [] }
        var output: [ArchiveImportIssue] = []
        appendUnknownKeys(
            in: root,
            allowed: [
                "schemaVersion", "exportedAt", "people", "interactions", "canonical",
                "ownedProfileSnapshots", "preservedExtensions"
            ],
            path: "$",
            digest: archiveDigest,
            output: &output
        )

        let personKeys: Set<String> = [
            "id", "displayName", "pronunciation", "aliases", "contexts", "role", "tags",
            "privateNote", "mentionableContext", "circle", "contacts", "cadenceDays", "priority",
            "createdAt", "modifiedAt", "lastInteractionAt", "snoozedUntil", "isArchived",
            "neverSuggest", "doNotContact", "deletedAt", "mergedIntoPersonID"
        ]
        let contactKeys: Set<String> = ["id", "kind", "value", "isPreferred"]
        if let people = root["people"] as? [[String: Any]] {
            for (index, person) in people.enumerated() {
                appendUnknownKeys(
                    in: person,
                    allowed: personKeys,
                    path: "$.people[\(index)]",
                    digest: archiveDigest,
                    output: &output
                )
                if let contacts = person["contacts"] as? [[String: Any]] {
                    for (contactIndex, contact) in contacts.enumerated() {
                        appendUnknownKeys(
                            in: contact,
                            allowed: contactKeys,
                            path: "$.people[\(index)].contacts[\(contactIndex)]",
                            digest: archiveDigest,
                            output: &output
                        )
                    }
                }
            }
        }

        let interactionKeys: Set<String> = [
            "id", "personID", "occurredAt", "kind", "channel", "status", "summary",
            "commitment", "followUpAt", "additionalParticipantIDs", "privateReflection",
            "generatedDraft", "finalContent", "sourceEvidenceIDs", "transcriptRetention",
            "anticipatedHesitation", "postActionDifficulty", "feltWorthwhile",
            "approximateDate", "direction", "rawTranscript", "contentFidelity",
            "communicationEvidence", "deletedAt"
        ]
        if let interactions = root["interactions"] as? [[String: Any]] {
            for (index, interaction) in interactions.enumerated() {
                appendUnknownKeys(
                    in: interaction,
                    allowed: interactionKeys,
                    path: "$.interactions[\(index)]",
                    digest: archiveDigest,
                    output: &output
                )
            }
        }

        if let canonical = root["canonical"] as? [String: Any] {
            appendUnknownKeys(
                in: canonical,
                allowed: [
                    "contexts", "cohortSchemes", "cohorts", "memberships",
                    "cohortAssignments", "roleDefinitions", "roleAssignments", "education",
                    "assertions", "sources", "artifactUnits", "portraitMedia", "evidence",
                    "reminders", "commitments", "savedViews", "attributeDefinitions",
                    "textImportReviews", "personMergeEvents"
                ],
                path: "$.canonical",
                digest: archiveDigest,
                output: &output
            )
        }
        return output
    }

    private func appendUnknownKeys(
        in dictionary: [String: Any],
        allowed: Set<String>,
        path: String,
        digest: String,
        output: inout [ArchiveImportIssue]
    ) {
        for key in Set(dictionary.keys).subtracting(allowed).sorted() {
            output.append(issue(
                digest: digest,
                code: .unknownField,
                severity: .warning,
                path: "\(path).\(key)",
                message: String(localized: "This field is unsupported and was reported without reinterpretation.")
            ))
        }
    }

    /// Finds keys silently ignored by synthesized `Decodable` implementations
    /// at any nesting depth. Comparing keys only (not values) avoids treating
    /// normal date/number re-encoding as a schema change.
    private func roundTripUnknownFieldIssues(
        original: Any,
        normalized: Any,
        archiveDigest: String
    ) -> [ArchiveImportIssue] {
        var output: [ArchiveImportIssue] = []

        func walk(_ original: Any, _ normalized: Any, path: String) {
            if let originalDictionary = original as? [String: Any],
               let normalizedDictionary = normalized as? [String: Any] {
                for key in originalDictionary.keys.sorted() {
                    let nextPath = "\(path).\(key)"
                    guard let normalizedValue = normalizedDictionary[key] else {
                        // Synthesized optional decoding commonly accepts an
                        // explicit null and then omits it when re-encoding.
                        guard !(originalDictionary[key] is NSNull) else { continue }
                        output.append(issue(
                            digest: archiveDigest,
                            code: .unknownField,
                            severity: .warning,
                            path: nextPath,
                            message: String(localized: "This field is unsupported and was reported without reinterpretation.")
                        ))
                        continue
                    }
                    if let originalValue = originalDictionary[key] {
                        walk(originalValue, normalizedValue, path: nextPath)
                    }
                }
            } else if let originalArray = original as? [Any],
                      let normalizedArray = normalized as? [Any] {
                for index in 0..<min(originalArray.count, normalizedArray.count) {
                    walk(
                        originalArray[index],
                        normalizedArray[index],
                        path: "\(path)[\(index)]"
                    )
                }
            }
        }

        walk(original, normalized, path: "$")
        return output
    }

    private func tombstoneConflictIssues(
        _ conflicts: ArchiveTombstoneInventory,
        archiveDigest: String
    ) -> [ArchiveImportIssue] {
        let message = String(localized: "The destination contains a deletion tombstone for this stable identifier. The incoming active record will not restore it without explicit edit-versus-delete review.")
        let people = conflicts.personIDs.sorted(by: uuidOrder).map { id in
            issue(
                digest: archiveDigest,
                code: .editDeleteConflict,
                severity: .blocking,
                path: "destination.people[\(id.uuidString)].deletedAt",
                message: message
            )
        }
        let interactions = conflicts.interactionIDs.sorted(by: uuidOrder).map { id in
            issue(
                digest: archiveDigest,
                code: .editDeleteConflict,
                severity: .blocking,
                path: "destination.interactions[\(id.uuidString)].deletedAt",
                message: message
            )
        }
        let structured = conflicts.structuredRecordIDs
            .sorted(by: structuredIdentityOrder)
            .map { identity in
                issue(
                    digest: archiveDigest,
                    code: .editDeleteConflict,
                    severity: .blocking,
                    path: "destination.\(identity.family.rawValue)[\(identity.id.uuidString)].deletedAt",
                    message: message
                )
            }
        return people + interactions + structured
    }

    private func issue(
        digest: String,
        code: ArchiveImportIssueCode,
        severity: ArchiveImportIssueSeverity,
        path: String,
        message: String
    ) -> ArchiveImportIssue {
        ArchiveImportIssue(
            id: ServiceDigest.deterministicUUID(
                seed: "archive-issue:\(digest):\(code.rawValue):\(path)"
            ),
            severity: severity,
            code: code,
            path: path,
            message: message
        )
    }

    private func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
}

private struct StructuredArchiveInspection {
    var toCreate: [ArchiveStructuredRecordIdentity] = []
    var unchanged: [ArchiveStructuredRecordIdentity] = []
    var conflicts: [ArchiveStructuredRecordIdentity] = []
    var issues: [ArchiveImportIssue] = []
}
