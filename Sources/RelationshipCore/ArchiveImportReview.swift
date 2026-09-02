import Foundation

public enum ArchivePersonField: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case displayName
    case pronunciation
    case aliases
    case contexts
    case role
    case tags
    case privateNote
    case mentionableContext
    case circle
    case contacts
    case cadenceDays
    case priority
    case lastInteractionAt
    case snoozedUntil
    case isArchived
    case neverSuggest
    case doNotContact
    case nameVariants

    public var id: Self { self }
}

public enum ArchiveSameNameDecision: Hashable, Codable, Sendable {
    case undecided
    case createSeparate
    case matchExisting(UUID)
    case skip
}

public struct ArchiveImportReviewSelection: Hashable, Codable, Sendable {
    public var selectedPersonCreateIDs: Set<UUID>
    public var selectedPersonUpdateFields: [UUID: Set<ArchivePersonField>]
    public var sameNameDecisions: [UUID: ArchiveSameNameDecision]
    public var sameNameMatchedFields: [UUID: Set<ArchivePersonField>]
    public var selectedInteractionCreateIDs: Set<UUID>
    public var selectedIncomingInteractionConflictIDs: Set<UUID>
    public var selectedStructuredRecords: Set<ArchiveStructuredRecordIdentity>
    public var selectedPreservedExtensionKeys: Set<String>

    public init(
        selectedPersonCreateIDs: Set<UUID> = [],
        selectedPersonUpdateFields: [UUID: Set<ArchivePersonField>] = [:],
        sameNameDecisions: [UUID: ArchiveSameNameDecision] = [:],
        sameNameMatchedFields: [UUID: Set<ArchivePersonField>] = [:],
        selectedInteractionCreateIDs: Set<UUID> = [],
        selectedIncomingInteractionConflictIDs: Set<UUID> = [],
        selectedStructuredRecords: Set<ArchiveStructuredRecordIdentity> = [],
        selectedPreservedExtensionKeys: Set<String> = []
    ) {
        self.selectedPersonCreateIDs = selectedPersonCreateIDs
        self.selectedPersonUpdateFields = selectedPersonUpdateFields
        self.sameNameDecisions = sameNameDecisions
        self.sameNameMatchedFields = sameNameMatchedFields
        self.selectedInteractionCreateIDs = selectedInteractionCreateIDs
        self.selectedIncomingInteractionConflictIDs = selectedIncomingInteractionConflictIDs
        self.selectedStructuredRecords = selectedStructuredRecords
        self.selectedPreservedExtensionKeys = selectedPreservedExtensionKeys
    }

    public static func proposed(
        plan: ArchiveImportPlan,
        existingPeople: [Person]
    ) -> ArchiveImportReviewSelection {
        let activeExisting = existingPeople.filter { $0.deletedAt == nil && $0.mergedIntoPersonID == nil }
        var sameName: [UUID: ArchiveSameNameDecision] = [:]
        var createIDs = Set<UUID>()
        for person in plan.peopleToCreate {
            let name = SearchNormalizer.normalize(person.displayName)
            let hasPossibleMatch = activeExisting.contains {
                SearchNormalizer.normalize($0.displayName) == name
            }
            if hasPossibleMatch {
                sameName[person.id] = .undecided
            } else {
                createIDs.insert(person.id)
            }
        }
        return ArchiveImportReviewSelection(
            selectedPersonCreateIDs: createIDs,
            selectedPersonUpdateFields: Dictionary(
                uniqueKeysWithValues: plan.personUpdates.map { ($0.id, []) }
            ),
            sameNameDecisions: sameName,
            selectedInteractionCreateIDs: Set(plan.interactionsToCreate.map(\.id)),
            selectedStructuredRecords: Set(plan.structuredRecordsToCreate),
            selectedPreservedExtensionKeys: Set(plan.preservedExtensionsToCreate.keys)
        )
    }

    public var unresolvedSameNamePersonIDs: Set<UUID> {
        Set(sameNameDecisions.compactMap { id, decision in
            if case .undecided = decision { return id }
            return nil
        })
    }
}

public struct ArchivePersonFieldDiff: Hashable, Codable, Sendable, Identifiable {
    public var personID: UUID
    public var field: ArchivePersonField
    public var existingValue: String
    public var incomingValue: String
    public var id: String { "\(personID.uuidString):\(field.rawValue)" }
}

public struct ArchiveImportReviewReportRow: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var group: String
    public var recordType: String
    public var recordID: String
    public var label: String
    public var decision: String

    public init(
        id: UUID = UUID(),
        group: String,
        recordType: String,
        recordID: String,
        label: String,
        decision: String
    ) {
        self.id = id
        self.group = group
        self.recordType = recordType
        self.recordID = recordID
        self.label = label
        self.decision = decision
    }
}

public struct ArchiveImportReviewReport: Hashable, Codable, Sendable {
    public var archiveSHA256: String
    public var reviewedAt: Date
    public var rows: [ArchiveImportReviewReportRow]
    public var omittedDependencyRecordIDs: [String]

    public init(
        archiveSHA256: String,
        reviewedAt: Date = .now,
        rows: [ArchiveImportReviewReportRow],
        omittedDependencyRecordIDs: [String] = []
    ) {
        self.archiveSHA256 = archiveSHA256
        self.reviewedAt = reviewedAt
        self.rows = rows
        self.omittedDependencyRecordIDs = omittedDependencyRecordIDs
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

public struct ReviewedArchiveImport: Sendable {
    public var archive: NotebookArchive
    public var report: ArchiveImportReviewReport

    public init(archive: NotebookArchive, report: ArchiveImportReviewReport) {
        self.archive = archive
        self.report = report
    }
}

public enum ArchiveImportReviewError: LocalizedError, Equatable, Sendable {
    case blockingInspectionIssue
    case unresolvedSameName(Set<UUID>)
    case unknownMatchTarget(UUID)

    public var errorDescription: String? {
        switch self {
        case .blockingInspectionIssue:
            String(localized: "This archive still has a blocking inspection issue.")
        case .unresolvedSameName:
            String(localized: "Choose Separate, Match, or Skip for every possible same-name record.")
        case .unknownMatchTarget:
            String(localized: "A selected same-name destination is no longer available.")
        }
    }
}

public struct ArchiveImportReviewEngine: Sendable {
    public init() {}

    public func fieldDiffs(for update: ArchivePersonUpdate) -> [ArchivePersonFieldDiff] {
        ArchivePersonField.allCases.compactMap { field in
            let existing = displayValue(field, in: update.existing)
            let incoming = displayValue(field, in: update.incoming)
            guard existing != incoming else { return nil }
            return ArchivePersonFieldDiff(
                personID: update.id,
                field: field,
                existingValue: existing,
                incomingValue: incoming
            )
        }
    }

    public func review(
        archive: NotebookArchive,
        plan: ArchiveImportPlan,
        existingPeople: [Person],
        selection: ArchiveImportReviewSelection,
        reviewedAt: Date = .now
    ) throws -> ReviewedArchiveImport {
        guard !plan.hasBlockingIssues else { throw ArchiveImportReviewError.blockingInspectionIssue }
        let unresolved = selection.unresolvedSameNamePersonIDs
        guard unresolved.isEmpty else { throw ArchiveImportReviewError.unresolvedSameName(unresolved) }

        let existingByID = Dictionary(uniqueKeysWithValues: existingPeople.map { ($0.id, $0) })
        var rows: [ArchiveImportReviewReportRow] = []
        var people: [Person] = []
        var remappedPersonIDs: [UUID: UUID] = [:]
        var excludedPersonIDs = Set<UUID>()

        for incoming in plan.peopleToCreate {
            if let sameNameDecision = selection.sameNameDecisions[incoming.id] {
                switch sameNameDecision {
                case .undecided:
                    throw ArchiveImportReviewError.unresolvedSameName([incoming.id])
                case .createSeparate:
                    people.append(incoming)
                    rows.append(row("create", "person", incoming.id, incoming.displayName, "create separate"))
                case .skip:
                    excludedPersonIDs.insert(incoming.id)
                    rows.append(row("skip", "person", incoming.id, incoming.displayName, "skip possible match"))
                case .matchExisting(let targetID):
                    guard let existing = existingByID[targetID],
                          existing.deletedAt == nil,
                          existing.mergedIntoPersonID == nil else {
                        throw ArchiveImportReviewError.unknownMatchTarget(targetID)
                    }
                    let fields = selection.sameNameMatchedFields[incoming.id] ?? []
                    if !fields.isEmpty {
                        people.append(applying(fields, from: incoming, to: existing, at: reviewedAt))
                    }
                    remappedPersonIDs[incoming.id] = targetID
                    rows.append(row("match", "person", incoming.id, incoming.displayName, "match \(targetID.uuidString); \(fields.count) field(s) applied"))
                }
            } else if selection.selectedPersonCreateIDs.contains(incoming.id) {
                people.append(incoming)
                rows.append(row("create", "person", incoming.id, incoming.displayName, "create"))
            } else {
                excludedPersonIDs.insert(incoming.id)
                rows.append(row("skip", "person", incoming.id, incoming.displayName, "skip"))
            }
        }

        for update in plan.personUpdates {
            let fields = selection.selectedPersonUpdateFields[update.id] ?? []
            if fields.isEmpty {
                rows.append(row("update", "person", update.id, update.incoming.displayName, "keep every existing field"))
            } else {
                people.append(applying(fields, from: update.incoming, to: update.existing, at: reviewedAt))
                rows.append(row("update", "person", update.id, update.incoming.displayName, "apply \(fields.count) selected field(s)"))
            }
        }

        let existingActiveIDs = Set(existingPeople.filter {
            $0.deletedAt == nil && $0.mergedIntoPersonID == nil
        }.map(\.id))
        let availablePersonIDs = existingActiveIDs.union(people.map(\.id))
        var interactions: [Interaction] = []
        let incomingInteractions = plan.interactionsToCreate.filter {
            selection.selectedInteractionCreateIDs.contains($0.id)
        } + plan.interactionConflicts.compactMap {
            selection.selectedIncomingInteractionConflictIDs.contains($0.id) ? $0.incoming : nil
        }
        for incoming in incomingInteractions {
            var interaction = incoming
            interaction.personID = interaction.personID.map { remappedPersonIDs[$0] ?? $0 }
            interaction.additionalParticipantIDs = interaction.additionalParticipantIDs?.map {
                remappedPersonIDs[$0] ?? $0
            }
            let participantIDs = Set(([interaction.personID].compactMap { $0 }) + (interaction.additionalParticipantIDs ?? []))
            guard participantIDs.isSubset(of: availablePersonIDs),
                  participantIDs.isDisjoint(with: excludedPersonIDs) else {
                rows.append(row("dependency", "interaction", interaction.id, interaction.channel, "skip because a participant was skipped"))
                continue
            }
            interactions.append(interaction)
            rows.append(row("interaction", "interaction", interaction.id, interaction.channel, "import"))
        }

        let requestedStructured = selection.selectedStructuredRecords
            .intersection(plan.structuredRecordsToCreate)
        let prunedStructured = dependencyClosedSelection(
            requestedStructured,
            incoming: archive.canonical,
            availablePersonIDs: availablePersonIDs,
            selectedInteractionIDs: Set(interactions.map(\.id)),
            allNew: Set(plan.structuredRecordsToCreate)
        )
        var canonical = archive.canonical?.selectingNewRecords(identifiedBy: prunedStructured.selected)
        if !remappedPersonIDs.isEmpty || !excludedPersonIDs.isEmpty {
            canonical = canonical?.droppingPersonReferences(
                to: Set(remappedPersonIDs.keys).union(excludedPersonIDs)
            )
        }
        for identity in plan.structuredRecordsToCreate {
            rows.append(row(
                "structured",
                identity.family.rawValue,
                identity.id,
                identity.family.rawValue,
                prunedStructured.selected.contains(identity) ? "import" : "skip"
            ))
        }

        let profiles = archive.ownedProfileSnapshots?.filter {
            prunedStructured.selected.contains(.init(family: .profileSnapshot, id: $0.cardVersionID))
        }
        let extensions = plan.preservedExtensionsToCreate.filter {
            selection.selectedPreservedExtensionKeys.contains($0.key)
        }
        for key in plan.preservedExtensionsToCreate.keys.sorted() {
            rows.append(ArchiveImportReviewReportRow(
                group: "extension",
                recordType: "extension",
                recordID: key,
                label: key,
                decision: extensions[key] == nil ? "skip" : "import"
            ))
        }

        let reviewed = NotebookArchive(
            schemaVersion: archive.schemaVersion,
            exportedAt: archive.exportedAt,
            people: people,
            interactions: interactions,
            canonical: canonical,
            ownedProfileSnapshots: profiles,
            preservedExtensions: extensions.isEmpty ? nil : extensions
        )
        let report = ArchiveImportReviewReport(
            archiveSHA256: plan.archiveSHA256,
            reviewedAt: reviewedAt,
            rows: rows,
            omittedDependencyRecordIDs: prunedStructured.omitted.map {
                "\($0.family.rawValue):\($0.id.uuidString)"
            }.sorted()
        )
        return ReviewedArchiveImport(archive: reviewed, report: report)
    }

    private func applying(
        _ fields: Set<ArchivePersonField>,
        from incoming: Person,
        to existing: Person,
        at date: Date
    ) -> Person {
        var result = existing
        for field in fields {
            switch field {
            case .displayName: result.displayName = incoming.displayName
            case .pronunciation: result.pronunciation = incoming.pronunciation
            case .aliases: result.aliases = incoming.aliases
            case .contexts: result.contexts = incoming.contexts
            case .role: result.role = incoming.role
            case .tags: result.tags = incoming.tags
            case .privateNote: result.privateNote = incoming.privateNote
            case .mentionableContext: result.mentionableContext = incoming.mentionableContext
            case .circle: result.circle = incoming.circle
            case .contacts: result.contacts = incoming.contacts
            case .cadenceDays: result.cadenceDays = incoming.cadenceDays
            case .priority: result.priority = incoming.priority
            case .lastInteractionAt: result.lastInteractionAt = incoming.lastInteractionAt
            case .snoozedUntil: result.snoozedUntil = incoming.snoozedUntil
            case .isArchived: result.isArchived = incoming.isArchived
            case .neverSuggest: result.neverSuggest = incoming.neverSuggest
            case .doNotContact: result.doNotContact = incoming.doNotContact
            case .nameVariants: result.nameVariants = incoming.nameVariants
            }
        }
        result.modifiedAt = date
        return result
    }

    private func displayValue(_ field: ArchivePersonField, in person: Person) -> String {
        switch field {
        case .displayName: person.displayName
        case .pronunciation: person.pronunciation
        case .aliases: person.aliases.joined(separator: ", ")
        case .contexts: person.contexts.joined(separator: ", ")
        case .role: person.role
        case .tags: person.tags.joined(separator: ", ")
        case .privateNote: person.privateNote
        case .mentionableContext: person.mentionableContext
        case .circle: person.circle.rawValue
        case .contacts: person.contacts.map { "\($0.kind.rawValue): \($0.value)" }.joined(separator: ", ")
        case .cadenceDays: String(person.cadenceDays)
        case .priority: String(person.priority)
        case .lastInteractionAt: person.lastInteractionAt?.ISO8601Format() ?? "—"
        case .snoozedUntil: person.snoozedUntil?.ISO8601Format() ?? "—"
        case .isArchived: String(person.isArchived)
        case .neverSuggest: String(person.neverSuggest)
        case .doNotContact: String(person.doNotContact)
        case .nameVariants: (person.nameVariants ?? []).map(\.fullName).joined(separator: ", ")
        }
    }

    private func dependencyClosedSelection(
        _ requested: Set<ArchiveStructuredRecordIdentity>,
        incoming: CanonicalArchivePayload?,
        availablePersonIDs: Set<UUID>,
        selectedInteractionIDs: Set<UUID>,
        allNew: Set<ArchiveStructuredRecordIdentity>
    ) -> (selected: Set<ArchiveStructuredRecordIdentity>, omitted: Set<ArchiveStructuredRecordIdentity>) {
        guard let incoming else { return ([], requested) }
        var selected = requested
        func available(_ family: ArchiveStructuredRecordFamily, _ id: UUID) -> Bool {
            let identity = ArchiveStructuredRecordIdentity(family: family, id: id)
            return !allNew.contains(identity) || selected.contains(identity)
        }
        var changed = true
        while changed {
            changed = false
            func reject(_ identity: ArchiveStructuredRecordIdentity) {
                if selected.remove(identity) != nil { changed = true }
            }
            for record in incoming.memberships where selected.contains(.init(family: .membership, id: record.id)) {
                if !availablePersonIDs.contains(record.personID) || !available(.context, record.contextID) {
                    reject(.init(family: .membership, id: record.id))
                }
            }
            for record in incoming.cohorts where selected.contains(.init(family: .cohort, id: record.id)) {
                if !available(.cohortScheme, record.schemeID) {
                    reject(.init(family: .cohort, id: record.id))
                }
            }
            for record in incoming.cohortAssignments where selected.contains(.init(family: .cohortAssignment, id: record.id)) {
                if !available(.membership, record.membershipEpisodeID) || !available(.cohort, record.cohortID) {
                    reject(.init(family: .cohortAssignment, id: record.id))
                }
            }
            for record in incoming.roleAssignments where selected.contains(.init(family: .roleAssignment, id: record.id)) {
                if !available(.membership, record.membershipEpisodeID)
                    || !(record.roleDefinitionID.map { available(.roleDefinition, $0) } ?? true) {
                    reject(.init(family: .roleAssignment, id: record.id))
                }
            }
            for record in incoming.education where selected.contains(.init(family: .education, id: record.id)) {
                if !availablePersonIDs.contains(record.personID) || !available(.context, record.institutionContextID) {
                    reject(.init(family: .education, id: record.id))
                }
            }
            for record in incoming.assertions where selected.contains(.init(family: .assertion, id: record.id)) {
                if !availablePersonIDs.contains(record.subjectID)
                    || !(record.sourceID.map { available(.source, $0) } ?? true)
                    || !record.evidenceIDs.allSatisfy({ available(.evidence, $0) }) {
                    reject(.init(family: .assertion, id: record.id))
                }
            }
            for record in incoming.evidence where selected.contains(.init(family: .evidence, id: record.id)) {
                if !available(.artifactUnit, record.unitID) {
                    reject(.init(family: .evidence, id: record.id))
                }
            }
            for record in incoming.artifactUnits ?? [] where selected.contains(.init(family: .artifactUnit, id: record.id)) {
                if !available(.source, record.sourceID) {
                    reject(.init(family: .artifactUnit, id: record.id))
                }
            }
            for record in incoming.reminders where selected.contains(.init(family: .reminder, id: record.id)) {
                let subjectAvailable: Bool = switch record.subject {
                case .person(let id): availablePersonIDs.contains(id)
                case .interaction(let id): selectedInteractionIDs.contains(id)
                case .context(let id): available(.context, id)
                case .assertion(let id): available(.assertion, id)
                case .commitment(let id): available(.commitment, id)
                }
                if !subjectAvailable { reject(.init(family: .reminder, id: record.id)) }
            }
            for record in incoming.commitments where selected.contains(.init(family: .commitment, id: record.id)) {
                if !Set(record.personIDs).isSubset(of: availablePersonIDs)
                    || !(record.interactionID.map(selectedInteractionIDs.contains) ?? true) {
                    reject(.init(family: .commitment, id: record.id))
                }
            }
        }
        return (selected, requested.subtracting(selected))
    }

    private func row(
        _ group: String,
        _ type: String,
        _ id: UUID,
        _ label: String,
        _ decision: String
    ) -> ArchiveImportReviewReportRow {
        ArchiveImportReviewReportRow(
            group: group,
            recordType: type,
            recordID: id.uuidString,
            label: label,
            decision: decision
        )
    }
}

private extension CanonicalArchivePayload {
    func droppingPersonReferences(to personIDs: Set<UUID>) -> CanonicalArchivePayload {
        CanonicalArchivePayload(
            contexts: contexts,
            cohortSchemes: cohortSchemes,
            cohorts: cohorts,
            memberships: memberships.filter { !personIDs.contains($0.personID) },
            cohortAssignments: cohortAssignments,
            roleDefinitions: roleDefinitions,
            roleAssignments: roleAssignments,
            education: education.filter { !personIDs.contains($0.personID) },
            assertions: assertions.filter { !personIDs.contains($0.subjectID) },
            sources: sources,
            artifactUnits: artifactUnits,
            portraitMedia: portraitMedia,
            evidence: evidence,
            reminders: reminders.filter {
                if case .person(let id) = $0.subject { return !personIDs.contains(id) }
                return true
            },
            commitments: commitments.filter { Set($0.personIDs).isDisjoint(with: personIDs) },
            savedViews: savedViews,
            attributeDefinitions: attributeDefinitions,
            textImportReviews: textImportReviews,
            personMergeEvents: personMergeEvents.filter {
                !personIDs.contains($0.sourcePersonBeforeMerge.id)
                    && !personIDs.contains($0.destinationPersonBeforeMerge.id)
            }
        )
    }
}
