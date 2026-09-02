import Social
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
    private var isSaving = false
    private var writer: SharedCaptureWriter?

    override func isContentValid() -> Bool {
        let hasText = !(contentText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let hasAttachment = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .contains { !($0.attachments ?? []).isEmpty } == true
        return !isSaving && (hasText || hasAttachment)
    }

    override func didSelectPost() {
        guard !isSaving else { return }
        isSaving = true
        validateContent()
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let writer = SharedCaptureWriter()
        self.writer = writer
        writer.persist(items: items, comment: contentText) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.writer = nil
                switch result {
                case .success(let requestID):
                    let URL = URL(string: "keepsake://shared-capture/\(requestID.uuidString)")
                    guard let URL else {
                        self.finish()
                        return
                    }
                    self.extensionContext?.open(URL) { [weak self] _ in
                        // The protected App Group inbox is durable even when
                        // iOS chooses not to foreground the containing app.
                        DispatchQueue.main.async { self?.finish() }
                    }
                case .failure(let error):
                    self.isSaving = false
                    self.validateContent()
                    self.presentError(error.localizedDescription)
                }
            }
        }
    }

    override func configurationItems() -> [Any]! {
        [
            SLComposeSheetConfigurationItem()!.configured(
                title: sharedLocalized("Review before saving"),
                value: sharedLocalized("No notebook records are created here")
            ),
            SLComposeSheetConfigurationItem()!.configured(
                title: sharedLocalized("Privacy"),
                value: sharedLocalized("Queued in protected local storage")
            )
        ]
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(
            title: sharedLocalized("Couldn’t queue this share"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: sharedLocalized("OK"), style: .default))
        present(alert, animated: true)
    }
}

private extension SLComposeSheetConfigurationItem {
    func configured(title: String, value: String) -> Self {
        self.title = title
        self.value = value
        return self
    }
}

private final class SharedCaptureWriter: @unchecked Sendable {
    private static let appGroupIdentifier = "group.com.zacrotech.RelationshipNotebook"
    private static let inboxDirectoryName = "KeepsakeSharedCaptures"
    private static let maximumFileCount = 20
    private static let maximumTotalBytes: Int64 = 100 * 1_024 * 1_024

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var storedEntries: [SharedCaptureManifest.FileEntry] = []
    private var firstError: Error?
    private var totalBytes: Int64 = 0

    func persist(
        items: [NSExtensionItem],
        comment: String?,
        completion: @escaping (Result<UUID, Error>) -> Void
    ) {
        guard let groupRoot = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            completion(.failure(SharedCaptureWriteError.appGroupUnavailable))
            return
        }

        let requestID = UUID()
        let requestDirectory = groupRoot
            .appendingPathComponent(Self.inboxDirectoryName, isDirectory: true)
            .appendingPathComponent(requestID.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: requestDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        } catch {
            completion(.failure(error))
            return
        }

        let providers = items.flatMap { $0.attachments ?? [] }
        let trimmedComment = (comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard providers.count + (trimmedComment.isEmpty ? 0 : 1) <= Self.maximumFileCount else {
            try? fileManager.removeItem(at: requestDirectory)
            completion(.failure(SharedCaptureWriteError.tooManyItems))
            return
        }

        if !trimmedComment.isEmpty {
            do {
                try persistData(
                    Data(trimmedComment.utf8),
                    suggestedName: "Shared-note.txt",
                    contentType: UTType.plainText.identifier,
                    requestDirectory: requestDirectory,
                    ordinal: 0
                )
            } catch {
                try? fileManager.removeItem(at: requestDirectory)
                completion(.failure(error))
                return
            }
        }

        guard !providers.isEmpty else {
            finish(requestID: requestID, requestDirectory: requestDirectory, completion: completion)
            return
        }

        let group = DispatchGroup()
        for (offset, provider) in providers.enumerated() {
            group.enter()
            load(provider: provider, ordinal: offset + 1, into: requestDirectory) { [weak self] result in
                if case .failure(let error) = result {
                    self?.record(error: error)
                }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self else { return }
            self.finish(
                requestID: requestID,
                requestDirectory: requestDirectory,
                completion: completion
            )
        }
    }

    private func load(
        provider: NSItemProvider,
        ordinal: Int,
        into requestDirectory: URL,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard let identifier = preferredIdentifier(for: provider) else {
            completion(.failure(SharedCaptureWriteError.unsupportedItem))
            return
        }
        provider.loadItem(forTypeIdentifier: identifier, options: nil) { [weak self] item, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            do {
                switch item {
                case let URL as URL where URL.isFileURL:
                    let accessed = URL.startAccessingSecurityScopedResource()
                    defer { if accessed { URL.stopAccessingSecurityScopedResource() } }
                    if let byteCount = try URL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       Int64(byteCount) > Self.maximumTotalBytes {
                        throw SharedCaptureWriteError.tooLarge
                    }
                    let data = try Data(contentsOf: URL, options: [.mappedIfSafe])
                    try self.persistData(
                        data,
                        suggestedName: URL.lastPathComponent,
                        contentType: identifier,
                        requestDirectory: requestDirectory,
                        ordinal: ordinal
                    )
                case let URL as URL:
                    try self.persistData(
                        Data(URL.absoluteString.utf8),
                        suggestedName: "Shared-link.txt",
                        contentType: UTType.plainText.identifier,
                        requestDirectory: requestDirectory,
                        ordinal: ordinal
                    )
                case let text as String:
                    try self.persistData(
                        Data(text.utf8),
                        suggestedName: "Shared-text.txt",
                        contentType: UTType.plainText.identifier,
                        requestDirectory: requestDirectory,
                        ordinal: ordinal
                    )
                case let attributed as NSAttributedString:
                    try self.persistData(
                        Data(attributed.string.utf8),
                        suggestedName: "Shared-text.txt",
                        contentType: UTType.plainText.identifier,
                        requestDirectory: requestDirectory,
                        ordinal: ordinal
                    )
                case let data as Data:
                    try self.persistData(
                        data,
                        suggestedName: "Shared-item.\(UTType(identifier)?.preferredFilenameExtension ?? "data")",
                        contentType: identifier,
                        requestDirectory: requestDirectory,
                        ordinal: ordinal
                    )
                case let image as UIImage:
                    guard let data = image.pngData() else {
                        throw SharedCaptureWriteError.unreadableItem
                    }
                    try self.persistData(
                        data,
                        suggestedName: "Shared-image.png",
                        contentType: UTType.png.identifier,
                        requestDirectory: requestDirectory,
                        ordinal: ordinal
                    )
                default:
                    throw SharedCaptureWriteError.unreadableItem
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func preferredIdentifier(for provider: NSItemProvider) -> String? {
        let preferred = [
            "com.zacrotech.keepsake.profile-snapshot-v1",
            "com.zacrotech.keepsake.encrypted-relationship-vault",
            "com.zacrotech.keepsake.relationship-vault",
            UTType.fileURL.identifier,
            UTType.pdf.identifier,
            UTType.image.identifier,
            UTType.plainText.identifier,
            UTType.text.identifier,
            UTType.url.identifier,
            UTType.data.identifier
        ]
        return preferred.first(where: provider.hasItemConformingToTypeIdentifier)
            ?? provider.registeredTypeIdentifiers.first
    }

    private func persistData(
        _ data: Data,
        suggestedName: String,
        contentType: String,
        requestDirectory: URL,
        ordinal: Int
    ) throws {
        let byteCount = Int64(data.count)
        lock.lock()
        defer { lock.unlock() }
        guard totalBytes + byteCount <= Self.maximumTotalBytes else {
            throw SharedCaptureWriteError.tooLarge
        }
        let lastPathComponent = URL(fileURLWithPath: suggestedName).lastPathComponent
        let cleaned = lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let filename = String(format: "%02d-%@", ordinal, cleaned.isEmpty ? "Shared-item.data" : cleaned)
        let destination = requestDirectory.appendingPathComponent(filename)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        totalBytes += byteCount
        storedEntries.append(.init(filename: filename, contentType: contentType))
    }

    private func record(error: Error) {
        lock.lock()
        if firstError == nil { firstError = error }
        lock.unlock()
    }

    private func finish(
        requestID: UUID,
        requestDirectory: URL,
        completion: @escaping (Result<UUID, Error>) -> Void
    ) {
        lock.lock()
        let error = firstError
        let entries = storedEntries.sorted { $0.filename < $1.filename }
        lock.unlock()
        if let error {
            try? fileManager.removeItem(at: requestDirectory)
            completion(.failure(error))
            return
        }
        do {
            let manifest = SharedCaptureManifest(
                version: 1,
                id: requestID,
                createdAt: .now,
                files: entries
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(
                to: requestDirectory.appendingPathComponent("manifest.json"),
                options: [.atomic, .completeFileProtection]
            )
            completion(.success(requestID))
        } catch {
            try? fileManager.removeItem(at: requestDirectory)
            completion(.failure(error))
        }
    }
}

private struct SharedCaptureManifest: Codable {
    struct FileEntry: Codable {
        let filename: String
        let contentType: String
    }

    let version: Int
    let id: UUID
    let createdAt: Date
    let files: [FileEntry]
}

private enum SharedCaptureWriteError: LocalizedError {
    case appGroupUnavailable
    case tooManyItems
    case tooLarge
    case unsupportedItem
    case unreadableItem

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            sharedLocalized("The protected Keepsake Share inbox is unavailable in this build.")
        case .tooManyItems:
            sharedLocalized("Share no more than 20 items at once.")
        case .tooLarge:
            sharedLocalized("This share is larger than the 100 MB review limit.")
        case .unsupportedItem:
            sharedLocalized("The source app did not provide a supported text, image, PDF, URL, or document representation.")
        case .unreadableItem:
            sharedLocalized("The source app’s shared item could not be read.")
        }
    }
}

private func sharedLocalized(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}
