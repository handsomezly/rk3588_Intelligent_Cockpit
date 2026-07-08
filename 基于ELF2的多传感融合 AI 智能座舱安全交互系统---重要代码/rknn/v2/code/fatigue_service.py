"""v2 fatigue-detection service: owns the camera + NPU, publishes frames over
shared memory and metrics over a local Unix socket. The Qt cockpit is a pure
display client.

Two modes:

  real (default, board only):
      Reuses the exact test.py pipeline (RetinaFace -> driver -> eye crop ->
      EyeCNN) plus perclos.py trackers. Instead of cv2.imshow it writes the raw
      RGB frame to /dev/shm and sends one metrics JSON line per frame.

      python3 code/fatigue_service.py \
          --face-model ./models/RetinaFace_mobile320.rknn \
          --eye-model ./eye_cnn.rknn --camera /dev/video21

  mock (host / no NPU):
      Generates a synthetic frame + cycling metrics so the Qt UI and the
      flicker fix can be developed and verified on the dev VM.

      python3 code/fatigue_service.py --mock

Frame transport: frame_shm.FrameShmWriter (triple-buffered tmpfs file).
Metrics transport: newline-delimited JSON over AF_UNIX SOCK_STREAM. The service
keeps running whether or not a client is connected; the client may reconnect.
"""

import argparse
import json
import math
import os
import socket
import time

import numpy as np

from frame_shm import FrameShmWriter
from camera_control import (
    DEFAULT_CONTROL_SOCK,
    CameraControlServer,
    CameraLifecycle,
    CameraState,
)
from imu_motion import (
    DEFAULT_IMU_SOCK,
    MotionContextReceiver,
    MotionGate,
    apply_alarm_gate,
)

DEFAULT_SHM = "cockpit_frame"
DEFAULT_SOCK = "/tmp/cockpit_fatigue.sock"
DEFAULT_CAMERA = "/dev/video21"
DEFAULT_FACE_MODEL = "./models/RetinaFace_mobile320.rknn"


# --------------------------------------------------------------------------- #
# Metrics socket (server). Accept is non-blocking so the pipeline never stalls
# waiting for the Qt client; the client send is blocking with a short timeout.
# --------------------------------------------------------------------------- #
class MetricsServer:
    def __init__(self, path):
        self.path = path
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._srv.bind(path)
        self._srv.listen(1)
        self._srv.setblocking(False)
        self._client = None
        print(f"[svc] metrics socket listening: {path}")

    def _accept(self):
        if self._client is not None:
            return
        try:
            conn, _ = self._srv.accept()
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            return
        conn.settimeout(1.0)
        self._client = conn
        print("[svc] client connected")

    def send(self, obj):
        self._accept()
        if self._client is None:
            return
        line = (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")
        try:
            self._client.sendall(line)
        except (BrokenPipeError, ConnectionResetError, socket.timeout, OSError):
            print("[svc] client disconnected")
            try:
                self._client.close()
            finally:
                self._client = None

    def close(self):
        if self._client is not None:
            self._client.close()
        self._srv.close()
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass


def _box_to_list(box):
    if box is None:
        return None
    return [int(round(v)) for v in box]


def build_metrics(seq, fps, eye_state, perclos_snap, blink_snap,
                  combined_fatigue, reason, frame_w, frame_h,
                  motion_decision=None, motion_context=None):
    """Translate the v2 pipeline outputs into the wire JSON schema."""
    p_status = perclos_snap["status"]
    if p_status in ("warming_up", "low_visibility"):
        status = p_status
    elif combined_fatigue:
        status = "fatigue_alarm"
    else:
        status = "normal"

    patches = eye_state.get("patches")
    face_box = patches.get("face_box") if patches else None

    metrics = {
        "seq": seq,
        "ts": round(time.time(), 3),
        "fps": round(fps, 1),
        "face_found": patches is not None,
        "status": status,
        "fatigue_alarm": bool(combined_fatigue),
        "fatigue_reason": reason,
        "perclos": round(float(perclos_snap["perclos"]), 4),
        "valid_count": int(perclos_snap["valid_count"]),
        "window_len": int(perclos_snap["window_len"]),
        "eye_left": eye_state.get("label_left"),
        "eye_right": eye_state.get("label_right"),
        "p_open_left": (round(float(eye_state["p_left"]), 3)
                        if eye_state.get("p_left") is not None else None),
        "p_open_right": (round(float(eye_state["p_right"]), 3)
                         if eye_state.get("p_right") is not None else None),
        "blink_rate": round(float(blink_snap["rate_per_min"]), 1),
        "mean_blink_ms": (round(float(blink_snap["mean_dur_ms"]), 0)
                          if blink_snap["mean_dur_ms"] is not None else None),
        "long_blink_count": int(blink_snap["long_blink_count"]),
        "frame_w": frame_w,
        "frame_h": frame_h,
        "face_box": _box_to_list(face_box),
        "eye_left_box": _box_to_list(eye_state.get("left_box")),
        "eye_right_box": _box_to_list(eye_state.get("right_box")),
    }
    if motion_decision is not None:
        metrics.update({
            "motion_gated": bool(motion_decision.suppressed),
            "motion_gate_reason": motion_decision.reason,
            "vision_confidence": round(float(motion_decision.confidence), 3),
            "vehicle_motion_state": ((motion_context or {}).get("motion_state")
                                     or "unknown"),
        })
    else:
        metrics.update({
            "motion_gated": False,
            "motion_gate_reason": "imu_missing",
            "vision_confidence": 1.0,
            "vehicle_motion_state": "unknown",
        })
    metrics.update({
        "camera_enabled": True,
        "camera_state": "running",
        "camera_error": "",
    })
    return metrics


def build_idle_metrics(camera_state):
    """Publish a neutral snapshot while no camera session is running."""
    metrics = {
        "seq": 0,
        "ts": round(time.time(), 3),
        "fps": 0.0,
        "face_found": False,
        "status": "camera_off",
        "fatigue_alarm": False,
        "fatigue_reason": None,
        "perclos": 0.0,
        "valid_count": 0,
        "window_len": 0,
        "eye_left": None,
        "eye_right": None,
        "p_open_left": None,
        "p_open_right": None,
        "blink_rate": 0.0,
        "mean_blink_ms": None,
        "long_blink_count": 0,
        "frame_w": 0,
        "frame_h": 0,
        "face_box": None,
        "eye_left_box": None,
        "eye_right_box": None,
        "motion_gated": False,
        "motion_gate_reason": "imu_missing",
        "vision_confidence": 1.0,
        "vehicle_motion_state": "unknown",
    }
    metrics.update(camera_state.metrics())
    return metrics


# --------------------------------------------------------------------------- #
# Real pipeline (board). Imports test.py lazily so --mock works without rknn.
# --------------------------------------------------------------------------- #
def run_real(args):
    import cv2  # noqa: heavy, board-only

    import test  # reuse the whole RetinaFace+EyeCNN pipeline
    from rknnpool_ld import rknnPoolExecutor
    from perclos import (
        PerclosTracker, BlinkTracker,
        STATUS_WARMING_UP, STATUS_LOW_VISIBILITY, STATUS_FATIGUE,
    )

    # Drive myFunc_pipeline in "no draw, fatigue on" mode: it returns the raw
    # frame plus the eye_state dict, no OpenCV overlay.
    test.PROFILE_ENABLED = False
    test.DRAW_RESULTS = False
    test.MODEL_ONLY = False
    test.FATIGUE_ENABLED = True

    cv2.setNumThreads(1)

    TPEs = 3
    pool = rknnPoolExecutor(
        face_model=args.face_model,
        eye_model=(args.eye_model or None),
        TPEs=TPEs,
        func=test.myFunc_pipeline,
    )
    print(f"[svc] face={args.face_model} eye={args.eye_model or '(dummy)'}")

    server = MetricsServer(args.sock)
    control = CameraControlServer(args.control_sock)
    motion_receiver = MotionContextReceiver(args.imu_sock)
    writer = None

    def open_session():
        cap = cv2.VideoCapture(args.camera, cv2.CAP_V4L2)
        if args.fourcc:
            fourcc = args.fourcc.upper()
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        cap.set(cv2.CAP_PROP_FPS, 30)
        if not cap.isOpened():
            cap.release()
            raise RuntimeError(f"无法打开摄像头 {args.camera}")

        try:
            for _ in range(TPEs + 1):
                ret, frame = cap.read()
                if not ret:
                    raise RuntimeError("摄像头预热读取失败")
                pool.put(frame)
        except Exception:
            cap.release()
            pool.drain()
            raise

        print(f"[svc] camera opened: {args.camera}")
        return {
            "cap": cap,
            "tracker": PerclosTracker(),
            "blink_tracker": BlinkTracker(),
            "motion_gate": MotionGate(),
            "last_alarm": False,
            "last_reason": None,
            "frames": 0,
            "fps": 0.0,
            "loop_t": time.time(),
        }

    def close_session(session):
        if session is not None:
            session["cap"].release()
        pool.drain()
        print("[svc] camera released")

    lifecycle = CameraLifecycle(open_session, close_session)
    next_idle_publish = 0.0
    print(f"[svc] running (real pipeline, camera default off), control={args.control_sock}")
    try:
        while True:
            requested = control.poll()
            if requested is not None:
                lifecycle.request(requested)
                next_idle_publish = 0.0

            if not lifecycle.state.enabled:
                now = time.monotonic()
                if now >= next_idle_publish:
                    server.send(build_idle_metrics(lifecycle.state))
                    next_idle_publish = now + 0.5
                time.sleep(0.02)
                continue

            session = lifecycle.resource
            ret, frame = session["cap"].read()
            if not ret:
                lifecycle.fail("摄像头读取失败")
                next_idle_publish = 0.0
                continue
            pool.put(frame)
            pkg, ok = pool.get()
            if not ok:
                lifecycle.fail("NPU 推理队列读取失败")
                next_idle_publish = 0.0
                continue
            frame_result, eye_state, _ = pkg
            h, w = frame_result.shape[:2]

            if writer is None:
                writer = FrameShmWriter(args.shm, width=w, height=h)
                print(f"[svc] shm ready: {writer.path} {w}x{h}")

            # IMU only gates short windows of unreliable visual observation.
            # Missing/stale IMU is neutral, and suppression is capped at 2 s.
            motion_context = motion_receiver.poll()
            motion_decision = session["motion_gate"].decide(motion_context)

            # PERCLOS + blink update (mirrors test.py main loop).
            if motion_decision.allow_observation:
                if eye_state.get("probs_left") is not None and eye_state.get("probs_right") is not None:
                    session["tracker"].update_probs(eye_state["probs_left"], eye_state["probs_right"])
                else:
                    session["tracker"].update(eye_state["p_left"], eye_state["p_right"])
                session["blink_tracker"].update(eye_state["p_left"], eye_state["p_right"])

            perclos_snap = session["tracker"].snapshot()
            blink_snap = session["blink_tracker"].snapshot()
            gate_clear = perclos_snap["status"] not in (STATUS_WARMING_UP, STATUS_LOW_VISIBILITY)
            perclos_fatigue = perclos_snap["status"] == STATUS_FATIGUE
            blink_fatigue = blink_snap["is_fatigued"]
            raw_combined = gate_clear and (perclos_fatigue or blink_fatigue)
            combined = apply_alarm_gate(raw_combined, session["last_alarm"], motion_decision)

            reason = None
            if combined and raw_combined:
                reasons = []
                if perclos_fatigue:
                    reasons.append(f"PERCLOS={perclos_snap['perclos']:.3f}")
                if blink_fatigue and blink_snap["fatigue_reason"]:
                    reasons.append(blink_snap["fatigue_reason"])
                reason = " | ".join(reasons) if reasons else None
            elif combined:
                reason = session["last_reason"]
            if combined and not session["last_alarm"]:
                print(f"[FATIGUE] {reason}")
            session["last_alarm"] = combined
            session["last_reason"] = reason if combined else None

            # Publish frame (BGR -> RGB) + metrics.
            rgb = cv2.cvtColor(frame_result, cv2.COLOR_BGR2RGB)
            seq = writer.write(rgb)
            metrics = build_metrics(
                seq, session["fps"], eye_state, perclos_snap, blink_snap,
                combined, reason, w, h,
                motion_decision=motion_decision,
                motion_context=motion_context)
            metrics.update(lifecycle.state.metrics())
            server.send(metrics)

            session["frames"] += 1
            if session["frames"] % 30 == 0:
                now = time.time()
                session["fps"] = 30.0 / max(now - session["loop_t"], 1e-6)
                session["loop_t"] = now
    except KeyboardInterrupt:
        print("\n[svc] 收到 Ctrl+C，退出")
    finally:
        if lifecycle.state.enabled:
            lifecycle.request(False)
        control.close()
        pool.release()
        server.close()
        motion_receiver.close()
        if writer is not None:
            writer.close()


# --------------------------------------------------------------------------- #
# Mock pipeline (host). No camera, no NPU; cycles metrics to exercise the UI.
# --------------------------------------------------------------------------- #
def _mock_frame(w, h, t):
    """Synthetic frame: gradient + a moving 'face' box and two 'eye' boxes."""
    img = np.empty((h, w, 3), dtype=np.uint8)
    xs = np.linspace(10, 70, w, dtype=np.uint8)
    img[:, :, 0] = xs[None, :]
    img[:, :, 1] = 20
    img[:, :, 2] = 30
    cx = int(w * 0.5 + math.sin(t * 0.8) * w * 0.12)
    cy = int(h * 0.5 + math.cos(t * 0.6) * h * 0.08)
    fw, fh = int(w * 0.30), int(h * 0.45)
    fx1, fy1 = cx - fw // 2, cy - fh // 2
    fx2, fy2 = cx + fw // 2, cy + fh // 2
    img[fy1:fy2, fx1:fx2] = (60, 70, 80)
    ey = cy - fh // 6
    ew, eh = int(fw * 0.22), int(fh * 0.12)
    lx = cx - fw // 5
    rx = cx + fw // 5
    img[ey - eh:ey + eh, lx - ew:lx + ew] = (200, 200, 210)
    img[ey - eh:ey + eh, rx - ew:rx + ew] = (200, 200, 210)
    face_box = [fx1, fy1, fx2, fy2]
    eye_l = [lx - ew, ey - eh, lx + ew, ey + eh]
    eye_r = [rx - ew, ey - eh, rx + ew, ey + eh]
    return img, face_box, eye_l, eye_r


def run_mock(args):
    w, h = 640, 480
    writer = None
    server = MetricsServer(args.sock)
    control = CameraControlServer(args.control_sock)
    motion_receiver = MotionContextReceiver(args.imu_sock)

    def open_session():
        return {
            "start": time.time(),
            "motion_gate": MotionGate(),
            "last_alarm": False,
            "last_reason": None,
        }

    def close_session(_session):
        return None

    lifecycle = CameraLifecycle(open_session, close_session)
    next_idle_publish = 0.0
    print(f"[svc] running (MOCK, camera default off), control={args.control_sock}")
    try:
        while True:
            requested = control.poll()
            if requested is not None:
                lifecycle.request(requested)
                next_idle_publish = 0.0

            if not lifecycle.state.enabled:
                now = time.monotonic()
                if now >= next_idle_publish:
                    server.send(build_idle_metrics(lifecycle.state))
                    next_idle_publish = now + 0.5
                time.sleep(0.02)
                continue

            session = lifecycle.resource
            if writer is None:
                writer = FrameShmWriter(args.shm, width=w, height=h)
                print(f"[svc] shm ready: {writer.path} {w}x{h}")

            t = time.time() - session["start"]
            frame, face_box, eye_l, eye_r = _mock_frame(w, h, t)
            seq = writer.write(frame)

            # Cycle a believable fatigue story over ~40s.
            phase = (t % 40.0) / 40.0
            perclos = max(0.0, min(0.45, 0.02 + 0.30 * max(0.0, math.sin(phase * math.pi * 2))))
            closing = perclos > 0.16
            p_open = 0.15 if closing else 0.92
            eye_label = "closed" if closing else ("squint" if perclos > 0.10 else "open")
            warming = t < 8.0
            motion_context = motion_receiver.poll()
            motion_decision = session["motion_gate"].decide(motion_context)
            raw_alarm = not warming and perclos > 0.15
            alarm = apply_alarm_gate(raw_alarm, session["last_alarm"], motion_decision)
            status = "warming_up" if warming else ("fatigue_alarm" if alarm else "normal")
            reason = f"PERCLOS={perclos:.3f}" if alarm and raw_alarm else session["last_reason"]
            session["last_alarm"] = alarm
            session["last_reason"] = reason if alarm else None

            metrics = {
                "seq": seq, "ts": round(time.time(), 3), "fps": 25.0,
                "face_found": True, "status": status, "fatigue_alarm": alarm,
                "fatigue_reason": reason,
                "perclos": round(perclos, 4),
                "valid_count": min(900, int(t * 25)), "window_len": min(900, int(t * 25)),
                "eye_left": eye_label, "eye_right": eye_label,
                "p_open_left": p_open, "p_open_right": round(p_open * 0.95, 3),
                "blink_rate": round(16 + 6 * math.sin(t * 0.3), 1),
                "mean_blink_ms": round(180 + 120 * max(0.0, math.sin(phase * math.pi * 2)), 0),
                "long_blink_count": 2 if alarm else 0,
                "frame_w": w, "frame_h": h,
                "face_box": face_box, "eye_left_box": eye_l, "eye_right_box": eye_r,
                "motion_gated": motion_decision.suppressed,
                "motion_gate_reason": motion_decision.reason,
                "vision_confidence": round(motion_decision.confidence, 3),
                "vehicle_motion_state": ((motion_context or {}).get("motion_state")
                                         or "unknown"),
            }
            metrics.update(lifecycle.state.metrics())
            server.send(metrics)
            time.sleep(1.0 / 25.0)
    except KeyboardInterrupt:
        print("\n[svc] 收到 Ctrl+C，退出")
    finally:
        if lifecycle.state.enabled:
            lifecycle.request(False)
        control.close()
        server.close()
        motion_receiver.close()
        if writer is not None:
            writer.close()


def parse_args():
    ap = argparse.ArgumentParser(description="v2 fatigue inference service")
    ap.add_argument("--mock", action="store_true", help="synthetic frames+metrics, no NPU")
    ap.add_argument("--camera", default=DEFAULT_CAMERA)
    ap.add_argument("--fourcc", default="", help="e.g. MJPG or YUYV")
    ap.add_argument("--face-model", default=DEFAULT_FACE_MODEL)
    ap.add_argument("--eye-model", default="./eye_cnn.rknn")
    ap.add_argument("--shm", default=DEFAULT_SHM, help="shm name under /dev/shm or abs path")
    ap.add_argument("--sock", default=DEFAULT_SOCK, help="AF_UNIX metrics socket path")
    ap.add_argument("--imu-sock", default=DEFAULT_IMU_SOCK,
                    help="AF_UNIX datagram path for Qt IMU motion context")
    ap.add_argument("--control-sock", default=DEFAULT_CONTROL_SOCK,
                    help="AF_UNIX datagram path for camera on/off commands")
    return ap.parse_args()


if __name__ == "__main__":
    args = parse_args()
    if args.mock:
        run_mock(args)
    else:
        run_real(args)
