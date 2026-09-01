"""Small, GUI-free helpers shared by camera streams and unit tests."""
from __future__ import annotations

from typing import Callable

_SOI = b"\xff\xd8"
_EOI = b"\xff\xd9"


def split_jpegs(buffer: bytearray, emit: Callable[[bytes], None]) -> None:
    """Pull every complete JPEG out of a growing byte buffer in place."""
    while True:
        start = buffer.find(_SOI)
        if start < 0:
            if len(buffer) > 4:
                del buffer[:-2]
            return
        end = buffer.find(_EOI, start + 2)
        if end < 0:
            if start > 0:
                del buffer[:start]
            return
        frame = bytes(buffer[start:end + 2])
        del buffer[:end + 2]
        emit(frame)


# Compatibility for code/tests written before this helper was extracted from camera.py.
_split_jpegs = split_jpegs
