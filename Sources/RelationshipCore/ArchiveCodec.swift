import Foundation

public enum ArchiveCodec {
    public static func encode(people: [Person], interactions: [Interaction]) throws -> Data {
        try encode(NotebookArchive(people: people, interactions: interactions))
    }

    public static func encode(_ archive: NotebookArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    public static func decode(_ data: Data) throws -> NotebookArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(NotebookArchive.self, from: data)
        guard archive.schemaVersion == 1 else {
            throw ArchiveError.unsupportedSchema(archive.schemaVersion)
        }
        return archive
    }

    public enum ArchiveError: LocalizedError {
        case unsupportedSchema(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                String(localized: "Archive schema \(version) is not supported.")
            }
        }
    }
}
