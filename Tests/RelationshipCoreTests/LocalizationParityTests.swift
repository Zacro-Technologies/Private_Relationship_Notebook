import Foundation
import Testing

private enum LocalizationCatalogError: Error {
    case resourcesDirectoryNotFound
    case invalidStringsFile(URL)
}

private func repositoryRootContainingLocalizationResources() throws -> URL {
    let fileManager = FileManager.default
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    while candidate.path != "/" {
        let englishCatalog = candidate
            .appendingPathComponent("Resources/en.lproj/Localizable.strings")
        let japaneseCatalog = candidate
            .appendingPathComponent("Resources/ja.lproj/Localizable.strings")

        if fileManager.fileExists(atPath: englishCatalog.path),
           fileManager.fileExists(atPath: japaneseCatalog.path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }

    throw LocalizationCatalogError.resourcesDirectoryNotFound
}

private func localizationEntries(at url: URL) throws -> [String: String] {
    let data = try Data(contentsOf: url)
    let propertyList = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    )
    guard let entries = propertyList as? [String: String] else {
        throw LocalizationCatalogError.invalidStringsFile(url)
    }
    return entries
}

private func duplicateLocalizationKeys(at url: URL) throws -> Set<String> {
    let source = try String(contentsOf: url, encoding: .utf8)
    let expression = try! NSRegularExpression(
        pattern: #"(?m)^\s*"((?:\\.|[^"\\])*)"\s*="#
    )
    let range = NSRange(source.startIndex..., in: source)
    var counts: [String: Int] = [:]
    for match in expression.matches(in: source, range: range) {
        guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
        counts[String(source[keyRange]), default: 0] += 1
    }
    return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
}

private func formatTokens(in value: String) -> [String] {
    let pattern = #"%(?:[0-9]+\$)?(?:@|lld|ld|d)"#
    let expression = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap { match in
        Range(match.range, in: value).map { String(value[$0]) }
    }
}

private let localizationAwareLiteralCalls: [String] = [
    "String\\s*\\(\\s*localized\\s*:",
    "Text\\s*\\(",
    "Label\\s*\\(",
    "Button\\s*\\(",
    "NavigationLink\\s*\\(",
    "Section\\s*\\(",
    "Toggle\\s*\\(",
    "Picker\\s*\\(",
    "TextField\\s*\\(",
    "SecureField\\s*\\(",
    "DatePicker\\s*\\(",
    "Stepper\\s*\\(",
    "LabeledContent\\s*\\(",
    "StructuredPartialDateField\\s*\\(",
    "ContentUnavailableView\\s*\\(",
    "DisclosureGroup\\s*\\(",
    "Menu\\s*\\(",
    "SharePreview\\s*\\(",
    "navigationTitle\\s*\\(",
    "alert\\s*\\(",
    "confirmationDialog\\s*\\(",
    "help\\s*\\(",
    "accessibilityLabel\\s*\\(",
    "accessibilityHint\\s*\\("
]

/// Converts a literal such as `"Last contact \(date)"` to the catalog shape
/// `"Last contact %@"`. The interpolation scanner balances nested calls and
/// ignores parentheses inside strings such as `joined(separator: ", ")`.
private func parsedLocalizedLiteral(
    in source: String,
    contentStart: String.Index
) -> String? {
    var result = ""
    var index = contentStart

    while index < source.endIndex {
        let character = source[index]
        if character == "\"" { return result }
        guard character == "\\" else {
            result.append(character)
            index = source.index(after: index)
            continue
        }

        let escapedIndex = source.index(after: index)
        guard escapedIndex < source.endIndex else { return nil }
        let escaped = source[escapedIndex]
        if escaped != "(" {
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            default: result.append(escaped)
            }
            index = source.index(after: escapedIndex)
            continue
        }

        result += "%@"
        var depth = 1
        var inNestedString = false
        var isEscaped = false
        index = source.index(after: escapedIndex)
        while index < source.endIndex, depth > 0 {
            let nested = source[index]
            if inNestedString {
                if isEscaped {
                    isEscaped = false
                } else if nested == "\\" {
                    isEscaped = true
                } else if nested == "\"" {
                    inNestedString = false
                }
            } else if nested == "\"" {
                inNestedString = true
            } else if nested == "(" {
                depth += 1
            } else if nested == ")" {
                depth -= 1
            }
            index = source.index(after: index)
        }
        guard depth == 0 else { return nil }
    }
    return nil
}

private func localizedLiteralKeys(in source: String) -> Set<String> {
    let callPattern = "(?:" + localizationAwareLiteralCalls.joined(separator: "|") + ")\\s*\""
    let expression = try! NSRegularExpression(pattern: callPattern)
    let sourceRange = NSRange(source.startIndex..., in: source)
    var keys = Set<String>()

    for match in expression.matches(in: source, range: sourceRange) {
        guard let matchRange = Range(match.range, in: source) else { continue }
        let contentStart = matchRange.upperBound
        if let key = parsedLocalizedLiteral(in: source, contentStart: contentStart), !key.isEmpty {
            keys.insert(key)
        }
    }
    return keys
}

private func formatCanonicalized(_ value: String) -> String {
    let pattern = #"%(?:[0-9]+\$)?(?:@|lld|ld|d)"#
    let expression = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(value.startIndex..., in: value)
    return expression.stringByReplacingMatches(in: value, range: range, withTemplate: "%@")
}

@Test func englishAndJapaneseLocalizationCatalogsHaveIdenticalKeySets() throws {
    let root = try repositoryRootContainingLocalizationResources()
    let englishURL = root.appendingPathComponent("Resources/en.lproj/Localizable.strings")
    let japaneseURL = root.appendingPathComponent("Resources/ja.lproj/Localizable.strings")
    let english = try localizationEntries(at: englishURL)
    let japanese = try localizationEntries(at: japaneseURL)

    let englishKeys = Set(english.keys)
    let japaneseKeys = Set(japanese.keys)

    #expect(englishKeys == japaneseKeys)
    #expect(try duplicateLocalizationKeys(at: englishURL).isEmpty)
    #expect(try duplicateLocalizationKeys(at: japaneseURL).isEmpty)
    #expect(englishKeys.count >= 1_000)
    #expect(english.values.allSatisfy { !$0.isEmpty })
    #expect(japanese.values.allSatisfy { !$0.isEmpty })

    for key in englishKeys {
        #expect(formatTokens(in: english[key]!) == formatTokens(in: japanese[key]!))
    }

    let requiredSyncKeys: Set<String> = [
        "Local only",
        "Waiting for iCloud",
        "Syncing",
        "Up to date",
        "Needs attention",
        "Saved locally; waiting to synchronize changes.",
        "Synchronization needs attention. Local changes are safe."
    ]
    #expect(requiredSyncKeys.isSubset(of: englishKeys))
}

@Test func userFacingSwiftLiteralsExistInBothLocalizationCatalogs() throws {
    let root = try repositoryRootContainingLocalizationResources()
    let english = try localizationEntries(
        at: root.appendingPathComponent("Resources/en.lproj/Localizable.strings")
    )
    let japanese = try localizationEntries(
        at: root.appendingPathComponent("Resources/ja.lproj/Localizable.strings")
    )
    var sourceKeys = Set<String>()
    let productionSourceDirectories = [
        "RelationshipCore",
        "RelationshipNotebookApp",
    ]
    for directory in productionSourceDirectories {
        let sourceRoot = root.appendingPathComponent("Sources/\(directory)")
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            sourceKeys.formUnion(
                localizedLiteralKeys(
                    in: try String(contentsOf: url, encoding: .utf8)
                )
            )
        }
    }

    let englishCanonical = Set(english.keys.map(formatCanonicalized))
    let japaneseCanonical = Set(japanese.keys.map(formatCanonicalized))
    let missingEnglish = sourceKeys.filter { !englishCanonical.contains(formatCanonicalized($0)) }.sorted()
    let missingJapanese = sourceKeys.filter { !japaneseCanonical.contains(formatCanonicalized($0)) }.sorted()

    #expect(missingEnglish.isEmpty, "Missing English localization keys: \(missingEnglish)")
    #expect(missingJapanese.isEmpty, "Missing Japanese localization keys: \(missingJapanese)")
    #expect(sourceKeys.count >= 1_000)
}

@Test func shareExtensionCatalogsHaveEnglishJapaneseParity() throws {
    let root = try repositoryRootContainingLocalizationResources()
    for filename in ["Localizable.strings", "InfoPlist.strings"] {
        let englishURL = root.appendingPathComponent("ShareExtension/en.lproj/\(filename)")
        let japaneseURL = root.appendingPathComponent("ShareExtension/ja.lproj/\(filename)")
        let english = try localizationEntries(at: englishURL)
        let japanese = try localizationEntries(at: japaneseURL)

        #expect(Set(english.keys) == Set(japanese.keys))
        #expect(try duplicateLocalizationKeys(at: englishURL).isEmpty)
        #expect(try duplicateLocalizationKeys(at: japaneseURL).isEmpty)
        #expect(!english.isEmpty)
        #expect(english.values.allSatisfy { !$0.isEmpty })
        #expect(japanese.values.allSatisfy { !$0.isEmpty })

        for key in english.keys {
            #expect(formatTokens(in: english[key]!) == formatTokens(in: japanese[key]!))
        }
    }
}
