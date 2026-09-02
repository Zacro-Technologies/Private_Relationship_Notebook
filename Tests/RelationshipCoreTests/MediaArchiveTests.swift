import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RelationshipCore

@Test func mediaArchivePackageRoundTripsVerifiedPortraits() throws {
    let fixture = try makeMediaArchiveFixture()
    let codec = RelationshipVaultPackageCodec()
    let package = try codec.makePackage(
        archive: fixture.archive,
        mediaData: [fixture.asset.id: fixture.data],
        localeIdentifier: "ja-JP"
    )
    let wrapper = try codec.fileWrapper(for: package)
    let verified = try codec.inspect(wrapper)

    #expect(verified.manifest.format == RelationshipVaultManifest.currentFormat)
    #expect(verified.manifest.localeIdentifier == "ja-JP")
    #expect(verified.manifest.encryption == "none")
    #expect(verified.manifest.entityCounts.people == 1)
    #expect(verified.manifest.entityCounts.media == 1)
    #expect(verified.archive.people.map(\.id) == [fixture.person.id])
    #expect(verified.archive.canonical?.portraitMedia?.map(\.id) == [fixture.asset.id])
    #expect(verified.mediaData[fixture.asset.id] == fixture.data)
}

@Test func mediaArchiveRejectsTamperedOrMissingMediaBeforePreview() throws {
    let fixture = try makeMediaArchiveFixture()
    let codec = RelationshipVaultPackageCodec()
    let package = try codec.makePackage(
        archive: fixture.archive,
        mediaData: [fixture.asset.id: fixture.data]
    )
    let wrapper = try codec.fileWrapper(for: package)
    let files = try #require(wrapper.fileWrappers)
    let fileName = "\(fixture.asset.id.uuidString.lowercased()).jpg"

    let tamperedRoot = FileWrapper(directoryWithFileWrappers: [
        "manifest.json": try #require(files["manifest.json"]),
        "data": try #require(files["data"]),
        "media": FileWrapper(directoryWithFileWrappers: [
            fileName: FileWrapper(regularFileWithContents: fixture.data + Data([0]))
        ]),
        "checksums.sha256": try #require(files["checksums.sha256"])
    ])
    #expect(throws: RelationshipVaultPackageError.self) {
        _ = try codec.inspect(tamperedRoot)
    }

    let missingRoot = FileWrapper(directoryWithFileWrappers: [
        "manifest.json": try #require(files["manifest.json"]),
        "data": try #require(files["data"]),
        "media": FileWrapper(directoryWithFileWrappers: [:]),
        "checksums.sha256": try #require(files["checksums.sha256"])
    ])
    #expect(throws: RelationshipVaultPackageError.self) {
        _ = try codec.inspect(missingRoot)
    }
}

@Test func mediaArchiveRejectsUnexpectedStructureAndFalseJPEG() throws {
    let fixture = try makeMediaArchiveFixture()
    let codec = RelationshipVaultPackageCodec()
    let package = try codec.makePackage(
        archive: fixture.archive,
        mediaData: [fixture.asset.id: fixture.data]
    )
    let wrapper = try codec.fileWrapper(for: package)
    let files = try #require(wrapper.fileWrappers)
    var unsafeFiles = files
    unsafeFiles["../escape"] = FileWrapper(regularFileWithContents: Data())
    #expect(throws: RelationshipVaultPackageError.invalidPackageStructure) {
        _ = try codec.inspect(FileWrapper(directoryWithFileWrappers: unsafeFiles))
    }

    var falseAsset = fixture.asset
    let falseData = Data("not really a jpeg".utf8)
    falseAsset.sha256 = SHA256.hash(data: falseData).map { String(format: "%02x", $0) }.joined()
    falseAsset.byteCount = Int64(falseData.count)
    let falseArchive = NotebookArchive(
        people: [fixture.person],
        interactions: [],
        canonical: CanonicalArchivePayload(portraitMedia: [falseAsset])
    )
    #expect(throws: RelationshipVaultPackageError.invalidMediaFile(falseAsset.id)) {
        _ = try codec.makePackage(
            archive: falseArchive,
            mediaData: [falseAsset.id: falseData]
        )
    }
}

@Test func mediaArchiveRejectsPrivateMetadataEvenWhenMarkedStripped() throws {
    let person = Person(displayName: "Metadata boundary owner")
    let data = try makeTinyJPEG(properties: [
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 35.6812,
            kCGImagePropertyGPSLongitude: 139.7671
        ],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifUserComment: "private archive metadata"
        ]
    ])
    let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let asset = PortraitMediaAsset(
        personID: person.id,
        sha256: checksum,
        byteCount: Int64(data.count),
        pixelWidth: 2,
        pixelHeight: 2,
        isPrimary: true,
        metadataWasStripped: true
    )
    let archive = NotebookArchive(
        people: [person],
        interactions: [],
        canonical: CanonicalArchivePayload(portraitMedia: [asset])
    )

    #expect(throws: RelationshipVaultPackageError.metadataNotSanitized(asset.id)) {
        _ = try RelationshipVaultPackageCodec().makePackage(
            archive: archive,
            mediaData: [asset.id: data]
        )
    }
}

@Test func portraitPackageImportStagingCanCommitAndRollback() async throws {
    let fixture = try makeMediaArchiveFixture()
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let store = PortraitMediaFileStore(rootDirectory: temporaryRoot)
    let sanitized = SanitizedPortrait(asset: fixture.asset, data: fixture.data)

    let ticket = try await store.stageImport(sanitized)
    try await store.commitImport(ticket)
    #expect(try await store.data(for: fixture.asset) == fixture.data)
    try await store.rollbackImport(ticket)
    await #expect(throws: PortraitMediaError.self) {
        _ = try await store.data(for: fixture.asset)
    }
}

@Test func importPlannerSelectsPortraitMetadataOnlyForVerifiedPackageBytes() throws {
    let fixture = try makeMediaArchiveFixture()
    let data = try ArchiveCodec.encode(fixture.archive)
    let planner = ArchiveImportPlanner()
    let plainPlan = try planner.inspect(
        data,
        existingPeople: [],
        existingInteractions: []
    )
    #expect(!plainPlan.structuredRecordsToCreate.contains {
        $0.family == .portraitMedia
    })
    #expect(plainPlan.issues.contains { $0.code == .missingMediaPayload })

    let packagePlan = try planner.inspect(
        data,
        existingPeople: [],
        existingInteractions: [],
        verifiedPortraitMediaIDs: [fixture.asset.id]
    )
    #expect(packagePlan.structuredRecordsToCreate.contains(
        ArchiveStructuredRecordIdentity(family: .portraitMedia, id: fixture.asset.id)
    ))
    #expect(!packagePlan.issues.contains { $0.code == .missingMediaPayload })
}

@Test func mediaArchiveURLPreflightBoundsFilesBeforeLoadingPackage() throws {
    let fixture = try makeMediaArchiveFixture()
    let codec = RelationshipVaultPackageCodec()
    let package = try codec.makePackage(
        archive: fixture.archive,
        mediaData: [fixture.asset.id: fixture.data]
    )
    let wrapper = try codec.fileWrapper(for: package)
    let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("relationshipvault")
    defer { try? FileManager.default.removeItem(at: packageURL) }
    try wrapper.write(to: packageURL, options: .atomic, originalContentsURL: nil)

    let verified = try codec.inspect(at: packageURL)
    #expect(verified.mediaData[fixture.asset.id] == fixture.data)

    let oversizedCodec = RelationshipVaultPackageCodec(limits: .init(
        maximumManifestBytes: 1_000_000,
        maximumNotebookBytes: 50_000_000,
        maximumMediaFiles: 10,
        maximumMediaFileBytes: max(1, fixture.data.count - 1),
        maximumMediaPixels: 80_000_000,
        maximumTotalPayloadBytes: 1_000_000
    ))
    #expect(throws: RelationshipVaultPackageError.mediaFileTooLarge(fixture.asset.id)) {
        _ = try oversizedCodec.inspect(at: packageURL)
    }
}

private struct MediaArchiveFixture {
    var person: Person
    var asset: PortraitMediaAsset
    var data: Data
    var archive: NotebookArchive
}

private func makeMediaArchiveFixture() throws -> MediaArchiveFixture {
    let person = Person(displayName: "Portrait owner")
    let data = try makeTinyJPEG()
    let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let asset = PortraitMediaAsset(
        personID: person.id,
        sha256: checksum,
        byteCount: Int64(data.count),
        pixelWidth: 2,
        pixelHeight: 2,
        isPrimary: true
    )
    let archive = NotebookArchive(
        people: [person],
        interactions: [],
        canonical: CanonicalArchivePayload(portraitMedia: [asset])
    )
    return MediaArchiveFixture(person: person, asset: asset, data: data, archive: archive)
}

private func makeTinyJPEG(properties: [CFString: Any]? = nil) throws -> Data {
    let pixels: [UInt8] = [
        255, 0, 0, 255, 0, 255, 0, 255,
        0, 0, 255, 255, 255, 255, 255, 255
    ]
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        output,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    if let properties {
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    } else {
        CGImageDestinationAddImage(destination, image, nil)
    }
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}
