# ContractGateway

**You can roll back a server. You can't roll back the build on someone's phone.**

On 21 October 2026 Anthropic shipped Claude API version `2026-10-21`. Three request shapes that worked for years now return HTTP 400: `temperature`, `top_p` and `top_k` (even at their default values), `document` blocks directly in `assistant` messages, and `citations` on `text` blocks in `user` messages ([migration guide](https://platform.claude.com/docs/en/api/migration-2026-10-21)).

A web service redeploys and moves on. An iOS app can't. Every App Store build you shipped since you added the AI feature is still in the field, still sending the request shape it was compiled with. You can't force-update all of them, and you can't take any of them back.

`ContractGateway` is the server-side layer that sits between **every build you ever shipped** and the provider API. It decides which provider version each request goes to, rewrites it with explicit rules, refuses to send anything it knows the vendor will reject, and keeps a per-build ledger of what each binary still depends on. Together with a contract-test matrix over recorded requests from every build, that ledger answers the question a lead actually gets asked: *"Can we turn the old version off yet?"*

> **Demo app:** [**ai-contract-gateway-demo-app**](https://github.com/rajatslakhina/ai-contract-gateway-demo-app). It's a separate Xcode project that consumes this package as a remote, version-pinned dependency (`1.0.0`, with the revision locked in `Package.resolved`) and replays six shipped builds through the gateway. It has been run on an iPhone 18 Pro simulator, and the screenshots are in its README.

---

## Why this matters

Most teams treat a provider API migration as an SDK bump: change the header, fix the compile errors, ship. That works when the caller is a server you deploy. It fails when the caller is a binary that is frozen at the moment Apple approved it:

- **The app must never name a provider version.** If build 412 hard-codes `anthropic-version: 2023-06-01`, the vendor's sunset date becomes your outage date, and the only fix is an app update a share of users will never install.
- **Some rewrites lose meaning.** Dropping `temperature: 0.2` is not a no-op on a model that honours it. The guide says so plainly: "No other setting replaces it." Silently stripping it lets a receipt classifier get less consistent with nobody noticing.
- **Some requests cannot be expressed on the new version at all.** A conversation that *starts* with an assistant turn carrying a document has no earlier user turn to move the document into.
- **The vendor can change things you didn't model.** A gateway that only knows the announced rules has to fail safe when the vendor says no anyway.

Each of these is a decision with an owner. This package makes each decision explicit, typed and tested, instead of leaving it as an `if` statement in a proxy nobody reviews.

## Architecture

```
  App Store builds (frozen)                 ContractGateway (server, Swift)                       Provider
 ┌──────────────────────────┐    ┌──────────────────────────────────────────────────────┐
 │ build 412 · app-schema v1│    │ 1 AppContract.validate   (schema + hard limits),     │
 │ build 455 · app-schema v1│───▶│   then the minimum-supported-build cutoff            │
 │ build 502 · app-schema v2│    │ 2 Router.route           (kill switch › sunset ›     │
 └──────────────────────────┘    │                           build pin › sticky % ramp) │
                                 │ 3 RequestTranslator      (ordered TranslationRules)  │    2026-10-21
  sends: app schema + build      │ 4 fallback decision      (untranslatable / lossy +   │──▶ or
  never: a provider version      │                           preserveIntent → legacy)   │    2023-06-01
                                 │ 5 ProviderContract       (independent preflight)     │
                                 │ ── first await: transport.send ──────────────────────│
                                 │ 6 one retry on legacy if the vendor 400s anyway      │
                                 │ 7 DependencyLedger       (bounded, per build)        │
                                 └──────────────────────────────────────────────────────┘
   CI: ContractMatrix replays every recorded fixture × every provider version → MatrixGate
```

### The pieces

| Type | Responsibility |
|---|---|
| `AppRequest`, `AppSchema` | What a build sends: its own frozen schema (`v1`, `v2`), its build number and an installation ID. **Never a provider version.** |
| `AppContract` | Rejects requests a build was never allowed to send (a `v2` build sending `temperature`, NaN/∞ sampling, empty turns), and enforces `GatewayLimits` (message, block and citation counts, total text bytes, identifier lengths) so a hostile client can't make the gateway do unbounded work. |
| `RoutingPolicy`, `Router` | Revisioned remote policy: sticky percentage ramp (FNV-1a buckets), per-build pins, kill switch, legacy sunset date, plus the minimum supported build that `ContractGateway` enforces before routing. `Router.route` is a pure function of (policy, build, installation, time). |
| `TranslationRule` (protocol) | One rewrite per breaking change: `SamplingRemovalRule`, `AssistantDocumentRelocationRule`, `UserCitationStripRule`. Each reports every change as an `Adjustment` graded `exact`, `reattributed` or `lossy`, or refuses with `.cannotTranslate`. |
| `RequestTranslator` | Runs the ordered rule chain. Adding the next breaking version means adding rules and a validator case, not rewriting the proxy. |
| `ProviderContract` | An **independent** statement of what each version accepts, written from the guide's wording, not derived from the rules. It's the gateway's preflight check. |
| `ContractGateway` (actor) | Validate → cut off retired builds → route → translate → fall back → preflight → send → at most one retry → record. A fallback keeps its reason: the rewrites `2026-10-21` would have needed (`consideredAdjustments`), or the refusing rule and its explanation (`untranslatableReason`). |
| `DependencyLedger` | Bounded per-build counters from live traffic: delivered per version, failed, rejected, rule hits, applied lossy rewrites, fallbacks. `observedLegacyDependents` lists the builds whose traffic actually needed `2023-06-01`. |
| `ContractMatrix`, `MatrixGate` | CI gate: replay every recorded fixture against every version, using the gateway's limits and build cutoff; fail on anything invalid, on unacknowledged loss, on duplicate fixture names, and on untranslatable requests once legacy is gone. `GateReport.sunsetBlockers` is the traffic-independent answer to "can we turn `2023-06-01` off?". |
| `FleetRun`, `GatewayKnobs` | Replays a fleet through a fresh gateway and the gate. Its `sunsetBlockers` combines the matrix's answer with live evidence the matrix can't have: builds the vendor rejected on `2026-10-21` that then worked on `2023-06-01`. `GatewayKnobs` maps an operator's toggles onto a `RoutingPolicy`. |
| `RuleConformance` | Checks the rule contract (no-op on other versions, every change reported, idempotent) for any rule on any sample. |
| `ContractGatewayUI` | SwiftUI dashboard used by the demo app. |

## Design decisions and trade-offs

**1. The app sends an app schema, the gateway picks the provider version.**
The provider version is the one thing you can't recall from a phone, so it never ships in a binary. *Rejected:* letting each build send `anthropic-version` and having the gateway pass it through. That ties every build's lifetime to the vendor's sunset calendar.

**2. Fidelity is graded, and "lossy" is a routing input, not a log line.**
`exact` means behaviour is unchanged (a default-only temperature, or a model like Claude Opus 4.7 that already samples with defaults only). `reattributed` means every byte still reaches the model but a different role "said" it (a document moved from an assistant turn into the preceding user turn). `lossy` means something the app asked for is gone (a lowered temperature on Claude Sonnet 4.6, citations on user text). Under `IntentPolicy.preserveIntent` a lossy request stays on `2023-06-01` while that version is still served. That is the guide's own advice ("keep that request on `2023-06-01`"), turned into a policy switch. *Rejected:* a boolean "translated or not". It can't tell you which builds still block the sunset.
*Known trade-off:* acknowledgements feed the CI gate, not routing. Under `preserveIntent`, a lossy rewrite the team has signed off still stays on `2023-06-01` until you switch that build to `preferCurrent` behaviour (e.g. with a `buildOverrides` pin plus `.preferCurrent`) or the sunset arrives. A next step would be per-build intent overrides in `RoutingPolicy`, so signed-off loss rides the ramp instead of moving all at once.

**3. `top_p` and `top_k` are always treated as intent.**
The guide names `temperature: 1.0` as a default but gives no default for `top_p`/`top_k`, so any value is reported as lossy rather than guessed to be harmless. Unknown models are assumed to honour sampling for the same reason. The cost is some false "lossy" reports; the alternative is silent drift.

**4. Relocate documents to the *nearest preceding* user turn, and refuse rather than invent.**
Moving to the nearest earlier user turn keeps the document close to where it appeared in the conversation. If there is no earlier user turn, or the assistant turn would be left empty, the rule returns `.cannotTranslate` instead of inventing or deleting a turn. *Rejected:* synthesising an empty user turn. It changes the conversation's structure in a way no test would catch. *Also considered and rejected for v1:* moving the document to the nearest *following* user turn. That arguably keeps causality better (the user re-sends what the assistant produced as context for the next question), and it would make build 470 translatable. It also moves content forward in time across turns, past any assistant text that referred to it. Both directions are defensible; v1 picks the conservative one and refuses the rest, so the refusals stay visible in the ledger. A forward-then-backward strategy is the natural v2.

**5. The preflight validator is independent of the rules.**
A validator built by re-running the rules agrees with every bug in them. `ProviderContract` is written separately, from the guide's sentences. When a rule is missing or wrong, the gateway returns `.preflightFailed` inside your system and the vendor never sees the request. The tests prove this with deliberately broken rule chains.

**6. Decisions happen before the first `await`.**
`ContractGateway` is an actor, and actors are reentrant: while one request is suspended in `transport.send`, a new policy can land. Every decision for a request (version, rules applied, fallback and whether a retry is allowed) is made in one actor turn against one captured `RoutingPolicy` and one clock reading. The retry request is translated and preflighted up front, too. A test parks a request inside the transport, applies a kill-switch policy with retries disabled, and asserts that the in-flight request still finishes under its original revision. During development the test was run against a mutant that reads the live policy after the `await`, and it failed as intended. That mutant isn't checked in; the rule-level broken implementations are (`BrokenImplementationTests`). The demo dashboard applies the same idea: a fleet replay that finishes after a newer one started is discarded instead of overwriting the screen.

**7. At most one retry, only on contract rejections, only while legacy is served.**
If the vendor 400s a `2026-10-21` request the preflight believed valid (a rule you didn't know about), the gateway retries **once** on `2023-06-01`. It counts the build as legacy-dependent only if that retry succeeds. If both versions refuse, the request itself is bad and is counted as `failed`. 429/5xx are left to the transport, because retrying a different API version can't fix an overloaded server. *Known cost:* a 400 that has nothing to do with the API version (an over-long prompt, say) also costs one extra request. A production deployment would add a per-build retry budget or circuit breaker on top. *Rejected:* retrying in a loop, or retrying on every error. Both turn a vendor change into a traffic multiplier.

**8. Policies are revisioned; stale deliveries are ignored.**
Remote config arrives out of order. `apply(_:)` accepts only a strictly newer revision, so a replayed old policy can't quietly switch the kill switch back off.

**9. Everything the client controls is bounded.**
The build number comes from the client, so `DependencyLedger` has a fixed capacity and evicts the least-recently-seen build, counting each eviction. `GatewayLimits` caps message, block and citation counts, total text bytes (1 MiB by default) and identifier lengths. Requests refused before routing (malformed, or from a retired build) are counted in one aggregate, `unattributedRejections`, and never get a per-build entry, so malformed or retired traffic can't churn the ledger. *Residual risk, tested and documented:* a well-formed request carrying an invented build number above the cutoff still gets an entry and can evict a real build. Closing that needs build attestation (App Attest) or a server-side list of released builds. Capacity is clamped to 4,096 because eviction scans for the least-recently-seen build. Counters saturate instead of trapping, and buckets are derived from `UInt64 % 10_000`, so nothing overflows `Int` even on 32-bit platforms.

**10. "Can we sunset?" is answered from fixtures, not from traffic.**
The ledger only sees requests that were actually tried on `2026-10-21`. With the kill switch on, or a build outside the ramp, it sees nothing and would report the fleet as ready. So the primary answer is the matrix over recorded fixtures, joined with live vendor rejections; the observed ledger view is secondary.

**11. Rollout buckets use FNV-1a, not `Hasher`.**
`Hasher` is seeded per process, so an installation would jump in and out of the rollout on every gateway restart. FNV-1a is checked against its published test vectors, not against values it produced itself. A test also checks the ramp is sticky within a process (everyone in at 25% is still in at 50%); cross-process stability is what the test-vector check pins.

### Rejected alternatives at the system level

- **Force-update everyone.** It works for a security fix. As a migration strategy it's a support queue, and a minimum-build cutoff (`minimumSupportedBuild`) is already available for the builds you really do have to cut off.
- **Pin the whole fleet to `2023-06-01` until it is sunset.** That's the cheapest option on day one. On sunset day you'd flip every build at once, with no data on what breaks.
- **Use a generic API gateway with JSON-path rewrite rules.** Rewrites stay invisible, there's no grading of loss, no per-build ledger and no contract tests. The rewriting is the easy part.

## Usage

```swift
.package(url: "https://github.com/rajatslakhina/ai-contract-gateway-kit.git", from: "1.0.0")
```

```swift
import ContractGateway

let gateway = ContractGateway(
    policy: RoutingPolicy(revision: 7,
                          currentVersionBasisPoints: 2_500,          // 25% ramp
                          intentPolicy: .preserveIntent,
                          legacySunset: announcedSunsetDate),
    transport: myURLSessionTransport)                                  // conforms to ProviderTransport

let outcome = await gateway.handle(appRequest)
// outcome.route, outcome.fallback, outcome.adjustments, outcome.attempts, outcome.rejection

let observed = await gateway.dependencies.observedLegacyDependents     // e.g. [412, 470, 488]
```

In CI, replay recorded requests from every supported build:

```swift
let cells = ContractMatrix.run(recordedFixtures)
let report = MatrixGate.evaluate(cells,
                                 acknowledged: [.init(build: 455, rule: .assistantDocumentRelocated)],
                                 legacyServed: true)
precondition(report.passed, report.blocking.joined(separator: "\n"))
// report.sunsetBlockers: builds that block turning 2023-06-01 off
```

### Build and test the library

```sh
git clone https://github.com/rajatslakhina/ai-contract-gateway-kit.git
cd ai-contract-gateway-kit
swift build -Xswiftc -warnings-as-errors
swift test
```

The core module has no platform dependencies and builds on Linux. `ContractGatewayUI` is compiled only where SwiftUI exists (the macOS CI job builds it for the iOS Simulator).

## Scope and honesty notes

- The content model is the subset of the Messages API the `2026-10-21` breaking changes touch: text with citations, and documents. A production gateway passes every other block through untouched; that pass-through is not modelled here.
- `ModelCatalog.migrationGuideExamples` contains the two models the guide names as examples. It isn't a list of every model.
- `SimulatedProvider` enforces `ProviderContract`. It doesn't call the real API, and nothing in this repo sends a request to Anthropic.
- The SDK-side changes in the same release (the `Authorization: Bearer` header, one credential per client) are reflected only in `ProviderRequest.headers(apiKey:)`.
- The app↔gateway wire format is Swift's synthesized `Codable`, not a hand-designed, versioned JSON schema. A build sending an unknown `schema` value fails to decode rather than getting a typed rejection, and `ProviderRequest` has no encoder to the vendor's JSON. A production gateway needs both.
- On `2023-06-01`, the validator doesn't model per-model sampling constraints: a non-default temperature sent to a defaults-only model under the kill switch is passed through as the build sent it.

## Verification

What has actually happened, stated separately:

- **Built and tested locally:** Swift 6.0.3 on Linux (x86_64). Clean build (`rm -rf .build`) with `-Xswiftc -warnings-as-errors`, 0 warnings. `swift test -Xswiftc -warnings-as-errors`: **69 tests, 0 failures**.
- **The tests include deliberately broken implementations** that must fail the checks: a rule that rewrites silently, a rule that touches `2023-06-01`, a non-idempotent rule, a sampling rule that forgets `top_k`, and a rule chain missing the relocation rule. The reentrancy test was also checked against a mutant that reads the live policy after the `await` (not checked in).
- **CI ([Actions](https://github.com/rajatslakhina/ai-contract-gateway-kit/actions)), green on `v1.0.0`:**
  - **Linux** (`swift:6.0` container): build and test with warnings as errors. **69 tests, 0 failures.**
  - **macOS 15** (Xcode 16.4, Swift 6.1.2): build and test with warnings as errors (**69 tests, 0 failures**). It then runs `xcodebuild` for `generic/platform=iOS Simulator` with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, which compiles both modules, `ContractGatewayUI` included.
- **Run on a simulator:** the companion demo app resolved this package from GitHub at `1.0.0`. It was built and run on an **iPhone 18 Pro simulator (iOS 27.0)** on 26 Oct 2026. The dashboard rendered, the toggles changed outcomes as documented, and the screenshots are in the [demo README](https://github.com/rajatslakhina/ai-contract-gateway-demo-app#screenshots).
- **Independent review:** 3 rounds by a separate model instance before publication. The round-3 fixes were applied but not re-reviewed. After round 3, the SwiftUI views were restructured into smaller views for compile safety. That change is covered by CI, not by a further review.
