"""Eye-region cropping helpers for the fatigue-detection pipeline.

RetinaFace post_process returns rows shaped:
    [x1, y1, x2, y2, score, lm0_x, lm0_y, ..., lm4_x, lm4_y]
Landmark order: 0=left eye, 1=right eye, 2=nose, 3=left mouth, 4=right mouth.
Coordinates are already in the original frame's pixel space.
"""

import math
import os
import time

import cv2
import numpy as np

# Detection-row column indices (matches post_process layout in test.py).
COL_X1, COL_Y1, COL_X2, COL_Y2, COL_SCORE = 0, 1, 2, 3, 4
COL_LM_LEFT_X, COL_LM_LEFT_Y = 5, 6
COL_LM_RIGHT_X, COL_LM_RIGHT_Y = 7, 8

# Quality gates: skip eye crops when face is too small or low-confidence.
MIN_FACE_SCORE = 0.7
MIN_FACE_HEIGHT = 80
DEFAULT_PATCH_SIZE = 32


def select_driver(detections):
    """Pick the largest face (h*w) as the driver. Returns one row or None."""
    if detections is None or len(detections) == 0:
        return None
    widths = detections[:, COL_X2] - detections[:, COL_X1]
    heights = detections[:, COL_Y2] - detections[:, COL_Y1]
    areas = widths * heights
    idx = int(np.argmax(areas))
    return detections[idx]


def _aligned_eye_patch(gray, center, half, angle_deg, patch_size):
    """Extract a square eye patch rotated so the eye line is horizontal.

    The crop region is a square of side 2*half centered on the eye landmark
    in the original frame, rotated by `angle_deg` (the roll angle of the line
    connecting both eye landmarks). warpAffine produces the aligned patch
    directly at the target resolution, so head roll is removed regardless of
    how far it goes - much cleaner than relying on training-time augmentation
    to cover ±25-30° rotation.

    Returns (patch_uint8, axis_aligned_bbox) where bbox is the smallest
    axis-aligned rectangle containing the rotated source square. The bbox is
    only used for on-screen drawing in test.py; the patch fed to the CNN is
    `patch_uint8`.
    """
    cx, cy = center
    scale = patch_size / (2.0 * half)
    # getRotationMatrix2D angle is CCW-positive. With image-coord y-down, the
    # raw atan2(dy, dx) of the eye line is exactly the angle we need to pass
    # so both landmarks end up on the same destination row (derivation: solve
    # for theta in left_dst_y == right_dst_y -> tan(theta) = dy/dx).
    M = cv2.getRotationMatrix2D((cx, cy), angle_deg, scale)
    M[0, 2] += patch_size / 2.0 - cx
    M[1, 2] += patch_size / 2.0 - cy
    patch = cv2.warpAffine(
        gray, M, (patch_size, patch_size),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_REFLECT,
    )

    cos_a = math.cos(math.radians(angle_deg))
    sin_a = math.sin(math.radians(angle_deg))
    xs = []
    ys = []
    for dx, dy in ((-half, -half), (half, -half), (half, half), (-half, half)):
        xs.append(cx + cos_a * dx + sin_a * dy)
        ys.append(cy - sin_a * dx + cos_a * dy)
    frame_h, frame_w = gray.shape[:2]
    x1 = max(0, int(round(min(xs))))
    y1 = max(0, int(round(min(ys))))
    x2 = min(frame_w - 1, int(round(max(xs))))
    y2 = min(frame_h - 1, int(round(max(ys))))
    if x2 - x1 < 4 or y2 - y1 < 4:
        return None
    return patch, (x1, y1, x2, y2)


def crop_eye_patches(frame_bgr, det, patch_size=DEFAULT_PATCH_SIZE):
    """Crop left+right eye regions around RetinaFace landmarks.

    Returns dict {left, right, left_box, right_box, score, box_h} or None when
    the detection fails the quality gates or the eye crop falls outside the frame.
    Patches are returned as uint8 grayscale, shape (patch_size, patch_size).
    """
    if det is None:
        return None

    score = float(det[COL_SCORE])
    if score < MIN_FACE_SCORE:
        return None

    box_h = float(det[COL_Y2] - det[COL_Y1])
    if box_h < MIN_FACE_HEIGHT:
        return None

    left = (float(det[COL_LM_LEFT_X]), float(det[COL_LM_LEFT_Y]))
    right = (float(det[COL_LM_RIGHT_X]), float(det[COL_LM_RIGHT_Y]))

    d_eye = float(np.hypot(left[0] - right[0], left[1] - right[1]))
    # Plan-evaluated rule: max(0.35*d_eye, 0.18*box_h) keeps eye region inside
    # the patch even on slight side-poses where d_eye shrinks.
    #
    # NOTE 2026-05-26: tried bumping to (0.50, 0.30) to tolerate landmark drift
    # on rolled heads. Result was catastrophic - the trained EyeCNN saw "small
    # eye in big background" patches it never saw at training time, so baseline
    # PERCLOS jumped from 0.000 to 0.766. Reverted. The right fix for landmark
    # drift is either (a) retrain on wider crops, or (b) temporal landmark EMA.
    half = max(0.35 * d_eye, 0.18 * box_h) / 2.0
    if half < 4:
        return None

    frame_h, frame_w = frame_bgr.shape[:2]
    # Eye landmarks must be inside the frame; if RetinaFace clipped one to
    # the border, warpAffine would fill the patch with reflected pixels and
    # the CNN sees a fabricated image.
    if not (0 <= left[0] < frame_w and 0 <= left[1] < frame_h):
        return None
    if not (0 <= right[0] < frame_w and 0 <= right[1] < frame_h):
        return None

    # Head-roll angle from the inter-eye vector; positive when right eye sits
    # lower than left on screen.
    angle_deg = math.degrees(math.atan2(right[1] - left[1], right[0] - left[0]))

    gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)

    left_result = _aligned_eye_patch(gray, left, half, angle_deg, patch_size)
    right_result = _aligned_eye_patch(gray, right, half, angle_deg, patch_size)
    if left_result is None or right_result is None:
        return None
    left_patch, left_box = left_result
    right_patch, right_box = right_result

    return {
        "left": left_patch,
        "right": right_patch,
        "left_box": left_box,
        "right_box": right_box,
        "score": score,
        "box_h": box_h,
        "eye_distance": d_eye,
        "roll_angle_deg": angle_deg,
        "left_center": left,
        "right_center": right,
        "face_box": (
            float(det[COL_X1]),
            float(det[COL_Y1]),
            float(det[COL_X2]),
            float(det[COL_Y2]),
        ),
    }


def dummy_classify_eye(patch_gray):
    """Hand-crafted open-eye probability used to validate the pipeline before
    the real CNN is trained. Open eyes show iris/pupil texture (high vertical
    gradient energy in the lower half); closed eyes are smoother.

    NOTE: prefer the trained EyeCNN (--eye-model) for any actual evaluation.
    This is only a fallback so the pipeline can run without a model.
    """
    if patch_gray is None:
        return 0.5
    bottom = patch_gray[patch_gray.shape[0] // 2 :, :]
    # Vertical Sobel (dx=0, dy=1) captures eyelid/iris boundaries best.
    sobel = cv2.Sobel(bottom, cv2.CV_32F, 0, 1, ksize=3)
    energy = float(np.mean(np.abs(sobel)))
    # Empirical scale: open eyes give ~25-60, closed ~5-15 on this camera.
    return float(min(max((energy - 10.0) / 25.0, 0.0), 1.0))


class EyePatchSaver:
    """Persist eye crops for later use as RKNN quantization calibration data."""

    def __init__(self, out_dir, max_images=2000, min_interval_sec=0.10):
        self.out_dir = out_dir
        self.max_images = max_images
        self.min_interval_sec = min_interval_sec
        self.count = 0
        self._last_save = 0.0
        os.makedirs(out_dir, exist_ok=True)

    def maybe_save(self, patches):
        """Save a (left, right) pair when interval/limit allow. Returns count saved."""
        if patches is None:
            return 0
        if self.count >= self.max_images:
            return 0
        now = time.time()
        if now - self._last_save < self.min_interval_sec:
            return 0
        self._last_save = now

        stamp = time.strftime("%Y%m%d_%H%M%S") + f"_{int((now * 1000) % 1000):03d}"
        left_path = os.path.join(self.out_dir, f"eye_L_{stamp}.png")
        right_path = os.path.join(self.out_dir, f"eye_R_{stamp}.png")
        cv2.imwrite(left_path, patches["left"])
        cv2.imwrite(right_path, patches["right"])
        self.count += 2
        return 2

    def is_full(self):
        return self.count >= self.max_images
