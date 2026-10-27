#!/usr/bin/env python3
"""Exercise quiet update notices through Sparkle and the real macOS menu.

Requires Accessibility/Screen Recording access and the maintainer's existing
update-signing Keychain item. Uses QA app copies, unique preference domains,
missing Codex homes and a loopback-only server. Never installs an update or
connects to Codex. Screenshots are actual native menu/dialog captures.
"""

import argparse
import functools
import http.server
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import threading
import time
import uuid

import sparkle
from test_updater import read_report, run, wait_for


ROOT = Path(__file__).resolve().parents[1]


def is_update_notice(title):
    """The menu names the available version, or falls back to a generic title."""
    return title.startswith("Update to Version ") or title == "Install Update…"


def script(body, *arguments):
    source = "on run argv\n" + body + "\nend run"
    return run(["osascript", "-e", source, "--", *arguments], timeout=12).stdout.decode().strip()


class Fixture:
    def __init__(self, app, tools, base, current):
        self.directory = base / ("current" if current else "available")
        self.directory.mkdir()
        self.domain = "com.aktay.codex-keep-going.qa.notice." + uuid.uuid4().hex
        self.state = self.directory / "state"
        self.report = self.directory / "updates.json"
        self.app = self.directory / "installed/Codex Whip Notice QA.app"
        self.requests = []
        self.pid = None
        self.window_tool = base / "window-info"
        requests = self.requests

        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                super().do_GET()

            def log_message(self, *_):
                pass

        handler = functools.partial(Handler, directory=str(self.directory))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{self.server.server_port}/"
        target_version = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
        # The feed's display version is the target copy's short version string set below.
        self.notice = f"Update to Version {target_version}…"
        for destination, version in ((self.app, target_version if current else "1.0.0"),
                                     (self.directory / "target/Codex Whip Notice QA.app", target_version)):
            shutil.copytree(app, destination, symlinks=True)
            info_path = destination / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info.update({
                "CFBundleIdentifier": self.domain,
                "CFBundleName": "Codex Whip Notice QA",
                "CFBundleDisplayName": "Codex Whip Notice QA",
                "CFBundleVersion": version,
                "CFBundleShortVersionString": version,
                "SUDefaultsDomain": self.domain,
                "SUFeedURL": url + "appcast.xml",
                "SUEnableAutomaticChecks": False,
                "SUAutomaticallyUpdate": False,
                "KeepGoingQAStateDirectory": str(self.state),
                "KeepGoingQACodexHome": str(self.directory / "missing-codex"),
                "KeepGoingQAUpdateFeed": url + "appcast.xml",
                "KeepGoingQAUpdateReport": str(self.report),
                "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
            })
            info_path.write_bytes(plistlib.dumps(info))
            run(["codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", destination])
        target = self.directory / "target/Codex Whip Notice QA.app"
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", target, self.directory / "Update.zip"])
        run([tools / "bin/generate_appcast", "--account", sparkle.KEYCHAIN_ACCOUNT,
             "--download-url-prefix", url, "--maximum-deltas", "0", "-o",
             self.directory / "appcast.xml", self.directory])
        run([tools / "bin/sign_update", "--account", sparkle.KEYCHAIN_ACCOUNT,
             "--verify", self.directory / "appcast.xml"])
        # Simulate the old menu's persisted coupled OFF state, in a QA domain.
        for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate"):
            self.preference(key, False)
        run(["defaults", "write", self.domain, "AppleLanguages", "-array", "en"])

    def preference(self, key, value):
        assert ".qa." in self.domain
        run(["defaults", "write", self.domain, key, "-bool", "true" if value else "false"])

    def launch(self, background=True):
        started = time.time()
        arguments = ["--test-update-background"] if background else []
        run(["open", "-n", self.app, "--args", *arguments])
        expression = "^" + re.escape(str(self.app / "Contents/MacOS/CodexWhip")) + "( |$)"

        def process():
            result = subprocess.run(["pgrep", "-f", expression], capture_output=True, text=True)
            values = result.stdout.splitlines()
            return int(values[0]) if len(values) == 1 else None

        self.pid = wait_for(process, "isolated app launch", timeout=15)
        wait_for(lambda: any(e["event"] == "started" and e["time"] >= started
                             for e in read_report(self.report).get("events", [])), "updater start", timeout=15)
        wait_for(lambda: (self.state / "worker.pid").exists(), "isolated helper ready", timeout=30)

    def event(self, name):
        return any(e["event"] == name for e in read_report(self.report).get("events", []))

    def ui(self, body, *args):
        return script('tell application "System Events"\n'
                      'tell (first application process whose unix id is (item 1 of argv as integer))\n'
                      + body + '\nend tell\nend tell', str(self.pid), *args)

    def open_menu(self):
        if self.visible_windows(menu=True):
            return None
        # AXPress may wait for menu tracking to end, so dispatch it separately.
        source = ('tell application "System Events" to tell '
                  f'(first application process whose unix id is {self.pid})\n'
                  'perform action "AXPress" of menu bar item 1 of menu bar 1\nend tell')
        process = subprocess.Popen(["osascript", "-e", source], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        wait_for(lambda: self.visible_windows(menu=True), "native menu open", timeout=10)
        return process

    def visible_windows(self, menu):
        data = json.loads(run([self.window_tool, str(self.pid)]).stdout)
        return [w for w in data if w["width"] > 100 and w["height"] > 50
                and ((w["layer"] > 0) if menu else (w["layer"] == 0))]

    def menu_names(self):
        try:
            return self.ui('set output to ""\n'
                           'repeat with entry in menu items of menu 1 of menu bar item 1 of menu bar 1\n'
                           'if name of entry is not missing value then set output to output & name of entry & linefeed\n'
                           'end repeat\nreturn output').splitlines()
        except RuntimeError:
            return []

    def click_menu(self, title):
        self.open_menu()
        self.ui('click menu item (item 2 of argv) of menu 1 of menu bar item 1 of menu bar 1', title)

    def window_buttons(self):
        return self.ui('set output to ""\nrepeat with w in windows\n'
                       'repeat with b in buttons of w\n'
                       'if name of b is not missing value then set output to output & name of b & linefeed\n'
                       'end repeat\nend repeat\nreturn output').splitlines()

    def capture(self, target, menu):
        if menu:
            self.open_menu()
        window = self.visible_windows(menu=menu)[0]
        run(["screencapture", "-x", "-o", "-l", str(window["id"]), target])
        assert target.stat().st_size > 1000, "Native capture is empty"

    def quit(self):
        if self.pid is None:
            return
        self.ui('set frontmost to true\nkey code 53')
        script('tell application id (item 1 of argv) to quit', self.domain)
        pid = self.pid

        def stopped():
            result = subprocess.run(["ps", "-p", str(pid), "-o", "pid="], capture_output=True)
            return result.returncode != 0

        wait_for(stopped, "QA app exit", timeout=20)
        wait_for(lambda: not (self.state / "worker.pid").exists(), "QA worker exit", timeout=15)
        self.pid = None

    def close(self):
        try:
            self.quit()
        finally:
            self.server.shutdown()
            self.server.server_close()
            subprocess.run(["defaults", "delete", self.domain], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)


def available_case(app, tools, base, captures):
    fixture = Fixture(app, tools, base, current=False)
    try:
        fixture.launch()
        wait_for(lambda: fixture.event("update-notice-shown"), "gentle update notice", timeout=30)
        report = read_report(fixture.report)
        assert report["available_version"], report
        assert report["quiet_checks_migrated"] and report["automatically_checks"], report
        assert not report["automatically_downloads"], report
        assert not any(path.endswith(".zip") for path in fixture.requests), fixture.requests
        assert fixture.ui("return count of windows") == "0", "Scheduled check opened an update window"
        fixture.open_menu()
        assert fixture.menu_names()[0] == fixture.notice, fixture.menu_names()
        assert fixture.ui('return enabled of menu item (item 2 of argv) of '
                          'menu 1 of menu bar item 1 of menu bar 1', fixture.notice) == "true"
        fixture.capture(captures / "update-notice-menu.png", menu=True)
        # A pending session must remain reachable even if auto-install is enabled.
        fixture.click_menu("Automatic Updates")
        wait_for(lambda: read_report(fixture.report).get("automatically_downloads"), "auto-install on")
        assert read_report(fixture.report)["available_version"]
        fixture.open_menu()
        assert fixture.menu_names()[0] == fixture.notice
        fixture.click_menu("Automatic Updates")
        wait_for(lambda: not read_report(fixture.report).get("automatically_downloads"), "auto-install off")
        assert read_report(fixture.report)["automatically_checks"]
        fixture.open_menu()
        fixture.click_menu(fixture.notice)
        wait_for(lambda: "Install Update" in fixture.window_buttons(), "standard update dialog", timeout=15)
        assert not read_report(fixture.report)["automatically_downloads"]
        assert not any(path.endswith(".zip") for path in fixture.requests), fixture.requests
        fixture.capture(captures / "update-notice-dialog.png", menu=False)
        fixture.ui('click button "Skip This Version" of window 1')
        wait_for(lambda: read_report(fixture.report).get("available_version") is None,
                 "notice cleared after skipping update", timeout=10)
        assert fixture.event("update-notice-cleared")
        fixture.open_menu()
        assert not any(map(is_update_notice, fixture.menu_names())), fixture.menu_names()
        return {"quiet_notice": True, "no_unrequested_window_or_archive_download": True,
                "migration_preserved_download_opt_out": True, "pending_notice_survives_toggle": True,
                "notice_opens_standard_dialog": True, "skip_clears_notice": True,
                "requests": fixture.requests}
    finally:
        fixture.close()


def current_case(app, tools, base, captures):
    fixture = Fixture(app, tools, base, current=True)
    try:
        fixture.launch()
        wait_for(lambda: fixture.event("no-update"), "up-to-date scheduled check", timeout=30)
        report = read_report(fixture.report)
        assert report.get("available_version") is None, report
        assert report["automatically_checks"] and not report["automatically_downloads"], report
        fixture.open_menu()
        assert not any(map(is_update_notice, fixture.menu_names())), fixture.menu_names()
        fixture.capture(captures / "update-current-menu.png", menu=True)
        fixture.quit()
        fixture.preference("SUEnableAutomaticChecks", False)
        previous_requests = len(fixture.requests)
        fixture.launch(background=False)
        report = read_report(fixture.report)
        assert report["quiet_checks_migrated"] and not report["automatically_checks"], report
        assert not report["automatically_downloads"] and report.get("available_version") is None, report
        assert sum(e["event"] == "quiet-update-checks-enabled" for e in report["events"]) == 1, report
        assert len(fixture.requests) == previous_requests, "Migration restarted an explicitly disabled scheduler"
        return {"no_notice_when_current": True, "migration_runs_once": True,
                "later_check_preference_preserved": True}
    finally:
        fixture.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="A compiled app with native update notices")
    parser.add_argument("--capture-dir", type=Path, help="Directory for actual native screenshots")
    args = parser.parse_args()
    app = args.app.resolve()
    assert (app / "Contents/MacOS/CodexWhip").is_file(), app
    base = ROOT / "build/update-notice-qa" / uuid.uuid4().hex
    base.mkdir(parents=True)
    window_source = base / "window-info.swift"
    window_source.write_text('''import Foundation
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
let result: [[String: Any]] = windows.compactMap { window in
    guard window[kCGWindowOwnerPID as String] as? Int == pid,
          let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return ["id": window[kCGWindowNumber as String]!, "layer": window[kCGWindowLayer as String]!,
            "width": bounds["Width"]!, "height": bounds["Height"]!]
}
print(String(data: try! JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
''')
    run(["xcrun", "swiftc", "-O", window_source, "-o", base / "window-info"])
    captures = args.capture_dir.resolve() if args.capture_dir else base / "captures"
    captures.mkdir(parents=True, exist_ok=True)
    print(f"QA evidence: {base}", flush=True)
    tools = sparkle.distribution(ROOT)
    result = {"available": available_case(app, tools, base, captures),
              "current": current_case(app, tools, base, captures),
              "captures": str(captures)}
    (base / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2), flush=True)
    print("PASS: quiet update notice, menu action, preference migration and pending-session behavior.", flush=True)


if __name__ == "__main__":
    main()
