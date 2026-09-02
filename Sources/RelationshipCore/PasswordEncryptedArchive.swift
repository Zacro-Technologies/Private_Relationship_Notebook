import Clibsodium
import CryptoKit
import Darwin
import Foundation
import Security
import ZIPFoundation

/// Limits that are checked before attacker-controlled lengths or Argon2
/// parameters can allocate memory.
public struct PasswordEncryptedArchiveLimits: Hashable, Sendable {
    public var maximumHeaderBytes: Int
    public var maximumEncryptedBytes: Int64
    public var maximumZIPBytes: Int64
    public var maximumMaterializedZIPBytes: Int64
    public var maximumPasswordUTF8Bytes: Int

    public init(
        maximumHeaderBytes: Int = 16 * 1_024,
        maximumEncryptedBytes: Int64 = 11 * 1_024 * 1_024 * 1_024,
        maximumZIPBytes: Int64 = 10 * 1_024 * 1_024 * 1_024 + 128 * 1_024 * 1_024,
        maximumMaterializedZIPBytes: Int64 = 512 * 1_024 * 1_024,
        maximumPasswordUTF8Bytes: Int = 1_024
    ) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumEncryptedBytes = maximumEncryptedBytes
        self.maximumZIPBytes = maximumZIPBytes
        self.maximumMaterializedZIPBytes = maximumMaterializedZIPBytes
        self.maximumPasswordUTF8Bytes = maximumPasswordUTF8Bytes
    }

    /// Early ciphertext bound for the current file-backed, materialized inner
    /// package implementation. The version-one envelope itself can support a
    /// larger configured limit once the inner package model is fully streaming.
    public var maximumAcceptedEncryptedBytes: Int64 {
        let chunkBytes: Int64 = 1_048_576
        let chunks: Int64
        if maximumMaterializedZIPBytes > 0 {
            chunks = maximumMaterializedZIPBytes / chunkBytes
                + (maximumMaterializedZIPBytes % chunkBytes == 0 ? 0 : 1)
        } else {
            chunks = 0
        }
        let recordOverhead = chunks.multipliedReportingOverflow(by: 25)
        let fixedOverhead = Int64(maximumHeaderBytes).addingReportingOverflow(256)
        guard !recordOverhead.overflow, !fixedOverhead.overflow else {
            return maximumEncryptedBytes
        }
        let withRecords = maximumMaterializedZIPBytes.addingReportingOverflow(
            recordOverhead.partialValue
        )
        guard !withRecords.overflow else { return maximumEncryptedBytes }
        let calculated = withRecords.partialValue.addingReportingOverflow(
            fixedOverhead.partialValue
        )
        guard !calculated.overflow else { return maximumEncryptedBytes }
        return min(maximumEncryptedBytes, calculated.partialValue)
    }
}

public enum PasswordEncryptedArchiveError: LocalizedError, Equatable, Sendable {
    case passwordTooShort
    case passwordTooLong
    case cannotCreateArchive
    case cannotOpenArchive
    case unsupportedVersion(Int)
    case unsafeParameters
    case archiveTooLarge
    case insufficientTemporaryStorage
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .passwordTooShort:
            String(localized: "Use a password with at least 12 characters.")
        case .passwordTooLong:
            String(localized: "The archive password is too long.")
        case .cannotCreateArchive:
            String(localized: "Keepsake could not create the encrypted archive.")
        case .cannotOpenArchive:
            String(localized: "The password is incorrect or the encrypted archive is damaged.")
        case .unsupportedVersion(let version):
            String(localized: "Encrypted archive version \(version) is not supported.")
        case .unsafeParameters:
            String(localized: "The encrypted archive requests unsafe password-derivation parameters.")
        case .archiveTooLarge:
            String(localized: "The encrypted archive exceeds the safe size limit.")
        case .insufficientTemporaryStorage:
            String(localized: "There is not enough protected temporary storage to process this archive.")
        case .cancelled:
            String(localized: "Encrypted archive processing was cancelled.")
        }
    }
}

public enum PasswordEncryptedArchivePasswordPolicy {
    public static let minimumCharacterCount = 12

    public static func validateForExport(
        _ password: String,
        maximumUTF8Bytes: Int = 1_024
    ) throws {
        let normalized = password.precomposedStringWithCanonicalMapping
        guard normalized.count >= minimumCharacterCount else {
            throw PasswordEncryptedArchiveError.passwordTooShort
        }
        guard normalized.utf8.count <= maximumUTF8Bytes else {
            throw PasswordEncryptedArchiveError.passwordTooLong
        }
    }
}

struct PasswordEncryptedArchiveKDF: Codable, Hashable, Sendable {
    var algorithm: String
    var version: Int
    var profile: String
    var saltBase64: String
    var memoryKiB: Int
    var iterations: Int
    var parallelism: Int
    var outputBytes: Int
}

struct PasswordEncryptedArchiveKeyWrap: Codable, Hashable, Sendable {
    var algorithm: String
    var nonceBase64: String
    var tagBytes: Int
    var wrappedKeyBytes: Int
}

struct PasswordEncryptedArchiveContent: Codable, Hashable, Sendable {
    var algorithm: String
    var payloadFormat: String
    var chunkBytes: Int
    var noncePrefixBase64: String
    var counterEncoding: String
    var terminalCounter: UInt32
    var tagBytes: Int
    var digestAlgorithm: String
}

struct PasswordEncryptedArchiveHeader: Codable, Hashable, Sendable {
    static let format = "private-relationship-notebook-encrypted-archive"
    static let currentVersion = 1
    static let passwordEncoding = "utf8-nfc"
    static let kdfProfile = "argon2id13-m64-t3-p1-v1"
    static let payloadFormat = "zip+relationshipvault-v1"

    var format: String
    var formatVersion: Int
    var archiveID: UUID
    var passwordEncoding: String
    var kdf: PasswordEncryptedArchiveKDF
    var keyWrap: PasswordEncryptedArchiveKeyWrap
    var content: PasswordEncryptedArchiveContent
}

struct Argon2idArchiveKeyDeriver: Sendable {
    func deriveKey(
        password: String,
        salt: Data,
        memoryKiB: Int,
        iterations: Int,
        outputBytes: Int,
        maximumPasswordBytes: Int
    ) throws -> Data {
        let normalized = password.precomposedStringWithCanonicalMapping
        var passwordBytes = Array(normalized.utf8)
        guard !passwordBytes.isEmpty,
              passwordBytes.count <= maximumPasswordBytes else {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        guard salt.count == 16, outputBytes == 32,
              memoryKiB == 65_536, iterations == 3 else {
            throw PasswordEncryptedArchiveError.unsafeParameters
        }
        guard sodium_init() >= 0 else {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }

        var output = [UInt8](repeating: 0, count: outputBytes)
        defer {
            passwordBytes.withUnsafeMutableBytes { bytes in
                if let address = bytes.baseAddress {
                    sodium_memzero(address, bytes.count)
                }
            }
        }
        let passwordByteCount = passwordBytes.count
        let status: Int32 = output.withUnsafeMutableBytes { outputBuffer in
            guard let outputAddress = outputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return -1
            }
            return passwordBytes.withUnsafeBytes { passwordBuffer in
                guard let passwordAddress = passwordBuffer.bindMemory(to: Int8.self).baseAddress else {
                    return -1
                }
                return salt.withUnsafeBytes { saltBuffer in
                    guard let saltAddress = saltBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return -1
                    }
                    return crypto_pwhash(
                        outputAddress,
                        UInt64(outputBytes),
                        passwordAddress,
                        UInt64(passwordByteCount),
                        saltAddress,
                        UInt64(iterations),
                        size_t(memoryKiB * 1_024),
                        crypto_pwhash_alg_argon2id13()
                    )
                }
            }
        }
        guard status == 0 else {
            output.withUnsafeMutableBytes { bytes in
                if let address = bytes.baseAddress { sodium_memzero(address, bytes.count) }
            }
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        let result = Data(output)
        output.withUnsafeMutableBytes { bytes in
            if let address = bytes.baseAddress { sodium_memzero(address, bytes.count) }
        }
        return result
    }
}

/// Version-one Argon2id/AES-256-GCM envelope for a ZIP representation of the
/// already validated `.relationshipvault` package.
public struct PasswordEncryptedRelationshipVaultCodec: Sendable {
    public static let magic = Data("KRVLTENC".utf8)
    public static let currentVersion: UInt16 = 1
    private static let temporaryDirectoryPrefix = "Keepsake-Encrypted-"

    private static let chunkRecord: UInt8 = 1
    private static let terminalRecord: UInt8 = 255
    private static let terminalIndex = UInt32.max
    private static let chunkBytes = 1_048_576
    private static let tagBytes = 16
    private static let wrappedKeyBytes = 48
    private static let terminalPlaintextBytes = 48

    public var limits: PasswordEncryptedArchiveLimits
    public var packageLimits: RelationshipVaultPackageLimits

    public init(
        limits: PasswordEncryptedArchiveLimits = .init(),
        packageLimits: RelationshipVaultPackageLimits = .init()
    ) {
        self.limits = limits
        self.packageLimits = packageLimits
    }

    /// Removes protected plaintext workspaces left by a prior process that
    /// terminated before its normal `defer` cleanup ran. Call once at launch,
    /// before starting any archive operation in the current process.
    public static func removeStaleProtectedTemporaryFiles(
        fileManager: FileManager = .default
    ) {
        let temporaryRoot = fileManager.temporaryDirectory
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return }

        let currentProcess = ProcessInfo.processInfo.processIdentifier
        for candidate in candidates
        where candidate.lastPathComponent.hasPrefix(temporaryDirectoryPrefix) {
            let suffix = candidate.lastPathComponent.dropFirst(temporaryDirectoryPrefix.count)
            let encodedProcess = suffix.prefix { $0 != "-" }
            if let process = Int32(encodedProcess) {
                if process == currentProcess || processIsRunning(process) {
                    continue
                }
            }
            guard let values = try? candidate.resourceValues(forKeys: keys),
                  values.isDirectory == true || values.isSymbolicLink == true else {
                continue
            }
            try? fileManager.removeItem(at: candidate)
        }
    }

    public func looksLikeEncryptedArchive(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: Self.magic.count)) == Self.magic
    }

    public func encrypt(
        package: VerifiedRelationshipVaultPackage,
        password: String,
        to outputURL: URL
    ) throws {
        try validateLimits()
        try PasswordEncryptedArchivePasswordPolicy.validateForExport(
            password,
            maximumUTF8Bytes: limits.maximumPasswordUTF8Bytes
        )
        do {
            try Task.checkCancellation()
        } catch {
            throw PasswordEncryptedArchiveError.cancelled
        }

        let workspace: URL
        do {
            workspace = try makeProtectedTemporaryDirectory()
        } catch {
            throw PasswordEncryptedArchiveError.cannotCreateArchive
        }
        defer { try? FileManager.default.removeItem(at: workspace) }
        let zipURL = workspace.appendingPathComponent("payload.zip", isDirectory: false)
        let stagedOutputURL = workspace.appendingPathComponent("encrypted.partial", isDirectory: false)

        do {
            let packageCodec = RelationshipVaultPackageCodec(limits: packageLimits)
            let verified = try packageCodec.inspect(packageCodec.fileWrapper(for: package))
            try ensureTemporaryCapacity(
                requiredBytes: try estimatedWorkspaceBytes(for: verified),
                at: workspace
            )
            try PlaintextRelationshipVaultZIPCodec(limits: packageLimits).write(
                package: verified,
                to: zipURL
            )
            try encryptZIP(
                at: zipURL,
                package: verified,
                password: password,
                to: stagedOutputURL
            )
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                throw PasswordEncryptedArchiveError.cannotCreateArchive
            }
            try FileManager.default.moveItem(at: stagedOutputURL, to: outputURL)
        } catch is CancellationError {
            throw PasswordEncryptedArchiveError.cancelled
        } catch let error as PasswordEncryptedArchiveError {
            switch error {
            case .archiveTooLarge, .insufficientTemporaryStorage, .cancelled:
                throw error
            default:
                throw PasswordEncryptedArchiveError.cannotCreateArchive
            }
        } catch {
            throw PasswordEncryptedArchiveError.cannotCreateArchive
        }
    }

    public func decrypt(
        at encryptedURL: URL,
        password: String
    ) throws -> VerifiedRelationshipVaultPackage {
        try validateLimits()
        do {
            try Task.checkCancellation()
        } catch {
            throw PasswordEncryptedArchiveError.cancelled
        }
        let workspace: URL
        do {
            workspace = try makeProtectedTemporaryDirectory()
        } catch {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        defer { try? FileManager.default.removeItem(at: workspace) }
        let zipURL = workspace.appendingPathComponent("authenticated-payload.zip")

        do {
            let archiveID = try decryptEnvelope(
                at: encryptedURL,
                password: password,
                to: zipURL
            )
            try Task.checkCancellation()
            let package = try PlaintextRelationshipVaultZIPCodec(limits: packageLimits)
                .inspect(at: zipURL)
            guard package.manifest.archiveID == archiveID else {
                throw PasswordEncryptedArchiveError.cannotOpenArchive
            }
            return package
        } catch is CancellationError {
            throw PasswordEncryptedArchiveError.cancelled
        } catch let error as PasswordEncryptedArchiveError {
            // A malformed or unsupported envelope and an authentication failure
            // intentionally share one user-visible result. A bounded size
            // rejection remains actionable without revealing a password oracle.
            switch error {
            case .unsafeParameters, .unsupportedVersion:
                throw PasswordEncryptedArchiveError.cannotOpenArchive
            default:
                throw error
            }
        } catch {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
    }
}

private extension PasswordEncryptedRelationshipVaultCodec {
    func validateLimits() throws {
        guard limits.maximumHeaderBytes >= 1_024,
              limits.maximumHeaderBytes <= 1_048_576,
              limits.maximumEncryptedBytes > 0,
              limits.maximumZIPBytes > 0,
              limits.maximumZIPBytes < limits.maximumEncryptedBytes,
              limits.maximumMaterializedZIPBytes > 0,
              limits.maximumMaterializedZIPBytes <= limits.maximumZIPBytes,
              limits.maximumAcceptedEncryptedBytes > limits.maximumMaterializedZIPBytes,
              limits.maximumPasswordUTF8Bytes >= 12,
              limits.maximumPasswordUTF8Bytes <= 1_048_576 else {
            throw PasswordEncryptedArchiveError.unsafeParameters
        }
        guard packageLimits.maximumManifestBytes > 0,
              packageLimits.maximumNotebookBytes > 0,
              packageLimits.maximumMediaFiles >= 0,
              packageLimits.maximumMediaFileBytes > 0,
              packageLimits.maximumMediaPixels > 0,
              packageLimits.maximumTotalPayloadBytes > 0,
              let manifestBytes = Int64(exactly: packageLimits.maximumManifestBytes),
              let notebookBytes = Int64(exactly: packageLimits.maximumNotebookBytes),
              let mediaBytes = Int64(exactly: packageLimits.maximumMediaFileBytes),
              manifestBytes <= limits.maximumZIPBytes,
              notebookBytes <= packageLimits.maximumTotalPayloadBytes,
              mediaBytes <= packageLimits.maximumTotalPayloadBytes else {
            throw PasswordEncryptedArchiveError.unsafeParameters
        }
    }

    func encryptZIP(
        at zipURL: URL,
        package: VerifiedRelationshipVaultPackage,
        password: String,
        to outputURL: URL
    ) throws {
        let zipByteCount = try preflightRegularFile(
            at: zipURL,
            maximumBytes: min(
                limits.maximumZIPBytes,
                limits.maximumMaterializedZIPBytes
            )
        )
        guard zipByteCount > 0 else {
            throw PasswordEncryptedArchiveError.cannotCreateArchive
        }

        let salt = try secureRandomData(count: 16)
        let wrapNonceData = try secureRandomData(count: 12)
        let contentNoncePrefix = try secureRandomData(count: 8)
        var dataEncryptionKey = try secureRandomData(count: 32)
        try Task.checkCancellation()
        var keyEncryptionKey = try Argon2idArchiveKeyDeriver().deriveKey(
            password: password,
            salt: salt,
            memoryKiB: 65_536,
            iterations: 3,
            outputBytes: 32,
            maximumPasswordBytes: limits.maximumPasswordUTF8Bytes
        )
        try Task.checkCancellation()
        defer {
            securelyZero(&dataEncryptionKey)
            securelyZero(&keyEncryptionKey)
        }

        let header = PasswordEncryptedArchiveHeader(
            format: PasswordEncryptedArchiveHeader.format,
            formatVersion: PasswordEncryptedArchiveHeader.currentVersion,
            archiveID: package.manifest.archiveID,
            passwordEncoding: PasswordEncryptedArchiveHeader.passwordEncoding,
            kdf: PasswordEncryptedArchiveKDF(
                algorithm: "argon2id",
                version: 19,
                profile: PasswordEncryptedArchiveHeader.kdfProfile,
                saltBase64: salt.base64EncodedString(),
                memoryKiB: 65_536,
                iterations: 3,
                parallelism: 1,
                outputBytes: 32
            ),
            keyWrap: PasswordEncryptedArchiveKeyWrap(
                algorithm: "aes-256-gcm",
                nonceBase64: wrapNonceData.base64EncodedString(),
                tagBytes: Self.tagBytes,
                wrappedKeyBytes: Self.wrappedKeyBytes
            ),
            content: PasswordEncryptedArchiveContent(
                algorithm: "aes-256-gcm-chunked",
                payloadFormat: PasswordEncryptedArchiveHeader.payloadFormat,
                chunkBytes: Self.chunkBytes,
                noncePrefixBase64: contentNoncePrefix.base64EncodedString(),
                counterEncoding: "uint32-be",
                terminalCounter: Self.terminalIndex,
                tagBytes: Self.tagBytes,
                digestAlgorithm: "sha256"
            )
        )
        let headerData = try encodeHeader(header)
        guard headerData.count <= limits.maximumHeaderBytes,
              headerData.count <= Int(UInt32.max) else {
            throw PasswordEncryptedArchiveError.cannotCreateArchive
        }
        var headerFraming = Self.magic
        headerFraming.appendInteger(Self.currentVersion)
        headerFraming.appendInteger(UInt32(headerData.count))
        headerFraming.append(headerData)
        let headerHash = Data(SHA256.hash(data: headerFraming))

        let keyWrappingKey = SymmetricKey(data: keyEncryptionKey)
        let wrapNonce = try AES.GCM.Nonce(data: wrapNonceData)
        let wrappedKey = try AES.GCM.seal(
            dataEncryptionKey,
            using: keyWrappingKey,
            nonce: wrapNonce,
            authenticating: headerFraming
        )
        guard wrappedKey.ciphertext.count == 32,
              wrappedKey.tag.count == Self.tagBytes else {
            throw PasswordEncryptedArchiveError.cannotCreateArchive
        }

        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: protectedFileAttributes
        ) else {
            throw PasswordEncryptedArchiveError.cannotCreateArchive
        }
        let input = try FileHandle(forReadingFrom: zipURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.write(contentsOf: headerFraming)
        try output.write(contentsOf: wrappedKey.ciphertext)
        try output.write(contentsOf: wrappedKey.tag)

        let contentKey = SymmetricKey(data: dataEncryptionKey)
        var streamHash = SHA256()
        var totalPlaintextBytes: UInt64 = 0
        var chunkCount: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: Self.chunkBytes) ?? Data()
            guard !chunk.isEmpty else { break }
            guard chunkCount < UInt64(Self.terminalIndex) else {
                throw PasswordEncryptedArchiveError.archiveTooLarge
            }
            let nextTotal = totalPlaintextBytes.addingReportingOverflow(UInt64(chunk.count))
            guard !nextTotal.overflow,
                  nextTotal.partialValue <= UInt64(limits.maximumZIPBytes) else {
                throw PasswordEncryptedArchiveError.archiveTooLarge
            }
            let index = UInt32(chunkCount)
            let sealed = try sealRecord(
                plaintext: chunk,
                type: Self.chunkRecord,
                index: index,
                key: contentKey,
                noncePrefix: contentNoncePrefix,
                headerHash: headerHash
            )
            try writeRecord(
                type: Self.chunkRecord,
                index: index,
                plaintextLength: UInt32(chunk.count),
                sealed: sealed,
                to: output
            )
            streamHash.update(data: chunk)
            totalPlaintextBytes = nextTotal.partialValue
            chunkCount += 1
        }

        var terminal = Data()
        terminal.appendInteger(totalPlaintextBytes)
        terminal.appendInteger(chunkCount)
        terminal.append(contentsOf: streamHash.finalize())
        guard terminal.count == Self.terminalPlaintextBytes else {
            throw PasswordEncryptedArchiveError.cannotCreateArchive
        }
        let sealedTerminal = try sealRecord(
            plaintext: terminal,
            type: Self.terminalRecord,
            index: Self.terminalIndex,
            key: contentKey,
            noncePrefix: contentNoncePrefix,
            headerHash: headerHash
        )
        try writeRecord(
            type: Self.terminalRecord,
            index: Self.terminalIndex,
            plaintextLength: UInt32(Self.terminalPlaintextBytes),
            sealed: sealedTerminal,
            to: output
        )
        try output.synchronize()
        let encryptedBytes = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(encryptedBytes) <= limits.maximumEncryptedBytes else {
            throw PasswordEncryptedArchiveError.archiveTooLarge
        }
    }

    func decryptEnvelope(
        at encryptedURL: URL,
        password: String,
        to zipURL: URL
    ) throws -> UUID {
        let encryptedByteCount = try preflightRegularFile(
            at: encryptedURL,
            maximumBytes: limits.maximumAcceptedEncryptedBytes
        )
        try ensureTemporaryCapacity(
            requiredBytes: try checkedAdd(encryptedByteCount, 64 * 1_024 * 1_024),
            at: zipURL.deletingLastPathComponent()
        )
        let input = try FileHandle(forReadingFrom: encryptedURL)
        defer { try? input.close() }

        let magic = try readExactly(Self.magic.count, from: input)
        guard magic == Self.magic else {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        let framingVersion = try readExactly(2, from: input).decodeUInt16()
        guard framingVersion == Self.currentVersion else {
            throw PasswordEncryptedArchiveError.unsupportedVersion(Int(framingVersion))
        }
        let headerLength = try readExactly(4, from: input).decodeUInt32()
        guard headerLength > 0,
              headerLength <= UInt32(limits.maximumHeaderBytes) else {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        let headerData = try readExactly(Int(headerLength), from: input)
        var headerFraming = magic
        headerFraming.appendInteger(framingVersion)
        headerFraming.appendInteger(headerLength)
        headerFraming.append(headerData)
        let header = try decodeAndValidateHeader(headerData)
        let salt = try decodeBase64(header.kdf.saltBase64, exactBytes: 16)
        let wrapNonceData = try decodeBase64(header.keyWrap.nonceBase64, exactBytes: 12)
        let noncePrefix = try decodeBase64(
            header.content.noncePrefixBase64,
            exactBytes: 8
        )

        try Task.checkCancellation()
        var keyEncryptionKey = try Argon2idArchiveKeyDeriver().deriveKey(
            password: password,
            salt: salt,
            memoryKiB: header.kdf.memoryKiB,
            iterations: header.kdf.iterations,
            outputBytes: header.kdf.outputBytes,
            maximumPasswordBytes: limits.maximumPasswordUTF8Bytes
        )
        try Task.checkCancellation()
        defer { securelyZero(&keyEncryptionKey) }
        let wrappedCiphertext = try readExactly(32, from: input)
        let wrappedTag = try readExactly(Self.tagBytes, from: input)
        let wrappedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: wrapNonceData),
            ciphertext: wrappedCiphertext,
            tag: wrappedTag
        )
        var dataEncryptionKey: Data
        do {
            dataEncryptionKey = try AES.GCM.open(
                wrappedBox,
                using: SymmetricKey(data: keyEncryptionKey),
                authenticating: headerFraming
            )
        } catch {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        guard dataEncryptionKey.count == 32 else {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        defer { securelyZero(&dataEncryptionKey) }

        guard FileManager.default.createFile(
            atPath: zipURL.path,
            contents: nil,
            attributes: protectedFileAttributes
        ) else {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        let output = try FileHandle(forWritingTo: zipURL)
        defer { try? output.close() }
        let contentKey = SymmetricKey(data: dataEncryptionKey)
        let headerHash = Data(SHA256.hash(data: headerFraming))
        var expectedIndex: UInt32 = 0
        var chunkCount: UInt64 = 0
        var totalPlaintextBytes: UInt64 = 0
        var streamHash = SHA256()

        while true {
            try Task.checkCancellation()
            let recordTypeData = try readExactly(1, from: input)
            let recordType = recordTypeData[recordTypeData.startIndex]
            let index = try readExactly(4, from: input).decodeUInt32()
            let plaintextLength = try readExactly(4, from: input).decodeUInt32()

            if recordType == Self.chunkRecord {
                guard index == expectedIndex,
                      index != Self.terminalIndex,
                      plaintextLength > 0,
                      plaintextLength <= UInt32(Self.chunkBytes) else {
                    throw PasswordEncryptedArchiveError.cannotOpenArchive
                }
                let ciphertext = try readExactly(Int(plaintextLength), from: input)
                let tag = try readExactly(Self.tagBytes, from: input)
                let plaintext = try openRecord(
                    ciphertext: ciphertext,
                    tag: tag,
                    plaintextLength: plaintextLength,
                    type: recordType,
                    index: index,
                    key: contentKey,
                    noncePrefix: noncePrefix,
                    headerHash: headerHash
                )
                let nextTotal = totalPlaintextBytes.addingReportingOverflow(
                    UInt64(plaintext.count)
                )
                guard !nextTotal.overflow,
                      nextTotal.partialValue <= UInt64(limits.maximumZIPBytes) else {
                    throw PasswordEncryptedArchiveError.archiveTooLarge
                }
                try output.write(contentsOf: plaintext)
                streamHash.update(data: plaintext)
                totalPlaintextBytes = nextTotal.partialValue
                chunkCount += 1
                guard expectedIndex < Self.terminalIndex - 1 else {
                    throw PasswordEncryptedArchiveError.archiveTooLarge
                }
                expectedIndex += 1
                continue
            }

            guard recordType == Self.terminalRecord,
                  index == Self.terminalIndex,
                  plaintextLength == UInt32(Self.terminalPlaintextBytes) else {
                throw PasswordEncryptedArchiveError.cannotOpenArchive
            }
            let ciphertext = try readExactly(Self.terminalPlaintextBytes, from: input)
            let tag = try readExactly(Self.tagBytes, from: input)
            let terminal = try openRecord(
                ciphertext: ciphertext,
                tag: tag,
                plaintextLength: plaintextLength,
                type: recordType,
                index: index,
                key: contentKey,
                noncePrefix: noncePrefix,
                headerHash: headerHash
            )
            let recordedTotal = try terminal.subdata(in: 0..<8).decodeUInt64()
            let recordedCount = try terminal.subdata(in: 8..<16).decodeUInt64()
            let recordedHash = terminal.subdata(in: 16..<48)
            let actualHash = Data(streamHash.finalize())
            guard recordedTotal == totalPlaintextBytes,
                  recordedCount == chunkCount,
                  recordedHash == actualHash,
                  !(try hasTrailingBytes(in: input)) else {
                throw PasswordEncryptedArchiveError.cannotOpenArchive
            }
            try output.synchronize()
            return header.archiveID
        }
    }

    func encodeHeader(_ header: PasswordEncryptedArchiveHeader) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(header)
    }

    func decodeAndValidateHeader(_ data: Data) throws -> PasswordEncryptedArchiveHeader {
        let header: PasswordEncryptedArchiveHeader
        do {
            header = try JSONDecoder().decode(PasswordEncryptedArchiveHeader.self, from: data)
        } catch {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        guard header.format == PasswordEncryptedArchiveHeader.format else {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        guard header.formatVersion == PasswordEncryptedArchiveHeader.currentVersion else {
            throw PasswordEncryptedArchiveError.unsupportedVersion(header.formatVersion)
        }
        guard header.passwordEncoding == PasswordEncryptedArchiveHeader.passwordEncoding,
              header.kdf.algorithm == "argon2id",
              header.kdf.version == 19,
              header.kdf.profile == PasswordEncryptedArchiveHeader.kdfProfile,
              header.kdf.memoryKiB == 65_536,
              header.kdf.iterations == 3,
              header.kdf.parallelism == 1,
              header.kdf.outputBytes == 32,
              header.keyWrap.algorithm == "aes-256-gcm",
              header.keyWrap.tagBytes == Self.tagBytes,
              header.keyWrap.wrappedKeyBytes == Self.wrappedKeyBytes,
              header.content.algorithm == "aes-256-gcm-chunked",
              header.content.payloadFormat == PasswordEncryptedArchiveHeader.payloadFormat,
              header.content.chunkBytes == Self.chunkBytes,
              header.content.counterEncoding == "uint32-be",
              header.content.terminalCounter == Self.terminalIndex,
              header.content.tagBytes == Self.tagBytes,
              header.content.digestAlgorithm == "sha256" else {
            throw PasswordEncryptedArchiveError.unsafeParameters
        }
        return header
    }

    func sealRecord(
        plaintext: Data,
        type: UInt8,
        index: UInt32,
        key: SymmetricKey,
        noncePrefix: Data,
        headerHash: Data
    ) throws -> AES.GCM.SealedBox {
        let length = UInt32(plaintext.count)
        return try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: AES.GCM.Nonce(data: recordNonce(prefix: noncePrefix, index: index)),
            authenticating: recordAAD(
                headerHash: headerHash,
                type: type,
                index: index,
                plaintextLength: length
            )
        )
    }

    func openRecord(
        ciphertext: Data,
        tag: Data,
        plaintextLength: UInt32,
        type: UInt8,
        index: UInt32,
        key: SymmetricKey,
        noncePrefix: Data,
        headerHash: Data
    ) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: recordNonce(prefix: noncePrefix, index: index)),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: recordAAD(
                    headerHash: headerHash,
                    type: type,
                    index: index,
                    plaintextLength: plaintextLength
                )
            )
            guard plaintext.count == Int(plaintextLength) else {
                throw PasswordEncryptedArchiveError.cannotOpenArchive
            }
            return plaintext
        } catch {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
    }

    func writeRecord(
        type: UInt8,
        index: UInt32,
        plaintextLength: UInt32,
        sealed: AES.GCM.SealedBox,
        to output: FileHandle
    ) throws {
        guard sealed.ciphertext.count == Int(plaintextLength),
              sealed.tag.count == Self.tagBytes else {
            throw PasswordEncryptedArchiveError.cannotCreateArchive
        }
        var framing = Data([type])
        framing.appendInteger(index)
        framing.appendInteger(plaintextLength)
        try output.write(contentsOf: framing)
        try output.write(contentsOf: sealed.ciphertext)
        try output.write(contentsOf: sealed.tag)
    }

    func recordNonce(prefix: Data, index: UInt32) -> Data {
        var nonce = prefix
        nonce.appendInteger(index)
        return nonce
    }

    func recordAAD(
        headerHash: Data,
        type: UInt8,
        index: UInt32,
        plaintextLength: UInt32
    ) -> Data {
        var aad = headerHash
        aad.append(type)
        aad.appendInteger(index)
        aad.appendInteger(plaintextLength)
        return aad
    }

    func decodeBase64(_ encoded: String, exactBytes: Int) throws -> Data {
        guard let data = Data(base64Encoded: encoded), data.count == exactBytes else {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        return data
    }

    func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            securelyZero(&data)
            throw PasswordEncryptedArchiveError.cannotCreateArchive
        }
        return data
    }

    func preflightRegularFile(at url: URL, maximumBytes: Int64) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0 else {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        let byteCount = Int64(size)
        guard byteCount <= maximumBytes else {
            throw PasswordEncryptedArchiveError.archiveTooLarge
        }
        return byteCount
    }

    func estimatedWorkspaceBytes(
        for package: VerifiedRelationshipVaultPackage
    ) throws -> Int64 {
        guard package.manifest.uncompressedPayloadBytes >= 0,
              package.manifest.uncompressedPayloadBytes
                <= limits.maximumMaterializedZIPBytes else {
            throw PasswordEncryptedArchiveError.archiveTooLarge
        }
        let entryCount = try checkedAdd(Int64(package.manifest.media.count), 3)
        let zipOverhead = try checkedAdd(
            Int64(packageLimits.maximumManifestBytes),
            try checkedMultiply(entryCount, 512)
        )
        let estimatedZIP = try checkedAdd(
            package.manifest.uncompressedPayloadBytes,
            zipOverhead
        )
        return try checkedAdd(
            try checkedMultiply(estimatedZIP, 2),
            64 * 1_024 * 1_024
        )
    }

    func ensureTemporaryCapacity(requiredBytes: Int64, at url: URL) throws {
        guard requiredBytes > 0 else {
            throw PasswordEncryptedArchiveError.archiveTooLarge
        }
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        if let available = values?.volumeAvailableCapacityForImportantUsage,
           available < requiredBytes {
            throw PasswordEncryptedArchiveError.insufficientTemporaryStorage
        }
    }

    func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow, result.partialValue >= 0 else {
            throw PasswordEncryptedArchiveError.archiveTooLarge
        }
        return result.partialValue
    }

    func checkedMultiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow, result.partialValue >= 0 else {
            throw PasswordEncryptedArchiveError.archiveTooLarge
        }
        return result.partialValue
    }

    func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count >= 0 else { throw PasswordEncryptedArchiveError.cannotOpenArchive }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let next = try handle.read(upToCount: count - result.count) ?? Data()
            guard !next.isEmpty else {
                throw PasswordEncryptedArchiveError.cannotOpenArchive
            }
            result.append(next)
        }
        return result
    }

    func hasTrailingBytes(in handle: FileHandle) throws -> Bool {
        !(try handle.read(upToCount: 1) ?? Data()).isEmpty
    }

    func makeProtectedTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(Self.temporaryDirectoryPrefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: protectedDirectoryAttributes
        )
        return directory
    }

    static func processIsRunning(_ process: Int32) -> Bool {
        errno = 0
        if Darwin.kill(process, 0) == 0 { return true }
        return errno == EPERM
    }

    var protectedFileAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        [
            .protectionKey: FileProtectionType.complete,
            .posixPermissions: 0o600
        ]
        #else
        [.posixPermissions: 0o600]
        #endif
    }

    var protectedDirectoryAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        [
            .protectionKey: FileProtectionType.complete,
            .posixPermissions: 0o700
        ]
        #else
        [.posixPermissions: 0o700]
        #endif
    }

    func securelyZero(_ data: inout Data) {
        data.withUnsafeMutableBytes { bytes in
            if let address = bytes.baseAddress { sodium_memzero(address, bytes.count) }
        }
        data.removeAll(keepingCapacity: false)
    }
}

struct PlaintextRelationshipVaultZIPCodec: Sendable {
    var limits: RelationshipVaultPackageLimits

    func write(
        package: VerifiedRelationshipVaultPackage,
        to url: URL
    ) throws {
        let wrapper = try RelationshipVaultPackageCodec(limits: limits)
            .fileWrapper(for: package)
        let payloads = try flatten(wrapper)
        let archive = try ZIPFoundation.Archive(url: url, accessMode: .create)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [
                .protectionKey: FileProtectionType.complete,
                .posixPermissions: 0o600
            ],
            ofItemAtPath: url.path
        )
        #else
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        #endif
        for (path, data) in payloads.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                modificationDate: package.manifest.createdAt,
                permissions: 0o600,
                compressionMethod: .none,
                bufferSize: 64 * 1_024
            ) { position, size in
                let start = Int(position)
                guard start >= 0, size >= 0, start <= data.count,
                      size <= data.count - start else { return Data() }
                return data.subdata(in: start..<(start + size))
            }
            try Task.checkCancellation()
        }
    }

    func inspect(at url: URL) throws -> VerifiedRelationshipVaultPackage {
        let archive = try ZIPFoundation.Archive(url: url, accessMode: .read)
        var payloads: [String: Data] = [:]
        var totalPayloadBytes: Int64 = 0
        var mediaCount = 0

        for entry in archive {
            try Task.checkCancellation()
            guard entry.type == .file,
                  !entry.isCompressed,
                  isAllowed(path: entry.path),
                  payloads[entry.path] == nil else {
                throw PasswordEncryptedArchiveError.cannotOpenArchive
            }
            let maximum = try maximumBytes(for: entry.path)
            guard entry.uncompressedSize <= UInt64(maximum),
                  entry.uncompressedSize <= UInt64(Int.max) else {
                throw PasswordEncryptedArchiveError.archiveTooLarge
            }
            if entry.path.hasPrefix("media/") {
                mediaCount += 1
                guard mediaCount <= limits.maximumMediaFiles else {
                    throw PasswordEncryptedArchiveError.archiveTooLarge
                }
            }
            let addition = totalPayloadBytes.addingReportingOverflow(
                Int64(entry.uncompressedSize)
            )
            let payloadBudget = limits.maximumTotalPayloadBytes.addingReportingOverflow(
                Int64(limits.maximumManifestBytes)
            )
            guard !addition.overflow,
                  !payloadBudget.overflow,
                  addition.partialValue <= payloadBudget.partialValue else {
                throw PasswordEncryptedArchiveError.archiveTooLarge
            }
            totalPayloadBytes = addition.partialValue

            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            _ = try archive.extract(
                entry,
                bufferSize: 64 * 1_024,
                skipCRC32: false
            ) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= Int(entry.uncompressedSize) - data.count else {
                    throw PasswordEncryptedArchiveError.cannotOpenArchive
                }
                data.append(chunk)
            }
            guard data.count == Int(entry.uncompressedSize) else {
                throw PasswordEncryptedArchiveError.cannotOpenArchive
            }
            payloads[entry.path] = data
        }

        guard let manifest = payloads["manifest.json"],
              let notebook = payloads["data/notebook.json"],
              let checksums = payloads["checksums.sha256"],
              payloads.count == mediaCount + 3 else {
            throw PasswordEncryptedArchiveError.cannotOpenArchive
        }
        var mediaWrappers: [String: FileWrapper] = [:]
        for (path, data) in payloads where path.hasPrefix("media/") {
            mediaWrappers[String(path.dropFirst("media/".count))] = FileWrapper(
                regularFileWithContents: data
            )
        }
        let root = FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: manifest),
            "data": FileWrapper(directoryWithFileWrappers: [
                "notebook.json": FileWrapper(regularFileWithContents: notebook)
            ]),
            "media": FileWrapper(directoryWithFileWrappers: mediaWrappers),
            "checksums.sha256": FileWrapper(regularFileWithContents: checksums)
        ])
        return try RelationshipVaultPackageCodec(limits: limits).inspect(root)
    }

    private func flatten(_ root: FileWrapper) throws -> [String: Data] {
        guard root.isDirectory, !root.isSymbolicLink,
              let files = root.fileWrappers,
              Set(files.keys) == ["manifest.json", "data", "media", "checksums.sha256"],
              let manifest = regularData(files["manifest.json"]),
              let checksums = regularData(files["checksums.sha256"]),
              let dataDirectory = files["data"], dataDirectory.isDirectory,
              !dataDirectory.isSymbolicLink,
              let dataFiles = dataDirectory.fileWrappers,
              Set(dataFiles.keys) == ["notebook.json"],
              let notebook = regularData(dataFiles["notebook.json"]),
              let mediaDirectory = files["media"], mediaDirectory.isDirectory,
              !mediaDirectory.isSymbolicLink,
              let mediaFiles = mediaDirectory.fileWrappers else {
            throw PasswordEncryptedArchiveError.cannotCreateArchive
        }
        var result = [
            "manifest.json": manifest,
            "data/notebook.json": notebook,
            "checksums.sha256": checksums
        ]
        for (name, wrapper) in mediaFiles {
            guard let data = regularData(wrapper), isAllowed(path: "media/\(name)") else {
                throw PasswordEncryptedArchiveError.cannotCreateArchive
            }
            result["media/\(name)"] = data
        }
        return result
    }

    private func regularData(_ wrapper: FileWrapper?) -> Data? {
        guard let wrapper, wrapper.isRegularFile, !wrapper.isSymbolicLink else { return nil }
        return wrapper.regularFileContents
    }

    private func isAllowed(path: String) -> Bool {
        if ["manifest.json", "data/notebook.json", "checksums.sha256"].contains(path) {
            return true
        }
        guard path == path.precomposedStringWithCanonicalMapping,
              !path.contains("\\"), !path.hasPrefix("/"),
              path.utf8.count <= 128 else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == "media" else { return false }
        let name = String(components[1])
        guard name.hasSuffix(".jpg") else { return false }
        let stem = String(name.dropLast(4))
        guard let id = UUID(uuidString: stem),
              "\(id.uuidString.lowercased()).jpg" == name else { return false }
        return true
    }

    private func maximumBytes(for path: String) throws -> Int64 {
        switch path {
        case "manifest.json", "checksums.sha256":
            return Int64(limits.maximumManifestBytes)
        case "data/notebook.json":
            return Int64(limits.maximumNotebookBytes)
        default:
            guard path.hasPrefix("media/") else {
                throw PasswordEncryptedArchiveError.cannotOpenArchive
            }
            return Int64(limits.maximumMediaFileBytes)
        }
    }
}

private extension Data {
    mutating func appendInteger(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendInteger(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendInteger(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    func decodeUInt16() throws -> UInt16 {
        guard count == 2 else { throw PasswordEncryptedArchiveError.cannotOpenArchive }
        return reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    func decodeUInt32() throws -> UInt32 {
        guard count == 4 else { throw PasswordEncryptedArchiveError.cannotOpenArchive }
        return reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func decodeUInt64() throws -> UInt64 {
        guard count == 8 else { throw PasswordEncryptedArchiveError.cannotOpenArchive }
        return reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
