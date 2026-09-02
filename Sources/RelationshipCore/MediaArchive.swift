import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The inspectable, media-capable plaintext backup format. It is represented as
/// a document package so it can be written atomically by `FileDocument` without
/// introducing an unreviewed ZIP dependency. Password-encrypted `.relationshipvault`
/// envelopes remain a separate, release-gated format that requires reviewed Argon2id.
public struct RelationshipVaultManifest: Codable, Hashable, Sendable {
    public static let currentFormat = "private-relationship-notebook-media-archive"
    public static let currentFormatVersion = 1

    public struct EntityCounts: Codable, Hashable, Sendable {
        public var people: Int
        public var interactions: Int
        public var canonicalRecords: Int
        public var ownedProfileSnapshots: Int
        public var media: Int

        public init(
            people: Int,
            interactions: Int,
            canonicalRecords: Int,
            ownedProfileSnapshots: Int,
            media: Int
        ) {
            self.people = people
            self.interactions = interactions
            self.canonicalRecords = canonicalRecords
            self.ownedProfileSnapshots = ownedProfileSnapshots
            self.media = media
        }
    }

    public struct MediaEntry: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID { mediaID }
        public var mediaID: UUID
        public var personID: UUID
        public var relativePath: String
        public var sha256: String
        public var contentType: String
        public var byteCount: Int64
        public var metadataWasStripped: Bool

        public init(
            mediaID: UUID,
            personID: UUID,
            relativePath: String,
            sha256: String,
            contentType: String,
            byteCount: Int64,
            metadataWasStripped: Bool
        ) {
            self.mediaID = mediaID
            self.personID = personID
            self.relativePath = relativePath
            self.sha256 = sha256
            self.contentType = contentType
            self.byteCount = byteCount
            self.metadataWasStripped = metadataWasStripped
        }
    }

    public var format: String
    public var formatVersion: Int
    public var archiveID: UUID
    public var schemaVersion: Int
    public var createdAt: Date
    public var localeIdentifier: String
    public var encryption: String
    public var checksumAlgorithm: String
    public var dataRelativePath: String
    public var dataSHA256: String
    public var dataByteCount: Int64
    public var checksumFileRelativePath: String
    public var checksumFileSHA256: String
    public var uncompressedPayloadBytes: Int64
    public var entityCounts: EntityCounts
    public var media: [MediaEntry]

    public init(
        format: String = Self.currentFormat,
        formatVersion: Int = Self.currentFormatVersion,
        archiveID: UUID = UUID(),
        schemaVersion: Int,
        createdAt: Date,
        localeIdentifier: String,
        encryption: String = "none",
        checksumAlgorithm: String = "sha256",
        dataRelativePath: String = "data/notebook.json",
        dataSHA256: String,
        dataByteCount: Int64,
        checksumFileRelativePath: String = "checksums.sha256",
        checksumFileSHA256: String,
        uncompressedPayloadBytes: Int64,
        entityCounts: EntityCounts,
        media: [MediaEntry]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.archiveID = archiveID
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.localeIdentifier = localeIdentifier
        self.encryption = encryption
        self.checksumAlgorithm = checksumAlgorithm
        self.dataRelativePath = dataRelativePath
        self.dataSHA256 = dataSHA256
        self.dataByteCount = dataByteCount
        self.checksumFileRelativePath = checksumFileRelativePath
        self.checksumFileSHA256 = checksumFileSHA256
        self.uncompressedPayloadBytes = uncompressedPayloadBytes
        self.entityCounts = entityCounts
        self.media = media
    }
}

public struct RelationshipVaultPackageLimits: Codable, Hashable, Sendable {
    public var maximumManifestBytes: Int
    public var maximumNotebookBytes: Int
    public var maximumMediaFiles: Int
    public var maximumMediaFileBytes: Int
    public var maximumMediaPixels: Int64
    public var maximumTotalPayloadBytes: Int64

    public init(
        maximumManifestBytes: Int = 1_000_000,
        maximumNotebookBytes: Int = 50_000_000,
        maximumMediaFiles: Int = 100_000,
        maximumMediaFileBytes: Int = 30 * 1_024 * 1_024,
        maximumMediaPixels: Int64 = 80_000_000,
        maximumTotalPayloadBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
    ) {
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumNotebookBytes = maximumNotebookBytes
        self.maximumMediaFiles = maximumMediaFiles
        self.maximumMediaFileBytes = maximumMediaFileBytes
        self.maximumMediaPixels = maximumMediaPixels
        self.maximumTotalPayloadBytes = maximumTotalPayloadBytes
    }
}

public enum RelationshipVaultPackageError: LocalizedError, Equatable, Sendable {
    case invalidLimits
    case invalidPackageStructure
    case unsupportedFormat
    case unsupportedFormatVersion(Int)
    case unsupportedEncryption
    case unsupportedChecksumAlgorithm
    case manifestTooLarge
    case notebookTooLarge
    case tooManyMediaFiles
    case mediaFileTooLarge(UUID)
    case totalPayloadTooLarge
    case malformedManifest
    case malformedNotebook
    case invalidRelativePath
    case duplicateMediaIdentifier(UUID)
    case missingMediaMetadata(UUID)
    case missingMediaFile(UUID)
    case unexpectedMediaFile(String)
    case mediaPersonMissing(UUID)
    case contentTypeMismatch(UUID)
    case invalidMediaFile(UUID)
    case mediaPixelCountTooLarge(UUID)
    case byteCountMismatch(String)
    case checksumMismatch(String)
    case entityCountMismatch
    case schemaVersionMismatch
    case metadataNotSanitized(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidLimits:
            String(localized: "Media archive inspection limits are invalid.")
        case .invalidPackageStructure:
            String(localized: "The media archive has an unsafe or unsupported file structure.")
        case .unsupportedFormat:
            String(localized: "This is not a supported Keepsake media archive.")
        case .unsupportedFormatVersion(let version):
            String(localized: "Media archive format version \(version) is not supported.")
        case .unsupportedEncryption:
            String(localized: "This archive uses an encryption mode that this build cannot open.")
        case .unsupportedChecksumAlgorithm:
            String(localized: "This archive uses an unsupported checksum algorithm.")
        case .manifestTooLarge:
            String(localized: "The media archive manifest exceeds the safe inspection size.")
        case .notebookTooLarge:
            String(localized: "The notebook data in this archive exceeds the safe inspection size.")
        case .tooManyMediaFiles:
            String(localized: "The media archive contains too many files.")
        case .mediaFileTooLarge:
            String(localized: "A media file in this archive exceeds the safe import size.")
        case .totalPayloadTooLarge:
            String(localized: "The media archive exceeds the safe total import size.")
        case .malformedManifest:
            String(localized: "The media archive manifest is not valid.")
        case .malformedNotebook:
            String(localized: "The notebook data in this media archive is not valid.")
        case .invalidRelativePath:
            String(localized: "The media archive contains an unsafe relative path.")
        case .duplicateMediaIdentifier:
            String(localized: "The media archive repeats a media identifier.")
        case .missingMediaMetadata:
            String(localized: "A media file has no matching notebook metadata.")
        case .missingMediaFile:
            String(localized: "A portrait listed by this archive is missing.")
        case .unexpectedMediaFile(let name):
            String(localized: "The media archive contains an unexpected file: \(name)")
        case .mediaPersonMissing:
            String(localized: "A portrait references a person who is not present in the archive.")
        case .contentTypeMismatch:
            String(localized: "A portrait content type does not match its notebook metadata.")
        case .invalidMediaFile:
            String(localized: "A portrait file is not a readable JPEG image.")
        case .mediaPixelCountTooLarge:
            String(localized: "A portrait in this archive has too many pixels to import safely.")
        case .byteCountMismatch(let path):
            String(localized: "The recorded byte count does not match \(path).")
        case .checksumMismatch(let path):
            String(localized: "The integrity checksum does not match \(path).")
        case .entityCountMismatch:
            String(localized: "The archive entity counts do not match its notebook data.")
        case .schemaVersionMismatch:
            String(localized: "The archive manifest and notebook schema versions do not match.")
        case .metadataNotSanitized:
            String(localized: "A portrait is not marked as metadata-stripped and cannot be imported safely.")
        }
    }
}

/// A fully verified media archive. Callers must use this result—not unverified
/// wrapper bytes—when constructing an import preview or staging media.
public struct VerifiedRelationshipVaultPackage: Sendable {
    public var manifest: RelationshipVaultManifest
    public var archive: NotebookArchive
    public var archiveData: Data
    public var mediaData: [UUID: Data]

    public init(
        manifest: RelationshipVaultManifest,
        archive: NotebookArchive,
        archiveData: Data,
        mediaData: [UUID: Data]
    ) {
        self.manifest = manifest
        self.archive = archive
        self.archiveData = archiveData
        self.mediaData = mediaData
    }
}

public struct RelationshipVaultPackageCodec: Sendable {
    public var limits: RelationshipVaultPackageLimits

    public init(limits: RelationshipVaultPackageLimits = .init()) {
        self.limits = limits
    }

    public func makePackage(
        archive: NotebookArchive,
        mediaData: [UUID: Data],
        localeIdentifier: String = Locale.current.identifier
    ) throws -> VerifiedRelationshipVaultPackage {
        try validateLimits()
        let archiveData = try ArchiveCodec.encode(archive)
        let assets = archive.canonical?.portraitMedia ?? []
        let manifestMedia = try validateAndBuildMediaEntries(
            assets: assets,
            archivePeople: archive.people,
            mediaData: mediaData
        )
        let checksums = checksumFileData(
            archiveData: archiveData,
            mediaEntries: manifestMedia,
            mediaData: mediaData
        )
        let payloadBytes = try checkedPayloadBytes(
            archiveData.count,
            checksums.count,
            mediaData.values.map(\.count)
        )
        let manifest = RelationshipVaultManifest(
            schemaVersion: archive.schemaVersion,
            createdAt: archive.exportedAt,
            localeIdentifier: localeIdentifier,
            dataSHA256: digest(archiveData),
            dataByteCount: Int64(archiveData.count),
            checksumFileSHA256: digest(checksums),
            uncompressedPayloadBytes: payloadBytes,
            entityCounts: entityCounts(for: archive, mediaCount: manifestMedia.count),
            media: manifestMedia
        )
        try validateBoundedSizes(manifest: manifest, archiveData: archiveData, mediaData: mediaData)
        return VerifiedRelationshipVaultPackage(
            manifest: manifest,
            archive: archive,
            archiveData: archiveData,
            mediaData: mediaData
        )
    }

    public func fileWrapper(for package: VerifiedRelationshipVaultPackage) throws -> FileWrapper {
        let manifestData = try encodeManifest(package.manifest)
        let checksums = checksumFileData(
            archiveData: package.archiveData,
            mediaEntries: package.manifest.media,
            mediaData: package.mediaData
        )
        guard digest(checksums) == package.manifest.checksumFileSHA256 else {
            throw RelationshipVaultPackageError.checksumMismatch("checksums.sha256")
        }

        var mediaWrappers: [String: FileWrapper] = [:]
        for entry in package.manifest.media {
            guard let data = package.mediaData[entry.mediaID] else {
                throw RelationshipVaultPackageError.missingMediaFile(entry.mediaID)
            }
            mediaWrappers[fileName(for: entry.mediaID)] = FileWrapper(regularFileWithContents: data)
        }
        return FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: manifestData),
            "data": FileWrapper(directoryWithFileWrappers: [
                "notebook.json": FileWrapper(regularFileWithContents: package.archiveData)
            ]),
            "media": FileWrapper(directoryWithFileWrappers: mediaWrappers),
            "checksums.sha256": FileWrapper(regularFileWithContents: checksums)
        ])
    }

    /// Performs a file-system metadata preflight before `FileWrapper` loads
    /// regular-file contents. Directory packages are uncompressed, so bounded
    /// regular-file sizes also bound the allocation performed by inspection.
    public func inspect(
        at packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> VerifiedRelationshipVaultPackage {
        try validateLimits()
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]
        let rootValues = try packageURL.resourceValues(forKeys: resourceKeys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }
        let rootItems = try fileManager.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )
        let rootByName = Dictionary(
            rootItems.map { ($0.lastPathComponent, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard rootByName.count == rootItems.count,
              Set(rootByName.keys) == ["manifest.json", "data", "media", "checksums.sha256"],
              let manifestURL = rootByName["manifest.json"],
              let dataDirectoryURL = rootByName["data"],
              let mediaDirectoryURL = rootByName["media"],
              let checksumURL = rootByName["checksums.sha256"] else {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }

        let manifestBytes = try preflightRegularFileSize(manifestURL, keys: resourceKeys)
        guard manifestBytes <= limits.maximumManifestBytes else {
            throw RelationshipVaultPackageError.manifestTooLarge
        }
        let checksumBytes = try preflightRegularFileSize(checksumURL, keys: resourceKeys)
        guard checksumBytes <= limits.maximumManifestBytes else {
            throw RelationshipVaultPackageError.manifestTooLarge
        }

        let dataValues = try dataDirectoryURL.resourceValues(forKeys: resourceKeys)
        guard dataValues.isDirectory == true, dataValues.isSymbolicLink != true else {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }
        let dataItems = try fileManager.contentsOfDirectory(
            at: dataDirectoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )
        guard dataItems.count == 1, dataItems[0].lastPathComponent == "notebook.json" else {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }
        let notebookBytes = try preflightRegularFileSize(dataItems[0], keys: resourceKeys)
        guard notebookBytes <= limits.maximumNotebookBytes else {
            throw RelationshipVaultPackageError.notebookTooLarge
        }

        let mediaValues = try mediaDirectoryURL.resourceValues(forKeys: resourceKeys)
        guard mediaValues.isDirectory == true, mediaValues.isSymbolicLink != true else {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }
        let mediaItems = try fileManager.contentsOfDirectory(
            at: mediaDirectoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )
        guard mediaItems.count <= limits.maximumMediaFiles else {
            throw RelationshipVaultPackageError.tooManyMediaFiles
        }
        var totalBytes = Int64(notebookBytes) + Int64(checksumBytes)
        for mediaURL in mediaItems {
            let size = try preflightRegularFileSize(mediaURL, keys: resourceKeys)
            guard size <= limits.maximumMediaFileBytes else {
                let stem = mediaURL.deletingPathExtension().lastPathComponent
                guard let mediaID = UUID(uuidString: stem) else {
                    throw RelationshipVaultPackageError.unexpectedMediaFile(
                        mediaURL.lastPathComponent
                    )
                }
                throw RelationshipVaultPackageError.mediaFileTooLarge(mediaID)
            }
            let addition = totalBytes.addingReportingOverflow(Int64(size))
            guard !addition.overflow else {
                throw RelationshipVaultPackageError.totalPayloadTooLarge
            }
            totalBytes = addition.partialValue
        }
        guard totalBytes <= limits.maximumTotalPayloadBytes else {
            throw RelationshipVaultPackageError.totalPayloadTooLarge
        }

        do {
            return try inspect(FileWrapper(url: packageURL, options: .immediate))
        } catch let error as RelationshipVaultPackageError {
            throw error
        } catch {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }
    }

    public func inspect(_ root: FileWrapper) throws -> VerifiedRelationshipVaultPackage {
        try validateLimits()
        guard root.isDirectory, !root.isSymbolicLink,
              let rootFiles = root.fileWrappers,
              Set(rootFiles.keys) == ["manifest.json", "data", "media", "checksums.sha256"] else {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }
        let manifestData = try regularData(rootFiles["manifest.json"])
        guard manifestData.count <= limits.maximumManifestBytes else {
            throw RelationshipVaultPackageError.manifestTooLarge
        }
        let manifest = try decodeManifest(manifestData)
        try validateManifestHeader(manifest)

        guard let dataDirectory = rootFiles["data"], dataDirectory.isDirectory,
              !dataDirectory.isSymbolicLink,
              let dataFiles = dataDirectory.fileWrappers,
              Set(dataFiles.keys) == ["notebook.json"] else {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }
        let archiveData = try regularData(dataFiles["notebook.json"])
        guard archiveData.count <= limits.maximumNotebookBytes else {
            throw RelationshipVaultPackageError.notebookTooLarge
        }
        guard Int64(archiveData.count) == manifest.dataByteCount else {
            throw RelationshipVaultPackageError.byteCountMismatch(manifest.dataRelativePath)
        }
        guard digest(archiveData) == manifest.dataSHA256 else {
            throw RelationshipVaultPackageError.checksumMismatch(manifest.dataRelativePath)
        }

        let archive: NotebookArchive
        do {
            archive = try ArchiveCodec.decode(archiveData)
        } catch {
            throw RelationshipVaultPackageError.malformedNotebook
        }
        guard archive.schemaVersion == manifest.schemaVersion else {
            throw RelationshipVaultPackageError.schemaVersionMismatch
        }
        guard manifest.entityCounts == entityCounts(for: archive, mediaCount: manifest.media.count) else {
            throw RelationshipVaultPackageError.entityCountMismatch
        }

        guard let mediaDirectory = rootFiles["media"], mediaDirectory.isDirectory,
              !mediaDirectory.isSymbolicLink,
              let mediaFiles = mediaDirectory.fileWrappers else {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }
        guard manifest.media.count <= limits.maximumMediaFiles,
              mediaFiles.count <= limits.maximumMediaFiles else {
            throw RelationshipVaultPackageError.tooManyMediaFiles
        }

        let manifestByID = try uniqueManifestEntries(manifest.media)
        let assets = archive.canonical?.portraitMedia ?? []
        let assetByID = try uniqueAssets(assets)
        guard Set(manifestByID.keys) == Set(assetByID.keys) else {
            if let missing = Set(assetByID.keys).subtracting(manifestByID.keys).first {
                throw RelationshipVaultPackageError.missingMediaFile(missing)
            }
            let extra = Set(manifestByID.keys).subtracting(assetByID.keys).first!
            throw RelationshipVaultPackageError.missingMediaMetadata(extra)
        }
        let expectedFileNames = Set(manifest.media.map { fileName(for: $0.mediaID) })
        if let extra = Set(mediaFiles.keys).subtracting(expectedFileNames).first {
            throw RelationshipVaultPackageError.unexpectedMediaFile(extra)
        }
        if let missingName = expectedFileNames.subtracting(mediaFiles.keys).first,
           let missingID = UUID(uuidString: String(missingName.dropLast(4))) {
            throw RelationshipVaultPackageError.missingMediaFile(missingID)
        }
        guard Set(mediaFiles.keys) == expectedFileNames else {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }

        let peopleIDs = Set(archive.people.map(\.id))
        var decodedMedia: [UUID: Data] = [:]
        for entry in manifest.media {
            try validateRelativePath(entry.relativePath, mediaID: entry.mediaID)
            guard entry.metadataWasStripped else {
                throw RelationshipVaultPackageError.metadataNotSanitized(entry.mediaID)
            }
            guard peopleIDs.contains(entry.personID) else {
                throw RelationshipVaultPackageError.mediaPersonMissing(entry.personID)
            }
            guard let asset = assetByID[entry.mediaID] else {
                throw RelationshipVaultPackageError.missingMediaMetadata(entry.mediaID)
            }
            try validate(entry: entry, matches: asset)
            let data = try regularData(mediaFiles[fileName(for: entry.mediaID)])
            guard data.count <= limits.maximumMediaFileBytes else {
                throw RelationshipVaultPackageError.mediaFileTooLarge(entry.mediaID)
            }
            guard Int64(data.count) == entry.byteCount else {
                throw RelationshipVaultPackageError.byteCountMismatch(entry.relativePath)
            }
            guard digest(data) == entry.sha256 else {
                throw RelationshipVaultPackageError.checksumMismatch(entry.relativePath)
            }
            try validateJPEGBytes(data, mediaID: entry.mediaID)
            decodedMedia[entry.mediaID] = data
        }

        let checksumData = try regularData(rootFiles["checksums.sha256"])
        guard checksumData.count <= limits.maximumManifestBytes else {
            throw RelationshipVaultPackageError.manifestTooLarge
        }
        guard digest(checksumData) == manifest.checksumFileSHA256 else {
            throw RelationshipVaultPackageError.checksumMismatch(manifest.checksumFileRelativePath)
        }
        let expectedChecksums = checksumFileData(
            archiveData: archiveData,
            mediaEntries: manifest.media,
            mediaData: decodedMedia
        )
        guard checksumData == expectedChecksums else {
            throw RelationshipVaultPackageError.checksumMismatch(manifest.checksumFileRelativePath)
        }
        let payloadBytes = try checkedPayloadBytes(
            archiveData.count,
            checksumData.count,
            decodedMedia.values.map(\.count)
        )
        guard payloadBytes == manifest.uncompressedPayloadBytes else {
            throw RelationshipVaultPackageError.byteCountMismatch(String(localized: "archive payload"))
        }
        guard payloadBytes <= limits.maximumTotalPayloadBytes else {
            throw RelationshipVaultPackageError.totalPayloadTooLarge
        }
        return VerifiedRelationshipVaultPackage(
            manifest: manifest,
            archive: archive,
            archiveData: archiveData,
            mediaData: decodedMedia
        )
    }

    private func validateAndBuildMediaEntries(
        assets: [PortraitMediaAsset],
        archivePeople: [Person],
        mediaData: [UUID: Data]
    ) throws -> [RelationshipVaultManifest.MediaEntry] {
        let assetByID = try uniqueAssets(assets)
        guard Set(assetByID.keys) == Set(mediaData.keys) else {
            if let missing = Set(assetByID.keys).subtracting(mediaData.keys).first {
                throw RelationshipVaultPackageError.missingMediaFile(missing)
            }
            let extra = Set(mediaData.keys).subtracting(assetByID.keys).first!
            throw RelationshipVaultPackageError.missingMediaMetadata(extra)
        }
        let peopleIDs = Set(archivePeople.map(\.id))
        return try assets.sorted { $0.id.uuidString < $1.id.uuidString }.map { asset in
            guard peopleIDs.contains(asset.personID) else {
                throw RelationshipVaultPackageError.mediaPersonMissing(asset.personID)
            }
            guard asset.metadataWasStripped else {
                throw RelationshipVaultPackageError.metadataNotSanitized(asset.id)
            }
            guard isJPEGContentType(asset.contentType) else {
                throw RelationshipVaultPackageError.contentTypeMismatch(asset.id)
            }
            guard let data = mediaData[asset.id] else {
                throw RelationshipVaultPackageError.missingMediaFile(asset.id)
            }
            try validateJPEGBytes(data, mediaID: asset.id)
            guard Int64(data.count) == asset.byteCount else {
                throw RelationshipVaultPackageError.byteCountMismatch("media/\(fileName(for: asset.id))")
            }
            let checksum = digest(data)
            guard checksum == asset.sha256.lowercased() else {
                throw RelationshipVaultPackageError.checksumMismatch("media/\(fileName(for: asset.id))")
            }
            return RelationshipVaultManifest.MediaEntry(
                mediaID: asset.id,
                personID: asset.personID,
                relativePath: "media/\(fileName(for: asset.id))",
                sha256: checksum,
                contentType: asset.contentType,
                byteCount: Int64(data.count),
                metadataWasStripped: asset.metadataWasStripped
            )
        }
    }

    private func validateManifestHeader(_ manifest: RelationshipVaultManifest) throws {
        guard manifest.format == RelationshipVaultManifest.currentFormat else {
            throw RelationshipVaultPackageError.unsupportedFormat
        }
        guard manifest.formatVersion == RelationshipVaultManifest.currentFormatVersion else {
            throw RelationshipVaultPackageError.unsupportedFormatVersion(manifest.formatVersion)
        }
        guard manifest.encryption == "none" else {
            throw RelationshipVaultPackageError.unsupportedEncryption
        }
        guard manifest.checksumAlgorithm == "sha256" else {
            throw RelationshipVaultPackageError.unsupportedChecksumAlgorithm
        }
        guard manifest.dataRelativePath == "data/notebook.json",
              manifest.checksumFileRelativePath == "checksums.sha256" else {
            throw RelationshipVaultPackageError.invalidRelativePath
        }
    }

    private func validateBoundedSizes(
        manifest: RelationshipVaultManifest,
        archiveData: Data,
        mediaData: [UUID: Data]
    ) throws {
        guard archiveData.count <= limits.maximumNotebookBytes else {
            throw RelationshipVaultPackageError.notebookTooLarge
        }
        guard manifest.media.count <= limits.maximumMediaFiles else {
            throw RelationshipVaultPackageError.tooManyMediaFiles
        }
        for (id, data) in mediaData where data.count > limits.maximumMediaFileBytes {
            throw RelationshipVaultPackageError.mediaFileTooLarge(id)
        }
        guard manifest.uncompressedPayloadBytes <= limits.maximumTotalPayloadBytes else {
            throw RelationshipVaultPackageError.totalPayloadTooLarge
        }
        guard try encodeManifest(manifest).count <= limits.maximumManifestBytes else {
            throw RelationshipVaultPackageError.manifestTooLarge
        }
    }

    private func uniqueManifestEntries(
        _ entries: [RelationshipVaultManifest.MediaEntry]
    ) throws -> [UUID: RelationshipVaultManifest.MediaEntry] {
        var result: [UUID: RelationshipVaultManifest.MediaEntry] = [:]
        for entry in entries {
            guard result.updateValue(entry, forKey: entry.mediaID) == nil else {
                throw RelationshipVaultPackageError.duplicateMediaIdentifier(entry.mediaID)
            }
        }
        return result
    }

    private func uniqueAssets(_ assets: [PortraitMediaAsset]) throws -> [UUID: PortraitMediaAsset] {
        var result: [UUID: PortraitMediaAsset] = [:]
        for asset in assets {
            guard result.updateValue(asset, forKey: asset.id) == nil else {
                throw RelationshipVaultPackageError.duplicateMediaIdentifier(asset.id)
            }
        }
        return result
    }

    private func validate(
        entry: RelationshipVaultManifest.MediaEntry,
        matches asset: PortraitMediaAsset
    ) throws {
        guard entry.personID == asset.personID,
              entry.sha256.lowercased() == asset.sha256.lowercased(),
              entry.byteCount == asset.byteCount,
              entry.metadataWasStripped == asset.metadataWasStripped else {
            throw RelationshipVaultPackageError.missingMediaMetadata(entry.mediaID)
        }
        guard isJPEGContentType(entry.contentType), entry.contentType == asset.contentType else {
            throw RelationshipVaultPackageError.contentTypeMismatch(entry.mediaID)
        }
    }

    private func validateRelativePath(_ path: String, mediaID: UUID) throws {
        guard path == "media/\(fileName(for: mediaID))",
              !path.contains(".."), !path.hasPrefix("/"), !path.contains("\\") else {
            throw RelationshipVaultPackageError.invalidRelativePath
        }
    }

    private func regularData(_ wrapper: FileWrapper?) throws -> Data {
        guard let wrapper, wrapper.isRegularFile, !wrapper.isSymbolicLink,
              let data = wrapper.regularFileContents else {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }
        return data
    }

    private func encodeManifest(_ manifest: RelationshipVaultManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private func decodeManifest(_ data: Data) throws -> RelationshipVaultManifest {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(RelationshipVaultManifest.self, from: data)
        } catch {
            throw RelationshipVaultPackageError.malformedManifest
        }
    }

    private func checksumFileData(
        archiveData: Data,
        mediaEntries: [RelationshipVaultManifest.MediaEntry],
        mediaData: [UUID: Data]
    ) -> Data {
        var lines = ["\(digest(archiveData))  data/notebook.json"]
        lines += mediaEntries.sorted { $0.relativePath < $1.relativePath }.compactMap { entry in
            guard let data = mediaData[entry.mediaID] else { return nil }
            return "\(digest(data))  \(entry.relativePath)"
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func entityCounts(
        for archive: NotebookArchive,
        mediaCount: Int
    ) -> RelationshipVaultManifest.EntityCounts {
        var canonicalCount = 0
        if let canonical = archive.canonical {
            canonicalCount += canonical.contexts.count
            canonicalCount += canonical.cohortSchemes.count
            canonicalCount += canonical.cohorts.count
            canonicalCount += canonical.memberships.count
            canonicalCount += canonical.cohortAssignments.count
            canonicalCount += canonical.roleDefinitions.count
            canonicalCount += canonical.roleAssignments.count
            canonicalCount += canonical.education.count
            canonicalCount += canonical.assertions.count
            canonicalCount += canonical.sources.count
            canonicalCount += canonical.artifactUnits?.count ?? 0
            canonicalCount += canonical.portraitMedia?.count ?? 0
            canonicalCount += canonical.evidence.count
            canonicalCount += canonical.reminders.count
            canonicalCount += canonical.commitments.count
            canonicalCount += canonical.savedViews.count
            canonicalCount += canonical.attributeDefinitions.count
            canonicalCount += canonical.textImportReviews.count
            canonicalCount += canonical.personMergeEvents.count
        }
        return RelationshipVaultManifest.EntityCounts(
            people: archive.people.count,
            interactions: archive.interactions.count,
            canonicalRecords: canonicalCount,
            ownedProfileSnapshots: archive.ownedProfileSnapshots?.count ?? 0,
            media: mediaCount
        )
    }

    private func checkedPayloadBytes(
        _ archiveBytes: Int,
        _ checksumBytes: Int,
        _ mediaBytes: [Int]
    ) throws -> Int64 {
        var total = Int64(archiveBytes) + Int64(checksumBytes)
        for count in mediaBytes {
            let addition = total.addingReportingOverflow(Int64(count))
            guard !addition.overflow else {
                throw RelationshipVaultPackageError.totalPayloadTooLarge
            }
            total = addition.partialValue
        }
        return total
    }

    private func validateLimits() throws {
        guard limits.maximumManifestBytes > 0,
              limits.maximumNotebookBytes > 0,
              limits.maximumMediaFiles >= 0,
              limits.maximumMediaFileBytes > 0,
              limits.maximumMediaPixels > 0,
              limits.maximumTotalPayloadBytes > 0 else {
            throw RelationshipVaultPackageError.invalidLimits
        }
    }

    private func preflightRegularFileSize(
        _ URL: URL,
        keys: Set<URLResourceKey>
    ) throws -> Int {
        let values = try URL.resourceValues(forKeys: keys)
        guard values.isRegularFile == true,
              values.isDirectory != true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0 else {
            throw RelationshipVaultPackageError.invalidPackageStructure
        }
        return size
    }

    private func fileName(for id: UUID) -> String {
        "\(id.uuidString.lowercased()).jpg"
    }

    private func isJPEGContentType(_ value: String) -> Bool {
        value == "public.jpeg" || value == "image/jpeg"
    }

    private func validateJPEGBytes(_ data: Data, mediaID: UUID) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String)?.conforms(to: .jpeg) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw RelationshipVaultPackageError.invalidMediaFile(mediaID)
        }
        let pixels = width.int64Value.multipliedReportingOverflow(by: height.int64Value)
        guard !pixels.overflow, pixels.partialValue <= limits.maximumMediaPixels else {
            throw RelationshipVaultPackageError.mediaPixelCountTooLarge(mediaID)
        }

        // A package's metadataWasStripped flag is only a claim until the
        // bytes agree. Reject private source metadata at both archive creation
        // and inspection so crafted packages cannot smuggle location, camera,
        // or embedded-comment data into protected portrait storage.
        let allowedMetadataContainers: Set<CFString> = [
            kCGImagePropertyExifDictionary,
            kCGImagePropertyJFIFDictionary
        ]
        for (key, value) in properties where value is NSDictionary {
            guard allowedMetadataContainers.contains(key) else {
                throw RelationshipVaultPackageError.metadataNotSanitized(mediaID)
            }
        }

        // ImageIO emits pixel dimensions in an otherwise empty EXIF container
        // when it creates a fresh JPEG. Those encoding facts are harmless; all
        // source EXIF fields (timestamps, camera details, comments, and so on)
        // must be absent.
        if let rawExif = properties[kCGImagePropertyExifDictionary] {
            guard let exif = rawExif as? [CFString: Any] else {
                throw RelationshipVaultPackageError.metadataNotSanitized(mediaID)
            }
            let allowedExifKeys: Set<CFString> = [
                kCGImagePropertyExifPixelXDimension,
                kCGImagePropertyExifPixelYDimension,
                kCGImagePropertyExifColorSpace,
                kCGImagePropertyExifComponentsConfiguration
            ]
            guard exif.keys.allSatisfy(allowedExifKeys.contains) else {
                throw RelationshipVaultPackageError.metadataNotSanitized(mediaID)
            }
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
