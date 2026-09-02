import Foundation

public enum SensitiveFieldPolicy {
    /// Relationship notebooks are not credential managers. This deliberately favors false
    /// positives so a user is redirected before secrets become searchable or synchronized.
    public static func credentialWarning(for label: String) -> String? {
        credentialWarning(in: label)
    }

    /// Applies the same deny-first credential boundary to a private note's
    /// contents. A note is a manual memory aid, not a fallback secret store.
    /// Existing notes are never mutated by this check; editors use it only to
    /// reject newly entered or changed credential-like content.
    public static func credentialWarning(forPrivateNote note: String) -> String? {
        credentialWarning(in: note)
    }

    /// Applies credential detection to the assertion payload, rather than only
    /// to its user-facing field label. This is the canonical fact write
    /// boundary used by `CanonicalVaultStore`; UI checks are only an earlier
    /// explanation of the same policy.
    public static func credentialWarning(forFactValue value: TypedValue) -> String? {
        factStrings(in: value).lazy.compactMap(credentialWarning(in:)).first
    }

    private static func credentialWarning(in value: String) -> String? {
        let normalized = SearchNormalizer.normalize(value)
        let blockedTokens = [
            "password", "passwd", "passcode", "pincode", "otp", "totp", "2fa", "mfa",
            "recoverycode", "backupcode", "secretkey", "privatekey", "apikey",
            "accesskey", "accesstoken", "refreshtoken", "authtoken", "sessiontoken",
            "securityanswer", "seedphrase", "mnemonic", "creditcardnumber", "cardnumber",
            "cvv", "cvc", "bankaccountnumber", "routingnumber", "暗証番号",
            "パスワード", "秘密鍵", "復旧コード", "認証コード",
            "アクセストークン", "シードフレーズ", "カード番号", "口座番号"
        ]
        let containsStandalonePIN = value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains { SearchNormalizer.normalize($0) == "pin" }
        let recognizableSecret = secretPatterns.contains { pattern in
            value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let containsPaymentCard = likelyPaymentCardNumber(in: value)
        guard containsStandalonePIN || recognizableSecret || containsPaymentCard ||
                blockedTokens.contains(where: normalized.contains) else { return nil }
        return String(localized: "Credentials and authentication secrets do not belong in this notebook. Use a password manager instead.")
    }

    private static let secretPatterns = [
        #"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,
        #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,
        #"\bsk-[A-Za-z0-9_-]{16,}\b"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
        #"://[^/\s:@]+:[^@\s/]+@"#
    ]

    private static func factStrings(in value: TypedValue) -> [String] {
        switch value {
        case .text(let value), .richText(let value), .language(let value),
             .email(let value), .phone(let value):
            [value]
        case .url(let value):
            [value.absoluteString]
        case .location(let value):
            [value.label]
        case .address(let value):
            [value.street, value.locality, value.administrativeArea, value.postalCode, value.countryCode]
                .compactMap { $0 }
        case .structuredJSON(let value):
            strings(in: value)
        case .number, .boolean, .partialDate, .dateRange, .singleSelect,
             .multiSelect, .personReference, .contextReference, .mediaReference:
            []
        }
    }

    private static func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let value):
            [value]
        case .object(let values):
            values.flatMap { key, value in [key] + strings(in: value) }
        case .array(let values):
            values.flatMap(strings(in:))
        case .number, .boolean, .null:
            []
        }
    }

    /// Detects a bare card number only after a Luhn check, avoiding ordinary
    /// phone numbers and dates. Separators are accepted, but surrounding prose
    /// is not treated as a number unless it contains a 13...19 digit run.
    private static func likelyPaymentCardNumber(in value: String) -> Bool {
        var candidates: [[Int]] = []
        var current: [Int] = []
        func finishCandidate() {
            if !current.isEmpty { candidates.append(current) }
            current.removeAll(keepingCapacity: true)
        }
        for character in value {
            if let digit = character.wholeNumberValue {
                current.append(digit)
            } else if (character == " " || character == "-") && !current.isEmpty {
                continue
            } else {
                finishCandidate()
            }
        }
        finishCandidate()

        return candidates.contains { digits in
            guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
            var sum = 0
            for (offset, digit) in digits.reversed().enumerated() {
                if offset.isMultiple(of: 2) {
                    sum += digit
                } else {
                    let doubled = digit * 2
                    sum += doubled > 9 ? doubled - 9 : doubled
                }
            }
            return sum.isMultiple(of: 10)
        }
    }
}
