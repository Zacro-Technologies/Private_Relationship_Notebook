import Foundation

public struct PersonMergePreview: Hashable, Sendable {
    public let source: Person
    public let destination: Person
    public let resultingPerson: Person
    public let interactionsToMove: Int
    public let warnings: [String]

    public init(
        source: Person,
        destination: Person,
        resultingPerson: Person,
        interactionsToMove: Int,
        warnings: [String]
    ) {
        self.source = source
        self.destination = destination
        self.resultingPerson = resultingPerson
        self.interactionsToMove = interactionsToMove
        self.warnings = warnings
    }
}

/// Exact before/after bytes for an interaction reference mutation. Keeping the
/// receipt as bytes avoids losing fractional date precision when the enclosing
/// merge event uses a human-readable ISO-8601 encoder.
public struct PersonMergeInteractionMutation: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let beforePayload: Data
    public let afterPayload: Data

    public init(id: UUID, beforePayload: Data, afterPayload: Data) {
        self.id = id
        self.beforePayload = beforePayload
        self.afterPayload = afterPayload
    }
}

/// Compare-and-swap receipt for a mutable canonical record changed by a merge.
/// Immutable provenance records are resolved through the merge redirect instead
/// of being rewritten.
public struct PersonMergeCanonicalMutation: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let kind: String
    public let beforePayload: Data
    public let afterPayload: Data
    public let beforeModifiedAtReferenceDate: TimeInterval?
    public let beforeDeletedAtReferenceDate: TimeInterval?
    public let afterModifiedAtReferenceDate: TimeInterval?
    public let afterDeletedAtReferenceDate: TimeInterval?

    public init(
        id: UUID,
        kind: String,
        beforePayload: Data,
        afterPayload: Data,
        beforeModifiedAtReferenceDate: TimeInterval?,
        beforeDeletedAtReferenceDate: TimeInterval?,
        afterModifiedAtReferenceDate: TimeInterval?,
        afterDeletedAtReferenceDate: TimeInterval?
    ) {
        self.id = id
        self.kind = kind
        self.beforePayload = beforePayload
        self.afterPayload = afterPayload
        self.beforeModifiedAtReferenceDate = beforeModifiedAtReferenceDate
        self.beforeDeletedAtReferenceDate = beforeDeletedAtReferenceDate
        self.afterModifiedAtReferenceDate = afterModifiedAtReferenceDate
        self.afterDeletedAtReferenceDate = afterDeletedAtReferenceDate
    }
}

/// Recovery state written in the same Core Data transaction as the merge. Undo
/// first verifies every after-state byte, then restores all before states in one
/// save; later edits therefore cause a conflict instead of being overwritten.
public struct PersonMergeRecoverySnapshot: Codable, Hashable, Sendable {
    public let sourcePersonBeforePayload: Data
    public let destinationPersonBeforePayload: Data
    public let sourcePersonAfterPayload: Data
    public let destinationPersonAfterPayload: Data
    public let interactionMutations: [PersonMergeInteractionMutation]
    public let canonicalMutations: [PersonMergeCanonicalMutation]

    public init(
        sourcePersonBeforePayload: Data,
        destinationPersonBeforePayload: Data,
        sourcePersonAfterPayload: Data,
        destinationPersonAfterPayload: Data,
        interactionMutations: [PersonMergeInteractionMutation],
        canonicalMutations: [PersonMergeCanonicalMutation]
    ) {
        self.sourcePersonBeforePayload = sourcePersonBeforePayload
        self.destinationPersonBeforePayload = destinationPersonBeforePayload
        self.sourcePersonAfterPayload = sourcePersonAfterPayload
        self.destinationPersonAfterPayload = destinationPersonAfterPayload
        self.interactionMutations = interactionMutations
        self.canonicalMutations = canonicalMutations
    }
}

public struct PersonMergeEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let sourcePersonBeforeMerge: Person
    public let destinationPersonBeforeMerge: Person
    public let interactionsBeforeMerge: [Interaction]
    public let mergedAt: Date
    public let recoveryExpiresAt: Date
    /// Optional so merge events written by earlier schema-1 builds remain
    /// readable. New events always include the compare-and-swap receipt.
    public let recoverySnapshot: PersonMergeRecoverySnapshot?
    public var undoneAt: Date?

    public init(
        id: UUID = UUID(),
        sourcePersonBeforeMerge: Person,
        destinationPersonBeforeMerge: Person,
        interactionsBeforeMerge: [Interaction],
        mergedAt: Date = .now,
        recoveryExpiresAt: Date? = nil,
        recoverySnapshot: PersonMergeRecoverySnapshot? = nil,
        undoneAt: Date? = nil
    ) {
        self.id = id
        self.sourcePersonBeforeMerge = sourcePersonBeforeMerge
        self.destinationPersonBeforeMerge = destinationPersonBeforeMerge
        self.interactionsBeforeMerge = interactionsBeforeMerge
        self.mergedAt = mergedAt
        self.recoveryExpiresAt = recoveryExpiresAt
            ?? Calendar(identifier: .gregorian).date(byAdding: .day, value: 30, to: mergedAt)
            ?? mergedAt.addingTimeInterval(30 * 86_400)
        self.recoverySnapshot = recoverySnapshot
        self.undoneAt = undoneAt
    }

    public var canUndo: Bool {
        undoneAt == nil && Date.now < recoveryExpiresAt
    }

    public var movedInteractionIDs: [UUID] { interactionsBeforeMerge.map(\.id) }
}

public enum PersonMergeError: LocalizedError, Equatable, Sendable {
    case missingPerson
    case samePerson
    case alreadyMerged
    case recoveryExpired
    case alreadyUndone
    case destinationChanged
    case interactionChanged
    case canonicalRecordChanged
    case recoverySnapshotUnavailable
    case saveFailed

    public var errorDescription: String? {
        switch self {
        case .missingPerson: String(localized: "One of the people no longer exists.")
        case .samePerson: String(localized: "Choose two different people.")
        case .alreadyMerged: String(localized: "One of these people has already been merged.")
        case .recoveryExpired: String(localized: "The merge recovery period has ended.")
        case .alreadyUndone: String(localized: "This merge has already been undone.")
        case .destinationChanged:
            String(localized: "Undo is unavailable because the merge destination changed in a conflicting way.")
        case .interactionChanged:
            String(localized: "Undo is unavailable because a moved interaction changed after the merge.")
        case .canonicalRecordChanged:
            String(localized: "Undo is unavailable because a linked reminder or commitment changed after the merge.")
        case .recoverySnapshotUnavailable:
            String(localized: "This merge was created by an earlier version and does not contain a safe recovery snapshot.")
        case .saveFailed:
            String(localized: "The merge could not be saved. Your existing records were left unchanged.")
        }
    }
}

public enum PersonMergePlanner {
    public static func preview(
        source: Person,
        destination: Person,
        interactions: [Interaction]
    ) -> PersonMergePreview {
        var result = destination
        result.aliases = orderedUnique(
            destination.aliases + [source.displayName] + source.aliases,
            excluding: destination.displayName
        )
        result.contexts = orderedUnique(destination.contexts + source.contexts)
        result.tags = orderedUnique(destination.tags + source.tags)
        result.contacts = uniqueContacts(destination.contacts + source.contacts)

        if result.pronunciation.isEmpty { result.pronunciation = source.pronunciation }
        if result.role.isEmpty { result.role = source.role }
        if result.mentionableContext.isEmpty { result.mentionableContext = source.mentionableContext }
        if result.privateNote.isEmpty { result.privateNote = source.privateNote }
        if result.recipientTimeZoneIdentifier == nil {
            result.recipientTimeZoneIdentifier = source.recipientTimeZoneIdentifier
        }
        if result.communicationPreferences == nil {
            result.communicationPreferences = source.communicationPreferences
        }
        if result.linkedContactIdentifier == nil {
            result.linkedContactIdentifier = source.linkedContactIdentifier
        }
        result.lastInteractionAt = [destination.lastInteractionAt, source.lastInteractionAt]
            .compactMap { $0 }
            .max()
        result.modifiedAt = .now

        var warnings: [String] = []
        if !source.privateNote.isEmpty, !destination.privateNote.isEmpty,
           source.privateNote != destination.privateNote {
            warnings.append(String(localized: "Both records contain private notes. The destination note stays current; the source note remains recoverable with the merged record."))
        }
        if !source.role.isEmpty, !destination.role.isEmpty, source.role != destination.role {
            warnings.append(String(localized: "The records have different current roles. The destination role stays current; structured role history is not discarded."))
        }
        if source.doNotContact != destination.doNotContact {
            warnings.append(String(localized: "Do-not-contact is enabled on one record and will remain enabled after the merge."))
            result.doNotContact = true
        }
        if source.neverSuggest != destination.neverSuggest {
            result.neverSuggest = source.neverSuggest || destination.neverSuggest
        }
        if let sourceLink = source.linkedContactIdentifier,
           let destinationLink = destination.linkedContactIdentifier,
           sourceLink != destinationLink {
            warnings.append(String(localized: "Both records are linked to different Contacts entries. The destination link stays current; relink it after the merge if needed."))
        }

        return PersonMergePreview(
            source: source,
            destination: destination,
            resultingPerson: result,
            interactionsToMove: interactions.filter { interaction in
                interaction.personID == source.id ||
                    (interaction.additionalParticipantIDs?.contains(source.id) ?? false)
            }.count,
            warnings: warnings
        )
    }

    private static func orderedUnique(_ values: [String], excluding excluded: String? = nil) -> [String] {
        var normalized = Set<String>()
        if let excluded { normalized.insert(SearchNormalizer.normalize(excluded)) }
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = SearchNormalizer.normalize(trimmed)
            guard normalized.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    private static func uniqueContacts(_ values: [ContactMethod]) -> [ContactMethod] {
        var seen = Set<String>()
        return values.filter { contact in
            let key = contact.kind.rawValue + "\u{0}" + SearchNormalizer.normalize(contact.value)
            return seen.insert(key).inserted
        }
    }
}
