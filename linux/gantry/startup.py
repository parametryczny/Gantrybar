"""Session-only launch state. No GTK, sockets, defaults or fake telemetry."""
from __future__ import annotations
import math
import time


class StartupState:
    timeout = 15.0

    def __init__(self, serials: list[str], clock=time.monotonic):
        self.serials = set(serials)
        self.received: set[str] = set()
        self.clock = clock
        self.deadline = clock() + self.timeout
        self.finished = not self.serials
        self.guide_claimed = False

    @property
    def ready(self) -> int:
        return len(self.received & self.serials)

    @property
    def loading(self) -> bool:
        if self.clock() >= self.deadline or self.ready >= math.ceil(len(self.serials) * .6):
            self.finished = True
        return not self.finished

    def report(self, serial: str) -> None:
        self.received.add(serial)
        _ = self.loading

    def remove(self, serial: str) -> None:
        self.serials.discard(serial)
        self.received.discard(serial)
        _ = self.loading

    def finish(self) -> None:
        self.finished = True

    def claim_guide(self, seen: bool) -> bool:
        if seen or self.guide_claimed:
            return False
        self.guide_claimed = True
        return True
