import Foundation

/// A reason a provider would reject a request with HTTP 400.
public enum ContractViolation: Sendable, Equatable, Hashable, CustomStringConvertible {
    case samplingParameterPresent(String)
    case documentInAssistantMessage(messageIndex: Int)
    case citationsOnUserText(messageIndex: Int)
    case noMessages
    case emptyMessage(messageIndex: Int)

    public var description: String {
        switch self {
        case .samplingParameterPresent(let p): return "\(p) is not accepted on 2026-10-21"
        case .documentInAssistantMessage(let i): return "document block in assistant message \(i)"
        case .citationsOnUserText(let i): return "citations on user text in message \(i)"
        case .noMessages: return "no messages"
        case .emptyMessage(let i): return "message \(i) is empty"
        }
    }
}

/// An *independent* statement of what each provider version accepts, written from the
/// migration guide's wording rather than derived from the translation rules.
///
/// It is the gateway's preflight oracle: a translated request is checked here before it is
/// sent, so a gap in the rule chain becomes a typed rejection inside your own system
/// instead of a 400 from the vendor on a user's phone. Keeping it separate from the rules
/// is the point. A validator built by re-running the rules would agree with every bug.
public enum ProviderContract {
    public static func violations(of request: ProviderRequest) -> [ContractViolation] {
        var found: [ContractViolation] = []
        if request.messages.isEmpty { found.append(.noMessages) }
        for (index, message) in request.messages.enumerated() where message.content.isEmpty {
            found.append(.emptyMessage(messageIndex: index))
        }
        guard request.version == .current else { return found }

        if request.sampling.temperature != nil { found.append(.samplingParameterPresent("temperature")) }
        if request.sampling.topP != nil { found.append(.samplingParameterPresent("top_p")) }
        if request.sampling.topK != nil { found.append(.samplingParameterPresent("top_k")) }
        for (index, message) in request.messages.enumerated() {
            switch message.role {
            case .assistant:
                if message.content.contains(where: { if case .document = $0 { return true } else { return false } }) {
                    found.append(.documentInAssistantMessage(messageIndex: index))
                }
            case .user:
                if message.content.contains(where: { if case .text(_, let c) = $0 { return !c.isEmpty } else { return false } }) {
                    found.append(.citationsOnUserText(messageIndex: index))
                }
            }
        }
        return found
    }
}
