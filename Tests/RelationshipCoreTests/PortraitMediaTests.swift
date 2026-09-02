import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RelationshipCore

@Test func portraitImportStripsMetadataAndRoundTripsProtectedBytes() async throws {
    let sourceData = try makePortraitFixtureWithLocationMetadata()
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let store = PortraitMediaFileStore(rootDirectory: temporaryRoot)
    let sanitized = try await store.sanitize(sourceData, personID: UUID(), isPrimary: true)
    #expect(sanitized.asset.metadataWasStripped)
    #expect(sanitized.asset.isPrimary)
    #expect(sanitized.asset.pixelWidth == 2)
    #expect(sanitized.asset.pixelHeight == 2)

    let source = try #require(CGImageSourceCreateWithData(sanitized.data as CFData, nil))
    let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    let EXIF = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(EXIF?[kCGImagePropertyExifUserComment] == nil)

    try await store.store(sanitized)
    #expect(try await store.data(for: sanitized.asset) == sanitized.data)

    let rollbackTicket = try await store.stageRemoval(sanitized.asset)
    var wasStaged = false
    do {
        _ = try await store.data(for: sanitized.asset)
    } catch is PortraitMediaError {
        wasStaged = true
    }
    #expect(wasStaged)
    try await store.restoreRemoval(rollbackTicket)
    #expect(try await store.data(for: sanitized.asset) == sanitized.data)

    let commitTicket = try await store.stageRemoval(sanitized.asset)
    try await store.finalizeRemoval(commitTicket)
    var didThrowExpectedError = false
    do {
        _ = try await store.data(for: sanitized.asset)
    } catch is PortraitMediaError {
        didThrowExpectedError = true
    }
    #expect(didThrowExpectedError)
}

private func makePortraitFixtureWithLocationMetadata() throws -> Data {
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
    let properties: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 35.6812,
            kCGImagePropertyGPSLongitude: 139.7671
        ],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private fixture"]
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}
