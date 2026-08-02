let meta = #{
    name: "fix-audit-findings",
    description: "TDD remediation of all 174 CodeEditorView deep-audit findings; no skip, defer, or residuals",
    when_to_use: "After the 2026-08-02 deep audit; drive every PKG/REL/DOC/CORE/WSP/CMD/WB/UI/LANG/SRCH/TASK/SCM/LSP/DAP/TER/EXT/BROKER/WASM finding to verified with regression tests",
    phases: [
        #{ title: "Bootstrap", detail: "Seed registry, progress, constraints" },
        #{ title: "Phase 0", detail: "Release truth and reproducibility" },
        #{ title: "Phase 1", detail: "Document and data-integrity foundation" },
        #{ title: "Phase 2", detail: "Concurrency, streams, process, RPC substrate" },
        #{ title: "Phase 3a", detail: "Commands" },
        #{ title: "Phase 3b", detail: "Native editor UI" },
        #{ title: "Phase 4", detail: "Workspace transactions and lifecycle" },
        #{ title: "Phase 5a", detail: "Search and replace" },
        #{ title: "Phase 5b", detail: "Tasks and problem matching" },
        #{ title: "Phase 5c", detail: "Source control" },
        #{ title: "Phase 6a", detail: "Language support and Tree-sitter" },
        #{ title: "Phase 6b", detail: "LSP" },
        #{ title: "Phase 7", detail: "DAP debugging" },
        #{ title: "Phase 8", detail: "Ghostty terminal" },
        #{ title: "Phase 9a", detail: "Extension package signing and install" },
        #{ title: "Phase 9b", detail: "Capability broker" },
        #{ title: "Phase 9c", detail: "Wasm containment" },
        #{ title: "Phase 10", detail: "Integrated workbench" },
        #{ title: "Final gate", detail: "Adversarial residual audit and full test suite" },
    ],
};

// ---------------------------------------------------------------------------
// Output schemas
// ---------------------------------------------------------------------------

let implement_schema = #{
    "type": "object",
    "required": ["batch", "status", "findings_completed", "findings_remaining", "tests_run", "tests_passed", "commit_shas", "summary", "blockers"],
    "properties": #{
        "batch": #{ "type": "string" },
        "status": #{ "type": "string", "enum": ["complete", "partial", "blocked"] },
        "findings_completed": #{ "type": "array", "items": #{ "type": "string" } },
        "findings_remaining": #{ "type": "array", "items": #{ "type": "string" } },
        "tests_run": #{ "type": "integer" },
        "tests_passed": #{ "type": "integer" },
        "commit_shas": #{ "type": "array", "items": #{ "type": "string" } },
        "summary": #{ "type": "string" },
        "blockers": #{ "type": "array", "items": #{ "type": "string" } },
    },
};

let verify_schema = #{
    "type": "object",
    "required": ["batch", "pass", "open_findings", "weak_tests", "stub_hits", "evidence"],
    "properties": #{
        "batch": #{ "type": "string" },
        "pass": #{ "type": "boolean" },
        "open_findings": #{
            "type": "array",
            "items": #{
                "type": "object",
                "required": ["id", "issue"],
                "properties": #{
                    "id": #{ "type": "string" },
                    "issue": #{ "type": "string" },
                },
            },
        },
        "weak_tests": #{ "type": "array", "items": #{ "type": "string" } },
        "stub_hits": #{ "type": "array", "items": #{ "type": "string" } },
        "evidence": #{ "type": "string" },
    },
};

let final_schema = #{
    "type": "object",
    "required": ["pass", "open_p0", "open_p1", "open_p2", "failed_tests", "residual_findings", "summary"],
    "properties": #{
        "pass": #{ "type": "boolean" },
        "open_p0": #{ "type": "integer" },
        "open_p1": #{ "type": "integer" },
        "open_p2": #{ "type": "integer" },
        "failed_tests": #{ "type": "array", "items": #{ "type": "string" } },
        "residual_findings": #{ "type": "array", "items": #{ "type": "string" } },
        "summary": #{ "type": "string" },
    },
};

// ---------------------------------------------------------------------------
// Shared prompt fragments
// ---------------------------------------------------------------------------

fn audit_paths() {
    let s = "";
    s += "Docs/Architecture/AUDIT-2026-08-02-Deep-Audit-and-Stable-Plan.md";
    s += " and Docs/Architecture/AUDIT-2026-08-02-FINDINGS.json";
    s += " and .implementation/PROGRESS.md";
    s
}

fn hard_rules() {
    let r = "";
    r += "HARD RULES (non-negotiable):\n";
    r += "1. TDD ONLY: for each finding, write one or more failing regression tests FIRST (name must include the finding ID, e.g. test_DOC_N01_undoToSavepointIsClean), run them (expect fail), implement, re-run (expect pass).\n";
    r += "2. NO SKIP: never XCTSkip, XCTExpectFailure as permanent, #if false test bodies, or empty test stubs that always pass.\n";
    r += "3. NO DEFER: if a finding is in this batch, finish it fully now. Do not leave TODO/FIXME/NotImplemented in production paths.\n";
    r += "4. NO RESIDUALS: production path must match the audit Required implementation / Acceptance criteria for that finding ID.\n";
    r += "5. NO soft security or data-loss fallbacks: fail closed. Test-only fakes must live in Tests/ or test-support targets, never as production defaults.\n";
    r += "6. Prefer shared substrate types when building streams/process/RPC: AsyncBroadcastHub, OneShotPromise, ProcessSupervisor, BoundedByteSpool, FramedRPCConnection (audit §22).\n";
    r += "7. After each finding or tight group: commit with conventional message including finding IDs (e.g. fix(documents): DOC-N01 content-state savepoints).\n";
    r += "8. Update Docs/Architecture/AUDIT-2026-08-02-FINDINGS.json: set status fixed, list regression_tests; append a short log line to .implementation/PROGRESS.md.\n";
    r += "9. Run targeted swift test for affected products; fix all failures you introduce before finishing.\n";
    r += "10. Work in the current workspace only. Read source with tools — never invent from memory.\n";
    r += "11. If an external tool (Ghostty link, sourcekit-lsp, lldb-dap) is unavailable on this machine, still implement production require-real path + CI hard gate + fixtures; never leave a fake as the production default. Document any environment-only verification gap under blockers WITHOUT leaving the finding open in code.\n";
    r
}

fn implement_prompt(batch_id, batch_title, finding_ids, extra_scope) {
    let p = "";
    p += "You are the TDD implementer for CodeEditorView audit batch ";
    p += batch_id;
    p += " — ";
    p += batch_title;
    p += ".\n\n";
    p += hard_rules();
    p += "\nREAD FIRST (use read_file/grep/list_dir):\n";
    p += "- ";
    p += audit_paths();
    p += "\n";
    p += "- The detailed section for EVERY finding ID in this batch inside the audit markdown\n";
    p += "- Relevant Sources/ and Tests/ for the products involved\n";
    p += "- Package.swift when adding targets/test targets\n";
    p += "- Architecture ADRs under Docs/Architecture/ when relevant\n\n";
    p += "FINDINGS IN SCOPE (complete ALL of them):\n";
    p += finding_ids;
    p += "\n\n";
    p += extra_scope;
    p += "\n\nWORKFLOW:\n";
    p += "A. Load FINDINGS.json; only skip a finding if status is already verified AND you independently re-run its regression tests and they pass.\n";
    p += "B. For each open finding: read acceptance criteria → write failing tests → implement → green tests → update registry → commit.\n";
    p += "C. After all findings: run the relevant test targets; fix red tests.\n";
    p += "D. Grep for leftover fake/stub patterns related to this batch (try? swallow on critical paths, byte-spool defaults, soft registration, mock in production).\n";
    p += "E. Return status=complete only if findings_remaining is empty AND tests_passed == tests_run AND every scoped finding has regression tests.\n";
    p += "F. findings_completed must list every ID you fully fixed; findings_remaining must be empty for complete.\n";
    p
}

fn verify_prompt(batch_id, batch_title, finding_ids) {
    let p = "";
    p += "You are an ADVERSARIAL verifier for CodeEditorView audit batch ";
    p += batch_id;
    p += " (";
    p += batch_title;
    p += ").\n\n";
    p += "Capability: you may use read_file, grep, list_dir, and run_terminal_command for git/swift test/rg only. Do NOT edit production sources to 'fix' verification — report only.\n\n";
    p += "For EVERY finding ID in: ";
    p += finding_ids;
    p += "\n\n";
    p += "1. Re-read the audit acceptance criteria for that ID.\n";
    p += "2. Confirm production code implements the required architecture (not a rename or comment-only change).\n";
    p += "3. Confirm regression tests exist (name contains the ID or registry lists them) and RUN them; they must pass without skip.\n";
    p += "4. Hunt stubs: XCTSkip, TODO/FIXME in production paths, fake defaults, soft fail-open security, empty residual handlers.\n";
    p += "5. Check FINDINGS.json status is fixed or verified for each ID with non-empty regression_tests.\n\n";
    p += "Set pass=true ONLY if every scoped finding is fully fixed with green tests and zero open_findings/weak_tests/stub_hits that block acceptance.\n";
    p += "Default to pass=false when evidence is missing. evidence must cite files and test names you actually inspected/ran.\n";
    p
}

fn run_batch(batch_id, batch_title, finding_ids, extra_scope, max_rounds, impl_schema, ver_schema) {
    phase(batch_title);
    log("Starting batch " + batch_id + " — " + batch_title);

    let rounds = 0;
    let last_feedback = "";
    let last_impl = ();
    let last_ver = ();

    while rounds < max_rounds {
        rounds += 1;
        log(batch_id + " implement round " + rounds.to_string());

        let prompt = implement_prompt(batch_id, batch_title, finding_ids, extra_scope);
        if last_feedback != "" {
            prompt += "\n\nPREVIOUS VERIFIER FAILURES — you MUST address all of these before finishing:\n";
            prompt += last_feedback;
            prompt += "\n";
        }

        let impl = agent(prompt, #{
            label: "impl:" + batch_id + ":r" + rounds.to_string(),
            capability_mode: "all",
            output_schema: impl_schema,
        });

        if impl == () || !impl.success {
            last_feedback = "Implementer agent failed or returned unusable output; retry full batch with TDD.";
            log(batch_id + " implementer failed round " + rounds.to_string());
            continue;
        }
        last_impl = impl.output;

        if impl.output.status != "complete" || impl.output.findings_remaining.len() > 0 {
            last_feedback = "Implementer returned incomplete status=" + impl.output.status
                + " remaining=" + json_encode(impl.output.findings_remaining)
                + " blockers=" + json_encode(impl.output.blockers)
                + ". Finish ALL remaining findings with TDD; no defer.";
            log(batch_id + " incomplete: " + impl.output.summary);
            continue;
        }

        log(batch_id + " verify round " + rounds.to_string());
        let vprompt = verify_prompt(batch_id, batch_title, finding_ids);
        let ver = agent(vprompt, #{
            label: "verify:" + batch_id + ":r" + rounds.to_string(),
            capability_mode: "execute",
            output_schema: ver_schema,
        });

        if ver == () || !ver.success {
            last_feedback = "Verifier agent failed; re-implement and ensure tests run cleanly.";
            log(batch_id + " verifier failed round " + rounds.to_string());
            continue;
        }
        last_ver = ver.output;

        if ver.output.pass == true
            && ver.output.open_findings.len() == 0
            && ver.output.weak_tests.len() == 0
            && ver.output.stub_hits.len() == 0 {
            log(batch_id + " PASSED after " + rounds.to_string() + " round(s)");
            // Mark verified via a short agent to keep registry accurate
            let mark = "";
            mark += "Update Docs/Architecture/AUDIT-2026-08-02-FINDINGS.json: for each of ";
            mark += finding_ids;
            mark += " set status to verified if fixed. Append to .implementation/PROGRESS.md that batch ";
            mark += batch_id;
            mark += " verified. Do not change production code. Commit: chore(audit): verify batch ";
            mark += batch_id;
            mark += ".";
            agent(mark, #{
                label: "mark:" + batch_id,
                capability_mode: "all",
            });
            return #{ batch: batch_id, pass: true, rounds: rounds, impl: last_impl, ver: last_ver };
        }

        last_feedback = "Verifier rejected batch. open_findings=" + json_encode(ver.output.open_findings)
            + " weak_tests=" + json_encode(ver.output.weak_tests)
            + " stub_hits=" + json_encode(ver.output.stub_hits)
            + " evidence=" + ver.output.evidence
            + ". Fix every item with TDD; do not skip.";
        log(batch_id + " verify failed: " + ver.output.evidence);
    }

    // Exhausted retries — human gate, then one more forced attempt after resume
    await_user("verification", "Batch " + batch_id + " (" + batch_title
        + ") failed after " + max_rounds.to_string()
        + " TDD rounds. Review /workflows and resume to continue remediation. Last feedback: "
        + last_feedback);

    log(batch_id + " resumed after await_user — final forced implement+verify");
    let prompt2 = implement_prompt(batch_id, batch_title, finding_ids, extra_scope);
    prompt2 += "\n\nFINAL ATTEMPT AFTER HUMAN RESUME. Feedback:\n";
    prompt2 += last_feedback;
    prompt2 += "\nYou MUST complete all findings. No partial status.\n";
    let impl2 = agent(prompt2, #{
        label: "impl:" + batch_id + ":final",
        capability_mode: "all",
        output_schema: impl_schema,
    });
    let ver2 = agent(verify_prompt(batch_id, batch_title, finding_ids), #{
        label: "verify:" + batch_id + ":final",
        capability_mode: "execute",
        output_schema: ver_schema,
    });

    let ok = ver2 != () && ver2.success && ver2.output.pass == true
        && ver2.output.open_findings.len() == 0
        && ver2.output.weak_tests.len() == 0
        && ver2.output.stub_hits.len() == 0;

    if !ok {
        // Fail closed: pause with infra so the run cannot silently complete with residuals
        pause("verification", "Batch " + batch_id + " still has residuals after resume. Fix locally or re-run workflow; residuals are not allowed.");
    }
    return #{ batch: batch_id, pass: ok, rounds: max_rounds + 1, impl: last_impl, ver: if ver2 != () { ver2.output } else { last_ver } };
}

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

phase("Bootstrap");
log("Bootstrap audit remediation workspace");

let boot = "";
boot += "Bootstrap CodeEditorView audit remediation.\n\n";
boot += hard_rules();
boot += "\nTasks:\n";
boot += "1. Confirm Docs/Architecture/AUDIT-2026-08-02-Deep-Audit-and-Stable-Plan.md and AUDIT-2026-08-02-FINDINGS.json exist (174 findings).\n";
boot += "2. Ensure .implementation/PROGRESS.md exists and lists all batches as open.\n";
boot += "3. If FINDINGS.json statuses are not all open/fixed/verified, leave as-is; do not mark anything fixed without tests.\n";
boot += "4. Optionally run `swift package dump-package` and a quick `swift test --filter Nonexistent` to ensure toolchain works; do not require full suite yet.\n";
boot += "5. Commit any bootstrap-only file fixes if needed: chore(audit): bootstrap remediation tracker.\n";
boot += "Return a short summary of repo readiness.\n";

agent(boot, #{
    label: "bootstrap",
    capability_mode: "all",
});

// ---------------------------------------------------------------------------
// Phase batches — dependency order from audit §23
// ---------------------------------------------------------------------------

let results = [];
let max_rounds = 3;

// Phase 0 — release truth
results.push(run_batch(
    "0",
    "Phase 0 — release truth",
    "PKG-N01, REL-N01, REL-N02, REL-N03, REL-N04, REL-N05, REL-N06, REL-N07, REL-N08",
    "Extra scope: Downgrade CompatibilityProfile.toml to experimental/pre-alpha (no phase-16-rc). Rewrite scorecard/defect/accessibility/performance/API/concurrency/Ghostty/LSP/DAP gates so they cannot pass on authored status alone. Link defect closures to regression tests. Move production mocks/conformance guests toward test support where in scope for REL/PKG. Update README maturity only if needed for consistency.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 1 — documents
results.push(run_batch(
    "1",
    "Phase 1 — documents",
    "DOC-N01, DOC-N02, DOC-N03, DOC-N04, DOC-N05, DOC-N06, DOC-N07, DOC-N08, DOC-N09, DOC-N10, DOC-N11, CORE-N01",
    "Extra scope: Implement DocumentContentStateID + DocumentSavepoint; isDirty from content state not monotonic version. One conflict-aware DocumentSaveRequest API; remove overwrite default bridge. Pin equal-offset insertion semantics with property tests. Atomic undo API only. Overflow-safe range arithmetic. Bounded document events with gaps. Durable local write (parent fsync) + versioned recovery record. Enforce DocumentStore ownership model (MainActor or DocumentActor). Acceptance tests from audit DOC-N01 section.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 2 — substrate
results.push(run_batch(
    "2",
    "Phase 2 — substrate",
    "CORE-N02, CORE-N03, CORE-N04",
    "Extra scope (REQUIRED architecture even if not separate finding IDs): Implement AsyncBroadcastHub (sequence/gap/replay/finish), OneShotPromise + deadline scheduler, ProcessSupervisor, BoundedByteSpool, and FramedRPCConnection per audit §22. Migrate Core ProcessHandle to supervisor + broadcast. cancel() nonblocking; awaitTermination separate. Shell execution as explicit high-trust capability. Full lifecycle tests: multi-subscriber, overflow gap, cancel/timeout/late response. Later products will migrate onto this substrate.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 3a — commands
results.push(run_batch(
    "3a",
    "Phase 3a — commands",
    "CMD-N01, CMD-N02, CMD-N03, CMD-N04, CMD-N05",
    "Extra scope: rejectDuplicate registration policy by default; explicit owned replace. CommandID grammar enforcement. Explicit dispose for registration tokens. Chord timeout re-resolves context and surfaces errors. CommandExecutionClass for long-running work.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 3b — UI
results.push(run_batch(
    "3b",
    "Phase 3b — native editor UI",
    "UI-N01, UI-N02, UI-N03, UI-N04, UI-N05, UI-N06, UI-N07, UI-N08, UI-N09, UI-N10",
    "Extra scope: CaretNavigationEngine on layout snapshots; grapheme-valid positions/ranges; fragment selection rects; real BiDi via platform layout; firstRect/attributedSubstring contracts; IME marked-text lifecycle tests; no silent try? on input paths; large-file mode; semantic accessibility. Add UI/unit tests under CodeEditorViewTests. Platform matrix evidence scripts where automation is possible.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 4 — workspace
results.push(run_batch(
    "4",
    "Phase 4 — workspace",
    "WSP-N01, WSP-N02, WSP-N03, WSP-N04, WSP-N05, WSP-N06, WSP-N07, WSP-N08, WSP-N09, WSP-N10",
    "Extra scope: WorkspaceTransactionCoordinator two-phase prepare/commit/recover; one rollback owner per resource; durable journal startup recovery; dirty-descendant preflight before delete; atomic bulk-close decision phases; background FS workers; byte/metadata-exact archive claims only if true; snapshot+sequence workspace events; descriptor-relative no-follow for untrusted paths; host hidden-file policy; DocumentLifecycleCoordinator as sole registry mutator.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 5a — search
results.push(run_batch(
    "5a",
    "Phase 5a — search",
    "SRCH-N01, SRCH-N02, SRCH-N03, SRCH-N04, SRCH-N05, SRCH-N06, SRCH-N07, SRCH-N08, SRCH-N09",
    "Extra scope: discover nested .gitignore (do not skip hidden ignore files). Git-compatible ignore corpus vs git check-ignore. Separate glob grammar. Bounded worker pool with cancellation. Encoding-aware skip reporting. Full regex replacement ($n, named, escaping, zero-width). Snapshot-bound multi-file replace via workspace transactions. Correct completion metrics.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 5b — tasks
results.push(run_batch(
    "5b",
    "Phase 5b — tasks",
    "TASK-N01, TASK-N02, TASK-N03, TASK-N04, TASK-N05, TASK-N06, TASK-N07, TASK-N08",
    "Extra scope: migrate TaskExecutionHandle.events to AsyncBroadcastHub. Incremental UTF-8 decoders per stream. Bounded spool with truncation markers. Validated readiness regex. Explicit TaskNodeOutcome DAG. Versioned problem ranges. Finish ownership on exit.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 5c — SCM
results.push(run_batch(
    "5c",
    "Phase 5c — SCM",
    "SCM-N01, SCM-N02, SCM-N03, SCM-N04, SCM-N05, SCM-N06, SCM-N07, SCM-N08, SCM-N09",
    "Extra scope: per-repo identity and actor serialization. Wire auth or remove from Stable scope with fail-closed. Dual index/worktree status model. Destructive ops through DocumentLifecycleCoordinator. Git-validated hunks. Multicast status stream. Bounded process output via ProcessSupervisor.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 6a — language
results.push(run_batch(
    "6a",
    "Phase 6a — language/Tree-sitter",
    "LANG-N01, LANG-N02, LANG-N03, LANG-N04, LANG-N05, LANG-N06, LANG-N07",
    "Extra scope: LanguageRegistrationRecord with owner/generation/token. Malformed queries fail closed. One ParseSession actor path. Pointer ownership wrappers + stress tests. Expand CodeEditorTreeSitterTests. Generated grammar conformance fixtures for shipped packs. Prefer host-owned registries over global side effects.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 6b — LSP
results.push(run_batch(
    "6b",
    "Phase 6b — LSP",
    "LSP-N01, LSP-N02, LSP-N03, LSP-N04, LSP-N05, LSP-N06, LSP-N07, LSP-N08, LSP-N09, LSP-N10, LSP-N11, LSP-N12, LSP-N13",
    "Extra scope: migrate to FramedRPCConnection/OneShotPromise — pending registered BEFORE any await; no unstructured registration Task. Message lanes. Safe synchronize API only. Gap recovery full resync. Per-document lane for change/save/close. Complete WorkspaceEdit → workspace transactions. No empty-text fallback on snapshot miss. Versioned diagnostics. Real sourcekit-lsp/clangd hard gate scripts + fixtures.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 7 — DAP
results.push(run_batch(
    "7",
    "Phase 7 — DAP",
    "DAP-N01, DAP-N02, DAP-N03, DAP-N04, DAP-N05, DAP-N06, DAP-N07, DAP-N08, DAP-N09, DAP-N10",
    "Extra scope: shared RPC lifecycle with LSP. Discard late responses. Reverse request failures not empty success. Session state machine no force unwrap. Requested vs verified breakpoints. Move MockDebugAdapter to tests. TerminalService-only runInTerminal. lldb-dap fixture hard gate.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 8 — terminal
results.push(run_batch(
    "8",
    "Phase 8 — terminal",
    "TER-N01, TER-N02, TER-N03, TER-N04, TER-N05, TER-N06, TER-N07, TER-N08, TER-N09, TER-N10",
    "Extra scope: production requireLinked/requireGhosttyLinked true; move byte-spool to test-only. Integrate real Ghostty surface path or hard-unavailable error (never fake UI as Ghostty). Deprecate legacy public VT path. ProcessSupervisor PTY. CodeEditorTerminalGhosttyTests with linked fixtures when available. Mandatory Ghostty CI gate.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 9a — extension package
results.push(run_batch(
    "9a",
    "Phase 9a — extension package",
    "EXT-N01, EXT-N02, EXT-N03, EXT-N04, EXT-N05, EXT-N06, EXT-N07, EXT-N08, EXT-N09, EXT-N10, EXT-N11, EXT-N12, EXT-N13, EXT-N14, EXT-N15, EXT-N16, EXT-N17, EXT-N18, EXT-N19, EXT-N20",
    "Extra scope: standards-compliant TOML or renamed language; compatibility levels S0–S4; SHA-256 only for security digests; full inventory including hidden files; sign .codeeditor package content or move host state out; canonical signed publisher statement; atomic key write; no fatalError without CryptoKit; fail-closed keyring; inventory quotas; verify before activate; crash-durable install journal; same-version reinstall safety; content-addressed paths only; revocation freshness; filter unverified snapshots; move mocks to test support; bounded logs; broadcast package snapshots.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 9b — broker
results.push(run_batch(
    "9b",
    "Phase 9b — capability broker",
    "BROKER-N01, BROKER-N02, BROKER-N03, BROKER-N04, BROKER-N05, BROKER-N06, BROKER-N07, BROKER-N08, BROKER-N09, BROKER-N10, BROKER-N11, BROKER-N12, BROKER-N13, BROKER-N14, BROKER-N15, BROKER-N16",
    "Extra scope: bind every handle to calling extension ID+generation; no mint for unregistered; strict wire schemas fail closed; surface storage/init and worktree I/O errors; descriptor-relative containment; revalidate executable identity; unambiguous roots; quotas async; real arg glob or rename; capability process streams via supervisor; streaming download with redirect policy; path allowlist not string prefix; scoped npm + size limits; nonblocking revoke.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 9c — Wasm
results.push(run_batch(
    "9c",
    "Phase 9c — Wasm",
    "WASM-N01, WASM-N02, WASM-N03, WASM-N04, WASM-N05, WASM-N06, WASM-N07, WASM-N08, WASM-N09, WASM-N10, WASM-N11, WASM-N12, WASM-N13, WASM-N14, WASM-N15, WASM-N16",
    "Extra scope: hard interrupt noncooperative loops (engine metering or killable helper process). Continuous memory limits. Required memory fails ABI. Serialize calls/memory. No value coerce-to-zero. Monotonic clocks. Per-request deadlines and cancel IDs (not global hasCancel). OneShotPromise request registration. Enforce all configured quotas. Bounded logs. dealloc pairing. Move linked Swift guest to test-only. Hostile corpus fixtures process-isolated.",
    max_rounds,
    implement_schema,
    verify_schema
));

// Phase 10 — workbench
results.push(run_batch(
    "10",
    "Phase 10 — workbench",
    "WB-N01, WB-N02, WB-N03, WB-N04, WB-N05, WB-N06, WB-N07",
    "Extra scope: rename fault isolation to error presentation; untrusted contributions declarative only. Layout-based reveal API. Implement or remove animation API. Background file-tree index. TaskBag lifecycle per window/pane. Wire advertised workflows to production services. Document Stable 1.0 workbench scope vs Xcode gaps without fake panels.",
    max_rounds,
    implement_schema,
    verify_schema
));

// ---------------------------------------------------------------------------
// Final residual gate
// ---------------------------------------------------------------------------

phase("Final gate");
log("Final residual audit across all 174 findings");

let final_prompt = "";
final_prompt += "You are the FINAL residual gate for CodeEditorView audit remediation.\n\n";
final_prompt += hard_rules();
final_prompt += "\n1. Read Docs/Architecture/AUDIT-2026-08-02-FINDINGS.json — every finding must be status fixed or verified with non-empty regression_tests.\n";
final_prompt += "2. Count any still open/in_progress as residual_findings.\n";
final_prompt += "3. Spot-check P0 findings in source against audit acceptance criteria (DOC-N01/N02, WSP-N01/N02, CORE-N02, LSP-N01, DAP-N01, TER-N01/N02, EXT-N04/N06/N12, BROKER-N01, WASM-N01/N09/N12).\n";
final_prompt += "4. Run as much of `swift test` as feasible (or product-targeted suites) and list failed_tests.\n";
final_prompt += "5. Grep for production fakes: byte spool default, expectedIdentity: nil overwrite bridge, XCTSkip in audit regression tests, phase-16-rc claims.\n";
final_prompt += "6. pass=true ONLY if open_p0==0 AND open_p1==0 AND residual_findings empty AND no critical failed_tests for remediated areas.\n";
final_prompt += "7. Write a report to .implementation/FINAL-GATE-REPORT.md and set pass accordingly.\n";

let final_r = agent(final_prompt, #{
    label: "final-gate",
    capability_mode: "all",
    output_schema: final_schema,
});

let final_pass = final_r != () && final_r.success && final_r.output.pass == true
    && final_r.output.open_p0 == 0
    && final_r.output.open_p1 == 0
    && final_r.output.residual_findings.len() == 0;

if !final_pass {
    let detail = "Final gate failed.";
    if final_r != () && final_r.success {
        detail = final_r.output.summary;
        detail += " residuals=" + json_encode(final_r.output.residual_findings);
        detail += " failed_tests=" + json_encode(final_r.output.failed_tests);
    }
    // One repair cycle
    log("Final gate failed — launching residual repair agent");
    let repair = "";
    repair += "FINAL RESIDUAL REPAIR. ";
    repair += hard_rules();
    repair += "\nFix ALL residual findings so the final gate would pass. Feedback:\n";
    repair += detail;
    repair += "\nUpdate FINDINGS.json and PROGRESS.md. No skip/defer.\n";
    agent(repair, #{
        label: "residual-repair",
        capability_mode: "all",
        output_schema: implement_schema,
    });

    let final_r2 = agent(final_prompt, #{
        label: "final-gate-2",
        capability_mode: "all",
        output_schema: final_schema,
    });
    final_pass = final_r2 != () && final_r2.success && final_r2.output.pass == true
        && final_r2.output.open_p0 == 0
        && final_r2.output.open_p1 == 0
        && final_r2.output.residual_findings.len() == 0;
    if final_pass {
        final_r = final_r2;
    } else {
        let d2 = detail;
        if final_r2 != () && final_r2.success {
            d2 = final_r2.output.summary;
        }
        pause("verification", "Final residual gate still failing: " + d2);
    }
}

let passed_batches = 0;
let i = 0;
while i < results.len() {
    if results[i].pass == true {
        passed_batches += 1;
    }
    i += 1;
}

let report = "";
report += "# Audit remediation workflow result\n\n";
report += "- Batches passed: " + passed_batches.to_string() + "/" + results.len().to_string() + "\n";
report += "- Final gate pass: " + final_pass.to_string() + "\n";
if final_r != () && final_r.success {
    report += "- Summary: " + final_r.output.summary + "\n";
    report += "- Open P0: " + final_r.output.open_p0.to_string() + "\n";
    report += "- Open P1: " + final_r.output.open_p1.to_string() + "\n";
}
report += "\nPolicy: TDD, no skip, no defer, no residuals.\n";

let path = write_scratch_file("audit-remediation-result.md", report);
log(report);

complete(#{
    path: path,
    batches_passed: passed_batches,
    batches_total: results.len(),
    final_pass: final_pass,
    findings_total: 174,
});
