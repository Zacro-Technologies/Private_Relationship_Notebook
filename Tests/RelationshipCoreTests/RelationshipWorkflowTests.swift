import Foundation
import Testing
@testable import RelationshipCore

@Test func interactionPlanningProjectionCreatesAndReconcilesFirstClassRecords() throws {
    let personID = UUID()
    let interactionID = UUID()
    let due = Date(timeIntervalSince1970: 2_000_000)
    let interaction = Interaction(
        id: interactionID,
        personID: personID,
        occurredAt: due.addingTimeInterval(-86_400),
        status: .confirmed,
        summary: "Caught up",
        commitment: "Send the introduction",
        followUpAt: due
    )

    let first = InteractionPlanningProjection.make(
        for: interaction,
        existingReminders: [],
        existingCommitments: [],
        now: due.addingTimeInterval(-100)
    )
    let reminder = try #require(first.reminder)
    let commitment = try #require(first.commitment)
    #expect(reminder.interactionID == interactionID)
    #expect(commitment.interactionID == interactionID)
    #expect(commitment.summary == "Send the introduction")

    var edited = interaction
    edited.commitment = ""
    edited.followUpAt = due.addingTimeInterval(3_600)
    let second = InteractionPlanningProjection.make(
        for: edited,
        existingReminders: [reminder],
        existingCommitments: [commitment]
    )
    #expect(second.reminder?.id == reminder.id)
    #expect(second.commitment == nil)
    #expect(second.commitmentIDsToDelete == [commitment.id])
}

@Test func planningLifecycleEventsDriveActionabilityAndPreserveHistory() {
    var reminder = Reminder(
        subject: .person(UUID()),
        title: "Follow up",
        due: .instant(.now.addingTimeInterval(86_400), timeZoneIdentifier: nil)
    )
    reminder.record(.completed, at: Date(timeIntervalSince1970: 10))
    #expect(reminder.lifecycleState == .completed)
    #expect(!reminder.isActionable)
    reminder.record(.reopened, at: Date(timeIntervalSince1970: 20))
    #expect(reminder.lifecycleState == .active)
    #expect(reminder.isActionable)
    #expect(reminder.events?.count == 2)

    var commitment = Commitment(summary: "Keep the promise")
    commitment.record(.completed, at: Date(timeIntervalSince1970: 10))
    #expect(commitment.lifecycleState == .completed)
    commitment.record(.reopened, at: Date(timeIntervalSince1970: 20))
    #expect(commitment.lifecycleState == .active)
}

@Test func todayAttentionProjectionIncludesOpenWorkAndExcludesResolvedState() throws {
    let personID = UUID()
    let due = Date(timeIntervalSince1970: 100)
    var completed = Reminder(
        subject: .person(personID),
        title: "Done",
        due: .instant(due, timeZoneIdentifier: nil)
    )
    completed.record(.completed, at: due)
    let active = Reminder(
        subject: .person(personID),
        title: "Open reminder",
        due: .instant(due, timeZoneIdentifier: nil)
    )
    let unresolved = Interaction(
        personID: personID,
        occurredAt: due,
        kind: .attempt,
        status: .composerOpened
    )
    let items = TodayAttentionProjector.project(
        reminders: [completed, active],
        commitments: [Commitment(personIDs: [personID], summary: "Open commitment")],
        interactions: [unresolved],
        pendingReviewIDs: [UUID()]
    )
    #expect(items.map(\.kind).contains(.reminder))
    #expect(items.map(\.kind).contains(.commitment))
    #expect(items.map(\.kind).contains(.unresolvedContact))
    #expect(items.map(\.kind).contains(.pendingReview))
    #expect(!items.contains { $0.recordID == completed.id })
}

@Test func contactHandoffRoutesPrefillOnlySupportedDestinations() throws {
    let body = "Hello & welcome?"
    let email = ContactHandoffRouteBuilder.route(
        for: ContactMethod(kind: .email, value: "friend@example.com"),
        reviewedBody: body
    )
    #expect(email.support == .recipientAndBody)
    let emailURL = try #require(email.URL)
    let emailComponents = try #require(URLComponents(url: emailURL, resolvingAgainstBaseURL: false))
    #expect(emailComponents.scheme == "mailto")
    #expect(emailComponents.path == "friend@example.com")
    #expect(emailComponents.queryItems?.first(where: { $0.name == "body" })?.value == body)

    let messages = ContactHandoffRouteBuilder.route(
        for: ContactMethod(kind: .messages, value: "+1 (416) 555-0100"),
        reviewedBody: body
    )
    #expect(messages.support == .recipientAndBody)
    let messagesURL = try #require(messages.URL)
    let messageComponents = try #require(URLComponents(url: messagesURL, resolvingAgainstBaseURL: false))
    #expect(messageComponents.path == "+14165550100")
    #expect(messageComponents.queryItems?.first(where: { $0.name == "body" })?.value == body)

    let whatsapp = ContactHandoffRouteBuilder.route(
        for: ContactMethod(kind: .whatsapp, value: "+1 (416) 555-0100"),
        reviewedBody: body
    )
    #expect(whatsapp.support == .recipientAndBody)
    let whatsAppURL = try #require(whatsapp.URL)
    let whatsAppComponents = try #require(URLComponents(url: whatsAppURL, resolvingAgainstBaseURL: false))
    #expect(whatsAppComponents.host == "wa.me")
    #expect(whatsAppComponents.path == "/14165550100")
    #expect(whatsAppComponents.queryItems?.first(where: { $0.name == "text" })?.value == body)

    for kind in [ContactKind.line, .instagram, .snapchat] {
        let unsupported = ContactHandoffRouteBuilder.route(
            for: ContactMethod(kind: kind, value: "private-handle"),
            reviewedBody: body
        )
        #expect(unsupported.support == .clipboardOnlyUntargeted)
        #expect(unsupported.URL?.absoluteString.contains("private-handle") == false)
        #expect(unsupported.URL?.absoluteString.contains(body) == false)
    }

    let avoided = ContactHandoffRouteBuilder.route(
        for: ContactMethod(
            kind: .email,
            value: "private@example.com",
            isAvoided: true
        ),
        reviewedBody: body
    )
    #expect(avoided.support == .clipboardOnlyUntargeted)
    #expect(avoided.URL == nil)
}

@Test func manualSuggestionHistoryDoesNotConsumeProactiveCooldown() throws {
    let personID = UUID()
    let now = Date(timeIntervalSince1970: 500)
    var history = NudgeSuggestionHistory()
    history.record(personID: personID, at: now, proactive: false)
    #expect(history.recentSuggestionByPerson[personID] == nil)
    #expect(history.manualSuggestionByPerson?[personID] == now)
    #expect(history.proactiveShownDates.isEmpty)

    let encoded = try JSONEncoder().encode(history)
    let decoded = try JSONDecoder().decode(NudgeSuggestionHistory.self, from: encoded)
    #expect(decoded.manualSuggestionByPerson?[personID] == now)
}

@Test func interactionCorrectionRecordsChangedFieldsWithoutDuplicatingPrivateNarrative() throws {
    let original = Interaction(
        personID: UUID(),
        occurredAt: Date(timeIntervalSince1970: 100),
        summary: "Sensitive old recap",
        privateReflection: "Sensitive old reflection"
    )
    var edited = original
    edited.status = .attempted
    edited.summary = "Sensitive new recap"
    let corrected = edited.recordingCorrection(from: original, at: Date(timeIntervalSince1970: 200))
    let changes = try #require(corrected.correctionHistory?.first?.changes)
    #expect(changes.contains { $0.field == "status" && $0.previousValue == "Confirmed" })
    #expect(changes.contains { $0.field == "summary" && $0.previousValue == "Present" && $0.newValue == "Present" } == false)
    #expect(!String(describing: changes).contains("Sensitive old"))
    #expect(!String(describing: changes).contains("Sensitive new"))
}

@MainActor
@Test func throwingPlanningWritesPublishConfirmedSnapshots() throws {
    let persistence = PersistenceController(inMemory: true)
    let canonical = CanonicalVaultStore(persistence: persistence)
    let personID = UUID()
    let reminder = Reminder(
        subject: .person(personID),
        title: "Confirmed reminder",
        due: .instant(.now.addingTimeInterval(86_400), timeZoneIdentifier: nil)
    )
    let commitment = Commitment(
        personIDs: [personID],
        summary: "Confirmed commitment"
    )

    try canonical.saveReminder(reminder)
    try canonical.saveCommitment(commitment)
    #expect(canonical.reminders.contains { $0.id == reminder.id })
    #expect(canonical.commitments.contains { $0.id == commitment.id })

    try canonical.deleteReminder(reminder)
    try canonical.deleteCommitment(commitment)
    #expect(!canonical.reminders.contains { $0.id == reminder.id })
    #expect(!canonical.commitments.contains { $0.id == commitment.id })
    #expect(canonical.recentlyDeletedRecords.contains { $0.recordID == reminder.id })
    #expect(canonical.recentlyDeletedRecords.contains { $0.recordID == commitment.id })
}

@Test func avoidedRoutesAndRecipientTimeZoneAffectHandoffEligibility() throws {
    let midnightUTC = try #require(
        ISO8601DateFormatter().date(from: "2026-08-31T00:30:00Z")
    )
    let person = Person(
        displayName: "Aiko",
        contacts: [
            ContactMethod(
                kind: .email,
                value: "avoid@example.com",
                isPreferred: true,
                isAvoided: true
            ),
            ContactMethod(kind: .messages, value: "+14165550100", isPreferred: false)
        ],
        recipientTimeZoneIdentifier: "UTC",
        communicationPreferences: "Messages before calls"
    ).normalizedForPersistence()

    #expect(person.contacts.first?.isPreferred == false)
    #expect(person.preferredAvailableContactMethod?.kind == .messages)
    let report = NudgeEngine(now: { midnightUTC }).eligibilityReport(
        for: [person],
        policy: NudgePolicy(cooldownDays: 0)
    )
    #expect(report.excluded[person.id] == .recipientQuietHours)
}

@MainActor
@Test func relationshipPreferencesAndContactLinkRoundTripThroughVaultPersistence() throws {
    let persistence = PersistenceController(inMemory: true)
    let notebook = NotebookStore(persistence: persistence)
    let person = Person(
        displayName: "Mina",
        contacts: [ContactMethod(
            kind: .phone,
            value: "+1 416 555 0100",
            isPreferred: false,
            isAvoided: true
        )],
        recipientTimeZoneIdentifier: "Asia/Tokyo",
        communicationPreferences: "Email on weekdays",
        linkedContactIdentifier: "opaque-contact-identifier"
    )

    #expect(notebook.save(person))
    let reloaded = NotebookStore(persistence: persistence)
    let saved = try #require(reloaded.person(id: person.id))
    #expect(saved.contacts.first?.avoided == true)
    #expect(saved.recipientTimeZoneIdentifier == "Asia/Tokyo")
    #expect(saved.communicationPreferences == "Email on weekdays")
    #expect(saved.linkedContactIdentifier == "opaque-contact-identifier")
}

@Test func batchFactPolicyRevisionPreservesProvenanceAndHistoryLink() throws {
    let sourceID = UUID()
    let original = try AssertionEnvelope(
        subjectID: UUID(),
        predicateID: "relationship.context",
        value: .text("Alumni group"),
        sourceID: sourceID,
        evidenceIDs: [UUID()],
        origin: .imported,
        reviewStatus: .pending,
        usePolicy: .init()
    )
    let revisedAt = Date(timeIntervalSince1970: 42)
    let revised = try original.revisingReviewAndUsePolicy(
        reviewStatus: .accepted,
        usePolicy: .restrictive,
        assertedAt: revisedAt
    )

    #expect(revised.id != original.id)
    #expect(revised.supersedesID == original.id)
    #expect(revised.sourceID == sourceID)
    #expect(revised.evidenceIDs == original.evidenceIDs)
    #expect(revised.reviewStatus == .accepted)
    #expect(revised.usePolicy == .restrictive)
    #expect(revised.assertedAt == revisedAt)
}
