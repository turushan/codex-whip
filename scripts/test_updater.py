#!/usr/bin/env python3
"""Explicit Mac integration test: signed local upgrade and tampered-archive rejection.

Requires a built app and the release Keychain key. Never connects to Codex or GitHub feeds.
Fixtures, reports and HTTP traffic stay in build/updater-qa on loopback.
"""

import argparse
import functools
import http.server
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import threading
import time
import uuid

import sparkle


ROOT = Path(__file__).resolve().parents[1]


def run(arguments, **kwargs):
    result = subprocess.run([str(value) for value in arguments],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{arguments[0]} failed ({result.returncode}):\n{result.stdout.decode(errors='replace')}")
    return result


def wait_for(predicate, description, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    raise AssertionError(f"Timed out: {description}")


def read_report(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def test_case(app, tools, base, tamper, legacy_app=None):
    case = base / ("tampered" if tamper else "automatic")
    case.mkdir()
    state = case / "state"
    report = case / "updates.json"
    domain = f"com.aktay.codex-keep-going.qa.{uuid.uuid4().hex}"
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(case))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}/"
    baseline = case / ("installed/Codex Keep Going QA.app" if legacy_app else "installed/Codex Whip QA.app")
    target = case / "target/Codex Whip QA.app"
    target_version = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
    baseline_version = "1.0.0"
    for path, version in ((baseline, baseline_version), (target, target_version)):
        shutil.copytree(legacy_app if path == baseline and legacy_app else app, path, symlinks=True)
        info_path = path / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info.update({
            "CFBundleIdentifier": domain,
            "CFBundleName": "Codex Keep Going QA" if path == baseline and legacy_app else "Codex Whip QA",
            "CFBundleDisplayName": "Codex Keep Going QA" if path == baseline and legacy_app else "Codex Whip QA",
            "CFBundleVersion": version,
            "CFBundleShortVersionString": version,
            "SUDefaultsDomain": domain,
            "SUFeedURL": url + "appcast.xml",
            "SUAutomaticallyUpdate": True,
            "SUEnableAutomaticChecks": True,
            "KeepGoingQAStateDirectory": str(state),
            "KeepGoingQACodexHome": str(case / "missing-codex"),
            "KeepGoingQAUpdateFeed": url + "appcast.xml",
            "KeepGoingQAUpdateReport": str(report),
            "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
        })
        info_path.write_bytes(plistlib.dumps(info))
        run(["codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", path])
    archive = case / "Update.zip"
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", target, archive])
    run([tools / "bin/generate_appcast", "--account", sparkle.KEYCHAIN_ACCOUNT,
         "--download-url-prefix", url, "--maximum-deltas", "0", "-o", case / "appcast.xml", case])
    run([tools / "bin/sign_update", "--account", sparkle.KEYCHAIN_ACCOUNT,
         "--verify", case / "appcast.xml"])
    if tamper:
        data = bytearray(archive.read_bytes())
        data[len(data) // 2] ^= 1
        archive.write_bytes(data)
    # Seed saved state/history with local fixture metadata; no Codex endpoint exists.
    helper = next(path for path in (baseline / "Contents/Helpers/whip-helper", baseline / "Contents/Helpers/keep-going-helper") if path.exists())
    run([helper, "--state-dir", state, "prepare"])
    state_path = state / "state.json"
    before = json.loads(state_path.read_text())
    before["enabled_at"] = 1234
    before["threads"] = ["qa-only-session"]
    state_path.write_text(json.dumps(before))
    sys.path.insert(0, str(ROOT))
    from history import History
    history = History(state)
    history.record("waiting", thread_id="qa-only-session", turn_id="qa-capacity")
    history.close()
    run(["open", "-W", "-n", baseline, "--args", "--test-update-toggle", "--quit-after", "2"], timeout=20)
    toggles = read_report(report)
    assert any(e["event"] == "toggle-test-passed" for e in toggles.get("events", [])), toggles
    run(["open", "-n", baseline, "--args", "--test-update-background"])
    try:
        if tamper:
            result = wait_for(lambda: (value if any(e["event"] == "aborted" for e in value.get("events", []))
                                      else None) if (value := read_report(report)) else None,
                              "tampered update rejection")
            installed = plistlib.loads((baseline / "Contents/Info.plist").read_bytes())
            assert installed["CFBundleVersion"] == baseline_version, "A tampered update replaced the app"
            assert not any(e["event"] == "installing" for e in result["events"]), result
            assert result.get("error"), "Rejection needs an error"
        else:
            result = wait_for(lambda: (value if value.get("app_build") == target_version else None)
                              if (value := read_report(report)) else None,
                              "signed automatic replacement and relaunch")
            installed = plistlib.loads((baseline / "Contents/Info.plist").read_bytes())
            assert installed["CFBundleVersion"] == target_version, "The installed bundle was not updated"
            stages = {event["event"] for event in result["events"]}
            assert {"automatic-install-ready", "helper-stopped-before-automatic-install", "relaunching"} <= stages, result
            run(["codesign", "--verify", "--deep", "--strict", baseline])
        after = json.loads(state_path.read_text())
        assert after["enabled_at"] == 1234 and after["threads"] == ["qa-only-session"], "Saved settings changed"
        from history import read_report as activity_report
        assert activity_report(state)["capacity"] == 1, "Activity history changed"
        wait_for(lambda: (state / "worker.pid").is_file(), "isolated helper resume", timeout=15)
        print(f"PASS: {'tampered update rejected' if tamper else 'signed automatic install and relaunch'}; settings/history preserved", flush=True)
    finally:
        run(["osascript", "-e", f'tell application id "{domain}" to quit'])
        wait_for(lambda: not (state / "worker.pid").exists(), "QA helper exit", timeout=10)
        server.shutdown()
        subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/Codex Whip.app")
    parser.add_argument("--legacy-app", type=Path, help="An existing pre-rename app for a genuine old-to-new update check")
    args = parser.parse_args()
    tools = sparkle.distribution(ROOT)
    base = ROOT / "build/updater-qa" / uuid.uuid4().hex
    base.mkdir(parents=True)
    print(f"QA evidence: {base}", flush=True)
    for tamper in (False, True):
        test_case(args.app.resolve(), tools, base, tamper, args.legacy_app.resolve() if args.legacy_app else None)


if __name__ == "__main__":
    main()
