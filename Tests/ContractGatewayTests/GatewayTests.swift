import XCTest
@testable import ContractGateway

final class GatewayTests: XCTestCase {
    let lossy = app(412, sampling: .init(temperature: 0.2), user(.text("Classify this receipt")))
    let assistantFirstDoc = app(470, assistant(.text("context"), doc("Brief")), user(.text("summarise")))
    let relocatable = app(455, user(.text("q")), assistant(.text("a"), doc("Summary")), user(.text("q2")))

    func gateway(_ p: RoutingPolicy, _ transport: any ProviderTransport, translator: RequestTranslator = .standard) -> ContractGateway {
        ContractGateway(policy: p, transport: transport, translator: translator, now: { t0 })
    }

    func testStaleOrReplayedPolicyIsIgnored() async {
        let g = gateway(policy(rev: 3), RecordingTransport())
        let replay = await g.apply(policy(rev: 2, kill: true))
        XCTAssertEqual(replay, .stale(current: 3, offered: 2))
        let same = await g.apply(policy(rev: 3, kill: true))
        XCTAssertEqual(same, .stale(current: 3, offered: 3))
        let killSwitch = await g.currentPolicy.killSwitch
        XCTAssertFalse(killSwitch)
        let newer = await g.apply(policy(rev: 4, kill: true))
        XCTAssertEqual(newer, .applied(revision: 4))
    }

    func testPreserveIntentKeepsLossyRequestOnLegacy() async {
        let transport = RecordingTransport()
        let g = gateway(policy(intent: .preserveIntent), transport)
        let out = await g.handle(lossy)
        XCTAssertEqual(out.route?.target, .current)
        XCTAssertEqual(out.fallback, .preservedIntent)
        XCTAssertEqual(out.deliveredVersion, .legacy)
        XCTAssertEqual(out.adjustments, [])
        XCTAssertEqual(out.consideredAdjustments.map(\.rule), [.samplingRemoved], "the reason for the fallback is kept")
        let sent = await transport.sent
        XCTAssertEqual(sent.map(\.version), [.legacy])
        XCTAssertEqual(sent.first?.sampling.temperature, 0.2, "the intent the build asked for is honoured")
        let blockers = await g.dependencies.observedLegacyDependents
        XCTAssertEqual(blockers, [412])
    }

    func testPreferCurrentSendsLossyAndRecordsTheLoss() async {
        let transport = RecordingTransport()
        let g = gateway(policy(intent: .preferCurrent), transport)
        let out = await g.handle(lossy)
        XCTAssertNil(out.fallback)
        XCTAssertEqual(out.deliveredVersion, .current)
        XCTAssertEqual(out.adjustments.map(\.fidelity), [.lossy])
        let dep = await g.dependencies.dependency(for: 412)
        XCTAssertEqual(dep?.lossyHits, 1)
        XCTAssertEqual(dep?.dependsOnLegacy, true)
    }

    func testExactTranslationGoesToCurrentAndIsNotObservedAsLegacyDependent() async {
        let g = gateway(policy(), RecordingTransport())
        let out = await g.handle(app(431, model: opus, sampling: .init(temperature: 0.2), user(.text("q"))))
        XCTAssertEqual(out.deliveredVersion, .current)
        let blockers = await g.dependencies.observedLegacyDependents
        XCTAssertEqual(blockers, [])
    }

    func testUntranslatableFallsBackWhileLegacyIsServed() async {
        let g = gateway(policy(), RecordingTransport())
        let out = await g.handle(assistantFirstDoc)
        XCTAssertEqual(out.fallback, .untranslatable)
        XCTAssertEqual(out.deliveredVersion, .legacy)
        XCTAssertTrue(out.untranslatableReason?.hasPrefix("assistant-document-relocated:") ?? false)
        let dep = await g.dependencies.dependency(for: 470)
        XCTAssertEqual(dep?.fallbacks[.untranslatable], 1)
        XCTAssertEqual(dep?.deliveredLegacy, 1)
    }

    func testUntranslatableAfterSunsetIsRejectedAndNeverSent() async {
        let transport = RecordingTransport()
        let g = gateway(policy(sunset: t0), transport)
        let out = await g.handle(assistantFirstDoc)
        guard case .noCompatibleVersion(.assistantDocumentRelocated, _)? = out.rejection else {
            return XCTFail("expected noCompatibleVersion, got \(String(describing: out.rejection))")
        }
        XCTAssertEqual(out.route?.reason, .legacySunset)
        let sent = await transport.sent
        XCTAssertEqual(sent, [])
        let dep = await g.dependencies.dependency(for: 470)
        XCTAssertEqual(dep?.rejected, 1)
        XCTAssertEqual(dep?.fallbacks[.untranslatable], 1)
    }

    func testLossyAfterSunsetIsSentLossyBecauseThereIsNoAlternative() async {
        let g = gateway(policy(intent: .preserveIntent, sunset: t0), RecordingTransport())
        let out = await g.handle(lossy)
        XCTAssertNil(out.fallback)
        XCTAssertEqual(out.deliveredVersion, .current)
        XCTAssertEqual(out.adjustments.first?.fidelity, .lossy)
    }

    func testAppContractAndMinimumBuildAreRejectedBeforeAnySend() async {
        let transport = RecordingTransport()
        let g = gateway(policy(minBuild: 400), transport)
        let old = await g.handle(app(399, user(.text("q"))))
        XCTAssertEqual(old.rejection, .unsupportedBuild(build: 399, minimum: 400))
        let bad = await g.handle(app(500, .v2, sampling: .init(temperature: 0.4), user(.text("q"))))
        XCTAssertEqual(bad.rejection, .appContract(.samplingNotAllowedInSchema(.v2)))
        let sent = await transport.sent
        XCTAssertEqual(sent, [])
        let ledger = await g.dependencies
        XCTAssertEqual(ledger.trackedBuildCount, 0, "refused-before-routing requests get no per-build entry")
        XCTAssertEqual(ledger.unattributedRejections, 2)
    }

    func testMalformedOrRetiredTrafficCannotEvictRealBuilds() async {
        let g = ContractGateway(policy: policy(minBuild: 400), transport: RecordingTransport(), ledgerCapacity: 2, now: { t0 })
        _ = await g.handle(app(412, sampling: .init(temperature: 0.2), user(.text("q"))))
        for fake in 1...300 { _ = await g.handle(app(fake, user(.text("q")))) }        // all below the cutoff
        for fake in [-5, 0] { _ = await g.handle(app(fake, user(.text("q")))) }        // invalid build numbers
        let ledger = await g.dependencies
        XCTAssertEqual(ledger.observedLegacyDependents, [412])
        XCTAssertEqual(ledger.evictedBuilds, 0)
        XCTAssertEqual(ledger.unattributedRejections, 302)
    }

    /// Documents the residual risk stated in the README: well-formed requests with invented
    /// build numbers above the cutoff DO get per-build entries and can evict real builds.
    func testResidualRiskInventedValidBuildNumbersCanEvict() async {
        let g = ContractGateway(policy: policy(minBuild: 400), transport: RecordingTransport(), ledgerCapacity: 2, now: { t0 })
        _ = await g.handle(app(412, sampling: .init(temperature: 0.2), user(.text("q"))))
        for fake in 10_000...10_005 { _ = await g.handle(app(fake, user(.text("q")))) }
        let ledger = await g.dependencies
        XCTAssertEqual(ledger.observedLegacyDependents, [])
        XCTAssertEqual(ledger.evictedBuilds, 5)
        XCTAssertEqual(DependencyLedger(capacity: 1_000_000).capacity, DependencyLedger.maxCapacity)
    }

    func testRuleHitsCountAppliedAndConsideredRewrites() async {
        let g = gateway(policy(), RecordingTransport())
        _ = await g.handle(lossy)        // considered, then fell back
        _ = await g.handle(relocatable)  // applied
        let hits412 = await g.dependencies.dependency(for: 412)?.ruleHits
        let hits455 = await g.dependencies.dependency(for: 455)?.ruleHits
        XCTAssertEqual(hits412, [.samplingRemoved: 1])
        XCTAssertEqual(hits455, [.assistantDocumentRelocated: 1])
        let lossy412 = await g.dependencies.dependency(for: 412)?.lossyHits
        XCTAssertEqual(lossy412, 0, "nothing lossy was actually sent")
    }

    func testVendorRejectionRetriesExactlyOnceOnLegacy() async {
        let transport = RecordingTransport(answer: rejectCurrent)
        let g = gateway(policy(), transport)
        let out = await g.handle(relocatable)
        XCTAssertEqual(out.attempts.map(\.version), [.current, .legacy])
        XCTAssertEqual(out.fallback, .vendorRejected)
        XCTAssertEqual(out.deliveredVersion, .legacy)
        XCTAssertEqual(out.adjustments, [], "the delivered legacy request was sent unmodified")
        XCTAssertEqual(out.consideredAdjustments.map(\.rule), [.assistantDocumentRelocated], "what was tried on 2026-10-21 is kept")
        let dep = await g.dependencies.dependency(for: 455)
        XCTAssertEqual(dep?.fallbacks[.vendorRejected], 1)
    }

    func testRetryIsBoundedEvenWhenLegacyAlsoRejects() async {
        let transport = RecordingTransport(answer: { _ in ProviderResponse(status: 400, errorType: "invalid_request_error") })
        let g = gateway(policy(), transport)
        let out = await g.handle(relocatable)
        XCTAssertEqual(out.attempts.count, 2)
        XCTAssertNil(out.deliveredVersion)
        let dep = await g.dependencies.dependency(for: 455)
        XCTAssertNil(dep?.fallbacks[.vendorRejected], "both versions refused: the request is bad, not legacy-dependent")
        XCTAssertEqual(dep?.failed, 1)
        XCTAssertEqual(dep?.dependsOnLegacy, false)
    }

    func testNoRetryWhenTheFirstAttemptWasAlreadyLegacy() async {
        let transport = RecordingTransport(answer: { _ in ProviderResponse(status: 400, errorType: "invalid_request_error") })
        let out = await gateway(policy(), transport).handle(assistantFirstDoc) // falls back to legacy up front
        XCTAssertEqual(out.attempts.map(\.version), [.legacy])
        XCTAssertEqual(out.fallback, .untranslatable)
    }

    func testBuildPinnedToCurrentStillFallsBackWhenUntranslatable() async {
        let out = await gateway(policy(bp: 0, overrides: [470: .current]), RecordingTransport()).handle(assistantFirstDoc)
        XCTAssertEqual(out.route, RouteDecision(target: .current, reason: .buildOverride))
        XCTAssertEqual(out.fallback, .untranslatable)
        XCTAssertEqual(out.deliveredVersion, .legacy)
    }

    func testOversizedClientInputIsRejectedBeforeAnySend() async {
        let transport = RecordingTransport()
        let g = gateway(policy(), transport)
        let longID = await g.handle(app(1, id: String(repeating: "x", count: 129), user(.text("q"))))
        XCTAssertEqual(longID.rejection, .appContract(.identifierTooLong("installationID")))
        let tooManyCites = await g.handle(app(1, user(.text("q", citations: Array(repeating: cite, count: 65)))))
        XCTAssertEqual(tooManyCites.rejection, .appContract(.tooManyCitations(messageIndex: 0, count: 65, limit: 64)))
        let huge = await g.handle(app(1, user(.text(String(repeating: "a", count: 600_000)), .text(String(repeating: "b", count: 600_000)))))
        XCTAssertEqual(huge.rejection, .appContract(.textTooLarge(limit: 1_048_576)))
        let sent = await transport.sent
        XCTAssertEqual(sent, [])
    }

    func testNoRetryAfterSunsetOrWhenDisabledOrOnTransientErrors() async {
        for (p, answer) in [
            (policy(sunset: t0), rejectCurrent),
            (policy(retry: false), rejectCurrent),
            (policy(), { @Sendable (_: ProviderRequest) in ProviderResponse(status: 529, errorType: "overloaded_error") }),
            (policy(), { @Sendable (_: ProviderRequest) in ProviderResponse(status: 400, errorType: "authentication_error") }),
        ] {
            let transport = RecordingTransport(answer: answer)
            let out = await gateway(p, transport).handle(relocatable)
            XCTAssertEqual(out.attempts.count, 1)
        }
    }

    func testPreflightStopsABrokenRuleChainBeforeTheVendorSeesIt() async {
        let transport = RecordingTransport()
        let broken = RequestTranslator(rules: [SamplingRemovalRule(), UserCitationStripRule()]) // relocation rule missing
        let out = await gateway(policy(), transport, translator: broken).handle(relocatable)
        XCTAssertEqual(out.rejection, .preflightFailed([.documentInAssistantMessage(messageIndex: 1)]))
        let sent = await transport.sent
        XCTAssertEqual(sent, [])
    }

    /// Actor reentrancy: a policy update that lands while a request is suspended in the
    /// transport must not change that request's version or its retry decision.
    func testInFlightRequestKeepsItsPolicySnapshotAcrossSuspension() async {
        let transport = GatedTransport(answer: rejectCurrent)
        let g = gateway(policy(rev: 1, retry: true), transport)

        let request = relocatable
        let inFlight = Task { await g.handle(request) }
        let parked = await transport.waitForArrivals(1)
        XCTAssertTrue(parked)

        // Lands mid-flight: kill switch on, retries off.
        let update = await g.apply(policy(rev: 2, kill: true, retry: false))
        XCTAssertEqual(update, .applied(revision: 2))
        await transport.releaseAll()
        // Second attempt (the retry) parks too; release it.
        let retried = await transport.waitForArrivals(2)
        XCTAssertTrue(retried)
        await transport.releaseAll()

        let out = await inFlight.value
        XCTAssertEqual(out.policyRevision, 1)
        XCTAssertEqual(out.attempts.map(\.version), [.current, .legacy], "rev 1 allowed the retry; rev 2's 'no retry' must not leak in")

        // The next request sees rev 2.
        let next = Task { await g.handle(request) }
        _ = await transport.waitForArrivals(3)
        await transport.releaseAll()
        let after = await next.value
        XCTAssertEqual(after.policyRevision, 2)
        XCTAssertEqual(after.route?.reason, .killSwitch)
        XCTAssertEqual(after.attempts.map(\.version), [.legacy])
    }

    func testConcurrentRequestsAreAllCounted() async {
        let g = gateway(policy(bp: 5_000), RecordingTransport())
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    _ = await g.handle(app(400 + i % 4, id: "device-\(i)", user(.text("q"))))
                }
            }
        }
        let snapshot = await g.dependencies.snapshot
        XCTAssertEqual(snapshot.map(\.requests).reduce(0, +), 200)
        XCTAssertEqual(snapshot.map { $0.deliveredCurrent + $0.deliveredLegacy }.reduce(0, +), 200)
        XCTAssertGreaterThan(snapshot.map(\.deliveredCurrent).reduce(0, +), 0)
        XCTAssertGreaterThan(snapshot.map(\.deliveredLegacy).reduce(0, +), 0)
    }

    func testHeadersCarryOneCredentialAndTheVersion() {
        let h = ProviderRequest(version: .current, model: opus, messages: [user(.text("q"))]).headers(apiKey: "k")
        XCTAssertEqual(h, ["anthropic-version": "2026-10-21", "authorization": "Bearer k"])
    }
}

final class MatrixTests: XCTestCase {
    let fleet: [Fixture] = [
        Fixture(name: "receipt classifier, temperature 0.2", request: app(412, sampling: .init(temperature: 0.2), user(.text("classify")))),
        Fixture(name: "Opus at default temperature", request: app(431, model: opus, sampling: .init(temperature: 1.0), user(.text("q")))),
        Fixture(name: "summary echoed back in assistant turn", request: app(455, user(.text("q")), assistant(.text("a"), doc("S")), user(.text("q2")))),
        Fixture(name: "assistant-first brief", request: app(470, assistant(.text("ctx"), doc("Brief")), user(.text("go")))),
        Fixture(name: "cited policy quoted back", request: app(488, .v2, user(.text("policy", citations: [cite])))),
        Fixture(name: "clean v2", request: app(502, .v2, user(.text("q")))),
    ]

    func testGateBlocksUnacknowledgedLossAndPassesOnceSignedOff() {
        let cells = ContractMatrix.run(fleet)
        XCTAssertEqual(cells.count, fleet.count * 2)
        XCTAssertTrue(cells.filter { $0.version == .legacy }.allSatisfy { $0.verdict == .exact })

        let none = MatrixGate.evaluate(cells, acknowledged: [], legacyServed: true)
        XCTAssertFalse(none.passed)
        XCTAssertEqual(none.blocking.count, 3) // 412 sampling, 455 relocation, 488 citations
        XCTAssertEqual(none.legacyDependentBuilds, [470])
        XCTAssertEqual(none.sunsetBlockers, [412, 455, 470, 488])

        let signedOff: Set<Acknowledgement> = [
            .init(build: 412, rule: .samplingRemoved), .init(build: 455, rule: .assistantDocumentRelocated),
            .init(build: 488, rule: .userCitationsStripped),
        ]
        let ok = MatrixGate.evaluate(cells, acknowledged: signedOff, legacyServed: true)
        XCTAssertTrue(ok.passed, "\(ok.blocking)")
        XCTAssertEqual(ok.acknowledged.count, 3)
        XCTAssertEqual(ok.sunsetBlockers, [470], "signed-off loss no longer blocks; untranslatable still does")

        let sunset = MatrixGate.evaluate(cells, acknowledged: signedOff, legacyServed: false)
        XCTAssertEqual(sunset.blocking.count, 1)
        XCTAssertTrue(sunset.blocking.first?.contains("build 470") ?? false)
    }

    func testAcknowledgementIsPerBuildNotPerRule() {
        let cells = ContractMatrix.run(fleet)
        let wrongBuild = MatrixGate.evaluate(cells, acknowledged: [.init(build: 999, rule: .samplingRemoved)], legacyServed: true)
        XCTAssertTrue(wrongBuild.blocking.contains { $0.contains("build 412") })
    }

    func testGateFailsWhenTheTranslatorIsBroken() {
        let broken = RequestTranslator(rules: [SamplingRemovalRule(), UserCitationStripRule()])
        let report = MatrixGate.evaluate(ContractMatrix.run(fleet, translator: broken), acknowledged: [], legacyServed: true)
        XCTAssertTrue(report.blocking.contains { $0.contains("would be rejected") && $0.contains("build 455") })
        XCTAssertTrue(report.sunsetBlockers.contains(455))
    }

    func testRetiredBuildsNeitherPassNorBlock() {
        let cells = ContractMatrix.run(fleet, minimumSupportedBuild: 450)
        XCTAssertTrue(cells.filter { $0.build < 450 }.allSatisfy { $0.verdict == .retired(minimumSupportedBuild: 450) })
        let report = MatrixGate.evaluate(cells, acknowledged: [], legacyServed: true)
        XCTAssertFalse(report.sunsetBlockers.contains(412))
        XCTAssertFalse(report.blocking.contains { $0.contains("build 412") })
    }

    func testDuplicateFixtureNamesBlock() {
        let dup = [Fixture(name: "same", request: app(1, user(.text("a")))), Fixture(name: "same", request: app(2, user(.text("b"))))]
        let report = MatrixGate.evaluate(ContractMatrix.run(dup), acknowledged: [], legacyServed: true)
        XCTAssertTrue(report.blocking.contains { $0.contains("duplicate fixture name 'same'") })
    }

    func testGateFailsOnABadFixture() {
        let bad = [Fixture(name: "v2 with temperature", request: app(600, .v2, sampling: .init(temperature: 0.1), user(.text("q"))))]
        XCTAssertFalse(MatrixGate.evaluate(ContractMatrix.run(bad), acknowledged: [], legacyServed: true).passed)
    }

    func testEmptyFleet() async {
        XCTAssertEqual(ContractMatrix.run([]), [])
        XCTAssertTrue(MatrixGate.evaluate([], acknowledged: [], legacyServed: false).passed)
        let report = await FleetRun.run(fixtures: [], policy: policy(), transport: SimulatedProvider(), acknowledged: [], now: t0)
        XCTAssertEqual(report.rows, [])
        XCTAssertEqual(report.sunsetBlockers, [])
        XCTAssertEqual(report.observedLegacyDependents, [])
    }

    func testFleetRunDefaultStory() async {
        let report = await FleetRun.run(fixtures: fleet, policy: policy(), transport: SimulatedProvider(),
                                        acknowledged: [], now: t0)
        let delivered = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.build, $0.outcome.deliveredVersion) })
        XCTAssertEqual(delivered[412], .legacy)   // lossy, preserve intent
        XCTAssertEqual(delivered[431], .current)  // exact strip
        XCTAssertEqual(delivered[455], .current)  // reattributed
        XCTAssertEqual(delivered[470], .legacy)   // untranslatable
        XCTAssertEqual(delivered[488], .legacy)   // lossy citations, preserve intent
        XCTAssertEqual(delivered[502], .current)
        XCTAssertEqual(report.observedLegacyDependents, [412, 470, 488])
        XCTAssertEqual(report.sunsetBlockers, [412, 455, 470, 488], "nothing acknowledged in this run")
    }

    /// The kill switch sends nothing to 2026-10-21, so the ledger observes no dependence.
    /// The sunset answer must not flip to "ready" just because traffic stopped probing.
    func testKillSwitchDoesNotMakeTheFleetLookSunsetReady() async {
        let report = await FleetRun.run(fixtures: fleet, policy: policy(kill: true), transport: SimulatedProvider(),
                                        acknowledged: [], now: t0)
        XCTAssertTrue(report.rows.allSatisfy { $0.outcome.deliveredVersion == .legacy })
        XCTAssertEqual(report.observedLegacyDependents, [])
        XCTAssertEqual(report.sunsetBlockers, [412, 455, 470, 488])
    }
}
