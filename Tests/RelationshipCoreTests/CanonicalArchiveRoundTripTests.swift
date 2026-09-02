import Foundation
import Testing
@testable import RelationshipCore

@MainActor
struct CanonicalArchiveRoundTripTests {
    @Test func fullJSONRoundTripPreservesStructuredRecords() throws {
        let sourcePersistence = PersistenceController(inMemory: true)
        let sourceStore = NotebookStore(persistence: sourcePersistence)
        let sourceCanonical = CanonicalVaultStore(persistence: sourcePersistence)

        let person = Person(displayName: "Aiko")
        let context = Context(kind: .program, names: LocalizedText("Kizuna"))
        let membership = MembershipEpisode(personID: person.id, contextID: context.id, status: .active)
        let reminder = Reminder(
            subject: .person(person.id),
            title: "Check in",
            due: .instant(.now.addingTimeInterval(86_400), timeZoneIdentifier: "Asia/Tokyo")
        )
        let source = SourceArtifact(kind: .pdf, sha256: "abc123")
        let unit = ArtifactUnit(sourceID: source.id, kind: .page, index: 2)
        let evidence = try EvidenceSpan(
            unitID: unit.id,
            textRange: TextEvidenceRange(startUTF16Offset: 4, endUTF16Offset: 12),
            excerptHash: "def456",
            retainedExcerpt: "evidence"
        )
        let portrait = PortraitMediaAsset(
            personID: person.id,
            sha256: "portrait-hash",
            byteCount: 128,
            pixelWidth: 4,
            pixelHeight: 4,
            isPrimary: true
        )
        sourceStore.save(person)
        sourceCanonical.save(context)
        sourceCanonical.save(membership)
        sourceCanonical.save(reminder)
        sourceCanonical.save(source)
        sourceCanonical.save(unit)
        sourceCanonical.save(evidence)
        sourceCanonical.save(portrait)

        let data = try sourceStore.exportData()
        let decoded = try ArchiveCodec.decode(data)
        #expect(decoded.canonical?.contexts.map(\.id) == [context.id])
        #expect(decoded.canonical?.memberships.map(\.id) == [membership.id])
        #expect(decoded.canonical?.reminders.map(\.id) == [reminder.id])
        #expect(decoded.canonical?.artifactUnits?.map(\.id) == [unit.id])
        #expect(decoded.canonical?.evidence.map(\.id) == [evidence.id])
        #expect(decoded.canonical?.portraitMedia?.map(\.id) == [portrait.id])

        let destinationPersistence = PersistenceController(inMemory: true)
        let destinationStore = NotebookStore(persistence: destinationPersistence)
        let destinationCanonical = CanonicalVaultStore(persistence: destinationPersistence)
        destinationStore.importArchive(decoded)
        destinationCanonical.reload()

        #expect(destinationStore.person(id: person.id)?.displayName == "Aiko")
        #expect(destinationCanonical.contexts.map(\.id) == [context.id])
        #expect(destinationCanonical.memberships.map(\.id) == [membership.id])
        #expect(destinationCanonical.reminders.map(\.id) == [reminder.id])
        #expect(destinationCanonical.artifactUnits.map(\.id) == [unit.id])
        #expect(destinationCanonical.evidence.map(\.id) == [evidence.id])
        #expect(destinationCanonical.portraitMedia.map(\.id) == [portrait.id])
    }

    @Test func safeFutureExtensionsSurviveImportAndFullExportWithoutOverwrite() throws {
        let persistence = PersistenceController(inMemory: true)
        let store = NotebookStore(persistence: persistence)
        try store.commitImportedArchive(NotebookArchive(
            people: [],
            interactions: [],
            preservedExtensions: [
                "future.one": .string("first"),
                "future.object": .object(["enabled": .boolean(true)])
            ]
        ))
        try store.commitImportedArchive(NotebookArchive(
            people: [],
            interactions: [],
            preservedExtensions: [
                "future.one": .string("incoming must not overwrite"),
                "future.two": .number(2)
            ]
        ))

        let exported = try store.exportArchive()
        #expect(exported.preservedExtensions?["future.one"] == .string("first"))
        #expect(exported.preservedExtensions?["future.two"] == .number(2))
        #expect(exported.preservedExtensions?["future.object"] == .object([
            "enabled": .boolean(true)
        ]))
    }
}
