from __future__ import annotations

"""Small, package-manager-safe release checker for the Linux settings window."""

import json
import hashlib
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path


API_URL = "https://api.github.com/repos/parametryczny/gantrybar/releases/latest"
RELEASES_URL = "https://github.com/parametryczny/gantrybar/releases"


@dataclass(frozen=True, slots=True)
class Release:
    version: str
    page_url: str
    deb_url: str | None = None
    deb_sha256: str | None = None


def version_tuple(value: str) -> tuple[int, ...]:
    text = value.strip().lstrip("vV")
    result: list[int] = []
    for part in text.split("."):
        digits = "".join(character for character in part if character.isdigit())
        result.append(int(digits or 0))
    return tuple(result)


def is_newer(candidate: str, current: str) -> bool:
    left, right = list(version_tuple(candidate)), list(version_tuple(current))
    width = max(len(left), len(right))
    return tuple(left + [0] * (width - len(left))) > tuple(right + [0] * (width - len(right)))


def latest_release(timeout: float = 8.0) -> Release:
    request = urllib.request.Request(
        API_URL,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "Gantry-Linux"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        root = json.loads(response.read().decode("utf-8"))
    tag = str(root.get("tag_name") or "").strip()
    if not tag:
        raise ValueError("release-without-version")
    deb_asset = next((asset for asset in root.get("assets", [])
                      if str(asset.get("name", "")).lower().endswith(".deb")
                      and asset.get("browser_download_url")), None)
    deb_url = str(deb_asset.get("browser_download_url")) if deb_asset else None
    digest = str(deb_asset.get("digest") or "") if deb_asset else ""
    deb_sha256 = digest.split(":", 1)[1].lower() if digest.startswith("sha256:") else None
    return Release(
        version=tag.lstrip("vV"),
        page_url=str(root.get("html_url") or RELEASES_URL),
        deb_url=deb_url,
        deb_sha256=deb_sha256,
    )


def download_deb(release: Release, timeout: float = 45.0) -> Path:
    """Download and validate a release .deb without acquiring package-manager privileges."""
    if not release.deb_url:
        raise ValueError("release-without-deb")
    target = Path(tempfile.gettempdir()) / f"Gantry-{release.version}-Linux.deb"
    request = urllib.request.Request(release.deb_url, headers={"User-Agent": "Gantry-Linux"})
    digest = hashlib.sha256()
    temporary = target.with_suffix(".download")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response, temporary.open("wb") as output:
            while chunk := response.read(1024 * 256):
                digest.update(chunk)
                output.write(chunk)
        with temporary.open("rb") as package:
            signature = package.read(8)
        if temporary.stat().st_size < 8 or signature != b"!<arch>\n":
            raise ValueError("invalid-deb")
        if release.deb_sha256 and digest.hexdigest().lower() != release.deb_sha256:
            raise ValueError("checksum-mismatch")
        temporary.replace(target)
        return target
    except Exception:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise
