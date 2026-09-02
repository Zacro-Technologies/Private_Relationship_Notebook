import Foundation
import Testing
@testable import RelationshipCore

private func recommendationPolicy(
    ai: AIPolicy,
    mention: MentionPolicy = .never
) -> AssertionUsePolicy {
    AssertionUsePolicy(
        search: .include,
        remindersAllowed: false,
        notifications: .exclude,
        sharing: .exclude,
        mention: mention,
        ai: ai
    )
}

private func recommendationAssertion(
    id: UUID = UUID(),
    subjectID: UUID,
    predicateID: String,
    value: TypedValue,
    sourceID: UUID? = nil,
    reviewStatus: AssertionReviewStatus = .accepted,
    sensitivity: Sensitivity = .private,
    ai: AIPolicy = .allowOnDevice,
    mention: MentionPolicy = .never,
    observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    assertedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    validFrom: PartialDate? = nil,
    validTo: PartialDate? = nil,
    supersedesID: UUID? = nil
) throws -> AssertionEnvelope {
    try AssertionEnvelope(
        id: id,
        subjectID: subjectID,
        predicateID: predicateID,
        value: value,
        sourceID: sourceID,
        origin: sourceID == nil ? .manual : .imported,
        reviewStatus: reviewStatus,
        observedAt: observedAt,
        assertedAt: assertedAt,
        validFrom: validFrom,
        validTo: validTo,
        sensitivity: sensitivity,
        usePolicy: recommendationPolicy(ai: ai, mention: mention),
        supersedesID: supersedesID
    )
}

@Test func recommendationMemoryCategoryIdentifiersAreStableAndUnique() {
    #expect(RecommendationMemoryCategory.conversationTopics.predicateID == "keepsake.memory.conversation_topic")
    #expect(RecommendationMemoryCategory.currentPriorities.predicateID == "keepsake.memory.current_priority")
    #expect(RecommendationMemoryCategory.connectionPreferences.predicateID == "keepsake.memory.connection_preference")
    #expect(RecommendationMemoryCategory.boundaries.predicateID == "keepsake.memory.boundary")
    #expect(RecommendationMemoryCategory.supportIdeas.predicateID == "keepsake.memory.support_idea")
    #expect(Set(RecommendationMemoryCategory.allCases.map(\.predicateID)).count == 5)
    #expect(RecommendationMemoryCategory.conversationTopics.labels.resolved(preferredLanguageTags: ["ja-JP"]) == "会話の話題")
}

@Test func recommendationMemoryProjectionUsesOnlyAcceptedCurrentTerminalPolicyEligibleFacts() throws {
    let person = Person(
        displayName: "Ari",
        privateNote: "PRIVATE NOTE MUST NEVER ENTER A PACKET",
        mentionableContext: "Legacy safe context stays outside this projection",
        contacts: [.init(kind: .email, value: "secret-contact@example.com")]
    )
    let otherPerson = Person(displayName: "Other")
    let old = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.conversationTopics.predicateID,
        value: .text("old topic must stay superseded")
    )
    let current = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.conversationTopics.predicateID,
        value: .text("ceramics"),
        ai: .allowPrivateCloudCompute,
        mention: .allow,
        assertedAt: old.assertedAt.addingTimeInterval(60),
        supersedesID: old.id
    )
    let pending = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.currentPriorities.predicateID,
        value: .text("pending fact"),
        reviewStatus: .pending
    )
    let denied = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.boundaries.predicateID,
        value: .text("AI denied"),
        ai: .deny,
        // A malformed cross-predicate supersession must not hide `current`.
        supersedesID: current.id
    )
    let highlySensitive = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.supportIdeas.predicateID,
        value: .text("highly sensitive"),
        sensitivity: .highlySensitive,
        ai: .allowPrivateCloudCompute
    )
    let expired = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.connectionPreferences.predicateID,
        value: .text("expired preference"),
        validTo: try .year(2020)
    )
    let future = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.connectionPreferences.predicateID,
        value: .text("future preference"),
        validFrom: try .year(2035)
    )
    let unrelated = try recommendationAssertion(
        subjectID: otherPerson.id,
        predicateID: RecommendationMemoryCategory.currentPriorities.predicateID,
        value: .text("other person's fact")
    )
    let emailFact = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.currentPriorities.predicateID,
        value: .email("another-secret@example.com")
    )

    let projection = RecommendationMemoryProjector().project(
        person: person,
        assertions: [pending, old, denied, highlySensitive, expired, future, unrelated, emailFact, current],
        attributeDefinitions: [],
        referenceDate: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(projection.facts.map(\.assertionID) == [current.id])
    #expect(projection.sourcePolicy == .cloudEligible)
    #expect(projection.mentionableFacts.map(\.value) == ["ceramics"])
    let prompt = projection.promptPacket(for: .personalizedRecommendation).prompt
    #expect(!prompt.contains(current.id.uuidString.lowercased()))
    #expect(!prompt.contains(person.id.uuidString.lowercased()))
    #expect(prompt.contains("Conversation topics: ceramics"))
    #expect(!prompt.contains(person.privateNote))
    #expect(!prompt.contains(person.contacts[0].value))
    #expect(!prompt.contains(person.mentionableContext))
    #expect(!prompt.contains("another-secret@example.com"))
    #expect(!prompt.contains("old topic"))
}

@Test func recommendationMemoryLinkedSourcePolicyIsCombinedConservatively() throws {
    let person = Person(displayName: "Source policy")
    let localSource = SourceArtifact(kind: .userNote, aiPolicy: .allowOnDevice)
    let deniedSource = SourceArtifact(kind: .pastedText, aiPolicy: .deny)
    let pccSource = SourceArtifact(kind: .pastedText, aiPolicy: .allowPrivateCloudCompute)
    let localBySource = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.currentPriorities.predicateID,
        value: .text("local source"),
        sourceID: localSource.id,
        ai: .allowPrivateCloudCompute
    )
    let deniedBySource = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.boundaries.predicateID,
        value: .text("denied source"),
        sourceID: deniedSource.id,
        ai: .allowPrivateCloudCompute
    )
    let pcc = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.supportIdeas.predicateID,
        value: .text("cloud source"),
        sourceID: pccSource.id,
        ai: .allowPrivateCloudCompute
    )
    let dangling = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.connectionPreferences.predicateID,
        value: .text("missing source"),
        sourceID: UUID(),
        ai: .allowPrivateCloudCompute
    )

    let projection = RecommendationMemoryProjector().project(
        person: person,
        assertions: [pcc, deniedBySource, dangling, localBySource],
        attributeDefinitions: [],
        sources: [pccSource, localSource, deniedSource]
    )

    #expect(Set(projection.facts.map(\.value)) == Set(["local source", "cloud source"]))
    #expect(projection.facts.first(where: { $0.assertionID == localBySource.id })?.effectiveAIPolicy == .allowOnDevice)
    #expect(projection.sourcePolicy == .onDeviceOnly)
}

@Test func recommendationMemoryCustomFactsRequireActiveAIEnabledDefinitionsAndConversationCapability() throws {
    let person = Person(displayName: "Custom facts")
    let conversational = AttributeDefinition(
        predicateID: "custom.favorite_activity",
        labels: LocalizedText("Favorite activity", localized: ["ja": "好きな活動"]),
        valueKind: .text,
        capabilities: AttributeCapabilities(
            supportsAI: true,
            supportsConversationMentions: true
        )
    )
    let internalOnly = AttributeDefinition(
        predicateID: "custom.preferred_pace",
        labels: LocalizedText("Preferred pace"),
        valueKind: .text,
        capabilities: AttributeCapabilities(
            supportsAI: true,
            supportsConversationMentions: false
        )
    )
    let disabled = AttributeDefinition(
        predicateID: "custom.disabled",
        labels: LocalizedText("Disabled"),
        valueKind: .text,
        capabilities: AttributeCapabilities(supportsAI: false)
    )
    let archived = AttributeDefinition(
        predicateID: "custom.archived",
        labels: LocalizedText("Archived"),
        valueKind: .text,
        capabilities: AttributeCapabilities(supportsAI: true),
        archivedAt: .now
    )
    let mentionableFact = try recommendationAssertion(
        subjectID: person.id,
        predicateID: conversational.predicateID,
        value: .text("walking"),
        ai: .allowConfiguredShortcut,
        mention: .allow
    )
    let forcedInternalFact = try recommendationAssertion(
        subjectID: person.id,
        predicateID: internalOnly.predicateID,
        value: .text("leave more time"),
        ai: .allowOnDevice,
        mention: .allow
    )
    let disabledFact = try recommendationAssertion(
        subjectID: person.id,
        predicateID: disabled.predicateID,
        value: .text("disabled value")
    )
    let archivedFact = try recommendationAssertion(
        subjectID: person.id,
        predicateID: archived.predicateID,
        value: .text("archived value")
    )

    let projection = RecommendationMemoryProjector().project(
        person: person,
        assertions: [archivedFact, disabledFact, forcedInternalFact, mentionableFact],
        attributeDefinitions: [archived, disabled, internalOnly, conversational],
        preferredLanguageTags: ["ja-JP"]
    )

    #expect(projection.facts.count == 2)
    #expect(projection.facts.first(where: { $0.assertionID == mentionableFact.id })?.label == "好きな活動")
    #expect(projection.facts.first(where: { $0.assertionID == mentionableFact.id })?.mentionScope == .mentionable)
    #expect(projection.facts.first(where: { $0.assertionID == forcedInternalFact.id })?.mentionScope == .internalGuidance)
    #expect(!projection.facts.contains(where: { $0.assertionID == archivedFact.id }))
    #expect(!projection.facts.contains(where: { $0.assertionID == disabledFact.id }))
}

@Test func recommendationMemoryPromptSeparatesMentionableFactsFromInternalGuidanceAndRecomputesPolicy() throws {
    let person = Person(displayName: "Prompt person")
    let mentionable = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.conversationTopics.predicateID,
        value: .text("their garden"),
        ai: .allowConfiguredShortcut,
        mention: .allow
    )
    let askFirst = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.connectionPreferences.predicateID,
        value: .text("prefers asynchronous plans"),
        ai: .allowOnDevice,
        mention: .ask
    )
    let neverMention = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.boundaries.predicateID,
        value: .text("do not suggest surprise visits"),
        ai: .allowConfiguredShortcut,
        mention: .never
    )
    let projection = RecommendationMemoryProjector().project(
        person: person,
        assertions: [neverMention, askFirst, mentionable],
        attributeDefinitions: []
    )

    let recommendation = projection.promptPacket(for: .personalizedRecommendation)
    #expect(recommendation.mentionableFacts.map(\.assertionID) == [mentionable.id])
    #expect(Set(recommendation.internalGuidance.map(\.assertionID)) == Set([askFirst.id, neverMention.id]))
    #expect(recommendation.sourcePolicy == .onDeviceOnly)
    #expect(recommendation.prompt.contains("MENTIONABLE FACTS"))
    #expect(recommendation.prompt.contains("INTERNAL GUIDANCE"))
    #expect(recommendation.prompt.contains("Never phrase these as facts to mention"))

    let draft = projection.promptPacket(for: .conversationDraft)
    #expect(draft.mentionableFacts.map(\.assertionID) == [mentionable.id])
    #expect(draft.internalGuidance.isEmpty)
    #expect(draft.sourcePolicy == .configuredShortcutEligible)
    #expect(!draft.prompt.contains("prefers asynchronous plans"))
    #expect(!draft.prompt.contains("do not suggest surprise visits"))

    let centralAI = projection.configuredShortcutPromptPacket(
        for: .personalizedRecommendation
    )
    #expect(centralAI.mentionableFacts.map(\.assertionID) == [mentionable.id])
    #expect(centralAI.internalGuidance.map(\.assertionID) == [neverMention.id])
    #expect(centralAI.sourcePolicy == .configuredShortcutEligible)
    #expect(centralAI.omittedFactCount == 1)
    #expect(!centralAI.prompt.contains("prefers asynchronous plans"))
    #expect(centralAI.prompt.contains("do not suggest surprise visits"))
}

@Test func centralShortcutPacketDeniesModelUseWithoutExplicitShortcutPermission() throws {
    let person = Person(displayName: "Local-only context")
    let localOnly = try recommendationAssertion(
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.currentPriorities.predicateID,
        value: .text("must remain on device"),
        ai: .allowOnDevice,
        mention: .allow
    )
    let projection = RecommendationMemoryProjector().project(
        person: person,
        assertions: [localOnly],
        attributeDefinitions: []
    )

    let packet = projection.configuredShortcutPromptPacket(
        for: .personalizedRecommendation
    )
    #expect(packet.mentionableFacts.isEmpty)
    #expect(packet.internalGuidance.isEmpty)
    #expect(packet.sourcePolicy == .modelsDenied)
    #expect(packet.omittedFactCount == 1)
    #expect(!packet.prompt.contains("must remain on device"))
}

@Test func recommendationMemoryProjectionOrderingAndTruncationAreDeterministicAndBounded() throws {
    let person = Person(displayName: String(repeating: "S", count: 100))
    let support = try recommendationAssertion(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.supportIdeas.predicateID,
        value: .text("support")
    )
    let topic = try recommendationAssertion(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.conversationTopics.predicateID,
        value: .text("abcdefghij"),
        mention: .allow
    )
    let priority = try recommendationAssertion(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        subjectID: person.id,
        predicateID: RecommendationMemoryCategory.currentPriorities.predicateID,
        value: .text("priority")
    )
    let limits = RecommendationMemoryLimits(
        maximumFacts: 2,
        maximumValueCharacters: 6,
        maximumTotalValueCharacters: 9,
        maximumSubjectCharacters: 8,
        maximumPromptCharacters: 1_000
    )
    let projector = RecommendationMemoryProjector()
    let first = projector.project(
        person: person,
        assertions: [support, priority, topic],
        attributeDefinitions: [],
        limits: limits
    )
    let second = projector.project(
        person: person,
        assertions: [topic, support, priority],
        attributeDefinitions: [],
        limits: limits
    )

    #expect(first.subject.displayName == "SSSSSSSS")
    #expect(first.facts.map(\.assertionID) == [topic.id, priority.id])
    #expect(first.facts.map(\.value) == ["abcdef", "pri"])
    #expect(first.omittedFactCount == 1)
    #expect(first == second)
    #expect(first.promptPacket(for: .personalizedRecommendation).prompt.count <= 1_000)
}

@Test func recommendationMemoryImmutableFactoryCreatesVersionsAndClearMarkerPreventsResurrection() throws {
    let personID = UUID()
    let original = try RecommendationMemoryAssertionFactory.makeNext(
        subjectID: personID,
        category: .conversationTopics,
        value: "  books  ",
        policy: recommendationPolicy(ai: .allowPrivateCloudCompute, mention: .allow),
        observedAt: Date(timeIntervalSince1970: 100),
        assertedAt: Date(timeIntervalSince1970: 100)
    )
    let replacement = try RecommendationMemoryAssertionFactory.makeNext(
        subjectID: personID,
        category: .conversationTopics,
        value: "films",
        policy: recommendationPolicy(ai: .allowOnDevice, mention: .ask),
        replacing: original,
        observedAt: Date(timeIntervalSince1970: 200),
        assertedAt: Date(timeIntervalSince1970: 200)
    )
    #expect(original.value == .text("books"))
    #expect(original.supersedesID == nil)
    #expect(replacement.value == .text("films"))
    #expect(replacement.supersedesID == original.id)
    #expect(replacement.usePolicy.ai == .allowOnDevice)

    let clear = try RecommendationMemoryAssertionFactory.makeClearedNext(
        subjectID: personID,
        category: .conversationTopics,
        replacing: replacement,
        observedAt: Date(timeIntervalSince1970: 300),
        assertedAt: Date(timeIntervalSince1970: 300)
    )
    #expect(clear.value == .text(""))
    #expect(clear.supersedesID == replacement.id)
    #expect(clear.usePolicy == .restrictive)

    let projection = RecommendationMemoryProjector().project(
        person: Person(id: personID, displayName: "Cleared"),
        assertions: [original, clear, replacement],
        attributeDefinitions: []
    )
    #expect(projection.facts.isEmpty)
    #expect(projection.sourcePolicy == .modelsDenied)
}

@Test func recommendationMemoryImmutableFactoryRejectsInvalidReplacementAndEmptyValue() throws {
    let personID = UUID()
    let original = try RecommendationMemoryAssertionFactory.makeNext(
        subjectID: personID,
        category: .conversationTopics,
        value: "topic",
        policy: recommendationPolicy(ai: .allowOnDevice)
    )
    #expect(throws: RecommendationMemoryAssertionFactoryError.emptyValue) {
        try RecommendationMemoryAssertionFactory.makeNext(
            subjectID: personID,
            category: .conversationTopics,
            value: "  ",
            policy: recommendationPolicy(ai: .allowOnDevice)
        )
    }
    #expect(throws: RecommendationMemoryAssertionFactoryError.replacementSubjectMismatch) {
        try RecommendationMemoryAssertionFactory.makeNext(
            subjectID: UUID(),
            category: .conversationTopics,
            value: "new",
            policy: recommendationPolicy(ai: .allowOnDevice),
            replacing: original
        )
    }
    #expect(throws: RecommendationMemoryAssertionFactoryError.replacementPredicateMismatch) {
        try RecommendationMemoryAssertionFactory.makeClearedNext(
            subjectID: personID,
            category: .boundaries,
            replacing: original
        )
    }
}
