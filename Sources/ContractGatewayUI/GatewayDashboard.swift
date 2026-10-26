#if canImport(SwiftUI)
import SwiftUI
import ContractGateway

/// The dashboard's settings are the core module's `GatewayKnobs`, so the mapping from
/// toggles to `RoutingPolicy` is the one the library's tests check.
public typealias DashboardSettings = GatewayKnobs

/// Drives the dashboard. Every settings change becomes a *new policy revision*, exactly as
/// a remotely delivered policy would, and the whole fleet is replayed through a fresh gateway.
@MainActor
public final class DashboardModel: ObservableObject {
    @Published public var settings: DashboardSettings
    @Published public private(set) var report: FleetReport?
    /// The latest revision requested. `report?.policyRevision` is the one on screen.
    @Published public private(set) var revision: Int = 0

    public let fixtures: [Fixture]
    public let acknowledged: Set<Acknowledgement>
    public let catalog: ModelCatalog
    public let referenceDate: Date

    public init(fixtures: [Fixture], acknowledged: Set<Acknowledgement>, catalog: ModelCatalog,
                settings: DashboardSettings = .init(), referenceDate: Date = Date()) {
        self.fixtures = fixtures
        self.acknowledged = acknowledged
        self.catalog = catalog
        self.settings = settings
        self.referenceDate = referenceDate
    }

    public func run() async {
        revision = revision.addingSaturating(1)
        let requested = revision
        let knobs = settings
        let result = await FleetRun.run(fixtures: fixtures, policy: knobs.policy(revision: requested, referenceDate: referenceDate),
                                        transport: knobs.transport, acknowledged: acknowledged,
                                        catalog: catalog, now: referenceDate)
        // Reentrancy guard: a newer run may have started (and even finished) while this one
        // was suspended. Only the latest requested revision may write the screen.
        guard requested == revision, !Task.isCancelled else { return }
        report = result
    }
}

/// A one-screen view of every shipped build's request going through the gateway.
public struct GatewayDashboardView: View {
    @StateObject private var model: DashboardModel

    public init(model: @autoclosure @escaping () -> DashboardModel) {
        _model = StateObject(wrappedValue: model())
    }

    private static let intro = "Every App Store build you ever shipped still sends its own frozen request shape. The gateway decides which provider API version each request goes to, rewrites it, and records what was lost."
    private static let rolloutSteps = [0, 25, 50, 100]

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(verbatim: Self.intro)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                policySection
                if let report = model.report {
                    FleetSection(report: report)
                    SunsetSection(report: report)
                    GateSection(report: report)
                } else {
                    Section { ProgressView("Replaying fleet…") }
                }
            }
            .navigationTitle("Contract Gateway")
            .task(id: model.settings) { await model.run() }
        }
    }

    private var policySection: some View {
        Section {
            Picker("Rollout to 2026-10-21", selection: $model.settings.rolloutPercent) {
                ForEach(Self.rolloutSteps, id: \.self) { percent in
                    Text(verbatim: "\(percent)%").tag(percent)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Kill switch (all → 2023-06-01)", isOn: $model.settings.killSwitch)
            Picker("Lossy requests", selection: $model.settings.intentPolicy) {
                ForEach(IntentPolicy.allCases, id: \.self) { policy in
                    Text(verbatim: policy.description).tag(policy)
                }
            }
            Toggle("2023-06-01 sunset has passed", isOn: $model.settings.legacySunsetPassed)
            Toggle("Vendor ships an unannounced rule (hypothetical)", isOn: $model.settings.unannouncedVendorRule)
        } header: {
            Text(verbatim: "Routing policy · revision \(model.report?.policyRevision ?? model.revision)")
        }
    }
}

private struct FleetSection: View {
    let report: FleetReport

    var body: some View {
        Section("Fleet replay") {
            if report.rows.isEmpty {
                Text("No recorded requests.").foregroundStyle(.secondary)
            }
            ForEach(report.rows) { row in
                FleetRowView(row: row)
            }
        }
    }
}

private struct FleetRowView: View {
    let row: FleetRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: "Build \(row.build)").font(.headline)
                Text(verbatim: "v\(row.schema.rawValue)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                VersionBadge(outcome: row.outcome)
            }
            Text(verbatim: row.fixture).font(.subheadline)
            Text(verbatim: row.routeSummary).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(row.outcome.adjustments.enumerated()), id: \.offset) { item in
                AdjustmentLine(adjustment: item.element)
            }
            if let refusal = row.outcome.untranslatableReason {
                Text(verbatim: "◦ cannot be expressed on 2026-10-21: \(refusal)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(row.outcome.consideredAdjustments.enumerated()), id: \.offset) { item in
                Text(verbatim: "◦ not applied on 2026-10-21: \(item.element.rule.rawValue) [\(item.element.fidelity.description)]")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if row.outcome.attempts.count > 1 {
                Text("Vendor rejected 2026-10-21, retried once on 2023-06-01")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AdjustmentLine: View {
    let adjustment: Adjustment

    var body: some View {
        Text(verbatim: "• \(adjustment.rule.rawValue) [\(adjustment.fidelity.description)] \(adjustment.detail)")
            .font(.caption2)
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch adjustment.fidelity {
        case .exact: return .secondary
        case .reattributed: return .blue
        case .lossy: return .orange
        }
    }
}

private struct SunsetSection: View {
    let report: FleetReport

    var body: some View {
        Section {
            Label(headline, systemImage: report.sunsetBlockers.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(report.sunsetBlockers.isEmpty ? Color.green : Color.orange)
            Text(verbatim: observed)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Can we turn 2023-06-01 off?")
        } footer: {
            Text("The answer comes from the contract matrix over every recorded build, plus live vendor rejections; never from the absence of traffic. With the kill switch on, nothing reaches 2026-10-21, so traffic alone would look ready.")
        }
    }

    private var headline: String {
        let builds = report.sunsetBlockers
        if builds.isEmpty { return "No recorded build needs 2023-06-01" }
        let list = builds.map { String($0) }.joined(separator: ", ")
        return "Blocked by build \(list)"
    }

    private var observed: String {
        let builds = report.observedLegacyDependents
        if builds.isEmpty { return "Observed in this replay: no request needed 2023-06-01." }
        let list = builds.map { String($0) }.joined(separator: ", ")
        return "Observed in this replay: build \(list) needed 2023-06-01 or lost meaning on 2026-10-21."
    }
}

private struct GateSection: View {
    let report: FleetReport

    var body: some View {
        Section("Contract matrix gate (CI)") {
            Label(verdict, systemImage: report.gate.passed ? "checkmark.circle" : "xmark.octagon")
                .foregroundStyle(report.gate.passed ? Color.green : Color.red)
            ForEach(report.gate.blocking, id: \.self) { line in
                Text(verbatim: line).font(.caption2).foregroundStyle(.red)
            }
            ForEach(report.gate.acknowledged, id: \.self) { line in
                Text(verbatim: "acknowledged: \(line)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var verdict: String {
        report.gate.passed ? "PASS" : "FAIL · \(report.gate.blocking.count) blocking"
    }
}

private struct VersionBadge: View {
    let outcome: GatewayOutcome

    var body: some View {
        Text(verbatim: label)
            .font(.caption.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        if outcome.rejection != nil { return "rejected" }
        guard let version = outcome.deliveredVersion else { return "failed" }
        return version.rawValue
    }

    private var tint: Color {
        if outcome.rejection != nil { return .red }
        guard let version = outcome.deliveredVersion else { return .red }
        return version == .current ? .green : .gray
    }
}
#endif
