// Ported from tests/test_app_helper.py: native-app helper commands, isolated from the user's
// services and Codex. In-process tests use only custom state directories and never reach
// launchctl. Parent-shutdown tests run the built `codex-whip` worker as a child process against
// a temporary state directory and a local Codex socket stub.

import Foundation
import Testing
@testable import WhipEngine

private final class Lines: @unchecked Sendable {
    var items: [String] = []
    var text: String { items.joined(separator: "\n") }
    func append(_ value: String) { items.append(value) }
}

private struct AppSandbox {
    let root: URL
    let home: URL
    let directory: URL

    init() throws {
        root = try HelperProcess.temporaryDirectory("ckg-app-")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        directory = root.appendingPathComponent("custom-state")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    var codexHome: URL { home.appendingPathComponent(".codex") }
    /// Where the default state directory would be with this sandbox as home.
    var defaultDirectory: URL { home.appendingPathComponent("Library/Application Support/Codex Whip") }
    var agentPath: URL { home.appendingPathComponent("Library/LaunchAgents/\(Paths.label).plist") }

    static let stateText = """
        {
            "version": 1,
            "enabled_at": 10000,
            "threads": [
                "chosen-session"
            ],
            "pending": {
                "chosen-session": {
                    "turn_id": "failure",
                    "due_at": 20500,
                    "model": "selected-model",
                    "effort": "xhigh"
                }
            },
            "handled": {
                "earlier-session": {
                    "turn_id": "earlier-failure",
                    "outcome": "submitted",
                    "retry_turn_id": "retry"
                }
            },
            "paused": {
                "paused-session": true
            },
            "last_error": null
        }

        """

    @discardableResult
    func savedState(_ directory: URL? = nil) throws -> JSON {
        let directory = directory ?? self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.stateText.utf8).write(to: directory.appendingPathComponent("state.json"))
        return try JSON.parse(Self.stateText)
    }

    @discardableResult
    func cliJob(arguments: [String]? = nil, environment: [String: String]? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: agentPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let job: [String: Any] = [
            "Label": Paths.label,
            "ProgramArguments": arguments ?? ["python3", "/unused/codex_whip.py", "_run"],
            "EnvironmentVariables": environment ?? [:],
        ]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: agentPath)
        return agentPath
    }
}

/// Holds the worker lock the way a running worker does, from a separate open file description.
private func holdWorkerLock(_ directory: URL) throws -> Int32 {
    let descriptor = open(directory.appendingPathComponent("worker.lock").path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw WhipError("Could not lock") }
    return descriptor
}

private func mode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0) & 0o777
}

@Suite(.serialized) struct AppHelperTests {
    // test_prepare_initializes_missing_state_in_custom_directory_without_services
    @Test func prepareInitializesMissingStateInCustomDirectoryWithoutServices() throws {
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        let result = Command.main(["--state-dir", sandbox.directory.path, "prepare"], stdout: { _ in }, stderr: { _ in })
        #expect(result == 0)
        let state = try FileStore.readJSON(sandbox.directory.appendingPathComponent("state.json"))
        #expect(state["version"] == 1)
        #expect(state["pending"] == [:])
        #expect(state["handled"] == [:])
        #expect(state["paused"] == [:])
        #expect(try mode(sandbox.directory) == 0o700)
        #expect(try mode(sandbox.directory.appendingPathComponent("state.json")) == 0o600)
    }

    // test_prepare_preserves_state_and_existing_history_bytes
    @Test func preparePreservesStateAndExistingHistoryBytes() throws {
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        let state = try sandbox.savedState()
        let history = sandbox.directory.appendingPathComponent("history.sqlite3")
        try Data("existing-history".utf8).write(to: history)
        let before = try Data(contentsOf: sandbox.directory.appendingPathComponent("state.json"))
        try Service.prepareState(directory: sandbox.directory)
        #expect(try Data(contentsOf: sandbox.directory.appendingPathComponent("state.json")) == before)
        #expect(try Data(contentsOf: history) == Data("existing-history".utf8))
        #expect(try FileStore.readJSON(sandbox.directory.appendingPathComponent("state.json")) == state)
    }

    // test_default_prepare_stops_cli_job_before_preserving_latest_state
    // NEEDS SEAM: Service.serviceRunning and Service.stopService call /bin/launchctl directly; inject
    // a launchd client so the test can report a running job and flush the latest state on stop.
    @Test(.disabled("NEEDS SEAM: Service.serviceRunning/stopService run the real launchctl"))
    func defaultPrepareStopsCLIJobBeforePreservingLatestState() {}

    // test_default_prepare_removes_unloaded_cli_job_file
    // NEEDS SEAM: Service.stopService runs the real `launchctl bootout`; inject a launchd client.
    @Test(.disabled("NEEDS SEAM: Service.serviceRunning/stopService run the real launchctl"))
    func defaultPrepareRemovesUnloadedCLIJobFile() {}

    /// Python ran prepare_state on the default directory and expected the refusal before any stop.
    /// The Swift default directory comes from FileManager.homeDirectoryForCurrentUser, which ignores
    /// HOME (a child process with a temporary HOME still prepares the real default path), so
    /// prepareState cannot target a temporary default directory.
    /// NEEDS SEAM: Paths.home, so prepareState can run against a temporary default directory.
    /// Ported here: the launch-job reading that prepareState refuses on, checked against the
    /// sandbox's default paths, with the saved state and launch file left byte for byte.
    private func assertRefusedCLIJob(arguments: [String]? = nil, environment: [String: String]? = nil,
                                     malformed: Data? = nil) throws {
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        let directory = sandbox.defaultDirectory
        try sandbox.savedState(directory)
        let path = try sandbox.cliJob(arguments: arguments, environment: environment)
        if let malformed { try malformed.write(to: path) }
        let stateBefore = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        let jobBefore = try Data(contentsOf: path)
        do {
            let paths = try Service.cliJobPaths(path)
            // prepareState refuses unless both the state directory and the Codex home match.
            let explicitState = arguments?.contains { $0.hasPrefix("--state-dir") } ?? false
            let stateMatches = !explicitState || paths.stateDirectory == Paths.resolve(directory.path)
            #expect(!(stateMatches && paths.codexHome == Paths.resolve(sandbox.codexHome.path)), "\(paths)")
        } catch let error as WhipError {
            #expect(error.description.contains("Keep that service"), "\(error)")
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("state.json")) == stateBefore)
        #expect(try Data(contentsOf: path) == jobBefore)
    }

    // test_prepare_refuses_cli_job_with_custom_state_directory
    @Test func prepareRefusesCLIJobWithCustomStateDirectory() throws {
        let other = try HelperProcess.temporaryDirectory("ckg-other-")
        defer { try? FileManager.default.removeItem(at: other) }
        try assertRefusedCLIJob(arguments: ["python3", "/unused/codex_whip.py", "--state-dir", other.path, "_run"])
    }

    // test_prepare_refuses_cli_job_with_custom_codex_home_argument
    @Test func prepareRefusesCLIJobWithCustomCodexHomeArgument() throws {
        try assertRefusedCLIJob(arguments: ["python3", "/unused/codex_whip.py", "--codex-home=/tmp/ckg-other-codex", "_run"])
    }

    // test_prepare_refuses_cli_job_with_custom_codex_home_environment
    @Test func prepareRefusesCLIJobWithCustomCodexHomeEnvironment() throws {
        try assertRefusedCLIJob(environment: ["CODEX_HOME": "/tmp/ckg-other-codex"])
    }

    // test_prepare_refuses_malformed_existing_plist
    @Test func prepareRefusesMalformedExistingPlist() throws {
        try assertRefusedCLIJob(malformed: Data("invalid plist".utf8))
    }

    // test_prepare_refuses_running_cli_job_without_launch_file
    // NEEDS SEAM: with no launch file, prepareState asks Service.serviceRunning, which runs the real
    // `launchctl print`; inject a launchd client that reports a running job.
    @Test(.disabled("NEEDS SEAM: Service.serviceRunning runs the real launchctl"))
    func prepareRefusesRunningCLIJobWithoutLaunchFile() {}

    // test_prepare_resolves_explicit_default_paths_and_argument_precedence
    // Ported for the path decision only. NEEDS SEAM: the follow-up Service.stopService call runs
    // the real launchctl, so prepareState itself is not run against a matching job.
    @Test func prepareResolvesExplicitDefaultPathsAndArgumentPrecedence() throws {
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        let directory = sandbox.defaultDirectory
        try sandbox.savedState(directory)
        let path = try sandbox.cliJob(arguments: [
            "python3", "/unused/codex_whip.py", "--state-dir", directory.appendingPathComponent("unused/..").path,
            "--codex-home", sandbox.codexHome.path, "_run",
        ], environment: ["CODEX_HOME": sandbox.root.appendingPathComponent("overridden-home").path])
        let paths = try Service.cliJobPaths(path)
        #expect(paths.stateDirectory == Paths.resolve(directory.path))
        #expect(paths.codexHome == Paths.resolve(sandbox.codexHome.path))
    }

    // test_prepare_accepts_matching_recorded_codex_home_environment
    // Ported for the path decision only. NEEDS SEAM: the follow-up Service.stopService call runs
    // the real launchctl.
    @Test func prepareAcceptsMatchingRecordedCodexHomeEnvironment() throws {
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        let codexHome = sandbox.root.appendingPathComponent("shared-codex")
        let path = try sandbox.cliJob(environment: ["CODEX_HOME": codexHome.path])
        let paths = try Service.cliJobPaths(path)
        #expect(paths.codexHome == Paths.resolve(codexHome.path))
        #expect(paths.stateDirectory == Paths.resolve(Paths.defaultStateDirectory.path))
    }

    // test_custom_prepare_does_not_even_inspect_default_job
    // Swift has no seam to fail on inspection; a custom directory never reaches the launch-job checks.
    @Test func customPrepareDoesNotEvenInspectDefaultJob() throws {
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        try Service.prepareState(directory: sandbox.directory)
        #expect(FileManager.default.fileExists(atPath: sandbox.directory.appendingPathComponent("state.json").path))
    }

    // test_dashboard_for_missing_state_is_json_only_and_creates_nothing
    @Test func dashboardForMissingStateIsJSONOnlyAndCreatesNothing() throws {
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        let output = Lines()
        let result = Command.main(["--state-dir", sandbox.directory.path, "dashboard"], stdout: output.append, stderr: { _ in })
        #expect(result == 0)
        let value = try JSON.parse(output.text)
        #expect(Set(value.object?.keys.map { $0 } ?? []) == ["state", "history", "running"])
        #expect(value["state"] == [:])
        #expect(value["history"]?["available"] == false)
        #expect(value["running"] == false)
        #expect(!FileManager.default.fileExists(atPath: sandbox.directory.path))
    }

    // test_dashboard_preserves_state_and_database_and_ignores_stale_pid
    @Test func dashboardPreservesStateAndDatabaseAndIgnoresStalePID() throws {
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        let state = try sandbox.savedState()
        let history = try History(directory: sandbox.directory)
        _ = try history.record("waiting", ["thread_id": "chosen-session", "turn_id": "failure"])
        history.close()
        try Data("12345".utf8).write(to: sandbox.directory.appendingPathComponent("worker.pid"))
        let stateBefore = try Data(contentsOf: sandbox.directory.appendingPathComponent("state.json"))
        let historyBefore = try Data(contentsOf: sandbox.directory.appendingPathComponent("history.sqlite3"))
        let entriesBefore = try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path).sorted()
        let result = try Service.dashboard(directory: sandbox.directory)
        #expect(result["state"] == state)
        #expect(result["history"]?["capacity"] == 1)
        #expect(result["running"] == false)
        #expect(try Data(contentsOf: sandbox.directory.appendingPathComponent("state.json")) == stateBefore)
        #expect(try Data(contentsOf: sandbox.directory.appendingPathComponent("history.sqlite3")) == historyBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path).sorted() == entriesBefore)
    }

    // test_dashboard_running_uses_held_worker_lock
    @Test func dashboardRunningUsesHeldWorkerLock() throws {
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        try sandbox.savedState()
        let lock = try holdWorkerLock(sandbox.directory)
        #expect(try Service.dashboard(directory: sandbox.directory)["running"] == true)
        flock(lock, LOCK_UN)
        close(lock)
        #expect(try Service.dashboard(directory: sandbox.directory)["running"] == false)
        #expect(try Data(contentsOf: sandbox.directory.appendingPathComponent("worker.lock")) == Data())
    }

    // test_frozen_install_runs_executable_without_temporary_source_path
    // NEEDS SEAM: Service.startService runs the real `launchctl bootstrap` and writes to the real
    // home (Paths.home); inject the home directory and a launchd client.
    @Test(.disabled("NEEDS SEAM: Service.startService runs the real launchctl and uses the real home"))
    func frozenInstallRunsExecutableWithoutTemporarySourcePath() {}

    // test_cli_start_does_not_install_another_job_when_native_worker_is_running
    // Paths.home is the real home in-process, so the command link and launch job are checked for
    // being left exactly as they were rather than for absence in a temporary home.
    @Test func cliStartDoesNotInstallAnotherJobWhenNativeWorkerIsRunning() throws {
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        try sandbox.savedState()
        let before = try Data(contentsOf: sandbox.directory.appendingPathComponent("state.json"))
        let lock = try holdWorkerLock(sandbox.directory)
        defer { close(lock) }
        // The held lock is what keeps startService away from launchctl; prove it first.
        try #require(workerRunning(sandbox.directory))
        let command = ServiceEnvironment.live.commandLink
        let linkBefore = Service.exists(command)
        let agentBefore = FileManager.default.fileExists(atPath: Paths.agentPath.path)
        let output = Lines()
        try Service.startService(directory: sandbox.directory, codexHome: sandbox.codexHome, threads: [],
                                 preserveState: false, output: output.append)
        #expect(output.text.contains("Already enabled"))
        #expect(try Data(contentsOf: sandbox.directory.appendingPathComponent("state.json")) == before)
        #expect(Service.exists(command) == linkBefore)
        #expect(FileManager.default.fileExists(atPath: Paths.agentPath.path) == agentBefore)
    }

    // test_cli_status_recognizes_native_worker_without_a_launch_agent
    @Test func cliStatusRecognizesNativeWorkerWithoutALaunchAgent() throws {
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        try sandbox.savedState()
        let lock = try holdWorkerLock(sandbox.directory)
        defer { close(lock) }
        // A held lock short-circuits before serviceRunning, so no launchctl call happens.
        try #require(workerRunning(sandbox.directory))
        let output = Lines()
        try Service.status(directory: sandbox.directory, output: output.append)
        #expect((output.text + "\n").hasPrefix("Enabled\n"), "\(output.text)")
    }

    // test_invalid_or_missing_parent_pid_keeps_normal_cli_mode
    @Test func invalidOrMissingParentPIDKeepsNormalCLIMode() {
        let original = ProcessInfo.processInfo.environment["CODEX_WHIP_PARENT_PID"]
        defer {
            if let original { setenv("CODEX_WHIP_PARENT_PID", original, 1) } else { unsetenv("CODEX_WHIP_PARENT_PID") }
        }
        for value in [nil, "", "invalid", "0", "-10"] as [String?] {
            unsetenv("CODEX_WHIP_PARENT_PID")
            if let value { setenv("CODEX_WHIP_PARENT_PID", value, 1) }
            #expect(configuredParentPID() == nil, "\(String(describing: value))")
        }
        setenv("CODEX_WHIP_PARENT_PID", "123", 1)
        #expect(configuredParentPID() == 123)
    }

    // test_process_liveness_accepts_existing_process_and_permission_denial
    // Python mocked os.kill; here a live process and launchd (signal permission denied) are probed.
    @Test func processLivenessAcceptsExistingProcessAndPermissionDenial() throws {
        #expect(processAlive(getpid()))
        try #require(getuid() != 0, "Permission denial needs a non-root user")
        #expect(kill(1, 0) == -1 && errno == EPERM)
        #expect(processAlive(1))
    }

    // test_process_liveness_rejects_missing_process
    @Test func processLivenessRejectsMissingProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(!processAlive(process.processIdentifier))
    }

    // test_missing_codex_error_opens_with_the_words_the_native_app_recognizes
    @Test func missingCodexErrorOpensWithTheWordsTheNativeAppRecognizes() throws {
        // The menu replaces this error, socket path included, with plain words.
        let source = try String(contentsOf: HelperProcess.engineDirectory.appendingPathComponent("../native/App.swift"),
                                encoding: .utf8)
        let after = try #require(source.components(separatedBy: "missingCodexMessage = \"").dropFirst().first)
        let recognized = try #require(after.components(separatedBy: "\"").first)
        let sandbox = try AppSandbox()
        defer { sandbox.remove() }
        do {
            _ = try resolveSocket(sandbox.codexHome)
            Issue.record("resolveSocket did not throw")
        } catch let error as RPCError {
            #expect(describe(error).hasPrefix(recognized + ":"), "\(describe(error))")
        }
    }

    // MARK: Parent shutdown
    //
    // Python mocked getppid, process_alive and the engine. Here the built worker runs under a
    // /bin/sh parent that execs into `sleep`, and the "UI" is either that parent or a separate
    // `sleep` process; the test kills one of them and watches the worker stop on its own.

    private struct ParentRun {
        let root: URL
        let stateDirectory: URL
        let stub: StalledCodexStub
        let parent: Process
        let ui: Process?
        let worker: pid_t

        /// Running and not a zombie: a parent that execs into `sleep` never reaps the worker.
        var workerAlive: Bool {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, worker]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
            return info.kp_proc.p_stat != SZOMB
        }

        func cleanup() {
            if workerAlive { kill(worker, SIGKILL) }
            if parent.isRunning { parent.terminate(); parent.waitUntilExit() }
            if let ui, ui.isRunning { ui.terminate(); ui.waitUntilExit() }
            stub.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func startParentRun(phase: StalledCodexStub.Phase, separateUI: Bool) throws -> ParentRun {
        let root = try HelperProcess.temporaryDirectory("ckg-parent-")
        let stateDirectory = root.appendingPathComponent("state")
        try HelperProcess.writeState(stateDirectory)
        let codexHome = root.appendingPathComponent("codex")
        let socketPath = codexHome.appendingPathComponent("app-server-control/app-server-control.sock")
        try FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try StalledCodexStub(socketPath: socketPath.path, phase: phase)
        var ui: Process?
        var extra: [String: String] = [:]
        if separateUI {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["600"]
            try process.run()
            ui = process
            extra["WHIP_UI_PID"] = String(process.processIdentifier)
        }
        let pidFile = root.appendingPathComponent("worker-pid.txt")
        extra["WHIP_PID_FILE"] = pidFile.path
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "CODEX_WHIP_PARENT_PID=${WHIP_UI_PID:-$$} \"$0\" \"$@\" & echo $! > \"$WHIP_PID_FILE\"; exec /bin/sleep 600",
                            try HelperProcess.executable().path,
                            "--state-dir", stateDirectory.path, "--codex-home", codexHome.path, "_run"]
        parent.environment = HelperProcess.environment(extra)
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        try parent.run()
        var worker: pid_t = 0
        _ = HelperProcess.waitUntil(5) {
            let text = (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            worker = text.flatMap { pid_t($0) } ?? 0
            return worker > 0
        }
        let run = ParentRun(root: root, stateDirectory: stateDirectory, stub: stub, parent: parent, ui: ui, worker: worker)
        guard worker > 0 else {
            run.cleanup()
            throw WhipError("The worker did not start")
        }
        return run
    }

    private func expectCleanStop(_ run: ParentRun, within seconds: Double) {
        #expect(HelperProcess.waitUntil(seconds) { !run.workerAlive }, "Worker kept running after losing its parent")
        #expect(HelperProcess.waitUntil(1) { !HelperProcess.lockHeld(run.stateDirectory) })
        #expect(!FileManager.default.fileExists(atPath: run.stateDirectory.appendingPathComponent("worker.pid").path))
        let events = HelperProcess.events(run.stateDirectory)
        #expect(!events.contains { $0["event"] == "connection_error" }, "\(events)")
        #expect(!events.contains { $0["event"] == "retry" }, "\(events)")
        #expect(events.last?["event"] == "stopped", "\(events)")
    }

    private func exerciseParentShutdown(duringStep: Bool, separateUI: Bool = false, loseUI: Bool = false) throws {
        let run = try startParentRun(phase: duringStep ? .rpc : .serve, separateUI: separateUI)
        defer { run.cleanup() }
        #expect(run.stub.ready.wait(timeout: .now() + 15) == .success, "Worker did not reach Codex")
        try #require(run.stub.errors.isEmpty, "\(run.stub.errors)")
        if !duringStep {
            // The step finished; wait until its scan is saved and the worker is sleeping.
            let saved = HelperProcess.waitUntil(5) {
                (try? FileStore.readJSON(run.stateDirectory.appendingPathComponent("state.json")))?["last_scan_at"]?.number != nil
            }
            #expect(saved, "The worker never finished its first scan")
        }
        // Before the loss, the worker keeps running even when the UI is not its direct parent.
        usleep(400_000)
        try #require(run.workerAlive, "The worker stopped before its parent or UI was lost")
        #expect(HelperProcess.lockHeld(run.stateDirectory))
        if loseUI {
            run.ui!.terminate()
            run.ui!.waitUntilExit()
        } else {
            run.parent.terminate()
            run.parent.waitUntilExit()
        }
        expectCleanStop(run, within: 2)
        #expect(run.stub.methods.filter { $0 == "thread/loaded/list" }.count == 1, "\(run.stub.methods)")
    }

    // test_parent_death_reaches_engine_stop_predicate_before_submission
    @Test func parentDeathReachesEngineStopPredicateBeforeSubmission() throws {
        try exerciseParentShutdown(duringStep: true)
    }

    // test_worker_stops_during_scan_sleep_after_parent_death
    @Test func workerStopsDuringScanSleepAfterParentDeath() throws {
        try exerciseParentShutdown(duringStep: false)
    }

    // test_frozen_worker_accepts_distinct_bootloader_parent
    @Test func frozenWorkerAcceptsDistinctBootloaderParent() throws {
        try exerciseParentShutdown(duringStep: true, separateUI: true)
    }

    // test_ui_exit_stops_worker_while_bootloader_parent_is_unchanged
    @Test func uiExitStopsWorkerWhileBootloaderParentIsUnchanged() throws {
        try exerciseParentShutdown(duringStep: true, separateUI: true, loseUI: true)
    }
}
