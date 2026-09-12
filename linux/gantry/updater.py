from __future__ import annotations

"""Small, package-manager-safe release checker for the Linux settings window."""

import json
import hashlib
import os
import platform
import shutil
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
    rpm_url: str | None = None
    rpm_sha256: str | None = None
    appimage_url: str | None = None
    appimage_sha256: str | None = None

    def asset(self, package_format: str) -> tuple[str | None, str | None]:
        return {
            "deb": (self.deb_url, self.deb_sha256),
            "rpm": (self.rpm_url, self.rpm_sha256),
            "appimage": (self.appimage_url, self.appimage_sha256),
        }.get(package_format, (None, None))


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
    assets = root.get("assets", [])
    def find(suffix: str) -> tuple[str | None, str | None]:
        asset = next((value for value in assets
                      if str(value.get("name", "")).lower().endswith(suffix)
                      and value.get("browser_download_url")), None)
        if not asset: return None, None
        digest = str(asset.get("digest") or "")
        return (str(asset["browser_download_url"]),
                digest.split(":", 1)[1].lower() if digest.startswith("sha256:") else None)
    deb_url, deb_sha256 = find(".deb")
    rpm_url, rpm_sha256 = find(".rpm")
    appimage_url, appimage_sha256 = find(".appimage")
    return Release(
        version=tag.lstrip("vV"),
        page_url=str(root.get("html_url") or RELEASES_URL),
        deb_url=deb_url,
        deb_sha256=deb_sha256,
        rpm_url=rpm_url,
        rpm_sha256=rpm_sha256,
        appimage_url=appimage_url,
        appimage_sha256=appimage_sha256,
    )


def detected_package_format() -> str:
    """Prefer the format already used by this installation, then the host package family."""
    if os.environ.get("APPIMAGE"): return "appimage"
    try: os_release = Path("/etc/os-release").read_text(errors="ignore").lower()
    except OSError: os_release = ""
    if any(value in os_release for value in ("id_like=debian", "id=debian", "id=ubuntu", "id=linuxmint", "id=pop")): return "deb"
    if any(value in os_release for value in ("id_like=fedora", "id_like=rhel", "id=fedora", "id=rhel", "id=opensuse")): return "rpm"
    if shutil.which("dpkg"): return "deb"
    if shutil.which("rpm"): return "rpm"
    return "appimage"


def select_package_format(release: Release, preference: str = "auto") -> str | None:
    requested = preference if preference in {"deb", "rpm", "appimage"} else detected_package_format()
    if release.asset(requested)[0]: return requested
    return next((value for value in ("appimage", "deb", "rpm") if release.asset(value)[0]), None)


def download_package(release: Release, package_format: str = "auto", timeout: float = 45.0) -> Path:
    """Download and validate the selected Linux artifact without acquiring root privileges."""
    selected = select_package_format(release, package_format)
    if selected is None: raise ValueError("release-without-linux-package")
    url, expected_digest = release.asset(selected)
    suffix = {"deb": ".deb", "rpm": ".rpm", "appimage": ".AppImage"}[selected]
    target = Path(tempfile.gettempdir()) / f"Gantry-{release.version}-Linux{suffix}"
    request = urllib.request.Request(str(url), headers={"User-Agent": "Gantry-Linux"})
    digest = hashlib.sha256()
    temporary = target.with_suffix(".download")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response, temporary.open("wb") as output:
            while chunk := response.read(1024 * 256):
                digest.update(chunk)
                output.write(chunk)
        with temporary.open("rb") as package: signature = package.read(8)
        valid = ((selected == "deb" and signature == b"!<arch>\n")
                 or (selected == "rpm" and signature[:4] == b"\xed\xab\xee\xdb")
                 or (selected == "appimage" and signature[:4] == b"\x7fELF"))
        if temporary.stat().st_size < 8 or not valid: raise ValueError(f"invalid-{selected}")
        if expected_digest and digest.hexdigest().lower() != expected_digest:
            raise ValueError("checksum-mismatch")
        temporary.replace(target)
        if selected == "appimage": target.chmod(target.stat().st_mode | 0o111)
        return target
    except Exception:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def download_deb(release: Release, timeout: float = 45.0) -> Path:
    """Compatibility wrapper used by older callers and tests."""
    return download_package(release, "deb", timeout)
