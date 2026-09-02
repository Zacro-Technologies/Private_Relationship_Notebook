#if RELATIONSHIP_LEGACY_INTELLIGENCE
import Foundation
import RelationshipCore

/// Compatibility contracts retained for deterministic router tests and archive
/// migrations. The production app target does not compile a native generative-
/// model client; its sole generative-AI path is the configured Shortcut.
public protocol TextIntelligenceClient: Sendable {
    func capability() async -> OnDeviceIntelligenceCapability
    func respond(instructions: String, prompt: String) async throws -> String
}

public enum IntelligenceReasoningLevel: String, Codable, Sendable {
    case light
    case moderate
    case deep
}

public protocol PrivateCloudTextIntelligenceClient: Sendable {
    func capability() async -> PrivateCloudComputeCapability
    func respond(
        instructions: String,
        prompt: String,
        reasoningLevel: IntelligenceReasoningLevel
    ) async throws -> String
    func presentQuotaIncreaseSuggestion() async -> Bool
}

/// Legacy native-routing modes retained only in the non-product package
/// regression target.
public enum AIMode: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case privateMode = "Private"
    case balanced = "Balanced"
    case bestQuality = "Best Quality"

    public var id: String { rawValue }
}

/// App-owned task categories used by the capability router. No concrete model
/// framework type crosses this boundary.
public enum IntelligenceTask: String, Codable, CaseIterable, Sendable {
    case structuredExtraction
    case summary
    case messageDraft
    case conversationStarter
    case duplicateSuggestion
    case sourceComparison
    case naturalLanguageFilter

    public var hasDeterministicFallback: Bool {
        switch self {
        case .structuredExtraction, .duplicateSuggestion, .naturalLanguageFilter:
            true
        case .summary, .messageDraft, .conversationStarter, .sourceComparison:
            false
        }
    }

    public var canBeChunkedWithoutChangingIntent: Bool {
        switch self {
        case .structuredExtraction, .sourceComparison:
            true
        case .summary, .messageDraft, .conversationStarter, .duplicateSuggestion, .naturalLanguageFilter:
            false
        }
    }
}

public struct IntelligenceRequest: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var task: IntelligenceTask
    public var mode: AIMode
    public var sourcePolicy: IntelligenceSourcePolicy
    public var estimatedTokens: Int
    public var requiresEvaluatedReasoning: Bool
    public var allowsDeterministicFallback: Bool

    public init(
        id: UUID = UUID(),
        task: IntelligenceTask,
        mode: AIMode = .balanced,
        sourcePolicy: IntelligenceSourcePolicy = .cloudEligible,
        estimatedTokens: Int,
        requiresEvaluatedReasoning: Bool = false,
        allowsDeterministicFallback: Bool = true
    ) {
        self.id = id
        self.task = task
        self.mode = mode
        self.sourcePolicy = sourcePolicy
        self.estimatedTokens = max(0, estimatedTokens)
        self.requiresEvaluatedReasoning = requiresEvaluatedReasoning
        self.allowsDeterministicFallback = allowsDeterministicFallback
    }
}

public enum IntelligenceUnavailabilityReason: String, Codable, CaseIterable, Sendable {
    case sdkUnavailable
    case modelDisabled
    case modelNotReady
    case entitlementMissing
    case regionIneligible
    case offline
    case quotaReached
    case serviceUnavailable
    case recentFailureBackoff
}

public struct OnDeviceIntelligenceCapability: Hashable, Codable, Sendable {
    public var isSDKAvailable: Bool
    public var isRuntimeAvailable: Bool
    public var evaluatedContextLimit: Int
    public var unavailableReason: IntelligenceUnavailabilityReason?

    public init(
        isSDKAvailable: Bool,
        isRuntimeAvailable: Bool,
        evaluatedContextLimit: Int,
        unavailableReason: IntelligenceUnavailabilityReason? = nil
    ) {
        self.isSDKAvailable = isSDKAvailable
        self.isRuntimeAvailable = isRuntimeAvailable
        self.evaluatedContextLimit = max(0, evaluatedContextLimit)
        self.unavailableReason = unavailableReason
    }

    public var isUsable: Bool { isSDKAvailable && isRuntimeAvailable }

    public static let unavailable = Self(
        isSDKAvailable: false,
        isRuntimeAvailable: false,
        evaluatedContextLimit: 0,
        unavailableReason: .sdkUnavailable
    )
}

public enum PrivateCloudComputeQuotaState: Hashable, Codable, Sendable {
    case unavailable
    case belowLimit(isApproaching: Bool, resetDate: Date?)
    case limitReached(resetDate: Date?)

    public var isAvailable: Bool {
        if case .belowLimit = self { return true }
        return false
    }

    public var isApproachingLimit: Bool {
        guard case .belowLimit(let isApproaching, _) = self else { return false }
        return isApproaching
    }

    public var resetDate: Date? {
        switch self {
        case .unavailable:
            nil
        case .belowLimit(_, let resetDate), .limitReached(let resetDate):
            resetDate
        }
    }
}

public struct PrivateCloudComputeCapability: Hashable, Codable, Sendable {
    public var isFeatureEnabled: Bool
    public var isSDKAvailable: Bool
    public var isEntitled: Bool
    public var isRegionEligible: Bool
    public var isRuntimeAvailable: Bool
    public var isNetworkPathAvailable: Bool
    public var isQuotaAvailable: Bool
    public var isFailureBackoffActive: Bool
    public var evaluatedContextLimit: Int
    public var quotaState: PrivateCloudComputeQuotaState
    public var canPresentQuotaIncreaseSuggestion: Bool

    public init(
        isFeatureEnabled: Bool = true,
        isSDKAvailable: Bool,
        isEntitled: Bool,
        isRegionEligible: Bool,
        isRuntimeAvailable: Bool,
        isNetworkPathAvailable: Bool,
        isQuotaAvailable: Bool,
        isFailureBackoffActive: Bool = false,
        evaluatedContextLimit: Int,
        quotaState: PrivateCloudComputeQuotaState? = nil,
        canPresentQuotaIncreaseSuggestion: Bool = false
    ) {
        self.isFeatureEnabled = isFeatureEnabled
        self.isSDKAvailable = isSDKAvailable
        self.isEntitled = isEntitled
        self.isRegionEligible = isRegionEligible
        self.isRuntimeAvailable = isRuntimeAvailable
        self.isNetworkPathAvailable = isNetworkPathAvailable
        let resolvedQuotaState = quotaState ?? (isQuotaAvailable
            ? .belowLimit(isApproaching: false, resetDate: nil)
            : .unavailable)
        // Treat the framework's structured quota state as an independent,
        // conservative gate. This prevents a stale Boolean (or decoded test
        // fixture) from routing content to PCC after the quota reaches zero.
        self.isQuotaAvailable = isQuotaAvailable && resolvedQuotaState.isAvailable
        self.isFailureBackoffActive = isFailureBackoffActive
        self.evaluatedContextLimit = max(0, evaluatedContextLimit)
        self.quotaState = resolvedQuotaState
        self.canPresentQuotaIncreaseSuggestion = canPresentQuotaIncreaseSuggestion
    }

    /// A positive network path is only one gate. It is intentionally
    /// insufficient on its own to make PCC usable.
    public var isUsable: Bool {
        isFeatureEnabled
            && isSDKAvailable
            && isEntitled
            && isRegionEligible
            && isRuntimeAvailable
            && isNetworkPathAvailable
            && isQuotaAvailable
            && quotaState.isAvailable
            && !isFailureBackoffActive
    }

    public var primaryUnavailabilityReason: IntelligenceUnavailabilityReason? {
        if !isFeatureEnabled { return .modelDisabled }
        if !isSDKAvailable { return .sdkUnavailable }
        if !isEntitled { return .entitlementMissing }
        if !isRegionEligible { return .regionIneligible }
        if !isRuntimeAvailable { return .serviceUnavailable }
        if !isNetworkPathAvailable { return .offline }
        if !isQuotaAvailable || !quotaState.isAvailable { return .quotaReached }
        if isFailureBackoffActive { return .recentFailureBackoff }
        return nil
    }

    public static let unavailable = Self(
        isFeatureEnabled: false,
        isSDKAvailable: false,
        isEntitled: false,
        isRegionEligible: false,
        isRuntimeAvailable: false,
        isNetworkPathAvailable: false,
        isQuotaAvailable: false,
        evaluatedContextLimit: 0
    )
}

public struct IntelligenceCapabilities: Hashable, Codable, Sendable {
    public var onDevice: OnDeviceIntelligenceCapability
    public var privateCloudCompute: PrivateCloudComputeCapability

    public init(
        onDevice: OnDeviceIntelligenceCapability,
        privateCloudCompute: PrivateCloudComputeCapability
    ) {
        self.onDevice = onDevice
        self.privateCloudCompute = privateCloudCompute
    }
}

public enum IntelligenceProcessingRoute: String, Codable, CaseIterable, Sendable {
    case onDevice
    case privateCloudCompute
    case deterministic
    case manual

    public var completedDisclosure: String {
        switch self {
        case .onDevice: String(localized: "Processed on this device")
        case .privateCloudCompute: String(localized: "Processed with Apple Private Cloud Compute")
        case .deterministic: String(localized: "Processed on this device without AI")
        case .manual: String(localized: "Manual review")
        }
    }

    public var intendedDisclosure: String {
        switch self {
        case .onDevice: String(localized: "Will process on this device")
        case .privateCloudCompute: String(localized: "Will use Apple Private Cloud Compute")
        case .deterministic: String(localized: "Will use the on-device deterministic fallback")
        case .manual: String(localized: "Manual editing will remain available")
        }
    }
}

public enum IntelligenceRoutingReason: String, Codable, Sendable {
    case privateMode
    case itemRestrictedToDevice
    case modelsDeniedForItem
    case ordinaryTaskPreferredLocally
    case largerContextBenefitsFromCloud
    case evaluatedReasoningBenefitsFromCloud
    case bestQualityPrefersCloud
    case cloudUnavailable
    case cloudContextLimitExceeded
    case localUnavailable
    case localChunkingRequired
    case deterministicFallback
    case manualFallback
    case nonFallbackFailureRequiresManualReview
}

public struct IntelligenceRouteStep: Hashable, Codable, Sendable {
    public var route: IntelligenceProcessingRoute
    public var reason: IntelligenceRoutingReason
    public var requiresChunking: Bool

    public init(
        route: IntelligenceProcessingRoute,
        reason: IntelligenceRoutingReason,
        requiresChunking: Bool = false
    ) {
        self.route = route
        self.reason = reason
        self.requiresChunking = requiresChunking
    }
}

public struct IntelligenceRoutingPlan: Hashable, Codable, Sendable {
    public var requestID: UUID
    public var steps: [IntelligenceRouteStep]
    public var notices: [IntelligenceRoutingReason]

    public init(
        requestID: UUID,
        steps: [IntelligenceRouteStep],
        notices: [IntelligenceRoutingReason] = []
    ) {
        self.requestID = requestID
        self.steps = steps
        self.notices = notices
    }

    public var intendedRoute: IntelligenceProcessingRoute {
        steps.first?.route ?? .manual
    }
}

public enum IntelligenceFailureKind: String, Codable, Sendable {
    case offline
    case networkInterrupted
    case serviceUnavailable
    case entitlementChanged
    case quotaReached
    case transientRateLimited
    case transientServiceError
    case contextLimitExceeded
    case safetyRefusal
    case unsupportedSource
    case cancelled
    case permanentFailure

    public var allowsAutomaticFallback: Bool {
        switch self {
        case .offline, .networkInterrupted, .serviceUnavailable, .entitlementChanged,
             .quotaReached, .transientRateLimited, .transientServiceError,
             .contextLimitExceeded:
            true
        case .safetyRefusal, .unsupportedSource, .cancelled, .permanentFailure:
            false
        }
    }
}

public struct IntelligenceRouteFailure: Error, Hashable, Codable, Sendable {
    public var kind: IntelligenceFailureKind

    /// Deliberately contains no source text, prompt, person name, or partial
    /// model output.
    public init(_ kind: IntelligenceFailureKind) {
        self.kind = kind
    }
}

public struct RoutedIntelligenceSuggestion<Output: Sendable>: Sendable {
    public var output: Output
    public var route: IntelligenceProcessingRoute
    public var disclosure: String
    public var isSuggested: Bool

    public init(output: Output, route: IntelligenceProcessingRoute) {
        self.output = output
        self.route = route
        self.disclosure = route.completedDisclosure
        self.isSuggested = true
    }
}

public struct ManualIntelligenceFallback: Hashable, Codable, Sendable {
    public var reason: IntelligenceRoutingReason
    public var attemptedRoutes: [IntelligenceProcessingRoute]

    public init(
        reason: IntelligenceRoutingReason,
        attemptedRoutes: [IntelligenceProcessingRoute]
    ) {
        self.reason = reason
        self.attemptedRoutes = attemptedRoutes
    }
}

public enum IntelligenceExecutionOutcome<Output: Sendable>: Sendable {
    case suggestion(RoutedIntelligenceSuggestion<Output>)
    case manual(ManualIntelligenceFallback)
    case cancelled
}

/// Pure capability planner plus a small executor that enforces safe fallback
/// semantics. Every attempt invokes the supplied operation independently, so a
/// partial cloud response is never continued or combined with a local result.
public struct IntelligenceRouter: Sendable {
    public init() {}

    public func plan(
        request: IntelligenceRequest,
        capabilities: IntelligenceCapabilities
    ) -> IntelligenceRoutingPlan {
        var steps: [IntelligenceRouteStep] = []
        var notices: [IntelligenceRoutingReason] = []

        let modelsAllowed = request.sourcePolicy == .cloudEligible
            || request.sourcePolicy == .onDeviceOnly
        let cloudAllowed = request.sourcePolicy == .cloudEligible && request.mode != .privateMode
        let localFits = request.estimatedTokens <= capabilities.onDevice.evaluatedContextLimit
        let localCanChunk = request.task.canBeChunkedWithoutChangingIntent
        let cloudFits = request.estimatedTokens <= capabilities.privateCloudCompute.evaluatedContextLimit

        if request.sourcePolicy == .modelsDenied
            || request.sourcePolicy == .configuredShortcutEligible {
            notices.append(.modelsDeniedForItem)
        } else if request.sourcePolicy == .onDeviceOnly {
            notices.append(.itemRestrictedToDevice)
        }

        let cloudPreferred: (Bool, IntelligenceRoutingReason) = {
            switch request.mode {
            case .privateMode:
                return (false, .privateMode)
            case .balanced:
                if request.requiresEvaluatedReasoning {
                    return (true, .evaluatedReasoningBenefitsFromCloud)
                }
                if !localFits {
                    return (true, .largerContextBenefitsFromCloud)
                }
                return (false, .ordinaryTaskPreferredLocally)
            case .bestQuality:
                return (true, .bestQualityPrefersCloud)
            }
        }()

        if modelsAllowed, cloudAllowed, cloudPreferred.0 {
            if !capabilities.privateCloudCompute.isUsable {
                notices.append(.cloudUnavailable)
            } else if cloudFits {
                steps.append(.init(route: .privateCloudCompute, reason: cloudPreferred.1))
            } else {
                notices.append(.cloudContextLimitExceeded)
            }
        }

        if modelsAllowed, capabilities.onDevice.isUsable {
            if localFits {
                let reason: IntelligenceRoutingReason = request.mode == .privateMode
                    ? .privateMode
                    : (request.sourcePolicy == .onDeviceOnly
                        ? .itemRestrictedToDevice
                        : .ordinaryTaskPreferredLocally)
                steps.append(.init(route: .onDevice, reason: reason))
            } else if localCanChunk {
                steps.append(.init(
                    route: .onDevice,
                    reason: .localChunkingRequired,
                    requiresChunking: true
                ))
                notices.append(.localChunkingRequired)
            }
        } else if modelsAllowed {
            notices.append(.localUnavailable)
        }

        if request.allowsDeterministicFallback, request.task.hasDeterministicFallback {
            steps.append(.init(route: .deterministic, reason: .deterministicFallback))
        }

        steps.append(.init(route: .manual, reason: .manualFallback))

        // Defensive deduplication keeps a malformed capability combination from
        // causing the same engine to be retried with a partial response.
        var seen = Set<IntelligenceProcessingRoute>()
        steps = steps.filter { seen.insert($0.route).inserted }
        return IntelligenceRoutingPlan(requestID: request.id, steps: steps, notices: notices)
    }

    public func remainingSteps(
        after failure: IntelligenceFailureKind,
        attemptedRoute: IntelligenceProcessingRoute,
        in plan: IntelligenceRoutingPlan
    ) -> [IntelligenceRouteStep] {
        if failure == .cancelled { return [] }

        guard failure.allowsAutomaticFallback else {
            return [IntelligenceRouteStep(
                route: .manual,
                reason: .nonFallbackFailureRequiresManualReview
            )]
        }

        guard let attemptedIndex = plan.steps.firstIndex(where: { $0.route == attemptedRoute }) else {
            return [IntelligenceRouteStep(route: .manual, reason: .manualFallback)]
        }
        return Array(plan.steps.dropFirst(attemptedIndex + 1))
    }

    public func execute<Output: Sendable>(
        plan: IntelligenceRoutingPlan,
        operation: @escaping @Sendable (IntelligenceProcessingRoute) async throws -> Output
    ) async -> IntelligenceExecutionOutcome<Output> {
        var attempted: [IntelligenceProcessingRoute] = []
        var remaining = plan.steps

        while let step = remaining.first {
            remaining.removeFirst()
            if step.route == .manual {
                return .manual(.init(reason: step.reason, attemptedRoutes: attempted))
            }

            attempted.append(step.route)
            do {
                let output = try await operation(step.route)
                return .suggestion(.init(output: output, route: step.route))
            } catch is CancellationError {
                return .cancelled
            } catch let failure as IntelligenceRouteFailure {
                let fallback = remainingSteps(
                    after: failure.kind,
                    attemptedRoute: step.route,
                    in: plan
                )
                if !failure.kind.allowsAutomaticFallback {
                    if failure.kind == .cancelled { return .cancelled }
                    return .manual(.init(
                        reason: .nonFallbackFailureRequiresManualReview,
                        attemptedRoutes: attempted
                    ))
                }
                remaining = fallback
            } catch {
                // Unknown failures are not assumed transient and therefore do
                // not silently move private input to another processing route.
                return .manual(.init(
                    reason: .nonFallbackFailureRequiresManualReview,
                    attemptedRoutes: attempted
                ))
            }
        }

        return .manual(.init(reason: .manualFallback, attemptedRoutes: attempted))
    }
}
#endif
