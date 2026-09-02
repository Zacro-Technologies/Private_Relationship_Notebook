import Foundation

public struct ImportLimits: Codable, Equatable, Sendable {
    public var maximumFileBytes: Int64
    public var maximumPages: Int
    public var maximumExtractedCharacters: Int
    public var maximumCandidates: Int
    public var maximumImagePixels: Int64

    public init(
        maximumFileBytes: Int64 = 200 * 1_024 * 1_024,
        maximumPages: Int = 500,
        maximumExtractedCharacters: Int = 5_000_000,
        maximumCandidates: Int = 50_000,
        maximumImagePixels: Int64 = 80_000_000
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumPages = maximumPages
        self.maximumExtractedCharacters = maximumExtractedCharacters
        self.maximumCandidates = maximumCandidates
        self.maximumImagePixels = maximumImagePixels
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var cloudContainerIdentifier: String?
    public var importLimits: ImportLimits
    public var tombstoneRetentionDays: Int
    public var indexSchemaVersion: Int

    public init(
        schemaVersion: Int = 1,
        cloudContainerIdentifier: String? = nil,
        importLimits: ImportLimits = .init(),
        tombstoneRetentionDays: Int = 30,
        indexSchemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.cloudContainerIdentifier = cloudContainerIdentifier
        self.importLimits = importLimits
        self.tombstoneRetentionDays = tombstoneRetentionDays
        self.indexSchemaVersion = indexSchemaVersion
    }

    public static func bundled(_ bundle: Bundle = .main) -> AppConfiguration {
        let container = (bundle.object(forInfoDictionaryKey: "CloudContainerIdentifier") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return AppConfiguration(cloudContainerIdentifier: container)
    }
}
