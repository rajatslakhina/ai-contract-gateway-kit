import Foundation

// MARK: - Saturating arithmetic

extension Int {
    /// `self + other`, clamped to `Int.min ... Int.max` instead of trapping.
    @inlinable
    public func addingSaturating(_ other: Int) -> Int {
        let (value, overflow) = addingReportingOverflow(other)
        guard overflow else { return value }
        return other > 0 ? Int.max : Int.min
    }
}

// MARK: - Stable bucketing

/// Deterministic, process-independent bucketing for sticky percentage rollouts.
///
/// Swift's `Hasher` is randomly seeded per process, so it would move an installation in
/// and out of a rollout on every relaunch. FNV-1a 64 is stable across processes,
/// platforms and releases, which is the only property a rollout bucket needs.
public enum StableBucket {
    public static let bucketCount = 10_000

    /// FNV-1a 64-bit over the UTF-8 bytes.
    public static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3 // wrapping multiply is the algorithm
        }
        return hash
    }

    /// A bucket in `0 ..< bucketCount`. The salt lets you re-shuffle a population for a
    /// *new* experiment without disturbing this one.
    public static func bucket(installationID: String, salt: String) -> Int {
        // bucketCount is a positive constant, so the remainder is in 0..<10_000 and fits Int
        // on every platform, 32-bit watchOS included.
        Int(fnv1a64(salt + "\u{0}" + installationID) % UInt64(bucketCount))
    }
}

// MARK: - Policy

/// What the gateway does with a request whose translation would be lossy.
public enum IntentPolicy: String, Sendable, Codable, CaseIterable, CustomStringConvertible {
    /// Translate anyway and record what was lost.
    case preferCurrent
    /// While the legacy version is still served, keep lossy requests on it.
    /// The migration guide's own advice for a request that relies on a non-default
    /// `temperature`: "keep that request on 2023-06-01".
    case preserveIntent

    public var description: String {
        switch self {
        case .preferCurrent: return "prefer 2026-10-21"
        case .preserveIntent: return "preserve intent"
        }
    }
}

/// The server-side routing policy. Delivered remotely and revisioned, so an out-of-order
/// or replayed delivery can never roll the gateway back to an older policy.
public struct RoutingPolicy: Sendable, Equatable {
    /// Monotonic revision; an update with a revision ≤ the current one is ignored.
    public var revision: Int
    /// Share of installations routed to `.current`, in basis points (0 ... 10_000).
    public var currentVersionBasisPoints: Int
    /// Salt for the rollout bucket.
    public var rolloutSalt: String
    /// Per-build pin, checked before the percentage.
    public var buildOverrides: [Int: ProviderVersion]
    /// Builds below this are refused (`.unsupportedBuild`) so the app can force-upgrade.
    public var minimumSupportedBuild: Int
    /// Sends everything to `.legacy` while it is still served.
    public var killSwitch: Bool
    public var intentPolicy: IntentPolicy
    /// When the vendor stops serving `.legacy`; `nil` means no sunset is announced.
    public var legacySunset: Date?
    /// Retry once on `.legacy` when the vendor rejects a `.current` request we believed valid.
    public var retryOnLegacyAfterRejection: Bool

    public init(revision: Int,
                currentVersionBasisPoints: Int,
                rolloutSalt: String = "api-2026-10-21",
                buildOverrides: [Int: ProviderVersion] = [:],
                minimumSupportedBuild: Int = 1,
                killSwitch: Bool = false,
                intentPolicy: IntentPolicy = .preserveIntent,
                legacySunset: Date? = nil,
                retryOnLegacyAfterRejection: Bool = true) {
        self.revision = revision
        self.currentVersionBasisPoints = Swift.min(Swift.max(currentVersionBasisPoints, 0), StableBucket.bucketCount)
        self.rolloutSalt = rolloutSalt
        self.buildOverrides = buildOverrides
        self.minimumSupportedBuild = minimumSupportedBuild
        self.killSwitch = killSwitch
        self.intentPolicy = intentPolicy
        self.legacySunset = legacySunset
        self.retryOnLegacyAfterRejection = retryOnLegacyAfterRejection
    }

    public func isLegacyServed(at now: Date) -> Bool {
        guard let sunset = legacySunset else { return true }
        return now < sunset
    }
}

/// Why a request was routed where it was. Every route has exactly one reason.
public enum RouteReason: Sendable, Equatable, CustomStringConvertible {
    case killSwitch
    /// The kill switch is on, but the legacy version is gone: nothing to fall back to.
    case killSwitchIneffectiveAfterSunset
    case legacySunset
    case buildOverride
    case inRollout(bucket: Int)
    case outsideRollout(bucket: Int)

    public var description: String {
        switch self {
        case .killSwitch: return "kill switch"
        case .killSwitchIneffectiveAfterSunset: return "kill switch ignored: legacy is sunset"
        case .legacySunset: return "legacy sunset"
        case .buildOverride: return "build override"
        case .inRollout(let b): return "in rollout (bucket \(b))"
        case .outsideRollout(let b): return "outside rollout (bucket \(b))"
        }
    }
}

public struct RouteDecision: Sendable, Equatable {
    public var target: ProviderVersion
    public var reason: RouteReason
}

public enum Router {
    /// Pure routing: same policy, request identity and time → same decision.
    public static func route(build: Int, installationID: String, policy: RoutingPolicy, now: Date) -> RouteDecision {
        let legacyServed = policy.isLegacyServed(at: now)
        if policy.killSwitch {
            return legacyServed
                ? RouteDecision(target: .legacy, reason: .killSwitch)
                : RouteDecision(target: .current, reason: .killSwitchIneffectiveAfterSunset)
        }
        guard legacyServed else { return RouteDecision(target: .current, reason: .legacySunset) }
        if let pinned = policy.buildOverrides[build] {
            return RouteDecision(target: pinned, reason: .buildOverride)
        }
        let bucket = StableBucket.bucket(installationID: installationID, salt: policy.rolloutSalt)
        return bucket < policy.currentVersionBasisPoints
            ? RouteDecision(target: .current, reason: .inRollout(bucket: bucket))
            : RouteDecision(target: .legacy, reason: .outsideRollout(bucket: bucket))
    }
}
