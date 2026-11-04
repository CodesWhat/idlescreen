"""Installed app paths that camera-gate evidence verifiers accept.

New runs install /Applications/IdleScreen.app. Evidence captured before the
rename names /Applications/idlescreen.app and must still replay. A record set
names exactly one of the two; mixing them fails closed.
"""

from __future__ import annotations

from pathlib import Path

CURRENT_APP_PATH = "/Applications/IdleScreen.app"
LEGACY_APP_PATH = "/Applications/idlescreen.app"
MAX_SCANNED_FILE_BYTES = 8 * 1024 * 1024


def app_path_named_by(text: str) -> str:
    """Return the installed app path the text names, or the current path."""
    has_current = CURRENT_APP_PATH in text
    has_legacy = LEGACY_APP_PATH in text
    if has_current and has_legacy:
        raise ValueError("evidence names both the current and legacy installed app paths")
    return LEGACY_APP_PATH if has_legacy else CURRENT_APP_PATH


def app_path_named_by_tree(root: Path) -> str:
    """Return the installed app path named by the regular files under root."""
    names: set[str] = set()
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        try:
            if path.stat().st_size > MAX_SCANNED_FILE_BYTES:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if CURRENT_APP_PATH in text:
            names.add(CURRENT_APP_PATH)
        if LEGACY_APP_PATH in text:
            names.add(LEGACY_APP_PATH)
    if len(names) > 1:
        raise ValueError("evidence names both the current and legacy installed app paths")
    return names.pop() if names else CURRENT_APP_PATH
