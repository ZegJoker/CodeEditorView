import Foundation
import Testing
@testable import CodeEditorCore

@Suite("Process substrate CORE-N02/N03/N04")
struct ProcessSubstrateTests {
    // MARK: - CORE-N02 multi-consumer process events

    @Test func test_CORE_N02_processEventsAreMultiConsumer() async throws {
        #if os(macOS)
        let service = ProcessService(profile: .test)
        let handle = try service.launch(
            ProcessLaunchRequest(
                executable: "/bin/echo",
                arguments: ["broadcast-hello"],
                mode: .direct,
                maxStdoutBytes: 64 * 1024,
                maxStderrBytes: 16 * 1024
            )
        )

        // Two independent consumers must both observe exit and the same stdout.
        async let consumerA: [ProcessOutputEvent] = {
            var events: [ProcessOutputEvent] = []
            for await e in handle.events { events.append(e) }
            return events
        }()
        async let consumerB: [ProcessOutputEvent] = {
            var events: [ProcessOutputEvent] = []
            for await e in handle.events { events.append(e) }
            return events
        }()

        let a = await consumerA
        let b = await consumerB
        let aExited = a.contains {
            if case .exited = $0 { return true }
            return false
        }
        let bExited = b.contains {
            if case .exited = $0 { return true }
            return false
        }
        #expect(aExited)
        #expect(bExited)

        let aStdout = a.compactMap { event -> String? in
            if case .stdout(let d) = event { return String(data: d, encoding: .utf8) }
            return nil
        }.joined()
        let bStdout = b.compactMap { event -> String? in
            if case .stdout(let d) = event { return String(data: d, encoding: .utf8) }
            return nil
        }.joined()
        #expect(aStdout.contains("broadcast-hello"))
        #expect(bStdout.contains("broadcast-hello"))
        #else
        // Foundation.Process is unavailable: launch must fail closed (not a silent empty stream).
        #expect(throws: ProcessServiceError.unavailableOnPlatform) {
            _ = try ProcessService(profile: .test).launch(
                ProcessLaunchRequest(executable: "/bin/echo", arguments: ["broadcast-hello"], mode: .direct)
            )
        }
        #endif
    }

    @Test func test_CORE_N02_processOutputIsBoundedNotUnbounded() async throws {
        #if os(macOS)
        let service = ProcessService(profile: .test)
        // Tiny caps force spill/gap rather than unbounded growth.
        let handle = try service.launch(
            ProcessLaunchRequest(
                executable: "/bin/sh",
                arguments: ["-c", "python3 -c \"print('x'*200000)\" 2>/dev/null || yes x | head -c 200000"],
                mode: .direct,
                maxStdoutBytes: 1024,
                maxStderrBytes: 256,
                capabilityKind: .localShellExecution
            )
        )
        var totalStdout = 0
        var sawExit = false
        var sawGap = false
        for await event in handle.events {
            switch event {
            case .stdout(let d):
                totalStdout += d.count
            case .stderr:
                break
            case .exited:
                sawExit = true
            case .outputGap:
                sawGap = true
            }
        }
        #expect(sawExit)
        // Cap must bound delivered payload well below flood size.
        #expect(totalStdout <= 8 * 1024)
        // With a 200KB flood and 1KB spool, gap or hard truncation must engage.
        #expect(sawGap || totalStdout <= 1024)
        #else
        #expect(throws: ProcessServiceError.unavailableOnPlatform) {
            _ = try ProcessService(profile: .test).launch(
                ProcessLaunchRequest(
                    executable: "/bin/sh",
                    arguments: ["-c", "yes x | head -c 200000"],
                    mode: .direct,
                    maxStdoutBytes: 1024,
                    capabilityKind: .localShellExecution
                )
            )
        }
        #endif
    }

    // MARK: - CORE-N03 nonblocking cancel

    @Test func test_CORE_N03_cancelReturnsWithoutWaitingForDeath() async throws {
        #if os(macOS)
        let service = ProcessService(profile: .test)
        let handle = try service.launch(
            ProcessLaunchRequest(
                executable: "/bin/sleep",
                arguments: ["30"],
                mode: .direct
            )
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(!handle.isTerminated)

        let start = ContinuousClock.now
        handle.cancel()
        let elapsed = ContinuousClock.now - start
        // cancel() must not block on process.waitUntilExit (would take ~grace or longer for sleep 30).
        #expect(elapsed < .milliseconds(50))

        // Reaping is a separate API; process was signalled (non-zero), not a clean exit 0.
        let exit = await handle.awaitTermination()
        #expect(handle.isTerminated)
        #expect(exit.code != 0)
        #else
        #expect(throws: ProcessServiceError.unavailableOnPlatform) {
            _ = try ProcessService(profile: .test).launch(
                ProcessLaunchRequest(executable: "/bin/sleep", arguments: ["30"], mode: .direct)
            )
        }
        #endif
    }

    @Test func test_CORE_N03_awaitTerminationIsSeparateFromCancel() async throws {
        #if os(macOS)
        let supervisor = ProcessSupervisor(profile: .test)
        let handle = try await supervisor.spawn(
            ProcessLaunchRequest(
                executable: "/bin/sleep",
                arguments: ["5"],
                mode: .direct
            )
        )
        #expect(!handle.isTerminated)

        let cancelStart = ContinuousClock.now
        await supervisor.cancel(handle.id, escalation: .termThenKill(grace: .milliseconds(100)))
        let cancelElapsed = ContinuousClock.now - cancelStart
        // cancel must return immediately; death is awaited separately.
        #expect(cancelElapsed < .milliseconds(50))

        let waitStart = ContinuousClock.now
        let exit = try await supervisor.awaitExit(handle.id)
        let waitElapsed = ContinuousClock.now - waitStart
        #expect(handle.isTerminated)
        #expect(exit.code != 0)
        // Death should complete within grace + kill window (not the full 5s sleep).
        #expect(waitElapsed < .seconds(3))
        #else
        do {
            _ = try await ProcessSupervisor(profile: .test).spawn(
                ProcessLaunchRequest(executable: "/bin/sleep", arguments: ["5"], mode: .direct)
            )
            Issue.record("expected unavailableOnPlatform from ProcessSupervisor.spawn")
        } catch ProcessServiceError.unavailableOnPlatform {
            // expected fail-closed
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #endif
    }

    // MARK: - CORE-N04 shell capability

    @Test func test_CORE_N04_shellModeRequiresShellCapability() async throws {
        var caps = PlatformCapabilityProfile.test.capabilities
        caps[.localShellExecution] = .unavailable(reason: "shell denied in test")
        let profile = PlatformCapabilityProfile(
            platform: HostPlatform.current,
            name: "no-shell",
            shippingProfileID: nil,
            capabilities: caps
        )
        let service = ProcessService(profile: profile)
        // Dedicated ProcessServiceError — not a soft generic process launch.
        #expect(throws: ProcessServiceError.shellCapabilityRequired) {
            _ = try service.launch(
                ProcessLaunchRequest(
                    executable: "/bin/echo",
                    arguments: ["hi"],
                    mode: .shell
                )
            )
        }
        // Direct still works when localProcess is granted (macOS only for live process).
        #if os(macOS)
        let handle = try service.launch(
            ProcessLaunchRequest(
                executable: "/bin/echo",
                arguments: ["ok"],
                mode: .direct
            )
        )
        #expect(handle.processIdentifier > 0)
        handle.cancel()
        _ = await handle.awaitTermination()
        #else
        #expect(throws: ProcessServiceError.unavailableOnPlatform) {
            _ = try service.launch(
                ProcessLaunchRequest(executable: "/bin/echo", arguments: ["ok"], mode: .direct)
            )
        }
        #endif
    }

    @Test func test_CORE_N04_shellModeSucceedsWhenCapabilityGranted() async throws {
        #if os(macOS)
        let service = ProcessService(profile: .test)
        let (stdout, _, code) = try await service.runCollecting(
            ProcessLaunchRequest(
                executable: "/bin/echo",
                arguments: ["shell-ok"],
                mode: .shell
            )
        )
        #expect(code == 0)
        #expect(stdout.contains("shell-ok"))
        #else
        // Shell capability may be granted by profile, but platform still has no Process.
        #expect(throws: ProcessServiceError.unavailableOnPlatform) {
            _ = try ProcessService(profile: .test).launch(
                ProcessLaunchRequest(executable: "/bin/echo", arguments: ["shell-ok"], mode: .shell)
            )
        }
        #endif
    }

    @Test func test_CORE_N04_shellCapabilityPresentOnShippingProfiles() {
        #expect(PlatformCapabilityProfile.directMacOS.availability(for: .localShellExecution) == .local)
        #expect(PlatformCapabilityProfile.enterprise.availability(for: .localShellExecution) == .local)
        #expect(PlatformCapabilityProfile.test.availability(for: .localShellExecution) == .local)
        // iOS must fail closed for shell.
        if case .unavailable = PlatformCapabilityProfile.iOS.availability(for: .localShellExecution) {
            // expected
        } else {
            Issue.record("iOS must not grant localShellExecution")
        }
        // iOS profile + shell mode must throw shellCapabilityRequired before any process spawn.
        let iosService = ProcessService(profile: .iOS)
        #expect(throws: ProcessServiceError.shellCapabilityRequired) {
            _ = try iosService.launch(
                ProcessLaunchRequest(executable: "/bin/echo", arguments: ["x"], mode: .shell)
            )
        }
    }
}
