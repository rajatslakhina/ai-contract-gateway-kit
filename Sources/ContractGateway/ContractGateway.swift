import Foundation

// MARK: - Transport

/// What came back from the provider. Only what the gateway's decisions need.
public struct ProviderResponse: Sendable, Equatable {
    public var status: Int
    public var errorType: String?
    public var message: String?

    public init(status: Int, errorType: String? = nil, message: String? = nil) {
        self.status = status
        self.errorType = errorType
        self.message = message
    }

    public static let ok = ProviderResponse(status: 200)

    /// A 400 `invalid_request_error`: the request shape, not the network, was wrong.
    public var isContractRejection: Bool { status == 400 && errorType == "invalid_request_error" }
}

/// The network edge. Retries of transient failures (429/5xx) belong here, not in the
/// gateway: the gateway only reacts to *contract* rejections, which retrying cannot fix.
public protocol ProviderTransport: Sendable {
    func send(_ request: ProviderRequest) async -> ProviderResponse
}

/// A stand-in vendor that enforces `ProviderContract`, plus optional extra rules that
/// model a breaking change nobody told you about.
public struct SimulatedProvider: ProviderTransport {
    public typealias ExtraRule = @Sendable (ProviderRequest) -> String?
    public var extraRules: [ExtraRule]

    public init(extraRules: [ExtraRule] = []) { self.extraRules = extraRules }

    public func send(_ request: ProviderRequest) async -> ProviderResponse {
        if let first = ProviderContract.violations(of: request).first {
            return ProviderResponse(status: 400, errorType: "invalid_request_error", message: first.description)
        }
        for rule in extraRules {
            if let message = rule(request) {
                return ProviderResponse(status: 400, errorType: "invalid_request_error", message: message)
            }
        }
        return .ok
    }
}

// MARK: - Outcome

public enum RejectionReason: Sendable, Equatable, CustomStringConvertible {
    case appContract(AppContractViolation)
    case unsupportedBuild(build: Int, minimum: Int)
    /// `.current` cannot express the request and `.legacy` is no longer served.
    case noCompatibleVersion(RuleID, String)
    /// The translated request would fail the provider contract; it was never sent.
    case preflightFailed([ContractViolation])

    public var description: String {
        switch self {
        case .appContract(let v): return "app contract: \(v)"
        case .unsupportedBuild(let b, let m): return "build \(b) is below the minimum \(m)"
        case .noCompatibleVersion(let rule, let why): return "no compatible version (\(rule)): \(why)"
        case .preflightFailed(let v): return "preflight: " + v.map(\.description).joined(separator: "; ")
        }
    }
}

/// One send attempt, in order.
public struct Attempt: Sendable, Equatable {
    public var version: ProviderVersion
    public var response: ProviderResponse
}

public struct GatewayOutcome: Sendable, Equatable {
    public var build: Int
    /// The router's decision, before any fallback.
    public var route: RouteDecision?
    /// Set when the gateway sent on `.legacy` although the router chose `.current`.
    public var fallback: LegacyFallback?
    /// The rewrites applied to the request that was finally sent (or would have been).
    public var adjustments: [Adjustment]
    /// When the gateway fell back to `.legacy`, the rewrites `.current` would have needed
    /// (and so the reason for the fallback). Empty otherwise. Never applied.
    public var consideredAdjustments: [Adjustment] = []
    /// When the fallback was `.untranslatable`: the refusing rule and its reason.
    public var untranslatableReason: String? = nil
    public var attempts: [Attempt]
    public var rejection: RejectionReason?
    /// The policy revision the whole request was decided under.
    public var policyRevision: Int

    public var deliveredVersion: ProviderVersion? {
        guard let last = attempts.last, last.response.status == 200 else { return nil }
        return last.version
    }
}

public enum PolicyUpdate: Sendable, Equatable {
    case applied(revision: Int)
    case stale(current: Int, offered: Int)
}

// MARK: - Gateway

/// Sits between every app build ever shipped and the provider API.
///
/// Concurrency contract: everything that decides a request — validation, routing,
/// translation, preflight, the fallback choice — runs in one actor turn against one
/// captured `RoutingPolicy` and one clock reading, before the first `await`. A policy
/// update that lands while the request is in flight (actor reentrancy) cannot change the
/// version it was translated for, the rules applied, or the retry decision.
public actor ContractGateway {
    private var policy: RoutingPolicy
    private var ledger: DependencyLedger
    private let translator: RequestTranslator
    private let catalog: ModelCatalog
    private let limits: GatewayLimits
    private let transport: any ProviderTransport
    private let now: @Sendable () -> Date

    public init(policy: RoutingPolicy,
                transport: any ProviderTransport,
                translator: RequestTranslator = .standard,
                catalog: ModelCatalog = .migrationGuideExamples,
                limits: GatewayLimits = .standard,
                ledgerCapacity: Int = 256,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.policy = policy
        self.transport = transport
        self.translator = translator
        self.catalog = catalog
        self.limits = limits
        self.ledger = DependencyLedger(capacity: ledgerCapacity)
        self.now = now
    }

    public var currentPolicy: RoutingPolicy { policy }
    public var dependencies: DependencyLedger { ledger }

    /// Applies a remotely delivered policy if, and only if, it is newer.
    @discardableResult
    public func apply(_ update: RoutingPolicy) -> PolicyUpdate {
        guard update.revision > policy.revision else {
            return .stale(current: policy.revision, offered: update.revision)
        }
        policy = update
        return .applied(revision: update.revision)
    }

    /// The planned send for a request: decided entirely from one policy snapshot.
    struct Plan: Sendable {
        var route: RouteDecision
        var request: ProviderRequest
        var adjustments: [Adjustment]
        var fallback: LegacyFallback?
        var consideredAdjustments: [Adjustment]
        var untranslatableReason: String?
        /// Pre-translated and preflighted `.legacy` request for the single vendor-rejection
        /// retry; `nil` when no retry is allowed under this policy snapshot.
        var retryRequest: ProviderRequest?
        var retryAdjustments: [Adjustment]
    }

    enum PlanResult: Sendable {
        case send(Plan)
        case reject(RejectionReason, RouteDecision?)
    }

    public func handle(_ app: AppRequest) async -> GatewayOutcome {
        let snapshot = policy
        let clock = now()
        var outcome = GatewayOutcome(build: app.build, route: nil, fallback: nil, adjustments: [],
                                     attempts: [], rejection: nil, policyRevision: snapshot.revision)

        switch plan(app, policy: snapshot, at: clock) {
        case .reject(let reason, let route):
            outcome.rejection = reason
            outcome.route = route
            record(app.build, outcome: outcome)
            return outcome
        case .send(let plan):
            outcome.route = plan.route
            outcome.fallback = plan.fallback
            outcome.adjustments = plan.adjustments
            outcome.consideredAdjustments = plan.consideredAdjustments
            outcome.untranslatableReason = plan.untranslatableReason

            // ---- first suspension point: nothing above depends on state read after it ----
            let first = await transport.send(plan.request)
            outcome.attempts.append(Attempt(version: plan.request.version, response: first))

            if first.isContractRejection, let legacy = plan.retryRequest {
                // Exactly one retry, on the version the request was valid for before the
                // migration, decided under the same snapshot as the first attempt.
                outcome.fallback = .vendorRejected
                outcome.consideredAdjustments = plan.adjustments
                outcome.adjustments = plan.retryAdjustments
                let second = await transport.send(legacy)
                outcome.attempts.append(Attempt(version: .legacy, response: second))
            }
            record(app.build, outcome: outcome)
            return outcome
        }
    }

    /// Synchronous planning. Pure apart from reading the catalog and limits.
    func plan(_ app: AppRequest, policy: RoutingPolicy, at clock: Date) -> PlanResult {
        if let violation = AppContract.validate(app, limits: limits) { return .reject(.appContract(violation), nil) }
        if app.build < policy.minimumSupportedBuild {
            return .reject(.unsupportedBuild(build: app.build, minimum: policy.minimumSupportedBuild), nil)
        }
        let legacyServed = policy.isLegacyServed(at: clock)
        let route = Router.route(build: app.build, installationID: app.installationID, policy: policy, now: clock)

        var fallback: LegacyFallback? = nil
        var considered: [Adjustment] = []
        var refusal: String? = nil
        var result = translator.translate(app, to: route.target, catalog: catalog)

        if route.target == .current, legacyServed {
            switch result {
            case .untranslatable(let rule, let why):
                fallback = .untranslatable
                refusal = "\(rule): \(why)"
            case .translated:
                if policy.intentPolicy == .preserveIntent, result.worstFidelity == .lossy {
                    fallback = .preservedIntent
                }
            }
            if fallback != nil {
                if case .translated(_, let made) = result { considered = made }
                result = translator.translate(app, to: .legacy, catalog: catalog)
            }
        }

        let request: ProviderRequest
        let adjustments: [Adjustment]
        switch result {
        case .untranslatable(let rule, let why):
            return .reject(.noCompatibleVersion(rule, why), route)
        case .translated(let shaped, let made):
            request = shaped
            adjustments = made
        }
        let violations = ProviderContract.violations(of: request)
        guard violations.isEmpty else { return .reject(.preflightFailed(violations), route) }

        // The retry target is prepared now, under this snapshot, and only kept if it would
        // itself pass preflight.
        var retryRequest: ProviderRequest? = nil
        var retryAdjustments: [Adjustment] = []
        if request.version == .current, legacyServed, policy.retryOnLegacyAfterRejection,
           case .translated(let legacy, let made) = translator.translate(app, to: .legacy, catalog: catalog),
           ProviderContract.violations(of: legacy).isEmpty {
            retryRequest = legacy
            retryAdjustments = made
        }
        return .send(Plan(route: route, request: request, adjustments: adjustments, fallback: fallback,
                          consideredAdjustments: considered, untranslatableReason: refusal, retryRequest: retryRequest, retryAdjustments: retryAdjustments))
    }

    private func record(_ build: Int, outcome: GatewayOutcome) {
        // Requests refused before routing (malformed, or from a retired build) never get a
        // per-build entry, so malformed or retired traffic can't churn the bounded ledger.
        // Residual risk: a well-formed request with an invented build number at or above the
        // cutoff still gets an entry. Closing that needs build attestation (e.g. App Attest)
        // or a server-side list of released builds.
        switch outcome.rejection {
        case .appContract?, .unsupportedBuild?:
            ledger.recordUnattributedRejection()
            return
        default:
            break
        }
        ledger.record(build: build) { entry in
            entry.requests = entry.requests.addingSaturating(1)
            if outcome.rejection != nil {
                entry.rejected = entry.rejected.addingSaturating(1)
            }
            switch outcome.deliveredVersion {
            case .current?: entry.deliveredCurrent = entry.deliveredCurrent.addingSaturating(1)
            case .legacy?: entry.deliveredLegacy = entry.deliveredLegacy.addingSaturating(1)
            case nil where !outcome.attempts.isEmpty: entry.failed = entry.failed.addingSaturating(1)
            case nil: break
            }
            for adjustment in outcome.adjustments + outcome.consideredAdjustments {
                entry.ruleHits.increment(adjustment.rule)
            }
            for adjustment in outcome.adjustments where adjustment.fidelity == .lossy {
                entry.lossyHits = entry.lossyHits.addingSaturating(1)
            }
            // A vendor rejection only proves a legacy dependency if legacy then worked;
            // if both versions refused, the request itself is bad, which is `failed`.
            if let fallback = outcome.fallback, fallback != .vendorRejected || outcome.deliveredVersion == .legacy {
                entry.fallbacks.increment(fallback)
            }
            if case .noCompatibleVersion = outcome.rejection { entry.fallbacks.increment(.untranslatable) }
        }
    }
}
