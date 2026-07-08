"""Non-blocking IMU context receiver and conservative fatigue-alarm gate.

Missing IMU data is deliberately neutral: a disconnected sensor must never
blind the visual fatigue detector. Vehicle shaking can pause tracker updates
and new alarms briefly, but the pause is capped at two seconds.
"""

from dataclasses import dataclass
import json
import os
import socket
import time


DEFAULT_IMU_SOCK = "/tmp/cockpit_imu_motion.sock"


@dataclass(frozen=True)
class MotionDecision:
    allow_observation: bool
    allow_new_alarm: bool
    suppressed: bool
    reason: str
    confidence: float


class MotionGate:
    def __init__(self, low_confidence=0.55, stale_after_s=0.5,
                 stable_confirm_s=1.5, max_suppression_s=2.0):
        self.low_confidence = float(low_confidence)
        self.stale_after_s = float(stale_after_s)
        self.stable_confirm_s = float(stable_confirm_s)
        self.max_suppression_s = float(max_suppression_s)
        self._unstable_since = None
        self._stable_since = None

    def _neutral(self, reason):
        self._unstable_since = None
        self._stable_since = None
        return MotionDecision(True, True, False, reason, 1.0)

    def decide(self, context, now=None):
        now = time.monotonic() if now is None else float(now)
        if context is None:
            return self._neutral("imu_missing")
        received_at = float(context.get("received_at", float("-inf")))
        if now - received_at > self.stale_after_s:
            return self._neutral("imu_stale")
        if not context.get("available", False) or not context.get("calibrated", False):
            return self._neutral("imu_unavailable")

        confidence = max(0.0, min(1.0, float(context.get("vision_confidence", 1.0))))
        if confidence < self.low_confidence:
            if self._unstable_since is None:
                self._unstable_since = now
            self._stable_since = None
            elapsed = max(0.0, now - self._unstable_since)
            if elapsed < self.max_suppression_s:
                return MotionDecision(False, False, True,
                                      "vehicle_shaking", confidence)
            # Safety cap: persistent rough-road motion must not disable fatigue
            # monitoring indefinitely.
            return MotionDecision(True, True, False,
                                  "suppression_cap", confidence)

        if self._unstable_since is not None:
            if self._stable_since is None:
                self._stable_since = now
            if now - self._stable_since < self.stable_confirm_s:
                return MotionDecision(True, False, True,
                                      "stabilizing", confidence)
            self._unstable_since = None
            self._stable_since = None
        return MotionDecision(True, True, False, "stable", confidence)


def apply_alarm_gate(raw_alarm, previous_alarm, decision):
    """Block only new alarms; retain an existing alarm while motion is gated."""
    if decision.allow_new_alarm:
        return bool(raw_alarm)
    return bool(previous_alarm)


class MotionContextReceiver:
    """Latest-only AF_UNIX datagram receiver; poll() never blocks."""

    def __init__(self, path=DEFAULT_IMU_SOCK):
        self.path = path
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self._sock.bind(path)
        self._sock.setblocking(False)
        self.latest = None

    def poll(self):
        while True:
            try:
                payload = self._sock.recv(4096)
            except (BlockingIOError, InterruptedError):
                break
            except OSError:
                break
            try:
                context = json.loads(payload.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if not isinstance(context, dict) or context.get("version") != 1:
                continue
            context["received_at"] = time.monotonic()
            self.latest = context
        return self.latest

    def close(self):
        self._sock.close()
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
