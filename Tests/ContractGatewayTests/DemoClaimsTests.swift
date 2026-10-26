import XCTest
@testable import ContractGateway

/// Pins the claims the demo app's README makes. The fleet below mirrors
/// `ShippedFleet` in ai-contract-gateway-demo-app/Demo/DemoApp.swift (installation IDs
/// included, since they decide rollout buckets); keep the two in sync.
final class DemoClaimsTests: XCTestCase {
    static func d(_ title: String) -> ContentBlock { .document(DocumentRef(id: title.lowercased(), title: title)) }

    let fleet: [Fixture] = [
        Fixture(name: "Receipt classifier, temperature 0.2", request: AppRequest(schema: .v1, build: 412, installationID: "ios-412-a", model: sonnet,
                                                 messages: [user(.text("Classify this receipt line: 'UBER *TRIP 23.10'"))],
                                                 sampling: .init(temperature: 0.2))),
        Fixture(name: "Smart reply on Opus 4.7, default temperature", request: AppRequest(schema: .v1, build: 431, installationID: "ios-431-a", model: opus,
                                                 messages: [user(.text("Suggest a short reply"))], sampling: .init(temperature: 1.0))),
        Fixture(name: "Summary card echoed back in the assistant turn", request: AppRequest(schema: .v1, build: 455, installationID: "ios-455-a", model: sonnet,
                                                 messages: [user(.text("Summarise my trip notes")),
                                                            assistant(.text("Here is your summary."), d("Trip summary")),
                                                            user(.text("Now make it a checklist"))])),
        Fixture(name: "Onboarding brief that opens with an assistant turn", request: AppRequest(schema: .v1, build: 470, installationID: "ios-470-a", model: sonnet,
                                                 messages: [assistant(.text("Welcome! Here is your plan."), d("Starter plan")),
                                                            user(.text("Adjust it for a beginner"))])),
        Fixture(name: "Cited refund policy quoted back by the user", request: AppRequest(schema: .v2, build: 488, installationID: "ios-488-a", model: sonnet,
                                                 messages: [user(.text("Your policy says refunds take 30 days. Is that right?",
                                                                       citations: [Citation(sourceTitle: "Refund policy", citedText: "within 30 days")]))])),
        Fixture(name: "Current build, clean request", request: AppRequest(schema: .v2, build: 502, installationID: "ios-502-a", model: opus,
                                                 messages: [user(.text("Draft a packing list"))])),
    ]
    let acknowledged: Set<Acknowledgement> = [.init(build: 455, rule: .assistantDocumentRelocated),
                                              .init(build: 488, rule: .userCitationsStripped)]

    func run(_ knobs: GatewayKnobs) async -> FleetReport {
        await FleetRun.run(fixtures: fleet, policy: knobs.policy(revision: 1, referenceDate: t0), transport: knobs.transport,
                           acknowledged: acknowledged, now: t0)
    }

    func delivered(_ r: FleetReport) -> [Int: ProviderVersion?] {
        Dictionary(uniqueKeysWithValues: r.rows.map { ($0.build, $0.outcome.deliveredVersion) })
    }

    func testDefaultState() async {
        let r = await run(GatewayKnobs())
        XCTAssertEqual(delivered(r), [412: .legacy, 431: .current, 455: .current, 470: .legacy, 488: .legacy, 502: .current])
        XCTAssertEqual(r.rows.first { $0.build == 412 }?.outcome.fallback, .preservedIntent)
        XCTAssertEqual(r.rows.first { $0.build == 470 }?.outcome.fallback, .untranslatable)
        XCTAssertEqual(r.rows.first { $0.build == 488 }?.outcome.fallback, .preservedIntent)
        XCTAssertEqual(r.rows.first { $0.build == 412 }?.outcome.consideredAdjustments.map(\.fidelity), [.lossy])
        XCTAssertEqual(r.rows.first { $0.build == 488 }?.outcome.consideredAdjustments.map(\.fidelity), [.lossy])
        XCTAssertEqual(r.rows.first { $0.build == 502 }?.outcome.adjustments, [])
        XCTAssertEqual(r.rows.first { $0.build == 431 }?.outcome.adjustments.map(\.fidelity), [.exact])
        XCTAssertEqual(r.rows.first { $0.build == 455 }?.outcome.adjustments.map(\.fidelity), [.reattributed])
        XCTAssertEqual(r.sunsetBlockers, [412, 470])
        XCTAssertEqual(r.gate.blocking.count, 1)
        XCTAssertEqual(r.gate.blocking, ["Receipt classifier, temperature 0.2 (build 412) on 2026-10-21: sampling-removed is lossy, not acknowledged"])
    }

    func testPreferCurrent() async {
        let r = await run(GatewayKnobs(intentPolicy: .preferCurrent))
        XCTAssertEqual(delivered(r)[412], .current)
        XCTAssertEqual(delivered(r)[488], .current)
        XCTAssertEqual(r.rows.first { $0.build == 412 }?.outcome.adjustments.map(\.fidelity), [.lossy])
        XCTAssertEqual(r.rows.first { $0.build == 488 }?.outcome.adjustments.map(\.fidelity), [.lossy])
    }

    func testSunsetPassed() async {
        let r = await run(GatewayKnobs(legacySunsetPassed: true))
        let b470 = r.rows.first { $0.build == 470 }?.outcome
        XCTAssertEqual(b470?.attempts.count, 0)
        if case .noCompatibleVersion? = b470?.rejection {} else { XCTFail("470 should be rejected") }
        XCTAssertTrue(r.rows.filter { $0.build != 470 }.allSatisfy { $0.outcome.deliveredVersion == .current })
        XCTAssertEqual(r.gate.blocking.count, 2)
        XCTAssertTrue(r.gate.blocking.contains { $0.contains("build 470") && $0.contains("legacy is sunset") })
    }

    func testKillSwitchKeepsSunsetBlocked() async {
        let r = await run(GatewayKnobs(killSwitch: true))
        XCTAssertTrue(r.rows.allSatisfy { $0.outcome.deliveredVersion == .legacy })
        XCTAssertEqual(r.observedLegacyDependents, [])
        XCTAssertEqual(r.sunsetBlockers, [412, 470])
    }

    func testHalfRolloutBuckets() async {
        let r = await run(GatewayKnobs(rolloutPercent: 50))
        XCTAssertEqual(r.rows.first { $0.build == 412 }?.outcome.route?.reason, .outsideRollout(bucket: 9921))
        XCTAssertEqual(r.rows.first { $0.build == 470 }?.outcome.route?.reason, .outsideRollout(bucket: 7045))
    }

    func testHypotheticalVendorRuleHitsOnly455AndAddsItAsBlocker() async {
        let r = await run(GatewayKnobs(unannouncedVendorRule: true))
        let retried = r.rows.filter { $0.outcome.attempts.count > 1 }.map(\.build)
        XCTAssertEqual(retried, [455])
        let b455 = r.rows.first { $0.build == 455 }?.outcome
        XCTAssertEqual(b455?.attempts.map(\.version), [.current, .legacy])
        XCTAssertEqual(b455?.fallback, .vendorRejected)
        XCTAssertEqual(b455?.consideredAdjustments.map(\.rule), [.assistantDocumentRelocated])
        XCTAssertEqual(r.sunsetBlockers, [412, 455, 470], "live vendor evidence joins the matrix's answer")
    }
}
