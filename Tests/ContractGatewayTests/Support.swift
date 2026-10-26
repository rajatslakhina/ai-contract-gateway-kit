import Foundation
import XCTest
@testable import ContractGateway

let sonnet = "claude-sonnet-4-6"   // accepts non-default sampling
let opus = "claude-opus-4-7"       // samples with defaults only
let catalog = ModelCatalog.migrationGuideExamples
let t0 = Date(timeIntervalSince1970: 1_793_000_000)

func user(_ blocks: ContentBlock...) -> Message { Message(role: .user, content: blocks) }
func assistant(_ blocks: ContentBlock...) -> Message { Message(role: .assistant, content: blocks) }
func doc(_ title: String) -> ContentBlock { .document(DocumentRef(id: title.lowercased(), title: title)) }
let cite = Citation(sourceTitle: "Return policy", citedText: "30 days")

func app(_ build: Int, _ schema: AppSchema, model: String = sonnet, id: String = "install-1",
         sampling: SamplingParameters = .init(), _ messages: Message...) -> AppRequest {
    AppRequest(schema: schema, build: build, installationID: id, model: model, messages: messages, sampling: sampling)
}

func app(_ build: Int, model: String = sonnet, id: String = "install-1",
         sampling: SamplingParameters = .init(), _ messages: Message...) -> AppRequest {
    AppRequest(schema: .v1, build: build, installationID: id, model: model, messages: messages, sampling: sampling)
}

func policy(rev: Int = 1, bp: Int = 10_000, kill: Bool = false, intent: IntentPolicy = .preserveIntent,
            sunset: Date? = t0.addingTimeInterval(86_400 * 90), retry: Bool = true,
            overrides: [Int: ProviderVersion] = [:], minBuild: Int = 1) -> RoutingPolicy {
    RoutingPolicy(revision: rev, currentVersionBasisPoints: bp, buildOverrides: overrides, minimumSupportedBuild: minBuild,
                  killSwitch: kill, intentPolicy: intent, legacySunset: sunset, retryOnLegacyAfterRejection: retry)
}

func translated(_ result: TranslationResult, file: StaticString = #filePath, line: UInt = #line) -> (ProviderRequest, [Adjustment])? {
    guard case .translated(let request, let adjustments) = result else {
        XCTFail("expected .translated, got \(result)", file: file, line: line)
        return nil
    }
    return (request, adjustments)
}

/// Counts sends and answers from a script; thread-safe via an actor.
actor RecordingTransport: ProviderTransport {
    private(set) var sent: [ProviderRequest] = []
    private let answer: @Sendable (ProviderRequest) -> ProviderResponse

    init(answer: @escaping @Sendable (ProviderRequest) -> ProviderResponse = { _ in .ok }) {
        self.answer = answer
    }

    func send(_ request: ProviderRequest) async -> ProviderResponse {
        sent.append(request)
        return answer(request)
    }
}

let rejectCurrent: @Sendable (ProviderRequest) -> ProviderResponse = { request in
    request.version == .current
        ? ProviderResponse(status: 400, errorType: "invalid_request_error", message: "unannounced rule")
        : .ok
}

/// Holds every send until released, so a test can mutate the gateway mid-flight.
actor GatedTransport: ProviderTransport {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrived = 0
    private(set) var sent: [ProviderRequest] = []
    private let answer: @Sendable (ProviderRequest) -> ProviderResponse

    init(answer: @escaping @Sendable (ProviderRequest) -> ProviderResponse = { _ in .ok }) {
        self.answer = answer
    }

    func send(_ request: ProviderRequest) async -> ProviderResponse {
        sent.append(request)
        arrived += 1
        await withCheckedContinuation { waiters.append($0) }
        return answer(request)
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    /// Spins (bounded) until `count` sends are parked.
    func waitForArrivals(_ count: Int) async -> Bool {
        for _ in 0..<2_000 {
            if arrived >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
}
