import Foundation

public enum SearchNormalizer {
    public static func normalize(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
    }

    public static func matches(_ person: Person, query: String) -> Bool {
        let needle = normalize(query)
        guard !needle.isEmpty else { return true }
        let fields = [person.displayName, person.pronunciation, person.role, person.mentionableContext]
            + person.aliases + person.contexts + person.tags
        return fields.contains { normalize($0).contains(needle) }
    }
}
