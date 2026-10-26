import XCTest
@testable import ContractGateway

final class TranslationTests: XCTestCase {
    let t = RequestTranslator.standard

    // MARK: sampling

    func testLoweredTemperatureOnSamplingModelIsLossyAndRemoved() throws {
        let r = app(412, sampling: .init(temperature: 0.2), user(.text("Classify this receipt")))
        let (out, adj) = try XCTUnwrap(translated(t.translate(r, to: .current, catalog: catalog)))
        XCTAssertTrue(out.sampling.isEmpty)
        XCTAssertEqual(adj.map(\.rule), [.samplingRemoved])
        XCTAssertEqual(adj.first?.fidelity, .lossy)
        XCTAssertEqual(ProviderContract.violations(of: out), [])
    }

    func testSamplingOnDefaultsOnlyModelIsExact() throws {
        let r = app(431, model: opus, sampling: .init(temperature: 0.2), user(.text("hi")))
        let (_, adj) = try XCTUnwrap(translated(t.translate(r, to: .current, catalog: catalog)))
        XCTAssertEqual(adj.first?.fidelity, .exact)
    }

    func testDefaultTemperatureAloneIsExactButTopKIsIntent() throws {
        let plain = app(1, sampling: .init(temperature: 1.0), user(.text("hi")))
        XCTAssertEqual(try XCTUnwrap(translated(t.translate(plain, to: .current, catalog: catalog))).1.first?.fidelity, .exact)
        let withK = app(1, sampling: .init(temperature: 1.0, topK: 40), user(.text("hi")))
        XCTAssertEqual(try XCTUnwrap(translated(t.translate(withK, to: .current, catalog: catalog))).1.first?.fidelity, .lossy)
    }

    func testUnknownModelIsTreatedAsHonouringSampling() throws {
        let r = app(1, model: "some-future-model", sampling: .init(temperature: 0), user(.text("hi")))
        XCTAssertEqual(try XCTUnwrap(translated(t.translate(r, to: .current, catalog: catalog))).1.first?.fidelity, .lossy)
    }

    func testLegacyTargetIsIdentity() throws {
        let r = app(412, sampling: .init(temperature: 0.2, topP: 0.9, topK: 5),
                    user(.text("q", citations: [cite])), assistant(.text("a"), doc("Summary")), user(.text("more")))
        let (out, adj) = try XCTUnwrap(translated(t.translate(r, to: .legacy, catalog: catalog)))
        XCTAssertEqual(adj, [])
        XCTAssertEqual(out.messages, r.messages)
        XCTAssertEqual(out.sampling, r.sampling)
    }

    // MARK: documents in assistant turns

    func testAssistantDocumentMovesToNearestPrecedingUserMessage() throws {
        let r = app(455,
                    user(.text("first question")),
                    assistant(.text("here is a summary"), doc("Summary A")),
                    user(.text("second question")),
                    assistant(.text("another"), doc("Summary B")),
                    user(.text("third")))
        let (out, adj) = try XCTUnwrap(translated(t.translate(r, to: .current, catalog: catalog)))
        XCTAssertEqual(out.messages[0].content, [.text("first question"), doc("Summary A")])
        XCTAssertEqual(out.messages[1].content, [.text("here is a summary")])
        XCTAssertEqual(out.messages[2].content, [.text("second question"), doc("Summary B")])
        XCTAssertEqual(out.messages[3].content, [.text("another")])
        XCTAssertEqual(out.messages.count, r.messages.count, "no turn is invented or deleted")
        XCTAssertEqual(adj.map(\.fidelity), [.reattributed, .reattributed])
        XCTAssertEqual(adj.map(\.messageIndex), [1, 3], "the index names the assistant turn the document left")
        XCTAssertEqual(ProviderContract.violations(of: out), [])
    }

    func testAssistantDocumentWithNoEarlierUserIsUntranslatable() {
        let r = app(470, assistant(.text("context"), doc("Brief")), user(.text("summarise")))
        guard case .untranslatable(let rule, _) = t.translate(r, to: .current, catalog: catalog) else {
            return XCTFail("expected untranslatable")
        }
        XCTAssertEqual(rule, .assistantDocumentRelocated)
    }

    func testDocumentOnlyAssistantTurnIsUntranslatable() {
        let r = app(470, user(.text("q")), assistant(doc("Brief")), user(.text("summarise")))
        guard case .untranslatable(let rule, _) = t.translate(r, to: .current, catalog: catalog) else {
            return XCTFail("expected untranslatable")
        }
        XCTAssertEqual(rule, .assistantDocumentRelocated)
    }

    // MARK: citations

    func testUserCitationsStrippedAssistantCitationsKept() throws {
        let r = app(488, .v2,
                    user(.text("policy says", citations: [cite, cite])),
                    assistant(.text("per the policy", citations: [cite])),
                    user(.text("ok")))
        let (out, adj) = try XCTUnwrap(translated(t.translate(r, to: .current, catalog: catalog)))
        XCTAssertEqual(out.messages[0].content, [.text("policy says")])
        XCTAssertEqual(out.messages[1].content, [.text("per the policy", citations: [cite])])
        XCTAssertEqual(adj.map(\.rule), [.userCitationsStripped])
        XCTAssertEqual(adj.first?.detail, "dropped 2 citation(s) from user text")
        XCTAssertEqual(ProviderContract.violations(of: out), [])
    }

    // MARK: chain properties

    func testChainIsIdempotentOnItsOwnOutput() throws {
        let r = app(1, sampling: .init(temperature: 0.3),
                    user(.text("q", citations: [cite])), assistant(.text("a"), doc("D")), user(.text("q2")))
        let (once, adj) = try XCTUnwrap(translated(t.translate(r, to: .current, catalog: catalog)))
        XCTAssertEqual(Set(adj.map(\.rule)), Set(RuleID.allCases), "the sample must exercise every rule")
        let (twice, adj2) = try XCTUnwrap(translated(t.translate(once, catalog: catalog)))
        XCTAssertEqual(twice, once)
        XCTAssertEqual(adj2, [])
    }

    func testEveryStandardRuleMeetsTheRuleContract() {
        let samples: [ProviderRequest] = [
            ProviderRequest(version: .current, model: sonnet, messages: [user(.text("plain"))]),
            ProviderRequest(version: .current, model: sonnet,
                            messages: [user(.text("q", citations: [cite])), assistant(.text("a"), doc("D")), user(.text("q2"))],
                            sampling: .init(temperature: 0.1, topK: 3)),
            ProviderRequest(version: .current, model: opus, messages: [assistant(doc("only"))]),
        ]
        for rule in RequestTranslator.standard.rules {
            for sample in samples {
                XCTAssertEqual(RuleConformance.violations(of: rule, on: sample, model: catalog.capabilities(for: sample.model)), [],
                               "\(rule.id) on \(sample.messages.count)-message sample")
            }
        }
    }
}

// MARK: - Deliberately broken implementations: the checks must FAIL on these.

/// Strips citations but claims it changed nothing.
struct SilentCitationStrip: TranslationRule {
    let id = RuleID.userCitationsStripped
    func apply(to request: inout ProviderRequest, context: TranslationContext) -> RuleOutcome {
        guard context.target == .current else { return .unchanged }
        for i in request.messages.indices {
            request.messages[i].content = request.messages[i].content.map {
                if case .text(let s, _) = $0 { return .text(s) } else { return $0 }
            }
        }
        return .unchanged
    }
}

/// Removes sampling on every version, including the one that accepts it.
struct OverEagerSampling: TranslationRule {
    let id = RuleID.samplingRemoved
    func apply(to request: inout ProviderRequest, context: TranslationContext) -> RuleOutcome {
        guard !request.sampling.isEmpty else { return .unchanged }
        request.sampling = .init()
        return .adjusted([Adjustment(rule: id, fidelity: .lossy, messageIndex: nil, detail: "removed")])
    }
}

/// Moves documents *into* the assistant turn after every user turn: not idempotent.
struct PingPongRelocation: TranslationRule {
    let id = RuleID.assistantDocumentRelocated
    func apply(to request: inout ProviderRequest, context: TranslationContext) -> RuleOutcome {
        guard context.target == .current else { return .unchanged }
        request.messages[0].content.append(doc("dup"))
        return .adjusted([Adjustment(rule: id, fidelity: .reattributed, messageIndex: 0, detail: "dup")])
    }
}

/// Only removes temperature, forgetting top_p/top_k.
struct TemperatureOnlyRule: TranslationRule {
    let id = RuleID.samplingRemoved
    func apply(to request: inout ProviderRequest, context: TranslationContext) -> RuleOutcome {
        guard context.target == .current, request.sampling.temperature != nil else { return .unchanged }
        request.sampling.temperature = nil
        return .adjusted([Adjustment(rule: id, fidelity: .lossy, messageIndex: nil, detail: "removed temperature")])
    }
}

final class BrokenImplementationTests: XCTestCase {
    let sample = ProviderRequest(version: .current, model: sonnet,
                                 messages: [user(.text("q", citations: [cite])), assistant(.text("a"))],
                                 sampling: .init(temperature: 0.2, topK: 4))

    func testConformanceCatchesSilentRewrite() {
        XCTAssertTrue(RuleConformance.violations(of: SilentCitationStrip(), on: sample, model: catalog.capabilities(for: sonnet))
            .contains { $0.contains("reported .unchanged") })
    }

    func testConformanceCatchesRuleThatTouchesLegacy() {
        XCTAssertTrue(RuleConformance.violations(of: OverEagerSampling(), on: sample, model: catalog.capabilities(for: sonnet))
            .contains { $0.contains("changed a 2023-06-01 request") })
    }

    func testConformanceCatchesNonIdempotentRule() {
        XCTAssertTrue(RuleConformance.violations(of: PingPongRelocation(), on: sample, model: catalog.capabilities(for: sonnet))
            .contains { $0.contains("not idempotent") })
    }

    func testPreflightCatchesIncompleteSamplingRule() throws {
        let broken = RequestTranslator(rules: [TemperatureOnlyRule(), AssistantDocumentRelocationRule(), UserCitationStripRule()])
        let r = app(1, sampling: .init(temperature: 0.2, topK: 4), user(.text("q")))
        let (out, _) = try XCTUnwrap(translated(broken.translate(r, to: .current, catalog: catalog)))
        XCTAssertEqual(ProviderContract.violations(of: out), [.samplingParameterPresent("top_k")])
    }

    func testPreflightCatchesMissingRelocationRule() throws {
        let broken = RequestTranslator(rules: [SamplingRemovalRule(), UserCitationStripRule()])
        let r = app(455, user(.text("q")), assistant(.text("a"), doc("D")))
        let (out, _) = try XCTUnwrap(translated(broken.translate(r, to: .current, catalog: catalog)))
        XCTAssertEqual(ProviderContract.violations(of: out), [.documentInAssistantMessage(messageIndex: 1)])
    }
}
