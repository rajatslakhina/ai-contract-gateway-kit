import Foundation

/// A recorded request from one shipped build: the unit of the contract-test matrix.
public struct Fixture: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var request: AppRequest
    public init(name: String, request: AppRequest) {
        self.name = name
        self.request = request
    }
}

/// What one fixture looks like on one provider version.
public enum MatrixVerdict: Sendable, Equatable {
    case exact
    case adjusted([Adjustment])
    case untranslatable(RuleID, String)
    case invalid([ContractViolation])
    case appContract(AppContractViolation)
    /// Below the minimum supported build: the gateway refuses it on every version, so it
    /// neither passes nor blocks anything.
    case retired(minimumSupportedBuild: Int)

    public var label: String {
        switch self {
        case .exact: return "exact"
        case .adjusted(let a): return a.map(\.fidelity).max().map { "\($0)" } ?? "exact"
        case .untranslatable: return "untranslatable"
        case .invalid: return "invalid"
        case .appContract: return "app-contract"
        case .retired: return "retired"
        }
    }
}

public struct MatrixCell: Sendable, Equatable {
    public var fixture: String
    public var build: Int
    public var version: ProviderVersion
    public var verdict: MatrixVerdict
}

/// An explicit sign-off: "we know build N loses this on 2026-10-21 and accept it."
public struct Acknowledgement: Sendable, Hashable {
    public var build: Int
    public var rule: RuleID
    public init(build: Int, rule: RuleID) {
        self.build = build
        self.rule = rule
    }
}

/// Replays every recorded request against every provider version.
///
/// This is the CI gate the gateway is meant to ship with. It is pure and offline, so it
/// runs on every pull request that touches a rule, and again on the day the vendor
/// announces the next version.
public enum ContractMatrix {
    public static func run(_ fixtures: [Fixture],
                           translator: RequestTranslator = .standard,
                           catalog: ModelCatalog = .migrationGuideExamples,
                           versions: [ProviderVersion] = ProviderVersion.allCases,
                           limits: GatewayLimits = .standard,
                           minimumSupportedBuild: Int = 1) -> [MatrixCell] {
        var cells: [MatrixCell] = []
        cells.reserveCapacity(fixtures.count.multipliedReportingOverflow(by: versions.count).overflow ? 0 : fixtures.count * versions.count)
        for fixture in fixtures {
            for version in versions {
                cells.append(MatrixCell(fixture: fixture.name, build: fixture.request.build, version: version,
                                        verdict: verdict(fixture.request, version, translator, catalog,
                                                         limits, minimumSupportedBuild)))
            }
        }
        return cells
    }

    static func verdict(_ app: AppRequest, _ version: ProviderVersion,
                        _ translator: RequestTranslator, _ catalog: ModelCatalog,
                        _ limits: GatewayLimits, _ minimumSupportedBuild: Int) -> MatrixVerdict {
        // Same order as the live gateway: app contract, then the build cutoff.
        if let violation = AppContract.validate(app, limits: limits) { return .appContract(violation) }
        if app.build < minimumSupportedBuild { return .retired(minimumSupportedBuild: minimumSupportedBuild) }
        switch translator.translate(app, to: version, catalog: catalog) {
        case .untranslatable(let rule, let why):
            return .untranslatable(rule, why)
        case .translated(let request, let adjustments):
            let violations = ProviderContract.violations(of: request)
            if !violations.isEmpty { return .invalid(violations) }
            return adjustments.isEmpty ? .exact : .adjusted(adjustments)
        }
    }
}

public struct GateReport: Sendable, Equatable {
    public var passed: Bool { blocking.isEmpty }
    /// Human-readable, one line per problem, sorted.
    public var blocking: [String]
    /// Builds that cannot run on `.current` and so still need `.legacy`.
    public var legacyDependentBuilds: [Int]
    /// Non-exact rewrites that were acknowledged, so they pass.
    public var acknowledged: [String]
    /// Builds that would break or silently get worse if `.legacy` were turned off today:
    /// their `.current` cell is invalid, untranslatable, or carries a non-exact rewrite
    /// nobody signed off. Traffic-independent, unlike the ledger's observed view.
    public var sunsetBlockers: [Int]
}

struct CellKey: Hashable {
    var fixture: String
    var version: ProviderVersion
}

public enum MatrixGate {
    /// The rules, in order of severity:
    /// 1. any `.invalid` cell fails: the translator produced something the vendor rejects;
    /// 2. any app-contract violation fails: the fixture itself is wrong;
    /// 3. a non-exact rewrite on `.current` fails unless `(build, rule)` is acknowledged;
    /// 4. an untranslatable fixture fails only once `.legacy` is no longer served,
    ///    and is otherwise reported as legacy-dependent.
    public static func evaluate(_ cells: [MatrixCell],
                                acknowledged: Set<Acknowledgement>,
                                legacyServed: Bool) -> GateReport {
        var blocking: Set<String> = []
        var accepted: Set<String> = []
        var legacyDependent: Set<Int> = []
        var blockers: Set<Int> = []

        var seen: [CellKey: Int] = [:]
        for cell in cells { seen.increment(CellKey(fixture: cell.fixture, version: cell.version)) }
        for (key, count) in seen where count > 1 {
            blocking.insert("duplicate fixture name '\(key.fixture)': results would be ambiguous")
        }

        for cell in cells {
            let where_ = "\(cell.fixture) (build \(cell.build)) on \(cell.version)"
            switch cell.verdict {
            case .exact, .retired:
                continue
            case .invalid(let violations):
                if cell.version == .current { blockers.insert(cell.build) }
                blocking.insert("\(where_): would be rejected: " + violations.map(\.description).joined(separator: "; "))
            case .appContract(let violation):
                blocking.insert("\(where_): fixture violates its app contract: \(violation)")
            case .untranslatable(let rule, _):
                guard cell.version == .current else {
                    blocking.insert("\(where_): untranslatable by \(rule)")
                    continue
                }
                legacyDependent.insert(cell.build)
                blockers.insert(cell.build)
                if !legacyServed { blocking.insert("\(where_): untranslatable by \(rule) and legacy is sunset") }
            case .adjusted(let adjustments):
                for adjustment in adjustments where adjustment.fidelity > .exact {
                    let line = "\(where_): \(adjustment.rule) is \(adjustment.fidelity)"
                    if acknowledged.contains(Acknowledgement(build: cell.build, rule: adjustment.rule)) {
                        accepted.insert(line)
                    } else {
                        blocking.insert(line + ", not acknowledged")
                        blockers.insert(cell.build)
                    }
                }
            }
        }
        return GateReport(blocking: blocking.sorted(), legacyDependentBuilds: legacyDependent.sorted(),
                          acknowledged: accepted.sorted(), sunsetBlockers: blockers.sorted())
    }
}
