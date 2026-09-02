import Testing
@testable import RelationshipCore

struct SensitiveFieldPolicyTests {
    @Test func credentialLikeCustomFieldsAreBlockedInEnglishAndJapanese() {
        #expect(SensitiveFieldPolicy.credentialWarning(for: "Wi-Fi password") != nil)
        #expect(SensitiveFieldPolicy.credentialWarning(for: "Door PIN") != nil)
        #expect(SensitiveFieldPolicy.credentialWarning(for: "銀行の暗証番号") != nil)
        #expect(SensitiveFieldPolicy.credentialWarning(for: "Campaign notes") == nil)
        #expect(SensitiveFieldPolicy.credentialWarning(for: "Favorite meal") == nil)
    }

    @Test func credentialLikePrivateNoteContentsAreBlockedWithoutRejectingOrdinaryMemories() {
        #expect(SensitiveFieldPolicy.credentialWarning(
            forPrivateNote: "Their Wi-Fi password is written on the router."
        ) != nil)
        #expect(SensitiveFieldPolicy.credentialWarning(
            forPrivateNote: "次回の認証コードは 123456"
        ) != nil)
        #expect(SensitiveFieldPolicy.credentialWarning(
            forPrivateNote: "Their credit-card number is in the shared document."
        ) != nil)
        #expect(SensitiveFieldPolicy.credentialWarning(
            forPrivateNote: "Prefers quiet coffee shops and usually meets on Fridays."
        ) == nil)
    }

    @Test func canonicalFactValuesDetectLabelsAndRecognizableSecretShapes() {
        #expect(SensitiveFieldPolicy.credentialWarning(
            forFactValue: .text("password: hunter2")
        ) != nil)
        #expect(SensitiveFieldPolicy.credentialWarning(
            forFactValue: .structuredJSON(.object(["apiKey": .string("abc123")]))
        ) != nil)
        #expect(SensitiveFieldPolicy.credentialWarning(
            forFactValue: .text("ghp_1234567890abcdefghijklmnop")
        ) != nil)
        #expect(SensitiveFieldPolicy.credentialWarning(
            forFactValue: .text("Prefers quiet coffee shops on Fridays")
        ) == nil)
    }
}
