import Foundation

/// Identifies one translation rule. Stable across releases: dashboards and the
/// acknowledgement allowlist key on it.
public enum RuleID: String, Sendable, Codable, CaseIterable, Comparable, CustomStringConvertible {
    case samplingRemoved = "sampling-removed"
    case assistantDocumentRelocated = "assistant-document-relocated"
    case userCitationsStripped = "user-citations-stripped"

    public var description: String { rawValue }
    public static func < (lhs: RuleID, rhs: RuleID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How much meaning a rewrite gives up. Ordered from harmless to harmful.
public enum Fidelity: Int, Sendable, Codable, Comparable, CustomStringConvertible {
    /// Provider behaviour is unchanged (e.g. stripping a default-valued parameter).
    case exact = 0
    /// Every byte still reaches the model, but who "said" it changed.
    case reattributed = 1
    /// Something the app asked for is no longer honoured.
    case lossy = 2

    public static func < (lhs: Fidelity, rhs: Fidelity) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String {
        switch self {
        case .exact: return "exact"
        case .reattributed: return "reattributed"
        case .lossy: return "lossy"
        }
    }
}

/// One recorded rewrite. The gateway never changes a request without producing one.
public struct Adjustment: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var rule: RuleID
    public var fidelity: Fidelity
    public var messageIndex: Int?
    public var detail: String

    public init(rule: RuleID, fidelity: Fidelity, messageIndex: Int?, detail: String) {
        self.rule = rule
        self.fidelity = fidelity
        self.messageIndex = messageIndex
        self.detail = detail
    }

    public var description: String {
        let at = messageIndex.map { " @msg\($0)" } ?? ""
        return "\(rule) [\(fidelity)]\(at): \(detail)"
    }
}

/// The outcome of one rule on one request.
public enum RuleOutcome: Sendable, Equatable {
    case unchanged
    case adjusted([Adjustment])
    /// The rule cannot express this request on the target version at all.
    case cannotTranslate(String)
}

/// Context every rule may read. Rules are pure: no clock, no I/O, no shared state.
public struct TranslationContext: Sendable {
    public var target: ProviderVersion
    public var model: ModelCapabilities
    public init(target: ProviderVersion, model: ModelCapabilities) {
        self.target = target
        self.model = model
    }
}

/// One rewrite from the app's request shape to a provider version's shape.
///
/// Contract every conforming rule must keep (each one is tested):
/// - it is a no-op for versions it does not target;
/// - it is idempotent: running it on its own output yields `.unchanged`;
/// - every change it makes is reported as an `Adjustment`.
public protocol TranslationRule: Sendable {
    var id: RuleID { get }
    func apply(to request: inout ProviderRequest, context: TranslationContext) -> RuleOutcome
}

// MARK: - The three 2026-10-21 rules

/// `temperature`, `top_p` and `top_k` return 400 on `2026-10-21`, even at defaults.
public struct SamplingRemovalRule: TranslationRule {
    public let id = RuleID.samplingRemoved
    public init() {}

    public func apply(to request: inout ProviderRequest, context: TranslationContext) -> RuleOutcome {
        guard context.target == .current, !request.sampling.isEmpty else { return .unchanged }
        let removed = request.sampling
        request.sampling = .init()

        let fidelity: Fidelity
        let why: String
        if !context.model.acceptsNonDefaultSampling {
            fidelity = .exact
            why = "model already samples with defaults only"
        } else if removed.isDefaultOnly {
            fidelity = .exact
            why = "only the default temperature (1.0) was sent"
        } else {
            fidelity = .lossy
            why = "consistency intent dropped; no setting replaces it"
        }
        var parts: [String] = []
        if let t = removed.temperature { parts.append("temperature=\(t)") }
        if let p = removed.topP { parts.append("top_p=\(p)") }
        if let k = removed.topK { parts.append("top_k=\(k)") }
        return .adjusted([Adjustment(rule: id, fidelity: fidelity, messageIndex: nil,
                                     detail: "removed \(parts.joined(separator: ", ")); \(why)")])
    }
}

/// A `document` block directly in an `assistant` message returns 400 on `2026-10-21`.
///
/// Strategy: move each such block, in order, to the end of the nearest *preceding* user
/// message. Every byte still reaches the model, so the rewrite is `.reattributed`.
/// Two shapes cannot be rewritten without inventing or deleting a turn, and are refused:
/// - there is no earlier user message to carry the document;
/// - the assistant message would be left with no content.
public struct AssistantDocumentRelocationRule: TranslationRule {
    public let id = RuleID.assistantDocumentRelocated
    public init() {}

    public func apply(to request: inout ProviderRequest, context: TranslationContext) -> RuleOutcome {
        guard context.target == .current else { return .unchanged }
        var messages = request.messages
        var adjustments: [Adjustment] = []
        var lastUserIndex: Int? = nil

        for index in messages.indices {
            if messages[index].role == .user {
                lastUserIndex = index
                continue
            }
            let documents = messages[index].content.filter(\.isDocument)
            guard !documents.isEmpty else { continue }
            guard let carrier = lastUserIndex else {
                return .cannotTranslate("assistant message \(index) carries a document and no earlier user message exists to move it to")
            }
            let remaining = messages[index].content.filter { !$0.isDocument }
            guard !remaining.isEmpty else {
                return .cannotTranslate("assistant message \(index) contains only documents; moving them would leave an empty turn")
            }
            messages[index].content = remaining
            messages[carrier].content.append(contentsOf: documents)
            for case .document(let ref) in documents {
                adjustments.append(Adjustment(rule: id, fidelity: .reattributed, messageIndex: index,
                                              detail: "moved document '\(ref.title)' to user message \(carrier)"))
            }
        }
        guard !adjustments.isEmpty else { return .unchanged }
        request.messages = messages
        return .adjusted(adjustments)
    }
}

/// A `text` block with a non-empty `citations` array in a `user` message returns 400 on
/// `2026-10-21`. The citations are dropped and the text kept; citations on assistant text
/// are still accepted and are left alone.
public struct UserCitationStripRule: TranslationRule {
    public let id = RuleID.userCitationsStripped
    public init() {}

    public func apply(to request: inout ProviderRequest, context: TranslationContext) -> RuleOutcome {
        guard context.target == .current else { return .unchanged }
        var adjustments: [Adjustment] = []
        for index in request.messages.indices where request.messages[index].role == .user {
            var stripped = 0
            request.messages[index].content = request.messages[index].content.map { block in
                guard case .text(let value, let citations) = block, !citations.isEmpty else { return block }
                stripped = stripped.addingSaturating(citations.count)
                return .text(value, citations: [])
            }
            if stripped > 0 {
                adjustments.append(Adjustment(rule: id, fidelity: .lossy, messageIndex: index,
                                              detail: "dropped \(stripped) citation(s) from user text"))
            }
        }
        return adjustments.isEmpty ? .unchanged : .adjusted(adjustments)
    }
}

// MARK: - Translator

/// Result of translating one app request to one provider version.
public enum TranslationResult: Sendable, Equatable {
    case translated(ProviderRequest, [Adjustment])
    case untranslatable(RuleID, String)

    /// The worst fidelity among the adjustments; `.exact` when there are none.
    public var worstFidelity: Fidelity? {
        guard case .translated(_, let adjustments) = self else { return nil }
        return adjustments.map(\.fidelity).max() ?? .exact
    }
}

/// Runs an ordered rule chain. The chain is the only place provider shape knowledge lives,
/// so adding the next breaking version is "add rules + a validator case", not a rewrite.
public struct RequestTranslator: Sendable {
    public var rules: [any TranslationRule]

    public init(rules: [any TranslationRule]) { self.rules = rules }

    /// The rule chain for the `2026-10-21` migration.
    public static let standard = RequestTranslator(rules: [
        SamplingRemovalRule(),
        AssistantDocumentRelocationRule(),
        UserCitationStripRule(),
    ])

    public func translate(_ app: AppRequest, to target: ProviderVersion, catalog: ModelCatalog) -> TranslationResult {
        let lifted = ProviderRequest(version: target, model: app.model, messages: app.messages, sampling: app.sampling)
        return translate(lifted, catalog: catalog)
    }

    /// Re-runs the chain on an already-shaped provider request (used to prove idempotency).
    public func translate(_ request: ProviderRequest, catalog: ModelCatalog) -> TranslationResult {
        var working = request
        let context = TranslationContext(target: request.version, model: catalog.capabilities(for: request.model))
        var adjustments: [Adjustment] = []
        for rule in rules {
            switch rule.apply(to: &working, context: context) {
            case .unchanged: continue
            case .adjusted(let made): adjustments.append(contentsOf: made)
            case .cannotTranslate(let reason): return .untranslatable(rule.id, reason)
            }
        }
        return .translated(working, adjustments)
    }
}

// MARK: - Rule conformance

/// Checks the `TranslationRule` contract on a sample request. Run it in CI against every
/// rule and every recorded fixture; it is what makes "the gateway never changes a request
/// without saying so" a tested property rather than a code-review hope.
public enum RuleConformance {
    public static func violations(of rule: any TranslationRule, on sample: ProviderRequest,
                                  model: ModelCapabilities) -> [String] {
        var problems: [String] = []

        // 1. A no-op on versions the rule does not target.
        var onLegacy = sample
        onLegacy.version = .legacy
        let legacyCopy = onLegacy
        let legacyOutcome = rule.apply(to: &onLegacy, context: .init(target: .legacy, model: model))
        if legacyOutcome != .unchanged || onLegacy != legacyCopy {
            problems.append("\(rule.id): changed a 2023-06-01 request")
        }

        // 2. Every change is reported, and nothing is reported that did not change.
        var current = sample
        current.version = .current
        let before = current
        let outcome = rule.apply(to: &current, context: .init(target: .current, model: model))
        switch outcome {
        case .unchanged:
            if current != before { problems.append("\(rule.id): changed the request but reported .unchanged") }
        case .adjusted(let made):
            if made.isEmpty { problems.append("\(rule.id): reported .adjusted with no adjustments") }
            if current == before { problems.append("\(rule.id): reported adjustments but changed nothing") }
            if made.contains(where: { $0.rule != rule.id }) { problems.append("\(rule.id): reported another rule's id") }
        case .cannotTranslate:
            if current != before { problems.append("\(rule.id): refused but still mutated the request") }
            return problems
        }

        // 3. Idempotent: a second pass over its own output does nothing.
        let once = current
        let second = rule.apply(to: &current, context: .init(target: .current, model: model))
        if second != .unchanged || current != once {
            problems.append("\(rule.id): not idempotent")
        }
        return problems
    }
}
