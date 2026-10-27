"""Validated private preferences for Codex Whip, separate from retry state."""

from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile


DEFAULT_MESSAGE = "Keep using the selected model. Continue the unfinished work."
DEFAULT_SETTINGS = {"retry_seconds": 180, "scan_seconds": 300, "message": DEFAULT_MESSAGE,
                    "sound_enabled": False}


class SettingsError(ValueError):
    pass


def validate_settings(value):
    legacy_keys = set(DEFAULT_SETTINGS) - {"sound_enabled"}
    if not isinstance(value, dict) or set(value) not in (legacy_keys, set(DEFAULT_SETTINGS)):
        raise SettingsError("Settings must contain retry_seconds, scan_seconds, message, and optional sound_enabled.")
    for name, lower, upper in (("retry_seconds", 60, 86400), ("scan_seconds", 15, 3600)):
        number = value[name]
        if isinstance(number, bool) or not isinstance(number, int) or not lower <= number <= upper:
            raise SettingsError(f"{name} must be an integer from {lower} to {upper} seconds.")
    message = value["message"]
    if not isinstance(message, str) or not message.strip() or len(message) > 4000:
        raise SettingsError("message must contain nonblank text of at most 4000 characters.")
    sound = value.get("sound_enabled", False)
    if not isinstance(sound, bool):
        raise SettingsError("sound_enabled must be true or false.")
    return {**value, "sound_enabled": sound}


def read_settings(directory):
    path = Path(directory) / "settings.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return dict(DEFAULT_SETTINGS)
    except (OSError, ValueError) as error:
        raise SettingsError(f"Cannot read settings.json: {error}") from error
    try:
        return validate_settings(value)
    except SettingsError as error:
        raise SettingsError(f"Invalid settings.json: {error}") from error


def save_settings(directory, value):
    value = validate_settings(value)
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=directory,
                                         prefix=".settings-", suffix=".tmp", delete=False) as file:
            temporary = Path(file.name)
            os.chmod(temporary, 0o600)
            json.dump(value, file, ensure_ascii=False, indent=2)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, directory / "settings.json")
    except OSError as error:
        raise SettingsError(f"Cannot save settings.json: {error}") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return value


def settings_envelope(directory):
    return {"settings": read_settings(directory), "defaults": dict(DEFAULT_SETTINGS)}


class ScanScheduler:
    """Changing cadence is measured from the last finished scan, never from settings edits."""

    def __init__(self):
        self.last_scan = None

    def due(self, now, interval):
        return self.last_scan is None or now - self.last_scan >= interval

    def finished(self, now):
        self.last_scan = now
