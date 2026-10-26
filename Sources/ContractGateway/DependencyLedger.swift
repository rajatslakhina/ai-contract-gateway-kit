import Foundation

/// Why a request that was routed to `.current` was sent on `.legacy` instead.
public enum LegacyFallback: String, Sendable, Codable, CaseIterable, Comparable, CustomStringConvertible {
    /// A rule could not express the request on `2026-10-21`.
    case untranslatable
    /// The translation was lossy and the policy is `.preserveIntent`.
    case preservedIntent
    /// The vendor rejected a `.current` request the preflight believed valid.
    case vendorRejected

    public var description: String { rawValue }
    public static func < (lhs: LegacyFallback, rhs: LegacyFallback) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Per-build counters: the answer to "which builds still depend on the old behaviour?".
public struct BuildDependency: Sendable, Equatable {
    public var build: Int
    public var requests: Int = 0
    /// Final attempt answered 200 on that version.
    public var deliveredCurrent: Int = 0
    public var deliveredLegacy: Int = 0
    /// Sent, but no attempt got a 200 (vendor errors, or a 400 on both versions).
    public var failed: Int = 0
    /// Refused by the gateway itself and never sent.
    public var rejected: Int = 0
    /// Rules that fired on this build's requests, applied or merely considered before a
    /// fallback (the fallback's reason).
    public var ruleHits: [RuleID: Int] = [:]
    /// Lossy rewrites actually applied to requests that were sent.
    public var lossyHits: Int = 0
    public var fallbacks: [LegacyFallback: Int] = [:]

    public init(build: Int) { self.build = build }

    /// Observed in live traffic: some request from this build needed `.legacy` to keep
    /// working, or lost meaning on `.current`. Only builds that actually sent traffic the
    /// gateway tried on `.current` can show up here; `MatrixGate` answers the same
    /// question for every recorded fixture, independent of traffic.
    public var dependsOnLegacy: Bool { !fallbacks.isEmpty || lossyHits > 0 }
}

/// A bounded, per-build record of what the gateway had to do for each binary in the field.
///
/// Bounded on purpose: the build number comes from the client, so an unbounded map would
/// let any caller grow gateway memory. At capacity the least-recently-seen build is
/// evicted and counted, never silently forgotten.
public struct DependencyLedger: Sendable {
    public private(set) var capacity: Int
    public private(set) var evictedBuilds: Int = 0
    /// Requests refused before routing (app-contract violations, retired builds). Kept as
    /// one number so client-supplied build numbers can't churn the per-build table.
    public private(set) var unattributedRejections: Int = 0
    private var entries: [Int: BuildDependency] = [:]
    private var lastSeen: [Int: UInt64] = [:]
    private var tick: UInt64 = 0

    public init(capacity: Int = 256) {
        // Eviction scans for the least-recently-seen build (O(capacity)), so capacity is clamped.
        self.capacity = Swift.min(Swift.max(1, capacity), DependencyLedger.maxCapacity)
    }

    public static let maxCapacity = 4_096

    public var trackedBuildCount: Int { entries.count }

    /// Adds `update` to the build's counters (creating, and if needed evicting, an entry).
    public mutating func record(build: Int, _ update: (inout BuildDependency) -> Void) {
        tick = tick &+ 1 // wraps after 2^64 records; ordering stays correct between wraps.
        if entries[build] == nil, entries.count >= capacity, let victim = lastSeen.min(by: { $0.value < $1.value })?.key {
            entries[victim] = nil
            lastSeen[victim] = nil
            evictedBuilds = evictedBuilds.addingSaturating(1)
        }
        var entry = entries[build] ?? BuildDependency(build: build)
        update(&entry)
        entries[build] = entry
        lastSeen[build] = tick
    }

    public mutating func recordUnattributedRejection() {
        unattributedRejections = unattributedRejections.addingSaturating(1)
    }

    public func dependency(for build: Int) -> BuildDependency? { entries[build] }

    /// All tracked builds, oldest build number first.
    public var snapshot: [BuildDependency] {
        entries.values.sorted { $0.build < $1.build }
    }

    /// Builds whose observed traffic depended on the legacy version, oldest first.
    public var observedLegacyDependents: [Int] {
        snapshot.filter(\.dependsOnLegacy).map(\.build)
    }
}

extension Dictionary where Value == Int {
    mutating func increment(_ key: Key, by amount: Int = 1) {
        self[key] = (self[key] ?? 0).addingSaturating(amount)
    }
}
