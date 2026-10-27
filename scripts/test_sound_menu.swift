// Native menu behavior QA. Uses isolated preferences and never opens a window or plays audio.
// swiftc native/Preferences.swift native/Settings.swift scripts/test_sound_menu.swift -o build/sound-menu-qa
import AppKit
import Foundation

private struct TestFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@main
private struct SoundMenuTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw TestFailure(message) }
    }

    static func run(in directory: URL) throws {
        let defaults = RetrySettings(retrySeconds: 180, scanSeconds: 300, message: "Continue.")
        let store = try PreferencesStore(directory: directory, defaults: defaults)
        let custom = RetrySettings(retrySeconds: 777, scanSeconds: 123, message: "Preserve my exact message 👩🏽‍💻.")
        try store.write(custom)
        let controller = PreferencesMenuController(store: store)
        var changed = 0
        controller.onChange = { changed += 1 }
        guard let item = controller.items.first(where: { $0.title == "Whip Sound" }),
              let action = item.action else {
            throw TestFailure("The native menu must expose its Whip Sound action")
        }
        try check(Thread.isMainThread, "Menu actions must run on the main thread")
        try check(!item.isEnabled && item.state == .off, "Sound is off and disabled until preferences are ready")
        NSApp.sendAction(action, to: item.target, from: item)
        try check(try store.read() == custom && changed == 0, "An unready action must not change preferences")

        controller.isReady = true
        try check(item.isEnabled && item.state == .off, "Ready preferences show the unchecked native menu item")
        NSApp.sendAction(action, to: item.target, from: item)
        var expected = custom
        expected.soundEnabled = true
        try check(try store.read() == expected, "The action enables sound and preserves custom timing and message")
        try check(item.state == .on && changed == 1, "The action immediately checks the item and reports one change")
        NSApp.sendAction(action, to: item.target, from: item)
        try check(try store.read() == custom, "The next action turns sound off without changing other preferences")
        try check(item.state == .off && changed == 2, "Turning sound off immediately unchecks the item")

        try store.update { $0.soundEnabled = true }
        controller.refresh()
        try check(item.state == .on && changed == 2, "The menu reflects external CLI changes without saving or previewing")
        controller.isReady = false
        try check(!item.isEnabled, "A paused preparation state disables the sound control")
        NSApp.sendAction(action, to: item.target, from: item)
        try check(try store.read().soundEnabled && changed == 2, "A disabled action preserves the saved sound preference")
        try check(NSApp.activationPolicy() == .prohibited && !NSApp.isActive, "QA must never activate the application")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-whip-sound-menu-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try run(in: directory)
            print("PASS: \(checks) native sound menu checks; no windows, playback, or activation")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
