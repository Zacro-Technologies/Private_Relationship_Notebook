import Foundation

public indirect enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
}

public struct MeasuredDecimal: Codable, Hashable, Sendable {
    public let value: Decimal
    public let unitCode: String?

    public init(value: Decimal, unitCode: String? = nil) {
        self.value = value
        self.unitCode = unitCode
    }
}

public struct LocationValue: Codable, Hashable, Sendable {
    public let label: String
    public let latitude: Double?
    public let longitude: Double?
    public let timeZoneIdentifier: String?

    public init(
        label: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        timeZoneIdentifier: String? = nil
    ) {
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public struct PostalAddressValue: Codable, Hashable, Sendable {
    public let street: String?
    public let locality: String?
    public let administrativeArea: String?
    public let postalCode: String?
    public let countryCode: String?

    public init(
        street: String? = nil,
        locality: String? = nil,
        administrativeArea: String? = nil,
        postalCode: String? = nil,
        countryCode: String? = nil
    ) {
        self.street = street
        self.locality = locality
        self.administrativeArea = administrativeArea
        self.postalCode = postalCode
        self.countryCode = countryCode
    }
}

public enum AttributeValueKind: String, Codable, CaseIterable, Sendable {
    case text
    case richText
    case boolean
    case number
    case partialDate
    case dateRange
    case singleSelect
    case multiSelect
    case language
    case url
    case email
    case phone
    case location
    case address
    case personReference
    case contextReference
    case mediaReference
    case structuredJSON
}

/// Canonical assertion payload. Its associated-value representation prevents
/// an assertion from populating more than one storage value at a time.
public enum TypedValue: Codable, Hashable, Sendable {
    case text(String)
    case richText(String)
    case boolean(Bool)
    case number(MeasuredDecimal)
    case partialDate(PartialDate)
    case dateRange(PartialDateRange)
    case singleSelect(UUID)
    case multiSelect([UUID])
    case language(String)
    case url(URL)
    case email(String)
    case phone(String)
    case location(LocationValue)
    case address(PostalAddressValue)
    case personReference(UUID)
    case contextReference(UUID)
    case mediaReference(UUID)
    case structuredJSON(JSONValue)

    public var kind: AttributeValueKind {
        switch self {
        case .text: .text
        case .richText: .richText
        case .boolean: .boolean
        case .number: .number
        case .partialDate: .partialDate
        case .dateRange: .dateRange
        case .singleSelect: .singleSelect
        case .multiSelect: .multiSelect
        case .language: .language
        case .url: .url
        case .email: .email
        case .phone: .phone
        case .location: .location
        case .address: .address
        case .personReference: .personReference
        case .contextReference: .contextReference
        case .mediaReference: .mediaReference
        case .structuredJSON: .structuredJSON
        }
    }

    public var isQueryable: Bool {
        kind != .structuredJSON
    }
}

public enum SourceArtifactKind: String, Codable, CaseIterable, Sendable {
    case pdf
    case image
    case screenshot
    case pastedText
    case json
    case exportedConversation
    case selfProfileCard
    case contactRecord
    case userNote
    case other
}

public enum SourceRetentionPolicy: String, Codable, CaseIterable, Sendable {
    case discardOriginalAfterExtraction
    case keepOriginalOnDevice
    case syncOriginalWithVault
}

public struct SourceArtifact: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var kind: SourceArtifactKind
    public var originalFilename: String?
    public var mediaID: UUID?
    public let sha256: String?
    public let importedAt: Date
    public var retentionPolicy: SourceRetentionPolicy
    public let parserVersion: String?
    public var aiPolicy: AIPolicy
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        kind: SourceArtifactKind,
        originalFilename: String? = nil,
        mediaID: UUID? = nil,
        sha256: String? = nil,
        importedAt: Date = .now,
        retentionPolicy: SourceRetentionPolicy = .discardOriginalAfterExtraction,
        parserVersion: String? = nil,
        aiPolicy: AIPolicy = .deny,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.kind = kind
        self.originalFilename = originalFilename
        self.mediaID = mediaID
        self.sha256 = sha256
        self.importedAt = importedAt
        self.retentionPolicy = retentionPolicy
        self.parserVersion = parserVersion
        self.aiPolicy = aiPolicy
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }
}

public enum ArtifactUnitKind: String, Codable, CaseIterable, Sendable {
    case page
    case slide
    case sheet
    case image
    case textBlock
    case message
    case record
}

public struct ArtifactUnit: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let sourceID: UUID
    public let kind: ArtifactUnitKind
    /// Zero-based page, slide, sheet, or record index.
    public let index: Int
    public let extractedTextReference: String?

    public init(
        id: UUID = UUID(),
        sourceID: UUID,
        kind: ArtifactUnitKind,
        index: Int,
        extractedTextReference: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.index = index
        self.extractedTextReference = extractedTextReference
    }
}

public enum EvidenceLocationValidationError: Error, Equatable, Sendable {
    case negativeTextOffset
    case reversedTextRange
    case nonFiniteRectangle
    case rectangleOutOfBounds
    case missingLocation
}

public struct TextEvidenceRange: Codable, Hashable, Sendable {
    public let startUTF16Offset: Int
    public let endUTF16Offset: Int

    public init(startUTF16Offset: Int, endUTF16Offset: Int) throws {
        guard startUTF16Offset >= 0, endUTF16Offset >= 0 else {
            throw EvidenceLocationValidationError.negativeTextOffset
        }
        guard startUTF16Offset <= endUTF16Offset else {
            throw EvidenceLocationValidationError.reversedTextRange
        }
        self.startUTF16Offset = startUTF16Offset
        self.endUTF16Offset = endUTF16Offset
    }

    private enum CodingKeys: String, CodingKey {
        case startUTF16Offset
        case endUTF16Offset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                startUTF16Offset: container.decode(Int.self, forKey: .startUTF16Offset),
                endUTF16Offset: container.decode(Int.self, forKey: .endUTF16Offset)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .startUTF16Offset,
                in: container,
                debugDescription: "Invalid evidence text range: \(error)"
            )
        }
    }
}

public struct NormalizedBoundingBox: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite) else {
            throw EvidenceLocationValidationError.nonFiniteRectangle
        }
        guard x >= 0, y >= 0, width >= 0, height >= 0,
              x + width <= 1, y + height <= 1 else {
            throw EvidenceLocationValidationError.rectangleOutOfBounds
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                x: container.decode(Double.self, forKey: .x),
                y: container.decode(Double.self, forKey: .y),
                width: container.decode(Double.self, forKey: .width),
                height: container.decode(Double.self, forKey: .height)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .x,
                in: container,
                debugDescription: "Invalid normalized bounding box: \(error)"
            )
        }
    }
}

public struct EvidenceSpan: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let unitID: UUID
    public let textRange: TextEvidenceRange?
    public let boundingBox: NormalizedBoundingBox?
    public let excerptHash: String?
    /// Present only when the user opted to retain the excerpt itself.
    public let retainedExcerpt: String?

    public init(
        id: UUID = UUID(),
        unitID: UUID,
        textRange: TextEvidenceRange? = nil,
        boundingBox: NormalizedBoundingBox? = nil,
        excerptHash: String? = nil,
        retainedExcerpt: String? = nil
    ) throws {
        guard textRange != nil || boundingBox != nil || retainedExcerpt != nil else {
            throw EvidenceLocationValidationError.missingLocation
        }
        self.id = id
        self.unitID = unitID
        self.textRange = textRange
        self.boundingBox = boundingBox
        self.excerptHash = excerptHash
        self.retainedExcerpt = retainedExcerpt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case unitID
        case textRange
        case boundingBox
        case excerptHash
        case retainedExcerpt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                unitID: container.decode(UUID.self, forKey: .unitID),
                textRange: container.decodeIfPresent(TextEvidenceRange.self, forKey: .textRange),
                boundingBox: container.decodeIfPresent(NormalizedBoundingBox.self, forKey: .boundingBox),
                excerptHash: container.decodeIfPresent(String.self, forKey: .excerptHash),
                retainedExcerpt: container.decodeIfPresent(String.self, forKey: .retainedExcerpt)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Invalid evidence span: \(error)"
            )
        }
    }
}

public enum Origin: String, Codable, CaseIterable, Sendable {
    case manual
    case imported
    case remoteSelf = "remote_self"
    case deterministic
    case model
}

/// Identifies the exact self-profile publication field from which a recipient
/// accepted a remote-self assertion. The digest is over the received bytes,
/// not a re-encoded model, so provenance remains tied to the reviewed file.
public struct RemoteSelfProfileProvenance: Codable, Hashable, Sendable {
    public let publicationID: UUID
    public let cardVersionID: UUID
    public let cardVersion: Int
    public let publishedAt: Date
    public let fieldID: UUID
    public let fieldKey: ShareableProfileFieldKey
    public let fieldAudience: ProfileSnapshotAudience
    public let exactPayloadSHA256: String
    public let authorshipIsUnverified: Bool
    public let advisoryExpiresAt: Date?
    public let retentionIntent: ProfileSnapshotRetentionIntent

    public init(
        publicationID: UUID,
        cardVersionID: UUID,
        cardVersion: Int,
        publishedAt: Date,
        fieldID: UUID,
        fieldKey: ShareableProfileFieldKey,
        fieldAudience: ProfileSnapshotAudience,
        exactPayloadSHA256: String,
        authorshipIsUnverified: Bool,
        advisoryExpiresAt: Date?,
        retentionIntent: ProfileSnapshotRetentionIntent
    ) {
        self.publicationID = publicationID
        self.cardVersionID = cardVersionID
        self.cardVersion = cardVersion
        self.publishedAt = publishedAt
        self.fieldID = fieldID
        self.fieldKey = fieldKey
        self.fieldAudience = fieldAudience
        self.exactPayloadSHA256 = exactPayloadSHA256
        self.authorshipIsUnverified = authorshipIsUnverified
        self.advisoryExpiresAt = advisoryExpiresAt
        self.retentionIntent = retentionIntent
    }
}

public enum AssertionReviewStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case rejected
    case deferred
    case conflicted
}

public enum AssertionCertainty: String, Codable, CaseIterable, Sendable {
    case exact
    case approximate
    case unknown
}

public enum Sensitivity: String, Codable, CaseIterable, Sendable {
    case ordinary
    case `private`
    case sensitive
    case highlySensitive = "highly_sensitive"
}

public enum MentionPolicy: String, Codable, CaseIterable, Sendable {
    case allow
    case ask
    case never
}

public enum AIPolicy: String, Codable, CaseIterable, Sendable {
    case deny
    case allowOnDevice = "allow_on_device"
    case allowPrivateCloudCompute = "allow_private_cloud_compute"
    /// Explicit permission for the user-owned, editable Apple Shortcut used by
    /// Keepsake's central AI workflow. This is intentionally distinct from the
    /// native PCC permission because the app cannot inspect or attest a
    /// Shortcut's selected model or added actions.
    case allowConfiguredShortcut = "allow_configured_shortcut"
}

/// Effective processing boundary after item- and source-level consent are
/// combined. Only `configuredShortcutEligible` is accepted by the production
/// generative-AI handoff; the native cases remain decode-compatible for data
/// created before the central Shortcut architecture.
public enum IntelligenceSourcePolicy: String, Codable, Sendable {
    case cloudEligible
    case onDeviceOnly
    case configuredShortcutEligible = "configured_shortcut_eligible"
    case modelsDenied
}

public enum SearchUsePolicy: String, Codable, CaseIterable, Sendable {
    case include
    case exclude
}

public enum NotificationUsePolicy: String, Codable, CaseIterable, Sendable {
    case exclude
    case genericOnly = "generic_only"
    case includeValue = "include_value"
}

public enum SharingUsePolicy: String, Codable, CaseIterable, Sendable {
    case exclude
    case eligibleAfterPreview = "eligible_after_preview"
}

public struct AssertionUsePolicy: Codable, Hashable, Sendable {
    public let search: SearchUsePolicy
    public let remindersAllowed: Bool
    public let notifications: NotificationUsePolicy
    public let sharing: SharingUsePolicy
    public let mention: MentionPolicy
    public let ai: AIPolicy

    public init(
        search: SearchUsePolicy = .include,
        remindersAllowed: Bool = true,
        notifications: NotificationUsePolicy = .genericOnly,
        sharing: SharingUsePolicy = .exclude,
        mention: MentionPolicy = .ask,
        ai: AIPolicy = .deny
    ) {
        self.search = search
        self.remindersAllowed = remindersAllowed
        self.notifications = notifications
        self.sharing = sharing
        self.mention = mention
        self.ai = ai
    }

    public static let restrictive = AssertionUsePolicy(
        search: .exclude,
        remindersAllowed: false,
        notifications: .exclude,
        sharing: .exclude,
        mention: .never,
        ai: .deny
    )
}

public enum AssertionValidationError: Error, Equatable, Sendable {
    case emptyPredicateID
    case confidenceOutOfRange(Double)
    case evidenceRequiresSource
    case sourceRequiredForOrigin(Origin)
    case duplicateEvidenceID(UUID)
    case invalidValidityRange
    case cannotSupersedeSelf
}

/// An immutable, source-aware claim. A changed value is represented by a new
/// envelope whose `supersedesID` points at the prior assertion.
public struct AssertionEnvelope: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let subjectID: UUID
    public let predicateID: String
    public let value: TypedValue
    public let sourceID: UUID?
    public let evidenceIDs: [UUID]
    public let origin: Origin
    public let confidence: Double?
    public let reviewStatus: AssertionReviewStatus
    public let certainty: AssertionCertainty
    public let observedAt: Date
    public let assertedAt: Date
    public let validFrom: PartialDate?
    public let validTo: PartialDate?
    public let sensitivity: Sensitivity
    public let usePolicy: AssertionUsePolicy
    public let supersedesID: UUID?
    public let remoteSelfProfileProvenance: RemoteSelfProfileProvenance?
    public let schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        subjectID: UUID,
        predicateID: String,
        value: TypedValue,
        sourceID: UUID? = nil,
        evidenceIDs: [UUID] = [],
        origin: Origin = .manual,
        confidence: Double? = nil,
        reviewStatus: AssertionReviewStatus = .accepted,
        certainty: AssertionCertainty = .exact,
        observedAt: Date = .now,
        assertedAt: Date = .now,
        validFrom: PartialDate? = nil,
        validTo: PartialDate? = nil,
        sensitivity: Sensitivity = .private,
        usePolicy: AssertionUsePolicy = .init(),
        supersedesID: UUID? = nil,
        remoteSelfProfileProvenance: RemoteSelfProfileProvenance? = nil,
        schemaRevision: Int32 = 1
    ) throws {
        let predicateID = predicateID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !predicateID.isEmpty else { throw AssertionValidationError.emptyPredicateID }
        if let confidence {
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw AssertionValidationError.confidenceOutOfRange(confidence)
            }
        }
        guard sourceID != nil || evidenceIDs.isEmpty else {
            throw AssertionValidationError.evidenceRequiresSource
        }
        if origin == .imported || origin == .remoteSelf {
            guard sourceID != nil else {
                throw AssertionValidationError.sourceRequiredForOrigin(origin)
            }
        }
        var seenEvidence = Set<UUID>()
        for evidenceID in evidenceIDs where !seenEvidence.insert(evidenceID).inserted {
            throw AssertionValidationError.duplicateEvidenceID(evidenceID)
        }
        guard PartialDateRange.isOrdered(start: validFrom, end: validTo) else {
            throw AssertionValidationError.invalidValidityRange
        }
        guard supersedesID != id else { throw AssertionValidationError.cannotSupersedeSelf }

        self.id = id
        self.subjectID = subjectID
        self.predicateID = predicateID
        self.value = value
        self.sourceID = sourceID
        self.evidenceIDs = evidenceIDs
        self.origin = origin
        self.confidence = confidence
        self.reviewStatus = reviewStatus
        self.certainty = certainty
        self.observedAt = observedAt
        self.assertedAt = assertedAt
        self.validFrom = validFrom
        self.validTo = validTo
        self.sensitivity = sensitivity
        self.usePolicy = usePolicy
        self.supersedesID = supersedesID
        self.remoteSelfProfileProvenance = remoteSelfProfileProvenance
        self.schemaRevision = schemaRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case subjectID
        case predicateID
        case value
        case sourceID
        case evidenceIDs
        case origin
        case confidence
        case reviewStatus
        case certainty
        case observedAt
        case assertedAt
        case validFrom
        case validTo
        case sensitivity
        case usePolicy
        case supersedesID
        case remoteSelfProfileProvenance
        case schemaRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                subjectID: container.decode(UUID.self, forKey: .subjectID),
                predicateID: container.decode(String.self, forKey: .predicateID),
                value: container.decode(TypedValue.self, forKey: .value),
                sourceID: container.decodeIfPresent(UUID.self, forKey: .sourceID),
                evidenceIDs: container.decode([UUID].self, forKey: .evidenceIDs),
                origin: container.decode(Origin.self, forKey: .origin),
                confidence: container.decodeIfPresent(Double.self, forKey: .confidence),
                reviewStatus: container.decode(AssertionReviewStatus.self, forKey: .reviewStatus),
                certainty: container.decode(AssertionCertainty.self, forKey: .certainty),
                observedAt: container.decode(Date.self, forKey: .observedAt),
                assertedAt: container.decode(Date.self, forKey: .assertedAt),
                validFrom: container.decodeIfPresent(PartialDate.self, forKey: .validFrom),
                validTo: container.decodeIfPresent(PartialDate.self, forKey: .validTo),
                sensitivity: container.decode(Sensitivity.self, forKey: .sensitivity),
                usePolicy: container.decode(AssertionUsePolicy.self, forKey: .usePolicy),
                supersedesID: container.decodeIfPresent(UUID.self, forKey: .supersedesID),
                remoteSelfProfileProvenance: container.decodeIfPresent(
                    RemoteSelfProfileProvenance.self,
                    forKey: .remoteSelfProfileProvenance
                ),
                schemaRevision: container.decode(Int32.self, forKey: .schemaRevision)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Invalid assertion envelope: \(error)"
            )
        }
    }
}

public typealias FactAssertion = AssertionEnvelope
