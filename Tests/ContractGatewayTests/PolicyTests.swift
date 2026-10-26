import XCTest
@testable import ContractGateway

final class ProviderContractTests: XCTestCase {
    func testCurrentVersionRejectsEachBreakingShape() {
        let r = ProviderRequest(version: .current, model: sonnet,
                                messages: [user(.text("q", citations: [cite])), assistant(.text("a"), doc("D"))],
                                sampling: .init(temperature: 1.0, topP: 0.9, topK: 3))
        XCTAssertEqual(Set(ProviderContract.violations(of: r)), [
            .samplingParameterPresent("temperature"), .samplingParameterPresent("top_p"), .samplingParameterPresent("top_k"),
            .documentInAssistantMessage(messageIndex: 1), .citationsOnUserText(messageIndex: 0),
        ])
    }

    func testDefaultTemperatureIsStillRejectedOnCurrent() {
        // "returns a 400 error, even at the parameter's default value"
        let r = ProviderRequest(version: .current, model: opus, messages: [user(.text("q"))], sampling: .init(temperature: 1.0))
        XCTAssertEqual(ProviderContract.violations(of: r), [.samplingParameterPresent("temperature")])
    }

    func testLegacyAcceptsTheOldShapes() {
        var r = ProviderRequest(version: .legacy, model: sonnet,
                                messages: [user(.text("q", citations: [cite])), assistant(.text("a"), doc("D"))],
                                sampling: .init(temperature: 0.2))
        XCTAssertEqual(ProviderContract.violations(of: r), [])
        r.messages = []
        XCTAssertEqual(ProviderContract.violations(of: r), [.noMessages])
    }

    func testAssistantCitationsAndUserDocumentsAreAccepted() {
        let r = ProviderRequest(version: .current, model: sonnet,
                                messages: [user(.text("q"), doc("D")), assistant(.text("a", citations: [cite]))])
        XCTAssertEqual(ProviderContract.violations(of: r), [])
    }
}

final class AppContractTests: XCTestCase {
    func testV2MayNotSendSampling() {
        XCTAssertEqual(AppContract.validate(app(500, .v2, sampling: .init(temperature: 0.5), user(.text("q")))),
                       .samplingNotAllowedInSchema(.v2))
    }

    func testRejectsNonFiniteAndOutOfRangeSampling() {
        // (NaN and ±∞ also fail the range comparison; the explicit isFinite guard documents intent.)
        XCTAssertEqual(AppContract.validate(app(1, sampling: .init(temperature: .nan), user(.text("q")))),
                       .samplingOutOfRange("temperature=nan"))
        XCTAssertEqual(AppContract.validate(app(1, sampling: .init(temperature: .infinity), user(.text("q")))),
                       .samplingOutOfRange("temperature=inf"))
        XCTAssertEqual(AppContract.validate(app(1, sampling: .init(topP: -0.1), user(.text("q")))),
                       .samplingOutOfRange("top_p=-0.1"))
        XCTAssertEqual(AppContract.validate(app(1, sampling: .init(topK: 0), user(.text("q")))),
                       .samplingOutOfRange("top_k=0"))
        XCTAssertEqual(AppContract.validate(app(1, sampling: .init(topK: Int.min), user(.text("q")))),
                       .samplingOutOfRange("top_k=\(Int.min)"))
        XCTAssertEqual(AppContract.validate(app(1, sampling: .init(temperature: 1.5), user(.text("q")))), .samplingOutOfRange("temperature=1.5"))
        XCTAssertEqual(AppContract.validate(app(1, sampling: .init(temperature: -0.1), user(.text("q")))), .samplingOutOfRange("temperature=-0.1"))
        XCTAssertEqual(AppContract.validate(app(1, sampling: .init(topP: 1.1), user(.text("q")))), .samplingOutOfRange("top_p=1.1"))
        XCTAssertNil(AppContract.validate(app(1, sampling: .init(temperature: 0, topP: 1, topK: 1), user(.text("q")))))
    }

    func testEmptyAndOversizedRequests() {
        XCTAssertEqual(AppContract.validate(app(1)), .noMessages)
        XCTAssertEqual(AppContract.validate(app(1, user())), .emptyMessage(index: 0))
        XCTAssertEqual(AppContract.validate(app(0, user(.text("q")))), .invalidBuild(0))
        XCTAssertEqual(AppContract.validate(app(Int.min, user(.text("q")))), .invalidBuild(Int.min))
        let many = AppRequest(schema: .v1, build: 1, installationID: "x", model: sonnet,
                              messages: Array(repeating: user(.text("q")), count: 3))
        XCTAssertEqual(AppContract.validate(many, limits: GatewayLimits(maxMessages: 2)), .tooManyMessages(count: 3, limit: 2))
        let wide = app(1, Message(role: .user, content: Array(repeating: .text("q"), count: 5)))
        XCTAssertEqual(AppContract.validate(wide, limits: GatewayLimits(maxBlocksPerMessage: 4)),
                       .tooManyBlocks(messageIndex: 0, count: 5, limit: 4))
        XCTAssertEqual(AppContract.validate(app(1, model: String(repeating: "m", count: 129), user(.text("q")))),
                       .identifierTooLong("model"))
        XCTAssertEqual(AppContract.validate(app(1, user(.document(DocumentRef(id: String(repeating: "d", count: 129), title: "t"))))),
                       .identifierTooLong("document id"))
        let small = GatewayLimits(maxTextBytes: 10)
        let citeHeavy = app(1, user(.text("q", citations: [Citation(sourceTitle: "0123456789", citedText: "x")])))
        XCTAssertEqual(AppContract.validate(citeHeavy, limits: small), .textTooLarge(limit: 10), "citation strings count")
        let titleHeavy = app(1, user(.text("q"), .document(DocumentRef(id: "d", title: "0123456789A"))))
        XCTAssertEqual(AppContract.validate(titleHeavy, limits: small), .textTooLarge(limit: 10), "document titles count")
        XCTAssertEqual(GatewayLimits(maxMessages: -3, maxBlocksPerMessage: 0), GatewayLimits(maxMessages: 1, maxBlocksPerMessage: 1))
    }
}

final class RolloutTests: XCTestCase {
    func testFNV1aKnownVectors() {
        // Published FNV-1a 64 test vectors, not values produced by this implementation.
        XCTAssertEqual(StableBucket.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableBucket.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableBucket.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
    }

    func testPercentageIsRoughlyHonoured() {
        let p = policy(bp: 2_500)
        let inRollout = (0..<10_000).filter {
            Router.route(build: 1, installationID: "device-\($0)", policy: p, now: t0).target == .current
        }.count
        XCTAssertGreaterThan(inRollout, 2_200)
        XCTAssertLessThan(inRollout, 2_800)
    }

    func testRampIsSticky() {
        // Raising the percentage must never move an installation back to legacy.
        // This holds for any `bucket < threshold` scheme within one process; cross-process
        // stability (the reason `Hasher` is not used) is what testFNV1aKnownVectors pins.
        let ids = (0..<5_000).map { "device-\($0)" }
        let at25 = Set(ids.filter { Router.route(build: 1, installationID: $0, policy: policy(bp: 2_500), now: t0).target == .current })
        let at50 = Set(ids.filter { Router.route(build: 1, installationID: $0, policy: policy(bp: 5_000), now: t0).target == .current })
        XCTAssertFalse(at25.isEmpty)
        XCTAssertTrue(at25.isSubset(of: at50))
        XCTAssertGreaterThan(at50.count, at25.count)
    }

    func testSaltReshuffles() {
        let ids = (0..<1_000).map { "device-\($0)" }
        let a = ids.map { StableBucket.bucket(installationID: $0, salt: "a") }
        let b = ids.map { StableBucket.bucket(installationID: $0, salt: "b") }
        XCTAssertGreaterThan(zip(a, b).filter { $0 != $1 }.count, 900)
    }

    func testBasisPointsAreClampedAndEndpointsAreExact() {
        XCTAssertEqual(policy(bp: -5).currentVersionBasisPoints, 0)
        XCTAssertEqual(policy(bp: 20_000).currentVersionBasisPoints, 10_000)
        let ids = (0..<2_000).map { "d\($0)" }
        XCTAssertTrue(ids.allSatisfy { Router.route(build: 1, installationID: $0, policy: policy(bp: 0), now: t0).target == .legacy })
        XCTAssertTrue(ids.allSatisfy { Router.route(build: 1, installationID: $0, policy: policy(bp: 10_000), now: t0).target == .current })
    }

    func testBucketBoundaryIsStrict() throws {
        let id = try XCTUnwrap((0..<10_000).map { "d\($0)" }.first {
            StableBucket.bucket(installationID: $0, salt: "api-2026-10-21") > 0
        })
        let k = StableBucket.bucket(installationID: id, salt: "api-2026-10-21")
        XCTAssertEqual(Router.route(build: 1, installationID: id, policy: policy(bp: k), now: t0).target, .legacy)
        XCTAssertEqual(Router.route(build: 1, installationID: id, policy: policy(bp: k + 1), now: t0).target, .current)
    }

    func testPrecedence() {
        let pinned = policy(bp: 0, overrides: [7: .current])
        XCTAssertEqual(Router.route(build: 7, installationID: "x", policy: pinned, now: t0),
                       RouteDecision(target: .current, reason: .buildOverride))
        var killed = pinned
        killed.killSwitch = true
        XCTAssertEqual(Router.route(build: 7, installationID: "x", policy: killed, now: t0),
                       RouteDecision(target: .legacy, reason: .killSwitch))
        let sunset = policy(bp: 0, sunset: t0, overrides: [7: .legacy])
        XCTAssertEqual(Router.route(build: 7, installationID: "x", policy: sunset, now: t0),
                       RouteDecision(target: .current, reason: .legacySunset), "sunset is inclusive: at the instant, legacy is gone")
        var killedAfterSunset = sunset
        killedAfterSunset.killSwitch = true
        XCTAssertEqual(Router.route(build: 7, installationID: "x", policy: killedAfterSunset, now: t0),
                       RouteDecision(target: .current, reason: .killSwitchIneffectiveAfterSunset))
    }
}

final class LedgerAndArithmeticTests: XCTestCase {
    func testSaturatingAddition() {
        XCTAssertEqual(Int.max.addingSaturating(1), Int.max)
        XCTAssertEqual(Int.min.addingSaturating(-1), Int.min)
        XCTAssertEqual(5.addingSaturating(-7), -2)
        var counts: [RuleID: Int] = [.samplingRemoved: Int.max]
        counts.increment(.samplingRemoved)
        XCTAssertEqual(counts[.samplingRemoved], Int.max)
    }

    func testLedgerEvictsLeastRecentlySeenBuildAndCountsIt() {
        var ledger = DependencyLedger(capacity: 2)
        ledger.record(build: 100) { $0.requests += 1 }
        ledger.record(build: 200) { $0.requests += 1 }
        ledger.record(build: 100) { $0.requests += 1 }   // 100 is now the most recent
        ledger.record(build: 300) { $0.requests += 1 }   // evicts 200
        XCTAssertEqual(ledger.snapshot.map(\.build), [100, 300])
        XCTAssertEqual(ledger.dependency(for: 100)?.requests, 2)
        XCTAssertEqual(ledger.evictedBuilds, 1)
        XCTAssertEqual(ledger.trackedBuildCount, 2)
    }

    func testLedgerCapacityIsAtLeastOneAndNeverGrows() {
        var ledger = DependencyLedger(capacity: 0)
        XCTAssertEqual(ledger.capacity, 1)
        for build in 1...500 { ledger.record(build: build) { $0.requests += 1 } }
        XCTAssertEqual(ledger.trackedBuildCount, 1)
        XCTAssertEqual(ledger.evictedBuilds, 499)
        XCTAssertEqual(ledger.snapshot.map(\.build), [500])
    }
}
