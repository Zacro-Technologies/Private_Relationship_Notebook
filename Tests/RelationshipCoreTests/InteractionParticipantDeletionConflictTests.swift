import Foundation
import Testing
@testable import RelationshipCore

@Test @MainActor
func interactionDraftWithPermanentlyDeletedParticipantMovesToLocalRecovery() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let person = Person(displayName: "Deleted on another device")
    #expect(store.save(person))

    let attemptedInteraction = Interaction(
        personID: person.id,
        summary: "Keep this unsaved relationship detail"
    )

    store.permanentlyDelete(person, deleteInteractions: false)
    #expect(store.person(id: person.id) == nil)

    #expect(!store.save(attemptedInteraction))
    #expect(store.interactions.allSatisfy { $0.id != attemptedInteraction.id })
    #expect(store.lastError?.contains("Deletion Conflict Recovery") == true)

    let draft = try #require(
        store.deletionConflictDrafts().first {
            $0.target == .interaction(attemptedInteraction.id)
        }
    )
    #expect(
        draft.row.attributes["summary"] ==
            .string(attemptedInteraction.summary)
    )
    guard case .data(let encodedInteraction) = draft.row.attributes["detailsData"] else {
        Issue.record("The rejected interaction was not preserved losslessly")
        return
    }
    #expect(
        try JSONDecoder().decode(Interaction.self, from: encodedInteraction) ==
            attemptedInteraction.normalizedForRetention()
    )
}

@Test @MainActor
func interactionDraftWithSoftDeletedAdditionalParticipantMovesToLocalRecovery() throws {
    let persistence = PersistenceController(inMemory: true)
    let store = NotebookStore(persistence: persistence)
    let primary = Person(displayName: "Still active")
    let deletedAdditional = Person(displayName: "Recently deleted elsewhere")
    #expect(store.save(primary))
    #expect(store.save(deletedAdditional))

    var softDeleted = deletedAdditional
    softDeleted.deletedAt = .now
    softDeleted.modifiedAt = .now
    #expect(store.save(softDeleted))
    let attemptedInteraction = Interaction(
        personID: primary.id,
        summary: "Preserve all participant choices",
        additionalParticipantIDs: [deletedAdditional.id]
    )

    #expect(!store.save(attemptedInteraction))
    #expect(store.interactions.allSatisfy { $0.id != attemptedInteraction.id })
    let draft = try #require(store.deletionConflictDrafts().first {
        $0.target == .interaction(attemptedInteraction.id)
    })
    guard case .data(let details) = draft.row.attributes["detailsData"] else {
        Issue.record("The rejected interaction details were not preserved")
        return
    }
    #expect(
        try JSONDecoder().decode(Interaction.self, from: details)
            .additionalParticipantIDs == [deletedAdditional.id]
    )
}
