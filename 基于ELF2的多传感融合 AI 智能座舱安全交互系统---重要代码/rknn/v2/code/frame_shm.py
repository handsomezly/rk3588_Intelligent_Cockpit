"""Shared-memory frame transport between the v2 inference service (writer) and
the Qt cockpit (reader).

We deliberately treat /dev/shm/<name> as a plain tmpfs file and mmap it on both
sides, instead of multiprocessing.shared_memory / POSIX shm_open. Reason: the
C++ reader maps the exact same path with open()+mmap(); using a plain file path
sidesteps the leading-"/" naming quirk of shm_open and is trivially debuggable
(`ls -la /dev/shm`, `hexdump`).

Layout (single writer, single reader, triple-buffered, little-endian):

    Header (64 bytes):
        off  0  u32   magic   = b'CKPF'  (4 ASCII bytes)
        off  4  u32   version = 1
        off  8  u32   width
        off 12  u32   height
        off 16  u32   channels = 3 (RGB888, row-tight)
        off 20  u32   num_slots = 3
        off 24  u64   slot_size = width*height*channels
        off 32  u32   latest_index   (published LAST -> tear-free handshake)
        off 36  u32   (pad)
        off 40  u64   seq            (frame counter, pairs with metrics JSON)
        off 48  16 bytes reserved
    Then num_slots * slot_size bytes of frame data.

Tear-free rule: the writer advances slot = (slot+1) % num_slots each frame, so
it never reuses the slot it just published for two more frames. A ~900 KB memcpy
by the reader always finishes well within that window, so no retry/seqlock is
needed; latest_index is written last as the publish point.
"""

import mmap
import os
import struct

import numpy as np

MAGIC = b"CKPF"
VERSION = 1
HEADER_SIZE = 64
DEFAULT_NUM_SLOTS = 3

# struct format for the fixed part of the header (little-endian). The 16-byte
# reserved tail is left untouched.
_HEADER_FMT = "<4sIIIIIQIIQ"  # magic, ver, w, h, ch, slots, slot_size, latest, pad, seq
_HEADER_FIXED = struct.calcsize(_HEADER_FMT)  # 48 bytes; rest is reserved

# Byte offsets of the two atomically-updated fields.
_OFF_LATEST = 32
_OFF_SEQ = 40


def shm_path(name):
    """Resolve a bare name ('cockpit_frame') or an absolute path to /dev/shm."""
    if os.path.isabs(name):
        return name
    return os.path.join("/dev/shm", name)


class FrameShmWriter:
    """Writes RGB888 frames into a triple-buffered shared-memory file."""

    def __init__(self, name, width, height, channels=3, num_slots=DEFAULT_NUM_SLOTS):
        self.path = shm_path(name)
        self.width = int(width)
        self.height = int(height)
        self.channels = int(channels)
        self.num_slots = int(num_slots)
        self.slot_size = self.width * self.height * self.channels
        self.total_size = HEADER_SIZE + self.num_slots * self.slot_size

        self._slot = 0
        self._seq = 0

        # Create / size the backing file, then mmap it.
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o666)
        try:
            os.ftruncate(fd, self.total_size)
            self._mm = mmap.mmap(fd, self.total_size, mmap.MAP_SHARED,
                                 mmap.PROT_READ | mmap.PROT_WRITE)
        finally:
            os.close(fd)

        self._write_header(latest_index=0, seq=0)

    def _write_header(self, latest_index, seq):
        struct.pack_into(
            _HEADER_FMT, self._mm, 0,
            MAGIC, VERSION, self.width, self.height, self.channels,
            self.num_slots, self.slot_size, latest_index, 0, seq,
        )

    def write(self, frame_rgb):
        """Publish one RGB888 frame (HxWx3 uint8). Returns the new seq number.

        The frame must already be RGB (not BGR) and match width/height. Anything
        else is resized/converted by the caller; this class only copies bytes.
        """
        if frame_rgb.dtype != np.uint8:
            frame_rgb = frame_rgb.astype(np.uint8)
        if not frame_rgb.flags["C_CONTIGUOUS"]:
            frame_rgb = np.ascontiguousarray(frame_rgb)

        h, w = frame_rgb.shape[:2]
        if w != self.width or h != self.height:
            raise ValueError(
                f"frame size {w}x{h} != shm {self.width}x{self.height}")

        slot = (self._slot + 1) % self.num_slots
        off = HEADER_SIZE + slot * self.slot_size
        self._mm[off:off + self.slot_size] = frame_rgb.tobytes()

        self._seq += 1
        # Bump seq first, then publish the slot index LAST so a reader that sees
        # the new latest_index also sees the matching (or newer) seq.
        struct.pack_into("<Q", self._mm, _OFF_SEQ, self._seq)
        struct.pack_into("<I", self._mm, _OFF_LATEST, slot)
        self._slot = slot
        return self._seq

    def close(self, unlink=True):
        try:
            self._mm.flush()
            self._mm.close()
        except (BufferError, ValueError):
            pass
        if unlink:
            try:
                os.unlink(self.path)
            except FileNotFoundError:
                pass
