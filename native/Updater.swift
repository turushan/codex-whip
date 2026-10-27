import AppKit
import Sparkle

/// Sparkle owns update preferences and its standard user interface. The app
/// supplies only menu actions, helper shutdown, and explicitly isolated QA.
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var onChange: (() -> Void)?
    var prepareForInstallation: ((@escaping () -> Void) -> Void)?
    var installationDidAbort: (() -> Void)?

    private var controller: SPUStandardUpdaterController?
    private var availabilityObservation: NSKeyValueObservation?
    private let isolated: Bool
    private let testFeed: URL?
    private let reportURL: URL?
    private var events: [[String: Any]] = []
    private var foundVersion: String?
    private var lastError: String?
    private static let quietCheckMigrationKey = "QuietUpdateChecksMigrated"
    private static let automaticUpdatesChoiceKey = "AutomaticUpdatesChosen"
    private static let automaticUpdatesMigrationKey = "AutomaticUpdatesDefaultApplied"

    private(set) var availableUpdateVersion: String?

    var isEnabled: Bool { controller != nil }
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates == true }
    var automaticUpdatesEnabled: Bool {
        guard let updater = controller?.updater else { return false }
        return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }

    init(isolated: Bool) {
        self.isolated = isolated
        let environment = ProcessInfo.processInfo.environment
        let qaFeed = isIsolatedQABundle() ? Bundle.main.object(forInfoDictionaryKey: "WhipQAUpdateFeed") as? String : nil
        let rawFeed = environment["CODEX_WHIP_UPDATE_FEED"] ?? qaFeed
        if isolated, let rawFeed,
           let url = URL(string: rawFeed),
           url.isFileURL || url.scheme == "https"
                || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")) {
            testFeed = url
        } else {
            testFeed = nil
        }
        let qaReport = isIsolatedQABundle() ? Bundle.main.object(forInfoDictionaryKey: "WhipQAUpdateReport") as? String : nil
        if isolated, let path = environment["CODEX_WHIP_UPDATE_REPORT"] ?? qaReport, !path.isEmpty {
            reportURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        } else {
            reportURL = nil
        }
        super.init()
        if let reportURL, let data = try? Data(contentsOf: reportURL),
           let prior = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            events = Array((prior["events"] as? [[String: Any]] ?? []).suffix(200))
            foundVersion = prior["found_version"] as? String
        }

        // An ordinary isolated UI or lifecycle test must not contact the live
        // release feed or change the user's saved update preferences.
        guard !isolated || testFeed != nil else {
            if rawFeed != nil {
                lastError = "The isolated update feed must be a file, HTTPS URL, or loopback HTTP URL."
            }
            record("disabled-in-isolated-qa")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: self,
                                                      userDriverDelegate: self)
        self.controller = controller
        availabilityObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            self?.onChange?()
        }
        migrateQuietUpdateChecks()
        applyAutomaticUpdatesDefault()
        let arguments = ProcessInfo.processInfo.arguments
        if isolated && testFeed != nil && arguments.contains("--test-update-toggle") {
            // Test Sparkle's actual preference setters before starting its
            // scheduler so this preference-only test cannot install an update.
            testAutomaticUpdatesToggle()
            return
        }
        controller.startUpdater()
        record("started")
        if isolated && testFeed != nil && arguments.contains("--test-update-check") {
            record("checking-information")
            controller.updater.checkForUpdateInformation()
        } else if isolated && testFeed != nil && arguments.contains("--test-update-ui") {
            checkForUpdates(nil)
        } else if isolated && testFeed != nil && arguments.contains("--test-update-background") {
            record("checking-in-background")
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates, let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        record("checking-with-standard-ui")
        controller.checkForUpdates(sender)
    }

    func toggleAutomaticUpdates() {
        guard let updater = controller?.updater else { return }
        let enabled = !automaticUpdatesEnabled
        // Daily checks can announce a release without downloading or installing it.
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = enabled
        UserDefaults.standard.set(true, forKey: Self.automaticUpdatesChoiceKey)
        record("automatic-updates-changed")
        onChange?()
    }

    private func migrateQuietUpdateChecks() {
        let defaultsDomain = Bundle.main.object(forInfoDictionaryKey: "SUDefaultsDomain") as? String
        let safeQADomain = defaultsDomain.map { $0.split(separator: ".").contains("qa") } ?? true
        guard !isolated || (isIsolatedQABundle() && safeQADomain),
              !UserDefaults.standard.bool(forKey: Self.quietCheckMigrationKey),
              let updater = controller?.updater else { return }
        // Earlier versions coupled checking to the automatic-install toggle.
        // Migrate that preference once, preserving the download/install choice.
        updater.automaticallyChecksForUpdates = true
        UserDefaults.standard.set(true, forKey: Self.quietCheckMigrationKey)
        record("quiet-update-checks-enabled")
    }

    /// Automatic Updates start on. Earlier versions could save "off" without the person choosing it,
    /// through the identity change in 1.10 or the update window's checkbox, so this turns it on
    /// once. A choice made later from the menu is kept.
    private func applyAutomaticUpdatesDefault() {
        guard !isolated,
              !UserDefaults.standard.bool(forKey: Self.automaticUpdatesMigrationKey),
              !UserDefaults.standard.bool(forKey: Self.automaticUpdatesChoiceKey),
              let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        UserDefaults.standard.set(true, forKey: Self.automaticUpdatesMigrationKey)
        record("automatic-updates-default-applied")
    }

    private func testAutomaticUpdatesToggle() {
        let defaultsDomain = Bundle.main.object(forInfoDictionaryKey: "SUDefaultsDomain") as? String
        let isolatedPreferences = defaultsDomain.map { $0.split(separator: ".").contains("qa") } ?? true
        guard isolated, isIsolatedQABundle(), isolatedPreferences, let updater = controller?.updater else {
            lastError = "The update-toggle test requires a QA bundle and a QA-only preferences domain."
            record("toggle-test-failed")
            return
        }
        func preferences() -> [String: Any] {
            ["automatically_checks": updater.automaticallyChecksForUpdates,
             "automatically_downloads": updater.automaticallyDownloadsUpdates]
        }
        record("toggle-test-initial", fields: preferences())
        if !automaticUpdatesEnabled { toggleAutomaticUpdates() }
        guard automaticUpdatesEnabled else {
            lastError = "Automatic updates did not enable before the off/on test."
            record("toggle-test-failed", fields: preferences())
            return
        }
        toggleAutomaticUpdates()
        let disabled = updater.automaticallyChecksForUpdates && !updater.automaticallyDownloadsUpdates
        record("toggle-test-off", fields: preferences())
        toggleAutomaticUpdates()
        let enabled = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        record("toggle-test-on", fields: preferences())
        if disabled && enabled {
            lastError = nil
            record("toggle-test-passed")
        } else {
            lastError = "Automatic installation did not switch off and on while update checks stayed enabled."
            record("toggle-test-failed")
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        // A delegate override is ephemeral. It never replaces the production
        // feed URL in Sparkle's persistent preferences.
        isolated ? testFeed?.absoluteString : nil
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundVersion = item.versionString
        lastError = nil
        record("found-update", fields: ["display_version": item.displayVersionString])
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        foundVersion = nil
        clearUpdateNotice()
        lastError = error.localizedDescription
        record("no-update")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        record("downloaded", fields: ["update_version": item.versionString])
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        record("extracted", fields: ["update_version": item.versionString])
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let prepareForInstallation else { return false }
        record("stopping-helper-before-install", fields: ["update_version": item.versionString])
        prepareForInstallation { [weak self] in
            self?.record("helper-stopped-before-install")
            installHandler()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        clearUpdateNotice()
        record("installing", fields: ["update_version": item.versionString])
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        // Sparkle calls this only after an automatic download. Honor the user's
        // download/install opt-in, then update this always-running utility now
        // instead of waiting for a future quit or Sparkle's impatient reminder.
        guard updater.automaticallyDownloadsUpdates else { return false }
        record("automatic-install-ready", fields: ["update_version": item.versionString])
        if let prepareForInstallation {
            prepareForInstallation { [weak self] in
                self?.record("helper-stopped-before-automatic-install")
                immediateInstallHandler()
            }
        } else {
            let runLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, immediateInstallHandler)
            CFRunLoopWakeUp(runLoop)
        }
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        record("relaunching")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        clearUpdateNotice()
        lastError = error.localizedDescription
        record("aborted")
        installationDidAbort?()
        onChange?()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { lastError = error.localizedDescription }
        record("cycle-finished")
        onChange?()
    }

    func standardUserDriverWillShowModalAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                               andInImmediateFocus immediateFocus: Bool) -> Bool {
        automaticUpdatesEnabled
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            availableUpdateVersion = update.displayVersionString
            record("update-notice-shown")
            onChange?()
        }
        if state.userInitiated { NSApp.activate(ignoringOtherApps: true) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        record("update-received-attention")
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearUpdateNotice()
    }

    private func clearUpdateNotice() {
        guard availableUpdateVersion != nil else { return }
        availableUpdateVersion = nil
        record("update-notice-cleared")
        onChange?()
    }

    private func record(_ event: String, fields: [String: Any] = [:]) {
        guard isolated, let reportURL else { return }
        events.append([
            "event": event, "time": Date().timeIntervalSince1970,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "",
        ].merging(fields) { _, new in new })
        events = Array(events.suffix(200))
        let updater = controller?.updater
        let report: [String: Any] = [
            "status": event,
            "enabled": isEnabled,
            "isolated": isolated,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "",
            "feed": testFeed?.absoluteString as Any? ?? NSNull(),
            "found_version": foundVersion as Any? ?? NSNull(),
            "available_version": availableUpdateVersion as Any? ?? NSNull(),
            "quiet_checks_migrated": UserDefaults.standard.bool(forKey: Self.quietCheckMigrationKey),
            "error": lastError as Any? ?? NSNull(),
            "can_check": canCheckForUpdates,
            "automatically_checks": updater?.automaticallyChecksForUpdates == true,
            "automatically_downloads": updater?.automaticallyDownloadsUpdates == true,
            "events": events,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        } catch {
            NSLog("Could not write the isolated update report: %@", error.localizedDescription)
        }
    }
}
