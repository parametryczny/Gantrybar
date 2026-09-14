"""Writes data files so a crash, a full disk or a killed process mid-write never leaves them empty or half
written: the contents go to a temporary file in the same folder, flushed to disk, which then replaces the
old file in one step; the previous version stays as ``.bak``. Reading falls back to that copy when the main
file is missing, empty or unreadable. Pure stdlib, so it stays unit-testable without GTK.
"""

from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path
from typing import Callable


def backup_path(path: Path) -> Path:
    return path.with_name(path.name + ".bak")


def write_text_atomic(path: Path, text: str, keep_backup_if: Callable[[str], bool] | None = None) -> None:
    """Replaces ``path`` with ``text`` in one step. The current file becomes the backup only when it is
    worth keeping (non-empty and accepted by ``keep_backup_if``), so a damaged file never overwrites the last
    good copy."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if path.exists() and _worth_keeping(path, keep_backup_if):
            shutil.copy2(path, backup_path(path))
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def read_text_with_backup(path: Path, is_valid: Callable[[str], bool]) -> str | None:
    """The file's text, or its last good copy when the file is missing, empty or rejected by ``is_valid``."""
    path = Path(path)
    for candidate in (path, backup_path(path)):
        try:
            text = candidate.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        try:
            if text and is_valid(text):
                return text
        except Exception:
            continue
    return None


def _worth_keeping(path: Path, keep_backup_if: Callable[[str], bool] | None) -> bool:
    try:
        current = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False
    if not current:
        return False
    try:
        return keep_backup_if is None or bool(keep_backup_if(current))
    except Exception:
        return False
