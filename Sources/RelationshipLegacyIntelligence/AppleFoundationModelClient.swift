#if RELATIONSHIP_LEGACY_INTELLIGENCE
import Foundation
import RelationshipCore

// Historical native-router adapter retained only in a non-product SwiftPM
// target so old routing invariants remain regression-tested. Production
// generative AI is the configured, authenticated Shortcut workflow.

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(Network)
import Network
#endif

public protocol PrivateCloudComputeEntitlementChecking: Sendable {
    func hasPrivateCloudComputeEntitlement() -> Bool
}

public struct SystemPrivateCloudComputeEntitlementChecker:
    PrivateCloudComputeEntitlementChecking {
    private let isProvisionedForThisBuild: Bool

    public init() {
        let configured = Bundle.main.object(
            forInfoDictionaryKey: "PCCEntitlementProvisioned"
        )
        if let boolean = configured as? Bool {
            isProvisionedForThisBuild = boolean
        } else if let string = configured as? String {
            isProvisionedForThisBuild = ["1", "true", "yes"]
                .contains(string.lowercased())
        } else {
            isProvisionedForThisBuild = false
        }
    }

    public init(isProvisionedForThisBuild: Bool) {
        self.isProvisionedForThisBuild = isProvisionedForThisBuild
    }

    public func hasPrivateCloudComputeEntitlement() -> Bool {
        // SecTask entitlement introspection is not a public iOS SDK API. This
        // conservative build declaration must be enabled only after the
        // managed entitlement is present in the signing profile. Apple's
        // public model availability remains the definitive runtime gate.
        isProvisionedForThisBuild
    }
}

public protocol IntelligenceNetworkPathChecking: Sendable {
    func isNetworkPathAvailable() async -> Bool
}

#if canImport(Network)
public final class SystemIntelligenceNetworkPathChecker:
    @unchecked Sendable,
    IntelligenceNetworkPathChecking {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(
        label: "com.zacrotech.RelationshipNotebook.intelligence-network"
    )
    private let lock = NSLock()
    private var latestStatus: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.record(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        let pending = lock.withLock {
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume(returning: false) }
    }

    public func isNetworkPathAvailable() async -> Bool {
        if let latestStatus = lock.withLock({ latestStatus }) {
            return latestStatus
        }
        return await withCheckedContinuation { continuation in
            let resolvedStatus = lock.withLock { () -> Bool? in
                if let status = latestStatus {
                    return status
                }
                waiters.append(continuation)
                return nil
            }
            if let resolvedStatus {
                continuation.resume(returning: resolvedStatus)
            }
        }
    }

    private func record(_ status: Bool) {
        let pending = lock.withLock {
            latestStatus = status
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume(returning: status) }
    }
}
#else
public struct SystemIntelligenceNetworkPathChecker: IntelligenceNetworkPathChecking {
    public init() {}
    public func isNetworkPathAvailable() async -> Bool { false }
}
#endif

public actor AppleFoundationModelClient: TextIntelligenceClient {
    public init() {}

    public func capability() async -> OnDeviceIntelligenceCapability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return .init(
                    isSDKAvailable: true,
                    isRuntimeAvailable: true,
                    evaluatedContextLimit: 4_096
                )
            case .unavailable(let reason):
                let mapped: IntelligenceUnavailabilityReason = switch reason {
                case .appleIntelligenceNotEnabled: .modelDisabled
                case .modelNotReady: .modelNotReady
                case .deviceNotEligible: .sdkUnavailable
                @unknown default: .serviceUnavailable
                }
                return .init(
                    isSDKAvailable: true,
                    isRuntimeAvailable: false,
                    evaluatedContextLimit: 4_096,
                    unavailableReason: mapped
                )
            }
        }
        #endif
        return .unavailable
    }

    public func respond(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {
                throw IntelligenceRouteFailure(.serviceUnavailable)
            }
            do {
                // Each attempt starts a fresh session. A failed PCC response is
                // never continued or combined with this local fallback.
                let session = LanguageModelSession(
                    model: .default,
                    tools: [],
                    instructions: instructions
                )
                return try await session.respond(to: prompt).content
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LanguageModelSession.GenerationError {
                throw Self.mapLegacyGenerationError(error)
            } catch {
                #if PRIVATE_CLOUD_COMPUTE_SDK && canImport(FoundationModels)
                if #available(iOS 27.0, macOS 27.0, *),
                   let failure = Self.mapSDK27Error(error) {
                    throw failure
                }
                #endif
                throw IntelligenceRouteFailure(.permanentFailure)
            }
        }
        #endif
        throw IntelligenceRouteFailure(.serviceUnavailable)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func mapLegacyGenerationError(
        _ error: LanguageModelSession.GenerationError
    ) -> IntelligenceRouteFailure {
        switch error {
        case .exceededContextWindowSize:
            .init(.contextLimitExceeded)
        case .assetsUnavailable:
            .init(.serviceUnavailable)
        case .guardrailViolation, .refusal:
            .init(.safetyRefusal)
        case .unsupportedLanguageOrLocale, .unsupportedGuide:
            .init(.unsupportedSource)
        case .rateLimited, .concurrentRequests:
            .init(.transientRateLimited)
        case .decodingFailure:
            .init(.permanentFailure)
        @unknown default:
            .init(.permanentFailure)
        }
    }
    #endif

    #if PRIVATE_CLOUD_COMPUTE_SDK && canImport(FoundationModels)
    @available(iOS 27.0, macOS 27.0, *)
    private static func mapSDK27Error(
        _ error: Error
    ) -> IntelligenceRouteFailure? {
        if let error = error as? SystemLanguageModel.Error {
            return switch error {
            case .assetsUnavailable(_):
                .init(.serviceUnavailable)
            @unknown default:
                .init(.permanentFailure)
            }
        }
        return mapSDK27SharedFoundationModelsError(error)
    }
    #endif
}

/// The SDK-27 adapter is compiled only when an SDK that exposes Apple's public
/// PCC types is selected and the target defines `PRIVATE_CLOUD_COMPUTE_SDK`.
/// Xcode 26 builds therefore never reference unavailable framework symbols.
public actor ApplePrivateCloudComputeClient: PrivateCloudTextIntelligenceClient {
    private let featureEnabled: Bool
    private let entitlementChecker: any PrivateCloudComputeEntitlementChecking
    private let networkChecker: any IntelligenceNetworkPathChecking
    private let now: @Sendable () -> Date
    private var consecutiveTransientFailures = 0
    private var backoffUntil: Date?

    public init(
        featureEnabled: Bool,
        entitlementChecker: any PrivateCloudComputeEntitlementChecking =
            SystemPrivateCloudComputeEntitlementChecker(),
        networkChecker: any IntelligenceNetworkPathChecking =
            SystemIntelligenceNetworkPathChecker(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.featureEnabled = featureEnabled
        self.entitlementChecker = entitlementChecker
        self.networkChecker = networkChecker
        self.now = now
    }

    public func capability() async -> PrivateCloudComputeCapability {
        guard featureEnabled else {
            return unavailableCapability(reason: .modelDisabled)
        }

        #if PRIVATE_CLOUD_COMPUTE_SDK && canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, *) {
            return await sdk27Capability()
        }
        #endif

        return unavailableCapability(reason: .sdkUnavailable)
    }

    public func respond(
        instructions: String,
        prompt: String,
        reasoningLevel: IntelligenceReasoningLevel
    ) async throws -> String {
        let currentCapability = await capability()
        guard currentCapability.isUsable else {
            throw IntelligenceRouteFailure(Self.failureKind(
                for: currentCapability.primaryUnavailabilityReason
            ))
        }

        #if PRIVATE_CLOUD_COMPUTE_SDK && canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, *) {
            do {
                let session = LanguageModelSession(
                    model: PrivateCloudComputeLanguageModel(),
                    tools: [],
                    instructions: instructions
                )
                let response = try await session.respond(
                    to: prompt,
                    contextOptions: ContextOptions(
                        reasoningLevel: reasoningLevel.foundationModelsValue
                    )
                )
                consecutiveTransientFailures = 0
                backoffUntil = nil
                return response.content
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = Self.mapSDK27Error(error)
                registerBackoffIfNeeded(for: failure.kind)
                throw failure
            }
        }
        #endif

        throw IntelligenceRouteFailure(.serviceUnavailable)
    }

    public func presentQuotaIncreaseSuggestion() async -> Bool {
        guard featureEnabled,
              entitlementChecker.hasPrivateCloudComputeEntitlement() else {
            return false
        }

        #if PRIVATE_CLOUD_COMPUTE_SDK && canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, *) {
            guard let suggestion = PrivateCloudComputeLanguageModel()
                .quotaUsage.limitIncreaseSuggestion else { return false }
            await MainActor.run { suggestion.show() }
            return true
        }
        #endif

        return false
    }

    private func unavailableCapability(
        reason: IntelligenceUnavailabilityReason
    ) -> PrivateCloudComputeCapability {
        PrivateCloudComputeCapability(
            isFeatureEnabled: featureEnabled,
            isSDKAvailable: reason != .sdkUnavailable,
            isEntitled: false,
            isRegionEligible: false,
            isRuntimeAvailable: false,
            isNetworkPathAvailable: false,
            isQuotaAvailable: false,
            isFailureBackoffActive: false,
            evaluatedContextLimit: 0,
            quotaState: .unavailable
        )
    }

    private static func failureKind(
        for reason: IntelligenceUnavailabilityReason?
    ) -> IntelligenceFailureKind {
        switch reason {
        case .offline:
            .offline
        case .quotaReached:
            .quotaReached
        case .entitlementMissing:
            .entitlementChanged
        case .recentFailureBackoff:
            .transientServiceError
        case .regionIneligible, .modelDisabled, .modelNotReady,
             .sdkUnavailable, .serviceUnavailable, nil:
            .serviceUnavailable
        }
    }

    private func registerBackoffIfNeeded(for failure: IntelligenceFailureKind) {
        guard [.networkInterrupted, .serviceUnavailable, .transientRateLimited,
               .transientServiceError].contains(failure) else { return }
        consecutiveTransientFailures = min(consecutiveTransientFailures + 1, 6)
        let delays: [TimeInterval] = [5, 15, 30, 60, 120, 300]
        backoffUntil = now().addingTimeInterval(
            delays[consecutiveTransientFailures - 1]
        )
    }

    #if PRIVATE_CLOUD_COMPUTE_SDK && canImport(FoundationModels)
    @available(iOS 27.0, macOS 27.0, *)
    private func sdk27Capability() async -> PrivateCloudComputeCapability {
        let entitled = entitlementChecker.hasPrivateCloudComputeEntitlement()
        guard entitled else {
            return PrivateCloudComputeCapability(
                isFeatureEnabled: true,
                isSDKAvailable: true,
                isEntitled: false,
                isRegionEligible: false,
                isRuntimeAvailable: false,
                isNetworkPathAvailable: false,
                isQuotaAvailable: false,
                evaluatedContextLimit: 0,
                quotaState: .unavailable
            )
        }

        let networkAvailable = await networkChecker.isNetworkPathAvailable()
        let model = PrivateCloudComputeLanguageModel()
        let quota = Self.quotaState(for: model)
        let runtimeAvailable: Bool
        let regionEligible: Bool
        switch model.availability {
        case .available:
            runtimeAvailable = true
            regionEligible = true
        case .unavailable(.deviceNotEligible):
            runtimeAvailable = false
            regionEligible = false
        case .unavailable(.systemNotReady):
            runtimeAvailable = false
            regionEligible = true
        case .unavailable:
            runtimeAvailable = false
            regionEligible = false
        @unknown default:
            runtimeAvailable = false
            regionEligible = false
        }

        if let backoffUntil, backoffUntil <= now() {
            self.backoffUntil = nil
            consecutiveTransientFailures = 0
        }
        let backoffActive = self.backoffUntil.map { $0 > now() } ?? false
        return PrivateCloudComputeCapability(
            isFeatureEnabled: true,
            isSDKAvailable: true,
            isEntitled: true,
            isRegionEligible: regionEligible,
            isRuntimeAvailable: runtimeAvailable,
            isNetworkPathAvailable: networkAvailable,
            isQuotaAvailable: quota.isAvailable,
            isFailureBackoffActive: backoffActive,
            evaluatedContextLimit: model.contextSize,
            quotaState: quota,
            canPresentQuotaIncreaseSuggestion:
                model.quotaUsage.limitIncreaseSuggestion != nil
        )
    }

    @available(iOS 27.0, macOS 27.0, *)
    private static func quotaState(
        for model: PrivateCloudComputeLanguageModel
    ) -> PrivateCloudComputeQuotaState {
        let usage = model.quotaUsage
        if usage.isLimitReached {
            return .limitReached(resetDate: usage.resetDate)
        }
        if case .belowLimit(let info) = usage.status {
            return .belowLimit(
                isApproaching: info.isApproachingLimit,
                resetDate: usage.resetDate
            )
        }
        return .unavailable
    }

    @available(iOS 27.0, macOS 27.0, *)
    private static func mapSDK27Error(_ error: Error) -> IntelligenceRouteFailure {
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            return switch error {
            case .quotaLimitReached(_):
                .init(.quotaReached)
            case .networkFailure(_):
                .init(.networkInterrupted)
            case .serviceUnavailable(_):
                .init(.serviceUnavailable)
            @unknown default:
                .init(.transientServiceError)
            }
        }
        if let failure = mapSDK27SharedFoundationModelsError(error) {
            return failure
        }
        if let error = error as? URLError {
            return switch error.code {
            case .notConnectedToInternet:
                .init(.offline)
            case .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .dnsLookupFailed:
                .init(.networkInterrupted)
            default:
                .init(.transientServiceError)
            }
        }
        return .init(.permanentFailure)
    }
    #endif
}

#if PRIVATE_CLOUD_COMPUTE_SDK && canImport(FoundationModels)
@available(iOS 27.0, macOS 27.0, *)
private func mapSDK27SharedFoundationModelsError(
    _ error: Error
) -> IntelligenceRouteFailure? {
    if let error = error as? LanguageModelError {
        return switch error {
        case .contextSizeExceeded(_):
            .init(.contextLimitExceeded)
        case .rateLimited(_), .timeout(_):
            .init(.transientRateLimited)
        case .refusal(_), .guardrailViolation(_):
            .init(.safetyRefusal)
        case .unsupportedCapability(_), .unsupportedTranscriptContent(_),
             .unsupportedGenerationGuide(_), .unsupportedLanguageOrLocale(_):
            .init(.unsupportedSource)
        @unknown default:
            .init(.permanentFailure)
        }
    }
    if let error = error as? LanguageModelSession.Error {
        return switch error {
        case .concurrentRequests:
            .init(.transientRateLimited)
        case .transcriptMutationWhileResponding:
            .init(.permanentFailure)
        @unknown default:
            .init(.permanentFailure)
        }
    }
    return nil
}

@available(iOS 27.0, macOS 27.0, *)
private extension IntelligenceReasoningLevel {
    var foundationModelsValue: ContextOptions.ReasoningLevel {
        switch self {
        case .light: .light
        case .moderate: .moderate
        case .deep: .deep
        }
    }
}
#endif

public struct IntelligenceCapabilityDetector: Sendable {
    private let localClient: any TextIntelligenceClient
    private let privateCloudClient: any PrivateCloudTextIntelligenceClient

    public init(
        localClient: any TextIntelligenceClient = AppleFoundationModelClient(),
        privateCloudClient: (any PrivateCloudTextIntelligenceClient)? = nil,
        pccFeatureEnabled: Bool = false
    ) {
        self.localClient = localClient
        self.privateCloudClient = privateCloudClient ?? ApplePrivateCloudComputeClient(
            featureEnabled: pccFeatureEnabled
        )
    }

    public func capabilities() async -> IntelligenceCapabilities {
        async let local = localClient.capability()
        async let privateCloud = privateCloudClient.capability()
        return await IntelligenceCapabilities(
            onDevice: local,
            privateCloudCompute: privateCloud
        )
    }
}

/// Executes one reviewed request through the capability router. Each model
/// attempt creates an independent session, PCC failures fall back only when the
/// error class permits it, and no partial response crosses routes.
public actor RoutedTextIntelligenceService {
    private let router: IntelligenceRouter
    private let localClient: any TextIntelligenceClient
    private let privateCloudClient: any PrivateCloudTextIntelligenceClient

    public init(
        router: IntelligenceRouter = .init(),
        localClient: any TextIntelligenceClient = AppleFoundationModelClient(),
        privateCloudClient: (any PrivateCloudTextIntelligenceClient)? = nil,
        pccFeatureEnabled: Bool = false
    ) {
        self.router = router
        self.localClient = localClient
        self.privateCloudClient = privateCloudClient ?? ApplePrivateCloudComputeClient(
            featureEnabled: pccFeatureEnabled
        )
    }

    public func capabilities() async -> IntelligenceCapabilities {
        await IntelligenceCapabilityDetector(
            localClient: localClient,
            privateCloudClient: privateCloudClient
        ).capabilities()
    }

    public func plan(for request: IntelligenceRequest) async -> IntelligenceRoutingPlan {
        router.plan(request: request, capabilities: await capabilities())
    }

    public func respond(
        to request: IntelligenceRequest,
        instructions: String,
        prompt: String,
        deterministicFallback: String? = nil
    ) async -> IntelligenceExecutionOutcome<String> {
        let plan = await plan(for: request)
        let localClient = self.localClient
        let privateCloudClient = self.privateCloudClient
        return await router.execute(plan: plan) { route in
            switch route {
            case .onDevice:
                try await localClient.respond(
                    instructions: instructions,
                    prompt: prompt
                )
            case .privateCloudCompute:
                try await privateCloudClient.respond(
                    instructions: instructions,
                    prompt: prompt,
                    reasoningLevel: request.requiresEvaluatedReasoning
                        ? .moderate
                        : .light
                )
            case .deterministic:
                if let deterministicFallback { deterministicFallback }
                else { throw IntelligenceRouteFailure(.permanentFailure) }
            case .manual:
                throw IntelligenceRouteFailure(.permanentFailure)
            }
        }
    }

    public func presentQuotaIncreaseSuggestion() async -> Bool {
        await privateCloudClient.presentQuotaIncreaseSuggestion()
    }
}
#endif
