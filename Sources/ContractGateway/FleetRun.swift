import Foundation

/// One fixture's journey through a gateway, flattened for display.
public struct FleetRow: Sendable, Equatable, Identifiable {
    /// Position in the fleet: unique even if two fixtures share a name.
    public var index: Int
    public var id: Int { index }
    public var fixture: String
    public var build: Int
    public var schema: AppSchema
    public var outcome: GatewayOutcome

    /// One-line summary of where the request went and why.
    public var routeSummary: String {
        if let rejection = outcome.rejection { return "rejected: \(rejection)" }
        var text = outcome.route.map { "\($0.reason)" } ?? "unrouted"
        if let fallback = outcome.fallback { text += " → fallback (\(fallback))" }
        return text
    }
}

public struct FleetReport: Sendable, Equatable {
    public var rows: [FleetRow]
    public var dependencies: [BuildDependency]
    /// Builds that block turning `.legacy` off: every build the contract matrix flags over
    /// the recorded fixtures, plus every build whose replayed traffic was rejected on
    /// `.current` by the vendor and then worked on `.legacy`. The matrix only knows the
    /// announced rules; the second half is the live evidence it can't have.
    public var sunsetBlockers: [Int]
    /// From the ledger: builds whose replayed traffic actually needed `.legacy` this run.
    public var observedLegacyDependents: [Int]
    public var gate: GateReport
    public var policyRevision: Int
}

/// Runs a whole fleet of recorded requests through a fresh gateway and the matrix gate.
/// The demo app uses this; so can an integration test or a CLI.
public enum FleetRun {
    public static func run(fixtures: [Fixture],
                           policy: RoutingPolicy,
                           transport: any ProviderTransport,
                           acknowledged: Set<Acknowledgement>,
                           catalog: ModelCatalog = .migrationGuideExamples,
                           translator: RequestTranslator = .standard,
                           now: Date = Date()) async -> FleetReport {
        let gateway = ContractGateway(policy: policy, transport: transport, translator: translator,
                                      catalog: catalog, now: { now })
        var rows: [FleetRow] = []
        rows.reserveCapacity(fixtures.count)
        for (index, fixture) in fixtures.enumerated() {
            let outcome = await gateway.handle(fixture.request)
            rows.append(FleetRow(index: index, fixture: fixture.name, build: fixture.request.build,
                                 schema: fixture.request.schema, outcome: outcome))
        }
        let ledger = await gateway.dependencies
        let cells = ContractMatrix.run(fixtures, translator: translator, catalog: catalog,
                                       minimumSupportedBuild: policy.minimumSupportedBuild)
        let gate = MatrixGate.evaluate(cells, acknowledged: acknowledged, legacyServed: policy.isLegacyServed(at: now))
        let vendorEvidence = ledger.snapshot.filter { ($0.fallbacks[.vendorRejected] ?? 0) > 0 }.map(\.build)
        let blockers = Set(gate.sunsetBlockers).union(vendorEvidence).sorted()
        return FleetReport(rows: rows, dependencies: ledger.snapshot, sunsetBlockers: blockers,
                           observedLegacyDependents: ledger.observedLegacyDependents,
                           gate: gate, policyRevision: policy.revision)
    }
}

// MARK: - Operator knobs

/// The handful of switches an on-call lead actually has during a provider migration,
/// mapped onto a `RoutingPolicy`. Lives in the core module (not the UI) so the mapping the
/// demo app shows is the mapping the tests check.
public struct GatewayKnobs: Equatable, Sendable {
    public var rolloutPercent: Int
    public var killSwitch: Bool
    public var intentPolicy: IntentPolicy
    public var legacySunsetPassed: Bool
    public var unannouncedVendorRule: Bool

    public init(rolloutPercent: Int = 100, killSwitch: Bool = false, intentPolicy: IntentPolicy = .preserveIntent,
                legacySunsetPassed: Bool = false, unannouncedVendorRule: Bool = false) {
        self.rolloutPercent = rolloutPercent
        self.killSwitch = killSwitch
        self.intentPolicy = intentPolicy
        self.legacySunsetPassed = legacySunsetPassed
        self.unannouncedVendorRule = unannouncedVendorRule
    }

    /// Sunset is one day in the past when passed, otherwise 90 days ahead of `referenceDate`.
    public func policy(revision: Int, referenceDate: Date) -> RoutingPolicy {
        let day: TimeInterval = 86_400
        let sunset = legacySunsetPassed ? referenceDate.addingTimeInterval(-day) : referenceDate.addingTimeInterval(90 * day)
        let percent = Swift.min(Swift.max(rolloutPercent, 0), 100)
        return RoutingPolicy(revision: revision, currentVersionBasisPoints: percent * 100, killSwitch: killSwitch,
                             intentPolicy: intentPolicy, legacySunset: sunset)
    }

    public var transport: SimulatedProvider {
        SimulatedProvider(extraRules: unannouncedVendorRule ? [GatewayKnobs.hypotheticalVendorRule] : [])
    }

    /// A deliberately made-up vendor rule, NOT part of the real 2026-10-21 change: on
    /// `.current`, a user message may not end with a document block. It exists to exercise
    /// the vendor-rejection retry path, and it happens to collide with this library's own
    /// relocation strategy (documents are appended to the user turn).
    public static let hypotheticalVendorRule: SimulatedProvider.ExtraRule = { request in
        guard request.version == .current else { return nil }
        for message in request.messages where message.role == .user {
            if let last = message.content.last, case .document = last {
                return "hypothetical rule: a user message may not end with a document block"
            }
        }
        return nil
    }
}
