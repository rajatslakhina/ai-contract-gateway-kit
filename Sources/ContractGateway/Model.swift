import Foundation

// MARK: - Provider side

/// A provider (vendor) API version the gateway can speak.
///
/// The gateway, never the app binary, owns this choice. An App Store build ships with an
/// *app-side* schema it can never change again; the provider version it ends up on is a
/// server-side routing decision that can be ramped, overridden per build and killed.
public enum ProviderVersion: String, Sendable, Codable, CaseIterable, Comparable, CustomStringConvertible {
    /// The long-lived version every pre-October-2026 SDK sent.
    case legacy = "2023-06-01"
    /// Claude API `2026-10-21`: sampling parameters, documents in assistant turns and
    /// citations on user text blocks all return HTTP 400.
    case current = "2026-10-21"

    /// The value sent in the `anthropic-version` header.
    public var headerValue: String { rawValue }
    public var description: String { rawValue }

    public static func < (lhs: ProviderVersion, rhs: ProviderVersion) -> Bool {
        lhs.rawValue < rhs.rawValue // ISO dates sort lexically.
    }
}

// MARK: - Shared content model

/// Message role on both sides of the gateway.
public enum Role: String, Sendable, Codable, Equatable {
    case user, assistant
}

/// A citation attached to a text block.
public struct Citation: Sendable, Codable, Equatable, Hashable {
    public var sourceTitle: String
    public var citedText: String
    public init(sourceTitle: String, citedText: String) {
        self.sourceTitle = sourceTitle
        self.citedText = citedText
    }
}

/// A document reference (the gateway never inspects the bytes).
public struct DocumentRef: Sendable, Codable, Equatable, Hashable {
    public var id: String
    public var title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// One content block. Deliberately the subset of the Messages API the October 2026
/// breaking changes touch; anything else would pass through untouched in a real gateway.
public enum ContentBlock: Sendable, Codable, Equatable, Hashable {
    case text(String, citations: [Citation])
    case document(DocumentRef)

    public static func text(_ value: String) -> ContentBlock { .text(value, citations: []) }

    var isDocument: Bool {
        if case .document = self { return true }
        return false
    }

    var hasCitations: Bool {
        if case .text(_, let citations) = self { return !citations.isEmpty }
        return false
    }
}

public struct Message: Sendable, Codable, Equatable, Hashable {
    public var role: Role
    public var content: [ContentBlock]
    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }
}

/// Sampling parameters as an old build sent them.
public struct SamplingParameters: Sendable, Codable, Equatable, Hashable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public init(temperature: Double? = nil, topP: Double? = nil, topK: Int? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
    }

    public var isEmpty: Bool { temperature == nil && topP == nil && topK == nil }

    /// `temperature == 1.0` alone is the documented default; it carries no intent.
    /// `top_p` / `top_k` have no value the migration guide calls a default, so any value
    /// is treated as intent (conservative: it is reported, never silently dropped).
    public var isDefaultOnly: Bool {
        topP == nil && topK == nil && (temperature == nil || temperature == 1.0)
    }
}

/// The wire request the gateway sends to the provider.
public struct ProviderRequest: Sendable, Equatable {
    public var version: ProviderVersion
    public var model: String
    public var messages: [Message]
    public var sampling: SamplingParameters

    public init(version: ProviderVersion, model: String, messages: [Message], sampling: SamplingParameters = .init()) {
        self.version = version
        self.model = model
        self.messages = messages
        self.sampling = sampling
    }

    /// Headers the gateway attaches. The credential is the gateway's, never the app's,
    /// and exactly one credential header is sent (the SDKs' one-credential-per-client rule).
    public func headers(apiKey: String) -> [String: String] {
        ["anthropic-version": version.headerValue, "authorization": "Bearer \(apiKey)"]
    }
}

// MARK: - App side

/// The schema an app binary was compiled against. It is frozen the day the build ships.
public enum AppSchema: Int, Sendable, Codable, Comparable, CaseIterable, CustomStringConvertible {
    /// Pre-October builds: may send sampling parameters, documents in assistant turns
    /// and citations on user text.
    case v1 = 1
    /// Builds compiled after the migration: no sampling parameters. (Documents and
    /// citations are still legal app-side; the gateway owns the provider shape.)
    case v2 = 2

    public static func < (lhs: AppSchema, rhs: AppSchema) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "app-schema v\(rawValue)" }
}

/// What an app binary sends to *your* gateway. It names an app schema and its own build,
/// never a provider API version: that is the one decision you cannot recall from a phone.
public struct AppRequest: Sendable, Codable, Equatable {
    public var schema: AppSchema
    public var build: Int
    /// Stable per-install identifier used for sticky percentage rollout.
    public var installationID: String
    public var model: String
    public var messages: [Message]
    public var sampling: SamplingParameters

    public init(schema: AppSchema, build: Int, installationID: String, model: String,
                messages: [Message], sampling: SamplingParameters = .init()) {
        self.schema = schema
        self.build = build
        self.installationID = installationID
        self.model = model
        self.messages = messages
        self.sampling = sampling
    }
}

/// Hard caps so a malformed or hostile client cannot make the gateway do unbounded work.
public struct GatewayLimits: Sendable, Equatable {
    public var maxMessages: Int
    public var maxBlocksPerMessage: Int
    /// Total UTF-8 bytes across all text, citation and document-title strings.
    public var maxTextBytes: Int
    public var maxCitationsPerBlock: Int
    /// Applies to the installation ID, model ID and document IDs.
    public var maxIdentifierBytes: Int

    public init(maxMessages: Int = 512, maxBlocksPerMessage: Int = 64, maxTextBytes: Int = 1_048_576,
                maxCitationsPerBlock: Int = 64, maxIdentifierBytes: Int = 128) {
        self.maxMessages = max(1, maxMessages)
        self.maxBlocksPerMessage = max(1, maxBlocksPerMessage)
        self.maxTextBytes = max(1, maxTextBytes)
        self.maxCitationsPerBlock = max(0, maxCitationsPerBlock)
        self.maxIdentifierBytes = max(1, maxIdentifierBytes)
    }
    public static let standard = GatewayLimits()
}

/// Ways an app request can violate its *own* schema. These are rejected before routing,
/// because translating a request the app was never allowed to send hides a client bug.
public enum AppContractViolation: Sendable, Equatable, CustomStringConvertible {
    case noMessages
    case emptyMessage(index: Int)
    case tooManyMessages(count: Int, limit: Int)
    case tooManyBlocks(messageIndex: Int, count: Int, limit: Int)
    case samplingNotAllowedInSchema(AppSchema)
    case samplingOutOfRange(String)
    case invalidBuild(Int)
    case tooManyCitations(messageIndex: Int, count: Int, limit: Int)
    case textTooLarge(limit: Int)
    case identifierTooLong(String)

    public var description: String {
        switch self {
        case .noMessages: return "request has no messages"
        case .emptyMessage(let i): return "message \(i) has no content"
        case .tooManyMessages(let c, let l): return "\(c) messages exceeds the limit of \(l)"
        case .tooManyBlocks(let i, let c, let l): return "message \(i) has \(c) blocks, limit \(l)"
        case .samplingNotAllowedInSchema(let s): return "\(s) may not send sampling parameters"
        case .samplingOutOfRange(let what): return "sampling parameter out of range: \(what)"
        case .invalidBuild(let b): return "build number \(b) is not positive"
        case .tooManyCitations(let i, let c, let l): return "message \(i) has a block with \(c) citations, limit \(l)"
        case .textTooLarge(let l): return "text exceeds \(l) UTF-8 bytes"
        case .identifierTooLong(let what): return "\(what) is longer than the identifier limit"
        }
    }
}

public enum AppContract {
    /// Validates an app request against its declared schema and the gateway limits.
    /// Returns the first violation, or `nil` when the request is acceptable.
    public static func validate(_ request: AppRequest, limits: GatewayLimits = .standard) -> AppContractViolation? {
        if request.build <= 0 { return .invalidBuild(request.build) }
        if request.installationID.utf8.count > limits.maxIdentifierBytes { return .identifierTooLong("installationID") }
        if request.model.utf8.count > limits.maxIdentifierBytes { return .identifierTooLong("model") }
        if request.messages.isEmpty { return .noMessages }
        if request.messages.count > limits.maxMessages {
            return .tooManyMessages(count: request.messages.count, limit: limits.maxMessages)
        }
        var textBytes = 0
        for (index, message) in request.messages.enumerated() {
            if message.content.isEmpty { return .emptyMessage(index: index) }
            if message.content.count > limits.maxBlocksPerMessage {
                return .tooManyBlocks(messageIndex: index, count: message.content.count, limit: limits.maxBlocksPerMessage)
            }
            for block in message.content {
                switch block {
                case .text(let value, let citations):
                    if citations.count > limits.maxCitationsPerBlock {
                        return .tooManyCitations(messageIndex: index, count: citations.count, limit: limits.maxCitationsPerBlock)
                    }
                    textBytes = textBytes.addingSaturating(value.utf8.count)
                    for citation in citations {
                        textBytes = textBytes.addingSaturating(citation.sourceTitle.utf8.count)
                            .addingSaturating(citation.citedText.utf8.count)
                    }
                case .document(let ref):
                    if ref.id.utf8.count > limits.maxIdentifierBytes { return .identifierTooLong("document id") }
                    textBytes = textBytes.addingSaturating(ref.title.utf8.count)
                }
                if textBytes > limits.maxTextBytes { return .textTooLarge(limit: limits.maxTextBytes) }
            }
        }
        let s = request.sampling
        if request.schema >= .v2 && !s.isEmpty { return .samplingNotAllowedInSchema(request.schema) }
        if let t = s.temperature, !(t.isFinite && t >= 0 && t <= 1) { return .samplingOutOfRange("temperature=\(t)") }
        if let p = s.topP, !(p.isFinite && p >= 0 && p <= 1) { return .samplingOutOfRange("top_p=\(p)") }
        if let k = s.topK, k <= 0 { return .samplingOutOfRange("top_k=\(k)") }
        return nil
    }
}

// MARK: - Models

/// What the gateway needs to know about a model to judge whether dropping a sampling
/// parameter changes behaviour.
public struct ModelCapabilities: Sendable, Equatable {
    /// `false` for models that already sample only with defaults (Claude 4.7 and later,
    /// per the migration guide), where removing the parameters is behaviour-preserving.
    public var acceptsNonDefaultSampling: Bool
    public init(acceptsNonDefaultSampling: Bool) {
        self.acceptsNonDefaultSampling = acceptsNonDefaultSampling
    }
}

/// Explicit model table. Unknown models are assumed to honour sampling, which makes the
/// gateway *report* a dropped parameter as lossy rather than silently call it exact.
public struct ModelCatalog: Sendable, Equatable {
    public var entries: [String: ModelCapabilities]
    public var unknownModelDefault: ModelCapabilities

    public init(entries: [String: ModelCapabilities],
                unknownModelDefault: ModelCapabilities = .init(acceptsNonDefaultSampling: true)) {
        self.entries = entries
        self.unknownModelDefault = unknownModelDefault
    }

    public func capabilities(for model: String) -> ModelCapabilities {
        entries[model] ?? unknownModelDefault
    }

    /// Illustrative table built from the migration guide's two named examples.
    public static let migrationGuideExamples = ModelCatalog(entries: [
        "claude-sonnet-4-6": .init(acceptsNonDefaultSampling: true),
        "claude-opus-4-7": .init(acceptsNonDefaultSampling: false),
    ])
}
