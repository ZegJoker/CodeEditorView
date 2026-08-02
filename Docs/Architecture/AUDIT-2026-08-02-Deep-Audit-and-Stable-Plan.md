# CodeEditorView New Codebase Deep Audit and Stable-Stage Implementation Plan

**Target outcome:** a production-quality, Xcode 26–class code editor kit for macOS 15+ and iOS 18+  
**Extension direction:** Swift-first authoring with Zed-style declarative contributions and host capabilities  
**Terminal requirement:** Ghostty must provide the production terminal state/rendering path  
**Audit date:** 2026-08-02  
**Audited archive:** `CodeEditorView-new.zip`  
**Archive SHA-256:** `834ff453b4c7e4a5cb13918036ac8b6185595c2ce12a378a77f15d657668778d`

---

## 1. Executive verdict

The new repository is **materially better than the previous audited snapshot**. Several earlier release blockers were addressed with real code rather than documentation-only changes:

- The package is now structurally resolvable: Tree-sitter grammar sources are committed in a separate local `CodeEditorGrammars` package.
- `DocumentStore.apply` stages a multi-edit transaction before committing it.
- Invalid UTF-16 offsets inside Unicode scalar boundaries are rejected.
- Undo/redo stack ownership moves only after successful grouped application.
- stale `DocumentRegistry` URI aliases are removed.
- dirty-tab close flows now have asynchronous save/discard/cancel orchestration.
- command chords account for exact-prefix ambiguity.
- workbench contribution registration tokens are retained.
- WasmKit now parses, instantiates, and calls the supplied module instead of selecting behavior solely from marker bytes.
- LSP document debouncing now coalesces to full-text synchronization rather than sending an incompatible last delta.
- workspace trust defaults are substantially more conservative.

Those changes move the repository from a broad prototype with several immediately destructive defects to a more credible **pre-alpha stabilization branch**. They do **not** yet justify Alpha, Beta, RC, Stable, or 1.0 claims.

### 1.1 Current recommended maturity

| Scope | Recommended status | Reason |
|---|---|---|
| Repository as a whole | **Pre-alpha / experimental** | Multiple P0 data-integrity, isolation, security, and integration blockers remain |
| Core editing engine | **Pre-alpha, approaching Alpha** | Transaction staging is real, but savepoint semantics, offset overflow, process/event primitives, and public undo APIs remain unsafe |
| Native editor UI | **Pre-alpha** | Unicode/IME/BiDi/selection geometry and large-selection behavior remain incomplete |
| Workspace/workbench | **Pre-alpha / experimental** | close orchestration improved, but filesystem transactions, rollback, deletion, restoration, and integrated IDE workflows remain incomplete |
| LSP/DAP/tasks/SCM/search | **Experimental** | shared-stream, request lifecycle, protocol completeness, dirty-buffer coordination, and real-tool integration gaps remain |
| Terminal | **Proof of concept only** | the default implementation is a raw byte spool shown in `NSTextView`/`UITextView`, not a Ghostty terminal UI |
| Extension SDK/runtime | **Experimental** | useful Swift API surface exists, but package signing, installation durability, broker authorization, TOML behavior, and Wasm containment are not production-safe |
| Internal “phase-16 RC” profile | **Incorrect and should be withdrawn** | it conflicts with the public pre-alpha declaration and with executable behavior |

### 1.2 Promotion decision

Do **not** promote this codebase beyond pre-alpha yet. The next valid promotion is **Alpha**, and Alpha should occur only after all of the following are true:

1. A clean exported source archive builds and tests on the supported macOS and iOS matrix.
2. No known operation can silently lose or overwrite user content.
3. document savepoints and external-file conflicts are correct.
4. workspace edits have typed, restart-recoverable transaction semantics.
5. shared event streams are multicast, bounded, observable, and gap-aware.
6. LSP/DAP request registration, cancellation, timeout, and late-response handling are race-free.
7. the shipping terminal requires a real linked Ghostty implementation and has no byte-spool fallback.
8. untrusted Wasm can be forcibly interrupted and constrained without guest cooperation.
9. extension signatures cover every package byte and bind publisher identity; installation is crash-durable and fail-closed.
10. release gates execute production integrations rather than validating manually authored status files.

### 1.3 Highest-priority stop-ship findings

| ID | Severity | Area | Stop-ship finding |
|---|---:|---|---|
| DOC-N01 | P0 | Documents | Dirty state is based on a monotonic version, so undoing to the saved content cannot return to clean state |
| DOC-N02 | P0 | Documents | normal document save bypasses the conflict-aware save API and overwrites with `expectedIdentity: nil`, `.overwrite` |
| DOC-N03 | P1 | Core | equal-offset insertion documentation promises declaration order, but implementation/test pin the reverse visible order |
| WSP-N01 | P0 | Workspace | workspace-edit rollback can double-restore resources, retain rollback edits in undo history, and cannot recover after a process crash |
| WSP-N02 | P0 | Workspace | delete can remove disk content before open dirty documents are safely resolved |
| EVT-N01 | P0 | Cross-cutting | several `AsyncStream` instances are consumed by multiple independent subsystems even though one stream does not broadcast each element to every iterator |
| RPC-N01 | P0 | LSP/DAP | “register-before-send” still creates an unstructured registration task; timeout/cancellation can win before pending state is installed |
| TER-N01 | P0 | Terminal | the default C shim is explicitly a “minimal VT-less byte spool,” and the workbench allows it in production-shaped paths |
| TER-N02 | P0 | Terminal UI | the visible terminal is a polled editable text view of full UTF-8 snapshots, not Ghostty’s terminal state, renderer, input model, or accessibility surface |
| WASM-N01 | P0 | Wasm | wall-time timeout sets a cooperative cancel flag but cannot interrupt a pure non-host-calling infinite Wasm loop |
| WASM-N02 | P0 | Wasm | memory growth, per-request deadlines, queue/log/request quotas, and guest allocation cleanup are incomplete |
| EXT-N01 | P0 | Signing | package inventory skips hidden files and explicitly excludes `.codeeditor/`, leaving package bytes outside the signature |
| EXT-N02 | P0 | Signing | default signing writes `publisher.json` after signing `checksums.json`, so publisher metadata is not cryptographically bound |
| EXT-N03 | P0 | Installation | install/update is not restart-durable; same-version reinstall can associate a plan parsed from new bytes with an existing old package directory |
| EXT-N04 | P0 | Capability broker | handle resolution does not verify that the calling extension owns the handle, enabling cross-extension handle reuse if a handle is disclosed |
| CI-N01 | P0 | Release truth | scorecard/defect/accessibility/performance/Ghostty/API gates can pass without proving production behavior |

### 1.4 Stable does not mean “the screens look like Xcode”

An Xcode 26–class editor target must be treated as a **quality and workflow contract**, not a visual skin. The kit needs predictable native text input, low-latency editing, project/workspace navigation, structured diagnostics, build/test workflows, source control, debugging, terminal integration, restoration, accessibility, and operability. A SwiftUI shell with Xcode-like panels is not sufficient when the underlying document, process, protocol, or persistence contracts are unsafe.

The roadmap in this report therefore stabilizes the dependency chain in this order:

```text
package truth
  → document correctness
    → process/event/RPC substrate
      → native editor input/layout
        → workspace transactions
          → search/tasks/SCM
            → LSP/DAP
              → Ghostty terminal
                → extensions/Wasm/security
                  → integrated Xcode-class workbench
                    → Beta/RC/Stable hardening
```

---

## 2. Audit scope, method, and limitations

### 2.1 Repository inventory

The submitted archive contains:

- **29 SwiftPM products**
- **51 targets** reported by the package model
- **369 Swift source files** under `Sources/`
- **68,816 lines of Swift source**
- **130 Swift test files** under `Tests/`
- **18,570 lines of Swift tests**
- **5 direct package dependencies**: TextStory, swift-collections, swift-tree-sitter, WasmKit, and the local `CodeEditorGrammars` package
- Swift tools 6.0, macOS 15+, and iOS 18+

Static risk inventory under `Sources/`:

| Pattern | Count | Interpretation |
|---|---:|---|
| `try?` | 336 | not all are defects, but silent error loss needs an allowlist and review |
| `fatalError(` | 16 | each public/runtime path must be eliminated, platform-gated, or proven unreachable |
| `precondition(` | 3 | verify none can be triggered by external/user/extension input |
| `@unchecked Sendable` | 103 | too large a concurrency-trust surface for Stable without evidence per site |
| `Task {` | 111 | lifecycle ownership and cancellation need review |
| `AsyncStream` references | 178 | stream ownership, buffering, broadcast, finish, and drop semantics need standardization |

### 2.2 Product/source inventory

| Source target | Swift files | Source LOC | Test files | Test LOC |
|---|---:|---:|---:|---:|
| `CodeEditorCommands` | 12 | 1,509 | 3 | 450 |
| `CodeEditorCore` | 35 | 4,306 | 11 | 873 |
| `CodeEditorDAP` | 8 | 2,056 | 3 | 369 |
| `CodeEditorDocuments` | 12 | 1,805 | 2 | 412 |
| `CodeEditorExtensionAPI` | 20 | 4,556 | 3 | 608 |
| `CodeEditorExtensionCLI` | 1 | 406 | 0 | 0 |
| `CodeEditorExtensionGuest` | 1 | 550 | 0 | 0 |
| `CodeEditorExtensionHost` | 37 | 7,696 | 11 | 3,635 |
| `CodeEditorExtensionProtocol` | 7 | 1,197 | 1 | 157 |
| `CodeEditorExtensionWasmGuest` | 1 | 271 | 0 | 0 |
| `CodeEditorExtensions` | 12 | 2,565 | 4 | 1,065 |
| `CodeEditorLSP` | 15 | 4,522 | 5 | 998 |
| `CodeEditorLanguageJSON` | 1 | 121 | 0 | 0 |
| `CodeEditorLanguageServices` | 7 | 3,042 | 4 | 518 |
| `CodeEditorLanguageSupport` | 13 | 1,232 | 1 | 90 |
| `CodeEditorLanguageSwift` | 1 | 122 | 0 | 0 |
| `CodeEditorLanguages` | 3 | 261 | 5 | 291 |
| `CodeEditorSearch` | 8 | 906 | 2 | 273 |
| `CodeEditorSourceControl` | 5 | 1,093 | 2 | 416 |
| `CodeEditorTasks` | 6 | 1,487 | 3 | 558 |
| `CodeEditorTerminal` | 11 | 1,938 | 3 | 439 |
| `CodeEditorTerminalGhostty` | 4 | 427 | 0 | 0 |
| `CodeEditorTreeSitter` | 7 | 1,048 | 1 | 39 |
| `CodeEditorView` | 99 | 15,328 | 53 | 4,791 |
| `CodeEditorWasmEngine` | 5 | 1,054 | 3 | 415 |
| `CodeEditorWasmEngineWasmKit` | 1 | 427 | 0 | 0 |
| `CodeEditorWorkbench` | 20 | 5,409 | 7 | 1,148 |
| `CodeEditorWorkspace` | 16 | 3,418 | 3 | 1,025 |
| `ConformanceExtensionGuest` | 1 | 64 | 0 | 0 |

The table is not a coverage score. It identifies obvious asymmetries: `CodeEditorTreeSitter`, `CodeEditorTerminalGhostty`, language packs, CLI/guest products, and WasmKit integration have insufficient direct test ownership relative to their stability claims and risk.

### 2.3 Activities performed

The audit included:

- archive integrity and source inventory
- SwiftPM manifest dump and product/target inspection
- clean dependency-resolution attempt
- comparison with the previous deep audit
- source review of document, undo, I/O, recovery, workspace, commands, native editor, workbench, Tree-sitter, search, tasks, SCM, LSP, DAP, terminal, extension package, broker, and Wasm paths
- static search for fake/stub/fallback behavior, swallowed errors, unbounded streams, unchecked concurrency, test doubles in production targets, and self-certified release gates
- execution of repository validation scripts that do not require unresolved external dependencies
- inspection of CI, status profiles, scorecards, defect declarations, API baselines, conformance claims, and release evidence design

### 2.4 What was executable

`swift package dump-package` succeeds. The previous missing-grammar manifest blocker is resolved.

These repository scripts returned success in the audit environment:

- `check-product-isolation.sh`
- `check-docs.sh`
- `check-feature-profiles.sh`
- `check-product-scorecards.sh`
- `check-defects.sh`
- `check-accessibility.sh`
- `check-grammar-pins.sh`
- `verify-grammars.sh`
- `check-perf-budgets.sh`
- `check-unchecked-sendable.sh`
- `check-ghostty-pin.sh`
- `check-vacuous-tests.sh`

Several of those successful results are themselves evidence of weak gate design, discussed later. For example, the product scorecard checker accepts dimensions marked `fail`, the Ghostty checker explicitly succeeds in unlinked mode, and accessibility/performance checks primarily inspect tokens or documents.

### 2.5 Build limitation

A complete `swift build`/`swift test` result is **not claimed**. Dependency resolution stopped before compilation because the isolated environment could not obtain remote SwiftPM dependencies and its SwiftPM cache referenced a missing `swift-tree-sitter` checkout:

```text
error: Git command 'git -C .../swift-tree-sitter-8abf6026 config --get remote.origin.url' failed:
fatal: cannot change to '.../swift-tree-sitter-8abf6026': No such file or directory
```

This is not attributed to repository source correctness. It means the audit can confirm manifest structure and deterministic source defects, but cannot certify complete compilation, platform linking, runtime tests, or sanitizer results. Clean-machine, empty-cache CI remains a mandatory Stable gate.

### 2.6 Confidence labels

- **Confirmed:** follows directly from deterministic source, package configuration, or executed gate behavior.
- **High confidence:** source ordering/lifetime makes the failure likely and a targeted regression test is specified.
- **Runtime verification required:** needs a real OS, tool, process, renderer, or performance run.

---

## 3. Delta from the previous audit

### 3.1 Correctly resolved

| Previous issue | New status | Audit conclusion |
|---|---|---|
| grammar targets absent from archive | Resolved | committed local grammar package makes the root manifest structurally valid |
| partial document mutation on failed transaction | Resolved | edits are validated and applied to staging storage before live commit |
| invalid UTF-16 interior offset maps to EOF | Resolved | scalar/surrogate interior positions are rejected |
| undo stack popped before failed application | Resolved for grouped path | grouped APIs commit stack movement after application succeeds |
| stale document URI aliases | Resolved | registry alias cleanup exists |
| dirty close had no save/discard/cancel path | Largely resolved | asynchronous close coordinator exists and synchronous unsafe paths fail closed |
| exact one-key binding made longer chord unreachable | Resolved in principle | dispatcher waits on prefix ambiguity |
| dropped workbench contribution tokens | Resolved | host retains tokens |
| WasmKit never instantiated module bytes | Resolved | current backend parses/instantiates the module |
| LSP debounce sent only the latest incompatible delta | Resolved in chosen mode | debounce now coalesces to full text |
| trust default was permissive | Improved | restricted/fail-closed defaults are present in more paths |

### 3.2 Partially resolved

| Area | Improvement | Remaining blocker |
|---|---|---|
| undo/redo | grouped TextDocument path is atomic | public per-edit convenience can still partially mutate a caller-owned document |
| save conflicts | compare-and-swap API exists | normal save bypasses it; default provider bridge ignores expected identity/policy |
| dirty state | `savedVersion` introduced | versions are monotonic, so undo cannot equal the old saved version |
| workspace edits | preflight/capture/journal code added | rollback model remains logically inconsistent and not restart-recoverable |
| commands | strict registration API exists | soft public registration still silently replaces; timeout failures are swallowed |
| workbench isolation | failed-contribution state exists | in-process SwiftUI wrapper is not crash, hang, memory, or privilege isolation |
| event backpressure | some streams are bounded and drops counted | several streams are single-consumer, unbounded, or lack resynchronization semantics |
| LSP/DAP request ordering | comments and helper names say register-before-send | registration itself is launched in a child `Task`, preserving a timeout/cancel race |
| Ghostty | package, pin, shim, adapter names exist | default shim has no VT state; UI is a snapshot text view; real link is optional |
| Wasm | actual Wasm executes | timeout and memory containment still depend on guest cooperation/incomplete limits |
| extension signing | visible-file exact map improved | hidden files, `.codeeditor/`, publisher binding, canonical statement, and durability remain unsafe |
| CI | many checks added | several checks validate declarations or optional integrations rather than behavior |

### 3.3 Newly identified or newly introduced

1. Same-offset insertion documentation and test comments contradict the pinned output.
2. `TextDocument`’s savepoint model cannot represent returning to saved content.
3. `TaskExecutionHandle.events` and similar streams are consumed by multiple services as though they were multicast.
4. extension broker handles are not bound to the caller at dispatch time.
5. same-version extension reinstalls can mix a new parsed plan with old installed bytes.
6. hidden package files and `.codeeditor/` content remain outside package signatures.
7. the terminal now has **two** public architectures: legacy custom VT types and a Ghostty-named snapshot path.
8. workspace regex replacement implements only `$0`, not normal capture/named-capture replacement semantics.
9. nested `.gitignore` discovery skips hidden files, including the ignore file itself.
10. SCM auth/progress APIs are present but are not wired into the Git process path.
11. the internal compatibility profile claims phase-16 RC and S0–S4 passing while the README correctly says pre-alpha.

---

## 4. Severity and promotion policy

| Severity | Meaning | Promotion rule |
|---|---|---|
| **P0** | data loss/corruption, security-boundary bypass, fake isolation, uncontainable guest/process, false release certification, or shipping implementation materially different from its claim | blocks Alpha for the affected dependency chain and blocks all RC/Stable claims |
| **P1** | major correctness, protocol/lifecycle race, native input failure, incomplete rollback, or significant feature contract mismatch | blocks Beta/RC for the affected product |
| **P2** | material completeness, performance, API, compatibility, or operational gap | must be fixed or explicitly excluded from Stable 1.0 scope |
| **P3** | polish, ergonomics, low-risk documentation, or noncritical test gap | may remain only with an owner and public limitation |

A product is not Stable merely because its scorecard is complete. Stable requires:

- no open P0/P1 defects
- a defined public behavioral scope
- semantic-versioned public API and migration policy
- strict Swift 6 concurrency with justified unsafe boundaries
- deterministic cancellation, timeout, cleanup, and shutdown
- no silent data loss or fail-open security behavior
- oldest/latest supported platform builds and runtime tests
- accessibility and keyboard behavior tested with real UI automation/manual protocol
- measured performance on a named reference machine/device
- real integrations for every advertised external protocol/runtime
- crash/restart recovery where persistent state is involved
- accurate documentation generated from executable evidence

---

## 5. Detailed audit — package, status truth, and release engineering

### PKG-N01 — package structure is fixed, but clean-resolution evidence is not yet produced

**Severity:** P1 until CI proves it  
**Evidence:** root manifest uses `Packages/CodeEditorGrammars`; `dump-package` succeeds; external dependency resolution was unavailable in the audit environment.

**Required implementation**

- Add a CI job that starts with an empty `HOME`, empty SwiftPM caches, and the exported release archive—not a checkout with developer caches.
- Resolve and build every public product in both debug and release.
- Build the two executable products and run `--version` plus meaningful commands.
- Validate local grammar package licenses, checksums, generated source provenance, and pin update reproducibility.
- Store dependency graph and package fingerprints as release artifacts.

**Acceptance criteria**

```text
fresh archive → swift package resolve → all product builds → all tests
```

must succeed without pre-running a bootstrap that changes the source tree.

### REL-N01 — README and compatibility profile conflict

**Severity:** P1 release-truth defect  
**Evidence:** `README.md` accurately says pre-alpha/experimental. `Docs/Architecture/CompatibilityProfile.toml` says `status = "phase-16-rc"`, marks many extension features/runtimes stable, and declares S0–S4 passing.

**Risk**

Downstream users and maintainers can select whichever document supports the desired claim. A release gate must have one source of truth.

**Required implementation**

- Change the compatibility profile to actual current statuses.
- Split **schema support**, **source compatibility**, **behavioral conformance**, **security qualification**, and **operational qualification** into separate fields.
- Generate the profile from CI results; do not author `passing` manually.
- Include exact artifact IDs, commit, toolchain, and test suite version.

### REL-N02 — product scorecards can pass while every dimension fails

**Severity:** P0 release-certification defect  
**Evidence:** `check-product-scorecards.sh` accepts `pass|partial|fail` for every dimension and only requires `residual = []`. It covers 26 products, omitting `codeeditor-extension`, `ConformanceExtensionGuest`, and `CodeEditorTerminalGhostty`.

**Required implementation**

Replace the current checker with generated product evidence:

```toml
[[product]]
name = "CodeEditorDocuments"
commit = "..."
api = { status = "pass", artifact = "symbolgraph-diff.json" }
correctness = { status = "pass", tests = 184, skipped = 0 }
concurrency = { status = "pass", swift6_errors = 0, tsan_failures = 0 }
platform = { status = "pass", macos15 = "job/...", ios18 = "job/..." }
operations = { status = "pass", fault_suite = "artifact/..." }
open_p0 = 0
open_p1 = 0
```

The release check must reject `partial`/`fail`, missing artifacts, skipped required suites, and omitted public products.

### REL-N03 — defect gate trusts manually marked “fixed” rows

**Severity:** P0  
**Evidence:** `check-defects.sh` reports no P0/P1 because the authored register says all are fixed, despite reproducible source defects documented here.

**Required implementation**

- Every defect closure must name one or more regression test IDs.
- CI must verify those tests exist and pass.
- Reopen a defect automatically if the test disappears, is skipped, or its production path is no longer exercised.
- Store defects in one structured source; generate Markdown from it.

### REL-N04 — accessibility gate is a source-token check

**Severity:** P1  
**Evidence:** the script checks for a file, `accessibilityIdentifier`, and reduce-motion tokens.

**Required implementation**

- XCUI tests using VoiceOver-relevant accessibility hierarchy.
- keyboard-only navigation across navigator/editor/inspectors/panels.
- rotor actions for errors, symbols, folds, breakpoints, and search results.
- high contrast, Dynamic Type where applicable, reduced motion, full keyboard access, Switch Control, and focus restoration.
- manual sign-off protocol for IME and screen reader scenarios that automation cannot reliably cover.

### REL-N05 — performance gate validates a document and one loose sample

**Severity:** P1  
**Required implementation**

- benchmark executables with fixed datasets and reference hardware metadata
- per-commit smoke budgets and nightly stress budgets
- regression comparison against a rolling baseline
- p50/p95/p99 latency, memory peak, allocation count, CPU, and dropped-event metrics
- hard failures for missing measurements

### REL-N06 — API freeze is not semantic API validation

**Severity:** P1  
**Evidence:** current scripts primarily extract public symbol names and cover only a subset of products.

**Required implementation**

Use Swift symbol graphs/API digester for all public libraries, including:

- declarations and signatures
- generic constraints
- conformances
- availability
- actor/global-actor isolation
- `Sendable`
- default argument source compatibility
- enum exhaustivity/frozen state
- SPI versus public exposure

### REL-N07 — strict concurrency is not warnings-as-errors

**Severity:** P1  
**Evidence:** CI comments defer warnings-as-errors; 103 `@unchecked Sendable` sites are accepted by allowlist.

**Required implementation**

- Swift 6 language mode and `-strict-concurrency=complete` with warnings as errors.
- per-site unsafe-concurrency dossier: invariant, owner, synchronization primitive, stress test, removal path.
- ratchet the unchecked count downward; no new site without approval.
- Thread Sanitizer jobs that execute tests, not only compile one target.

### REL-N08 — optional production integrations are allowed to fail

**Severity:** P0 for Ghostty, P1 for LSP/DAP  
**Evidence:** Ghostty build is `continue-on-error`; “real LSP” can be only `sourcekit-lsp --help`; DAP scripts tolerate no adapter response.

**Required implementation**

- required linked-Ghostty build/test job for release branches
- real `sourcekit-lsp` and `clangd` initialize/open/change/completion/diagnostic/shutdown sessions
- real `lldb-dap` initialize/launch/breakpoint/stack/variables/evaluate/disconnect session
- hard failure when the tool is absent in the release image

---

## 6. Detailed audit — CodeEditorCore and CodeEditorDocuments

### DOC-N01 — saved-version dirty tracking is logically impossible after undo

**Severity:** P0 data-integrity/user-trust defect  
**Evidence:** `TextDocument.savedVersion` stores the version at save; every apply, including undo, creates a newer monotonic version; `recomputeDirtyFromSavedVersion()` checks `store.version != savedVersion`.

After saving at version 10, editing creates version 11, and undo creates version 12. Even if content exactly equals saved content, version 12 can never equal 10.

**Required architecture**

Track a **content state identity**, not a monotonic event generation:

```swift
public struct DocumentContentStateID: Hashable, Sendable, Codable {
    public let rawValue: UUID
}

public struct AppliedEditTransaction: Sendable {
    public let beforeState: DocumentContentStateID
    public let afterState: DocumentContentStateID
    public let beforeVersion: DocumentVersion
    public let afterVersion: DocumentVersion
    // edits...
}
```

Undo restores the prior `DocumentContentStateID`; redo restores the forward ID. A save records:

```swift
struct DocumentSavepoint: Sendable {
    let contentState: DocumentContentStateID
    let fileIdentity: DocumentFileIdentity?
    let encoding: DocumentEncoding
    let lineEnding: LineEnding
}
```

`isDirty` is `currentContentState != savepoint.contentState`. The monotonic `DocumentVersion` remains for synchronization ordering.

**Acceptance criteria**

- edit → undo to savepoint becomes clean
- redo becomes dirty
- save after undo moves the savepoint correctly
- multi-session edits preserve monotonic versions while sharing one content state
- external reload establishes a new clean state
- save conflict does not move the savepoint
- a failed save does not become clean

### DOC-N02 — normal save bypasses conflict-aware save

**Severity:** P0 potential overwrite  
**Evidence:** `TextDocument.save(using:to:io:)` calls the simple provider `save`; `LocalFileDocumentProvider.save` bridges to `expectedIdentity: nil` and `.overwrite`; the protocol’s default conflict-aware implementation ignores `expectedIdentity` and `policy`.

**Required implementation**

Make one save API authoritative:

```swift
public protocol DocumentContentProvider: Sendable {
    func load(uri: DocumentURI) async throws -> LoadedDocument
    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveOutcome
}

public struct DocumentSaveRequest: Sendable {
    let snapshot: DocumentSnapshot
    let target: DocumentURI
    let encoding: DocumentEncoding
    let expectedIdentity: DocumentFileIdentity?
    let conflictPolicy: SaveConflictPolicy
    let durability: SaveDurability
}
```

Remove the unsafe default bridge. A provider must explicitly declare whether it can implement identity comparison. Local files should default to `requireHostDecision`, not overwrite.

**Acceptance criteria**

- modifying a file externally between load and save returns a conflict
- Save, Save All, close-with-save, workspace refactor, SCM discard, and extension edits all use the same conflict path
- overwrite requires an explicit host decision/auditable action
- providers without identity support return `.unsupportedConflictDetection`, not silent success

### DOC-N03 — equal-offset insertion contract is internally contradictory

**Severity:** P1 correctness/API contract  
**Evidence:** `DocumentStore.apply` sorts equal-offset insertions by original index ascending, then applies each at the same offset. The second insertion appears before the first. The test accepts either result temporarily, then pins `a21b`, while comments/docstrings claim declaration order.

**Required decision**

Choose and document one semantic:

- **Declaration-order visible output:** for equal offset, apply source order in reverse, or group replacement strings before one mutation.
- **Editor-order output:** define ordering by selection identity/caret order and pin it.

Recommended: sort selections by stable selection ID and concatenate equal-position insertions so visible output matches declared transaction order.

**Acceptance criteria**

- one deterministic result only
- property tests across 2–100 carets at same/different offsets
- undo restores the original text in one transaction
- redo reproduces exact order
- LSP synchronization receives the same final text

### DOC-N04 — public per-edit undo convenience can partially mutate external state

**Severity:** P1  
**Evidence:** `UndoCoordinator.undo(apply:)` loops over edits. If a later callback throws, prior callback effects cannot be rolled back, while the coordinator correctly leaves its stacks unchanged.

**Required implementation**

- remove or deprecate the per-edit callback from public API
- expose only atomic grouped transaction callbacks
- alternatively require a reversible transaction protocol with prepare/commit/rollback

### DOC-N05 — UTF-16 range arithmetic can overflow

**Severity:** P1 for untrusted protocol/extension inputs  
**Required implementation**

Use overflow-safe checks:

```swift
guard location >= 0, length >= 0 else { throw ... }
let (end, overflow) = location.addingReportingOverflow(length)
guard !overflow, end <= documentLength else { throw ... }
```

Apply the same rule to NSRange/offset arithmetic across editor, LSP, DAP, search, tasks, and extension wire payloads.

### DOC-N06 — `bufferSize <= 0` creates an unbounded event stream

**Severity:** P1 operational risk  
**Evidence:** `TextDocument.makeEventStream` maps nonpositive buffer sizes to `.unbounded`.

**Required implementation**

- remove unbounded public behavior
- use a validated `EventBufferPolicy` with a finite maximum
- every event carries sequence/version
- on drop, publish a gap marker or require a fresh snapshot
- expose drop metrics

### DOC-N07 — document encoding fallback contradicts its contract

**Severity:** P2  
**Finding:** `.other` encoding behavior silently falls back/aliases where documentation implies unsupported behavior.

**Required implementation**

Represent encoding with a validated identifier and return a typed unsupported-encoding error. Never silently change the encoding of user data.

### DOC-N08 — conflict check still has a time-of-check/time-of-use window

**Severity:** P1 for local concurrent writers  
**Finding:** identity is checked twice, then a separate replacement occurs.

**Required implementation**

Where the platform permits, coordinate/open the target and compare identity under the same coordinated write. At minimum:

- `NSFileCoordinator` for user-visible local files
- file descriptor identity check immediately before rename
- directory/file descriptor–relative operations
- after-write identity verification
- surface unavoidable external-race semantics explicitly

### DOC-N09 — local read path still doubles peak memory

**Severity:** P2 performance  
**Evidence:** read chunks are retained in an array and then combined into a second `Data`; `resourceIdentity` calls the same content-reading routine even when only a hash is needed.

**Required implementation**

- preallocate a single `Data` when metadata size is known and capped
- or stream into the text decoder/text storage
- provide a hash-only identity path
- large files should open a viewport before full syntax/indexing

### DOC-N10 — durable write omits parent-directory durability and rich metadata

**Severity:** P1 for the “durable” claim  

**Required implementation**

- fsync/fdatasync temporary content
- atomic replace/rename
- fsync parent directory
- preserve/define behavior for permissions, ACLs, extended attributes, ownership, quarantine, resource forks, and symlinks
- never follow symlinks unintentionally
- fault-inject every stage and reboot/restart after each injected point

### DOC-N11 — recovery is a sidecar snapshot, not a durable journal

**Severity:** P1  
**Findings**

- synchronous quota scans occur in async paths
- quarantine/cleanup errors are suppressed
- `createdAt` semantics are unstable
- directory durability is not guaranteed
- the design does not record a sequence of transactions or a committed savepoint

**Required implementation**

Use a versioned recovery record:

```text
header: schema, document ID, URI, base file identity, content state, encoding
payload: compressed snapshot or bounded edit log
footer: SHA-256/MAC, byte count
write: temp → fsync → rename → fsync directory
```

Recovery discovery must be deterministic, bounded, corrupt-record tolerant, and covered by restart tests.

### CORE-N01 — `DocumentStore` main-thread ownership is convention, not enforced architecture

**Severity:** P1 concurrency  

Decide one model:

- `@MainActor` document mutation, with background immutable snapshots; or
- dedicated `DocumentActor`, with UI applying versioned snapshots.

Do not leave mutable text storage nominally Sendable through conventions. For Xcode-class performance, a dedicated document actor plus immutable viewport/layout snapshots is the preferred long-term model.

### CORE-N02 — process event stream is single-consumer and unbounded

**Severity:** P0 cross-cutting substrate  

`ProcessHandle.events` is used as if the waiter, output collector, problem matcher, readiness detector, terminal, and caller can independently observe all events. They cannot safely share one `AsyncStream` iterator contract.

Implement the broadcast substrate specified in Section 18 before building more task/LSP/DAP/terminal behavior.

### CORE-N03 — process cancellation can synchronously block the caller

**Severity:** P1  

`ProcessHandle.cancel()` waits for process termination. Called from an actor or main actor, this can stall unrelated work.

**Required implementation**

- `cancel()` requests cancellation and returns
- `awaitTermination()` is separate
- escalation runs in a supervisor actor/task
- process group is established atomically at spawn time
- all readers close on termination
- output buffers are bounded and independently subscribed

### CORE-N04 — shell execution is an explicit high-trust capability

**Severity:** P1 security/API  

Any `/bin/sh -c` path must be named and permissioned as shell execution, not generic process launch. Extension/task APIs should prefer executable + argv and require a separate capability/user confirmation for shell commands.

---

## 7. Detailed audit — CodeEditorWorkspace

### WSP-N01 — workspace rollback is not a coherent transaction

**Severity:** P0  
**Affected area:** `WorkspaceEdit.swift`, workspace filesystem operations, document registry/undo integration

The implementation has more preflight/capture/journal structure than the previous snapshot, but the transaction model remains internally inconsistent:

- resource capture restoration and inverse operations can both attempt to restore the same path
- a forward document edit may register undo history before a later operation fails; rollback changes content but does not remove the forward history entry
- rollback errors can replace or obscure the original failure
- cleanup errors are commonly suppressed
- a deleted directory’s simple inverse may recreate only an empty directory while capture restoration separately attempts archive restore
- disk identity preflight can rely on a cached document identity instead of a fresh filesystem identity
- duplicate targets are not always compared by canonical resource identity
- preflight and commit are separated by an unavoidable race without a coherent conflict/revalidation model

**Required architecture: typed two-phase transaction**

```swift
public actor WorkspaceTransactionCoordinator {
    func prepare(_ request: WorkspaceTransactionRequest) async throws -> PreparedWorkspaceTransaction
    func commit(_ prepared: PreparedWorkspaceTransaction) async throws -> WorkspaceTransactionReceipt
    func recoverPendingTransactions() async throws
}
```

A prepared transaction must contain:

- canonical operation graph
- all affected document IDs/URIs and expected content states
- all affected filesystem objects and expected identities
- conflict decisions
- exact rollback materials
- an undo checkpoint per document
- a durable transaction ID and journal location

The journal state machine should be explicit:

```text
preparing → prepared → committing → committed
                     ↘ rollingBack → rolledBack
                                  ↘ recoveryRequired
```

Only one rollback mechanism should own each resource. Do not combine independent “capture restore” and “inverse operation” paths without ownership metadata.

**Acceptance criteria**

- injected failure before/after every operation leaves documents, filesystem, undo stacks, and registry consistent
- killing the process after every durable state boundary recovers deterministically on next launch
- original error and rollback error are both preserved
- a failed transaction creates no user-visible undo entry
- a committed multi-file refactor is one undoable workspace transaction
- conflicts are detected using live identities immediately before commit

### WSP-N02 — file deletion can race dirty/open document lifecycle

**Severity:** P0 data-loss risk

The navigator/workspace delete path can remove an item from disk and then close/discard the corresponding document. A dirty buffer must be resolved before destructive filesystem mutation.

**Required implementation**

1. Discover all open documents and views under the target path.
2. Resolve save/discard/cancel for every dirty document.
3. Abort the entire delete if any item cancels or save conflicts.
4. Move the resource to a recoverable workspace trash/staging area.
5. update registry, tabs, watchers, and indexes.
6. commit/delete staging only after the transaction is durable.

For directories, dirty descendants must be included.

### WSP-N03 — bulk close can partially save before a later cancellation

**Severity:** P1

Sequentially asking and saving each tab means a later Cancel can leave earlier documents saved and tabs still open. That behavior may be acceptable only if explicitly specified; it is not an atomic “Close All” transaction.

**Required implementation**

Split bulk close into:

- **decision phase:** gather save/discard/cancel decisions for every dirty document
- **save phase:** perform conflict-aware saves and collect failures
- **commit phase:** close tabs/panes only when policy permits

The host should be able to choose either “best effort” or “all-or-nothing,” but the default must be explicit and testable.

### WSP-N04 — local filesystem actor executes blocking traversal and mutation

**Severity:** P1 responsiveness

`FileManager` enumeration, copying, moving, deleting, and archiving are synchronous. Running them inside an actor does not make them nonblocking; it monopolizes that actor’s executor and may inherit main-actor work through callers.

**Required implementation**

- isolate blocking filesystem work in bounded worker tasks
- maintain cancellation checkpoints
- stream directory entries in batches
- cap depth, file count, bytes, and elapsed time
- publish progress through a multicast event hub
- keep model mutation actor-isolated after each batch

### WSP-N05 — directory archive is not byte/metadata exact

**Severity:** P0 for rollback claim, P2 if the claim is removed

A Stable transaction archive must define behavior for:

- regular files and directories
- symlinks without following them
- hard links
- sparse files
- executable and POSIX permissions
- ACLs and extended attributes
- ownership where permitted
- timestamps
- Unicode/path normalization
- resource forks on Apple filesystems
- large files without whole-memory buffering
- truncation/corruption during restore

Use a proven archive/container format or a typed CodeEditor journal format with bounded streaming. Do not label an ad hoc length-prefixed archive “byte exact” until the full matrix passes.

### WSP-N06 — journal has no complete startup recovery contract

**Severity:** P0

Writing a transaction description is not sufficient. Stable requires:

- discovery of unfinished journals before workspace activation
- schema/version validation
- checksum verification
- safe path validation relative to known roots
- deterministic resume or rollback policy
- user-visible recovery result
- quarantine for corrupt/untrusted journals
- cleanup after parent-directory fsync

### WSP-N07 — workspace event stream can miss startup events

**Severity:** P1

Observer registration performed in an unstructured task can occur after an early filesystem event. An unbounded stream also has no backpressure contract.

**Required implementation**

Every workspace subscription starts with an authoritative snapshot and sequence number:

```swift
struct WorkspaceEventEnvelope<Event>: Sendable {
    let sequence: UInt64
    let event: Event
}

enum WorkspaceStreamItem<Event> {
    case snapshot(WorkspaceSnapshot, sequence: UInt64)
    case event(WorkspaceEventEnvelope<Event>)
    case gap(expected: UInt64, actual: UInt64)
}
```

### WSP-N08 — symlink containment remains time-of-check/time-of-use sensitive

**Severity:** P1 security

`resolvingSymlinksInPath` followed by a later path operation is not a security boundary when an attacker can replace path components.

**Required implementation**

For extension/workspace security boundaries use directory file descriptors and `openat`/`fstatat`/`renameat`/`unlinkat` with no-follow semantics where available. For normal trusted workspace operations, document the weaker model but still revalidate immediately before mutation.

### WSP-N09 — hidden-file policy is hardcoded

**Severity:** P2

The navigator and search/index layers need one host policy for hidden files, packages, generated folders, ignored files, and explicit reveals. Hardcoded `.skipsHiddenFiles` breaks `.gitignore` discovery and prevents users from editing common project files.

### WSP-N10 — registry mutation bypasses higher-level ownership

**Severity:** P1

Direct document-registry removal can bypass tab leases, dirty handling, LSP close notifications, syntax services, recovery, and restoration state.

**Required implementation**

Only a central `DocumentLifecycleCoordinator` may open, move, rename, close, or remove a document. Workspace, workbench, SCM, search replacement, and extensions call that coordinator.

---

## 8. Detailed audit — CodeEditorCommands and CodeEditorWorkbench

### CMD-N01 — public soft registration silently replaces commands

**Severity:** P1 API correctness

A strict duplicate API exists, but a public convenience still suppresses registration errors and can replace an existing command. Extension/host command ownership cannot be reliable under silent replacement.

**Required implementation**

Use one explicit policy:

```swift
public enum CommandRegistrationPolicy: Sendable {
    case rejectDuplicate
    case replaceOwnedRegistration(expectedToken: CommandRegistrationToken.ID)
}
```

Default to `rejectDuplicate`. Replacement must prove ownership and emit diagnostics.

### CMD-N02 — `CommandID` validation and documentation disagree

**Severity:** P2

If IDs are documented as lowercase, reject uppercase. Recommended grammar:

```text
^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$
```

Add maximum length and reserve host namespaces.

### CMD-N03 — token deinit unregisters through an unstructured task

**Severity:** P1 lifecycle nondeterminism

Cleanup triggered by `deinit` and scheduled onto the main actor has indeterminate timing. Stable APIs should require explicit disposal and let deinit be a debug assertion/fallback only.

### CMD-N04 — chord timeout executes with stale context and hides errors

**Severity:** P1

A command executed after the ambiguity timeout may use context captured before focus, selection, editor, trust, or enablement changed. `try?` suppresses execution failures.

**Required implementation**

At timeout:

- re-resolve active context
- re-evaluate `when`/enablement predicates
- ensure the same focus scope still owns the chord
- execute through the normal command pipeline
- surface failure to diagnostics/UI
- cancel pending chord when focus/window/workspace changes

### CMD-N05 — synchronous handlers can block the main actor

**Severity:** P1

Commands should declare execution class:

```swift
enum CommandExecutionClass {
    case immediateUI
    case asynchronous
    case transactionalWorkspace
    case longRunningCancellable
}
```

Long-running work must not execute synchronously on the main actor.

### WB-N01 — contribution “fault isolation” is not isolation

**Severity:** P0 if presented as security/crash isolation; P2 if renamed to error presentation

`makeBodyIsolated` can display a fallback for an ordinary error state. It cannot contain:

- a Swift crash or `fatalError`
- an infinite loop/main-thread stall
- memory exhaustion
- arbitrary filesystem/network access
- AppKit/UIKit misuse
- process termination

**Required implementation**

- Data-only contributions may render through host-owned views.
- Untrusted procedural extensions must return declarative view models, commands, or data over the capability boundary.
- Trusted built-in Swift contributions may create native views, but documentation must say they are in-process and not isolated.
- Remove “fault isolation” wording from the in-process wrapper.

### WB-N02 — fabricated navigation offsets remain

**Severity:** P1

Mapping a source selection to scroll position with a formula such as `selection.location / 40` is not layout/navigation behavior.

**Required implementation**

Editor navigation must call a layout service:

```swift
await editor.reveal(
    range: range,
    alignment: .centerIfOutsideViewport,
    selectionPolicy: .select,
    animation: .respectReduceMotion
)
```

The layout engine resolves actual wrapped visual lines and folds.

### WB-N03 — no-op animation wrapper is fake behavior

**Severity:** P2

Either implement platform/reduce-motion-aware animation or remove the API and claim. No-op wrappers create tests that pass without user-visible behavior.

### WB-N04 — file-tree indexing can freeze the main actor

**Severity:** P1

Recursively expanding tens of thousands of files and mutating model state on the main actor is not acceptable.

**Required implementation**

- background index actor
- lazy expansion by directory
- diffable immutable node snapshots
- watcher-driven incremental updates
- cancellation when workspace changes
- bounded result batches to the UI

### WB-N05 — unstructured tasks can outlive models/windows

**Severity:** P1

Workbench models launch many `Task {}` blocks without a common owner. Add `TaskBag`/lifecycle scope per window, pane, tab, panel, and contribution; cancel on deactivation/deinit and await critical shutdown.

### WB-N06 — models exist without end-to-end workflows

**Severity:** P1/P2 by feature

Problems, source control, debug, test, terminal, schemes, and navigator models provide useful scaffolding, but Stable requires each advertised workflow to run through production services with restoration, cancellation, progress, error UI, accessibility, and tests.

### WB-N07 — Xcode-class workbench gaps

The final goal still lacks complete product-level implementations for:

- project/build graph and target model
- schemes, configurations, destinations, and environment overrides
- structured build logs and result bundles
- test plans, test navigator, rerun failures, coverage navigation
- diff/merge/conflict editor
- breakpoint navigator and breakpoint conditions/actions
- variables, watch expressions, memory view, debugger console, source mapping
- preview/canvas/plugin-provided preview providers
- package/dependency navigator
- inspectors and settings editors
- source control branches/remotes/auth/conflict resolution
- multi-window restoration and state migration
- source navigation history, symbol/call/type hierarchy
- find navigator replacement preview and conflict handling
- profiling/instrumentation hooks
- device/simulator/destination abstraction
- signing/capability/provisioning integrations where a host app elects to provide them

These should be treated as a versioned roadmap. Stable 1.0 needs a clearly bounded subset; documentation must not imply all of Xcode is already represented.

---

## 9. Detailed audit — native editor UI (`CodeEditorView`)

### UI-N01 — UIKit vertical movement is raw UTF-16 arithmetic

**Severity:** P1 native input correctness

Moving up/down by adding an offset to a UTF-16 position does not preserve visual column, wrapping, folds, variable-width glyphs, tabs, or bidirectional runs. It can also land inside a scalar/grapheme boundary.

**Required implementation**

Create a platform-neutral `CaretNavigationEngine` driven by immutable layout snapshots:

```swift
func move(
    caret: TextPosition,
    direction: VisualDirection,
    preferredX: CGFloat?,
    layout: EditorLayoutSnapshot
) -> CaretMovementResult
```

UIKit/AppKit adapters translate native commands to this engine.

### UI-N02 — generic offset clamping can return invalid insertion points

**Severity:** P1

All `UITextPosition` and `UITextRange` creation must validate grapheme/scalar boundaries. Never clamp to an arbitrary UTF-16 unit.

### UI-N03 — selection rectangle generation is O(selection UTF-16 length)

**Severity:** P1 performance

Walking every UTF-16 position in a large selection can freeze the UI and still produces incorrect geometry for wrapped and BiDi text.

**Required implementation**

- intersect selection with visible layout fragments
- produce one rect per visual fragment/run, not per code unit
- virtualize offscreen selections
- support discontiguous/multi-cursor selections
- preserve directionality and writing mode

### UI-N04 — BiDi behavior is heuristic/incomplete

**Severity:** P1

Stable needs the Unicode Bidirectional Algorithm behavior supplied by the platform text stack/layout engine, not a first-character direction heuristic. `setBaseWritingDirection` cannot be a no-op.

Test Arabic/Hebrew mixed with Latin, numbers, punctuation, code indentation, selections, and caret affinity.

### UI-N05 — first-rect/attributed-substring contracts are incomplete

**Severity:** P1

Native input clients expect accurate ranges and geometry for IME candidate windows, dictation, writing tools, accessibility, and services. Validate requested ranges and return actual ranges consistent with the returned content.

### UI-N06 — IME conformance is not complete

**Severity:** P1

Required matrix:

- Simplified/Traditional Chinese Pinyin and handwriting
- Japanese Kana/Romaji conversion
- Korean 2-set composition
- marked-text sub-selection
- reconversion and replacement range
- emoji, ZWJ sequences, flags, skin tones
- combining marks and Indic scripts
- dictation and autocorrection where enabled
- external keyboard dead keys
- undo grouping across composition commit/cancel

### UI-N07 — AppKit/UIKit error paths are frequently suppressed

**Severity:** P1

Input/action failures hidden by `try?` can desynchronize native selection and the document. Route errors to a centralized editor diagnostic channel, fail the operation atomically, and restore a coherent selection snapshot.

### UI-N08 — platform build/runtime evidence is incomplete

**Severity:** P1

Stable requires real Xcode builds and UI tests on:

- oldest supported macOS 15 runtime
- latest supported macOS runtime with Xcode 26 toolchain
- iOS 18 simulator/device class
- latest iOS simulator/device class
- Intel support only if promised; otherwise document Apple silicon-only test policy

### UI-N09 — large-file architecture needs an explicit mode

**Severity:** P1 for Xcode-class claim

Define thresholds and behavior:

- initial viewport without full file materialization where feasible
- delayed/disabled syntax, minimap, folding, semantic tokens, and diagnostics based on policy
- line index and layout virtualization
- bounded undo
- memory-pressure response
- visible “large file mode” limitations rather than silent degradation

### UI-N10 — accessibility must be semantic, not identifier-only

**Severity:** P1

The editor should expose:

- current line/column/selection summary
- text editing semantics compatible with platform accessibility
- rotor/navigation for diagnostics, folds, changes, breakpoints, symbols, and search matches
- multi-cursor announcement and control
- code completion accessibility
- panel/focus landmarks
- reduced-motion-safe transitions

---

## 10. Detailed audit — language support and Tree-sitter

### LANG-N01 — duplicate language registration overwrites ownership

**Severity:** P1 extension correctness

A registry entry needs owner, priority, generation, and registration token. Unregistering one extension must not remove another extension’s replacement.

Recommended entry:

```swift
struct LanguageRegistrationRecord: Sendable {
    let languageID: LanguageID
    let owner: ContributionOwner
    let generation: UInt64
    let priority: Int
    let descriptor: LanguageDescriptor
}
```

### LANG-N02 — malformed queries can be silently omitted

**Severity:** P1

Missing optional features may be allowed, but a present malformed query must produce a typed package/contribution error with file and query diagnostics. Avoid `try?` for query compilation.

### LANG-N03 — dual parser/tree state paths can diverge

**Severity:** P1

Use one actor-owned parse state per `(documentID, languageGeneration)`:

```swift
actor ParseSession {
    var documentVersion: DocumentVersion
    var tree: Tree?
    var parser: Parser
    func apply(_ transaction: AppliedEditTransaction, snapshot: DocumentSnapshot) async throws
}
```

The UI consumes immutable highlight/fold/symbol snapshots tagged with document version. Stale results are discarded.

### LANG-N04 — parser/language pointer lifetime is unclear

**Severity:** P1 memory safety

Document who owns every `OpaquePointer`, ensure grammars outlive parsers/trees/queries, and add deallocation stress tests. Prefer wrapper types that cannot be copied across actors unsafely.

### LANG-N05 — Tree-sitter direct test ownership is inadequate

**Severity:** P1

The product needs its own tests for:

- incremental edits before/inside/after multibyte scalars
- error recovery and malformed source
- cancellation/stale generation discard
- query capture validation
- all supported query categories
- grammar unload/reload and duplicate registration
- large files and repeated edits
- memory leak/ownership stress

### LANG-N06 — language packs need generated conformance fixtures

**Severity:** P1 before Stable

For all 39 grammars, generate a matrix covering:

- parser loads
- representative source parses
- highlight query compiles and captures expected scopes
- indentation/fold/injection/textobject queries compile when shipped
- malformed fixture does not crash
- license/provenance/pin metadata is present
- SwiftPM clean build works independently

### LANG-N07 — global bootstrap side effects are not ideal Stable API

**Severity:** P2

Prefer explicit registry instances/configuration owned by the host. Global static registration complicates tests, multiple workspaces, unloading, extension generations, and deterministic startup.

---

## 11. Detailed audit — search and replace

### SRCH-N01 — nested `.gitignore` files are skipped

**Severity:** P1 correctness

The directory enumerator skips hidden files; `.gitignore` itself is hidden. Nested ignore rules therefore cannot be discovered reliably.

### SRCH-N02 — gitignore semantics are only partial

**Severity:** P1 for “gitignore-compatible” claim

Missing/incomplete behavior includes escaped `#`/`!`, trailing-space rules, leading slash anchoring, directory-only rules, negation under ignored parents, character classes, and precise `**` semantics.

**Required implementation**

Adopt a proven implementation or implement against Git’s documented corpus. Build a fixture repository and compare results with `git check-ignore -v`.

### SRCH-N03 — workspace glob matching is ad hoc

**Severity:** P1

Define a separate glob grammar for include/exclude filters. Do not conflate it with gitignore. Support anchoring, separators, `?`, classes, braces only if explicitly promised, and platform case-sensitivity policy.

### SRCH-N04 — search performs blocking traversal/regex work on one actor

**Severity:** P1 responsiveness

Use a bounded worker pool with cancellation, byte/file/time limits, ordered result aggregation, and independent subscriptions.

### SRCH-N05 — UTF-8-only search silently excludes files

**Severity:** P2

Integrate the document codec/encoding policy. At minimum report skipped files and reason; do not silently treat them as no match.

### SRCH-N06 — regular expression evaluation is unbounded

**Severity:** P1 denial-of-service/performance

Use per-file cancellation/time budgets, result limits, input-size limits, and a regex policy. Materializing all matches in one call is unsafe for very large files.

### SRCH-N07 — completion metrics are incorrect

**Severity:** P2

`filesScanned` must count scanned files, not files with matches. Define counters precisely: discovered, eligible, opened, decoded, scanned, matched, skipped, failed, cancelled.

### SRCH-N08 — regex replacement is fake/incomplete

**Severity:** P1

Only `$0` replacement is implemented. Stable regex replacement needs numbered captures, named captures where supported, escaping, zero-length match progress, case conversion only if documented, and the exact regex result ranges used during preview.

Do not perform a second “find matching text” fallback that can replace the wrong occurrence.

### SRCH-N09 — replace transaction inherits workspace transaction defects

**Severity:** P0 for multi-file replacement

Preview must pin document content states/file identities. Commit must either apply exactly to those states or present conflicts/rebase. Partial replacement followed by failed rollback is unacceptable.

---

## 12. Detailed audit — tasks and problem matching

### TASK-N01 — task events are not multicast

**Severity:** P0

A single `TaskExecutionHandle.events` stream is observed by the internal process pump, readiness matcher, problem matcher, caller/tests, and potentially UI. Multiple iterators can divide events rather than each receiving every event.

**Required implementation**

Use the shared `AsyncBroadcastHub` design in Section 18. Each consumer gets an independent bounded subscription and sequence numbers.

### TASK-N02 — chunk-local UTF-8 decoding corrupts output

**Severity:** P1

A multibyte scalar split across reads must be held until complete. Maintain independent incremental decoders for stdout and stderr. Preserve raw bytes for terminal/binary consumers.

### TASK-N03 — `.bufferingNewest` silently drops task output

**Severity:** P1

For terminal/log output, dropping arbitrary chunks changes meaning. Apply bounded spooling:

- raw byte ring or temporary file
- sequence ranges
- UI viewport reads
- explicit truncation marker once
- drop/truncate metrics

### TASK-N04 — output accumulation is unbounded

**Severity:** P1

Do not retain full stdout/stderr strings for long builds. Persist bounded log segments and indexes; let UI lazily load.

### TASK-N05 — invalid readiness regex disables behavior silently

**Severity:** P1

Validate task definitions before launch. Return a source-located configuration error.

### TASK-N06 — dependency/exclusive-group failures are suppressed

**Severity:** P1

Define task graph outcomes:

```swift
enum TaskNodeOutcome {
    case succeeded
    case failed(TaskFailure)
    case cancelled
    case skippedBecauseDependency(TaskID)
}
```

A dependent cannot launch merely because waiting returned.

### TASK-N07 — problem source paths/ranges remain weak

**Severity:** P1

Carry line/column as line/column until resolved against the exact document snapshot. Normalize paths using workspace roots and canonical components, never weak string-prefix fallback.

### TASK-N08 — task/output channels lack finish ownership

**Severity:** P1

Every producer owns completion exactly once. Subscriptions finish on process exit/cancel/failure. No orphan continuation remains after task/service/window teardown.

---

## 13. Detailed audit — source control

### SCM-N01 — provider identity collides across repositories

**Severity:** P1

A constant provider ID such as `git` cannot distinguish multiple roots. Use a stable repository identity derived from canonical root/resource ID, not only path text.

### SCM-N02 — auth callback is not wired

**Severity:** P1 feature-contract mismatch

The Git subprocess disables terminal prompting, while the advertised auth callback does not participate. Either implement a credential broker/keychain/askpass flow or remove the API from Stable scope.

### SCM-N03 — progress events are not a real path

**Severity:** P2

Long operations need parsed progress, cancellation, and one operation coordinator per repository.

### SCM-N04 — status model cannot represent staged and unstaged state simultaneously

**Severity:** P1

A file can have separate index and worktree statuses. Model both, plus unmerged/conflict stages, rename/copy source/destination, submodule state, intent-to-add, ignored/untracked policy.

### SCM-N05 — repository mutations are not serialized

**Severity:** P1

Stage/unstage/commit/checkout/branch/pull operations can race on the index and working tree. Use a per-repository actor with operation categories and cancellation policy.

### SCM-N06 — destructive Git operations ignore dirty editor buffers

**Severity:** P0 data-loss risk

Discard, checkout, reset, pull/merge, switch branch, and rebase must coordinate open documents through `DocumentLifecycleCoordinator` and file identities. Never let Git replace a path while a dirty buffer remains unresolved.

### SCM-N07 — hunk patch generation is incomplete

**Severity:** P1

The implementation needs Git quoting, no-newline markers, binary/rename/mode metadata, correct context and line offsets, and `git apply --check` before mutation. Prefer asking Git to generate/apply patches rather than reconstructing all edge cases manually.

### SCM-N08 — status stream is not lifecycle-safe

**Severity:** P1

Use multicast snapshots/events, finish on provider removal, and watcher-driven refresh with debounce and explicit stale state.

### SCM-N09 — process output is unbounded

**Severity:** P1

SCM must use the shared process supervisor and bounded output capture, with sanitized logs that do not expose credentials.

---

## 14. Detailed audit — LSP

### LSP-N01 — request registration still races timeout/cancellation

**Severity:** P0 protocol/lifecycle

`LSPJSONRPCConnection.requestRaw` races two child tasks: one calls `executeRegisteredRequest`, and another sleeps for the timeout. `executeRegisteredRequest` creates a continuation and then starts another unstructured `Task` to run `registerThenSend`.

The comment says “register before send,” which is true inside `registerThenSend`, but it does not guarantee registration before the timeout/cancellation path runs. A sufficiently short timeout or cancelled parent can call `failPending` before the child installs the continuation. The child can then install pending state and send an orphaned request.

The bounded `earlyResponses` map does not fix this lifecycle; IDs are monotonically increasing and generally will not be reused, so retaining late/early responses is usually a leak or misleading recovery mechanism.

**Required shared RPC architecture**

Do not register continuations through unstructured tasks. Use a one-shot request promise that safely handles completion-before-wait:

```swift
actor RequestPromise<Value: Sendable> {
    private enum State {
        case waiting([CheckedContinuation<Value, Error>])
        case completed(Result<Value, Error>)
    }
    // wait(), succeed(), fail(); exactly-once completion
}

actor JSONRPCConnection {
    private var pending: [RequestID: RequestPromise<Data>] = [:]

    func request(...) async throws -> Data {
        let id = allocateID()
        let promise = RequestPromise<Data>()
        pending[id] = promise                  // no await
        do {
            try await transport.send(frame)   // pending already exists
        } catch {
            pending.removeValue(forKey: id)
            await promise.fail(error)
            throw error
        }

        return try await withTaskCancellationHandler {
            try await promise.wait(until: ContinuousClock.now + timeout)
        } onCancel: {
            Task { await self.cancelAndRemove(id) }
        }
    }
}
```

A dedicated timeout scheduler/clock should remove pending state exactly once. Late responses are discarded and counted; they are not stored for never-reused IDs.

### LSP-N02 — ordered inbound chain can be stalled by one handler

**Severity:** P1

Serial ordering is necessary for stateful notifications, but awaiting arbitrary notification/server-request handlers in one chain lets one slow handler block every response/event behind it.

**Required implementation**

Classify inbound messages:

- responses: complete pending immediately on the connection actor
- state-ordered notifications: enqueue to a bounded serial protocol lane
- independent notifications: dispatch to bounded handler tasks while preserving per-method ordering if needed
- server requests: independent bounded tasks with deadlines and cancellation

### LSP-N03 — public `didChange` API remains ambiguous/unsafe

**Severity:** P1

A public session API that fabricates a `{0,0}` range or accepts post-edit content without a clearly defined base version invites server desynchronization.

**Required implementation**

Expose only:

```swift
func synchronize(
    document: DocumentID,
    from old: DocumentSnapshot,
    applying transaction: AppliedEditTransaction,
    to new: DocumentSnapshot
) async throws
```

or full-text sync. The synchronizer decides incremental/full based on negotiated capability and version continuity.

### LSP-N04 — `preferIncremental` does not control behavior meaningfully

**Severity:** P2

Make synchronization policy explicit and capability-driven:

- server supports `None`/`Full`/`Incremental`
- host policy may force full for reliability/large batching
- version gaps force full reopen/resync
- debounce coalescing uses full text unless a valid composed delta is constructed

### LSP-N05 — bounded document events have no gap recovery

**Severity:** P0 for synchronization

If a document event is dropped, the server can silently miss a version. Every synchronizer subscription must compare sequence/document versions. On a gap, cancel pending debounce and send a full resync or close/reopen.

### LSP-N06 — save/close/change ordering is not one document lane

**Severity:** P1

`didSave` can overtake a pending debounced `didChange`; close can race pending work; errors are suppressed.

**Required implementation**

One actor per `(serverSession, documentID)` owns:

- open state
- last sent version
- pending coalesced text
- send queue
- save/close barrier
- resync state

Save flushes pending change first. Close cancels debounce, optionally flushes per policy, sends close, and terminates the lane.

### LSP-N07 — local open state can change before send succeeds

**Severity:** P1

Only commit host session state after the transport write succeeds, or maintain explicit `opening/open/closing/failed` state and recover.

### LSP-N08 — WorkspaceEdit decoding is incomplete

**Severity:** P1 for rename/code-action claim

Stable LSP needs:

- `changes`
- `documentChanges`
- versioned text document edits
- create/rename/delete resource operations
- change annotations and confirmation
- URI conversion and workspace-root checks
- per-document encoding conversion
- transaction preview/conflict policy

Decode to the shared typed workspace transaction engine, never apply ad hoc.

### LSP-N09 — cross-file snapshot resolution can silently use empty text

**Severity:** P0 for source edits/navigation

Resolver failure must not become an empty document, because line/character conversion then produces incorrect ranges. Resolve open snapshots first, then conflict-aware disk snapshots; otherwise return a typed unavailable/stale error.

### LSP-N10 — dynamic registration accounting is fragile

**Severity:** P2

Track each server registration by registration ID and method/options. Unregister exactly that record; do not use simple method counts that fail with duplicates/options.

### LSP-N11 — JSON result model is incomplete

**Severity:** P2

LSP results can be object, array, string, number, boolean, or null. Use a complete `JSONValue` model and avoid discarding valid scalar results.

### LSP-N12 — diagnostics streams are unbounded/not version-safe

**Severity:** P1

Diagnostics must include URI, source, server generation, document version when known, and sequence. The Problems service discards stale diagnostics when document/server generations change.

### LSP-N13 — current “real LSP” gate is not an integration test

**Severity:** P1

Required fixture:

1. start `sourcekit-lsp` for a temporary Swift package
2. `initialize`/`initialized`
3. open a Swift file
4. send change
5. request completion/hover/definition/symbols
6. observe diagnostics
7. apply a versioned edit fixture
8. shutdown/exit
9. assert no pending requests/tasks/file descriptors

Repeat with `clangd` for cross-server behavior.

---

## 15. Detailed audit — DAP

### DAP-N01 — same pending-registration race as LSP

**Severity:** P0

`DAPJSONRPCConnection` also creates a continuation, then starts `Task { await registerPendingThenSend(...) }`, while a sibling timeout task can win first. Replace both LSP and DAP implementations with one generic request lifecycle substrate.

### DAP-N02 — late responses are retained as “early” responses

**Severity:** P1

DAP sequence IDs are not expected to be reused. A response with no pending request should be logged/metriced and discarded, not cached.

### DAP-N03 — one reverse request/event can stall all inbound messages

**Severity:** P1

Apply the same message-lane classification as LSP. Responses must not wait behind a slow `runInTerminal` or custom event handler.

### DAP-N04 — missing reverse handler returns empty success

**Severity:** P1 protocol correctness

An unsupported reverse request should return a failed DAP response with an explanatory message, not `{}` success.

### DAP-N05 — session connection lifetime can crash

**Severity:** P0 if force-unwrapped during teardown

Remove force unwraps. Use an explicit session state machine:

```text
idle → starting → initializing → configured → running → terminating → terminated
                         ↘ failed
```

Every public method validates state and captures a stable connection reference or returns `invalidState`.

### DAP-N06 — breakpoint state is committed before adapter reconciliation

**Severity:** P1

The adapter may move, reject, or modify breakpoints. Store requested and verified breakpoint state separately, and update UI from the response.

### DAP-N07 — production target contains a mock adapter

**Severity:** P1 release hygiene

Move `Testing/MockDebugAdapter.swift` to a test-support target not shipped as production API.

### DAP-N08 — `runInTerminal` spans two terminal architectures

**Severity:** P1

DAP must depend only on the stable `TerminalService` facade. The facade must always route to real Ghostty in production. Remove legacy custom-terminal coupling.

### DAP-N09 — Stable DAP workflow is incomplete

**Severity:** P1/P2

Required end-to-end coverage:

- initialize capabilities
- launch and attach
- configurationDone
- source/function/data/instruction breakpoints as supported
- breakpoint reconciliation
- continue/pause/step in/out/over
- threads, stackTrace, scopes, variables
- evaluate/watch/REPL
- output/events
- runInTerminal
- sourceReference/source mapping
- modules/loadedSources when supported
- exception info
- disconnect/terminate/restart
- adapter crash, malformed frame, timeout, cancellation, and reconnection policy

### DAP-N10 — real DAP gate must use `lldb-dap`

**Severity:** P1

Use a tiny compiled fixture program with a deterministic breakpoint and variable value. Assert the complete lifecycle and process cleanup.

---

## 16. Detailed audit — terminal and Ghostty

### 16.1 Verdict

The current terminal is **not a Ghostty terminal UI**. It is a useful integration scaffold, but the shipping-shaped default path is explicitly a fallback byte spool.

`Sources/CGhosttyShim/codeeditor_ghostty.c` states:

```c
/*
 * Until libghostty is linked ..., this file provides a
 * minimal VT-less byte spool ...
 */
```

`ce_ghostty_surface_write` appends raw bytes to a string buffer. `ce_ghostty_surface_key_input` queues the supplied bytes unchanged. There is no terminal state machine, cells, cursor, attributes, alternate screen, reflow, hyperlinks, images, mouse mode, or renderer.

`GhosttySessionController` defaults `requireLinked: false`. `TerminalService` defaults `requireGhosttyLinked: false`. The workbench explicitly constructs both with `false`. CI’s Ghostty build is optional and `continue-on-error`, and the pin check succeeds in “unlinked mode.”

The visible terminal surface is an editable `NSTextView`/`UITextView` fed full UTF-8 snapshots and polled at roughly 50 ms. This is not Ghostty’s Metal/CoreText terminal rendering/input/accessibility path.

### TER-N01 — fake fallback is on the default production-shaped path

**Severity:** P0

**Required implementation**

- The release configuration must compile/link the pinned Ghostty library.
- `requireLinked` must be `true` in every production initializer/factory.
- The byte-spool implementation must move to a dedicated test target or compile only under an unmistakable test macro.
- `ce_ghostty_is_linked() == false` must make the terminal product unavailable with a clear configuration error; it must never produce a fake terminal.

### TER-N02 — terminal UI is a text snapshot, not Ghostty rendering

**Severity:** P0

To satisfy “Ghostty as the terminal UI,” use one of these explicit integration levels:

#### Required final level: full Ghostty surface integration

```text
CodeEditorWorkbench TerminalPanel
        │ tabs/splits/focus/restoration owned by CodeEditor
        ▼
CodeEditorTerminal public session/input/accessibility facade
        ▼
CodeEditorTerminalGhostty adapter
        ▼
CGhosttyShim (narrow, pinned compatibility ABI)
        ▼
Ghostty terminal state + renderer + platform surface
        ▼
Metal/CoreText on macOS; supported Ghostty path on other platforms
```

CodeEditor owns IDE chrome, process/session lifecycle, tabs, splits, task/debug association, and security policy. Ghostty owns terminal emulation, screen state, cursor/modes, input encoding, reflow, and terminal rendering behavior.

#### Temporary development level

If only `libghostty-vt` is practically embeddable at the pinned revision, CodeEditor may use Ghostty’s VT state with a CodeEditor renderer. It must be documented as **Ghostty VT engine + CodeEditor renderer**, not “Ghostty UI,” and cannot meet the user’s final requirement until the real surface path is integrated.

### TER-N03 — two conflicting terminal architectures remain public

**Severity:** P1

Legacy `VTParser`, `TerminalScreen`, `TerminalSessionManager`, and related custom-terminal types remain public and tested, while the new service says it does not use them.

**Required implementation**

- choose `TerminalService` + Ghostty as the only production architecture
- move the custom parser/screen to test fixtures or remove it
- provide migration deprecations for any public APIs already used
- DAP/tasks/workbench all depend on one facade

### TER-N04 — input mapping is incomplete

**Severity:** P1

Passing `event.characters` bytes does not implement:

- modifiers
- arrows/navigation/function keys
- application cursor/keypad modes
- Kitty keyboard protocol where supported
- control/meta/option policy
- dead keys and IME
- bracketed paste
- mouse reporting and selection interaction
- focus in/out
- clipboard/OSC 52 policy
- drag/drop
- hyperlinks
- context menu and accessibility actions

Route native events to Ghostty’s input encoder/state, not a hand-built byte map.

### TER-N05 — per-chunk UTF-8 snapshot handling loses split scalars

**Severity:** P1

Raw terminal output is bytes, not independently decodable strings. Feed bytes directly into Ghostty and derive display from terminal state. Never decode each process chunk to a standalone Swift `String`.

### TER-N06 — repeated full-string snapshots are O(n²)-prone

**Severity:** P1

Do not append/suffix/copy full scrollback strings on every chunk or poll full snapshots. Render dirty cells/lines/tiles and expose a paged scrollback/search API.

### TER-N07 — local PTY transport stream and write lifecycle are unsafe

**Severity:** P1

Findings include:

- unbounded inbound stream
- concurrent writes can overwrite one dispatch write source/continuation
- termination may block
- user termination can look like exit 0
- row/column conversion can trap outside `UInt16`
- C setup ignores important return codes
- controlling terminal/process group establishment is not fully proven

**Required implementation**

A `ProcessSupervisor`-owned PTY session with:

- atomic spawn/session/process-group setup
- serialized bounded writes
- raw-byte multicast output
- nonblocking cancel/escalation
- exact exit reason (`exited`, `signalled`, `cancelled`, `spawnFailed`)
- validated/clamped dimensions
- resize coalescing
- descriptor lifecycle tests

### TER-N08 — terminal security policy is incomplete

**Severity:** P1

Define local/remote/sandboxed profiles:

- macOS direct distribution: local PTY allowed under host policy
- Mac App Store: host-specific entitlement/review constraints
- iOS: no local arbitrary process; remote terminal transport only unless host has a permitted specialized environment
- extension access: explicit terminal-create/write/read capabilities, not ambient access
- OSC actions, hyperlinks, clipboard, file transfer, notifications, and shell integration individually permissioned

### TER-N09 — no direct tests for `CodeEditorTerminalGhostty`

**Severity:** P0 before Stable

Add a dedicated test target and real linked-library conformance fixtures:

- ANSI/VT corpus
- UTF-8 split at every byte boundary
- alternate screen
- resize/reflow
- wide/combining/emoji cells
- color/style/cursor modes
- bracketed paste/input encoding
- mouse/focus reporting
- scrollback/search/selection
- 100 MiB sustained output soak
- rapid resize/input/output concurrency
- process exit/cancel/crash
- memory/resource leak checks
- VoiceOver/keyboard UI tests for the rendered surface

### TER-N10 — pinning alone is not integration qualification

**Severity:** P1

Ghostty’s embeddable C interfaces are evolving. Keep an exact commit pin and a CodeEditor-owned C compatibility shim, but require:

- ABI compile probes
- symbol checks
- behavior corpus
- upstream update diff report
- license notices
- reproducible build artifact/checksum
- no Ghostty C/Zig types in public Swift API

---

## 17. Detailed audit — extension manifests, packages, runtime, and security

### EXT-N01 — TOML parser is intentionally a minimal subset

**Severity:** P1 compatibility/correctness

A custom line parser with basic quote/comment handling is not a general TOML implementation. It risks silently accepting malformed lines as warnings and mishandling escapes, multiline strings, dotted keys, arrays/tables, numeric forms, and comments inside strings.

**Required decision**

Choose one:

1. Use a standards-compliant TOML parser and publish the supported manifest schema.
2. Define a deliberately smaller **CodeEditor Manifest Language** and do not call it general TOML/Zed-compatible.

Recommended: standards-compliant TOML syntax plus a versioned CodeEditor schema. Unknown required fields and malformed contribution entries fail closed; unknown optional fields can be retained for forward compatibility.

### EXT-N02 — compatibility claims need levels, not one “passing” flag

**Severity:** P1 release truth

Define:

- **S0 Package syntax:** package layout/manifest parses
- **S1 Data contributions:** themes/icons/snippets/grammars/query assets behave equivalently
- **S2 Swift SDK parity:** CodeEditor Swift API can express the target capability
- **S3 Behavioral parity:** host behavior matches documented fixtures
- **S4 Operational parity:** install/update/revoke/crash/security/performance qualified
- **Zed binary compatibility:** separate and not initially promised

Each feature carries its own level and test evidence.

### EXT-N03 — non-cryptographic digest fallback exists in plan validation

**Severity:** P0 if used as security identity

Any digest used for signatures, package identity, cache identity, or trusted plan binding must require SHA-256 or stronger and throw when unavailable. A DJB-like fallback may be used only as a non-security hash with a different type/name.

### EXT-N04 — package signature skips hidden files

**Severity:** P0

`fileDigests` enumerates with `.skipsHiddenFiles`. An attacker can add hidden files that are installed/consumed later without changing the signature.

**Required implementation**

Inventory every directory entry except a narrowly defined set of detached signature files. Prefer an explicit canonical manifest of paths/types/sizes/digests. Reject symlinks and special files unless a signed schema explicitly permits them.

### EXT-N05 — `.codeeditor/` is explicitly unsigned

**Severity:** P0

Host installation metadata must not live inside the untrusted package root. Either sign `.codeeditor/` package content or move host-generated state outside the immutable content-addressed package.

### EXT-N06 — publisher identity is not bound by default signature

**Severity:** P0

The default signer signs `checksums.json`, then writes `publisher.json`. A verifier may validate the key against a local keyring, but the complete publisher statement is not one canonical signed payload.

**Required signed statement**

```json
{
  "schema": 1,
  "extension_id": "publisher.extension",
  "version": "1.2.3",
  "publisher": {
    "subject": "Example Publisher",
    "key_id": "ed25519:..."
  },
  "manifest_sha256": "...",
  "inventory_sha256": "...",
  "package_sha256": "...",
  "created_at": "...",
  "minimum_host_api": "1.0",
  "maximum_host_api": null
}
```

Sign a canonical encoding (for example deterministic CBOR or JSON Canonicalization Scheme). Require all fields; reject duplicates/noncanonical encodings.

### EXT-N07 — key writing can destroy the existing key before replacement succeeds

**Severity:** P0 key-loss risk

Do not remove a regular key file and then attempt exclusive create at the same path. Write a new key to a unique file, fsync, set mode, atomically rename, fsync directory, and retain backup/rotation metadata. Handle short writes and `EINTR`.

### EXT-N08 — security helpers `fatalError` without CryptoKit

**Severity:** P1

Public/runtime security APIs must throw `cryptoUnavailable` or be unavailable at compile time. Host input must never reach a fatal process termination.

### EXT-N09 — keyring parser silently skips malformed data

**Severity:** P1

Use a versioned strict schema. Duplicate key IDs, invalid base64/length, duplicate subjects, malformed revocations, and unknown required fields are errors. A partially parsed trust store is unsafe.

### EXT-N10 — package inventory has no global resource limits

**Severity:** P0 denial of service

Before parsing or hashing, enforce:

- maximum file count
- maximum directory depth
- maximum individual and total bytes
- maximum path length/component length
- no symlink/special file
- bounded manifest/TOML/JSON sizes
- bounded compression ratio if archives are supported
- streaming hashes, not whole-file `Data`

### EXT-N11 — install parses/copies before complete verification

**Severity:** P0

Use a secure staging inventory first. The installer should not activate or trust data from the package until structural validation, signature verification, manifest binding, capabilities, and compatibility all pass.

### EXT-N12 — installation/update is not crash durable

**Severity:** P0

Required content-addressed layout:

```text
ExtensionStore/
  blobs/sha256/<digest>/immutable package bytes
  installs/<extension-id>/<version>.json      signed/verified pointer metadata
  active/<extension-id>.json                  atomic active pointer
  transactions/<tx-id>.json                   durable journal
  host-state/<extension-id>/...                mutable settings/cache outside package
```

Install flow:

1. secure no-follow inventory and limits
2. stream into unique staging directory
3. verify canonical signature/inventory/manifest
4. fsync content and directories
5. atomically move to content-addressed blob
6. write/fsync version record
7. atomically swap active pointer
8. fsync parent
9. publish snapshot
10. retain prior version for rollback

Startup replays/rolls back incomplete transactions before loading extensions.

### EXT-N13 — same-version reinstall can mix plan and bytes

**Severity:** P0

If `<id>/<version>` already exists, compare immutable content digest. Either return the existing verified install only when digests match, or install a distinct content revision and require explicit replacement policy. Never parse a new source and return an old path.

### EXT-N14 — persisted package paths are trusted too directly

**Severity:** P0

Do not trust absolute package roots from mutable `packages.json`. Persist content digest and relative store key; reconstruct under the known root and reverify on startup.

### EXT-N15 — revocation state lacks freshness/rollback protection

**Severity:** P0 for marketplace trust

Revocation metadata needs issuer, signature, sequence/epoch, issued/expiry times, and monotonic rollback prevention. Failure to refresh must follow an explicit policy. A revoked package must be removed from active snapshots and drivers terminated immediately.

### EXT-N16 — recovery and snapshot filtering can expose unverified state

**Severity:** P0

A loadable extension record must satisfy all of:

```text
installed
∧ immutable bytes exist under store root
∧ package digest matches
∧ signature/trust verified under current policy
∧ not revoked
∧ enabled
∧ compatible with host/platform
∧ capabilities granted
∧ store not quarantined
```

No recovered directory defaults to enabled/trusted.

### EXT-N17 — executable-content detection is heuristic

**Severity:** P0

Classify executable content from the signed manifest/inventory and validate every file path/type. Detect Wasm/native/helper content recursively. A data-only package cannot contain undeclared executable material.

### EXT-N18 — telemetry/log files are unbounded and errors are swallowed

**Severity:** P1

Rotate by size/time, cap total disk usage, redact secrets/paths as policy requires, and expose write failure metrics.

### EXT-N19 — package snapshot stream is not a robust broadcast contract

**Severity:** P1

Use immutable full snapshots plus sequenced deltas through the shared broadcast hub. A dropped delta forces a new snapshot.

### EXT-N20 — test doubles and simulations are public production surface

**Severity:** P1

Move mock transports, linked-guest simulation, and conformance-only guests to test-support packages. `ConformanceExtensionGuest` should not be a public product that must later be declared Stable; it is a fixture executable.

---

## 18. Detailed audit — capability broker and runtime isolation

### BROKER-N01 — broker handles are not bound to the caller

**Severity:** P0 capability-boundary bypass

`BrokerHandle` stores its owning `extensionID`, but `CapabilityBroker.dispatch(method:extensionID:payload:)` resolves most handles only by handle ID, kind, operation, and stored generation. `resolve` does not compare the stored owner with the `extensionID` making the call. `resolveWorktreePath` receives an extension ID and discards it.

If one extension obtains another extension’s handle through logging, IPC confusion, a compromised guest, or a host bug, it can exercise that handle’s capabilities.

**Required fix**

```swift
private func resolve(
    _ id: BrokerHandleID,
    caller: ExtensionID,
    kind: CapabilityKind,
    operation: CapabilityOperation
) throws -> BrokerHandle {
    guard let handle = handles[id] else { throw BrokerError.forgedHandle }
    guard handle.extensionID == caller else { throw BrokerError.forgedHandle }
    guard generations[caller] == handle.generation else { throw BrokerError.staleGeneration }
    guard handle.kind == kind, handle.operations.contains(operation) else { ... }
    return handle
}
```

Add cross-extension adversarial tests for every handle type.

### BROKER-N02 — handles can be minted for unregistered extensions

**Severity:** P0

`issue` uses generation `0` when no registration exists; settings/storage handles can be minted without a permission check. Require an active registered extension generation before issuing any handle.

### BROKER-N03 — malformed wire payloads degrade to defaults

**Severity:** P0 for security-sensitive calls

Invalid JSON becomes `{}`, invalid base64 becomes empty `Data`, and missing fields become empty strings. This hides protocol attacks and can turn malformed input into a valid request with unintended defaults.

**Required implementation**

Use typed Codable/CBOR request schemas with required fields, bounded lengths, enum validation, and a schema version. Reject unknown fields in security-sensitive messages unless explicitly forward-compatible.

### BROKER-N04 — initialization suppresses storage directory errors

**Severity:** P1

If storage/cache roots cannot be created securely, broker initialization must fail. Do not continue with partially unavailable storage.

### BROKER-N05 — worktree list hides I/O failure as an empty directory

**Severity:** P1

An empty result is semantically different from permission denied, deleted, transient I/O, or path race. Propagate typed errors.

### BROKER-N06 — path containment is not descriptor-relative

**Severity:** P0 for untrusted extensions

`resolvingSymlinksInPath` and later `Data(contentsOf:)` leave a symlink-swap race. Use directory-descriptor-relative no-follow operations and validate the final file identity/type.

### BROKER-N07 — executable allow decision can race executable replacement

**Severity:** P0

Resolve and open the executable under trusted directories, validate it, then spawn by a trusted descriptor/path identity where the platform permits. At minimum revalidate immediately before spawn and prohibit extension-writable allowlist directories.

### BROKER-N08 — `projectInfo` encodes roots ambiguously

**Severity:** P2

Do not join roots with `:`. Return a typed array of URI/path records.

### BROKER-N09 — settings/storage have incomplete quotas

**Severity:** P1

Enforce key length/count, value length, total settings bytes, total storage bytes, per-item bytes, and operation rate. Include settings in extension storage accounting.

### BROKER-N10 — storage quota calculation scans synchronously

**Severity:** P1

Maintain durable accounting metadata and verify periodically. Writes use a serialized reservation/commit model and remain robust to external tampering.

### BROKER-N11 — process “argsGlob” is not a glob

**Severity:** P1 policy ambiguity

The current policy is exact argument vector or `**`. Rename it to exact matcher or implement a safe structured matcher. Avoid shell-like patterns that become injection surfaces.

### BROKER-N12 — spawned process output has no complete capability stream

**Severity:** P1

Starting a process without a bounded stdout/stderr subscription means output can accumulate with no consumer. Return a process lease that exposes sequenced output subscriptions, exit status, cancellation, and resource metrics through the shared process supervisor.

### BROKER-N13 — download is whole-memory and redirect policy incomplete

**Severity:** P1

- reject non-HTTPS initial and redirected URLs unless an explicit profile permits otherwise
- enforce host/path after every redirect
- validate `Content-Length` early when present
- stream to a unique restrictive temp file while hashing
- enforce compressed/decompressed limits where relevant
- fsync and atomic move into tool cache
- bind expected digest and source URL in metadata
- do not build the entire response in memory

### BROKER-N14 — path-prefix allowlist uses string prefix

**Severity:** P0

`/allowed-bad` must not match `/allowed`. Normalize URL path components and compare component prefixes after percent-decoding policy is defined.

### BROKER-N15 — npm materializer mishandles scoped packages and total size

**Severity:** P1/P0 denial of service

- rejecting `/` prevents `@scope/package`
- recursive size accounting does not reliably return child totals to the parent
- hidden files are skipped
- package content is modified after copy, breaking source digest identity
- there is no complete dependency/lockfile/integrity model

Treat npm as a host-owned artifact resolver, not arbitrary `npm install`. Resolve from a trusted registry/cache, verify integrity, materialize immutable files, and disable scripts before acquisition through policy—not by mutating a copied `package.json` after verification.

### BROKER-N16 — revoke can block the broker actor

**Severity:** P1

Process cancellation must be asynchronous through the process supervisor. Revocation should remove capabilities immediately, request process termination, and await cleanup outside the broker’s critical actor path.

---

## 19. Detailed audit — Wasm execution and Swift extension guest

### WASM-N01 — watchdog cannot interrupt a noncooperative Wasm loop

**Severity:** P0 isolation failure

`WasmKitEngine.call` invokes Wasm synchronously on a global queue and races that work against a timeout task. At timeout it sets an interrupt flag in host state. A Wasm loop that does not call a host import cannot observe that flag. Cancelling the Swift task group does not stop the synchronous `Function.invoke`, and structured task groups wait for child completion before returning.

The current hostile loop fixture calls `host_should_cancel`, so it proves cooperative cancellation only.

**Required implementation options**

1. Use engine-supported instruction fuel/epoch interruption/store limits if WasmKit exposes reliable facilities at the pinned version.
2. Instrument modules with metering at validation/compile time and reject uninstrumentable modules.
3. Run the Wasm engine in a killable helper process, enforce wall/CPU/memory limits externally, and terminate the process on timeout.

For third-party untrusted extensions, option 3 is the safest fallback until in-process hard interruption is proven.

**Acceptance criterion:** a Wasm function containing a pure `loop { br 0 }` with no imports terminates within the configured deadline plus a small bounded shutdown tolerance, and no worker thread remains stuck.

### WASM-N02 — memory growth is not continuously limited

**Severity:** P0

Checking initial/current memory at instantiation does not constrain subsequent `memory.grow`. Enforce declared max pages and runtime store limiter. Reject modules without a maximum unless the engine can impose one. Meter tables, globals, stack/recursion, and instance count too.

### WASM-N03 — missing memory must fail ABI validation

**Severity:** P0

Do not fabricate a detached memory when the guest fails to export the required memory. Validate all required imports/exports and exact signatures before activation.

### WASM-N04 — calls and memory access are not clearly serialized

**Severity:** P0 memory/concurrency safety

WasmKit function/store/memory values are boxed `@unchecked Sendable` and invoked from global queues. One instance must be owned by one serial runtime actor/executor unless the engine explicitly guarantees concurrency.

### WASM-N05 — memory view growth API is incomplete

**Severity:** P1

A public `grow` that always throws under the nominal limit is a stub. Either implement safe growth through the engine or remove it from the Stable protocol.

### WASM-N06 — unsupported Wasm values must not coerce to zero

**Severity:** P0 ABI correctness

Unknown/unsupported value types return a typed `unsupportedValueType` error. Never silently convert to `i32(0)`.

### WASM-N07 — monotonic clock is not monotonic and may truncate

**Severity:** P1

Use `ContinuousClock`/monotonic host time, and expose an ABI width that does not truncate uptime. Wall-clock `Date` is unsuitable for deadlines.

### WASM-N08 — session-wide deadline expires all future calls

**Severity:** P0

`CoreWasmABISession` creates one deadline at initialization and checks it in every `pollOnce`. A healthy long-lived extension eventually fails solely because the session has existed too long.

Use per-activation and per-request deadlines, plus optional per-tick budget. All use a monotonic clock.

### WASM-N09 — request continuation is installed by an unstructured task

**Severity:** P0

`request` creates a continuation then starts `Task { await runRequest(...) }`. Apply the same one-shot promise and atomic pending-registration design as LSP/DAP.

### WASM-N10 — configured limits are not enforced

**Severity:** P0/P1

Ensure active enforcement and tests for:

- max concurrent requests
- max outstanding guest allocations
- max poll ticks per request and per activation
- max host-send messages/bytes
- max log bytes/rate
- max request/response bytes
- max wall and CPU time
- max memory/table/stack/instances
- max capability calls/rate

### WASM-N11 — logs are unbounded

**Severity:** P1

The message box appends strings indefinitely. Use a byte-counted ring with rate limits and truncation metrics.

### WASM-N12 — cancellation is global and never reset

**Severity:** P0 correctness

A single `hasCancel` flag means one request cancellation can affect all later requests. Cancellation must be keyed by request ID and removed after completion. The ABI should pass/request the ID consistently.

### WASM-N13 — poll return status is ignored

**Severity:** P1

Define and enforce statuses: idle, progress, backpressure, completed, guest error, fatal. Unknown statuses are ABI errors.

### WASM-N14 — guest allocations are leaked

**Severity:** P1

Every `alloc` used for start/receive/request must be paired with `dealloc` in `defer`, including failures.

### WASM-N15 — linked Swift guest simulation must be test-only

**Severity:** P1 release truth

A linked in-process Swift guest is useful for protocol tests, but it is not Wasm isolation. Move it behind test support/SPI and ensure conformance runs separately against actual Wasm bytes.

### WASM-N16 — adversarial corpus needs truly hostile modules

**Severity:** P0 before Stable

Required compiled/generated fixtures:

- pure noncooperative infinite loop
- unbounded/large `memory.grow`
- deep recursion/stack exhaustion
- huge table
- malformed imports/exports/signatures
- out-of-bounds reads/writes
- oversized host sends/log flood
- capability-call flood
- invalid CBOR/envelope and decompression bombs if supported
- response after cancellation/timeout
- guest trap during activation/deactivation
- concurrent request pressure

Run in process-isolated CI so a failed containment test cannot hang the whole test runner.

---

## 20. Fake, simulated, soft-stub, or misleading implementation inventory

The following items should be removed, renamed, restricted to tests, or completed before Stable:

| Area | Current behavior | Why it is misleading | Stable action |
|---|---|---|---|
| Ghostty C shim | raw byte spool | no terminal state or rendering | test-only; production must require linked Ghostty |
| Ghostty surface | editable text view with snapshots | not Ghostty terminal UI | integrate real Ghostty surface/render path |
| Ghostty CI | optional/continue-on-error | pin can pass with no library | mandatory linked test artifact |
| legacy terminal | custom parser/screen remains public | two terminal architectures | remove/deprecate from production surface |
| contribution isolation | SwiftUI wrapper/fallback | cannot contain crash/hang/privilege | rename to error fallback; declarative/out-of-process boundary for untrusted code |
| regex replacement | `$0` only | normal regex replacement not implemented | full capture semantics and exact preview ranges |
| navigation reveal | fabricated offset formula | not layout-based navigation | editor layout reveal API |
| animation helper | no-op | name claims behavior absent | implement or remove |
| LSP “real” test | tool `--help`/soft availability | does not exercise protocol | full real-server session |
| DAP “real” test | tolerant probe | does not exercise debugger | `lldb-dap` fixture program |
| API freeze | symbol-name grep/subset | misses semantic API changes | symbol graphs/API digester all products |
| accessibility gate | token grep | does not prove accessible use | XCUI + manual protocol |
| performance gate | docs keywords/loose sample | no reliable regression evidence | benchmark artifacts and hard budgets |
| defect/scorecard gates | authored “fixed/pass/empty” | circular self-certification | generated from test artifacts |
| linked guest Wasm | in-process Swift simulation | no Wasm/security boundary | test support only |
| hostile Wasm | cooperative cancel fixture | does not prove hard interruption | pure non-host-calling infinite loop |
| mock DAP/remote transports | production targets | expands public fake surface | test-support targets |
| SCM auth/progress | API not wired to Git path | feature appears available but is not | implement or remove from scope |
| “durable” workspace journal | no complete startup recovery | write-only record is not recovery | typed journal + restart recovery |
| `npmInstall` | local tree copy/mutation | not npm lifecycle/integrity | host artifact resolver with integrity |

---

## 21. Product-by-product maturity assessment

“Alpha candidate” means the product could reach Alpha after named blockers close; it does not mean current Alpha quality.

| Product | Current audit maturity | Primary blockers before Alpha | Stable exit emphasis |
|---|---|---|---|
| `CodeEditorCore` | Pre-alpha / Alpha candidate | content-state/savepoint model; process/event substrate; unsafe public undo; overflow checks | property/fuzz tests, actor ownership, API digester, perf |
| `CodeEditorDocuments` | Pre-alpha, P0 | normal save bypasses CAS; recovery durability; file metadata/races | no-overwrite guarantee, restart recovery, provider conformance |
| `CodeEditorCommands` | Alpha candidate | soft replacement, token lifetime, stale timeout context | deterministic scopes/chords, diagnostics, accessibility |
| `CodeEditorWorkspace` | Pre-alpha, P0 | transaction rollback/recovery; dirty delete; blocking I/O | crash-durable typed transactions, multi-root/watcher tests |
| `CodeEditorWorkbench` | Experimental/pre-alpha | façade workflows, fake isolation, task lifetime, main-thread indexing | integrated workflows, restoration, accessibility/UI tests |
| `CodeEditorView` | Pre-alpha | IME/BiDi/grapheme/geometry/large selections; platform evidence | native text-input suite, layout performance, accessibility |
| `CodeEditorLanguageSupport` | Alpha candidate | registry ownership/generation; global bootstrap | stable descriptor/registry contracts, extension ownership |
| `CodeEditorLanguageServices` | Pre-alpha | provider lifecycle, stale result/cancellation, complete feature contracts | real-provider fixtures and versioned result discipline |
| `CodeEditorExtensionAPI` | Experimental | API surface not security/runtime-qualified; compatibility claims | Swift SDK conformance, semantic versioning, samples/docs |
| `CodeEditorExtensions` | Experimental, P0 | installer durability/trust/snapshot filtering | immutable store, signed plans, rollback/revocation |
| `codeeditor-extension` | Experimental | no direct test target; CLI error/format compatibility | golden CLI tests, signing/build/package workflows |
| `CodeEditorExtensionHost` | Experimental, P0 | broker ownership, signing, runtime isolation, process transport | threat-model suite, containment, lifecycle/telemetry |
| `CodeEditorWasmEngine` | Experimental, P0 | hard interrupt, limits, public simulation | hostile corpus, resource metering, semantic ABI |
| `CodeEditorWasmEngineWasmKit` | Experimental, P0 | noncooperative loop/memory/call serialization; no direct tests | engine-specific conformance and process-isolated stress |
| `CodeEditorExtensionWasmGuest` | Experimental | cancellation/request IDs/allocations/limits | Swift-Wasm toolchain fixtures and ABI compatibility |
| `CodeEditorExtensionProtocol` | Experimental | strict schema/limits/version negotiation; mocks public | fuzzed framing/CBOR, backward/forward compatibility |
| `CodeEditorExtensionGuest` | Experimental | helper process containment/lifecycle; no direct tests | crash/hang/fork/output-flood suites |
| `ConformanceExtensionGuest` | Test fixture, not a Stable product | incorrectly exposed as product | move to test support or clearly non-public tooling |
| `CodeEditorLSP` | Experimental, P0 | request race, stream gaps, ordering, WorkspaceEdit, live server tests | protocol matrix, real servers, cancellation/timeout soak |
| `CodeEditorDAP` | Experimental, P0 | request race, state machine, reverse request, real adapter | lldb-dap end-to-end and malformed-adapter tests |
| `CodeEditorSearch` | Pre-alpha | ignore/glob/regex/encoding/transaction correctness | Git parity corpus, bounded streaming, replace preview |
| `CodeEditorTasks` | Pre-alpha, P0 | non-broadcast stream, decoding, unbounded logs, graph outcomes | real process graph, readiness/problem fixtures, soak |
| `CodeEditorTerminal` | Experimental, P0 | dual architecture, PTY/process lifecycle | single Ghostty-backed facade and real terminal corpus |
| `CodeEditorTerminalGhostty` | Proof of concept/fake fallback | no linked default, no renderer, no direct tests | mandatory real Ghostty surface, input/accessibility/soak |
| `CodeEditorSourceControl` | Experimental, P0/P1 | dirty buffers, status model, auth, concurrency, patch correctness | real repositories, operation actor, credential integration |
| `CodeEditorTreeSitter` | Pre-alpha | dual state, query suppression, pointer ownership, minimal direct tests | all-grammar incremental/query/perf/memory fixtures |
| `CodeEditorLanguageSwift` | Pre-alpha | no direct test target; query completeness | representative Swift syntax/query/indent/fold fixtures |
| `CodeEditorLanguageJSON` | Pre-alpha | no direct test target | JSON/JSONC policy, malformed/large fixtures |
| `CodeEditorLanguages` | Pre-alpha | all-pack bootstrap/lifecycle and generated conformance | 39-grammar matrix, provenance, load/unload tests |

### Product rationalization before API freeze

Not every current product should become a public Stable promise:

- Move `ConformanceExtensionGuest` to test support.
- Move mock transports/adapters and linked-guest simulations out of production products.
- Consider keeping `CodeEditorTerminalGhostty` an implementation package while `CodeEditorTerminal` owns the Stable public API.
- Keep low-level guest/Wasm protocol products Experimental/SPI until the extension ABI has passed compatibility and security qualification; the user-facing Swift SDK can stabilize separately.
- Do not leak Ghostty, WasmKit, Tree-sitter C pointers, or transport implementation types through Stable public APIs.

---

## 22. Target architecture for a Stable Xcode-class kit

### 22.1 Architectural rules

1. **One owner per mutable resource.** A document, process, terminal session, server connection, debugger session, repository, extension runtime, and workspace transaction each have one actor/supervisor owner.
2. **Immutable snapshots cross actor/UI boundaries.** Mutable parser trees, terminal screens, text storage, and process state do not leak as unchecked Sendable objects.
3. **Every stream declares broadcast, buffering, sequence, gap, and finish semantics.** No raw `AsyncStream` is exposed without a policy.
4. **Every asynchronous operation has cancellation, deadline, cleanup, and exactly-once completion.** No continuation is installed through an unowned task.
5. **Persistent mutations are journaled and restart-recoverable.** Atomic rename alone is not enough when multiple resources participate.
6. **Security boundaries fail closed.** Missing policy, verifier, identity, crypto, runtime limits, or linked implementation disables the feature.
7. **Public APIs describe behavior, not implementation aspirations.** A method named “isolated,” “durable,” “Ghostty,” or “Zed-compatible” must meet that contract.
8. **Test doubles never ship as production defaults.** They live in test-support targets and require explicit construction.
9. **The workbench composes services; it does not reimplement them.** Editor/workspace/tasks/SCM/LSP/DAP/terminal/extension paths have one source of truth.
10. **Stable scope is explicit.** Unsupported Xcode/Zed features are marked unsupported/experimental rather than represented by placeholders.

### 22.2 Proposed dependency layers

```text
Layer 0 — Value contracts
  CodeEditorCoreTypes (or nonmutating portions of CodeEditorCore)
  IDs, ranges, snapshots, JSON/CBOR values, errors, clocks, metrics

Layer 1 — Reliability substrate
  AsyncBroadcastHub
  OneShotPromise / DeadlineScheduler
  ProcessSupervisor
  BoundedByteSpool
  StructuredLog
  DurableTransactionJournal

Layer 2 — Editing foundation
  DocumentActor / DocumentStore
  DocumentLifecycleCoordinator
  Savepoint + file identity + recovery
  Selection/caret/navigation engine
  immutable layout snapshots

Layer 3 — Workspace foundation
  WorkspaceFileSystem
  WorkspaceTransactionCoordinator
  WorkspaceIndex / watcher
  Commands and focus scopes

Layer 4 — Tooling protocols
  Language registry / Tree-sitter
  Search
  Tasks
  SCM
  generic framed RPC transport

Layer 5 — External integrations
  LSP
  DAP
  Ghostty terminal
  extension native/Wasm/remote runtimes

Layer 6 — Workbench composition
  windows, tabs, splits, navigators, panels, restoration
  project/build/test/debug/source-control workflows

Layer 7 — Host applications
  small editor, medium workspace, full IDE, platform-specific capabilities
```

The package may preserve current product names; this is a dependency/ownership model, not necessarily a mandatory package split.

### 22.3 Shared multicast event hub

Implement one reviewed hub instead of custom stream creation in every product:

```swift
public actor AsyncBroadcastHub<Event: Sendable> {
    public struct SubscriptionID: Hashable, Sendable { /* ... */ }

    public enum OverflowPolicy: Sendable {
        case suspendProducer(maxPending: Int)
        case dropOldest(capacity: Int, emitGap: Bool)
        case spoolToDisk(maxBytes: Int)
    }

    public struct Envelope: Sendable {
        public let sequence: UInt64
        public let event: Event
    }

    public func subscribe(
        policy: OverflowPolicy,
        replay: ReplayPolicy = .none
    ) -> AsyncStream<StreamItem<Envelope>>

    public func publish(_ event: Event) async
    public func finish(_ reason: StreamFinishReason)
}
```

Requirements:

- each subscriber receives every event after its subscription unless its own policy overflows
- producer/subscriber lifetimes are explicit
- sequence numbers expose gaps
- overflow is metriced and, where correctness matters, emits `.gap`
- snapshots/replay are supported where consumers need recovery
- no subscription registration race: construction happens inside the owning actor before returning
- finish occurs exactly once

Use it for documents, workspace, process output, task events, diagnostics, SCM status, extension snapshots, terminal events, debug events, and logs.

### 22.4 Shared process supervisor

```swift
public actor ProcessSupervisor {
    public func spawn(_ request: ProcessSpawnRequest) async throws -> ProcessLease
    public func cancel(_ lease: ProcessLease.ID, escalation: EscalationPolicy) async
    public func awaitExit(_ lease: ProcessLease.ID) async throws -> ProcessExit
}

public struct ProcessLease: Sendable {
    public let id: ID
    public let pid: pid_t
    public let stdout: AsyncBroadcastHub<ProcessOutput>.SubscriptionFactory
    public let stderr: AsyncBroadcastHub<ProcessOutput>.SubscriptionFactory
    public let events: AsyncBroadcastHub<ProcessEvent>.SubscriptionFactory
}
```

The supervisor owns:

- executable/cwd/environment validation
- `posix_spawn`/PTY creation
- process group/session establishment before child execution
- raw byte reads and incremental decoding helpers
- output spool limits
- exit/cancel/escalation
- descriptor cleanup
- child reaping
- resource metrics
- trust/capability audit

Tasks, LSP, DAP, Git, MCP, native extension helpers, and terminal PTYs use this service. No product launches `Process` independently in Stable paths.

### 22.5 Shared framed-RPC engine

Build a generic engine parameterized by framing and message codec:

```swift
public actor FramedRPCConnection<Codec: RPCCodec, Transport: ByteTransport> {
    public func request(
        method: Codec.Method,
        params: Codec.Params,
        deadline: ContinuousClock.Instant
    ) async throws -> Codec.Result

    public func notify(... ) async throws
    public func close(reason: RPCShutdownReason) async
}
```

Required semantics:

- pending record created synchronously before any transport await
- one-shot promise handles response-before-wait
- monotonic deadline scheduler
- cancellation removes pending state and sends protocol cancellation when supported
- late response discarded/metriced
- bounded message/body size
- parse/framing errors are typed
- responses are completed immediately, not blocked by slow handlers
- ordered lanes for stateful notifications
- bounded server/reverse request concurrency
- shutdown fails all pending exactly once
- test clock and deterministic scheduling fixtures

LSP, DAP, MCP, remote extensions, and native helper RPC adapt this engine instead of maintaining subtly different continuation code.

### 22.6 Document model

Recommended core state:

```swift
actor DocumentActor {
    private var storage: TextStorage
    private var version: DocumentVersion
    private var stateID: DocumentContentStateID
    private var savepoint: DocumentSavepoint?
    private var undoGraph: UndoGraph
    private let events: AsyncBroadcastHub<DocumentEvent>

    func snapshot() -> DocumentSnapshot
    func apply(_ transaction: EditTransaction, expected: DocumentVersion?) throws -> AppliedEditTransaction
    func undo() throws -> AppliedEditTransaction?
    func redo() throws -> AppliedEditTransaction?
    func establishSavepoint(_ receipt: DocumentSaveReceipt)
}
```

`DocumentSnapshot` must be immutable and self-contained enough for background layout/parsing. `DocumentVersion` orders events; `DocumentContentStateID` tracks undo/savepoint identity.

### 22.7 Document lifecycle coordinator

One coordinator owns every operation that can change URI, disk content, or open state:

```swift
@MainActor
public final class DocumentLifecycleCoordinator {
    func open(_ uri: DocumentURI, options: OpenOptions) async throws -> DocumentHandle
    func save(_ id: DocumentID, decision: SaveDecision) async throws -> SaveOutcome
    func requestClose(_ ids: [DocumentID], policy: ClosePolicy) async -> CloseOutcome
    func prepareForExternalMutation(_ paths: [URL], reason: ExternalMutationReason) async -> ExternalMutationPermit
    func applyExternalResult(_ receipt: ExternalMutationReceipt) async throws
}
```

Workspace, SCM, search replacement, refactoring, extensions, and workbench never directly discard/close/rename a document.

### 22.8 Workspace transaction engine

The transaction engine coordinates:

- document state and undo checkpoints
- filesystem identities and rollback material
- LSP/resource operations
- SCM external mutations
- watcher suppression/coalescing
- workspace indexes
- workbench tabs/restoration

A transaction receipt is retained for user undo and diagnostics. Startup recovery runs before normal watcher/index activation.

### 22.9 Editor layout and native input

Separate four concerns:

```text
DocumentActor
  text and edit state

EditorSessionActor / @MainActor session
  selections, viewport, folds, decorations, commands

LayoutEngine
  immutable viewport layout snapshots, glyph runs, visual navigation, hit testing

PlatformTextInputAdapter
  NSTextInputClient / UITextInput, IME, accessibility, services
```

The UI must not scan the full document or selection on each callback. Layout snapshots are versioned; stale async results are discarded.

### 22.10 Language and intelligence pipeline

```text
Document event (version N)
   ├─ Tree-sitter ParseSession → syntax/folds/symbols snapshot N
   ├─ LSP DocumentLane → server version N
   ├─ DiagnosticsAggregator → problems tagged N/server generation
   └─ Semantic presentation merge → editor decoration snapshot N
```

Every result carries document version/generation. Merge policy defines syntax versus semantic token precedence and stale-result behavior.

### 22.11 Ghostty terminal architecture

Public facade:

```swift
public protocol TerminalSession: Sendable {
    var id: TerminalSessionID { get }
    func events() async -> TerminalEventSubscription
    func send(_ input: TerminalInputEvent) async throws
    func resize(_ geometry: TerminalGeometry) async throws
    func search(_ query: TerminalSearchQuery) async throws -> [TerminalMatch]
    func close() async
}
```

Production implementation:

```text
TerminalSession facade
  ├─ ProcessSupervisor PTY transport (macOS local)
  ├─ remote byte transport (iOS/macOS remote)
  └─ GhosttySurfaceOwner actor/main-thread bridge
       ├─ pinned C shim
       ├─ Ghostty app/terminal state
       ├─ renderer surface
       ├─ input encoder
       └─ terminal accessibility snapshot
```

No full-screen `String` is the source of truth. Snapshot/export APIs are secondary views of cell/scrollback state.

### 22.12 Swift-first extension architecture

Author API remains Swift:

```swift
@CodeEditorExtension
public struct MyExtension: EditorExtension {
    public func activate(context: ExtensionContext) async throws {
        try await context.languages.register(...)
        try await context.commands.register(...)
    }
}
```

Execution profiles:

| Profile | Authored in | Artifact/runtime | Stable use |
|---|---|---|---|
| built-in Swift | Swift | statically linked | trusted host/first-party |
| data-only | TOML/assets | host parsed | downloadable where platform policy permits |
| native helper | Swift | signed process | trusted macOS direct distribution |
| Swift-Wasm | Swift | `.wasm` | isolated portable procedural extension after containment qualification |
| remote provider | Swift/other server | authenticated remote service | iOS/enterprise/process-restricted hosts |

All profiles use the same value/protocol-level SDK. Runtime-specific types stay internal.

### 22.13 Extension package and activation boundary

```text
untrusted source/archive
   ↓ bounded no-follow inventory
staging bytes
   ↓ canonical signature + manifest + compatibility verification
immutable content-addressed store
   ↓ explicit capability grant / platform policy
activation plan bound to exact package digest
   ↓ runtime driver
capability broker bound to extension ID + generation + handle owner
```

Activation never accepts an unverified path or a plan not bound to the exact immutable digest.

### 22.14 Workbench architecture

Workbench owns orchestration and presentation:

- window/workspace lifecycle
- tabs/splits/navigation history
- navigator/panel layouts
- command/focus contexts
- restoration schema/migration
- user decisions and progress UI
- project/build/test/debug workflows

It does not own raw process launching, Git mutation, terminal emulation, document disk writes, LSP request maps, or extension verification.

---

## 23. Stable-stage implementation roadmap

The phases are dependency ordered. Parallel work is safe only where dependencies are explicitly satisfied.

### Phase 0 — restore truth and reproducibility

**Goal:** make the repository accurately self-describing and produce trustworthy build evidence.

**Implementation tasks**

1. Downgrade `CompatibilityProfile.toml` to current experimental statuses.
2. Replace manually passing scorecards and defect status with CI-generated evidence.
3. Add source-archive clean resolve/build/test job.
4. Require all 29 current products or rationalize/remove nonpublic test products first.
5. Add semantic symbol graph/API digester baselines for every intended public library.
6. Make strict concurrency warnings errors.
7. Move mocks/conformance simulations to test-support targets.
8. Add direct test targets for CLI, Ghostty adapter, WasmKit adapter, language packs, and guest runtimes.
9. Make real Ghostty/LSP/DAP integrations mandatory on release branches.
10. Establish one structured defect register linked to regression tests.

**Exit gate**

- clean exported archive resolves/builds/tests on required platform matrix
- all release checks produce artifacts and cannot pass through authored status strings
- public product catalog and stability labels match source behavior
- no production target contains a default fake implementation

### Phase 1 — document/data-integrity foundation

**Goal:** no silent content loss, corruption, or overwrite.

**Implementation tasks**

1. Add `DocumentContentStateID` and savepoint model.
2. Replace normal save API with conflict-aware request/outcome.
3. remove unsafe provider default bridge.
4. make local saves coordinated and durable, including parent-directory fsync.
5. implement overflow-safe range arithmetic repository-wide.
6. choose/pin equal-offset insertion semantics.
7. remove/deprecate per-edit undo callbacks.
8. redesign recovery record and startup recovery.
9. define metadata/symlink/encoding/large-file policies.
10. centralize document lifecycle.

**Required tests**

- property tests over random edit transactions and Unicode
- save/external-modification races
- injected failure at every write stage
- edit/undo/redo/savepoint state machine model checking
- crash/restart recovery corpus
- binary/non-UTF/permissions/symlink policy fixtures

**Exit gate**

- zero known data-loss P0s
- model-based test confirms content/undo/savepoint invariants
- all save entry points enforce the same conflict contract

### Phase 2 — concurrency, streams, process, and RPC substrate

**Goal:** eliminate duplicated unsafe lifecycle primitives.

**Implementation tasks**

1. Implement `AsyncBroadcastHub` with sequence/gap/replay/finish semantics.
2. Implement `OneShotPromise` and monotonic deadline scheduler.
3. Implement shared framed-RPC engine.
4. Implement `ProcessSupervisor` and `BoundedByteSpool`.
5. migrate Core process API, tasks, Git, LSP, DAP, MCP, native extensions, and terminal transport.
6. remove unbounded/single-consumer public streams.
7. define task/taskbag ownership per service/model/window.
8. reduce and document every `@unchecked Sendable` site.
9. add deterministic test clock and scheduler hooks.

**Required tests**

- response before/after wait registration
- timeout at every lifecycle boundary
- cancellation before send/during send/after response
- late responses and duplicate responses
- stream subscriber churn, overflow, gap recovery, finish
- 100 concurrent processes/requests under resource caps
- Thread Sanitizer and actor reentrancy stress

**Exit gate**

- LSP/DAP/task/process races reproduced by old tests and prevented by new substrate
- no continuation leaks in soak tests
- no correctness-critical consumer shares one raw `AsyncStream`

### Phase 3 — native editor correctness and performance

**Goal:** native-quality AppKit/UIKit editing suitable for sustained use.

**Implementation tasks**

1. Build layout-driven caret navigation and hit testing.
2. validate every native position/range at grapheme/scalar boundaries.
3. implement correct marked-text lifecycle and sub-selection.
4. implement visual selection rectangles by layout fragments.
5. implement BiDi paragraph/writing direction through platform layout.
6. complete firstRect/attributedSubstring contracts.
7. centralize editor error diagnostics; remove silent input failures.
8. implement large-file mode and viewport virtualization.
9. optimize line index/layout/invalidation.
10. build editor accessibility model and actions.

**Required tests**

- CJK/Korean IME manual + UI matrix
- emoji/ZWJ/combining/Indic/BiDi property corpus
- wrapped lines, tabs, folds, variable fonts, very long lines
- selection from 0 bytes to entire 100 MiB file without O(n) UI callback
- VoiceOver/full keyboard/switch control
- latency and memory benchmarks

**Exit gate**

- all native text-input conformance scenarios pass
- no known invalid caret/range state
- defined editor latency/memory budgets pass on reference hardware

### Phase 4 — workspace transaction and lifecycle hardening

**Goal:** safe multi-file/project mutations and recoverable workspace state.

**Implementation tasks**

1. implement typed two-phase workspace transaction coordinator.
2. integrate document savepoints and undo checkpoints.
3. implement durable state journal/startup recovery.
4. unify delete/rename/move/create/refactor/search-replace/LSP edits.
5. preflight dirty descendants before destructive operations.
6. move blocking filesystem work off UI/critical actors.
7. implement descriptor-relative no-follow operations for untrusted boundaries.
8. add snapshot+sequence workspace event stream.
9. implement host-configurable hidden/ignore/generated policies.
10. centralize registry/tab/watcher/index lifecycle.

**Required tests**

- fault injection after every operation/state write
- forced process termination at every journal state
- permissions/symlink/hardlink/sparse/large-directory corpus
- concurrent external changes
- multi-root rename/move conflicts
- workspace undo/redo across documents and filesystem

**Exit gate**

- every mutating workflow uses the transaction coordinator
- restart recovery leaves no ambiguous partial state
- dirty content cannot be discarded by delete/rename/SCM/refactor without explicit decision

### Phase 5 — search, tasks, and SCM correctness

**Goal:** production tooling built on the stable substrate.

**Search tasks**

- Git-compatible ignore corpus verified against `git check-ignore`
- explicit glob grammar and tests
- encoding-aware bounded worker search
- full regex replacement semantics
- exact preview snapshot binding and transaction commit

**Task tasks**

- multicast event subscriptions
- incremental raw-byte decoders
- bounded log spool and UI virtualization
- validated task graph/readiness/problem matchers
- dependency outcomes and cancellation propagation
- Problems entries resolved against versioned snapshots

**SCM tasks**

- per-repository actor and stable identity
- complete index/worktree/conflict status model
- credential broker/askpass/keychain integration or explicit non-support
- dirty-buffer coordination for all destructive operations
- Git-generated/check-validated hunk operations
- watcher refresh and progress/cancellation

**Exit gate**

- real Git fixture suite passes across status/rename/copy/conflict/binary/unicode/worktree cases
- multi-file replacement is atomic/recoverable
- task output/readiness/problems remain correct under arbitrary byte chunking and multiple subscribers

### Phase 6 — LSP and language intelligence

**Goal:** reliable real-server editing intelligence.

**Implementation tasks**

1. migrate to shared RPC engine.
2. implement one document synchronization lane per server/document.
3. detect stream/version gaps and full-resync.
4. complete negotiated incremental/full sync.
5. complete WorkspaceEdit/resource operations and transaction preview.
6. implement complete JSON values and dynamic registration ownership.
7. version diagnostics, semantic tokens, symbols, inlay hints, code lens, and stale-result handling.
8. implement provider/session restart and backoff policy.
9. run real SourceKit-LSP/clangd fixtures.
10. establish latency/cancellation/backpressure metrics.

**Exit gate**

- no pending-request leaks/races in deterministic stress
- real servers pass lifecycle and feature matrix
- external/multi-session edits cannot desynchronize server without detection/recovery

### Phase 7 — DAP/debugging

**Goal:** complete, recoverable debugger sessions.

**Implementation tasks**

1. migrate to shared RPC engine.
2. implement explicit session state machine.
3. reconcile requested/verified breakpoints.
4. implement reverse request errors and bounded concurrency.
5. integrate real Ghostty-backed `runInTerminal`.
6. complete threads/stack/scopes/variables/evaluate/output/source mapping.
7. build workbench breakpoint/debug/console/variables UI.
8. run `lldb-dap` fixture and malformed/crash fixtures.

**Exit gate**

- real launch/attach/breakpoint/step/inspect/terminate flow passes
- adapter crash/hang/malformed response never corrupts editor/workspace state
- no debugger session resources survive teardown

### Phase 8 — Ghostty terminal

**Goal:** one real Ghostty-backed terminal product.

**Implementation tasks**

1. decide/pin the exact upstream Ghostty surface API.
2. implement narrow C compatibility shim.
3. make linked library mandatory in release builds.
4. remove byte spool from production.
5. integrate actual Ghostty state/render surface.
6. implement native event-to-Ghostty input mapping.
7. use shared process supervisor/PTY and raw-byte path.
8. implement scrollback/search/selection/hyperlink/clipboard policy.
9. implement terminal tabs/splits/restoration and task/debug association.
10. implement terminal accessibility.
11. remove/deprecate legacy custom VT public types.

**Exit gate**

- real Ghostty linked in every release artifact
- terminal conformance/soak/input/accessibility matrix passes
- no snapshot text view or custom VT parser on production path

### Phase 9 — extension package, broker, and Wasm security

**Goal:** downloadable extensions cannot escape declared capabilities or corrupt host state.

**Implementation tasks**

1. adopt standards-compliant TOML and versioned manifest schema.
2. implement canonical full-package signed statement.
3. include hidden files; move host state outside package root.
4. implement content-addressed crash-durable installation.
5. bind activation plan to exact digest.
6. implement signed/fresh revocation and atomic rollback.
7. bind broker handles to caller extension/generation.
8. replace weak payload defaults with typed strict schemas.
9. implement descriptor-relative worktree/file access.
10. implement bounded streaming download/npm artifact resolver.
11. harden native helper process profile.
12. implement hard Wasm interruption/memory/resource limits, or move Wasm execution to killable helper process.
13. move simulations/mocks to test support.
14. run adversarial corpus and penetration review.

**Exit gate**

- full threat-model suite passes
- package update/revoke/crash/restart cannot activate unverified bytes
- cross-extension handles fail
- pure infinite Wasm loop and memory bomb are contained
- every capability is deny-by-default and audit logged

### Phase 10 — integrated Xcode-class workbench

**Goal:** turn stable services into coherent IDE workflows.

**Implementation tasks**

1. project/build graph, schemes/configurations/destinations abstraction.
2. structured build log and Problems integration.
3. test navigator/plans/results/coverage.
4. source control navigator, diff/merge/conflict workflows.
5. debug navigator, breakpoints, variables, console.
6. terminal tabs/splits and task/debug integration.
7. search navigator with replacement preview/conflicts.
8. source/symbol navigation history and Open Quickly.
9. inspectors/settings/package dependencies appropriate to the host.
10. multi-window restoration schema and migration.
11. extension contribution placement through declarative host surfaces.
12. complete keyboard/focus/accessibility model.
13. optional preview/canvas provider architecture.

**Exit gate**

- every advertised workflow has an end-to-end UI test and service integration test
- restoration survives force quit/version migration
- no panel is a placeholder or fake data source in the Stable profile

### Phase 11 — Beta hardening

**Goal:** feature-complete Stable scope under real usage.

**Tasks**

- freeze Stable 1.0 feature scope
- no new public API except blocker fixes
- dogfood on real medium/large Swift repositories
- telemetry/diagnostic opt-in design
- crash reports and recovery UX
- performance regression dashboard
- dependency/upstream update rehearsals
- migration from current manifests/store/restoration formats
- documentation/sample review
- localization and accessibility review
- security review and threat-model sign-off

**Beta exit gate**

- no open P0; no unowned P1
- no flaky required test over a defined repetition count
- real-tool soak passes
- all migration/recovery rehearsals pass

### Phase 12 — RC and Stable

**RC criteria**

- public API frozen through semantic API baseline
- no open P0/P1
- all required jobs hard green on release commit and exported archive
- release artifacts reproducible and signed
- performance/accessibility/security evidence complete
- dependency licenses/notices complete
- upgrade and rollback rehearsal complete
- release notes accurately list unsupported/experimental surfaces

**Stable criteria**

- RC used in real host applications without unresolved critical regressions
- support/deprecation policy published
- compatibility matrix published from CI
- extension SDK/runtime versions and capability policy fixed for the release line
- all public products either Stable or explicitly excluded/Experimental; no test fixture is misrepresented as a Stable product

---

## 24. CI and release-gate redesign

### 24.1 Required job matrix

| Job | Required platforms/tools | Purpose | Hard release gate |
|---|---|---|---|
| source archive | clean macOS runner, empty caches | export source, verify no missing generated/local content | yes |
| package resolve | empty SwiftPM caches | prove dependency graph/bootstrap | yes |
| macOS debug/release | oldest supported + current pinned Xcode | compile all libraries/executables/examples | yes |
| iOS simulator | iOS 18 + latest supported | compile and run unit/UI examples | yes |
| strict concurrency | Swift 6 complete + warnings as errors | concurrency correctness | yes |
| semantic API diff | all public libraries | source/ABI contract review | yes |
| unit/property | all test targets | deterministic correctness | yes |
| sanitizer | ASan, TSan, UBSan where supported | memory/race/undefined behavior | yes for scheduled/release |
| fuzz/property | framing, CBOR/TOML, ranges, archives, ignores | adversarial parsing/state | yes for release corpus |
| document fault | save/recovery/transaction fault injection | no content loss | yes |
| workspace crash recovery | subprocess kill at journal boundaries | durable transactions | yes |
| real LSP | SourceKit-LSP and clangd | protocol behavior | yes |
| real DAP | lldb-dap fixture | debugger behavior | yes |
| real Ghostty | pinned library built/linked | terminal state/render/input | yes |
| Wasm hostile | process-isolated malicious guests | containment | yes |
| extension security | signed/tampered/revoked/update/crash corpus | supply-chain boundary | yes |
| real Git | fixture repositories | SCM behavior | yes |
| editor UI | XCUI/macOS UI | IME-adjacent flows, keyboard, accessibility | yes |
| performance | named reference hardware | latency/memory regression | yes |
| soak | long-running real services | leak/lifecycle stability | yes for RC |
| docs/examples | DocC, sample builds, code snippets | developer experience | yes |
| license/SBOM | dependencies, grammars, Ghostty | distribution compliance | yes |

### 24.2 No soft skips in release jobs

Release jobs must fail when:

- Ghostty cannot build/link
- a real LSP/DAP executable is absent
- coverage/benchmark export fails
- a required platform runtime is missing
- a required test is skipped
- a sanitizer cannot start
- an evidence artifact is absent

Optional behavior belongs only in pull-request convenience jobs and must be clearly labeled nonqualifying.

### 24.3 Semantic API gate

For every intended Stable product:

1. emit symbol graphs for the current commit
2. compare to the last Stable baseline
3. classify compatible additions versus source/binary breaks
4. require explicit migration note and semver decision for breaks
5. include actor isolation and Sendable changes
6. fail when a public mock/internal type leaks into the graph

### 24.4 Coverage policy

Do not use one repository percentage as the only metric. Require:

- critical branch/state coverage for document/save/recovery/transactions/RPC/Wasm/security
- direct target ownership for every public product
- mutation score for selected pure logic modules
- integration scenario coverage for external tools
- zero unreviewed test skips

Coverage export failure is a gate failure, not `|| true`.

### 24.5 Defect evidence

A closed defect entry should contain:

```json
{
  "id": "DOC-N02",
  "severity": "P0",
  "status": "fixed",
  "fixed_commit": "...",
  "regression_tests": [
    "DocumentSaveConflictTests.externalModificationBlocksNormalSave",
    "WorkspaceCloseTests.saveConflictKeepsTabOpen"
  ],
  "evidence_artifacts": ["job/.../test-results.json"]
}
```

The gate verifies test discovery and results. It does not trust the status string alone.

### 24.6 Performance evidence format

Each benchmark artifact records:

- commit
- exact Xcode/Swift/OS
- machine model/CPU/RAM/device
- dataset hash
- warm/cold state
- repetitions
- p50/p95/p99/max
- peak resident memory
- allocations where available
- comparison baseline and allowed regression

### 24.7 Flake policy

- required tests are never automatically rerun to hide the first failure
- reruns may diagnose, but the job remains failed
- flaky tests enter a visible quarantine with owner and deadline; quarantined tests cannot provide release evidence
- deterministic clocks/transports should replace sleeps wherever possible

### 24.8 Release evidence bundle

Generate one immutable bundle:

```text
ReleaseEvidence/<commit>/
  manifest.json
  toolchain.json
  package-graph.json
  builds/
  tests/
  api-diff/
  coverage/
  sanitizers/
  fuzz/
  performance/
  accessibility/
  integrations/{ghostty,lsp,dap,git,wasm}/
  security/
  licenses/
  sbom/
  known-limitations.md
```

The compatibility profile and product scorecards are generated from this bundle.

---

## 25. Comprehensive test plan

### 25.1 Core edit property tests

Generate random Unicode documents and transactions. Verify:

- atomicity: failure leaves text, attributes, version, state ID, selection, and undo unchanged
- applying generated inverse restores exact prior snapshot
- undo/redo state machine matches a reference model
- nonoverlap/order behavior is deterministic
- UTF-16/UTF-8/String.Index conversions round-trip only on valid boundaries
- no overflow/trap for arbitrary `Int` ranges
- line index agrees with a slow reference implementation
- line-ending transformations are reversible under policy

Run seeds as persistent regression corpus.

### 25.2 Document I/O and recovery

Fixture matrix:

- UTF-8/UTF-16 LE/BE/BOM/no BOM and explicitly supported encodings
- LF/CRLF/CR/mixed endings
- empty, very long line, huge file, invalid byte sequence
- read-only file and directory
- permissions/ACL/xattrs according to declared support
- symlink target and symlink replacement attack
- external edit/delete/move between load/check/write
- disk full, permission loss, interrupted write, failed fsync, failed rename, failed directory fsync
- crash after each journal/write phase
- corrupted/truncated recovery record
- multiple recovery records/quota pressure

Assertions include content, identity, dirty state, recovery visibility, metadata, and no orphan temp files.

### 25.3 Workspace transaction model testing

Build a reference in-memory filesystem/document model. Generate operation sequences:

- create file/directory
- edit text
- rename/move
- delete
- LSP resource edit
- search replacement
- extension workspace edit
- conflict/external mutation

Inject failure after every step and compare real final state to either the fully committed or fully rolled-back reference state. Then repeat with process termination and startup recovery.

### 25.4 Stream/broadcast tests

For every event hub:

- subscribers before/after publish
- 1, 2, 100 subscribers
- slow and cancelled subscribers
- independent overflow policies
- sequence/gap behavior
- replay/snapshot semantics
- finish and producer deallocation
- no cross-subscriber event stealing
- bounded memory under flood

### 25.5 RPC lifecycle tests

Use a deterministic transport/test clock and permute:

- response before send returns
- response immediately after pending registration
- timeout before/after send
- cancellation before/during/after send
- send failure
- duplicate response
- unknown/late response
- malformed frame/body
- transport close with many pending
- server/reverse request that hangs
- request ID exhaustion/wrap policy

Assert exactly-once completion and zero pending records/tasks afterward.

### 25.6 Process supervisor tests

- executable/cwd/env validation
- stdout/stderr arbitrary chunking
- split UTF-8 and raw binary output
- large output/spool truncation
- child process/fork group cancellation
- graceful then forced termination
- exit versus signal versus cancellation reporting
- concurrent writes
- PTY resize storms
- descriptor leak counts
- process spawn failure at each setup step
- shell capability separation

### 25.7 Native editor test matrix

#### Unicode and IME

- all scenarios in UI-N06
- caret left/right by grapheme and visual direction
- word/subword movement for code identifiers
- delete backward/forward around composed sequences
- selection extension and affinity
- multi-cursor edits with IME policy

#### Layout

- wrapped lines
- tabs and indentation guides
- folds and hidden ranges
- proportional/monospaced fallback glyphs
- bidi mixed lines
- extremely long lines
- annotations/inlay hints/diagnostics
- viewport resize and scale changes

#### Platform behavior

- copy/paste, rich/plain paste policy
- drag/drop
- Services/Writing Tools where supported
- context menus
- dictation
- hardware keyboard commands
- accessibility hierarchy and actions

### 25.8 Tree-sitter/language tests

For each grammar:

- load/unload and ownership token
- representative valid/invalid source
- incremental edit equivalence to full reparse
- query compile/capture golden output
- injection/fold/indent/textobject behavior where shipped
- Unicode byte-offset conversion
- stale generation discard
- cancellation and rapid language switch
- memory lifetime/leak stress

### 25.9 Search tests

- compare ignore results with Git across a golden repository
- glob grammar fixtures
- regex capture/named capture/escape/zero-length replacements
- arbitrary byte chunk/encoding boundaries
- cancellation and limits
- preview then external edit conflict
- multi-file transaction rollback/recovery
- symlink/cycle/permission/hidden/generated policies
- metrics accuracy

### 25.10 Task/problem tests

- DAG success/failure/cancel/skip
- cycle detection
- exclusive groups
- readiness across split chunks and stdout/stderr
- invalid definitions fail before launch
- compiler matcher paths with spaces/unicode/relative roots
- line/column conversion against exact snapshots
- multiple subscribers receive identical ordered events
- long build log and UI virtualization

### 25.11 SCM tests

Create real temporary repositories for:

- untracked/ignored/staged/unstaged/both
- rename/copy/delete/typechange
- merge conflicts and stages
- unicode/quoted paths
- spaces/newlines in names if supported
- executable mode and symlink
- submodule
- branch switch with open clean/dirty documents
- discard/stage selected hunk
- binary/no-newline patches
- concurrent operations
- auth callback fixture without logging secret

Compare status with Git porcelain output and verify filesystem/document coordination.

### 25.12 LSP tests

#### Mock protocol

- all RPC lifecycle permutations
- capability negotiation
- document lane gaps/resync
- dynamic registration
- diagnostics/semantic token staleness
- WorkspaceEdit/resource operations
- malformed/nonconforming server

#### Real servers

SourceKit-LSP and clangd end-to-end scenarios, including edits during requests, cancellation, server restart, and multi-root workspace.

### 25.13 DAP tests

#### Mock adapter

- state transitions and malformed behavior
- reverse requests
- breakpoint reconciliation
- concurrent events/responses
- cancellation/timeout/crash

#### Real adapter

Compile a fixture, stop on a line, inspect a known variable, evaluate an expression, step, continue, and terminate. Verify Ghostty-backed `runInTerminal` when requested.

### 25.14 Ghostty tests

Run the real linked library; the spool fallback is not accepted. Include official/upstream-compatible VT/input fixtures, stress, screenshots/golden cell state where appropriate, and platform UI/accessibility tests.

### 25.15 Extension package/security tests

- valid signed package
- hidden added/removed/modified file
- `.codeeditor` injection
- symlink/special file/hardlink policy
- path traversal/normalization collisions/case collisions
- duplicate manifest keys/invalid TOML
- oversized file/count/depth/path
- publisher/key/digest/version mismatch
- revoked/expired/unknown key
- stale revocation rollback
- install crash at every transaction phase
- same-version different bytes
- active pointer corruption
- store path escape
- rollback to prior version
- capability grant changes

### 25.16 Broker adversarial tests

- Extension A uses Extension B’s handle: must fail for every method
- stale generation handle
- forged UUID
- malformed JSON/CBOR/base64
- worktree symlink swap
- allowlist prefix confusion
- executable replacement
- redirect to HTTP/disallowed host/path
- oversized download and false `Content-Length`
- scoped npm package and nested quota
- settings/storage quota/rate/key attacks
- process/output flood and revoke during execution

### 25.17 Wasm hostile tests

Run each fixture in an isolated helper test process. The harness has an outer kill timeout and reports whether the runtime itself contained the guest. Include the corpus in WASM-N16.

### 25.18 Workbench/UI end-to-end tests

- launch/open workspace/file
- edit/save/conflict/recover
- tabs, preview/pin, splits, navigation history
- search and transactional replacement
- task/build/problem navigation
- SCM status/diff/stage/commit/branch conflict decisions
- LSP completion/definition/rename/code action
- DAP breakpoint/debug/terminal
- terminal tabs/input/resize/restoration
- extension install/enable/disable/update/revoke/contributions
- force quit and restoration migration
- keyboard-only and accessibility workflows

---

## 26. Proposed performance and resource budgets

These are **initial engineering budgets**, not measurements of the current repository. Calibrate them on named reference hardware and adjust deliberately. A feature may define stricter budgets.

### 26.1 Editor

| Scenario | Initial budget |
|---|---|
| ordinary keystroke document mutation | p95 ≤ 4 ms on reference Mac |
| end-to-end visible keystroke frame | p95 ≤ one 60 Hz frame; no sustained dropped frames |
| caret/selection command | p95 ≤ 8 ms |
| scroll/layout visible viewport | p95 ≤ one frame after warmup |
| open 1 MiB source to editable viewport | ≤ 250 ms warm dependency cache |
| open 10 MiB source to first viewport | ≤ 1 s, with deferred intelligence |
| memory for 10 MiB plain document | bounded and documented; no multi-copy spikes proportional to every subsystem |
| large selection geometry | proportional to visible fragments, not selected UTF-16 length |

### 26.2 Language intelligence

| Scenario | Initial budget |
|---|---|
| Tree-sitter incremental parse for small edit | p95 ≤ 20 ms for typical source |
| syntax highlight visible viewport | p95 ≤ 33 ms |
| stale parse/LSP result | discarded with no UI flash |
| completion request cancellation | pending work removed within 100 ms plus transport constraints |
| diagnostics memory | bounded by document/result policy |

### 26.3 Search/tasks/SCM

- first search result should stream without waiting for full traversal
- cancellation should stop new file work promptly
- task/terminal logs must have fixed memory caps and disk spool caps
- Git status refresh should be incremental/debounced and not block editor interaction
- all counters and truncations are observable

### 26.4 Terminal

- no output byte loss under supported throughput
- bounded renderer latency under sustained output
- resize/input remains responsive during output flood
- 100 MiB soak does not grow memory without bound
- scrollback cap and storage policy are explicit

### 26.5 Extension runtime

- activation deadline and memory cap per runtime profile
- capability call/request rate limits
- package install limits for files/bytes/depth/time
- no unbounded log/event queue
- hostile guest containment deadline measured independently of guest cooperation

---

## 27. Security threat model and required controls

### 27.1 Assets

- user source files and unsaved buffers
- credentials, tokens, signing keys, keychain data
- workspace/project metadata
- build/test/debug processes
- extension package store and trust decisions
- terminal/clipboard/history
- source control state
- host application integrity and availability

### 27.2 Adversaries

- malicious downloaded extension
- compromised publisher/update server
- tampered package after signing
- malicious workspace/repository filenames/symlinks/configuration
- hostile LSP/DAP/MCP/process output
- malformed archive/TOML/JSON/CBOR/Wasm
- local concurrent process changing files during validation
- accidental buggy trusted extension

### 27.3 Mandatory controls

- fail-closed policy defaults
- canonical signed full-package inventory and publisher statement
- content-addressed immutable store
- caller-bound generation-scoped capability handles
- descriptor-relative no-follow file access
- executable/download/npm allowlists with component-aware matching
- strict request schemas and size/rate limits
- hard process/Wasm containment
- revocation freshness and immediate deactivation
- secret redaction and bounded logs
- transaction/recovery integrity
- explicit trusted versus untrusted UI contribution model
- platform-specific execution policy

### 27.4 Platform profiles

| Profile | Local process | Native extension helper | Wasm | Downloaded data contributions | Remote provider |
|---|---:|---:|---:|---:|---:|
| direct macOS | host policy | signed/trusted | after containment | yes under policy | yes |
| Mac App Store | host/review dependent | generally constrained | host/review dependent | host/review dependent | yes |
| iOS | no arbitrary local process | no | technical capability does not itself establish distribution approval | data-only under host/review policy | yes |
| enterprise/internal | managed policy | managed signed | managed | managed | managed |
| tests | fixtures only | fixtures | hostile corpus | fixtures | mock/local server |

The framework exposes policy; each host app remains responsible for its distribution/entitlement/review strategy.

### 27.5 Security review gate

Before extension runtime Stable:

- independent design review of signing/store/broker/Wasm/process boundaries
- adversarial code review of all `@unchecked Sendable`, C, POSIX, cryptographic, and path operations
- fuzz corpus with sanitizer execution
- documented response process for compromised publisher/revocation/runtime vulnerability
- reproducible key rotation and emergency disable rehearsal

---

## 28. Recommended implementation sequence by pull request

Keep each pull request narrow enough to review and bisect. The order below prevents feature work from being built on unsafe primitives.

### Foundation and release truth

1. **PR-01: Correct maturity metadata.** Downgrade compatibility profile, remove manual RC claims, list all known P0/P1 findings.
2. **PR-02: Product catalog rationalization.** Move `ConformanceExtensionGuest`, mocks, linked-guest simulation, and testing adapters into test-support targets; decide which 1.0 products are public.
3. **PR-03: Clean archive CI.** Empty-cache resolve/build all products/examples/executables from an exported archive.
4. **PR-04: Semantic API baselines.** Symbol graphs/API digester for every intended public library.
5. **PR-05: Evidence-driven release manifest.** Generate scorecards/compatibility/defect evidence from CI artifacts.

### Documents and I/O

6. **PR-06: Content state IDs and savepoints.** Separate synchronization version from content-state identity; fix clean-after-undo.
7. **PR-07: Deterministic equal-offset edits.** Define semantics, simplify comments/tests, add property tests.
8. **PR-08: Atomic-only undo API.** Remove/deprecate per-edit callbacks; integrate undo checkpoints.
9. **PR-09: Unified conflict-aware save.** Remove unsafe bridge and update every caller.
10. **PR-10: Durable local file I/O.** streaming hash/read, coordinated identity, fsync parent, metadata policy, fault injection.
11. **PR-11: Recovery format and startup recovery.** versioned checksummed record, quota/index, corruption handling.
12. **PR-12: Repository-wide safe range arithmetic.** shared checked offset/range helpers and fuzz tests.

### Async/process/RPC substrate

13. **PR-13: AsyncBroadcastHub.** Migrate one low-risk stream first, then add conformance suite.
14. **PR-14: BoundedByteSpool and incremental decoders.** raw bytes, paging, truncation metrics.
15. **PR-15: ProcessSupervisor.** migrate Core process service; atomically establish process groups; nonblocking cancellation.
16. **PR-16: OneShotPromise/deadline scheduler.** deterministic exactly-once completion primitive.
17. **PR-17: FramedRPCConnection.** generic framing/codec engine and lifecycle tests.
18. **PR-18: Migrate LSP RPC.** remove early-response cache and child registration tasks.
19. **PR-19: Migrate DAP/MCP/extension RPC.** one shared behavior and tests.
20. **PR-20: Strict concurrency ratchet.** warnings as errors; per-site `@unchecked Sendable` evidence.

### Native editor and workspace

21. **PR-21: Layout-driven text positions.** validated native positions, grapheme navigation, visual movement.
22. **PR-22: IME/BiDi/selection geometry.** complete platform adapters and test fixtures.
23. **PR-23: large-file/viewport architecture.** visible-fragment layout and explicit feature policy.
24. **PR-24: DocumentLifecycleCoordinator.** route save/close/move/delete/external mutations through one owner.
25. **PR-25: typed workspace transaction plan.** canonical preflight and one rollback owner per resource.
26. **PR-26: durable transaction journal/recovery.** restart tests and workspace undo receipt.
27. **PR-27: background workspace index/watcher stream.** lazy tree and gap-aware events.

### Tooling

28. **PR-28: Search ignore/glob engine.** Git parity corpus and separate glob grammar.
29. **PR-29: Search replacement engine.** full capture semantics and snapshot-bound preview.
30. **PR-30: Tasks on ProcessSupervisor/BroadcastHub.** correct decoding, readiness, DAG outcomes, log spooling.
31. **PR-31: SCM repository actor/status model.** index/worktree/conflict representation and real repo tests.
32. **PR-32: SCM dirty-buffer/auth/patch workflow.** lifecycle coordinator, askpass/keychain, Git-validated hunks.
33. **PR-33: Tree-sitter ParseSession.** one actor-owned state path and ownership tokens.
34. **PR-34: all-grammar conformance generator.** queries, incremental edits, provenance, memory/performance.
35. **PR-35: LSP document lanes and full WorkspaceEdit.** gaps/resync/save/close ordering and transaction integration.
36. **PR-36: real LSP fixtures.** SourceKit-LSP and clangd hard gates.
37. **PR-37: DAP session state and complete model.** breakpoints/threads/stack/scopes/variables/evaluate.
38. **PR-38: real `lldb-dap` fixture and workbench debug integration.** hard gate.

### Ghostty

39. **PR-39: Ghostty integration ADR and upstream pin contract.** exact APIs, build reproducibility, license, update policy.
40. **PR-40: real linked C shim and terminal-state owner.** remove release fallback.
41. **PR-41: real Ghostty render surface.** replace text snapshot UI.
42. **PR-42: native input/event mapping and terminal accessibility.** keyboard/mouse/paste/selection/clipboard policies.
43. **PR-43: PTY transport migration to ProcessSupervisor.** raw bytes, exit, resize, cancellation.
44. **PR-44: terminal conformance/soak tests.** real library mandatory.
45. **PR-45: remove legacy custom VT public path.** migration deprecations and DAP/tasks integration.

### Extensions and Wasm

46. **PR-46: standards-compliant TOML + schema validation.** strict manifest errors and compatibility levels.
47. **PR-47: canonical signed statement/full inventory.** hidden files/publisher/manifest/version binding.
48. **PR-48: immutable content-addressed store.** bounded staging and exact digest paths.
49. **PR-49: crash-durable install/update/rollback/recovery.** journal/pointer fsync and same-version handling.
50. **PR-50: revocation freshness and activation filter.** immediate driver shutdown and snapshot rebuild.
51. **PR-51: caller-bound capability handles and strict wire schemas.** cross-extension adversarial tests.
52. **PR-52: descriptor-relative workspace/storage operations.** path race hardening.
53. **PR-53: streaming download/tool artifact resolver.** HTTPS redirects, digest, quotas, immutable cache.
54. **PR-54: Wasm runtime serialization and ABI validation.** required exports/memory/value types/deallocation.
55. **PR-55: per-request clocks/quotas/cancellation IDs.** remove session deadline/global cancel.
56. **PR-56: hard Wasm containment.** engine metering or killable helper process.
57. **PR-57: hostile Wasm and native-helper corpus.** process-isolated hard gate.
58. **PR-58: Swift extension SDK conformance samples.** built-in/native/Wasm/remote equivalent behavior.

### Workbench and release hardening

59. **PR-59: workbench lifecycle task scopes and restoration schema.** multi-window migration/force-quit recovery.
60. **PR-60: integrated navigator/panel workflows.** real Problems/search/SCM/tasks/terminal/debug state.
61. **PR-61: build/project/test service abstractions.** bounded Stable 1.0 scope.
62. **PR-62: complete keyboard/focus/accessibility model.** XCUI/manual protocol.
63. **PR-63: performance benchmark suite/dashboard.** hard budgets.
64. **PR-64: sanitizer/fuzz/soak release jobs.** no soft skips.
65. **PR-65: API/documentation freeze and migration guides.** Stable 1.0 candidate.
66. **PR-66: RC evidence bundle and upgrade/rollback rehearsal.** release sign-off.

---

## 29. Definition of done for every production change

A change is not complete until all applicable items are satisfied:

### Correctness

- public behavior and failure semantics documented
- invalid/untrusted input validated before mutation
- operation is atomic or its partial behavior is explicitly modeled
- state machine transitions are enumerated
- no error hidden with `try?` without a documented reason and metric
- no `fatalError` reachable from external/user/extension/protocol input

### Concurrency/lifecycle

- one owner for mutable state
- task owner and cancellation path identified
- deadline uses monotonic time
- continuation completes exactly once
- stream buffering/broadcast/finish/gap policy declared
- shutdown releases tasks, descriptors, observers, continuations, and registrations
- `@unchecked Sendable` has synchronization proof and stress test

### Persistence/security

- write/transaction durability level defined
- startup recovery defined
- path/symlink/race behavior defined
- quotas and resource limits enforced
- trust/capability decision fail closed
- logs avoid secrets and are bounded

### Testing

- positive, negative, cancellation, timeout, malformed, and fault-injection tests
- regression test linked to defect
- direct tests in the owning target
- real integration test when an external runtime/tool is claimed
- performance impact measured for hot paths

### API/documentation

- semantic API diff reviewed
- availability and Sendable/actor isolation correct
- no implementation dependency leaked
- sample and DocC updated
- migration/deprecation path included for breaking changes

---

## 30. Promotion checklists

### 30.1 Pre-alpha → Alpha

- [ ] public/internal maturity metadata agrees
- [ ] clean archive builds/tests on supported platform matrix
- [ ] no open content-loss/overwrite P0
- [ ] document savepoint and conflict model complete
- [ ] workspace destructive operations preflight dirty documents
- [ ] shared broadcast/process/RPC substrate in use for correctness-critical paths
- [ ] no default fake Ghostty/Wasm/isolation path represented as production
- [ ] strict concurrency warnings are errors
- [ ] test fixtures/mocks removed from production public API
- [ ] every Alpha product has direct tests and a defined scope

### 30.2 Alpha → Beta

- [ ] Stable 1.0 feature scope frozen
- [ ] native editor IME/Unicode/BiDi/accessibility matrix passes
- [ ] workspace transaction crash recovery passes
- [ ] search/tasks/SCM real fixtures pass
- [ ] real SourceKit-LSP/clangd and lldb-dap gates pass
- [ ] real linked Ghostty terminal passes conformance and soak
- [ ] extension package/store/broker/Wasm threat-model suite passes for Beta-enabled profiles
- [ ] no open P0; all P1 have owners and Beta-blocking policy
- [ ] dogfood hosts can recover from crashes and conflicts without manual file repair

### 30.3 Beta → RC

- [ ] no open P0/P1 in Stable scope
- [ ] semantic public API frozen
- [ ] all release jobs hard green with zero required skips
- [ ] performance budgets pass on named hardware
- [ ] sanitizer/fuzzer/soak results pass
- [ ] accessibility sign-off complete
- [ ] migration from current package/store/restoration formats rehearsed
- [ ] extension key rotation/revocation/emergency disable rehearsed
- [ ] dependency licenses/SBOM/reproducible artifacts complete
- [ ] known limitations accurately published

### 30.4 RC → Stable

- [ ] RC used by representative host applications/workspaces
- [ ] no unresolved critical regression from RC usage
- [ ] release evidence bundle immutable and signed
- [ ] support, compatibility, deprecation, and security-response policies published
- [ ] every public product has an explicit Stable/Experimental status; no ambiguous global claim
- [ ] installation and rollback of the release itself rehearsed

---

## 31. Stable exit criteria by product family

### Editing foundation

Applies to Core, Documents, View, LanguageSupport, TreeSitter, language packs.

- no invalid Unicode position can mutate unrelated content
- save/undo/recovery invariants pass model tests
- editor native input and accessibility pass platform matrix
- parsing/layout are versioned, cancellable, off critical UI paths, and bounded
- all grammars have generated conformance evidence

### Workspace/workbench

- all destructive/multi-file mutations use typed transaction engine
- startup recovery handles interrupted mutations and restoration
- tab/pane/window lifecycle has no unowned task/token/observer
- every advertised panel/navigator uses production data and real workflow
- keyboard/focus/accessibility complete

### Tooling

Applies to Search, Tasks, SCM, LSP, DAP.

- uses shared broadcast/process/RPC primitives
- real external tools/repositories are hard-gated
- dirty documents and content versions are coordinated
- cancellation/timeout/late response cannot leak or corrupt state
- logs/results are bounded and stale results discarded

### Terminal

- release artifact contains real pinned Ghostty integration
- no fallback byte spool/custom VT production path
- real renderer/input/accessibility behavior
- PTY/remote lifecycle safe and bounded
- tasks/debugger use the same terminal service

### Extensions

Applies to ExtensionAPI, Protocol, Guest, Wasm, Extensions, Host, CLI.

- Swift author API is versioned and runtime-neutral
- package syntax/schema conformance is precise
- immutable signed package/install/revocation path is crash-durable
- capability handles are caller-bound and deny by default
- native helper and Wasm containment proven under hostile corpus
- runtime equivalence tests for built-in/native/Wasm/remote profiles
- CLI package/sign/verify/publish workflows have golden tests

---

## 32. Immediate engineering priorities

The first implementation focus should be limited to these items until they are green:

1. correct status/evidence gates
2. content-state savepoints and conflict-aware normal save
3. shared multicast stream and process supervisor
4. race-free shared RPC engine
5. workspace transaction/recovery redesign
6. real mandatory Ghostty integration plan and removal of release fallback
7. extension full-package signing, immutable store, caller-bound broker handles
8. hard Wasm containment

Do not add new public extension capabilities, new workbench panels, or additional Xcode-like visual features before those foundations are complete. New surface area would multiply unstable contracts and make API freeze harder.

---

## 33. Audit command/evidence appendix

### 33.1 Package and source inventory

```bash
sha256sum CodeEditorView-new.zip
swift package dump-package
find Sources -type f -name '*.swift' | wc -l
find Sources -type f -name '*.swift' -print0 | xargs -0 wc -l
find Tests -type f -name '*.swift' | wc -l
find Tests -type f -name '*.swift' -print0 | xargs -0 wc -l
```

Observed:

```text
archive SHA-256: 834ff453b4c7e4a5cb13918036ac8b6185595c2ce12a378a77f15d657668778d
products: 29
source Swift files: 369
source Swift LOC: 68,816
test Swift files: 130
test Swift LOC: 18,570
```

### 33.2 Static risk inventory

```bash
rg -o 'try\?' Sources -g '*.swift' | wc -l
rg -o 'fatalError\(' Sources -g '*.swift' | wc -l
rg -o 'precondition\(' Sources -g '*.swift' | wc -l
rg -o '@unchecked Sendable' Sources -g '*.swift' | wc -l
rg -o 'Task\s*\{' Sources -g '*.swift' | wc -l
rg -o 'AsyncStream' Sources -g '*.swift' | wc -l
```

Observed counts are listed in Section 2. These are review signals, not automatic defects.

### 33.3 Package resolution attempt

```bash
swift package resolve
```

Stopped before compilation because the environment could not restore remote dependencies and had a stale/missing SwiftPM cache checkout. Therefore this report does not claim a complete build/test result.

### 33.4 Repository scripts executed

The successful scripts are listed in Section 2.4. Their output was reviewed together with their implementation; a passing script is not treated as proof when the script only validates declarations.

### 33.5 Important source locations reviewed

- `Package.swift`
- `README.md`
- `.github/workflows/ci.yml`
- `Docs/Architecture/CompatibilityProfile.toml`
- `Docs/Architecture/scorecards/products.toml`
- `Docs/Architecture/DEFECTS.md` / structured defect data
- `Sources/CodeEditorCore/Document/DocumentStore.swift`
- `Sources/CodeEditorCore/Undo/UndoCoordinator.swift`
- `Sources/CodeEditorCore/Platform/ProcessService.swift`
- `Sources/CodeEditorDocuments/TextDocument.swift`
- `Sources/CodeEditorDocuments/DocumentContentProvider.swift`
- `Sources/CodeEditorDocuments/DocumentIO/*`
- `Sources/CodeEditorWorkspace/*`
- `Sources/CodeEditorCommands/*`
- `Sources/CodeEditorView/*`
- `Sources/CodeEditorWorkbench/*`
- `Sources/CodeEditorTreeSitter/*`
- `Sources/CodeEditorLanguageSupport/*`
- `Sources/CodeEditorSearch/*`
- `Sources/CodeEditorTasks/*`
- `Sources/CodeEditorSourceControl/*`
- `Sources/CodeEditorLSP/*`
- `Sources/CodeEditorDAP/*`
- `Sources/CodeEditorTerminal/*`
- `Sources/CodeEditorTerminalGhostty/*`
- `Sources/CGhosttyShim/*`
- `Sources/CodeEditorExtensionAPI/*`
- `Sources/CodeEditorExtensions/*`
- `Sources/CodeEditorExtensionHost/*`
- `Sources/CodeEditorExtensionProtocol/*`
- `Sources/CodeEditorWasmEngine/*`
- `Sources/CodeEditorWasmEngineWasmKit/*`
- release/check scripts under `scripts/`

---

## 34. External architectural references

These references inform the target, not the repository-specific findings:

- Apple, **What’s new in Xcode 26**: https://developer.apple.com/videos/play/wwdc2025/247/
- Ghostty repository and embedding direction: https://github.com/ghostty-org/ghostty
- Zed extensions documentation: https://zed.dev/docs/extensions/developing-extensions
- Zed extension repository: https://github.com/zed-industries/extensions
- Swift WebAssembly getting started: https://www.swift.org/documentation/articles/wasm-getting-started.html
- WasmKit: https://github.com/swiftwasm/WasmKit
- Apple App Review Guidelines for host application policy decisions: https://developer.apple.com/app-store/review/guidelines/

Ghostty and WasmKit APIs are upstream dependencies with evolving implementation surfaces. CodeEditorView should pin exact revisions where needed, wrap them behind narrow internal adapters, and qualify behavior through its own conformance tests rather than exposing upstream runtime types publicly.

---

## 35. Final recommendation

Keep the repository at **pre-alpha/experimental** while executing Phases 0–4. The package and several critical algorithms are substantially improved, so this is no longer a recommendation to restart the project. The correct strategy is to preserve the modular product layout and replace the remaining unsafe/shared primitives with a small set of rigorously tested foundations.

The most important architectural decisions are:

1. separate document event version from content-state/savepoint identity
2. make conflict-aware save the only save path
3. centralize document lifecycle and workspace transactions
4. standardize multicast streams, process supervision, and framed RPC
5. use one real Ghostty-backed terminal path with mandatory linking and rendering
6. make extension packages immutable, fully signed, crash-durable, and capability-bound
7. require hard Wasm interruption or move untrusted execution to a killable helper process
8. generate release claims from executable artifacts

Once those are complete, the higher-level Xcode-like workbench can be implemented without repeatedly rebuilding unsafe foundations. Stable should be awarded product by product only after each product’s public contract, real integrations, platform behavior, accessibility, performance, security, recovery, and API compatibility are demonstrated by hard release evidence.
