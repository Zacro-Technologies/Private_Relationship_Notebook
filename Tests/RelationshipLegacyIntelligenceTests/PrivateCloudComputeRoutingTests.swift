import Foundation
import Testing
@testable import RelationshipCore
@testable import RelationshipLegacyIntelligence

private struct LocalInvocation: Equatable, Sendable {
    var instructions: String
    var prompt: String
}

private struct CloudInvocation: Equatable, Sendable {
    var instructions: String
    var prompt: String
    var reasoningLevel: IntelligenceReasoningLevel
}

private enum StubbedResponse: Sendable {
    case success(String)
    case failure(IntelligenceFailureKind)
}

private actor StubLocalIntelligenceClient: TextIntelligenceClient {
    private let advertisedCapability: OnDeviceIntelligenceCapability
    private let response: StubbedResponse
    private(set) var capabilityCallCount = 0
    private(set) var invocations: [LocalInvocation] = []

    init(
        capability: OnDeviceIntelligenceCapability,
        response: StubbedResponse = .success("local")
    ) {
        advertisedCapability = capability
        self.response = response
    }

    func capability() async -> OnDeviceIntelligenceCapability {
        capabilityCallCount += 1
        return advertisedCapability
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        invocations.append(.init(instructions: instructions, prompt: prompt))
        switch response {
        case .success(let output):
            return output
        case .failure(let kind):
            throw IntelligenceRouteFailure(kind)
        }
    }
}

private actor StubPrivateCloudIntelligenceClient: PrivateCloudTextIntelligenceClient {
    private let advertisedCapability: PrivateCloudComputeCapability
    private let response: StubbedResponse
    private let quotaSuggestionResult: Bool
    private(set) var capabilityCallCount = 0
    private(set) var invocations: [CloudInvocation] = []
    private(set) var quotaSuggestionCallCount = 0

    init(
        capability: PrivateCloudComputeCapability,
        response: StubbedResponse = .success("cloud"),
        quotaSuggestionResult: Bool = false
    ) {
        advertisedCapability = capability
        self.response = response
        self.quotaSuggestionResult = quotaSuggestionResult
    }

    func capability() async -> PrivateCloudComputeCapability {
        capabilityCallCount += 1
        return advertisedCapability
    }

    func respond(
        instructions: String,
        prompt: String,
        reasoningLevel: IntelligenceReasoningLevel
    ) async throws -> String {
        invocations.append(.init(
            instructions: instructions,
            prompt: prompt,
            reasoningLevel: reasoningLevel
        ))
        switch response {
        case .success(let output):
            return output
        case .failure(let kind):
            throw IntelligenceRouteFailure(kind)
        }
    }

    func presentQuotaIncreaseSuggestion() async -> Bool {
        quotaSuggestionCallCount += 1
        return quotaSuggestionResult
    }
}

private let pccTestLocalCapability = OnDeviceIntelligenceCapability(
    isSDKAvailable: true,
    isRuntimeAvailable: true,
    evaluatedContextLimit: 4_096
)

private let pccTestCloudCapability = PrivateCloudComputeCapability(
    isSDKAvailable: true,
    isEntitled: true,
    isRegionEligible: true,
    isRuntimeAvailable: true,
    isNetworkPathAvailable: true,
    isQuotaAvailable: true,
    evaluatedContextLimit: 32_768,
    quotaState: .belowLimit(isApproaching: false, resetDate: nil),
    canPresentQuotaIncreaseSuggestion: true
)

@Test func intelligenceCapabilityDetectorCombinesIndependentClients() async {
    let local = StubLocalIntelligenceClient(capability: pccTestLocalCapability)
    let cloud = StubPrivateCloudIntelligenceClient(capability: pccTestCloudCapability)
    let detector = IntelligenceCapabilityDetector(
        localClient: local,
        privateCloudClient: cloud
    )

    let detected = await detector.capabilities()

    #expect(detected.onDevice == pccTestLocalCapability)
    #expect(detected.privateCloudCompute == pccTestCloudCapability)
    #expect(await local.capabilityCallCount == 1)
    #expect(await cloud.capabilityCallCount == 1)
}

@Test func routedServiceNeverSendsRestrictedOrDeniedInputToPCC() async {
    let local = StubLocalIntelligenceClient(
        capability: pccTestLocalCapability,
        response: .success("device-only answer")
    )
    let cloud = StubPrivateCloudIntelligenceClient(
        capability: pccTestCloudCapability,
        response: .success("must not be used")
    )
    let service = RoutedTextIntelligenceService(
        localClient: local,
        privateCloudClient: cloud
    )
    let restrictedRequest = IntelligenceRequest(
        task: .summary,
        mode: .bestQuality,
        sourcePolicy: .onDeviceOnly,
        estimatedTokens: 800
    )

    let restrictedOutcome = await service.respond(
        to: restrictedRequest,
        instructions: "private instructions",
        prompt: "private prompt"
    )

    switch restrictedOutcome {
    case .suggestion(let suggestion):
        #expect(suggestion.route == .onDevice)
        #expect(suggestion.output == "device-only answer")
    case .manual, .cancelled:
        Issue.record("An on-device-only request should use the available local model")
    }
    #expect(await local.invocations == [
        .init(instructions: "private instructions", prompt: "private prompt")
    ])
    #expect(await cloud.invocations.isEmpty)

    let deniedRequest = IntelligenceRequest(
        task: .structuredExtraction,
        mode: .bestQuality,
        sourcePolicy: .modelsDenied,
        estimatedTokens: 800
    )
    let deniedOutcome = await service.respond(
        to: deniedRequest,
        instructions: "denied instructions",
        prompt: "denied prompt",
        deterministicFallback: "literal extraction"
    )

    switch deniedOutcome {
    case .suggestion(let suggestion):
        #expect(suggestion.route == .deterministic)
        #expect(suggestion.output == "literal extraction")
    case .manual, .cancelled:
        Issue.record("A denied model request should retain its deterministic path")
    }
    #expect(await local.invocations.count == 1)
    #expect(await cloud.invocations.isEmpty)
}

@Test func routedServiceRestartsLocallyAfterEligiblePCCFailure() async {
    let local = StubLocalIntelligenceClient(
        capability: pccTestLocalCapability,
        response: .success("fresh local answer")
    )
    let cloud = StubPrivateCloudIntelligenceClient(
        capability: pccTestCloudCapability,
        response: .failure(.quotaReached)
    )
    let service = RoutedTextIntelligenceService(
        localClient: local,
        privateCloudClient: cloud
    )
    let request = IntelligenceRequest(
        task: .summary,
        mode: .bestQuality,
        estimatedTokens: 1_200,
        requiresEvaluatedReasoning: true
    )

    let outcome = await service.respond(
        to: request,
        instructions: "summarize conservatively",
        prompt: "prepared source"
    )

    switch outcome {
    case .suggestion(let suggestion):
        #expect(suggestion.route == .onDevice)
        #expect(suggestion.output == "fresh local answer")
    case .manual, .cancelled:
        Issue.record("Quota failure should start an independent local attempt")
    }
    #expect(await cloud.invocations == [
        .init(
            instructions: "summarize conservatively",
            prompt: "prepared source",
            reasoningLevel: .moderate
        )
    ])
    #expect(await local.invocations == [
        .init(instructions: "summarize conservatively", prompt: "prepared source")
    ])
}

@Test func routedServiceDoesNotRetrySafetyRefusalLocally() async {
    let local = StubLocalIntelligenceClient(
        capability: pccTestLocalCapability,
        response: .success("unsafe retry")
    )
    let cloud = StubPrivateCloudIntelligenceClient(
        capability: pccTestCloudCapability,
        response: .failure(.safetyRefusal)
    )
    let service = RoutedTextIntelligenceService(
        localClient: local,
        privateCloudClient: cloud
    )
    let request = IntelligenceRequest(
        task: .messageDraft,
        mode: .bestQuality,
        estimatedTokens: 500
    )

    let outcome = await service.respond(
        to: request,
        instructions: "draft",
        prompt: "prepared source"
    )

    switch outcome {
    case .manual(let fallback):
        #expect(fallback.reason == .nonFallbackFailureRequiresManualReview)
        #expect(fallback.attemptedRoutes == [.privateCloudCompute])
    case .suggestion, .cancelled:
        Issue.record("A PCC safety refusal must stop automatic model routing")
    }
    #expect(await cloud.invocations.count == 1)
    #expect(await local.invocations.isEmpty)
}

@Test func reachedQuotaIsConservativelyUnusableAndRoutesLocally() async {
    let resetDate = Date(timeIntervalSince1970: 2_000_000_000)
    let reachedQuota = PrivateCloudComputeCapability(
        isSDKAvailable: true,
        isEntitled: true,
        isRegionEligible: true,
        isRuntimeAvailable: true,
        isNetworkPathAvailable: true,
        // A stale optimistic Boolean must not override the structured state.
        isQuotaAvailable: true,
        evaluatedContextLimit: 32_768,
        quotaState: .limitReached(resetDate: resetDate),
        canPresentQuotaIncreaseSuggestion: true
    )
    #expect(!reachedQuota.isQuotaAvailable)
    #expect(!reachedQuota.isUsable)
    #expect(reachedQuota.primaryUnavailabilityReason == .quotaReached)
    #expect(reachedQuota.quotaState.resetDate == resetDate)

    let local = StubLocalIntelligenceClient(capability: pccTestLocalCapability)
    let cloud = StubPrivateCloudIntelligenceClient(
        capability: reachedQuota,
        response: .success("must not be used"),
        quotaSuggestionResult: true
    )
    let service = RoutedTextIntelligenceService(
        localClient: local,
        privateCloudClient: cloud
    )
    let request = IntelligenceRequest(
        task: .summary,
        mode: .bestQuality,
        estimatedTokens: 500
    )

    let plan = await service.plan(for: request)
    #expect(plan.steps.map(\.route) == [.onDevice, .manual])
    #expect(plan.notices.contains(.cloudUnavailable))
    let outcome = await service.respond(
        to: request,
        instructions: "summarize",
        prompt: "prepared source"
    )
    if case .suggestion(let suggestion) = outcome {
        #expect(suggestion.route == .onDevice)
    } else {
        Issue.record("A reached PCC quota should route to the usable local model")
    }
    #expect(await cloud.invocations.isEmpty)
    #expect(await service.presentQuotaIncreaseSuggestion())
    #expect(await cloud.quotaSuggestionCallCount == 1)
}

private final class EntitlementProbe:
    @unchecked Sendable,
    PrivateCloudComputeEntitlementChecking {
    private let lock = NSLock()
    private var callCountStorage = 0
    private let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func hasPrivateCloudComputeEntitlement() -> Bool {
        lock.withLock { callCountStorage += 1 }
        return result
    }

    var callCount: Int {
        lock.withLock { callCountStorage }
    }
}

private actor NetworkProbe: IntelligenceNetworkPathChecking {
    private let result: Bool
    private(set) var callCount = 0

    init(result: Bool) {
        self.result = result
    }

    func isNetworkPathAvailable() async -> Bool {
        callCount += 1
        return result
    }
}

@Test func disabledPCCFeatureGateStopsBeforeEntitlementOrNetworkChecks() async {
    let entitlement = EntitlementProbe(result: true)
    let network = NetworkProbe(result: true)
    let client = ApplePrivateCloudComputeClient(
        featureEnabled: false,
        entitlementChecker: entitlement,
        networkChecker: network
    )

    let capability = await client.capability()

    #expect(!capability.isFeatureEnabled)
    #expect(!capability.isUsable)
    #expect(capability.primaryUnavailabilityReason == .modelDisabled)
    #expect(entitlement.callCount == 0)
    #expect(await network.callCount == 0)
    let didPresentSuggestion = await client.presentQuotaIncreaseSuggestion()
    #expect(!didPresentSuggestion)
    #expect(entitlement.callCount == 0)

    do {
        _ = try await client.respond(
            instructions: "must not run",
            prompt: "must not leave the device",
            reasoningLevel: .deep
        )
        Issue.record("A disabled PCC adapter must reject generation")
    } catch let failure as IntelligenceRouteFailure {
        #expect(failure.kind == .serviceUnavailable)
    } catch {
        Issue.record("Expected a redacted IntelligenceRouteFailure")
    }
    #expect(entitlement.callCount == 0)
    #expect(await network.callCount == 0)
}
