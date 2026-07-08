"""PERCLOS sliding-window tracker for fatigue detection.

P80 rule: PERCLOS = (frames with both eyes >=80% closed) / (valid frames in window).
Reports fatigue when PERCLOS exceeds the configured threshold and the window
has accumulated enough valid observations.

Also provides BlinkTracker which complements PERCLOS by measuring blink
duration and long-blink (microsleep) events. The combined fatigue decision in
test.py fires when EITHER signal trips its threshold.
"""

import time
from collections import deque

# Frame-level eye state codes stored in the rolling window.
STATE_OPEN = 0
STATE_CLOSED = 1
STATE_INVALID = 2  # face missing / crop failed; not counted in PERCLOS
STATE_SQUINT = 3    # half-open/squint; valid observation, not counted as PERCLOS closed

STATUS_WARMING_UP = "warming_up"
STATUS_LOW_VISIBILITY = "low_visibility"
STATUS_NORMAL = "normal"
STATUS_FATIGUE = "fatigue_alarm"


class PerclosTracker:
    def __init__(
        self,
        window_frames=900,         # 30s @ 30FPS
        p80_threshold=0.15,
        close_th=0.35,             # p_open below this -> CLOSED (hysteresis low)
        open_th=0.55,              # p_open above this -> OPEN  (hysteresis high)
        closed_prob_th=0.60,       # trinary p_closed at/above this -> CLOSED
        squint_prob_th=0.60,       # trinary p_squint at/above this -> SQUINT
        min_valid_frames=600,      # ~20s of usable observations before alarming
        min_valid_ratio=0.6,       # window must be at least this observable
    ):
        self.window_frames = window_frames
        self.p80_threshold = p80_threshold
        self.close_th = close_th
        self.open_th = open_th
        self.closed_prob_th = closed_prob_th
        self.squint_prob_th = squint_prob_th
        self.min_valid_frames = min_valid_frames
        self.min_valid_ratio = min_valid_ratio

        self.window = deque(maxlen=window_frames)
        # Incremental counters - never sum the deque every frame.
        self.closed_count = 0
        self.squint_count = 0
        self.valid_count = 0
        # Hysteresis state for both eyes; start as OPEN so a single noisy frame
        # doesn't immediately register as closed.
        self.last_eye_state = STATE_OPEN

    def _classify_frame(self, p_open_left, p_open_right):
        """Apply hysteresis. Returns one of STATE_OPEN / STATE_CLOSED / STATE_INVALID."""
        if p_open_left is None or p_open_right is None:
            return STATE_INVALID

        # P80 wants "both eyes effectively closed".
        p_min = min(p_open_left, p_open_right)

        if self.last_eye_state == STATE_OPEN:
            if p_min < self.close_th:
                return STATE_CLOSED
            return STATE_OPEN
        # last was CLOSED -> need clear evidence to flip back to OPEN.
        if p_min > self.open_th:
            return STATE_OPEN
        return STATE_CLOSED

    def _classify_probs(self, probs_left, probs_right):
        """Classify a frame from trinary [p_closed, p_open, p_squint] probabilities."""
        if probs_left is None or probs_right is None:
            return STATE_INVALID
        if len(probs_left) < 3 or len(probs_right) < 3:
            raise ValueError("eye probabilities must be [p_closed, p_open, p_squint]")

        p_closed = min(float(probs_left[0]), float(probs_right[0]))
        p_open = min(float(probs_left[1]), float(probs_right[1]))
        p_squint = min(float(probs_left[2]), float(probs_right[2]))

        if self.last_eye_state == STATE_CLOSED:
            if p_open >= self.open_th:
                return STATE_OPEN
            if p_squint >= self.squint_prob_th and p_closed < self.closed_prob_th:
                return STATE_SQUINT
            return STATE_CLOSED

        if p_closed >= self.closed_prob_th:
            return STATE_CLOSED
        if p_open >= self.open_th:
            return STATE_OPEN
        if p_squint >= self.squint_prob_th:
            return STATE_SQUINT
        if self.last_eye_state == STATE_INVALID:
            return STATE_OPEN
        return self.last_eye_state

    def _append_state(self, new_state):
        """Push one classified state and update rolling counters."""
        if new_state != STATE_INVALID:
            self.last_eye_state = new_state

        # If window is full, account for the frame about to be evicted.
        if len(self.window) == self.window_frames:
            old = self.window[0]
            if old == STATE_CLOSED:
                self.closed_count -= 1
            if old == STATE_SQUINT:
                self.squint_count -= 1
            if old != STATE_INVALID:
                self.valid_count -= 1

        self.window.append(new_state)
        if new_state == STATE_CLOSED:
            self.closed_count += 1
        if new_state == STATE_SQUINT:
            self.squint_count += 1
        if new_state != STATE_INVALID:
            self.valid_count += 1

    def update(self, p_open_left, p_open_right):
        """Push one frame. Pass None for both when no usable observation."""
        new_state = self._classify_frame(p_open_left, p_open_right)
        self._append_state(new_state)

    def update_probs(self, probs_left, probs_right):
        """Push one frame from trinary probabilities.

        Probabilities follow the project-wide class convention:
        index 0 = closed, index 1 = open, index 2 = squint. Squint frames count
        as valid observations but never add to the PERCLOS closed numerator.
        """
        new_state = self._classify_probs(probs_left, probs_right)
        self._append_state(new_state)

    def perclos(self):
        if self.valid_count == 0:
            return 0.0
        return self.closed_count / self.valid_count

    def status(self):
        if self.valid_count < self.min_valid_frames:
            return STATUS_WARMING_UP
        # Avoid divide-by-zero before window has any frames.
        win_len = len(self.window) or 1
        if self.valid_count / win_len < self.min_valid_ratio:
            return STATUS_LOW_VISIBILITY
        return STATUS_FATIGUE if self.perclos() > self.p80_threshold else STATUS_NORMAL

    def snapshot(self):
        """Light dict for HUD rendering; cheap to call every frame."""
        return {
            "perclos": self.perclos(),
            "status": self.status(),
            "valid_count": self.valid_count,
            "closed_count": self.closed_count,
            "squint_count": self.squint_count,
            "squint_ratio": self.squint_count / self.valid_count if self.valid_count else 0.0,
            "window_len": len(self.window),
            "last_eye_state": self.last_eye_state,
        }


class BlinkTracker:
    """Detect blink events (OPEN -> CLOSED -> OPEN) and report rate / duration.

    Unlike PerclosTracker, this works in real wall-clock time (time.monotonic),
    so it does not need to know the camera FPS. Each completed blink is stored
    as (end_time, duration_seconds) and evicted after window_seconds.

    Fatigue triggers (any one):
      - mean blink duration > mean_dur_alarm_ms (drowsy slow blinks)
      - long_blink_count >= long_blink_alarm_count in the window (microsleeps)

    Blink RATE is reported on the HUD but intentionally NOT used as a primary
    alarm trigger - rate has high inter-person variance and many confounders
    (talking, eyeglasses, dry eye), making it unreliable on its own.
    """

    def __init__(
        self,
        close_th=0.35,
        open_th=0.55,
        window_seconds=60.0,
        min_blink_ms=80,            # below this -> noise, ignore
        long_blink_ms=500,          # above this -> microsleep
        mean_dur_alarm_ms=400,      # avg duration -> fatigue
        long_blink_alarm_count=3,   # microsleeps in window -> fatigue
        min_blinks_for_alarm=3,     # need this many blinks before alarming
        time_fn=None,               # injectable for tests
    ):
        self.close_th = close_th
        self.open_th = open_th
        self.window_seconds = window_seconds
        self.min_blink_s = min_blink_ms / 1000.0
        self.long_blink_s = long_blink_ms / 1000.0
        self.mean_dur_alarm_s = mean_dur_alarm_ms / 1000.0
        self.long_blink_alarm_count = long_blink_alarm_count
        self.min_blinks_for_alarm = min_blinks_for_alarm
        self._now = time_fn or time.monotonic

        self.start_time = self._now()
        self.last_state = STATE_OPEN
        self.current_blink_start = None  # wall-clock seconds, None if not in blink
        self.blink_events = deque()       # entries: (end_time, duration_s)

    def _classify(self, p_open_left, p_open_right):
        if p_open_left is None or p_open_right is None:
            return STATE_INVALID
        p_min = min(p_open_left, p_open_right)
        if self.last_state == STATE_OPEN:
            return STATE_CLOSED if p_min < self.close_th else STATE_OPEN
        if self.last_state == STATE_CLOSED:
            return STATE_OPEN if p_min > self.open_th else STATE_CLOSED
        # Last was INVALID: re-baseline against midpoint, no transitions emitted.
        return STATE_OPEN if p_min >= 0.5 else STATE_CLOSED

    def update(self, p_open_left, p_open_right):
        now = self._now()
        new_state = self._classify(p_open_left, p_open_right)

        # Only emit transitions across confirmed (non-INVALID) states. This
        # prevents fabricating a blink when a face reappears already closed.
        if self.last_state == STATE_OPEN and new_state == STATE_CLOSED:
            self.current_blink_start = now
        elif self.last_state == STATE_CLOSED and new_state == STATE_OPEN:
            if self.current_blink_start is not None:
                duration = now - self.current_blink_start
                if duration >= self.min_blink_s:
                    self.blink_events.append((now, duration))
                self.current_blink_start = None
        elif new_state == STATE_INVALID:
            # Face lost mid-blink: discard the in-progress event.
            self.current_blink_start = None

        # Evict events outside the window.
        cutoff = now - self.window_seconds
        while self.blink_events and self.blink_events[0][0] < cutoff:
            self.blink_events.popleft()

        self.last_state = new_state

    # --- Reporting ---------------------------------------------------------

    def _elapsed(self):
        return min(self._now() - self.start_time, self.window_seconds)

    def blink_rate_per_min(self):
        elapsed = self._elapsed()
        if elapsed <= 0:
            return 0.0
        return len(self.blink_events) * 60.0 / elapsed

    def mean_blink_duration_ms(self):
        if not self.blink_events:
            return None
        total = sum(d for _, d in self.blink_events)
        return (total / len(self.blink_events)) * 1000.0

    def long_blink_count(self):
        return sum(1 for _, d in self.blink_events if d >= self.long_blink_s)

    def is_fatigued(self):
        if len(self.blink_events) < self.min_blinks_for_alarm:
            return False, None
        mean_dur = self.mean_blink_duration_ms()
        if mean_dur is not None and mean_dur > self.mean_dur_alarm_s * 1000.0:
            return True, f"avg_blink={mean_dur:.0f}ms"
        long_count = self.long_blink_count()
        if long_count >= self.long_blink_alarm_count:
            return True, f"long_blinks={long_count}"
        return False, None

    def snapshot(self):
        fatigue, reason = self.is_fatigued()
        return {
            "blink_count": len(self.blink_events),
            "rate_per_min": self.blink_rate_per_min(),
            "mean_dur_ms": self.mean_blink_duration_ms(),
            "long_blink_count": self.long_blink_count(),
            "in_blink": self.current_blink_start is not None,
            "is_fatigued": fatigue,
            "fatigue_reason": reason,
        }


# Quick self-test: run `python perclos.py` to validate the tracker logic
# without needing a board / camera.
if __name__ == "__main__":
    def run_synthetic():
        # Case 1: 900 OPEN frames -> perclos = 0
        t = PerclosTracker()
        for _ in range(900):
            t.update(0.9, 0.9)
        snap = t.snapshot()
        assert snap["perclos"] == 0.0, snap
        assert snap["status"] == STATUS_NORMAL, snap

        # Case 2: 630 OPEN + 270 CLOSED -> perclos = 270/900 = 0.30
        t = PerclosTracker()
        for _ in range(630):
            t.update(0.9, 0.9)
        for _ in range(270):
            t.update(0.1, 0.1)
        snap = t.snapshot()
        assert abs(snap["perclos"] - 0.30) < 1e-6, snap
        assert snap["status"] == STATUS_FATIGUE, snap

        # Case 3: all None -> warming_up forever
        t = PerclosTracker()
        for _ in range(900):
            t.update(None, None)
        snap = t.snapshot()
        assert snap["valid_count"] == 0, snap
        assert snap["status"] == STATUS_WARMING_UP, snap

        # Case 4: hysteresis - flickering near 0.5 should not flip state.
        t = PerclosTracker(close_th=0.35, open_th=0.55)
        for _ in range(20):
            t.update(0.9, 0.9)  # firmly OPEN
        for _ in range(20):
            t.update(0.45, 0.45)  # in the dead zone -> stay OPEN
        # Last eye state should remain OPEN.
        assert t.last_eye_state == STATE_OPEN, t.last_eye_state

        # Case 5: window eviction keeps counters accurate.
        t = PerclosTracker(window_frames=10, min_valid_frames=1)
        for _ in range(10):
            t.update(0.1, 0.1)  # all CLOSED
        assert t.closed_count == 10 and t.valid_count == 10, t.snapshot()
        for _ in range(10):
            t.update(0.9, 0.9)  # push OPENs, evicting CLOSEDs
        assert t.closed_count == 0 and t.valid_count == 10, t.snapshot()

        print("PerclosTracker self-test: OK")

    def run_blink_tests():
        # Fake clock so we can simulate frames at any pace.
        clock = [0.0]
        def fake_now():
            return clock[0]

        # Helper: feed a stretch of (p_left, p_right) over a duration.
        def feed(t, p_l, p_r, n_frames, total_seconds):
            dt = total_seconds / n_frames
            for _ in range(n_frames):
                clock[0] += dt
                t.update(p_l, p_r)

        # Case A: single 200ms blink registered, mean_dur ~= 200ms.
        t = BlinkTracker(time_fn=fake_now)
        feed(t, 0.9, 0.9, 100, 2.0)   # 2s OPEN
        feed(t, 0.1, 0.1, 10,  0.20)  # 200ms CLOSED
        feed(t, 0.9, 0.9, 100, 2.0)   # 2s OPEN
        snap = t.snapshot()
        assert snap["blink_count"] == 1, snap
        assert 150 < snap["mean_dur_ms"] < 260, snap
        assert snap["long_blink_count"] == 0, snap
        assert snap["is_fatigued"] is False, snap

        # Case B: three long blinks (700ms) -> long_blink alarm fires.
        t = BlinkTracker(time_fn=fake_now)
        for _ in range(3):
            feed(t, 0.9, 0.9, 50, 1.0)   # 1s OPEN
            feed(t, 0.1, 0.1, 35, 0.70)  # 700ms CLOSED (long)
        feed(t, 0.9, 0.9, 50, 1.0)
        snap = t.snapshot()
        assert snap["blink_count"] == 3, snap
        assert snap["long_blink_count"] == 3, snap
        assert snap["is_fatigued"] is True, snap
        # Either avg_blink or long_blinks could fire first; both are valid here.
        assert snap["fatigue_reason"] is not None, snap

        # Case C: face lost mid-blink -> blink discarded (not counted).
        t = BlinkTracker(time_fn=fake_now)
        feed(t, 0.9, 0.9, 30, 0.6)
        feed(t, 0.1, 0.1, 5, 0.10)   # blink starts
        feed(t, None, None, 5, 0.10) # face disappears mid-blink
        feed(t, 0.9, 0.9, 30, 0.6)
        snap = t.snapshot()
        assert snap["blink_count"] == 0, snap

        # Case D: window eviction - blinks older than 60s drop off.
        t = BlinkTracker(window_seconds=10.0, time_fn=fake_now)
        feed(t, 0.9, 0.9, 10, 0.2)
        feed(t, 0.1, 0.1, 10, 0.2)
        feed(t, 0.9, 0.9, 10, 0.2)  # blink #1 done at t~0.6s
        # Advance well past the 10s window.
        feed(t, 0.9, 0.9, 100, 12.0)
        snap = t.snapshot()
        assert snap["blink_count"] == 0, snap

        print("BlinkTracker self-test: OK")

    run_synthetic()
    run_blink_tests()
