"""Best-effort translucent/frosted-glass backdrop for the Gantry tray popover.

Layered, and always safe:

  1. GTK RGBA transparency  -- done by the Dashboard itself (set_visual), always available with a
     compositor. This module never touches it.
  2. Compositor blur request -- only where a portable mechanism exists. Today that means KDE/KWin on
     X11 via the `_KDE_NET_WM_BLUR_BEHIND_REGION` window property (empty region = blur the whole
     window). No extra dependency: the property is set through GDK.
  3. Fallback -- if there is no compositor blur (GNOME/XFCE/Cinnamon, or Wayland without a portable
     background-blur protocol), we simply keep the RGBA transparency. Never crash, never a black or
     empty panel.

Real desktop-content blur can only be done by the compositor: an application cannot see the pixels
behind its own window, so there is no GTK-side blur to attempt. We only *request* it.

The architecture leaves room to add a standard Wayland background-effect protocol later
(`_try_wayland_blur`) without changing the Dashboard.
"""

from __future__ import annotations

try:
    import gi
    from gi.repository import Gdk
except Exception:  # pragma: no cover - GI is required to run the app, not to import helpers in tests
    Gdk = None  # type: ignore


def apply_backdrop(window) -> str:
    """Request the best available backdrop for a realised Gtk.Window.

    Returns one of: "kwin-blur", "wayland-blur", "transparency", "opaque".
    Never raises.
    """
    if Gdk is None:
        return "opaque"
    try:
        gdk_window = window.get_window()
    except Exception:
        gdk_window = None
    if gdk_window is None:
        # Not realised yet -- caller should re-try on "realize"/"map".
        return "transparency"

    backend = _backend_name(gdk_window)

    if backend == "wayland":
        # No portable background-blur protocol yet; keep RGBA transparency. Do NOT poke X11 here.
        if _try_wayland_blur(window):
            return "wayland-blur"
        return "transparency"

    if backend == "x11":
        if _try_kwin_x11_blur(gdk_window):
            return "kwin-blur"
        return "transparency"

    return "transparency"


def _backend_name(gdk_window) -> str:
    """Detect the display backend from the GdkWindow's concrete type (X11 vs Wayland)."""
    try:
        name = type(gdk_window).__name__.lower()
    except Exception:
        return "unknown"
    if "wayland" in name:
        return "wayland"
    if "x11" in name:
        return "x11"
    return "unknown"


def _try_kwin_x11_blur(gdk_window) -> bool:
    """Ask KWin (KDE) to blur behind the whole window by setting an empty blur-region property.

    KWin treats `_KDE_NET_WM_BLUR_BEHIND_REGION` with zero elements as "blur the entire window".
    Best-effort: returns False (never raises) on any other compositor or if the property cannot be set.
    """
    try:
        prop = Gdk.Atom.intern("_KDE_NET_WM_BLUR_BEHIND_REGION", False)
        cardinal = Gdk.Atom.intern("CARDINAL", False)
        # Empty CARDINAL/32 payload -> whole-window blur. Try the byte form first, then an empty list,
        # since the exact PyGObject signature for zero-length property data varies by version.
        for payload in (b"", []):
            try:
                gdk_window.property_change(prop, cardinal, 32, Gdk.PropMode.REPLACE, payload)
                return True
            except (TypeError, ValueError):
                continue
        return False
    except Exception:
        return False


def _try_wayland_blur(window) -> bool:
    """Placeholder for a future standard Wayland background-blur protocol.

    No stable, widely-supported protocol exists across compositors today, so we do nothing and let the
    caller fall back to plain RGBA transparency. Kept as a seam so support can be added without
    touching the Dashboard.
    """
    return False
