#!/usr/bin/env python3
"""Explicit-thread, focus-free Desktop capacity retry prototype.

doctor only reads the selected conversation. watch is an opt-in foreground
worker with a separate journal; it never installs a login item or changes the
normal app's settings/state. Desktop quota recovery remains unsupported.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import time

import codex_whip as core
from desktop_backend import DesktopRPC
from desktop_ipc import DesktopIPCError
from settings import DEFAULT_SETTINGS, read_settings, save_settings
from whip_sound import RetrySound


def diagnostic(backend, thread_id):
    with backend._lease(thread_id) as (_ipc, view):
        try:
            turn = backend._matched_turn(view, backend._stored_turns(thread_id))
            matched = True
        except core.RequestError:
            turn, matched = view.turn, False
        return {
            "connected": True, "backend": "desktop-ipc", "selected_conversations": 1,
            "runtime": view.thread.get("status", {}).get("type"),
            "ready_for_direct_input": core.watchable(view.thread),
            "capacity_failure": core.is_capacity(turn),
            "latest_turn_status": turn.get("status") if turn else None,
            "saved_turn_matches": matched,
            "completion_timestamp_verified": bool(matched and turn and turn.get("completedAt") is not None),
            "blocked_reason": view.blocked_reason,
            "quota_recovery_supported": False,
            "message_sent": False,
        }


def watch(directory, codex_home, thread_id, once=False, backend_factory=DesktopRPC,
          metadata_factory=core.WebSocketRPC):
    directory = Path(directory)
    production = core.default_state_directory().resolve()
    if directory.resolve() == production:
        raise ValueError("The Desktop prototype requires a separate state directory.")
    if (directory / "state.json").exists():
        original = core.read_json(directory / "state.json")
        if (not isinstance(original, dict) or original.get("control_backend") != "desktop-ipc"
                or original.get("threads") != [thread_id]):
            raise ValueError("This directory belongs to another watcher.")
    elif directory.exists() and any(directory.iterdir()):
        raise ValueError("Choose an empty directory for a new Desktop journal.")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    with (directory / "worker.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("This Desktop watcher is already running.") from None
        state_path = directory / "state.json"
        existing = state_path.exists()
        state = core.read_json(state_path) if existing else core.initial_state([thread_id])
        if (not isinstance(state, dict) or state.get("version") != 1 or state.get("threads") != [thread_id]
                or (existing and state.get("control_backend") != "desktop-ipc")):
            raise ValueError("This journal belongs to another Desktop scope.")
        state["control_backend"] = "desktop-ipc"
        core.atomic_json(state_path, state)
        if not (directory / "settings.json").exists():
            save_settings(directory, {**DEFAULT_SETTINGS, "sound_enabled": False})
        stopping = False

        def stop(_signum, _frame):
            nonlocal stopping
            stopping = True

        previous = {s: signal.signal(s, stop) for s in (signal.SIGINT, signal.SIGTERM)}
        history, audio, metadata, backend = None, None, None, None
        try:
            history = core.History(directory)
            audio = RetrySound()
            (directory / "worker.log").touch(mode=0o600, exist_ok=True)
            os.chmod(directory / "worker.log", 0o600)
            logger = core.log_emitter(directory)
        except BaseException:
            if audio:
                audio.close()
            if history:
                history.close()
            for sig, handler in previous.items():
                signal.signal(sig, handler)
            raise
        step_held = False

        def report(event, **fields):
            nonlocal step_held
            if event == "thread_unavailable":
                step_held = True
            history.record(event, **fields)
            logger(event, **fields)
            try:
                audio.report(event)
            except Exception:
                pass

        engine = core.RetryEngine(state, lambda value: core.atomic_json(state_path, value), report,
                                  threads=[thread_id], should_stop=lambda: stopping)
        scheduler = core.ScanScheduler()
        reconnect_after = 0
        try:
            while not stopping:
                settings = read_settings(directory)
                engine.apply_settings(settings)
                audio.configure(settings["sound_enabled"])
                if time.monotonic() < reconnect_after:
                    if once:
                        break
                    time.sleep(0.5)
                    continue
                discovery = scheduler.due(time.monotonic(), settings["scan_seconds"])
                if discovery or engine.maintenance_due(time.time()):
                    try:
                        if metadata is None:
                            metadata = metadata_factory(core.resolve_socket(codex_home), should_stop=lambda: stopping)
                            backend = backend_factory(Path(codex_home) / "ipc/ipc.sock", metadata,
                                                      [thread_id], should_stop=lambda: stopping)
                        core.reconcile_history(state, history, time.time())
                        step_held = False
                        engine.step(backend, time.time(), discover=discovery)
                        state["last_error"] = ("Desktop's saved turn cannot be verified; retries remain on hold."
                                               if step_held else None)
                        if discovery:
                            state["last_scan_at"] = time.time()
                    except core.RPCCancelled:
                        break
                    except (core.RPCError, DesktopIPCError, OSError, ValueError):
                        state["last_error"] = "Desktop checking is unavailable; retries remain on hold."
                        engine.reset_observations()
                        if backend:
                            backend.close()
                        if metadata:
                            metadata.close()
                        backend, metadata = None, None
                        reconnect_after = time.monotonic() + min(30, settings["scan_seconds"])
                    core.atomic_json(state_path, state)
                    if discovery:
                        scheduler.finished(time.monotonic())
                if once:
                    break
                time.sleep(0.5)
        finally:
            audio.close()
            if backend:
                backend.close()
            if metadata:
                metadata.close()
            history.close()
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        return state.get("last_error") is None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-home", type=Path,
                        default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    parser.add_argument("--thread", required=True, help="One explicitly selected local Desktop conversation ID")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor", help="Read Desktop state without sending messages")
    worker = commands.add_parser("watch", help="Watch future failures in this one conversation")
    worker.add_argument("--state-dir", type=Path, help="A separate private prototype journal directory")
    worker.add_argument("--once", action="store_true", help="Run one scheduled watcher step and exit")
    args = parser.parse_args(argv)
    home = args.codex_home.expanduser().resolve()
    if not args.thread.strip() or len(args.thread) > 512:
        parser.error("Provide one conversation ID.")
    try:
        if args.command == "doctor":
            metadata = core.WebSocketRPC(core.resolve_socket(home))
            backend = DesktopRPC(home / "ipc/ipc.sock", metadata, [args.thread])
            try:
                print(json.dumps(diagnostic(backend, args.thread), indent=2))
            finally:
                backend.close()
                metadata.close()
        else:
            scope = hashlib.sha256(args.thread.encode()).hexdigest()[:16]
            directory = args.state_dir or (Path.home() / "Library/Application Support/Codex Whip Desktop Prototype" / scope)
            print("Watching one selected Desktop conversation. Quota recovery stays on hold. Stop with Ctrl-C.",
                  file=sys.stderr)
            if not watch(directory.expanduser().resolve(), home, args.thread, args.once):
                return 1
        return 0
    except (core.RPCError, DesktopIPCError, OSError, ValueError, RuntimeError):
        print("Desktop prototype unavailable. Check the app, selected conversation, and local daemon.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
