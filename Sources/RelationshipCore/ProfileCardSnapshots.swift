import Foundation

/// Deny-by-default field allowlist for self-profile snapshots. Private notes,
/// interaction history, reminders, relationship preferences, and source
/// artifacts intentionally have no representation here.
public enum ShareableProfileFieldKey: String, Codable, CaseIterable, Sendable {
    case preferredName = "preferred_name"
    case pronunciation
    case languages
    case timeZone = "time_zone"
    case contactMethod = "contact_method"
    case affiliation
    case cohort
    case currentRole = "current_role"
    case interests
    case communicationPreference = "communication_preference"
    case portrait
}

public enum ProfileSnapshotAudience: String, Codable, CaseIterable, Sendable {
    case anyRecipient = "any_recipient"
    case firstMeeting = "first_meeting"
    case scholarship
    case professional
    case friends
}

public enum ProfileSnapshotRetentionIntent: String, Codable, CaseIterable, Sendable {
    case recipientMayRetain = "recipient_may_retain"
    case askRecipientToDeleteAfterExpiry = "ask_recipient_to_delete_after_expiry"
}

public struct ProfileSnapshotLocalState: Hashable, Codable, Sendable, Identifiable {
    public var cardVersionID: UUID
    public var isRevokedForFutureSharing: Bool
    public var archivedAt: Date?
    public var modifiedAt: Date

    public var id: UUID { cardVersionID }

    public init(
        cardVersionID: UUID,
        isRevokedForFutureSharing: Bool = false,
        archivedAt: Date? = nil,
        modifiedAt: Date = .now
    ) {
        self.cardVersionID = cardVersionID
        self.isRevokedForFutureSharing = isRevokedForFutureSharing
        self.archivedAt = archivedAt
        self.modifiedAt = modifiedAt
    }
}

public enum ProfileSnapshotContactChannel: String, Codable, CaseIterable, Sendable {
    case email
    case messages
    case phone
    case line
    case instagram
    case whatsapp
    case snapchat
}

public enum ProfileSnapshotFieldValue: Hashable, Sendable {
    case text(String)
    case textList([String])
    case contact(channel: ProfileSnapshotContactChannel, value: String, label: String?)
    case sanitizedMedia(
        mediaID: UUID,
        contentType: String,
        sha256: String,
        byteCount: Int,
        metadataStripped: Bool
    )
}

extension ProfileSnapshotFieldValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case items
        case channel
        case value
        case label
        case mediaID = "media_id"
        case contentType = "content_type"
        case sha256
        case byteCount = "byte_count"
        case metadataStripped = "metadata_stripped"
    }

    private enum ValueType: String, Codable {
        case text
        case textList = "text_list"
        case contact
        case sanitizedMedia = "sanitized_media"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .textList:
            self = .textList(try container.decode([String].self, forKey: .items))
        case .contact:
            self = .contact(
                channel: try container.decode(ProfileSnapshotContactChannel.self, forKey: .channel),
                value: try container.decode(String.self, forKey: .value),
                label: try container.decodeIfPresent(String.self, forKey: .label)
            )
        case .sanitizedMedia:
            self = .sanitizedMedia(
                mediaID: try container.decode(UUID.self, forKey: .mediaID),
                contentType: try container.decode(String.self, forKey: .contentType),
                sha256: try container.decode(String.self, forKey: .sha256),
                byteCount: try container.decode(Int.self, forKey: .byteCount),
                metadataStripped: try container.decode(Bool.self, forKey: .metadataStripped)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(ValueType.text, forKey: .type)
            try container.encode(value, forKey: .text)
        case .textList(let values):
            try container.encode(ValueType.textList, forKey: .type)
            try container.encode(values, forKey: .items)
        case .contact(let channel, let value, let label):
            try container.encode(ValueType.contact, forKey: .type)
            try container.encode(channel, forKey: .channel)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(label, forKey: .label)
        case .sanitizedMedia(let mediaID, let contentType, let sha256, let byteCount, let metadataStripped):
            try container.encode(ValueType.sanitizedMedia, forKey: .type)
            try container.encode(mediaID, forKey: .mediaID)
            try container.encode(contentType, forKey: .contentType)
            try container.encode(sha256, forKey: .sha256)
            try container.encode(byteCount, forKey: .byteCount)
            try container.encode(metadataStripped, forKey: .metadataStripped)
        }
    }
}

/// The serializer accepts this deliberately small value graph rather than a
/// private `Person` or repository. The string key models untrusted/dynamic card
/// editor input and is converted to the strict allowlist during serialization.
public struct ProfileSnapshotFieldDraft: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var key: String
    public var value: ProfileSnapshotFieldValue
    public var audience: ProfileSnapshotAudience

    public init(
        id: UUID = UUID(),
        key: String,
        value: ProfileSnapshotFieldValue,
        audience: ProfileSnapshotAudience = .anyRecipient
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.audience = audience
    }
}

public struct ProfileCardSnapshotDraft: Hashable, Codable, Sendable {
    public var publicationID: UUID
    public var cardVersionID: UUID
    public var cardVersion: Int
    public var publishedAt: Date
    public var advisoryExpiresAt: Date?
    public var retentionIntent: ProfileSnapshotRetentionIntent
    public var fields: [ProfileSnapshotFieldDraft]
    public var embeddedMedia: [ProfileSnapshotEmbeddedMedia]

    public init(
        publicationID: UUID = UUID(),
        cardVersionID: UUID = UUID(),
        cardVersion: Int,
        publishedAt: Date = .now,
        advisoryExpiresAt: Date? = nil,
        retentionIntent: ProfileSnapshotRetentionIntent = .recipientMayRetain,
        fields: [ProfileSnapshotFieldDraft],
        embeddedMedia: [ProfileSnapshotEmbeddedMedia] = []
    ) {
        self.publicationID = publicationID
        self.cardVersionID = cardVersionID
        self.cardVersion = cardVersion
        self.publishedAt = publishedAt
        self.advisoryExpiresAt = advisoryExpiresAt
        self.retentionIntent = retentionIntent
        self.fields = fields
        self.embeddedMedia = embeddedMedia
    }
}

public struct ProfileSnapshotEmbeddedMedia: Hashable, Codable, Sendable, Identifiable {
    public var fieldID: UUID
    public var mediaID: UUID
    public var contentType: String
    public var sha256: String
    public var data: Data

    public var id: UUID { fieldID }

    public init(
        fieldID: UUID,
        mediaID: UUID,
        contentType: String,
        sha256: String,
        data: Data
    ) {
        self.fieldID = fieldID
        self.mediaID = mediaID
        self.contentType = contentType
        self.sha256 = sha256
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case fieldID = "field_id"
        case mediaID = "media_id"
        case contentType = "content_type"
        case sha256
        case data = "data_base64"
    }
}

public struct ProfileCardSnapshotField: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var key: ShareableProfileFieldKey
    public var value: ProfileSnapshotFieldValue
    public var audience: ProfileSnapshotAudience
    public var source: String

    public init(
        id: UUID,
        key: ShareableProfileFieldKey,
        value: ProfileSnapshotFieldValue,
        audience: ProfileSnapshotAudience,
        source: String = "self_asserted"
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.audience = audience
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id = "field_id"
        case key
        case value
        case audience
        case source
    }
}

public struct ProfileCardSnapshotPayload: Hashable, Codable, Sendable {
    public var schema: String
    public var format: String
    public var formatVersion: String
    public var schemaVersion: Int
    public var publicationID: UUID
    public var cardVersionID: UUID
    public var cardVersion: Int
    public var publishedAt: Date
    public var advisoryExpiresAt: Date?
    public var retentionIntent: ProfileSnapshotRetentionIntent
    public var expiryIsAdvisoryOnly: Bool
    public var authorshipIsUnverified: Bool
    public var fields: [ProfileCardSnapshotField]
    /// Exact metadata-stripped portrait bytes selected for this immutable
    /// version. Older snapshots omit this key and remain valid.
    public var embeddedMedia: [ProfileSnapshotEmbeddedMedia]?

    public init(
        schema: String = ProfileCardSnapshotSerializer.schemaIdentifier,
        format: String = ProfileCardSnapshotSerializer.formatIdentifier,
        formatVersion: String = "1.0.0",
        schemaVersion: Int = 1,
        publicationID: UUID,
        cardVersionID: UUID,
        cardVersion: Int,
        publishedAt: Date,
        advisoryExpiresAt: Date?,
        retentionIntent: ProfileSnapshotRetentionIntent,
        expiryIsAdvisoryOnly: Bool = true,
        authorshipIsUnverified: Bool = true,
        fields: [ProfileCardSnapshotField],
        embeddedMedia: [ProfileSnapshotEmbeddedMedia]? = nil
    ) {
        self.schema = schema
        self.format = format
        self.formatVersion = formatVersion
        self.schemaVersion = schemaVersion
        self.publicationID = publicationID
        self.cardVersionID = cardVersionID
        self.cardVersion = cardVersion
        self.publishedAt = publishedAt
        self.advisoryExpiresAt = advisoryExpiresAt
        self.retentionIntent = retentionIntent
        self.expiryIsAdvisoryOnly = expiryIsAdvisoryOnly
        self.authorshipIsUnverified = authorshipIsUnverified
        self.fields = fields
        self.embeddedMedia = embeddedMedia
    }

    private enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case format
        case formatVersion = "format_version"
        case schemaVersion = "schema_version"
        case publicationID = "publication_id"
        case cardVersionID = "card_version_id"
        case cardVersion = "card_version"
        case publishedAt = "published_at"
        case advisoryExpiresAt = "advisory_expires_at"
        case retentionIntent = "retention_intent"
        case expiryIsAdvisoryOnly = "expiry_is_advisory_only"
        case authorshipIsUnverified = "authorship_is_unverified"
        case fields
        case embeddedMedia = "embedded_media"
    }
}

public struct SerializedProfileCardSnapshot: Sendable {
    public var data: Data
    public var payload: ProfileCardSnapshotPayload

    public init(data: Data, payload: ProfileCardSnapshotPayload) {
        self.data = data
        self.payload = payload
    }
}

public enum ProfileSnapshotQRCodeError: LocalizedError, Equatable, Sendable {
    case payloadTooLarge
    case invalidCode

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            String(localized: "This exact profile copy is too large for reliable QR exchange. Share its profile file instead.")
        case .invalidCode:
            String(localized: "This QR code does not contain a Keepsake profile copy.")
        }
    }
}

public struct ProfileSnapshotQRCodeCodec: Sendable {
    public static let prefix = "keepsake-profile-v1:"
    public var maximumPayloadBytes: Int

    public init(maximumPayloadBytes: Int = 2_000) {
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    public func message(for exactPayloadBytes: Data) throws -> String {
        guard !exactPayloadBytes.isEmpty,
              exactPayloadBytes.count <= maximumPayloadBytes else {
            throw ProfileSnapshotQRCodeError.payloadTooLarge
        }
        let value = exactPayloadBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.prefix + value
    }

    public func exactPayloadBytes(from message: String) throws -> Data {
        guard message.hasPrefix(Self.prefix) else { throw ProfileSnapshotQRCodeError.invalidCode }
        var encoded = String(message.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        encoded.append(String(repeating: "=", count: padding))
        guard let data = Data(base64Encoded: encoded),
              !data.isEmpty,
              data.count <= maximumPayloadBytes else {
            throw ProfileSnapshotQRCodeError.invalidCode
        }
        return data
    }
}

public struct ProfileCardSnapshotLimits: Hashable, Codable, Sendable {
    public var maximumFields: Int
    public var maximumTextCharacters: Int
    public var maximumListItems: Int
    public var maximumMediaBytes: Int

    public init(
        maximumFields: Int = 64,
        maximumTextCharacters: Int = 1_000,
        maximumListItems: Int = 50,
        maximumMediaBytes: Int = 5_000_000
    ) {
        self.maximumFields = maximumFields
        self.maximumTextCharacters = maximumTextCharacters
        self.maximumListItems = maximumListItems
        self.maximumMediaBytes = maximumMediaBytes
    }
}

public enum ProfileCardSnapshotError: LocalizedError, Equatable, Sendable {
    case invalidCardVersion
    case emptySnapshot
    case tooManyFields
    case duplicateFieldIdentifier(UUID)
    case duplicateFieldKey(ShareableProfileFieldKey)
    case fieldNotShareable(String)
    case valueTypeDoesNotMatchField(ShareableProfileFieldKey)
    case invalidValue(ShareableProfileFieldKey)
    case unsanitizedMedia
    case invalidExpiry
    case malformedPayload
    case unsupportedSchema
    case unexpectedPayloadKey(String)
    case missingMediaPayload(UUID)
    case invalidMediaPayload(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidCardVersion: String(localized: "The profile-card version must be greater than zero.")
        case .emptySnapshot: String(localized: "Select at least one self-profile field before sharing.")
        case .tooManyFields: String(localized: "The profile card contains too many fields.")
        case .duplicateFieldIdentifier: String(localized: "Each shared profile field needs a unique identifier.")
        case .duplicateFieldKey(let key):
            String(localized: "The profile card includes ‘\(key.rawValue)’ more than once.")
        case .fieldNotShareable(let key):
            String(localized: "The field ‘\(key)’ is not eligible for profile sharing.")
        case .valueTypeDoesNotMatchField(let key):
            String(localized: "The value type is not valid for ‘\(key.rawValue)’.")
        case .invalidValue(let key):
            String(localized: "The value for ‘\(key.rawValue)’ is invalid.")
        case .unsanitizedMedia: String(localized: "Profile media must have private metadata removed before sharing.")
        case .invalidExpiry: String(localized: "Advisory expiry must be later than the publication date.")
        case .malformedPayload: String(localized: "The profile snapshot is malformed.")
        case .unsupportedSchema: String(localized: "This profile snapshot schema is not supported.")
        case .unexpectedPayloadKey(let key):
            String(localized: "The profile snapshot contains an unexpected key: \(key).")
        case .missingMediaPayload:
            String(localized: "A selected portrait is missing its sanitized image bytes.")
        case .invalidMediaPayload:
            String(localized: "A selected portrait payload does not match its reviewed metadata.")
        }
    }
}

/// Creates immutable, exact-preview JSON bytes from the isolated card graph.
/// It cannot accept a private `Person`, interaction, note, or repository.
public struct ProfileCardSnapshotSerializer: Sendable {
    public static let schemaIdentifier = "urn:private-relationship-notebook:schema:profile-card:1.0"
    public static let formatIdentifier = "private-relationship-notebook-profile-card"

    public var limits: ProfileCardSnapshotLimits

    public init(limits: ProfileCardSnapshotLimits = .init()) {
        self.limits = limits
    }

    public func serialize(_ draft: ProfileCardSnapshotDraft) throws -> SerializedProfileCardSnapshot {
        guard draft.cardVersion > 0 else { throw ProfileCardSnapshotError.invalidCardVersion }
        guard !draft.fields.isEmpty else { throw ProfileCardSnapshotError.emptySnapshot }
        guard draft.fields.count <= limits.maximumFields else { throw ProfileCardSnapshotError.tooManyFields }
        if let expiry = draft.advisoryExpiresAt, expiry <= draft.publishedAt {
            throw ProfileCardSnapshotError.invalidExpiry
        }

        var identifiers = Set<UUID>()
        var fieldKeys = Set<ShareableProfileFieldKey>()
        var fields: [ProfileCardSnapshotField] = []
        for draftField in draft.fields {
            guard identifiers.insert(draftField.id).inserted else {
                throw ProfileCardSnapshotError.duplicateFieldIdentifier(draftField.id)
            }
            guard let key = ShareableProfileFieldKey(rawValue: draftField.key) else {
                throw ProfileCardSnapshotError.fieldNotShareable(draftField.key)
            }
            guard fieldKeys.insert(key).inserted else {
                throw ProfileCardSnapshotError.duplicateFieldKey(key)
            }
            try validate(draftField.value, for: key)
            fields.append(ProfileCardSnapshotField(
                id: draftField.id,
                key: key,
                value: draftField.value,
                audience: draftField.audience
            ))
        }

        let payload = ProfileCardSnapshotPayload(
            publicationID: draft.publicationID,
            cardVersionID: draft.cardVersionID,
            cardVersion: draft.cardVersion,
            publishedAt: draft.publishedAt,
            advisoryExpiresAt: draft.advisoryExpiresAt,
            retentionIntent: draft.retentionIntent,
            fields: fields,
            embeddedMedia: draft.embeddedMedia.isEmpty ? nil : draft.embeddedMedia
        )
        try validateEmbeddedMedia(payload, requiresPayloadForMediaFields: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return SerializedProfileCardSnapshot(data: data, payload: payload)
    }

    /// The preview must be built with this method from the exact bytes that will
    /// be shared, avoiding a second view model with broader data access.
    public func preview(from exactPayloadBytes: Data) throws -> ProfileCardSnapshotPayload {
        try deserialize(exactPayloadBytes)
    }

    public func canonicalBytes(for payload: ProfileCardSnapshotPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        guard try deserialize(data) == payload else {
            throw ProfileCardSnapshotError.malformedPayload
        }
        return data
    }

    public func deserialize(_ data: Data) throws -> ProfileCardSnapshotPayload {
        try rejectUnexpectedKeys(in: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: ProfileCardSnapshotPayload
        do {
            payload = try decoder.decode(ProfileCardSnapshotPayload.self, from: data)
        } catch {
            throw ProfileCardSnapshotError.malformedPayload
        }
        guard payload.schema == Self.schemaIdentifier,
              payload.format == Self.formatIdentifier,
              payload.schemaVersion == 1,
              payload.formatVersion == "1.0.0" else {
            throw ProfileCardSnapshotError.unsupportedSchema
        }
        guard payload.cardVersion > 0,
              !payload.fields.isEmpty,
              payload.fields.count <= limits.maximumFields,
              payload.expiryIsAdvisoryOnly,
              payload.authorshipIsUnverified else {
            throw ProfileCardSnapshotError.malformedPayload
        }
        if let expiry = payload.advisoryExpiresAt, expiry <= payload.publishedAt {
            throw ProfileCardSnapshotError.invalidExpiry
        }
        var identifiers = Set<UUID>()
        var fieldKeys = Set<ShareableProfileFieldKey>()
        for field in payload.fields {
            guard identifiers.insert(field.id).inserted,
                  fieldKeys.insert(field.key).inserted,
                  field.source == "self_asserted" else {
                throw ProfileCardSnapshotError.malformedPayload
            }
            try validate(field.value, for: field.key)
        }
        try validateEmbeddedMedia(payload, requiresPayloadForMediaFields: false)
        return payload
    }

    private func validate(
        _ value: ProfileSnapshotFieldValue,
        for key: ShareableProfileFieldKey
    ) throws {
        switch (key, value) {
        case (.preferredName, .text(let text)),
             (.pronunciation, .text(let text)),
             (.timeZone, .text(let text)),
             (.affiliation, .text(let text)),
             (.cohort, .text(let text)),
             (.currentRole, .text(let text)),
             (.communicationPreference, .text(let text)):
            guard validText(text) else { throw ProfileCardSnapshotError.invalidValue(key) }

        case (.languages, .textList(let values)),
             (.interests, .textList(let values)):
            guard !values.isEmpty,
                  values.count <= limits.maximumListItems,
                  values.allSatisfy(validText) else {
                throw ProfileCardSnapshotError.invalidValue(key)
            }

        case (.contactMethod, .contact(_, let value, let label)):
            guard validText(value), label.map(validText) ?? true else {
                throw ProfileCardSnapshotError.invalidValue(key)
            }

        case (.portrait, .sanitizedMedia(_, let contentType, let sha256, let byteCount, let stripped)):
            guard stripped else { throw ProfileCardSnapshotError.unsanitizedMedia }
            guard ["image/jpeg", "image/png", "image/heic"].contains(contentType.lowercased()),
                  sha256.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
                  byteCount > 0,
                  byteCount <= limits.maximumMediaBytes else {
                throw ProfileCardSnapshotError.invalidValue(key)
            }

        default:
            throw ProfileCardSnapshotError.valueTypeDoesNotMatchField(key)
        }
    }

    private func validText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= limits.maximumTextCharacters
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func validateEmbeddedMedia(
        _ payload: ProfileCardSnapshotPayload,
        requiresPayloadForMediaFields: Bool
    ) throws {
        let mediaFields = payload.fields.compactMap { field -> (UUID, UUID, String, String, Int)? in
            guard case .sanitizedMedia(let mediaID, let contentType, let sha256, let byteCount, _) = field.value else {
                return nil
            }
            return (field.id, mediaID, contentType, sha256.lowercased(), byteCount)
        }
        let embedded = payload.embeddedMedia ?? []
        var seenFieldIDs = Set<UUID>()
        for item in embedded {
            guard seenFieldIDs.insert(item.fieldID).inserted,
                  let field = mediaFields.first(where: { $0.0 == item.fieldID }),
                  item.mediaID == field.1,
                  item.contentType.lowercased() == field.2.lowercased(),
                  item.sha256.lowercased() == field.3,
                  item.data.count == field.4,
                  item.data.count <= limits.maximumMediaBytes,
                  ServiceDigest.sha256Hex(item.data) == field.3 else {
                throw ProfileCardSnapshotError.invalidMediaPayload(item.fieldID)
            }
        }
        if requiresPayloadForMediaFields,
           let missing = mediaFields.first(where: { field in
               !embedded.contains { $0.fieldID == field.0 }
           }) {
            throw ProfileCardSnapshotError.missingMediaPayload(missing.0)
        }
    }

    private func rejectUnexpectedKeys(in data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProfileCardSnapshotError.malformedPayload
        }
        guard let root = object as? [String: Any] else {
            throw ProfileCardSnapshotError.malformedPayload
        }

        let rootKeys: Set<String> = [
            "$schema", "format", "format_version", "schema_version",
            "publication_id", "card_version_id", "card_version", "published_at",
            "advisory_expires_at", "retention_intent", "expiry_is_advisory_only",
            "authorship_is_unverified", "fields", "embedded_media"
        ]
        try requireOnly(keys: Set(root.keys), allowed: rootKeys)
        guard let fields = root["fields"] as? [[String: Any]] else {
            throw ProfileCardSnapshotError.malformedPayload
        }

        let fieldKeys: Set<String> = ["field_id", "key", "value", "audience", "source"]
        for field in fields {
            try requireOnly(keys: Set(field.keys), allowed: fieldKeys)
            guard let value = field["value"] as? [String: Any] else {
                throw ProfileCardSnapshotError.malformedPayload
            }
            guard let type = value["type"] as? String else {
                throw ProfileCardSnapshotError.malformedPayload
            }
            let allowedValueKeys: Set<String> = switch type {
            case "text": ["type", "text"]
            case "text_list": ["type", "items"]
            case "contact": ["type", "channel", "value", "label"]
            case "sanitized_media": [
                "type", "media_id", "content_type", "sha256", "byte_count", "metadata_stripped"
            ]
            default: throw ProfileCardSnapshotError.malformedPayload
            }
            try requireOnly(keys: Set(value.keys), allowed: allowedValueKeys)
        }
        if let embedded = root["embedded_media"] as? [[String: Any]] {
            let allowedMediaKeys: Set<String> = [
                "field_id", "media_id", "content_type", "sha256", "data_base64"
            ]
            for media in embedded {
                try requireOnly(keys: Set(media.keys), allowed: allowedMediaKeys)
            }
        } else if root["embedded_media"] != nil {
            throw ProfileCardSnapshotError.malformedPayload
        }
    }

    private func requireOnly(keys: Set<String>, allowed: Set<String>) throws {
        if let unexpected = keys.subtracting(allowed).sorted().first {
            throw ProfileCardSnapshotError.unexpectedPayloadKey(unexpected)
        }
    }
}

public enum ReceivedProfileSnapshotImportPlanningError: LocalizedError, Equatable, Sendable {
    case noFieldsSelected
    case unknownSelectedField(UUID)
    case sourceIdentifierConflict(UUID)
    case cardVersionIdentifierConflict(UUID)
    case assertionIdentifierConflict(UUID)
    case fieldIdentifierChangedMeaning(UUID)

    public var errorDescription: String? {
        switch self {
        case .noFieldsSelected:
            String(localized: "Select at least one profile field to import.")
        case .unknownSelectedField:
            String(localized: "A selected profile field is no longer present in the reviewed file.")
        case .sourceIdentifierConflict:
            String(localized: "This profile file conflicts with an existing source record. Nothing was imported.")
        case .cardVersionIdentifierConflict:
            String(localized: "This profile version identifier was already used for different contents. Nothing was imported.")
        case .assertionIdentifierConflict:
            String(localized: "An imported profile fact conflicts with an existing record. Nothing was imported.")
        case .fieldIdentifierChangedMeaning:
            String(localized: "A profile field identifier changed meaning between versions. Review the file with its sender.")
        }
    }
}

public enum ReceivedProfileSnapshotImportCommitError: LocalizedError, Equatable, Sendable {
    case subjectMismatch
    case newPersonAlreadyExists
    case newPersonMustBeActive
    case destinationPersonUnavailable
    case pendingNotebookChanges

    public var errorDescription: String? {
        switch self {
        case .subjectMismatch:
            String(localized: "The reviewed profile no longer matches its selected destination. Nothing was imported.")
        case .newPersonAlreadyExists:
            String(localized: "A person already uses this import destination. Review the profile again before importing.")
        case .newPersonMustBeActive:
            String(localized: "A received profile can only create an active person record.")
        case .destinationPersonUnavailable:
            String(localized: "The selected person is no longer active. Nothing was imported.")
        case .pendingNotebookChanges:
            String(localized: "Another notebook change is still being saved. Wait a moment, then try the import again.")
        }
    }
}

/// A reviewed, deterministic set of canonical writes. It retains the exact
/// received bytes so the store can re-plan against its latest state at commit
/// time instead of trusting a stale or independently reconstructed model.
public struct ReceivedProfileSnapshotImportBundle: Hashable, Sendable {
    public let exactPayloadBytes: Data
    public let payload: ProfileCardSnapshotPayload
    public let subjectID: UUID
    public let selectedFieldIDs: Set<UUID>
    public let originalFilename: String?
    public let retentionPolicy: SourceRetentionPolicy
    public let importedAt: Date
    public let sourceToCreate: SourceArtifact?
    public let assertionsToCreate: [AssertionEnvelope]
    public let alreadyImportedFieldIDs: Set<UUID>

    public var hasChanges: Bool {
        sourceToCreate != nil || !assertionsToCreate.isEmpty
    }

    init(
        exactPayloadBytes: Data,
        payload: ProfileCardSnapshotPayload,
        subjectID: UUID,
        selectedFieldIDs: Set<UUID>,
        originalFilename: String?,
        retentionPolicy: SourceRetentionPolicy,
        importedAt: Date,
        sourceToCreate: SourceArtifact?,
        assertionsToCreate: [AssertionEnvelope],
        alreadyImportedFieldIDs: Set<UUID>
    ) {
        self.exactPayloadBytes = exactPayloadBytes
        self.payload = payload
        self.subjectID = subjectID
        self.selectedFieldIDs = selectedFieldIDs
        self.originalFilename = originalFilename
        self.retentionPolicy = retentionPolicy
        self.importedAt = importedAt
        self.sourceToCreate = sourceToCreate
        self.assertionsToCreate = assertionsToCreate
        self.alreadyImportedFieldIDs = alreadyImportedFieldIDs
    }
}

/// Converts only explicitly selected fields from a strictly validated profile
/// snapshot into remote-self assertions for an explicitly supplied person ID.
/// It has no Person input and therefore cannot infer a match or mutate one.
public struct ReceivedProfileSnapshotImportPlanner: Sendable {
    public let serializer: ProfileCardSnapshotSerializer

    public init(serializer: ProfileCardSnapshotSerializer = .init()) {
        self.serializer = serializer
    }

    public func inspect(exactPayloadBytes: Data) throws -> ProfileCardSnapshotPayload {
        try serializer.deserialize(exactPayloadBytes)
    }

    public func plan(
        exactPayloadBytes: Data,
        selectedFieldIDs: Set<UUID>,
        subjectID: UUID,
        existingAssertions: [AssertionEnvelope] = [],
        existingDefinitions _: [AttributeDefinition] = [],
        existingSources: [SourceArtifact] = [],
        originalFilename: String? = nil,
        retentionPolicy: SourceRetentionPolicy = .discardOriginalAfterExtraction,
        importedAt: Date = .now
    ) throws -> ReceivedProfileSnapshotImportBundle {
        let payload = try inspect(exactPayloadBytes: exactPayloadBytes)
        guard !selectedFieldIDs.isEmpty else {
            throw ReceivedProfileSnapshotImportPlanningError.noFieldsSelected
        }

        let fieldsByID = Dictionary(uniqueKeysWithValues: payload.fields.map { ($0.id, $0) })
        if let unknownID = selectedFieldIDs.subtracting(fieldsByID.keys).sorted(by: uuidLessThan).first {
            throw ReceivedProfileSnapshotImportPlanningError.unknownSelectedField(unknownID)
        }

        let exactDigest = ServiceDigest.sha256Hex(exactPayloadBytes)
        let sourceID = ServiceDigest.deterministicUUID(
            seed: "received-profile-source:v1:\(exactDigest)"
        )
        let existingSource = existingSources.first { $0.id == sourceID }
        if let existingSource,
           existingSource.kind != .selfProfileCard || existingSource.sha256 != exactDigest {
            throw ReceivedProfileSnapshotImportPlanningError.sourceIdentifierConflict(sourceID)
        }
        let sourceToCreate = existingSource == nil ? SourceArtifact(
            id: sourceID,
            kind: .selfProfileCard,
            originalFilename: originalFilename,
            sha256: exactDigest,
            importedAt: importedAt,
            retentionPolicy: retentionPolicy,
            parserVersion: payload.formatVersion,
            aiPolicy: .deny,
            createdAt: importedAt,
            modifiedAt: importedAt
        ) : nil

        for assertion in existingAssertions {
            guard let provenance = assertion.remoteSelfProfileProvenance,
                  provenance.cardVersionID == payload.cardVersionID else { continue }
            guard provenance.publicationID == payload.publicationID,
                  provenance.cardVersion == payload.cardVersion,
                  provenance.exactPayloadSHA256 == exactDigest else {
                throw ReceivedProfileSnapshotImportPlanningError.cardVersionIdentifierConflict(
                    payload.cardVersionID
                )
            }
        }

        var assertionsByID: [UUID: AssertionEnvelope] = [:]
        for assertion in existingAssertions {
            if let prior = assertionsByID[assertion.id], prior != assertion {
                throw ReceivedProfileSnapshotImportPlanningError.assertionIdentifierConflict(assertion.id)
            }
            assertionsByID[assertion.id] = assertion
        }

        let usePolicy = AssertionUsePolicy(
            search: .include,
            remindersAllowed: false,
            notifications: .exclude,
            sharing: .exclude,
            mention: .ask,
            ai: .deny
        )
        var assertionsToCreate: [AssertionEnvelope] = []
        var alreadyImportedFieldIDs = Set<UUID>()

        for field in payload.fields where selectedFieldIDs.contains(field.id) {
            for existing in existingAssertions {
                guard let provenance = existing.remoteSelfProfileProvenance,
                      existing.origin == .remoteSelf,
                      existing.subjectID == subjectID,
                      provenance.publicationID == payload.publicationID,
                      provenance.fieldID == field.id else { continue }
                guard provenance.fieldKey == field.key else {
                    throw ReceivedProfileSnapshotImportPlanningError.fieldIdentifierChangedMeaning(field.id)
                }
            }

            let predicateID = Self.predicateID(for: field.key)
            let value = Self.typedValue(for: field.value)
            let assertionID = ServiceDigest.deterministicUUID(
                seed: [
                    "received-profile-assertion:v1",
                    subjectID.uuidString,
                    payload.publicationID.uuidString,
                    payload.cardVersionID.uuidString,
                    field.id.uuidString
                ].joined(separator: ":")
            )
            let supersedesID = existingAssertions
                .filter { existing in
                    guard existing.origin == .remoteSelf,
                          existing.subjectID == subjectID,
                          existing.predicateID == predicateID,
                          let provenance = existing.remoteSelfProfileProvenance else { return false }
                    return provenance.publicationID == payload.publicationID
                        && provenance.fieldID == field.id
                        && provenance.cardVersion < payload.cardVersion
                }
                .max { lhs, rhs in
                    let left = lhs.remoteSelfProfileProvenance?.cardVersion ?? 0
                    let right = rhs.remoteSelfProfileProvenance?.cardVersion ?? 0
                    return left == right ? lhs.assertedAt < rhs.assertedAt : left < right
                }?.id
            let provenance = RemoteSelfProfileProvenance(
                publicationID: payload.publicationID,
                cardVersionID: payload.cardVersionID,
                cardVersion: payload.cardVersion,
                publishedAt: payload.publishedAt,
                fieldID: field.id,
                fieldKey: field.key,
                fieldAudience: field.audience,
                exactPayloadSHA256: exactDigest,
                authorshipIsUnverified: payload.authorshipIsUnverified,
                advisoryExpiresAt: payload.advisoryExpiresAt,
                retentionIntent: payload.retentionIntent
            )
            let assertion = try AssertionEnvelope(
                id: assertionID,
                subjectID: subjectID,
                predicateID: predicateID,
                value: value,
                sourceID: sourceID,
                origin: .remoteSelf,
                reviewStatus: .accepted,
                certainty: .exact,
                observedAt: payload.publishedAt,
                assertedAt: importedAt,
                sensitivity: .private,
                usePolicy: usePolicy,
                supersedesID: supersedesID,
                remoteSelfProfileProvenance: provenance
            )

            if let existing = assertionsByID[assertionID] {
                guard Self.isIdempotentMatch(existing, assertion) else {
                    throw ReceivedProfileSnapshotImportPlanningError.assertionIdentifierConflict(
                        assertionID
                    )
                }
                alreadyImportedFieldIDs.insert(field.id)
            } else {
                assertionsToCreate.append(assertion)
            }
        }

        return ReceivedProfileSnapshotImportBundle(
            exactPayloadBytes: exactPayloadBytes,
            payload: payload,
            subjectID: subjectID,
            selectedFieldIDs: selectedFieldIDs,
            originalFilename: originalFilename,
            retentionPolicy: retentionPolicy,
            importedAt: importedAt,
            sourceToCreate: sourceToCreate,
            assertionsToCreate: assertionsToCreate,
            alreadyImportedFieldIDs: alreadyImportedFieldIDs
        )
    }

    public static func predicateID(for key: ShareableProfileFieldKey) -> String {
        "person.\(key.rawValue)"
    }

    public static func typedValue(for value: ProfileSnapshotFieldValue) -> TypedValue {
        switch value {
        case .text(let text):
            .text(text)
        case .textList(let items):
            .text(items.joined(separator: ", "))
        case .contact(let channel, let value, let label):
            .text([label, channel.rawValue, value].compactMap { $0 }.joined(separator: " · "))
        case .sanitizedMedia(let mediaID, let contentType, let sha256, let byteCount, let stripped):
            .structuredJSON(.object([
                "media_id": .string(mediaID.uuidString.lowercased()),
                "content_type": .string(contentType),
                "sha256": .string(sha256.lowercased()),
                "byte_count": .number(Double(byteCount)),
                "metadata_stripped": .boolean(stripped)
            ]))
        }
    }

    private static func isIdempotentMatch(
        _ existing: AssertionEnvelope,
        _ expected: AssertionEnvelope
    ) -> Bool {
        existing.subjectID == expected.subjectID
            && existing.predicateID == expected.predicateID
            && existing.value == expected.value
            && existing.sourceID == expected.sourceID
            && existing.evidenceIDs == expected.evidenceIDs
            && existing.origin == expected.origin
            && existing.confidence == expected.confidence
            && existing.reviewStatus == expected.reviewStatus
            && existing.certainty == expected.certainty
            && existing.observedAt == expected.observedAt
            && existing.validFrom == expected.validFrom
            && existing.validTo == expected.validTo
            && existing.sensitivity == expected.sensitivity
            && existing.usePolicy == expected.usePolicy
            && existing.supersedesID == expected.supersedesID
            && existing.remoteSelfProfileProvenance == expected.remoteSelfProfileProvenance
    }

    private func uuidLessThan(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
}
