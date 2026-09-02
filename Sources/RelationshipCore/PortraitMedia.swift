import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PortraitMediaAsset: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let personID: UUID
    public var contentType: String
    public var sha256: String
    public var byteCount: Int64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isPrimary: Bool
    public let metadataWasStripped: Bool
    public let createdAt: Date
    public var modifiedAt: Date
    public var schemaRevision: Int32

    public init(
        id: UUID = UUID(),
        personID: UUID,
        contentType: String = UTType.jpeg.identifier,
        sha256: String,
        byteCount: Int64,
        pixelWidth: Int,
        pixelHeight: Int,
        isPrimary: Bool,
        metadataWasStripped: Bool = true,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        schemaRevision: Int32 = 1
    ) {
        self.id = id
        self.personID = personID
        self.contentType = contentType
        self.sha256 = sha256
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isPrimary = isPrimary
        self.metadataWasStripped = metadataWasStripped
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaRevision = schemaRevision
    }
}

public struct PortraitImportLimits: Codable, Hashable, Sendable {
    public var maximumInputBytes: Int
    public var maximumSourcePixels: Int64
    public var maximumOutputDimension: Int
    public var maximumOutputBytes: Int

    public init(
        maximumInputBytes: Int = 30 * 1_024 * 1_024,
        maximumSourcePixels: Int64 = 80_000_000,
        maximumOutputDimension: Int = 4_096,
        maximumOutputBytes: Int = 20 * 1_024 * 1_024
    ) {
        self.maximumInputBytes = maximumInputBytes
        self.maximumSourcePixels = maximumSourcePixels
        self.maximumOutputDimension = maximumOutputDimension
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public enum PortraitMediaError: LocalizedError, Equatable, Sendable {
    case inputTooLarge
    case invalidImage
    case excessivePixelCount
    case encodingFailed
    case outputTooLarge
    case storageUnavailable
    case integrityMismatch
    case destinationAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .inputTooLarge: String(localized: "This portrait file is larger than the private import limit.")
        case .invalidImage: String(localized: "The selected item is not a readable still image.")
        case .excessivePixelCount: String(localized: "This image has too many pixels to process safely.")
        case .encodingFailed: String(localized: "The portrait could not be sanitized on this device.")
        case .outputTooLarge: String(localized: "The sanitized portrait remains too large to store safely.")
        case .storageUnavailable: String(localized: "Protected portrait storage is unavailable.")
        case .integrityMismatch: String(localized: "The stored portrait failed its integrity check.")
        case .destinationAlreadyExists: String(localized: "A portrait with this stable identifier already exists.")
        }
    }
}

public struct SanitizedPortrait: Sendable {
    public var asset: PortraitMediaAsset
    public var data: Data

    public init(asset: PortraitMediaAsset, data: Data) {
        self.asset = asset
        self.data = data
    }
}

public struct PortraitRemovalTicket: Sendable {
    fileprivate let originalURL: URL
    fileprivate let stagedURL: URL?
}

public struct PortraitImportTicket: Sendable {
    public let assetID: UUID
    fileprivate let stagedURL: URL
    fileprivate let destinationURL: URL
}

/// Device-local protected cache for portraits. Imports are decoded and re-rasterized into a
/// new JPEG so EXIF, GPS, comments, embedded thumbnails, and other source metadata do not cross
/// the boundary. This service never performs face detection, recognition, or identity matching.
public actor PortraitMediaFileStore {
    private let rootDirectory: URL
    private let limits: PortraitImportLimits
    private let fileManager: FileManager

    public init(
        rootDirectory: URL? = nil,
        limits: PortraitImportLimits = .init(),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.limits = limits
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            self.rootDirectory = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PrivateRelationshipNotebook", isDirectory: true)
                .appendingPathComponent("Portraits", isDirectory: true)
        }
    }

    public func sanitize(
        _ input: Data,
        personID: UUID,
        isPrimary: Bool
    ) throws -> SanitizedPortrait {
        guard input.count <= limits.maximumInputBytes else { throw PortraitMediaError.inputTooLarge }
        guard let source = CGImageSourceCreateWithData(input as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw PortraitMediaError.invalidImage
        }
        let sourcePixels = sourceWidth.int64Value.multipliedReportingOverflow(by: sourceHeight.int64Value)
        guard !sourcePixels.overflow, sourcePixels.partialValue <= limits.maximumSourcePixels else {
            throw PortraitMediaError.excessivePixelCount
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.maximumOutputDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw PortraitMediaError.invalidImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PortraitMediaError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw PortraitMediaError.encodingFailed }
        let data = output as Data
        guard data.count <= limits.maximumOutputBytes else { throw PortraitMediaError.outputTooLarge }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SanitizedPortrait(
            asset: PortraitMediaAsset(
                personID: personID,
                sha256: digest,
                byteCount: Int64(data.count),
                pixelWidth: image.width,
                pixelHeight: image.height,
                isPrimary: isPrimary
            ),
            data: data
        )
    }

    public func store(_ portrait: SanitizedPortrait) throws {
        do {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: protectedDirectoryAttributes
            )
            let destination = fileURL(for: portrait.asset.id)
            try portrait.data.write(to: destination, options: protectedWriteOptions)
            try fileManager.setAttributes(protectedFileAttributes, ofItemAtPath: destination.path)
        } catch {
            throw PortraitMediaError.storageUnavailable
        }
    }

    /// Writes verified package bytes to a protected staging location. The live
    /// destination is not changed until `commitImport` is called.
    public func stageImport(_ portrait: SanitizedPortrait) throws -> PortraitImportTicket {
        let digest = SHA256.hash(data: portrait.data).map { String(format: "%02x", $0) }.joined()
        guard digest == portrait.asset.sha256.lowercased(),
              Int64(portrait.data.count) == portrait.asset.byteCount,
              portrait.asset.metadataWasStripped else {
            throw PortraitMediaError.integrityMismatch
        }
        let destinationURL = fileURL(for: portrait.asset.id)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw PortraitMediaError.destinationAlreadyExists
        }
        let stagingDirectory = rootDirectory.appendingPathComponent("ImportStaging", isDirectory: true)
        let stagedURL = stagingDirectory
            .appendingPathComponent("\(portrait.asset.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())")
            .appendingPathExtension("jpg")
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true,
                attributes: protectedDirectoryAttributes
            )
            try portrait.data.write(to: stagedURL, options: protectedWriteOptions)
            try fileManager.setAttributes(protectedFileAttributes, ofItemAtPath: stagedURL.path)
            return PortraitImportTicket(
                assetID: portrait.asset.id,
                stagedURL: stagedURL,
                destinationURL: destinationURL
            )
        } catch let error as PortraitMediaError {
            throw error
        } catch {
            throw PortraitMediaError.storageUnavailable
        }
    }

    /// Makes staged bytes live immediately before the metadata transaction. If
    /// metadata persistence fails, `rollbackImport` removes these bytes.
    public func commitImport(_ ticket: PortraitImportTicket) throws {
        guard fileManager.fileExists(atPath: ticket.stagedURL.path),
              !fileManager.fileExists(atPath: ticket.destinationURL.path) else {
            throw PortraitMediaError.destinationAlreadyExists
        }
        do {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: protectedDirectoryAttributes
            )
            try fileManager.moveItem(at: ticket.stagedURL, to: ticket.destinationURL)
            try fileManager.setAttributes(protectedFileAttributes, ofItemAtPath: ticket.destinationURL.path)
        } catch {
            throw PortraitMediaError.storageUnavailable
        }
    }

    /// Idempotently removes either the staged or newly committed package file.
    public func rollbackImport(_ ticket: PortraitImportTicket) throws {
        do {
            if fileManager.fileExists(atPath: ticket.stagedURL.path) {
                try fileManager.removeItem(at: ticket.stagedURL)
            }
            if fileManager.fileExists(atPath: ticket.destinationURL.path) {
                try fileManager.removeItem(at: ticket.destinationURL)
            }
        } catch {
            throw PortraitMediaError.storageUnavailable
        }
    }

    public func data(for asset: PortraitMediaAsset, verifyIntegrity: Bool = true) throws -> Data {
        do {
            let data = try Data(contentsOf: fileURL(for: asset.id), options: [.mappedIfSafe])
            if verifyIntegrity {
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == asset.sha256 else { throw PortraitMediaError.integrityMismatch }
            }
            return data
        } catch let error as PortraitMediaError {
            throw error
        } catch {
            throw PortraitMediaError.storageUnavailable
        }
    }

    public func remove(_ asset: PortraitMediaAsset) throws {
        try remove(id: asset.id)
    }

    public func remove(id: UUID) throws {
        let URL = fileURL(for: id)
        guard fileManager.fileExists(atPath: URL.path) else { return }
        do {
            try fileManager.removeItem(at: URL)
        } catch {
            throw PortraitMediaError.storageUnavailable
        }
    }

    /// Removes orphaned top-level cache files while leaving import/removal
    /// staging directories and unrecognized files untouched.
    public func removeCachedPortraits(except retainedIDs: Set<UUID>) throws -> Int {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return 0 }
        do {
            let URLs = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            var removed = 0
            for URL in URLs where URL.pathExtension.lowercased() == "jpg" {
                let values = try URL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true,
                      let id = UUID(uuidString: URL.deletingPathExtension().lastPathComponent),
                      !retainedIDs.contains(id) else { continue }
                try fileManager.removeItem(at: URL)
                removed += 1
            }
            return removed
        } catch {
            throw PortraitMediaError.storageUnavailable
        }
    }

    /// Moves a portrait out of its live location before metadata is changed. The caller can
    /// restore the file if the metadata transaction fails, or finalize it after the transaction
    /// commits, avoiding a live metadata row that points at a prematurely deleted JPEG.
    public func stageRemoval(_ asset: PortraitMediaAsset) throws -> PortraitRemovalTicket {
        let originalURL = fileURL(for: asset.id)
        guard fileManager.fileExists(atPath: originalURL.path) else {
            return PortraitRemovalTicket(originalURL: originalURL, stagedURL: nil)
        }
        let stagingDirectory = rootDirectory.appendingPathComponent("RemovalStaging", isDirectory: true)
        let stagedURL = stagingDirectory
            .appendingPathComponent("\(asset.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())")
            .appendingPathExtension("jpg")
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true,
                attributes: protectedDirectoryAttributes
            )
            try fileManager.moveItem(at: originalURL, to: stagedURL)
            try fileManager.setAttributes(protectedFileAttributes, ofItemAtPath: stagedURL.path)
            return PortraitRemovalTicket(originalURL: originalURL, stagedURL: stagedURL)
        } catch {
            throw PortraitMediaError.storageUnavailable
        }
    }

    public func restoreRemoval(_ ticket: PortraitRemovalTicket) throws {
        guard let stagedURL = ticket.stagedURL,
              fileManager.fileExists(atPath: stagedURL.path) else { return }
        guard !fileManager.fileExists(atPath: ticket.originalURL.path) else {
            throw PortraitMediaError.storageUnavailable
        }
        do {
            try fileManager.moveItem(at: stagedURL, to: ticket.originalURL)
            try fileManager.setAttributes(protectedFileAttributes, ofItemAtPath: ticket.originalURL.path)
        } catch {
            throw PortraitMediaError.storageUnavailable
        }
    }

    public func finalizeRemoval(_ ticket: PortraitRemovalTicket) throws {
        guard let stagedURL = ticket.stagedURL,
              fileManager.fileExists(atPath: stagedURL.path) else { return }
        do {
            try fileManager.removeItem(at: stagedURL)
        } catch {
            throw PortraitMediaError.storageUnavailable
        }
    }

    public func removeAll() throws {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
        do {
            try fileManager.removeItem(at: rootDirectory)
        } catch {
            throw PortraitMediaError.storageUnavailable
        }
    }

    public func fileURL(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("jpg")
    }

    private var protectedDirectoryAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        [:]
        #endif
    }

    private var protectedWriteOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUnlessOpen]
        #else
        [.atomic]
        #endif
    }

    private var protectedFileAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        [:]
        #endif
    }
}
