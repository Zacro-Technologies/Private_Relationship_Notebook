import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RelationshipCore

@Suite(.serialized)
struct PasswordEncryptedArchiveTests {
    @Test func realArgon2idAndAESGCMEnvelopeRoundTripsAndRejectsDamage() throws {
        let initialProtectedWorkspaces = try encryptedWorkspaceNames()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PasswordEncryptedArchiveTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let package = try makeNotebookPackage()
        let codec = PasswordEncryptedRelationshipVaultCodec()
        let decomposedPassword = "Keepsake-Cafe\u{301}-2026!"
        let composedPassword = "Keepsake-Caf\u{e9}-2026!"
        #expect(Data(decomposedPassword.utf8) != Data(composedPassword.utf8))

        let firstURL = temporaryDirectory.appendingPathComponent("first.relationshipvault")
        let secondURL = temporaryDirectory.appendingPathComponent("second.relationshipvault")
        try codec.encrypt(package: package, password: decomposedPassword, to: firstURL)
        try codec.encrypt(package: package, password: decomposedPassword, to: secondURL)

        let firstBytes = try Data(contentsOf: firstURL)
        let secondBytes = try Data(contentsOf: secondURL)
        #expect(firstBytes != secondBytes)
        #expect(codec.looksLikeEncryptedArchive(at: firstURL))
        let outputAttributes = try FileManager.default.attributesOfItem(atPath: firstURL.path)
        let outputPermissions = (outputAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((outputPermissions & 0o777) == 0o600)

        let layout = try parseEnvelope(firstBytes)
        #expect(firstBytes.prefix(PasswordEncryptedRelationshipVaultCodec.magic.count)
            == PasswordEncryptedRelationshipVaultCodec.magic)
        #expect(layout.version == PasswordEncryptedRelationshipVaultCodec.currentVersion)
        #expect(layout.header.format == PasswordEncryptedArchiveHeader.format)
        #expect(layout.header.formatVersion == PasswordEncryptedArchiveHeader.currentVersion)
        #expect(layout.header.archiveID == package.manifest.archiveID)
        #expect(layout.header.passwordEncoding == "utf8-nfc")
        #expect(layout.header.kdf.algorithm == "argon2id")
        #expect(layout.header.kdf.version == 19)
        #expect(layout.header.kdf.profile == "argon2id13-m64-t3-p1-v1")
        #expect(layout.header.kdf.memoryKiB == 65_536)
        #expect(layout.header.kdf.iterations == 3)
        #expect(layout.header.kdf.parallelism == 1)
        #expect(layout.header.kdf.outputBytes == 32)
        #expect(Data(base64Encoded: layout.header.kdf.saltBase64)?.count == 16)
        #expect(layout.header.keyWrap.algorithm == "aes-256-gcm")
        #expect(Data(base64Encoded: layout.header.keyWrap.nonceBase64)?.count == 12)
        #expect(layout.header.keyWrap.tagBytes == 16)
        #expect(layout.header.keyWrap.wrappedKeyBytes == 48)
        #expect(layout.header.content.algorithm == "aes-256-gcm-chunked")
        #expect(layout.header.content.payloadFormat == "zip+relationshipvault-v1")
        #expect(layout.header.content.chunkBytes == 1_048_576)
        #expect(Data(base64Encoded: layout.header.content.noncePrefixBase64)?.count == 8)
        #expect(layout.header.content.counterEncoding == "uint32-be")
        #expect(layout.header.content.terminalCounter == UInt32.max)
        #expect(layout.header.content.tagBytes == 16)
        #expect(layout.header.content.digestAlgorithm == "sha256")

        // Swift strings compare canonically, but their UTF-8 encodings above are
        // deliberately different. Successful decryption proves the codec's NFC
        // password profile is interoperable across equivalent input forms.
        let decrypted = try codec.decrypt(at: firstURL, password: composedPassword)
        #expect(decrypted.archiveData == package.archiveData)
        #expect(decrypted.manifest.archiveID == package.manifest.archiveID)
        #expect(decrypted.archive.people.map(\.id) == package.archive.people.map(\.id))
        #expect(decrypted.archive.people.map(\.displayName)
            == package.archive.people.map(\.displayName))
        #expect(decrypted.archive.interactions.map(\.id)
            == package.archive.interactions.map(\.id))
        #expect(decrypted.mediaData.isEmpty)

        try expectGenericOpenFailure(
            codec: codec,
            bytes: firstBytes,
            password: "Different-Password-2026!",
            named: "wrong-password",
            in: temporaryDirectory
        )

        var tamperedWrappedKey = firstBytes
        tamperedWrappedKey[layout.wrappedKeyRange.lowerBound] ^= 0x80
        try expectGenericOpenFailure(
            codec: codec,
            bytes: tamperedWrappedKey,
            password: composedPassword,
            named: "tampered-wrapped-key",
            in: temporaryDirectory
        )

        var tamperedAuthenticatedHeader = firstBytes
        let encodedArchiveID = Data(package.manifest.archiveID.uuidString.utf8)
        guard let archiveIDRange = tamperedAuthenticatedHeader.range(of: encodedArchiveID) else {
            throw TestEnvelopeError.malformed
        }
        tamperedAuthenticatedHeader[archiveIDRange.lowerBound] =
            tamperedAuthenticatedHeader[archiveIDRange.lowerBound] == 0x41 ? 0x42 : 0x41
        try expectGenericOpenFailure(
            codec: codec,
            bytes: tamperedAuthenticatedHeader,
            password: composedPassword,
            named: "tampered-authenticated-header",
            in: temporaryDirectory
        )

        var tamperedKDFProfile = firstBytes
        let profile = Data("argon2id13-m64-t3-p1-v1".utf8)
        guard let profileRange = tamperedKDFProfile.range(of: profile) else {
            throw TestEnvelopeError.malformed
        }
        tamperedKDFProfile[profileRange.upperBound - 1] = 0x32
        try expectGenericOpenFailure(
            codec: codec,
            bytes: tamperedKDFProfile,
            password: composedPassword,
            named: "tampered-kdf-profile",
            in: temporaryDirectory
        )

        var tamperedChunk = firstBytes
        tamperedChunk[layout.chunkCiphertextRange.lowerBound] ^= 0x40
        try expectGenericOpenFailure(
            codec: codec,
            bytes: tamperedChunk,
            password: composedPassword,
            named: "tampered-chunk",
            in: temporaryDirectory
        )

        var tamperedTerminal = firstBytes
        tamperedTerminal[layout.terminalCiphertextRange.lowerBound] ^= 0x20
        try expectGenericOpenFailure(
            codec: codec,
            bytes: tamperedTerminal,
            password: composedPassword,
            named: "tampered-terminal",
            in: temporaryDirectory
        )

        var wrongChunkIndex = firstBytes
        wrongChunkIndex[layout.chunkRecordRange.lowerBound + 4] ^= 0x01
        try expectGenericOpenFailure(
            codec: codec,
            bytes: wrongChunkIndex,
            password: composedPassword,
            named: "wrong-chunk-index",
            in: temporaryDirectory
        )

        var zeroChunkLength = firstBytes
        for offset in 5..<9 {
            zeroChunkLength[layout.chunkRecordRange.lowerBound + offset] = 0
        }
        try expectGenericOpenFailure(
            codec: codec,
            bytes: zeroChunkLength,
            password: composedPassword,
            named: "zero-chunk-length",
            in: temporaryDirectory
        )

        var duplicatedChunk = firstBytes
        duplicatedChunk.insert(
            contentsOf: firstBytes[layout.chunkRecordRange],
            at: layout.terminalRecordRange.lowerBound
        )
        try expectGenericOpenFailure(
            codec: codec,
            bytes: duplicatedChunk,
            password: composedPassword,
            named: "duplicated-chunk",
            in: temporaryDirectory
        )

        try expectGenericOpenFailure(
            codec: codec,
            bytes: Data(firstBytes[..<layout.terminalRecordRange.lowerBound]),
            password: composedPassword,
            named: "missing-terminal-record",
            in: temporaryDirectory
        )

        try expectGenericOpenFailure(
            codec: codec,
            bytes: Data(firstBytes.dropLast()),
            password: composedPassword,
            named: "truncated",
            in: temporaryDirectory
        )

        var trailingByte = firstBytes
        trailingByte.append(0)
        try expectGenericOpenFailure(
            codec: codec,
            bytes: trailingByte,
            password: composedPassword,
            named: "trailing-byte",
            in: temporaryDirectory
        )

        var wrongMagic = firstBytes
        wrongMagic[0] ^= 0x01
        let wrongMagicURL = temporaryDirectory.appendingPathComponent("wrong-magic.relationshipvault")
        try wrongMagic.write(to: wrongMagicURL, options: .atomic)
        #expect(!codec.looksLikeEncryptedArchive(at: wrongMagicURL))
        #expect(throws: PasswordEncryptedArchiveError.cannotOpenArchive) {
            _ = try codec.decrypt(at: wrongMagicURL, password: composedPassword)
        }

        var unsupportedVersion = firstBytes
        unsupportedVersion[PasswordEncryptedRelationshipVaultCodec.magic.count] = 0
        unsupportedVersion[PasswordEncryptedRelationshipVaultCodec.magic.count + 1] = 2
        try expectGenericOpenFailure(
            codec: codec,
            bytes: unsupportedVersion,
            password: composedPassword,
            named: "unsupported-or-damaged-version",
            in: temporaryDirectory
        )

        var oversizedHeader = firstBytes
        let headerLengthOffset = PasswordEncryptedRelationshipVaultCodec.magic.count + 2
        for offset in 0..<4 { oversizedHeader[headerLengthOffset + offset] = 0xff }
        try expectGenericOpenFailure(
            codec: codec,
            bytes: oversizedHeader,
            password: composedPassword,
            named: "oversized-header",
            in: temporaryDirectory
        )
        #expect(try encryptedWorkspaceNames() == initialProtectedWorkspaces)
    }

    @Test func argon2idProfileMatchesKnownAnswer() throws {
        let derived = try Argon2idArchiveKeyDeriver().deriveKey(
            password: "Keepsake-Archive-KAT",
            salt: Data((0..<16).map(UInt8.init)),
            memoryKiB: 65_536,
            iterations: 3,
            outputBytes: 32,
            maximumPasswordBytes: 1_024
        )
        #expect(
            derived.map { String(format: "%02x", $0) }.joined()
                == "3f13e97625674a8b38cf01c5391050a1186448532b4a79aca9545823bca6c7c5"
        )
    }

    @Test func payloadLargerThanOneMiBRoundTripsAsMultipleAuthenticatedChunks() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PasswordEncryptedArchiveMultiChunkTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let note = String(repeating: "authenticated multi-chunk payload ", count: 40_000)
        let package = try makeNotebookPackage(privateNote: note)
        let archiveURL = temporaryDirectory.appendingPathComponent("multi.relationshipvault")
        let codec = PasswordEncryptedRelationshipVaultCodec()
        try codec.encrypt(
            package: package,
            password: "Multiple-Chunks-2026!",
            to: archiveURL
        )

        let encrypted = try Data(contentsOf: archiveURL)
        #expect(try authenticatedChunkCount(in: encrypted) >= 2)
        let decrypted = try codec.decrypt(at: archiveURL, password: "Multiple-Chunks-2026!")
        #expect(decrypted.archiveData == package.archiveData)
        #expect(decrypted.archive.people.first?.privateNote == note)
    }

    @Test func alreadyCancelledExportReturnsTypedErrorAndCreatesNoOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PasswordEncryptedArchiveCancellationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outputURL = temporaryDirectory.appendingPathComponent("cancelled.relationshipvault")
        let package = try makeNotebookPackage()
        let task = Task.detached {
            try? await Task.sleep(for: .seconds(10))
            try PasswordEncryptedRelationshipVaultCodec().encrypt(
                package: package,
                password: "Cancelled-Archive-2026!",
                to: outputURL
            )
        }
        task.cancel()

        do {
            try await task.value
            Issue.record("A cancelled export unexpectedly succeeded.")
        } catch let error as PasswordEncryptedArchiveError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("A cancelled export returned an unexpected error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test func midOperationCancellationRemovesProtectedPlaintextWorkspace() async throws {
        let initialWorkspaces = try encryptedWorkspaceNames()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PasswordEncryptedArchiveMidCancellationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outputURL = temporaryDirectory.appendingPathComponent("cancelled.relationshipvault")
        let package = try makeNotebookPackage(
            privateNote: String(repeating: "cancel while protected ", count: 80_000)
        )
        let task = Task.detached {
            try PasswordEncryptedRelationshipVaultCodec().encrypt(
                package: package,
                password: "Cancel-During-Archive-2026!",
                to: outputURL
            )
        }

        var observedWorkspace = false
        for _ in 0..<200 {
            if try encryptedWorkspaceNames() != initialWorkspaces {
                observedWorkspace = true
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(observedWorkspace)
        task.cancel()
        do {
            try await task.value
            Issue.record("A mid-operation cancelled export unexpectedly succeeded.")
        } catch let error as PasswordEncryptedArchiveError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("A mid-operation cancel returned an unexpected error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        #expect(try encryptedWorkspaceNames() == initialWorkspaces)
    }

    @Test func staleProtectedWorkspaceIsScavengedWithoutTouchingCurrentWork() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
        let stale = temporaryRoot.appendingPathComponent(
            "Keepsake-Encrypted-stale-test-\(UUID().uuidString)",
            isDirectory: true
        )
        let active = temporaryRoot.appendingPathComponent(
            "Keepsake-Encrypted-\(ProcessInfo.processInfo.processIdentifier)-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: stale)
            try? FileManager.default.removeItem(at: active)
        }
        try Data("plaintext canary".utf8).write(
            to: stale.appendingPathComponent("payload.zip")
        )

        PasswordEncryptedRelationshipVaultCodec.removeStaleProtectedTemporaryFiles()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
    }

    @Test func invalidPackageLimitsRejectBeforeOpeningOrAllocating() {
        let invalidPackageLimits = RelationshipVaultPackageLimits(
            maximumManifestBytes: -1,
            maximumNotebookBytes: 1,
            maximumMediaFiles: 0,
            maximumMediaFileBytes: 1,
            maximumMediaPixels: 1,
            maximumTotalPayloadBytes: 1
        )
        let codec = PasswordEncryptedRelationshipVaultCodec(
            packageLimits: invalidPackageLimits
        )
        #expect(throws: PasswordEncryptedArchiveError.unsafeParameters) {
            _ = try codec.decrypt(
                at: URL(fileURLWithPath: "/this-file-must-not-be-opened"),
                password: "Irrelevant-Password-2026!"
            )
        }
    }

    @Test func mediaBearingEncryptedArchiveRoundTripsVerifiedPortrait() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PasswordEncryptedArchiveMediaTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let (package, mediaID, jpeg) = try makeMediaNotebookPackage()
        let url = temporaryDirectory.appendingPathComponent("media.relationshipvault")
        let codec = PasswordEncryptedRelationshipVaultCodec()
        try codec.encrypt(
            package: package,
            password: "Portrait-Archive-2026!",
            to: url
        )
        let decrypted = try codec.decrypt(at: url, password: "Portrait-Archive-2026!")
        #expect(decrypted.archiveData == package.archiveData)
        #expect(decrypted.mediaData[mediaID] == jpeg)
    }

    @Test func exportPasswordPolicyEnforcesNormalizedCharacterAndByteLimits() throws {
        #expect(throws: PasswordEncryptedArchiveError.passwordTooShort) {
            try PasswordEncryptedArchivePasswordPolicy.validateForExport("12345678901")
        }
        #expect(throws: PasswordEncryptedArchiveError.passwordTooLong) {
            try PasswordEncryptedArchivePasswordPolicy.validateForExport(
                "1234567890123",
                maximumUTF8Bytes: 12
            )
        }

        // Eleven ASCII characters plus one decomposed grapheme becomes twelve
        // characters after NFC and remains a valid minimum-length password.
        try PasswordEncryptedArchivePasswordPolicy.validateForExport(
            "12345678901e\u{301}"
        )
        try PasswordEncryptedArchivePasswordPolicy.validateForExport("123456789012")
    }
}

private struct TestEnvelopeLayout {
    var version: UInt16
    var header: PasswordEncryptedArchiveHeader
    var wrappedKeyRange: Range<Int>
    var chunkRecordRange: Range<Int>
    var chunkCiphertextRange: Range<Int>
    var terminalRecordRange: Range<Int>
    var terminalCiphertextRange: Range<Int>
}

private enum TestEnvelopeError: Error {
    case malformed
}

private func parseEnvelope(_ data: Data) throws -> TestEnvelopeLayout {
    let magicBytes = PasswordEncryptedRelationshipVaultCodec.magic.count
    let fixedHeaderBytes = magicBytes + 2 + 4
    guard data.count >= fixedHeaderBytes,
          data.prefix(magicBytes) == PasswordEncryptedRelationshipVaultCodec.magic else {
        throw TestEnvelopeError.malformed
    }

    let version = try readUInt16(data, at: magicBytes)
    let headerLength = Int(try readUInt32(data, at: magicBytes + 2))
    let headerStart = fixedHeaderBytes
    guard headerLength > 0, headerLength <= data.count - headerStart else {
        throw TestEnvelopeError.malformed
    }
    let headerEnd = headerStart + headerLength
    let header = try JSONDecoder().decode(
        PasswordEncryptedArchiveHeader.self,
        from: data.subdata(in: headerStart..<headerEnd)
    )

    let wrappedKeyStart = headerEnd
    let wrappedKeyEnd = wrappedKeyStart + header.keyWrap.wrappedKeyBytes
    guard header.keyWrap.wrappedKeyBytes == 48,
          wrappedKeyEnd <= data.count else {
        throw TestEnvelopeError.malformed
    }

    let chunkRecordStart = wrappedKeyEnd
    let chunkHeaderEnd = chunkRecordStart + 9
    guard chunkHeaderEnd <= data.count,
          data[chunkRecordStart] == 1,
          try readUInt32(data, at: chunkRecordStart + 1) == 0 else {
        throw TestEnvelopeError.malformed
    }
    let chunkLength = Int(try readUInt32(data, at: chunkRecordStart + 5))
    let chunkCiphertextStart = chunkHeaderEnd
    let chunkCiphertextEnd = chunkCiphertextStart + chunkLength
    let chunkTagEnd = chunkCiphertextEnd + 16
    guard chunkLength > 0, chunkTagEnd <= data.count else {
        throw TestEnvelopeError.malformed
    }

    let terminalRecordStart = chunkTagEnd
    let terminalHeaderEnd = terminalRecordStart + 9
    guard terminalHeaderEnd <= data.count,
          data[terminalRecordStart] == 255,
          try readUInt32(data, at: terminalRecordStart + 1) == UInt32.max else {
        throw TestEnvelopeError.malformed
    }
    let terminalLength = Int(try readUInt32(data, at: terminalRecordStart + 5))
    let terminalCiphertextStart = terminalHeaderEnd
    let terminalCiphertextEnd = terminalCiphertextStart + terminalLength
    let terminalTagEnd = terminalCiphertextEnd + 16
    guard terminalLength == 48, terminalTagEnd == data.count else {
        throw TestEnvelopeError.malformed
    }

    return TestEnvelopeLayout(
        version: version,
        header: header,
        wrappedKeyRange: wrappedKeyStart..<wrappedKeyEnd,
        chunkRecordRange: chunkRecordStart..<chunkTagEnd,
        chunkCiphertextRange: chunkCiphertextStart..<chunkCiphertextEnd,
        terminalRecordRange: terminalRecordStart..<terminalTagEnd,
        terminalCiphertextRange: terminalCiphertextStart..<terminalCiphertextEnd
    )
}

private func expectGenericOpenFailure(
    codec: PasswordEncryptedRelationshipVaultCodec,
    bytes: Data,
    password: String,
    named name: String,
    in temporaryDirectory: URL
) throws {
    let url = temporaryDirectory
        .appendingPathComponent(name)
        .appendingPathExtension("relationshipvault")
    try bytes.write(to: url, options: .atomic)
    #expect(throws: PasswordEncryptedArchiveError.cannotOpenArchive) {
        _ = try codec.decrypt(at: url, password: password)
    }
}

private func makeNotebookPackage(
    privateNote: String = "Prefers quiet coffee shops."
) throws -> VerifiedRelationshipVaultPackage {
    let personID = UUID(uuidString: "9AF650E4-94C0-4B12-87B5-2DF0A9FC0AA1")!
    let interactionID = UUID(uuidString: "00F6D330-A75D-4F81-96DA-5ED98D6255CC")!
    let instant = Date(timeIntervalSince1970: 1_752_000_000)
    let person = Person(
        id: personID,
        displayName: "Yuki Tanaka",
        contexts: ["Design community"],
        privateNote: privateNote,
        circle: .friends,
        createdAt: instant,
        modifiedAt: instant
    )
    let interaction = Interaction(
        id: interactionID,
        personID: personID,
        occurredAt: instant,
        kind: .meeting,
        direction: .mutual,
        channel: "In person",
        summary: "Planned an autumn museum visit.",
        commitment: "Send two possible dates."
    )
    let archive = NotebookArchive(
        exportedAt: instant,
        people: [person],
        interactions: [interaction]
    )
    return try RelationshipVaultPackageCodec().makePackage(
        archive: archive,
        mediaData: [:],
        localeIdentifier: "ja-JP"
    )
}

private func makeMediaNotebookPackage() throws -> (
    VerifiedRelationshipVaultPackage,
    UUID,
    Data
) {
    let person = Person(displayName: "Portrait owner")
    let jpeg = try makeTinyEncryptedArchiveJPEG()
    let checksum = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
    let asset = PortraitMediaAsset(
        personID: person.id,
        sha256: checksum,
        byteCount: Int64(jpeg.count),
        pixelWidth: 2,
        pixelHeight: 2,
        isPrimary: true
    )
    let archive = NotebookArchive(
        people: [person],
        interactions: [],
        canonical: CanonicalArchivePayload(portraitMedia: [asset])
    )
    let package = try RelationshipVaultPackageCodec().makePackage(
        archive: archive,
        mediaData: [asset.id: jpeg],
        localeIdentifier: "en-US"
    )
    return (package, asset.id, jpeg)
}

private func makeTinyEncryptedArchiveJPEG() throws -> Data {
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
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

private func encryptedWorkspaceNames() throws -> Set<String> {
    Set(
        try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        ).filter { $0.hasPrefix("Keepsake-Encrypted-") }
    )
}

private func authenticatedChunkCount(in data: Data) throws -> Int {
    let magicBytes = PasswordEncryptedRelationshipVaultCodec.magic.count
    let fixedHeaderBytes = magicBytes + 2 + 4
    guard data.count >= fixedHeaderBytes else { throw TestEnvelopeError.malformed }
    let headerLength = Int(try readUInt32(data, at: magicBytes + 2))
    var cursor = fixedHeaderBytes + headerLength + 48
    var expectedIndex: UInt32 = 0
    var chunkCount = 0

    while cursor <= data.count - 9 {
        let recordType = data[cursor]
        let index = try readUInt32(data, at: cursor + 1)
        let plaintextLength = Int(try readUInt32(data, at: cursor + 5))
        cursor += 9
        guard plaintextLength >= 0,
              cursor <= data.count - plaintextLength - 16 else {
            throw TestEnvelopeError.malformed
        }
        cursor += plaintextLength + 16
        if recordType == 1 {
            guard index == expectedIndex, plaintextLength > 0 else {
                throw TestEnvelopeError.malformed
            }
            expectedIndex += 1
            chunkCount += 1
            continue
        }
        guard recordType == 255,
              index == UInt32.max,
              plaintextLength == 48,
              cursor == data.count else {
            throw TestEnvelopeError.malformed
        }
        return chunkCount
    }
    throw TestEnvelopeError.malformed
}

private func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
    guard offset >= 0, offset <= data.count - 2 else {
        throw TestEnvelopeError.malformed
    }
    return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
}

private func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset <= data.count - 4 else {
        throw TestEnvelopeError.malformed
    }
    return (UInt32(data[offset]) << 24)
        | (UInt32(data[offset + 1]) << 16)
        | (UInt32(data[offset + 2]) << 8)
        | UInt32(data[offset + 3])
}
