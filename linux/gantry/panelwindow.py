"""One auxiliary panel in a window of its own, centred on the screen.

The panels used to be overlays inside the fleet window: a dimmed layer with the card floating in the
middle of it. That cost more than it bought. A panel could never be larger than its host, it dimmed
the cards the user had just come to read, and the fleet window had to be kept awake by hand so it did
not hide from under the thing it had opened.

Windows and macOS already put diagnostics, statistics and Spoolbase in their own windows; this is
where the last overlay-only panel (maintenance) gets one too.
"""
from __future__ import annotations

from typing import Any, Callable

from gi.repository import Gtk, Gdk  # type: ignore


class PanelWindow(Gtk.Window):
    """A bordered, resizable window holding one panel widget, centred on the screen."""

    def __init__(self, app: Any, content: Gtk.Widget, title: str,
                 width: int = 470, height: int = 560,
                 cleanup: Callable[[], None] | None = None) -> None:
        super().__init__(title=title)
        self.app = app
        self._cleanup = cleanup
        self.set_transient_for(app.window)
        # Centred on the screen, not on the parent: a panel centred on the fleet window opens on top
        # of the cards, which is the thing the overlay did wrong.
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_default_size(width, height)
        self.set_size_request(min(360, width), min(240, height))
        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.set_title(title)
        self.set_titlebar(header)
        # The panel drew its own centred card because it had a whole window's worth of dimmed space
        # around it. In a window of this size it is the content, so it fills it.
        content.set_halign(Gtk.Align.FILL)
        content.set_valign(Gtk.Align.FILL)
        content.set_size_request(-1, -1)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(content)
        self.add(scroll)
        self.connect("key-press-event", self._on_key)
        self.connect("destroy", self._on_destroy)
        # The fleet window stays on screen for as long as this one does.
        app.window.hold_fleet_panel(self)

    def _on_key(self, _widget: Gtk.Widget, event: Gdk.EventKey) -> bool:
        if event.keyval == Gdk.KEY_Escape:
            self.destroy()
            return True
        return False

    def _on_destroy(self, *_args: object) -> None:
        cleanup, self._cleanup = self._cleanup, None
        if cleanup:
            cleanup()

    def present_centered(self) -> None:
        self.show_all()
        self.present()
