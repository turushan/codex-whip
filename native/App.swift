import AppKit
import CoreFoundation
import Darwin
import ServiceManagement

// The approved surface is a standard macOS status menu. System typography,
// spacing, materials, focus, and keyboard behavior own its presentation.

private let appName = "Codex Whip"
private let advisoryLock: (Int32, Int32) -> Int32 = flock

func isIsolatedQABundle() -> Bool {
    Bundle.main.bundleIdentifier?.split(separator: ".").contains("qa") == true
}

private struct Dashboard: Decodable {
    var state: HelperState?
    var history: HistoryReport?
    var running: Bool?
}

private struct HelperState: Decodable {
    var sessions: SessionCounts?
    var pending: [String: PendingRetry]?
    var lastScanAt: Double?
    var lastError: String?
}

private struct SessionCounts: Decodable {
    var total: Int?
    var active: Int?
    var idle: Int?
    var errored: Int?
}

private struct PendingRetry: Decodable {
    var dueAt: Double?
    var model: String?
    var kind: String?
    var quotaStatus: String?
}

private struct HistoryReport: Decodable {
    var available: Bool?
    var capacity: Int?
    var retries: Int?
    var successful: Int?
    var completed: Int?
    var failed: Int?
    var failedCapacity: Int?
    var failedOther: Int?
    var interrupted: Int?
    var uncertain: Int?
    var awaiting: Int?
    var quota: Int?
    var quotaRetries: Int?
    var quotaSuccessful: Int?
    var quotaCompleted: Int?
    var quotaFailed: Int?
    var quotaFailedCapacity: Int?
    var quotaFailedOther: Int?
    var quotaInterrupted: Int?
    var quotaUncertain: Int?
    var quotaAwaiting: Int?
    var recordedSince: Double?
    var recent: [ActivityEvent]?
}

private struct ActivityEvent: Decodable {
    var ts: Double?
    var event: String?
    var threadId: String?
    var status: String?
    var capacity: Bool?
    var kind: String?
}

private struct CommandResult {
    var status: Int32
    var output: Data
    var error: String
}

private final class OutputBuffer {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, 2 * 1024 * 1024 - data.count)
        data.append(contentsOf: chunk.prefix(remaining))
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class HelperClient {
    let executable: URL
    let stateDirectory: URL
    private let environment: [String: String]

    init(stateDirectory: URL, codexHomeOverride: String? = nil) {
        self.stateDirectory = stateDirectory
        var environment = ProcessInfo.processInfo.environment
        if let codexHomeOverride { environment["CODEX_HOME"] = codexHomeOverride }
        self.environment = environment
        executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/whip-helper")
    }

    func process(_ command: String) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--state-dir", stateDirectory.path, command]
        var childEnvironment = environment
        childEnvironment.removeValue(forKey: "CODEX_WHIP_PARENT_PID")
        if command == "_run" {
            childEnvironment["CODEX_WHIP_PARENT_PID"] = String(getpid())
        }
        process.environment = childEnvironment
        return process
    }

    // Routine menu refreshes read only the local state and advisory lock. They
    // never launch the frozen executable or connect to a Codex session.
    func localDashboard() -> CommandResult {
        do {
            let stateURL = stateDirectory.appendingPathComponent("state.json")
            var state: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let value = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
                guard let object = value as? [String: Any] else {
                    return CommandResult(status: -1, output: Data(), error: "The local watcher state is invalid.")
                }
                state = object
            }
            let lockURL = stateDirectory.appendingPathComponent("worker.lock")
            let descriptor = Darwin.open(lockURL.path, O_RDONLY | O_CLOEXEC)
            let running: Bool
            if descriptor < 0 {
                let code = errno
                guard code == ENOENT else {
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                running = false
            } else {
                defer { Darwin.close(descriptor) }
                if advisoryLock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    _ = advisoryLock(descriptor, LOCK_UN)
                    running = false
                } else {
                    let code = errno
                    guard code == EWOULDBLOCK || code == EAGAIN else {
                        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                    }
                    running = true
                }
            }
            let data = try JSONSerialization.data(withJSONObject: ["state": state, "running": running])
            return CommandResult(status: 0, output: data, error: "")
        } catch {
            return CommandResult(status: -1, output: Data(), error: error.localizedDescription)
        }
    }

    // Runs only on background queues. Drain both pipes while waiting so a large
    // local report cannot fill a pipe and deadlock the helper.
    func run(_ command: String, timeout: TimeInterval) -> CommandResult {
        let process = process(command)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: Data(), error: error.localizedDescription)
        }
        let readers = DispatchGroup()
        let output = OutputBuffer()
        let errors = OutputBuffer()
        for (handle, buffer) in [(stdout.fileHandleForReading, output),
                                 (stderr.fileHandleForReading, errors)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                    buffer.append(chunk)
                }
            }
        }
        let timedOut = terminated.wait(timeout: .now() + timeout) == .timedOut
        if timedOut && process.isRunning {
            process.terminate()
            if terminated.wait(timeout: .now() + 1.5) == .timedOut && process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
        }
        _ = readers.wait(timeout: .now() + 1)
        let error = String(decoding: errors.value(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(status: timedOut ? -1 : process.terminationStatus,
                             output: output.value(),
                             error: timedOut ? "The helper did not respond in time." : error)
    }
}

private final class WorkerSupervisor {
    enum Phase {
        case starting, running, paused, failed(String)
    }

    private struct Worker {
        let process: Process
        let terminated: DispatchSemaphore
    }

    var onChange: ((Phase, Int32?, Bool) -> Void)?
    private let helper: HelperClient
    private let queue = DispatchQueue(label: "com.aktay.codex-keep-going.supervisor", qos: .utility)
    private var worker: Worker?
    private var prepared = false
    private var shouldRun = false
    private let intentLock = NSLock()
    private var runRequested = false

    init(helper: HelperClient) {
        self.helper = helper
    }

    func start() {
        requestRunning(true)
        queue.async {
            guard self.isRunRequested else { return }
            self.shouldRun = true
            guard self.worker == nil else { return }
            self.publish(.starting)
            guard self.prepareIfNeeded() else { return }
            self.launchWorker()
        }
    }

    func prepareWhilePaused() {
        requestRunning(false)
        queue.async {
            self.shouldRun = false
            guard self.prepareIfNeeded() else { return }
            self.publish(.paused)
        }
    }

    private func prepareIfNeeded() -> Bool {
        if prepared { return true }
        // A cold frozen-runtime launch can include first-use macOS checks.
        let result = helper.run("prepare", timeout: 30)
        guard result.status == 0 else {
            shouldRun = false
            publish(.failed(result.error.isEmpty ? "The helper could not be prepared." : result.error))
            return false
        }
        prepared = true
        return true
    }

    func pause(completion: (() -> Void)? = nil) {
        requestRunning(false)
        queue.async {
            self.shouldRun = false
            self.stopWorker()
            self.publish(.paused)
            if let completion {
                // AppKit can wait in a nested termination run loop while the
                // main dispatch queue is still executing NSApp.terminate.
                // Run-loop delivery permits the termination reply to run there.
                let mainRunLoop = CFRunLoopGetMain()
                CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue, completion)
                CFRunLoopWakeUp(mainRunLoop)
            }
        }
    }

    private func launchWorker() {
        guard shouldRun, isRunRequested, worker == nil else { return }
        let process = helper.process("_run")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { [weak self] process in
            terminated.signal()
            guard let self else { return }
            self.queue.async {
                guard self.worker?.process === process else { return }
                self.worker = nil
                if self.shouldRun && self.isRunRequested {
                    self.shouldRun = false
                    self.publish(.failed("The helper stopped unexpectedly (exit \(process.terminationStatus)). Resume to try again."))
                }
            }
        }
        do {
            try process.run()
            worker = Worker(process: process, terminated: terminated)
            publish(.running)
        } catch {
            shouldRun = false
            publish(.failed(error.localizedDescription))
        }
    }

    private func stopWorker() {
        guard let current = worker else { return }
        worker = nil
        if current.process.isRunning {
            current.process.terminate()
            if current.terminated.wait(timeout: .now() + 2) == .timedOut && current.process.isRunning {
                kill(current.process.processIdentifier, SIGKILL)
                _ = current.terminated.wait(timeout: .now() + 1)
            }
        }
    }

    private func publish(_ phase: Phase) {
        let pid = worker?.process.processIdentifier
        let ready = prepared
        DispatchQueue.main.async { [weak self] in self?.onChange?(phase, pid, ready) }
    }

    private func requestRunning(_ value: Bool) {
        intentLock.lock()
        runRequested = value
        intentLock.unlock()
    }

    private var isRunRequested: Bool {
        intentLock.lock()
        defer { intentLock.unlock() }
        return runRequested
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var updateNoticeItem: NSMenuItem!
    private let updateNoticeSeparator = NSMenuItem.separator()
    private let statusRow = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let nextRetryRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let quotaRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let errorRow = NSMenuItem(title: "The helper needs attention", action: nil, keyEquivalent: "")
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var preferencesMenu: PreferencesMenuController?
    private var preferenceSetupError: String?
    private var showMessageWhenReady = false
    private var demoController: DemoController?
    private var helperReady = false
    private var checkForUpdatesItem: NSMenuItem!
    private var automaticUpdatesItem: NSMenuItem!
    private var appUpdater: AppUpdater?
    private var installingUpdate = false
    private var activityWindow: NSWindow?
    private var activityText: NSTextView?
    private var timer: Timer?
    private var helper: HelperClient!
    private var supervisor: WorkerSupervisor!
    private let dashboardQueue = DispatchQueue(label: "com.aktay.codex-keep-going.dashboard", qos: .utility)
    private let activityQueue = DispatchQueue(label: "com.aktay.codex-keep-going.activity", qos: .utility)
    private var dashboard: Dashboard?
    private var refreshInProgress = false
    private var activityLoading = false
    private var activityError: String?
    private var phase: WorkerSupervisor.Phase = .starting
    private var paused = false
    private var quitting = false
    private var helperError: String?
    private var dashboardError: String?
    private var isolated = false
    private var workerPID: Int32?
    private var dashboardQueryAt: TimeInterval = 0
    private enum TestStage { case initial, paused, resumed, finished }
    private var testStage: TestStage?
    private var testTimer: Timer?
    private var testReportURL: URL?
    private var testStartedAt: TimeInterval = 0
    private var testStageStartedAt: TimeInterval = 0
    private var testInitialPID: Int32?
    private var testEvidence: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        let qaBundle = isIsolatedQABundle()
        let qaState = qaBundle ? Bundle.main.object(forInfoDictionaryKey: "KeepGoingQAStateDirectory") as? String : nil
        let override = environment["CODEX_WHIP_STATE_DIR"] ?? qaState
        isolated = override != nil || qaBundle
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let defaultDirectory = qaBundle
            ? support.appendingPathComponent("Codex Whip QA", isDirectory: true)
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "qa", isDirectory: true)
            : support.appendingPathComponent(appName, isDirectory: true)
        let directory = override.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? defaultDirectory
        let qaCodexHome = qaBundle ? Bundle.main.object(forInfoDictionaryKey: "KeepGoingQACodexHome") as? String : nil
        let fixtureHome = qaCodexHome.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let codexHome = isolated
            ? (fixtureHome ?? directory.appendingPathComponent("missing-codex", isDirectory: true).path)
            : environment["CODEX_HOME"]
        helper = HelperClient(stateDirectory: directory, codexHomeOverride: codexHome)
        supervisor = WorkerSupervisor(helper: helper)
        supervisor.onChange = { [weak self] phase, pid, ready in
            guard let self, !self.quitting else { return }
            self.phase = phase
            self.workerPID = pid
            self.helperReady = ready
            if case .failed(let error) = phase { self.helperError = error }
            else { self.helperError = nil }
            self.updateMenu()
            if ready && self.showMessageWhenReady {
                self.showMessageWhenReady = false
                self.preferencesMenu?.editMessage()
            }
            self.refreshDashboard()
        }
        paused = !isolated && UserDefaults.standard.bool(forKey: "WatcherPaused")
        buildMenu()
        configureUpdater()
        if paused {
            phase = .paused
            supervisor.prepareWhilePaused()
        } else { supervisor.start() }
        updateMenu()
        refreshDashboard()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.refreshDashboard() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--enable-login") {
            if isolated {
                writeLoginReport(error: "Login registration is disabled in isolated QA.")
            } else {
                configureLogin(enabled: true, presentError: false)
            }
        }
        if arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.quitting else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.statusItem.button?.performClick(nil)
            }
        }
        if isolated && arguments.contains("--show-activity") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.quitting else { return }
                self.showActivity()
            }
        }
        if isolated && arguments.contains("--test-pause-resume") {
            if let path = environment["CODEX_WHIP_TEST_REPORT"], !path.isEmpty {
                beginSelfTest(reportURL: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
            } else {
                NSLog("The isolated Pause/Resume test requires CODEX_WHIP_TEST_REPORT.")
            }
        }
        if isolated && arguments.contains("--show-message") {
            showMessageWhenReady = true
            if helperReady {
                showMessageWhenReady = false
                preferencesMenu?.editMessage()
            }
        }
        if isolated && arguments.contains("--show-demo") {
            showDemo()
        }
        if let index = arguments.firstIndex(of: "--quit-after"), arguments.indices.contains(index + 1),
           let seconds = Double(arguments[index + 1]), seconds > 0, seconds.isFinite {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        updateNoticeItem = action("A new update is available…", selector: #selector(checkForUpdates))
        updateNoticeItem.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        updateNoticeItem.image?.size = NSSize(width: 9, height: 9)
        if #available(macOS 27.0, *) {
            // Use the public runtime setter so older SDK builds can opt in too.
            let visibilitySetter = NSSelectorFromString("setPreferredImageVisibility:")
            if updateNoticeItem.responds(to: visibilitySetter) {
                updateNoticeItem.setValue(1, forKey: "preferredImageVisibility") // .visible
            }
        }
        updateNoticeItem.isHidden = true
        updateNoticeSeparator.isHidden = true
        menu.addItem(updateNoticeSeparator)
        let title = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        statusRow.isEnabled = false
        menu.addItem(statusRow)
        nextRetryRow.isEnabled = false
        menu.addItem(nextRetryRow)
        quotaRow.isEnabled = false
        menu.addItem(quotaRow)
        errorRow.isEnabled = false
        menu.addItem(errorRow)
        menu.addItem(.separator())
        pauseItem = action("Pause", selector: #selector(togglePause))
        loginItem = action("Start at Login", selector: #selector(toggleLogin))
        do {
            let defaults = try PreferencesStore.bundledDefaults()
            let store = try PreferencesStore(directory: helper.stateDirectory, defaults: defaults)
            let preferences = PreferencesMenuController(store: store)
            preferences.onChange = { [weak self] in
                self?.updateMenu()
                self?.refreshDashboard()
            }
            preferencesMenu = preferences
            for item in preferences.items { menu.addItem(item) }
        } catch {
            preferenceSetupError = error.localizedDescription
            let unavailable = NSMenuItem(title: "Preferences unavailable", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            unavailable.toolTip = error.localizedDescription
            menu.addItem(unavailable)
        }
        menu.addItem(.separator())
        checkForUpdatesItem = action("Check for Updates…", selector: #selector(checkForUpdates))
        automaticUpdatesItem = action("Automatic Updates", selector: #selector(toggleAutomaticUpdates))
        automaticUpdatesItem.toolTip = "Automatically download and install updates. Quiet daily update checks stay on."
        menu.addItem(.separator())
        _ = action("Activity…", selector: #selector(showActivity))
        _ = action("Watch Demo…", selector: #selector(showDemo))
        _ = action("Quit", selector: #selector(quit), key: "q")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.whip(accessibilityDescription: appName)
        statusItem.button?.setAccessibilityLabel(appName)
        statusItem.menu = menu
    }

    @discardableResult
    private func action(_ title: String, selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
        refreshDashboard()
    }

    private func updateMenu() {
        let failed: Bool
        if case .failed = phase { failed = true } else { failed = false }
        pauseItem.title = paused || failed ? "Resume" : "Pause"
        pauseItem.isEnabled = !installingUpdate
        preferencesMenu?.isReady = helperReady && !installingUpdate
        preferencesMenu?.refresh()
        let preferenceError = preferenceSetupError ?? preferencesMenu?.errorText
        checkForUpdatesItem.isEnabled = appUpdater?.canCheckForUpdates == true && !installingUpdate
        let availableVersion = appUpdater?.availableUpdateVersion
        updateNoticeItem.isHidden = availableVersion == nil
        updateNoticeSeparator.isHidden = availableVersion == nil
        updateNoticeItem.isEnabled = checkForUpdatesItem.isEnabled
        updateNoticeItem.toolTip = availableVersion.map {
            "Version \($0) is available. Review the update and choose when to install."
        }
        automaticUpdatesItem.isEnabled = appUpdater?.isEnabled == true && !installingUpdate
        automaticUpdatesItem.state = appUpdater?.automaticUpdatesEnabled == true ? .on : .off
        errorRow.isHidden = helperError == nil && dashboardError == nil && preferenceError == nil
        errorRow.title = preferenceError == nil ? "The helper needs attention" : "Preferences need attention"
        errorRow.toolTip = preferenceError ?? helperError ?? dashboardError
        if paused || failed || installingUpdate {
            statusRow.title = "Paused"
        } else if case .running = phase, dashboard?.running == true {
            if let error = dashboard?.state?.lastError, !error.isEmpty {
                statusRow.title = preferenceError == nil ? "Waiting for Codex" : "Waiting for preferences"
            } else if let sessions = dashboard?.state?.sessions, dashboard?.state?.lastScanAt != nil {
                let count = sessions.total ?? 0
                statusRow.title = "Watching \(count) \(count == 1 ? "session" : "sessions")"
            } else {
                statusRow.title = "Starting…"
            }
        } else {
            statusRow.title = "Starting…"
        }
        statusItem.button?.toolTip = "\(appName): \(statusRow.title)"
        let pending = Array((dashboard?.state?.pending ?? [:]).values)
        let showPending = !paused && !failed && !installingUpdate
        let due = pending.filter { $0.kind == nil || $0.kind == "capacity" }
            .compactMap(\.dueAt).filter(\.isFinite).min()
        nextRetryRow.isHidden = !showPending || due == nil
        if let due {
            nextRetryRow.title = "Next retry \(countdown(to: due))"
        }
        let quota = pending.filter { $0.kind == "quota" }
        quotaRow.isHidden = !showPending || quota.isEmpty
        let quotaDue = quota.compactMap(\.dueAt).filter(\.isFinite).min()
        if quota.contains(where: { $0.quotaStatus == "account_changed" }) {
            quotaRow.title = "Quota recovery paused · account changed"
            quotaRow.toolTip = "A pending quota retry belongs to another Codex account. It stays on hold until the original account is active. Other sessions continue to be watched."
        } else if quota.contains(where: { $0.quotaStatus == "unknown" }) {
            quotaRow.title = quotaDue.map { "Quota unavailable · check \(countdown(to: $0))" }
                ?? "Quota unavailable · checking again"
            quotaRow.toolTip = "Codex Whip could not confirm the available quota. It will keep checking and hold the retry until quota is available."
        } else {
            quotaRow.title = quotaDue.map { "Waiting for quota · check \(countdown(to: $0))" }
                ?? "Waiting for quota"
            quotaRow.toolTip = "The unfinished work stays on hold until Codex reports available quota. Its retry keeps the saved session settings."
        }
        updateLoginItem()
        updateActivity()
    }

    private func countdown(to due: TimeInterval) -> String {
        let seconds = max(0, ceil(due - Date().timeIntervalSince1970))
        if seconds == 0 { return "soon" }
        if seconds < 60 { return "in \(Int(seconds)) sec" }
        guard let minutes = Int(exactly: ceil(seconds / 60)) else { return "later" }
        return "in \(minutes) min"
    }

    private func updateLoginItem() {
        loginItem.isEnabled = true
        loginItem.title = "Start at Login"
        loginItem.toolTip = nil
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.state = .on
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.title = "Start at Login (Approval Required)"
            loginItem.toolTip = "Approve Codex Whip in System Settings → General → Login Items."
        case .notFound:
            loginItem.state = .off
            loginItem.isEnabled = false
            loginItem.toolTip = "Install the app in Applications to enable starting at login."
        case .notRegistered:
            loginItem.state = .off
        @unknown default:
            loginItem.state = .off
            loginItem.isEnabled = false
        }
    }

    private func configureUpdater() {
        let updater = AppUpdater(isolated: isolated)
        updater.onChange = { [weak self] in self?.updateMenu() }
        updater.prepareForInstallation = { [weak self] completion in
            guard let self else { completion(); return }
            self.installingUpdate = true
            self.updateMenu()
            self.supervisor.pause(completion: completion)
        }
        updater.installationDidAbort = { [weak self] in
            guard let self, self.installingUpdate, !self.quitting else { return }
            self.installingUpdate = false
            if !self.paused { self.supervisor.start() }
            self.updateMenu()
        }
        appUpdater = updater
    }

    @objc private func checkForUpdates() {
        appUpdater?.checkForUpdates(checkForUpdatesItem)
    }

    @objc private func toggleAutomaticUpdates() {
        appUpdater?.toggleAutomaticUpdates()
        updateMenu()
    }

    @MainActor @objc private func showDemo() {
        if demoController == nil { demoController = DemoController() }
        demoController?.present()
    }

    private func refreshDashboard() {
        guard !quitting, !refreshInProgress else { return }
        refreshInProgress = true
        let queryAt = Date().timeIntervalSince1970
        dashboardQueue.async { [weak self] in
            guard let self else { return }
            let result = self.helper.localDashboard()
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = result.status == 0 ? try? decoder.decode(Dashboard.self, from: result.output) : nil
            DispatchQueue.main.async {
                self.refreshInProgress = false
                guard !self.quitting else { return }
                if var decoded {
                    decoded.history = self.dashboard?.history
                    self.dashboard = decoded
                    self.dashboardQueryAt = queryAt
                    self.dashboardError = nil
                } else {
                    self.dashboardError = result.error.isEmpty ? "Could not read local activity." : result.error
                }
                self.updateMenu()
            }
        }
    }

    private func refreshActivity() {
        guard !quitting, !activityLoading else { return }
        activityLoading = true
        activityError = nil
        updateActivity()
        activityQueue.async { [weak self] in
            guard let self else { return }
            let result = self.helper.run("dashboard", timeout: 10)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = result.status == 0 ? try? decoder.decode(Dashboard.self, from: result.output) : nil
            DispatchQueue.main.async {
                self.activityLoading = false
                guard !self.quitting else { return }
                if let history = decoded?.history {
                    if self.dashboard == nil {
                        self.dashboard = Dashboard(state: nil, history: history, running: nil)
                    } else {
                        self.dashboard?.history = history
                    }
                    self.activityError = nil
                } else {
                    self.activityError = result.error.isEmpty ? "Could not read local activity." : result.error
                }
                self.updateActivity()
            }
        }
    }

    @objc private func togglePause() {
        if paused || { if case .failed = phase { return true }; return false }() {
            paused = false
            phase = .starting
            supervisor.start()
        } else {
            paused = true
            phase = .paused
            supervisor.pause()
        }
        if !isolated { UserDefaults.standard.set(paused, forKey: "WatcherPaused") }
        updateMenu()
    }

    @objc private func toggleLogin() {
        let current = SMAppService.mainApp.status
        configureLogin(enabled: current != .enabled && current != .requiresApproval, presentError: true)
    }

    private func configureLogin(enabled: Bool, presentError: Bool) {
        var failure: String?
        do {
            let current = SMAppService.mainApp.status
            if enabled {
                // A registered item awaiting approval must stay registered.
                // Its authorization state is reported rather than called enabled.
                if current != .enabled && current != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else if current == .enabled || current == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error.localizedDescription
            if presentError {
                let alert = NSAlert()
                alert.messageText = "Couldn’t change Start at Login"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        writeLoginReport(error: failure)
        updateLoginItem()
    }

    private func writeLoginReport(error: String?) {
        let status: String
        switch SMAppService.mainApp.status {
        case .enabled: status = "enabled"
        case .requiresApproval: status = "requiresApproval"
        case .notRegistered: status = "notRegistered"
        case .notFound: status = "notFound"
        @unknown default: status = "unknown"
        }
        if ProcessInfo.processInfo.arguments.contains("--enable-login") {
            print("Start at Login: \(status)" + (error.map { ". \($0)" } ?? ""))
        }
        guard let path = ProcessInfo.processInfo.environment["CODEX_WHIP_LOGIN_REPORT"], !path.isEmpty else { return }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let report: [String: Any] = ["status": status, "error": error.map { $0 as Any } ?? NSNull()]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Could not write the login status report: %@", error.localizedDescription)
        }
    }

    @objc private func showActivity() {
        if activityWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "\(appName) Activity"
            window.minSize = NSSize(width: 420, height: 280)
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.isRichText = false
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            text.textColor = .textColor
            text.backgroundColor = .textBackgroundColor
            text.textContainerInset = NSSize(width: 20, height: 20)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            window.contentView?.addSubview(scroll)
            window.center()
            activityWindow = window
            activityText = text
        }
        updateActivity()
        activityWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshDashboard()
        refreshActivity()
    }

    private func updateActivity() {
        guard let text = activityText else { return }
        var lines = ["Last 24 hours", ""]
        if let history = dashboard?.history, history.available != false {
            lines += [
                "Capacity",
                "Errors found: \(history.capacity ?? 0) · Retries sent: \(history.retries ?? 0)",
                "Successful: \(history.successful ?? history.completed ?? 0) · Failed: \(history.failed ?? 0) (\(history.failedCapacity ?? 0) capacity, \(history.failedOther ?? 0) other)",
                "Interrupted: \(history.interrupted ?? 0) · Awaiting recovery: \(history.awaiting ?? 0)",
                "Uncertain sends: \(history.uncertain ?? 0)",
                "", "Quota recovery",
                "Limits found: \(history.quota ?? 0) · Retries sent: \(history.quotaRetries ?? 0)",
                "Successful: \(history.quotaSuccessful ?? history.quotaCompleted ?? 0) · Failed: \(history.quotaFailed ?? 0) (\(history.quotaFailedCapacity ?? 0) capacity, \(history.quotaFailedOther ?? 0) other)",
                "Interrupted: \(history.quotaInterrupted ?? 0) · Awaiting recovery: \(history.quotaAwaiting ?? 0)",
                "Uncertain sends: \(history.quotaUncertain ?? 0)",
                "", "Success: 2 minutes without interruption, or a finished turn.",
            ]
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            if let since = history.recordedSince, since > Date().timeIntervalSince1970 - 86400 {
                lines += ["", "Recording since \(formatter.string(from: Date(timeIntervalSince1970: since)))"]
            }
            let recent = history.recent ?? []
            lines += ["", recent.isEmpty ? "No activity yet." : "Recent activity"]
            for event in recent {
                let label: String
                let origin = event.kind == "quota" ? "Quota" : "Capacity"
                switch event.event {
                case "capacity": label = "Capacity error found"
                case "quota": label = "Quota limit found"
                case "retry": label = "\(origin) retry sent"
                case "uncertain": label = "\(origin) send uncertain"
                case "retry_result":
                    if event.status == "successful" || event.status == "completed" {
                        label = "\(origin) retry successful"
                    } else {
                        label = "\(origin) retry \(event.status ?? "finished")" + (event.capacity == true ? " (capacity)" : "")
                    }
                default: continue
                }
                let timestamp = event.ts.map { formatter.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
                let session = event.threadId.map { String($0.prefix(8)) } ?? ""
                lines.append("\(timestamp) · \(session) · \(label)")
            }
        } else if activityLoading {
            lines.append("Loading activity…")
        } else {
            lines.append("Activity will appear after the helper starts.")
        }
        if activityLoading && dashboard?.history != nil {
            lines += ["", "Updating activity…"]
        }
        if let error = activityError {
            lines += ["", "Activity could not be loaded: \(error)"]
        }
        if let error = helperError ?? dashboardError ?? dashboard?.state?.lastError {
            lines += ["", "Status: \(error)"]
        }
        let content = lines.joined(separator: "\n")
        if text.string != content { text.string = content }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private var phaseName: String {
        switch phase {
        case .starting: return "starting"
        case .running: return "running"
        case .paused: return "paused"
        case .failed: return "failed"
        }
    }

    // These checks use the ordinary menu actions and fresh local reports. They
    // are available only with an explicitly isolated state directory.
    private func beginSelfTest(reportURL: URL) {
        guard isolated else { return }
        testReportURL = reportURL
        testStartedAt = Date().timeIntervalSince1970
        testStageStartedAt = testStartedAt
        testStage = .initial
        writeTestReport(passed: false, status: "running")
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.advanceSelfTest() }
        RunLoop.main.add(timer, forMode: .common)
        testTimer = timer
    }

    private func advanceSelfTest() {
        guard isolated, let stage = testStage, stage != .finished else { return }
        if Date().timeIntervalSince1970 - testStartedAt > 30 {
            finishSelfTest(passed: false, error: "Pause/Resume verification timed out after 30 seconds.")
            return
        }
        if case .failed = phase {
            finishSelfTest(passed: false, error: helperError ?? "The helper failed.")
            return
        }
        refreshDashboard()
        guard dashboardQueryAt >= testStageStartedAt else { return }
        switch stage {
        case .initial:
            guard case .running = phase, dashboard?.running == true, let pid = workerPID else { return }
            testInitialPID = pid
            recordTestStage("initial-running")
            testStage = .paused
            testStageStartedAt = Date().timeIntervalSince1970
            togglePause()
        case .paused:
            guard case .paused = phase, dashboard?.running == false, workerPID == nil,
                  let initialPID = testInitialPID else { return }
            guard kill(initialPID, 0) == -1 && errno == ESRCH else { return }
            recordTestStage("paused-child-exited")
            testStage = .resumed
            testStageStartedAt = Date().timeIntervalSince1970
            togglePause()
        case .resumed:
            guard case .running = phase, dashboard?.running == true,
                  let pid = workerPID, pid != testInitialPID else { return }
            recordTestStage("resumed-new-child")
            finishSelfTest(passed: true)
        case .finished:
            break
        }
    }

    private func recordTestStage(_ name: String) {
        testEvidence.append([
            "stage": name,
            "time": Date().timeIntervalSince1970,
            "phase": phaseName,
            "dashboard_running": dashboard?.running.map { NSNumber(value: $0) } ?? NSNull(),
            "child_pid": workerPID.map { NSNumber(value: $0) } ?? NSNull(),
        ])
        writeTestReport(passed: false, status: "running")
    }

    private func finishSelfTest(passed: Bool, error: String? = nil) {
        guard testStage != nil && testStage != .finished else { return }
        testStage = .finished
        testTimer?.invalidate()
        testTimer = nil
        writeTestReport(passed: passed, status: "finished", error: error)
    }

    private func writeTestReport(passed: Bool, status: String, error: String? = nil) {
        guard isolated, let url = testReportURL else { return }
        var report: [String: Any] = [
            "passed": passed, "status": status, "stages": testEvidence,
            "initial_child_pid": testInitialPID.map { NSNumber(value: $0) } ?? NSNull(),
            "elapsed_seconds": Date().timeIntervalSince1970 - testStartedAt,
        ]
        if let error { report["error"] = error }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Could not write the isolated self-test report: %@", error.localizedDescription)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        finishSelfTest(passed: false, error: "The app quit before Pause/Resume verification finished.")
        quitting = true
        timer?.invalidate()
        demoController?.stop()
        menu.cancelTracking()
        supervisor.pause { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
private enum ApplicationMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
