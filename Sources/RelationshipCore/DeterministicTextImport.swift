import CryptoKit
import Foundation

enum ServiceDigest {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func deterministicUUID(seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        // Mark the identifier as a name-derived UUID variant. The exact input
        // remains app-owned and no timestamp or device identifier is encoded.
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public enum TextImportSourceKind: String, Codable, CaseIterable, Sendable {
    case pastedText
    case plainTextFile
    case sharedText
}

public enum ImportedSourceRetentionPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case decideDuringReview
    case keepOriginal
    case evidenceExcerptsOnly
    case discardAfterReview

    public var id: String { rawValue }

    public var localizedTitle: String { localizedTitle(locale: .current) }

    public func localizedTitle(locale: Locale) -> String {
        switch self {
        case .decideDuringReview:
            String(localized: "Ask every time", locale: locale)
        case .keepOriginal:
            String(localized: "Keep extracted source text", locale: locale)
        case .evidenceExcerptsOnly:
            String(localized: "Keep accepted evidence excerpts", locale: locale)
        case .discardAfterReview:
            String(localized: "Discard source text after review", locale: locale)
        }
    }
}

public struct TextImportSourceArtifact: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: TextImportSourceKind
    public var originalFilename: String?
    public var contentSHA256: String
    public var importedAt: Date
    public var text: String
    public var retentionPolicy: ImportedSourceRetentionPolicy

    public init(
        id: UUID? = nil,
        kind: TextImportSourceKind,
        originalFilename: String? = nil,
        importedAt: Date = .now,
        text: String,
        retentionPolicy: ImportedSourceRetentionPolicy = .decideDuringReview
    ) {
        let digest = ServiceDigest.sha256Hex(Data(text.utf8))
        self.id = id ?? ServiceDigest.deterministicUUID(seed: "text-source:\(digest)")
        self.kind = kind
        self.originalFilename = originalFilename
        self.contentSHA256 = digest
        self.importedAt = importedAt
        self.text = text
        self.retentionPolicy = retentionPolicy
    }
}

public enum EvidenceOffsetEncoding: String, Codable, Sendable {
    case utf16
}

public struct TextEvidenceSpan: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var lineNumber: Int
    public var location: Int
    public var length: Int
    public var offsetEncoding: EvidenceOffsetEncoding
    public var excerpt: String
    /// Exact source unit containing this span. Older reviews omit this and are
    /// resolved from the legacy global UTF-16 range.
    public var unitID: UUID?
    public var unitIndex: Int?
    /// Vision-normalized coordinates (origin at the lower-left) when OCR can
    /// identify the supporting image region.
    public var normalizedBoundingBox: TextImportNormalizedRect?
    public var ocrConfidence: Double?

    public init(
        id: UUID,
        sourceID: UUID,
        lineNumber: Int,
        location: Int,
        length: Int,
        offsetEncoding: EvidenceOffsetEncoding = .utf16,
        excerpt: String,
        unitID: UUID? = nil,
        unitIndex: Int? = nil,
        normalizedBoundingBox: TextImportNormalizedRect? = nil,
        ocrConfidence: Double? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.lineNumber = lineNumber
        self.location = location
        self.length = length
        self.offsetEncoding = offsetEncoding
        self.excerpt = excerpt
        self.unitID = unitID
        self.unitIndex = unitIndex
        self.normalizedBoundingBox = normalizedBoundingBox
        self.ocrConfidence = ocrConfidence
    }
}

public struct TextImportNormalizedRect: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.width = min(max(width, 0), 1 - self.x)
        self.height = min(max(height, 0), 1 - self.y)
    }
}

public enum TextCandidatePredicate: String, Codable, CaseIterable, Sendable {
    case alias
    case pronunciation
    case context
    case role
    case tag
    case email
    case phone
    case mentionableContext
}

public enum CandidateEvidenceRelationship: String, Codable, Sendable {
    case explicit
    case inferred
}

public struct TextImportCandidateAssertion: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var predicate: TextCandidatePredicate
    public var value: String
    public var confidence: Double
    public var evidenceRelationship: CandidateEvidenceRelationship
    public var evidenceIDs: [UUID]
    public var isPreselectedForReview: Bool

    public init(
        id: UUID,
        predicate: TextCandidatePredicate,
        value: String,
        confidence: Double,
        evidenceRelationship: CandidateEvidenceRelationship = .explicit,
        evidenceIDs: [UUID],
        isPreselectedForReview: Bool
    ) {
        self.id = id
        self.predicate = predicate
        self.value = value
        self.confidence = min(max(confidence, 0), 1)
        self.evidenceRelationship = evidenceRelationship
        self.evidenceIDs = evidenceIDs
        self.isPreselectedForReview = isPreselectedForReview
    }
}

public enum ImportCandidateReviewState: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
    case deferred
}

public struct TextImportCandidate: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var proposedDisplayName: String
    public var confidence: Double
    public var evidenceIDs: [UUID]
    public var assertions: [TextImportCandidateAssertion]
    public var possibleDuplicateCandidateIDs: [UUID]
    public var reviewState: ImportCandidateReviewState
    public var isPreselectedForReview: Bool

    public init(
        id: UUID,
        sourceID: UUID,
        proposedDisplayName: String,
        confidence: Double,
        evidenceIDs: [UUID],
        assertions: [TextImportCandidateAssertion],
        possibleDuplicateCandidateIDs: [UUID] = [],
        reviewState: ImportCandidateReviewState = .pending,
        isPreselectedForReview: Bool
    ) {
        self.id = id
        self.sourceID = sourceID
        self.proposedDisplayName = proposedDisplayName
        self.confidence = min(max(confidence, 0), 1)
        self.evidenceIDs = evidenceIDs
        self.assertions = assertions
        self.possibleDuplicateCandidateIDs = possibleDuplicateCandidateIDs
        self.reviewState = reviewState
        self.isPreselectedForReview = isPreselectedForReview
    }
}

public enum TextImportSafetyCategory: String, Codable, Sendable {
    case instructionLikeSourceText
    case externalActionRequest
    case credentialLikeContent
    case unsupportedField
    case invalidFieldValue
    case possibleDuplicate
}

public struct TextImportSafetyFinding: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var category: TextImportSafetyCategory
    public var evidenceID: UUID
    public var message: String
    public var blockedFromCandidateOutput: Bool

    public init(
        id: UUID,
        category: TextImportSafetyCategory,
        evidenceID: UUID,
        message: String,
        blockedFromCandidateOutput: Bool
    ) {
        self.id = id
        self.category = category
        self.evidenceID = evidenceID
        self.message = message
        self.blockedFromCandidateOutput = blockedFromCandidateOutput
    }
}

public struct TextImportReview: Hashable, Codable, Sendable, Identifiable {
    public var source: TextImportSourceArtifact
    public var evidence: [TextEvidenceSpan]
    public var candidates: [TextImportCandidate]
    public var safetyFindings: [TextImportSafetyFinding]
    public var parserVersion: String
    /// Workflow state was introduced after the first archive schema. A nil
    /// value denotes a legacy completed review, never a resumable draft.
    public var workflow: TextImportWorkflowState?

    public init(
        source: TextImportSourceArtifact,
        evidence: [TextEvidenceSpan],
        candidates: [TextImportCandidate],
        safetyFindings: [TextImportSafetyFinding],
        parserVersion: String,
        workflow: TextImportWorkflowState? = nil
    ) {
        self.source = source
        self.evidence = evidence
        self.candidates = candidates
        self.safetyFindings = safetyFindings
        self.parserVersion = parserVersion
        self.workflow = workflow
    }

    /// This pure pipeline has no repository capability. Its output can only be
    /// reviewed by another layer; it can never commit facts by itself.
    public var hasCommittedChanges: Bool { false }
    public var requiresUserReview: Bool { true }
    public var isResumable: Bool { workflow?.lifecycle == .pending }
    public var id: UUID { source.id }
}

public enum TextImportReviewLifecycle: String, Codable, CaseIterable, Sendable {
    case pending
    case committed
    case cancelled
}

public enum TextImportReviewedDisposition: String, Codable, CaseIterable, Sendable {
    case createNew
    case addToExisting
    case deferred
    case skip
}

public struct TextImportCandidateDecisionSnapshot: Hashable, Codable, Sendable, Identifiable {
    public var candidateID: UUID
    public var displayName: String
    public var disposition: TextImportReviewedDisposition
    public var targetPersonID: UUID?
    public var selectedAssertionIDs: Set<UUID>

    public var id: UUID { candidateID }

    public init(
        candidateID: UUID,
        displayName: String,
        disposition: TextImportReviewedDisposition,
        targetPersonID: UUID?,
        selectedAssertionIDs: Set<UUID>
    ) {
        self.candidateID = candidateID
        self.displayName = displayName
        self.disposition = disposition
        self.targetPersonID = targetPersonID
        self.selectedAssertionIDs = selectedAssertionIDs
    }
}

public struct TextImportSourceUnitSnapshot: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var index: Int
    public var text: String
    public var usedOCR: Bool
    public var ocrConfidence: Double?
    public var regions: [TextImportSourceRegion]

    public init(
        id: UUID,
        index: Int,
        text: String,
        usedOCR: Bool,
        ocrConfidence: Double? = nil,
        regions: [TextImportSourceRegion] = []
    ) {
        self.id = id
        self.index = index
        self.text = text
        self.usedOCR = usedOCR
        self.ocrConfidence = ocrConfidence
        self.regions = regions
    }
}

public struct TextImportSourceRegion: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var startUTF16Offset: Int
    public var endUTF16Offset: Int
    public var normalizedBoundingBox: TextImportNormalizedRect
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        text: String,
        startUTF16Offset: Int,
        endUTF16Offset: Int,
        normalizedBoundingBox: TextImportNormalizedRect,
        confidence: Double
    ) {
        self.id = id
        self.text = text
        self.startUTF16Offset = max(0, startUTF16Offset)
        self.endUTF16Offset = max(self.startUTF16Offset, endUTF16Offset)
        self.normalizedBoundingBox = normalizedBoundingBox
        self.confidence = min(max(confidence, 0), 1)
    }
}

/// The exact original bytes are deliberately nested under an explicit
/// retention record, so inventories and exports can distinguish them from
/// extracted text and evidence excerpts.
public struct RetainedTextImportSource: Hashable, Codable, Sendable {
    public var contentType: String
    public var filename: String?
    public var sha256: String
    public var data: Data

    public init(contentType: String, filename: String?, sha256: String, data: Data) {
        self.contentType = contentType
        self.filename = filename
        self.sha256 = sha256
        self.data = data
    }
}

public struct TextImportConversationProposal: Hashable, Codable, Sendable {
    public var shouldCreateInteraction: Bool
    public var occurredAt: Date
    public var transcriptRetention: TranscriptRetention

    public init(
        shouldCreateInteraction: Bool = false,
        occurredAt: Date = .now,
        transcriptRetention: TranscriptRetention = .metadataOnly
    ) {
        self.shouldCreateInteraction = shouldCreateInteraction
        self.occurredAt = occurredAt
        self.transcriptRetention = transcriptRetention
    }
}

public struct TextImportPortraitProposal: Hashable, Codable, Sendable {
    public var shouldProposeFirstImageAsPortrait: Bool
    public var confirmedPersonID: UUID?
    public var confirmedAt: Date?

    public init(
        shouldProposeFirstImageAsPortrait: Bool = false,
        confirmedPersonID: UUID? = nil,
        confirmedAt: Date? = nil
    ) {
        self.shouldProposeFirstImageAsPortrait = shouldProposeFirstImageAsPortrait
        self.confirmedPersonID = confirmedPersonID
        self.confirmedAt = confirmedAt
    }
}

/// Audit-safe provenance for an optional model proposal returned through the
/// user-configured Shortcut. The model output itself remains the review's
/// source text, so the selected retention policy governs whether it survives.
public struct TextImportAIProposal: Hashable, Codable, Sendable {
    public var originSourceSHA256: String
    public var modelOutputSHA256: String
    public var returnedAt: Date
    public var providerDisclosure: String

    public init(
        originSourceSHA256: String,
        modelOutputSHA256: String,
        returnedAt: Date = .now,
        providerDisclosure: String
    ) {
        self.originSourceSHA256 = originSourceSHA256
        self.modelOutputSHA256 = modelOutputSHA256
        self.returnedAt = returnedAt
        self.providerDisclosure = providerDisclosure
    }
}

public struct TextImportWorkflowState: Hashable, Codable, Sendable {
    public var lifecycle: TextImportReviewLifecycle
    public var savedAt: Date
    public var completedAt: Date?
    public var sourceArtifactKind: SourceArtifactKind
    public var sourceRetention: ImportedSourceRetentionPolicy
    public var candidateDecisions: [TextImportCandidateDecisionSnapshot]
    public var sourceUnits: [TextImportSourceUnitSnapshot]
    public var retainedSource: RetainedTextImportSource?
    public var conversation: TextImportConversationProposal?
    public var portrait: TextImportPortraitProposal?
    public var aiProposal: TextImportAIProposal?

    public init(
        lifecycle: TextImportReviewLifecycle,
        savedAt: Date = .now,
        completedAt: Date? = nil,
        sourceArtifactKind: SourceArtifactKind,
        sourceRetention: ImportedSourceRetentionPolicy,
        candidateDecisions: [TextImportCandidateDecisionSnapshot],
        sourceUnits: [TextImportSourceUnitSnapshot] = [],
        retainedSource: RetainedTextImportSource? = nil,
        conversation: TextImportConversationProposal? = nil,
        portrait: TextImportPortraitProposal? = nil,
        aiProposal: TextImportAIProposal? = nil
    ) {
        self.lifecycle = lifecycle
        self.savedAt = savedAt
        self.completedAt = completedAt
        self.sourceArtifactKind = sourceArtifactKind
        self.sourceRetention = sourceRetention
        self.candidateDecisions = candidateDecisions
        self.sourceUnits = sourceUnits
        self.retainedSource = retainedSource
        self.conversation = conversation
        self.portrait = portrait
        self.aiProposal = aiProposal
    }
}

public struct DeterministicTextImportLimits: Hashable, Codable, Sendable {
    public var maximumUTF8Bytes: Int
    public var maximumLines: Int
    public var maximumCandidates: Int
    public var maximumFieldCharacters: Int

    public init(
        maximumUTF8Bytes: Int = 1_000_000,
        maximumLines: Int = 10_000,
        maximumCandidates: Int = 5_000,
        maximumFieldCharacters: Int = 2_000
    ) {
        self.maximumUTF8Bytes = maximumUTF8Bytes
        self.maximumLines = maximumLines
        self.maximumCandidates = maximumCandidates
        self.maximumFieldCharacters = maximumFieldCharacters
    }
}

public enum DeterministicTextImportError: LocalizedError, Equatable, Sendable {
    case sourceTooLarge
    case tooManyLines
    case tooManyCandidates
    case invalidLimits

    public var errorDescription: String? {
        switch self {
        case .sourceTooLarge: String(localized: "The text is larger than the reviewed import limit.")
        case .tooManyLines: String(localized: "The text contains more lines than this import can safely review.")
        case .tooManyCandidates: String(localized: "The text produced more candidates than this import can safely review.")
        case .invalidLimits: String(localized: "The configured import limits are invalid.")
        }
    }
}

/// A bounded, deterministic fallback for pasted and plain text. It recognizes
/// one person per line plus an explicit allowlist of `label: value` fields.
/// Source material is never interpreted as executable instruction text.
public struct DeterministicTextImportPipeline: Sendable {
    public static let parserVersion = "deterministic-text-v1"

    public var limits: DeterministicTextImportLimits

    public init(limits: DeterministicTextImportLimits = .init()) {
        self.limits = limits
    }

    public func extract(from source: TextImportSourceArtifact) throws -> TextImportReview {
        guard limits.maximumUTF8Bytes > 0,
              limits.maximumLines > 0,
              limits.maximumCandidates > 0,
              limits.maximumFieldCharacters > 0 else {
            throw DeterministicTextImportError.invalidLimits
        }
        guard source.text.utf8.count <= limits.maximumUTF8Bytes else {
            throw DeterministicTextImportError.sourceTooLarge
        }

        let lines = sourceLines(source.text)
        guard lines.count <= limits.maximumLines else {
            throw DeterministicTextImportError.tooManyLines
        }

        var evidence: [TextEvidenceSpan] = []
        var candidates: [TextImportCandidate] = []
        var findings: [TextImportSafetyFinding] = []

        for line in lines where !line.text.isEmpty {
            let evidenceID = ServiceDigest.deterministicUUID(
                seed: "\(source.contentSHA256):evidence:\(line.location):\(line.length)"
            )
            let span = TextEvidenceSpan(
                id: evidenceID,
                sourceID: source.id,
                lineNumber: line.number,
                location: line.location,
                length: line.length,
                excerpt: line.text
            )
            evidence.append(span)

            let safety = classifySafety(line.text)
            for category in safety {
                findings.append(finding(
                    category: category,
                    evidenceID: evidenceID,
                    sourceDigest: source.contentSHA256,
                    blocked: true
                ))
            }

            // If a line itself asks the importer to change behavior, perform an
            // external action, or exposes a credential, retain it only as source
            // evidence. It has no authority and produces no candidate values.
            if safety.contains(.instructionLikeSourceText)
                || safety.contains(.externalActionRequest)
                || safety.contains(.credentialLikeContent) {
                continue
            }

            guard var parsed = parseCandidate(
                line.text,
                source: source,
                evidenceID: evidenceID,
                location: line.location,
                findings: &findings
            ) else { continue }

            if parsed.proposedDisplayName.count > limits.maximumFieldCharacters {
                findings.append(finding(
                    category: .invalidFieldValue,
                    evidenceID: evidenceID,
                    sourceDigest: source.contentSHA256,
                    blocked: true
                ))
                continue
            }
            parsed.assertions.removeAll { $0.value.count > limits.maximumFieldCharacters }
            candidates.append(parsed)
            if candidates.count > limits.maximumCandidates {
                throw DeterministicTextImportError.tooManyCandidates
            }
        }

        linkPossibleDuplicates(
            candidates: &candidates,
            findings: &findings,
            evidence: evidence,
            sourceDigest: source.contentSHA256
        )

        return TextImportReview(
            source: source,
            evidence: evidence,
            candidates: candidates,
            safetyFindings: findings,
            parserVersion: Self.parserVersion
        )
    }

    private struct SourceLine {
        var number: Int
        var location: Int
        var length: Int
        var text: String
    }

    private func sourceLines(_ text: String) -> [SourceLine] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        var output: [SourceLine] = []
        var cursor = 0
        var lineNumber = 1

        while cursor < source.length {
            let fullRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            let raw = source.substring(with: fullRange) as NSString
            let nonWhitespace = raw.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
            if nonWhitespace.location != NSNotFound {
                var end = raw.length
                while end > nonWhitespace.location {
                    let character = raw.character(at: end - 1)
                    guard let scalar = UnicodeScalar(character),
                          CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
                    end -= 1
                }
                let trimmedRange = NSRange(
                    location: nonWhitespace.location,
                    length: end - nonWhitespace.location
                )
                output.append(SourceLine(
                    number: lineNumber,
                    location: fullRange.location + trimmedRange.location,
                    length: trimmedRange.length,
                    text: raw.substring(with: trimmedRange)
                ))
            } else {
                output.append(SourceLine(
                    number: lineNumber,
                    location: fullRange.location,
                    length: 0,
                    text: ""
                ))
            }
            cursor = NSMaxRange(fullRange)
            lineNumber += 1
        }
        return output
    }

    private func classifySafety(_ text: String) -> Set<TextImportSafetyCategory> {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        var categories = Set<TextImportSafetyCategory>()

        let instructionMarkers = [
            "ignore previous", "ignore all instructions", "ignore all rules", "system prompt",
            "developer message", "bypass review", "override the rules",
            "jailbreak", "<script", "execute this", "run this command"
        ]
        if instructionMarkers.contains(where: folded.contains) {
            categories.insert(.instructionLikeSourceText)
        }

        let actionMarkers = [
            "send this data", "share this notebook", "upload this",
            "delete the notebook", "automatically send", "open this url"
        ]
        if actionMarkers.contains(where: folded.contains) {
            categories.insert(.externalActionRequest)
        }

        let credentialMarkers = [
            "password:", "api key:", "private key:", "seed phrase:",
            "recovery phrase:"
        ]
        if credentialMarkers.contains(where: folded.contains) {
            categories.insert(.credentialLikeContent)
        }
        return categories
    }

    private func parseCandidate(
        _ originalLine: String,
        source: TextImportSourceArtifact,
        evidenceID: UUID,
        location: Int,
        findings: inout [TextImportSafetyFinding]
    ) -> TextImportCandidate? {
        let line = stripListPrefix(originalLine)
        guard !line.isEmpty else { return nil }
        let segments = line
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "|" || $0 == "\t" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        var displayName: String?
        var nameWasExplicitlyLabeled = false
        var assertionValues: [(TextCandidatePredicate, String)] = []

        for (index, segment) in segments.enumerated() where !segment.isEmpty {
            if let labeled = labeledValue(segment) {
                if isNameLabel(labeled.label) {
                    displayName = labeled.value
                    nameWasExplicitlyLabeled = true
                } else if let predicate = predicate(for: labeled.label) {
                    let values = predicate == .tag
                        ? labeled.value.split(separator: ",").map(String.init)
                        : [labeled.value]
                    for value in values {
                        let clean = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        if validate(clean, for: predicate) {
                            assertionValues.append((predicate, clean))
                        } else {
                            findings.append(finding(
                                category: .invalidFieldValue,
                                evidenceID: evidenceID,
                                sourceDigest: source.contentSHA256,
                                blocked: true
                            ))
                        }
                    }
                } else {
                    findings.append(finding(
                        category: .unsupportedField,
                        evidenceID: evidenceID,
                        sourceDigest: source.contentSHA256,
                        blocked: true
                    ))
                }
            } else if index == 0 {
                let extracted = extractNameAndEmail(segment)
                displayName = extracted.name
                if let email = extracted.email, validate(email, for: .email) {
                    assertionValues.append((.email, email))
                }
            } else {
                findings.append(finding(
                    category: .unsupportedField,
                    evidenceID: evidenceID,
                    sourceDigest: source.contentSHA256,
                    blocked: true
                ))
            }
        }

        guard let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              isPlausibleName(displayName) else { return nil }

        let confidence = nameWasExplicitlyLabeled ? 1.0 : 0.78
        let candidateID = ServiceDigest.deterministicUUID(
            seed: "\(source.contentSHA256):candidate:\(location):\(displayName)"
        )
        let assertions = assertionValues.enumerated().map { index, item in
            TextImportCandidateAssertion(
                id: ServiceDigest.deterministicUUID(
                    seed: "\(candidateID.uuidString):assertion:\(index):\(item.0.rawValue):\(item.1)"
                ),
                predicate: item.0,
                value: item.1,
                confidence: 1,
                evidenceIDs: [evidenceID],
                isPreselectedForReview: true
            )
        }
        return TextImportCandidate(
            id: candidateID,
            sourceID: source.id,
            proposedDisplayName: displayName,
            confidence: confidence,
            evidenceIDs: [evidenceID],
            assertions: assertions,
            isPreselectedForReview: nameWasExplicitlyLabeled
        )
    }

    private func stripListPrefix(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = result.first, ["-", "*", "•"].contains(first) {
            result.removeFirst()
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = result.range(
            of: #"^\d{1,4}[.)]\s+"#,
            options: .regularExpression
        ) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func labeledValue(_ segment: String) -> (label: String, value: String)? {
        guard let separator = segment.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return nil
        }
        let label = String(segment[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(segment[segment.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !value.isEmpty else { return nil }
        return (normalizedLabel(label), value)
    }

    private func normalizedLabel(_ label: String) -> String {
        label.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased().replacingOccurrences(of: "_", with: " ")
    }

    private func isNameLabel(_ label: String) -> Bool {
        ["name", "display name", "preferred name", "氏名", "名前"].contains(label)
    }

    private func predicate(for label: String) -> TextCandidatePredicate? {
        switch label {
        case "alias", "aliases", "別名": .alias
        case "pronunciation", "reading", "よみ", "読み", "ふりがな": .pronunciation
        case "context", "organization", "community", "所属": .context
        case "role", "position", "役割", "役職": .role
        case "tag", "tags", "タグ": .tag
        case "email", "e-mail", "メール": .email
        case "phone", "telephone", "tel", "電話": .phone
        case "mentionable context", "safe context", "話題": .mentionableContext
        default: nil
        }
    }

    private func validate(_ value: String, for predicate: TextCandidatePredicate) -> Bool {
        guard !value.isEmpty,
              value.count <= limits.maximumFieldCharacters,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        switch predicate {
        case .email:
            return value.range(
                of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        case .phone:
            let allowed = CharacterSet(charactersIn: "+0123456789 ()-. ")
            let digits = value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            return digits.count >= 5 && value.unicodeScalars.allSatisfy(allowed.contains)
        case .alias, .pronunciation, .context, .role, .tag, .mentionableContext:
            return true
        }
    }

    private func extractNameAndEmail(_ segment: String) -> (name: String, email: String?) {
        guard let match = segment.range(
            of: #"<([^\s<>@]+@[^\s<>@]+\.[^\s<>@]+)>\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return (segment, nil) }
        let bracketed = String(segment[match])
        let email = String(bracketed.dropFirst().dropLast())
        let name = String(segment[..<match.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, email)
    }

    private func isPlausibleName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200, value.count >= 1 else { return false }
        if value.contains("http://") || value.contains("https://") { return false }
        if value.range(of: #"[.!?。！？]{2,}"#, options: .regularExpression) != nil { return false }
        return value.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private func finding(
        category: TextImportSafetyCategory,
        evidenceID: UUID,
        sourceDigest: String,
        blocked: Bool
    ) -> TextImportSafetyFinding {
        let message: String = switch category {
        case .instructionLikeSourceText:
            String(localized: "Instruction-like text was retained only as untrusted source evidence.")
        case .externalActionRequest:
            String(localized: "An external-action request in the source has no authority and was not acted on.")
        case .credentialLikeContent:
            String(localized: "Credential-like content was blocked from candidate output.")
        case .unsupportedField:
            String(localized: "An unrecognized field was preserved in source evidence but not reinterpreted.")
        case .invalidFieldValue:
            String(localized: "A field value failed deterministic validation and requires manual review.")
        case .possibleDuplicate:
            String(localized: "Candidates with the same normalized name remain separate pending review.")
        }
        return TextImportSafetyFinding(
            id: ServiceDigest.deterministicUUID(
                seed: "\(sourceDigest):finding:\(category.rawValue):\(evidenceID.uuidString)"
            ),
            category: category,
            evidenceID: evidenceID,
            message: message,
            blockedFromCandidateOutput: blocked
        )
    }

    private func linkPossibleDuplicates(
        candidates: inout [TextImportCandidate],
        findings: inout [TextImportSafetyFinding],
        evidence: [TextEvidenceSpan],
        sourceDigest: String
    ) {
        let grouped = Dictionary(grouping: candidates.indices) { index in
            candidates[index].proposedDisplayName.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).filter { !$0.isWhitespace && !$0.isPunctuation }
        }

        for indexes in grouped.values where indexes.count > 1 {
            for index in indexes {
                candidates[index].possibleDuplicateCandidateIDs = indexes
                    .filter { $0 != index }
                    .map { candidates[$0].id }
                if let evidenceID = candidates[index].evidenceIDs.first {
                    findings.append(finding(
                        category: .possibleDuplicate,
                        evidenceID: evidenceID,
                        sourceDigest: sourceDigest,
                        blocked: false
                    ))
                }
            }
        }
    }
}
